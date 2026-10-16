// Package wukong 是 WuKongIM substrate 的 agent-bus 端实现(ADR-0026)。
package wukong

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// WuKong channel_type(WuKong 二进制协议 / ADR-0026)。
const (
	ChannelTypePerson = 1 // 1v1 私聊
	ChannelTypeGroup  = 2 // 群聊
)

// 租户命名空间映射(ADR-0026 §2.3)。
//
// 安全:WuKong :5001 不暴露给客户端(boundaries §1 不变量 5),故 channel_id 可读不构成
// 跨租户泄露面;`t_{tenant}_` 前缀用于 agent-bus 侧路由/校验,确保跨租户 id 不复用。
// 多租户隔离 100% 由 agent-bus(命名空间 + 鉴权 + 不外露 :5001)负责。

// UserUID: 普通员工 → t_{tenant_id}_u_{account_uuid}
func UserUID(tenantID int64, accountUUID string) string {
	return "t_" + strconv.FormatInt(tenantID, 10) + "_u_" + accountUUID
}

// AgentUID: 数字员工 → t_{tenant_id}_a_{agent_uuid}
func AgentUID(tenantID int64, agentUUID string) string {
	return "t_" + strconv.FormatInt(tenantID, 10) + "_a_" + agentUUID
}

// GroupChannelID: 群聊 → t_{tenant_id}_g_{room_uuid}(channel_type=2)
func GroupChannelID(tenantID int64, roomUUID string) string {
	return "t_" + strconv.FormatInt(tenantID, 10) + "_g_" + roomUUID
}

// DirectChannelID: 1v1 → t_{tenant_id}_d_{pair_hash}(channel_type=2 group)。
// WuKong 个人频道(type=1)隐式、不支持 subscriber_add,故 1v1 用共享 group 频道建模。
// pair_hash 用排序后两端 account_uuid 的短哈希,保证 (a,b) 与 (b,a) 同一 channel。
func DirectChannelID(tenantID int64, accountUUIDA, accountUUIDB string) string {
	a, b := accountUUIDA, accountUUIDB
	if a > b {
		a, b = b, a
	}
	sum := sha256.Sum256([]byte(a + ":" + b))
	return "t_" + strconv.FormatInt(tenantID, 10) + "_d_" + hex.EncodeToString(sum[:])[:16]
}

// AgentDirectChannelID: human↔数字员工 1v1 → t_{tenant_id}_d_{pair_hash}(channel_type=2 group)。
// 与 human-human 的 DirectChannelID **不冲突**:用 role-tagged 输入(`u:{account}|a:{agent}`)+ 固定顺序
// (human 在前、agent 在后)做哈希,即便 account_uuid 与 agent_uuid 撞码也派生不同 channel。
// 确定且幂等:同一 (tenant, account, agent) 永远同一 channel_id(ADR-0026 agent-direct 后端最小前置)。
func AgentDirectChannelID(tenantID int64, accountUUID, agentUUID string) string {
	sum := sha256.Sum256([]byte("u:" + accountUUID + "|a:" + agentUUID))
	return "t_" + strconv.FormatInt(tenantID, 10) + "_d_" + hex.EncodeToString(sum[:])[:16]
}

// ParseNamespacedID 解析 `t_{tenant_id}_{kind}_{rest}`。kind ∈ {u,a,g,d};rest = account/agent/room uuid 或 pair_hash。
// 解析失败 → ok=false(用于 webhook 识别 / 防回环纯逻辑)。
func ParseNamespacedID(id string) (tenantID int64, kind, rest string, ok bool) {
	if !strings.HasPrefix(id, "t_") {
		return 0, "", "", false
	}
	s := id[len("t_"):]
	i := strings.IndexByte(s, '_')
	if i <= 0 {
		return 0, "", "", false
	}
	t, err := strconv.ParseInt(s[:i], 10, 64)
	if err != nil {
		return 0, "", "", false
	}
	s = s[i+1:] // {kind}_{rest}
	j := strings.IndexByte(s, '_')
	if j <= 0 {
		return 0, "", "", false
	}
	kind = s[:j]
	rest = s[j+1:]
	if kind == "" || rest == "" {
		return 0, "", "", false
	}
	return t, kind, rest, true
}

// IsDirectChannel 判定 channelID 是否为 1v1 direct channel(kind=='d',含 human-human 与 human-agent)。
func IsDirectChannel(channelID string) bool {
	_, kind, _, ok := ParseNamespacedID(channelID)
	return ok && kind == "d"
}

// TenantIDFromNamespacedID 从命名空间 id(uid/channel_id)反解 tenant_id,用于跨租户校验。
// 解析失败返回 (-1, error)。
func TenantIDFromNamespacedID(id string) (int64, error) {
	if !strings.HasPrefix(id, "t_") {
		return -1, fmt.Errorf("wukong: id %q missing tenant namespace prefix", id)
	}
	rest := id[len("t_"):]
	i := strings.IndexByte(rest, '_')
	if i <= 0 {
		return -1, fmt.Errorf("wukong: id %q malformed namespace", id)
	}
	t, err := strconv.ParseInt(rest[:i], 10, 64)
	if err != nil {
		return -1, fmt.Errorf("wukong: id %q tenant segment not int: %w", id, err)
	}
	return t, nil
}
