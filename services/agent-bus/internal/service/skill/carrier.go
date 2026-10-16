// carrier.go — F03 v0.9.1 ZAP skills carrier 序列化层（spec §3.5 / §6.1 / §6.5；协议 ZAP-1.1 §11）。
//
// 把内部 SkillRail / 单技能版本 → ZAP `POST /sessions` body.skills 节
// + `POST /sessions/{sid}/skills/resync` 全量快照 + `PATCH /sessions/{sid}/skills` 增量 body 的纯函数。
//
// **范围**：仅做数据形变与序列化；
//   - 出站 HTTP（NewSession / PATCH / Resync）调用见 internal/adapter/zapclient/client.go
//   - 带 agent/包/builtin_key 装载的完整构造见 zap_carrier.go（Service.BuildZapSessionSkills），
//     chat 派发 (POST /sessions) 与绑定变化后的 live session resync 都走它。
//   - 字段名以协议 ZAP-1.1 §11.1 为准（`skill_id`；dsh-runtime `src/skills/skills.ts` 同口径）。
package skill

import (
	"encoding/json"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
)

// AgentSkillCarrier 对应 ZAP-1.1 §11.1 `skills.agent_skills[]` 单元。
type AgentSkillCarrier struct {
	SkillID          string          `json:"skill_id"`
	Code             string          `json:"code"`
	Version          string          `json:"version"`
	PackageURL       string          `json:"package_url"`
	PackageSHA256    string          `json:"package_sha256"`
	PackageSizeBytes int64           `json:"package_size_bytes"`
	DefaultParams    json.RawMessage `json:"default_params"`
	Frontmatter      Frontmatter     `json:"frontmatter"`
}

// Frontmatter 对应 SKILL.md zip 解析后的前置元数据快照（§11.1 平铺，避免 Agent 重复解析）。
type Frontmatter struct {
	Name             string          `json:"name,omitempty"`
	InputChipsSchema json.RawMessage `json:"input_chips_schema"`
	AgentCompat      json.RawMessage `json:"agent_compat,omitempty"`
}

// BuiltinSkillCarrier 对应 ZAP-1.1 §11.1 `skills.builtin_skills[]` 单元（read-only 视图）。
type BuiltinSkillCarrier struct {
	SkillID          string          `json:"skill_id"`
	Code             string          `json:"code"`
	BuiltinKey       string          `json:"builtin_key"`
	Name             string          `json:"name,omitempty"`
	ExecutionMode    string          `json:"execution_mode"`
	DefaultParams    json.RawMessage `json:"default_params"`
	InputChipsSchema json.RawMessage `json:"input_chips_schema"`
}

// SkillsCarrier 嵌入 ZAP `POST /sessions` body 的 skills 节根（resync body.skills 同 schema）。
type SkillsCarrier struct {
	AgentSkills   []AgentSkillCarrier   `json:"agent_skills"`
	BuiltinSkills []BuiltinSkillCarrier `json:"builtin_skills"`
}

// ResyncPayload 对应 ZAP-1.1 §11.3 POST /zap/v1/sessions/{sid}/skills/resync body。
type ResyncPayload struct {
	SessionID string         `json:"session_id"`
	Skills    *SkillsCarrier `json:"skills"`
}

// PatchPayload 对应 spec §6.5.A PATCH /zap/v1/sessions/{sid}/skills body。
type PatchPayload struct {
	SessionID string              `json:"session_id"`
	PatchSeq  int64               `json:"patch_seq"`
	Added     []AgentSkillCarrier `json:"added,omitempty"`
	Updated   []AgentSkillCarrier `json:"updated,omitempty"`
	Removed   []string            `json:"removed,omitempty"`
}

// packageMeta 单技能版本的 zip 元数据（签名下载 URL + 完整性信息），由对象存储解出。
type packageMeta struct {
	URL       string
	SHA256    string
	SizeBytes int64
}

// BuildSessionCarrier 把 SkillRail 转成出站 ZAP carrier（POST /sessions / resync 用）。
//
//   - packageByVersionUUID: version_uuid → 包元数据。**没有可用签名 URL 的 agent 技能会被整条跳过**
//     （协议要求 package_url 为 http(s)，空串会让 runtime 422 拒开会话，宁可少下发一个技能）。
//   - builtinKeyBySkillUUID: skill_uuid → builtin_key（rail 项不带该字段，由 service 阶段查 skills 表补齐）。
func BuildSessionCarrier(rail *domskill.SkillRail, packageByVersionUUID map[string]packageMeta, builtinKeyBySkillUUID map[string]string) *SkillsCarrier {
	out := &SkillsCarrier{
		AgentSkills:   []AgentSkillCarrier{},
		BuiltinSkills: []BuiltinSkillCarrier{},
	}
	if rail == nil {
		return out
	}
	all := append([]domskill.SkillRailItem{}, rail.ChipRail...)
	all = append(all, rail.MoreDrawer...)
	for _, it := range all {
		switch it.Kind {
		case domskill.KindAgent:
			meta, ok := packageByVersionUUID[it.VersionUUID]
			if !ok || meta.URL == "" {
				continue
			}
			out.AgentSkills = append(out.AgentSkills, AgentSkillCarrier{
				SkillID:          it.SkillUUID,
				Code:             it.Code,
				Version:          it.Version,
				PackageURL:       meta.URL,
				PackageSHA256:    meta.SHA256,
				PackageSizeBytes: meta.SizeBytes,
				DefaultParams:    rawOr(it.DefaultParams, "{}"),
				Frontmatter: Frontmatter{
					Name:             it.Name,
					InputChipsSchema: rawOr(it.InputChipsSchema, "[]"),
				},
			})
		case domskill.KindBuiltin:
			out.BuiltinSkills = append(out.BuiltinSkills, BuiltinSkillCarrier{
				SkillID:          it.SkillUUID,
				Code:             it.Code,
				BuiltinKey:       builtinKeyBySkillUUID[it.SkillUUID],
				Name:             it.Name,
				ExecutionMode:    it.ExecutionMode,
				DefaultParams:    rawOr(it.DefaultParams, "{}"),
				InputChipsSchema: rawOr(it.InputChipsSchema, "[]"),
			})
		}
	}
	return out
}

func rawOr(b []byte, def string) json.RawMessage {
	if len(b) == 0 {
		return json.RawMessage(def)
	}
	return json.RawMessage(b)
}
