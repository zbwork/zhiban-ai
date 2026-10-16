// Package im 是 IM substrate 的后端抽象(ADR-0026)。
//
// 目的:让 agent-bus 业务层(im credentials / direct-rooms / webhook)与 WuKongIM substrate
// 解耦,业务 UI / 调用方不绑死具体 REST 实现细节。
package im

import "context"

// ConnInfo 是下发给客户端用于建立 IM 长连接的信息(经 POST /api/agent-bus/v1/im/credentials)。
//
// 安全(ADR-0026):**绝不包含任何特权 REST 地址**(WuKong :5001 不下发给客户端)。
// 客户端只用 TCPAddr / WSAddr 长连接收发时间线。
type ConnInfo struct {
	Substrate string `json:"substrate"` // "wukong"
	UID       string `json:"uid"`
	Token     string `json:"token"`
	TCPAddr   string `json:"tcp_addr,omitempty"`
	WSAddr    string `json:"ws_addr,omitempty"`
	// DeviceFlag 必须与服务端 RegisterUserToken 使用的 WuKong 设备类别一致：
	// 0=App, 1=Web, 2=Desktop。客户端不得自行猜测或覆盖。
	DeviceFlag int `json:"device_flag"`
	// DeviceID 由已鉴权凭证接口回显，客户端必须原样用于 CONNECT。
	// 该值不进入 IM 监控表；采集和元数据表只保存 SHA-256。
	DeviceID string `json:"device_id,omitempty"`

	// ExpiresAt 是本次连接凭证的建议刷新时刻(RFC3339, UTC)。
	// = 签发时刻 + 配置 TTL(默认 24h)。客户端据此提前刷新 token、统一连接状态机;
	// 即便底层 token 长期有效,也回一个刷新建议时间。空 = 未知(客户端不强制刷新)。
	ExpiresAt string `json:"expires_at,omitempty"`
}

// Substrate 是后端对 IM 引擎的最小操作集(Phase 1:身份/连接/channel)。
//
// 注意:这些方法只在 agent-bus 服务端调用(走 substrate 特权 API);客户端不直接调。
type Substrate interface {
	// Name 返回 substrate 标识("wukong")。
	Name() string

	// RegisterUserToken 注册/更新某 uid 的客户端连接 token(幂等)。
	// 客户端随后用 (uid, token) 建立长连接。token 由 agent-bus 生成并下发。
	RegisterUserToken(ctx context.Context, uid, token string, deviceFlag, deviceLevel int) error

	// EnsureChannel 确保 channel 存在并包含给定订阅者(幂等)。
	// channelType 由 substrate 定义(WuKong: 1=person, 2=group)。
	EnsureChannel(ctx context.Context, channelID string, channelType int, subscribers []string) error

	// ClientConnAddrs 返回下发给客户端的长连接地址(TCP, WS)。
	ClientConnAddrs() (tcpAddr, wsAddr string)
}
