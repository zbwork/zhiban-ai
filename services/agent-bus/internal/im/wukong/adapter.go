package wukong

import (
	"context"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im"
)

// Adapter 是 WuKongIM 对 im.Substrate 的实现(ADR-0026)。
//
// 装配:apiAddr=WuKong 特权 REST(仅 agent-bus);tcpAddr/wsAddr=下发给客户端的长连接地址。
type Adapter struct {
	client  *Client
	tcpAddr string
	wsAddr  string
}

// NewAdapter 构造 WuKong substrate adapter。
func NewAdapter(apiAddr, tcpAddr, wsAddr string, hc *http.Client) *Adapter {
	return &Adapter{
		client:  NewClient(apiAddr, hc),
		tcpAddr: tcpAddr,
		wsAddr:  wsAddr,
	}
}

func (a *Adapter) Name() string { return "wukong" }

func (a *Adapter) RegisterUserToken(ctx context.Context, uid, token string, deviceFlag, deviceLevel int) error {
	return a.client.RegisterUserToken(ctx, uid, token, deviceFlag, deviceLevel)
}

func (a *Adapter) EnsureChannel(ctx context.Context, channelID string, channelType int, subscribers []string) error {
	return a.client.AddSubscribers(ctx, channelID, channelType, subscribers)
}

func (a *Adapter) ClientConnAddrs() (string, string) { return a.tcpAddr, a.wsAddr }

// Client 暴露底层 REST client,供 Phase 2(Agent 代发 / 历史代理)使用。
func (a *Adapter) Client() *Client { return a.client }

// 编译期断言:Adapter 满足 im.Substrate。
var _ im.Substrate = (*Adapter)(nil)
