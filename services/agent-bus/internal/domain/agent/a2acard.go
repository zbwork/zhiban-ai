// a2acard.go — A2A v1b 协作卡片 (plans/2026-07-06 §8.2) 领域类型与校验。
//
// 两条消费路径, 两种解析姿势:
//   - Admin PUT (写路径): ValidateA2ACard — 严格 fail-closed, 非法即拒 (400), 不落库;
//   - discover / invoke (读路径): ParseA2ACardLenient — 永不失败, 非法/历史脏数据按空卡默认值处理,
//     不 panic、不阻断候选返回 (卡片只是提示, 治理闸门另有 capability/callable)。
//
// requires_approval=true 的卡片: discover 照常返回 (带标记), invoke fail-closed 拒
// (a2a.approval_required, v1b 无审批流)。
package agent

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// A2AInvokeSentinelUUID a2a_invoke capability 哨兵 (boundaries §3.4 / database-design §5.3):
// a2a_invoke 是非版本化运行时开关, 唯一合法 binding 形态 =
// (agent_version_id IS NULL, capability_uuid=本哨兵, source='borrow')。
const A2AInvokeSentinelUUID = "00000000-0000-0000-0000-000000000000"

// A2ACardSchemaVersion 当前唯一支持的卡片 schema 版本。
const A2ACardSchemaVersion = "a2a-card-1"

// A2ACardMaxBytes 卡片原文上限 (与 a2a payload redaction cap 同量级)。
const A2ACardMaxBytes = 16 * 1024

// A2ACardExample few-shot 示例。
type A2ACardExample struct {
	Input  string `json:"input"`
	Expect string `json:"expect,omitempty"`
}

// A2ACard digital_employees.a2a_card 的领域投影 (schema 见 plans/2026-07-06 §8.2)。
type A2ACard struct {
	SchemaVersion    string           `json:"schema_version"`
	Summary          string           `json:"summary"`
	WhenToUse        []string         `json:"when_to_use"`
	WhenNotToUse     []string         `json:"when_not_to_use"`
	Examples         []A2ACardExample `json:"examples"`
	InputSchema      map[string]any   `json:"input_schema"`
	OutputSchema     map[string]any   `json:"output_schema"`
	SupportedModes   []string         `json:"supported_modes"`
	RiskLevel        string           `json:"risk_level"`
	RequiresApproval bool             `json:"requires_approval"`
	CardVersion      int              `json:"card_version"`
}

// 卡片字段上限 (v1b 拍板; 超限 = 400, 防 LLM 上下文注入体积失控)。
const (
	a2aCardMaxSummaryRunes = 500
	a2aCardMaxListItems    = 20
	a2aCardMaxItemRunes    = 300
	a2aCardMaxExamples     = 10
	a2aCardMaxExampleRunes = 1000
)

// applyA2ACardDefaults 空值归一化 (读写路径共用): modes 空 → [sync async], risk 空 → low,
// schema_version 空 → 当前版本, 切片 nil → 空切片 (JSON 序列化稳定)。
func applyA2ACardDefaults(c *A2ACard) {
	if c.SchemaVersion == "" {
		c.SchemaVersion = A2ACardSchemaVersion
	}
	if len(c.SupportedModes) == 0 {
		c.SupportedModes = []string{"sync", "async"}
	}
	if c.RiskLevel == "" {
		c.RiskLevel = "low"
	}
	if c.WhenToUse == nil {
		c.WhenToUse = []string{}
	}
	if c.WhenNotToUse == nil {
		c.WhenNotToUse = []string{}
	}
	if c.Examples == nil {
		c.Examples = []A2ACardExample{}
	}
	if c.InputSchema == nil {
		c.InputSchema = map[string]any{}
	}
	if c.OutputSchema == nil {
		c.OutputSchema = map[string]any{}
	}
	if c.CardVersion < 0 {
		c.CardVersion = 0
	}
}

// ParseA2ACardLenient 读路径解析: 永不返回错误。
//   - "" / "{}" / 非法 JSON / 类型不符 / 枚举非法 → 按空卡默认值 (fail-closed 到最保守展示,
//     requires_approval 保持 false —— 卡片非法不等于要审批, 治理闸门在 capability/callable);
//   - 合法但缺字段 → 补默认值。
func ParseA2ACardLenient(raw string) A2ACard {
	var c A2ACard
	if raw != "" && len(raw) <= A2ACardMaxBytes {
		// 宽松: 未知字段忽略; 类型不符整体回退空卡 (部分字段坏 → 整卡不可信)。
		if err := json.Unmarshal([]byte(raw), &c); err != nil {
			c = A2ACard{}
		}
	}
	// 枚举非法 → 回退默认 (不整卡丢弃: risk/modes 单字段坏只影响该字段)。
	if c.RiskLevel != "" && !isValidA2ARiskLevel(c.RiskLevel) {
		c.RiskLevel = ""
	}
	c.SupportedModes = filterValidA2AModes(c.SupportedModes)
	applyA2ACardDefaults(&c)
	return c
}

// ValidateA2ACard 写路径严格校验 + 归一化。unknown field / 类型不符 / 枚举非法 / 超限 → error。
// 返回归一化后的卡片 (调用方负责设置 CardVersion 后 Marshal 落库)。
func ValidateA2ACard(raw []byte) (*A2ACard, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("a2a_card: empty body")
	}
	if len(raw) > A2ACardMaxBytes {
		return nil, fmt.Errorf("a2a_card: exceeds %d bytes", A2ACardMaxBytes)
	}
	var c A2ACard
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("a2a_card: invalid json: %w", err)
	}
	// 严格拒绝 trailing token (v1b review 返修): Decoder 只消费第一个 JSON 值,
	// `{"summary":"x"} {"extra":1}` 这类多值/尾随垃圾必须整体拒绝, 防"校验看前半、落库存全文"歧义。
	if err := dec.Decode(new(json.RawMessage)); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("a2a_card: invalid json: trailing data after document")
	}
	if c.SchemaVersion != "" && c.SchemaVersion != A2ACardSchemaVersion {
		return nil, fmt.Errorf("a2a_card: unsupported schema_version %q", c.SchemaVersion)
	}
	if utf8.RuneCountInString(c.Summary) > a2aCardMaxSummaryRunes {
		return nil, fmt.Errorf("a2a_card: summary exceeds %d runes", a2aCardMaxSummaryRunes)
	}
	if err := validateA2ACardList("when_to_use", c.WhenToUse); err != nil {
		return nil, err
	}
	if err := validateA2ACardList("when_not_to_use", c.WhenNotToUse); err != nil {
		return nil, err
	}
	if len(c.Examples) > a2aCardMaxExamples {
		return nil, fmt.Errorf("a2a_card: examples exceeds %d items", a2aCardMaxExamples)
	}
	for i, ex := range c.Examples {
		if ex.Input == "" {
			return nil, fmt.Errorf("a2a_card: examples[%d].input required", i)
		}
		if utf8.RuneCountInString(ex.Input) > a2aCardMaxExampleRunes ||
			utf8.RuneCountInString(ex.Expect) > a2aCardMaxExampleRunes {
			return nil, fmt.Errorf("a2a_card: examples[%d] exceeds %d runes", i, a2aCardMaxExampleRunes)
		}
	}
	if c.RiskLevel != "" && !isValidA2ARiskLevel(c.RiskLevel) {
		return nil, fmt.Errorf("a2a_card: risk_level must be low|medium|high")
	}
	for _, m := range c.SupportedModes {
		if m != "sync" && m != "async" {
			// stream 本轮不开放 (plans/2026-07-06 §16 v2)
			return nil, fmt.Errorf("a2a_card: supported_modes only allows sync|async, got %q", m)
		}
	}
	applyA2ACardDefaults(&c)
	return &c, nil
}

func validateA2ACardList(field string, items []string) error {
	if len(items) > a2aCardMaxListItems {
		return fmt.Errorf("a2a_card: %s exceeds %d items", field, a2aCardMaxListItems)
	}
	for i, it := range items {
		if it == "" {
			return fmt.Errorf("a2a_card: %s[%d] empty", field, i)
		}
		if utf8.RuneCountInString(it) > a2aCardMaxItemRunes {
			return fmt.Errorf("a2a_card: %s[%d] exceeds %d runes", field, i, a2aCardMaxItemRunes)
		}
	}
	return nil
}

func isValidA2ARiskLevel(r string) bool {
	return r == "low" || r == "medium" || r == "high"
}

func filterValidA2AModes(modes []string) []string {
	if len(modes) == 0 {
		return nil
	}
	out := make([]string, 0, len(modes))
	seen := map[string]bool{}
	for _, m := range modes {
		if (m == "sync" || m == "async") && !seen[m] {
			seen[m] = true
			out = append(out, m)
		}
	}
	return out
}

// SupportsMode 卡片是否声明支持某 invoke_kind ("" = 不过滤)。
func (c A2ACard) SupportsMode(mode string) bool {
	if mode == "" {
		return true
	}
	for _, m := range c.SupportedModes {
		if m == mode {
			return true
		}
	}
	return false
}

// A2ACardEmbeddingText 生成协作卡片的向量化文本。只包含正向能力描述,
// 不包含 when_not_to_use, 避免“不适合找它”的关键词反而拉高相似度。
func A2ACardEmbeddingText(name string, tags []string, card A2ACard) string {
	parts := []string{
		"name: " + name,
		"summary: " + card.Summary,
		"tags: " + strings.Join(tags, ", "),
		"when_to_use: " + strings.Join(card.WhenToUse, "\n"),
	}
	if len(card.Examples) > 0 {
		examples := make([]string, 0, len(card.Examples))
		for _, ex := range card.Examples {
			examples = append(examples, strings.TrimSpace(ex.Input+" -> "+ex.Expect))
		}
		parts = append(parts, "examples: "+strings.Join(examples, "\n"))
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}
