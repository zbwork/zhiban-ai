package a2a

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
)

// ComputeIdemKey F09 §3.5 step 5 + §14 D18 (legacy helper):
//
//	idem_key = sha256(parent_edge_id || ':' || step_index || ':' || from_agent_id || ':' || to_agent_id)
//
// parent_edge_id 缺省 ("") 表示 root 调用; step_index 0 是合法默认.
//
// 长度限制: a2a_call_edges.idem_key VARCHAR(64), 这里返 hex 64 char.
//
// 新调用路径应优先使用 ComputeScopedIdemKey, 把同一 tool_call 的 idempotency_key
// 或 request_fingerprint 纳入作用域, 避免不同用户消息复用旧 edge。
func ComputeIdemKey(parentEdgeID *int64, stepIndex int, fromAgentID, toAgentID int64) string {
	return computeIdemKey(parentEdgeID, stepIndex, fromAgentID, toAgentID, "")
}

// ComputeScopedIdemKey 生成 A2A invoke 幂等键。
//
// scope 必须是调用作用域:推荐 "client:<tool_call_id>"；未传客户端 key 时由 service 使用
// "fp:<request_fingerprint>" 兜底。这样:
//   - 同一 tool_call 网络重试仍返回同一 edge;
//   - 不同用户输入 / 不同 payload 不会仅因 parent+step+from+to 相同而复用旧 edge。
func ComputeScopedIdemKey(parentEdgeID *int64, stepIndex int, fromAgentID, toAgentID int64, scope string) string {
	return computeIdemKey(parentEdgeID, stepIndex, fromAgentID, toAgentID, strings.TrimSpace(scope))
}

func computeIdemKey(parentEdgeID *int64, stepIndex int, fromAgentID, toAgentID int64, scope string) string {
	parent := ""
	if parentEdgeID != nil {
		parent = strconv.FormatInt(*parentEdgeID, 10)
	}
	var b strings.Builder
	b.WriteString(parent)
	b.WriteByte(':')
	b.WriteString(strconv.FormatInt(int64(stepIndex), 10))
	b.WriteByte(':')
	b.WriteString(strconv.FormatInt(fromAgentID, 10))
	b.WriteByte(':')
	b.WriteString(strconv.FormatInt(toAgentID, 10))
	if scope != "" {
		b.WriteByte(':')
		b.WriteString(scope)
	}
	h := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(h[:])
}

// ComputeRequestFingerprint (Phase5 §12.4.1) 规范化调用指纹, 供「不同轮次重复调用」治理:
//
//	request_fingerprint = sha256(tenant_id : from_agent_id : to_agent_id : invoke_kind : sha256(canonical(payload)))
//
// payload 用脱敏后 request payload (已 ≤16KB)。canonical = 键序稳定的紧凑 JSON:
// 仅键序 / 空白不同的两次调用得到同一指纹。与 idem_key (仅 parent:step:from:to,
// 管「同一 tool call 重试」幂等) 正交: 指纹管「内容相同的不同轮次」。返 hex 64 char。
func ComputeRequestFingerprint(tenantID, fromAgentID, toAgentID int64, invokeKind string, payload []byte) string {
	var b strings.Builder
	b.WriteString(strconv.FormatInt(tenantID, 10))
	b.WriteByte(':')
	b.WriteString(strconv.FormatInt(fromAgentID, 10))
	b.WriteByte(':')
	b.WriteString(strconv.FormatInt(toAgentID, 10))
	b.WriteByte(':')
	b.WriteString(invokeKind)
	b.WriteByte(':')
	b.WriteString(canonicalPayloadHash(payload))
	h := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(h[:])
}

// canonicalPayloadHash 对 payload 做键序稳定的规范化后哈希。encoding/json 对 map 键
// 按字典序输出, 故 unmarshal→marshal 即得 canonical 形态 (键序 / 空白无关)。非法 JSON
// 退化为对原始字节直接哈希 (仍稳定)。
func canonicalPayloadHash(payload []byte) string {
	if len(payload) == 0 {
		payload = []byte("{}")
	}
	var v any
	if err := json.Unmarshal(payload, &v); err == nil {
		if canon, cerr := json.Marshal(v); cerr == nil {
			h := sha256.Sum256(canon)
			return hex.EncodeToString(h[:])
		}
	}
	h := sha256.Sum256(payload)
	return hex.EncodeToString(h[:])
}
