// probe.go: stateless RuntimeCard 连通性测试 (M3 §6 / ZAP v1.1 §1)。
//
// 该 service **不写库**: probe 阶段拿 inline secret, 通过后签 probe_token,
// 由 create 端复用同一份 token 才能落库; 见 [ProbeTokenIssuer]。
//
// 调用方 (platform admin / tenant admin / personal client) 透传:
//   - framework / endpoints / auth.secret / timeout_sec / expect_multi_agent
//
// 通过 caller 信息 (account_id / tenant_id / scope) 由 transport 层注入。
package runtime

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	zapadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
)

// AgentManagement 反序列化 RuntimeCard.agent_management。
type AgentManagement struct {
	SupportsCreate bool `json:"supports_create"`
	SupportsUpdate bool `json:"supports_update"`
	SupportsDelete bool `json:"supports_delete"`
	SupportsList   bool `json:"supports_list"`
}

// RuntimeCard 反序列化 RuntimeCard JSON (ZAP v1.1 §1.2; v0.3 ADR-0025)。
type RuntimeCard struct {
	ProtocolVersion     string          `json:"protocol_version"`
	SchemaVersion       string          `json:"schema_version"`
	Framework           string          `json:"framework"`
	Vendor              string          `json:"vendor,omitempty"`
	Version             string          `json:"version,omitempty"`
	Description         string          `json:"description,omitempty"`
	SupportsMultiAgent  bool            `json:"supports_multi_agent"`
	DefaultAgentKey     string          `json:"default_agent_key,omitempty"`
	MaxAgents           int             `json:"max_agents"`
	AgentManagement     AgentManagement `json:"agent_management"`
	RuntimeUIComponents []string        `json:"runtime_ui_components,omitempty"`
	DataEgress          string          `json:"data_egress,omitempty"`
	Limits              map[string]any  `json:"limits,omitempty"`
	// ADR-0025 §2.8a: runtime 自描述能否做 per-tenant 数据隔离。
	// 缺省 / 缺失字段视为 false; platform external probe 强校验 = true。
	MultiTenantIsolation      bool   `json:"multi_tenant_isolation,omitempty"`
	MultiTenantIsolationNotes string `json:"multi_tenant_isolation_notes,omitempty"`
	// LLMCredentials ZAP v0.35: /instances llm.scope 支持声明 (supports_agent_scope), 原样保留供缓存与展示。
	LLMCredentials map[string]any `json:"llm_credentials,omitempty"`
	Extensions     map[string]any `json:"extensions,omitempty"`
}

// ProbeRequest probe 入参 (M3 §6.1)。caller 信息在 service 调用时显式传入。
type ProbeRequest struct {
	Framework        string            `json:"framework"`
	Endpoints        map[string]string `json:"endpoints"` // base / ws / agent_card
	Auth             ProbeAuth         `json:"auth"`
	TimeoutSec       int               `json:"timeout_sec"`
	ExpectMultiAgent *bool             `json:"expect_multi_agent,omitempty"`
	// Scope 由 transport 层根据路由注入: platform / tenant / personal。
	// 不出现在 wire body, 但在签 probe_token 时绑定。
	Scope string `json:"-"`
}

// ProbeAuth probe 阶段鉴权。
//
// P1-1 闭环 (Codex 第三轮): 必须显式带 SecretRef, probe 阶段用它 + Kind 计算
// AuthConfigSHA256, 写进 probe_token claims; create/patch 用相同 SecretRef
// 写库时, service 层在 verify 阶段重算同一 hash 比对, 任何不一致都拒绝。
//
//   - Secret    : probe 时实际握手用的明文 (e.g. inline bearer token);
//     仅在 probe 调用栈里短暂存在, 不入库, 不写进 token claims。
//   - SecretRef : 最终入库的引用 (env:// 或 value://); 必填,
//     与 create/patch 的 api_key_secret_ref 必须一致。
type ProbeAuth struct {
	Kind      string `json:"kind"`                 // bearer
	Secret    string `json:"secret"`               // probe 用明文; 不入 token
	SecretRef string `json:"secret_ref,omitempty"` // 入库 ref; 必填以闭环 P1-1
}

// ProbeResult probe 响应 (M3 §6.1 / §6.2)。
//
// ok=true 时 ProbeToken / ProtocolVersion / FrameworkDetected / RuntimeCard 必填;
// ok=false 时 ErrorCode / ErrorMessage 必填, 其余按情况填。
type ProbeResult struct {
	OK                       bool         `json:"ok"`
	LatencyMs                int64        `json:"latency_ms"`
	ProbeToken               string       `json:"probe_token,omitempty"`
	ProtocolVersion          string       `json:"protocol_version,omitempty"`
	FrameworkDetected        string       `json:"framework_detected,omitempty"`
	RuntimeCard              *RuntimeCard `json:"runtime_card,omitempty"`
	MissingRequiredEndpoints []string     `json:"missing_required_endpoints,omitempty"`
	Warnings                 []string     `json:"warnings,omitempty"`
	ErrorCode                string       `json:"error_code,omitempty"`
	ErrorMessage             string       `json:"error_message,omitempty"`
}

// ProbeService stateless 探测; 不写库。
type ProbeService interface {
	Probe(ctx context.Context, callerAccountID, callerTenantID int64, req ProbeRequest) (*ProbeResult, error)
}

// HTTPDoer 抽象 net/http 客户端, 便于单测注入 mock。
type HTTPDoer interface {
	Do(req *http.Request) (*http.Response, error)
}

type probeImpl struct {
	doer    HTTPDoer
	now     func() time.Time
	token   *ProbeTokenIssuer
	ssrf    *SSRFGuard
	callLog *zapadapter.CallLogWriter
}

// ProbeOptions 构造选项 (test/dev/prod 由 caller 控制)。
type ProbeOptions struct {
	// Doer 自定义 HTTP client; nil → 默认 http.Client + Timeout=30s + 禁 redirect。
	Doer HTTPDoer
	// SSRFGuard nil → 严格默认 (仅 https, 拒所有私网)。
	// dev/test caller 可注入 AllowHTTP=true / AllowedHosts=[]string{"127.0.0.1"}。
	SSRFGuard *SSRFGuard
	// CallLog 记录 ZAP runtime_card / agent-management probe 的请求结果。
	CallLog *zapadapter.CallLogWriter
}

// NewProbeService 构造 probe service。
//
// 旧签名 (doer, tokenIssuer) 已废弃; 调用方迁移到 NewProbeServiceWithOptions。
// 兼容: 旧签名内部转为 ProbeOptions{Doer: doer}, SSRF 用严格默认。
func NewProbeService(doer HTTPDoer, tokenIssuer *ProbeTokenIssuer) ProbeService {
	return NewProbeServiceWithOptions(tokenIssuer, ProbeOptions{Doer: doer})
}

// NewProbeServiceWithOptions 构造 probe service + 完整选项。
//
// 默认 Doer 走 SSRFGuard.SafeTransport, 把 DialContext 拦在 SSRF 守卫链,
// 防 Validate ↔ Dial 之间 DNS rebinding。
// 单测可注入 opt.Doer (fake Doer 不会真发网络, 但仍由 probe.Probe 入口
// 调 SSRFGuard.Validate 早期失败)。
func NewProbeServiceWithOptions(tokenIssuer *ProbeTokenIssuer, opt ProbeOptions) ProbeService {
	guard := opt.SSRFGuard
	if guard == nil {
		guard = &SSRFGuard{}
	}
	doer := opt.Doer
	if doer == nil {
		doer = &http.Client{
			Timeout:       30 * time.Second,
			CheckRedirect: noRedirect,
			Transport:     guard.SafeTransport(),
		}
	}
	return &probeImpl{doer: doer, now: time.Now, token: tokenIssuer, ssrf: guard, callLog: opt.CallLog}
}

// 框架白名单 (ADR-0023, ZAP v1.1 §1.2, 与 runtimetype.known 保持一致)。
// agno/langgraph/autogen/custom 不再支持 (UI 也已删除选项)。
var allowedFrameworks = map[string]bool{
	"openclaw": true,
	"hermes":   true,
	"zap":      true,
	"dsh":      true, // 平台自营 dsh 运行时: 线协议 ZAP, runtime_card.framework 报 zap (ADR-0035 修订)
}

func (p *probeImpl) Probe(ctx context.Context, callerAccountID, callerTenantID int64, req ProbeRequest) (*ProbeResult, error) {
	start := p.now()
	res := &ProbeResult{}

	// 1. 基础校验。
	if _, ok := allowedFrameworks[req.Framework]; !ok {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.framework_mismatch"
		res.ErrorMessage = fmt.Sprintf("framework %q not in allowed set", req.Framework)
		return res, nil
	}
	base := strings.TrimRight(req.Endpoints["base"], "/")
	if base == "" {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.unreachable"
		res.ErrorMessage = "endpoints.base required"
		return res, nil
	}
	// SSRF 守卫: probe 实际只用 base (拉 /zap/v1/runtime_card + /zap/v1/agents);
	// ws / agent_card 不在 probe 里发请求, 但仍校验 scheme + host 防 create 时被指向内网。
	// ws/wss scheme 在 SSRF 校验前换成 https 走同款 host 检查。
	if p.ssrf != nil {
		if err := p.ssrf.Validate(ctx, base); err != nil {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.unreachable"
			res.ErrorMessage = fmt.Sprintf("服务地址不可达: 目标地址属于受限网段, 不允许探测 (%v)", err)
			return res, nil
		}
		for key, raw := range req.Endpoints {
			if key == "base" || strings.TrimSpace(raw) == "" {
				continue
			}
			// ws/wss → 仅做 host 检查, 不强制 scheme
			normalized := raw
			if strings.HasPrefix(strings.ToLower(raw), "wss://") {
				normalized = "https://" + raw[len("wss://"):]
			} else if strings.HasPrefix(strings.ToLower(raw), "ws://") {
				normalized = "http://" + raw[len("ws://"):]
			}
			if err := p.ssrf.Validate(ctx, normalized); err != nil {
				res.OK = false
				res.LatencyMs = elapsedMs(start, p.now())
				res.ErrorCode = "runtime.unreachable"
				res.ErrorMessage = fmt.Sprintf("服务地址 (%s) 不可达: 目标地址属于受限网段, 不允许探测 (%v)", key, err)
				return res, nil
			}
		}
	}
	if req.Auth.Kind != "" && req.Auth.Kind != "bearer" {
		return nil, errors.New("probe: only bearer auth supported")
	}
	timeout := time.Duration(req.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	if timeout > 30*time.Second {
		timeout = 30 * time.Second
	}
	expectMulti := req.ExpectMultiAgent

	// 2. GET /zap/v1/runtime_card
	cardCtx, cardCancel := context.WithTimeout(ctx, timeout)
	defer cardCancel()
	var accountID *int64
	if callerAccountID > 0 {
		accountID = &callerAccountID
	}
	meta := &zapadapter.CallMetadata{
		TenantID:  callerTenantID,
		AccountID: accountID,
	}
	cardResp, cardErr := p.httpGetLogged(cardCtx, base+"/zap/v1/runtime_card", "/zap/v1/runtime_card", req.Auth.Secret, meta)
	if cardErr != nil {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.unreachable"
		res.ErrorMessage = cardErr.Error()
		return res, nil
	}
	defer cardResp.Body.Close()

	// 2a. RuntimeCard missing (404 / 405): 走宽松过渡分支 (§8 兼容矩阵)。
	if cardResp.StatusCode == http.StatusNotFound || cardResp.StatusCode == http.StatusMethodNotAllowed {
		if expectMulti != nil && *expectMulti {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.runtime_card_missing"
			res.ErrorMessage = "expected multi-agent but runtime does not expose /zap/v1/runtime_card"
			return res, nil
		}
		// 允许保存为 single-agent legacy; protocol_version=zap-1.0-legacy。
		// 不签 probe_token, 留给 create 阶段用户手填 default_agent_key 后再签 (本轮跳过下游)。
		// 这里仍返 ok=true 以便上层进入"single-agent fallback" UI 路径; 但 RuntimeCard 留空。
		res.OK = true
		res.LatencyMs = elapsedMs(start, p.now())
		res.ProtocolVersion = "zap-1.0-legacy"
		res.FrameworkDetected = req.Framework
		res.Warnings = append(res.Warnings, "runtime_card_missing: legacy single-agent fallback only")
		// missing_required_endpoints 仅记录信息, 不阻断。
		res.MissingRequiredEndpoints = []string{"/zap/v1/runtime_card"}
		// 签发 probe_token (单 Agent legacy 也允许 create)
		if p.token != nil {
			tok, err := p.token.Issue(ProbeTokenClaims{
				CallerAccountID:    callerAccountID,
				CallerTenantID:     callerTenantID,
				EndpointsSHA256:    EndpointsSHA256(req.Endpoints),
				AuthConfigSHA256:   AuthConfigSHA256(req.Auth.Kind, req.Auth.SecretRef),
				Scope:              req.Scope,
				ProtocolVersion:    res.ProtocolVersion,
				RuntimeCardSummary: "",
			})
			if err == nil {
				res.ProbeToken = tok
			}
		}
		return res, nil
	}
	if cardResp.StatusCode == http.StatusUnauthorized || cardResp.StatusCode == http.StatusForbidden {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.auth_failed"
		res.ErrorMessage = fmt.Sprintf("runtime_card auth status=%d", cardResp.StatusCode)
		return res, nil
	}
	if cardResp.StatusCode != http.StatusOK {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.unreachable"
		res.ErrorMessage = fmt.Sprintf("runtime_card status=%d", cardResp.StatusCode)
		return res, nil
	}

	bodyBytes, rerr := io.ReadAll(io.LimitReader(cardResp.Body, 1<<20))
	if rerr != nil {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.runtime_card_invalid"
		res.ErrorMessage = rerr.Error()
		return res, nil
	}
	var card RuntimeCard
	if err := json.Unmarshal(bodyBytes, &card); err != nil {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.runtime_card_invalid"
		res.ErrorMessage = err.Error()
		return res, nil
	}

	// 3. RuntimeCard 校验 (ZAP v1.1 §1.3)。
	if card.ProtocolVersion != "zap-1.1" && card.ProtocolVersion != "zap-1.0" {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.protocol_version_unsupported"
		res.ErrorMessage = fmt.Sprintf("protocol_version=%q not supported", card.ProtocolVersion)
		return res, nil
	}
	if _, ok := allowedFrameworks[card.Framework]; !ok || (req.Framework != "" && req.Framework != "custom" && req.Framework != card.Framework && !(req.Framework == "dsh" && card.Framework == "zap")) {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.framework_mismatch"
		res.ErrorMessage = fmt.Sprintf("user framework=%q vs runtime_card framework=%q", req.Framework, card.Framework)
		return res, nil
	}
	if !card.SupportsMultiAgent {
		if strings.TrimSpace(card.DefaultAgentKey) == "" {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.runtime_card_invalid"
			res.ErrorMessage = "single-agent runtime must declare default_agent_key"
			return res, nil
		}
		if card.MaxAgents != 0 && card.MaxAgents != 1 {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.runtime_card_invalid"
			res.ErrorMessage = "single-agent runtime must have max_agents=1"
			return res, nil
		}
	} else {
		am := card.AgentManagement
		if !(am.SupportsCreate && am.SupportsUpdate && am.SupportsDelete && am.SupportsList) {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.agent_management_missing"
			res.ErrorMessage = "multi-agent runtime must implement all four agent_management endpoints"
			return res, nil
		}
	}
	// runtime_ui_components 至少包含 markdown + error (与 v1.0 §4.2 一致)。
	{
		hasMarkdown, hasError := false, false
		for _, c := range card.RuntimeUIComponents {
			switch c {
			case "markdown":
				hasMarkdown = true
			case "error":
				hasError = true
			}
		}
		if !hasMarkdown || !hasError {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.runtime_card_invalid"
			res.ErrorMessage = "runtime_ui_components must include 'markdown' and 'error'"
			return res, nil
		}
	}
	if expectMulti != nil && *expectMulti != card.SupportsMultiAgent {
		res.OK = false
		res.LatencyMs = elapsedMs(start, p.now())
		res.ErrorCode = "runtime.expectation_mismatch"
		res.ErrorMessage = fmt.Sprintf("expect_multi_agent=%v but runtime_card supports_multi_agent=%v", *expectMulti, card.SupportsMultiAgent)
		return res, nil
	}

	// 4. multi-agent 探测 GET /zap/v1/agents (M3 §6.4)。
	if card.SupportsMultiAgent {
		agCtx, agCancel := context.WithTimeout(ctx, timeout)
		agResp, agErr := p.httpGetLogged(agCtx, base+"/zap/v1/agents", "/zap/v1/agents", req.Auth.Secret, meta)
		agCancel()
		if agErr != nil {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.agent_management_missing"
			res.ErrorMessage = "GET /zap/v1/agents failed: " + agErr.Error()
			return res, nil
		}
		_ = agResp.Body.Close()
		if agResp.StatusCode != http.StatusOK {
			res.OK = false
			res.LatencyMs = elapsedMs(start, p.now())
			res.ErrorCode = "runtime.agent_management_missing"
			res.ErrorMessage = fmt.Sprintf("GET /zap/v1/agents status=%d", agResp.StatusCode)
			return res, nil
		}
	}

	// 5. ADR-0025 §2.8a · tenant external multi_tenant_isolation 三档 (warning 档):
	//    runtime probe 这条路径目前只服务 tenant external (platform external 走 runtimehosting
	//    自己的 fetchRuntimeCardForExternal, 在那里强校验)。所以这里 warning 档即可: 缺失或 false
	//    时往 res.Warnings 追一条, 不阻塞保存; 前端用黄色 chip 提示。
	//    若未来同一条 probe 服务 platform 强校验, 可由 caller 在 ProbeRequest 加 hosting_kind
	//    上下文 + scope 二选一升级。
	if !card.MultiTenantIsolation {
		res.Warnings = append(res.Warnings,
			"multi_tenant_isolation: runtime 未声明或为 false; 多账户共用此 runtime 时请确认隔离实现")
	}

	// 6. 成功; 签 probe_token。
	res.OK = true
	res.LatencyMs = elapsedMs(start, p.now())
	res.ProtocolVersion = card.ProtocolVersion
	res.FrameworkDetected = card.Framework
	res.RuntimeCard = &card

	if p.token != nil {
		cardSum := sha256.Sum256(bodyBytes)
		tok, err := p.token.Issue(ProbeTokenClaims{
			CallerAccountID:    callerAccountID,
			CallerTenantID:     callerTenantID,
			EndpointsSHA256:    EndpointsSHA256(req.Endpoints),
			AuthConfigSHA256:   AuthConfigSHA256(req.Auth.Kind, req.Auth.SecretRef),
			Scope:              req.Scope,
			ProtocolVersion:    card.ProtocolVersion,
			RuntimeCardSummary: hex.EncodeToString(cardSum[:]),
		})
		if err == nil {
			res.ProbeToken = tok
		}
	}
	return res, nil
}

func (p *probeImpl) httpGet(ctx context.Context, url, bearer string) (*http.Response, error) {
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	r.Header.Set("Accept", "application/json")
	return p.doer.Do(r)
}

func (p *probeImpl) httpGetLogged(ctx context.Context, rawURL, path, bearer string, meta *zapadapter.CallMetadata) (*http.Response, error) {
	start := p.now()
	resp, err := p.httpGet(ctx, rawURL, bearer)
	if p.callLog == nil {
		return resp, err
	}
	latencyMS := int(elapsedMs(start, p.now()))
	if err != nil {
		p.callLog.WriteHTTPCall(ctx, meta, "zap", zapOperationForProbe(path), http.MethodGet, path, nil, nil, 0, latencyMS, err.Error(), nil)
		return resp, err
	}
	if resp == nil {
		p.callLog.WriteHTTPCall(ctx, meta, "zap", zapOperationForProbe(path), http.MethodGet, path, nil, nil, 0, latencyMS, "empty response", nil)
		return resp, err
	}
	raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	_ = resp.Body.Close()
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	errMsg := ""
	if readErr != nil {
		errMsg = readErr.Error()
	}
	p.callLog.WriteHTTPCall(ctx, meta, "zap", zapOperationForProbe(path), http.MethodGet, path, nil, raw, resp.StatusCode, latencyMS, errMsg, nil)
	return resp, err
}

func zapOperationForProbe(path string) string {
	switch path {
	case "/zap/v1/runtime_card":
		return "zap.runtime_card"
	case "/zap/v1/agents":
		return "zap.agent_collection"
	default:
		return "zap.http"
	}
}

func elapsedMs(start, end time.Time) int64 {
	return end.Sub(start).Milliseconds()
}
