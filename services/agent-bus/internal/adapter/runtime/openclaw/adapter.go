// Package openclaw 是 OpenClaw Runtime 的 Bus 适配器。
//
// ⚠️ DEPRECATED (Batch 2C 2026-05-15 提示, Batch 2D 2026-05-16 chat 路径完全切走):
//
// 本文件 (adapter.go) + Legacy* resolver/workload (resolver_local.go /
// resolver_k8s.go / workload_stub.go) 实现的是 OpenClaw Gateway 的
// `POST /v1/responses` (HTTP+SSE) 兼容层。该兼容层已在 OpenClaw 上游下线 ——
// legacy ai-office 实际生产跑通的是 Gateway v3 原生 WebSocket 协议
// (chat.send / sessions.* + lifecycle/tool 事件)。
//
// Batch 2C 起新增 `internal/adapter/runtime/openclaw/gatewayws/` 走 v3 WS。
//
// **Batch 2D (T2D.1) 收口**: chat 服务 (`internal/service/chat`) 不再经
// `runtime.Manager` 间接调用本 Adapter, 而是直接构造 `gatewayws.Client` +
// `InstanceResolver` 走 v3 WS chat.send。chat 路径任何调用栈如再次落到本
// `*Adapter` 上, 即视为 bug, 测试需覆盖。
//
// 这些 Legacy* 类型保留仅为:
//   - rollback 兜底 (Batch 2F 物理清理前): 若 v3 WS 出现致命退化, 可临时把
//     `cmd/bus/main.go` 的 chat 注入回退到 Manager → adapter.go 路径
//   - K8s pod 拉起 (workload_stub.go) 在 K8s 真实接通前的预留
//
// 不再扩展功能, 不再被 chat 路径调用, 不允许从 chat 服务以任何形式 fallback
// 到本 adapter; 新功能一律走 gatewayws + 新的 InstanceResolver
// (按 runtime_registration_id 解析).
//
// 物理删除计划: Batch 2F (`T-FOLLOWUP-OPENRESPONSES-PURGE`)。
package openclaw

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/httpcli"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// LegacyInstanceResolver 是 OpenResponses HTTP+SSE 适配器 (DEPRECATED) 的实例解析抽象。
//
// ⚠️ 仅供 adapter.go (DEPRECATED) 用; 新代码请用顶层 `InstanceResolver`
// (按 runtime_registration_id 解析, 见 resolver.go)。
//
// local 模式实现固定返回配置里的 URL; k8s 模式实现按 (accountID, tenantID)
// 找 / 创建 runtime_instances 记录并返回 Pod 入口。
type LegacyInstanceResolver interface {
	// Resolve 返回 (endpoint URL, bearer token, error)。
	// endpoint 形如 "http://127.0.0.1:18789" —— 不含具体 path。
	Resolve(ctx context.Context, tenantID, accountID int64) (endpoint string, bearer string, err error)
}

// Adapter 实现 runtime.Adapter (HTTP+SSE 模式, DEPRECATED)。
type Adapter struct {
	logger   *log.Logger
	resolver LegacyInstanceResolver
	client   *http.Client
}

// New 构造 OpenClaw adapter (DEPRECATED, Batch 2D 删)。
func New(logger *log.Logger, resolver LegacyInstanceResolver) *Adapter {
	return &Adapter{
		logger:   logger,
		resolver: resolver,
		client:   httpcli.New(10 * time.Minute),
	}
}

func (a *Adapter) Name() string { return "openclaw" }

func (a *Adapter) HealthCheck(ctx context.Context) error {
	if a.resolver == nil {
		return errors.New("no resolver")
	}
	// 用一个零值身份去尝试解析；local 模式直接通；k8s 模式可能没数据，此时返回 nil
	_, _, err := a.resolver.Resolve(ctx, 0, 0)
	if err != nil && !strings.Contains(err.Error(), "no identity") {
		return err
	}
	return nil
}

// responsesRequest 是 OpenClaw /v1/responses 的请求体（精简版）。
type responsesRequest struct {
	Model  string        `json:"model"`
	Input  []interface{} `json:"input"`
	Stream bool          `json:"stream"`
	User   string        `json:"user,omitempty"`
}

// Stream 启动一条对话流。
func (a *Adapter) Stream(ctx context.Context, req runtime.StreamRequest) (runtime.Stream, error) {
	endpoint, bearer, err := a.resolver.Resolve(ctx, req.TenantID, req.AccountID)
	if err != nil {
		return nil, fmt.Errorf("resolve openclaw instance: %w", err)
	}
	if endpoint == "" {
		return nil, errors.New("openclaw instance not ready")
	}

	model := "openclaw/" + req.AgentUUID
	if req.ModelHint != "" && strings.Contains(req.ModelHint, "/") {
		model = req.ModelHint
	}

	// 转 OpenResponses 输入条目数组：历史 + 当前 user。
	input := make([]interface{}, 0, len(req.History)+1)
	for _, h := range req.History {
		role := normalizeRole(h.Role)
		if role == "" || h.Text == "" {
			continue
		}
		input = append(input, map[string]any{"role": role, "content": h.Text})
	}
	if req.UserMessage != "" {
		input = append(input, map[string]any{"role": "user", "content": req.UserMessage})
	}

	body, _ := json.Marshal(responsesRequest{
		Model:  model,
		Input:  input,
		Stream: true,
		User:   fmt.Sprintf("conv-%d", req.ConversationID),
	})

	httpReq, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(endpoint, "/")+"/v1/responses", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	httpReq.Header.Set("User-Agent", "agent-bus/0.1 (openclaw)")
	if bearer != "" {
		httpReq.Header.Set("Authorization", "Bearer "+bearer)
	}

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("openclaw call: %w", err)
	}
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("openclaw %d: %s", resp.StatusCode, string(b))
	}
	return &stream{body: resp.Body, sc: bufio.NewScanner(resp.Body), buf: ""}, nil
}

// normalizeRole 把内部 role 映射成 OpenResponses 接受的 role。
func normalizeRole(r string) string {
	switch r {
	case "user", "system", "developer":
		return r
	case "agent", "assistant":
		return "assistant"
	default:
		return ""
	}
}

// stream 解析 OpenClaw SSE 流，转换成 runtime.StreamEvent。
//
// OpenClaw 事件类型示例（精简，详见文档）：
//   - response.output_text.delta   { "delta": "..." }
//   - response.output_text.done    { "text": "..." }
//   - response.completed           {}
//   - response.error               { "error": {...} }
//
// 我们把 delta 累计后推 runtime.StreamEvent{Kind:"delta", Text: 累计文本}；
// 收到 completed 时推 final（携带 markdown block）。
type stream struct {
	body      io.ReadCloser
	sc        *bufio.Scanner
	buf       string
	done      bool
	bufferSet bool
}

func init() {
	// scanner 默认 64KB 太小，大 SSE 帧会失败 —— 改成 1 MB。
	// 这里没办法在 init 里改 stream 的实例配置，所以下面 Recv 用更大的 buffer。
}

type sseEnvelope struct {
	Delta    string `json:"delta"`
	Text     string `json:"text"`
	Output   any    `json:"output"`
	Response struct {
		OutputText string `json:"output_text"`
	} `json:"response"`
	Error struct {
		Message string `json:"message"`
		Code    string `json:"code"`
	} `json:"error"`
}

func (s *stream) Recv() (runtime.StreamEvent, error) {
	// 增大 scanner buffer
	if !s.bufferSet {
		s.sc.Buffer(make([]byte, 0, 64*1024), 1*1024*1024)
		s.bufferSet = true
	}
	var lastEvent string
	for s.sc.Scan() {
		line := strings.TrimSpace(s.sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "event:") {
			lastEvent = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		raw := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if raw == "" || raw == "[DONE]" {
			s.done = true
			return runtime.StreamEvent{
				Kind:   "final",
				Blocks: s.finalBlocks(),
				Final:  true,
			}, nil
		}
		var env sseEnvelope
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			// 非法帧不致命，继续
			continue
		}
		switch lastEvent {
		case "response.output_text.delta":
			if env.Delta != "" {
				s.buf += env.Delta
			}
			return runtime.StreamEvent{Kind: "delta", Text: s.buf}, nil
		case "response.output_text.done":
			if env.Text != "" {
				s.buf = env.Text
			}
			return runtime.StreamEvent{Kind: "delta", Text: s.buf}, nil
		case "response.completed":
			return runtime.StreamEvent{Kind: "final", Blocks: s.finalBlocks(), Final: true}, nil
		case "response.error":
			return runtime.StreamEvent{Kind: "error", Err: fmt.Errorf("%s: %s", env.Error.Code, env.Error.Message)}, nil
		default:
			// 其它事件（reasoning / tool_call / 等）暂不转译，继续读
			continue
		}
	}
	if err := s.sc.Err(); err != nil {
		return runtime.StreamEvent{}, err
	}
	if !s.done {
		s.done = true
		return runtime.StreamEvent{Kind: "final", Blocks: s.finalBlocks(), Final: true}, nil
	}
	return runtime.StreamEvent{}, nil
}

func (s *stream) finalBlocks() []map[string]any {
	if s.buf == "" {
		return []map[string]any{}
	}
	return []map[string]any{{"type": "markdown", "text": s.buf}}
}

func (s *stream) Close() error { return s.body.Close() }
