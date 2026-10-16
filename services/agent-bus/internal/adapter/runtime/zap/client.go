// Package zap 是 ZAP / 自定义平台 runtime 的 control-plane agent 管理 HTTP 客户端 (doc-12 §3.1, S5/Task D)。
//
// 与 OpenClaw 不同: ZAP runtime **自管 workspace / 人格化**, agent 同步是**纯 HTTP**(无 exec、无 workspace
// 文件落地)。协议路径 `/zap/v1/agents*`(ADR-0025; 与 apps/example/agent-example 对齐, 见 docs ZAP 协议页)。
//
// ai-office 无 ZAP agent 管理实现可参考 (其 agent 生命周期全走 OpenClaw CLI/exec); 本协议据 ADR-0025 + example 设计。
//
// 安全: bearer token 仅设 Authorization 头, **绝不进入错误/日志字符串** (doc-12 §9)。
package zap

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DefaultTimeout 单次 ZAP runtime 调用超时。
const DefaultTimeout = 15 * time.Second

// Client 针对单个 ZAP runtime (baseURL + bearer 已绑定) 的 agent 管理客户端。
type Client struct {
	baseURL  string // runtime 根地址 (= primary_endpoint); 内部拼 /zap/v1/agents
	token    string // runtime 访问凭证; 仅设头, 不入日志
	httpc    *http.Client
	callLog  *CallLogWriter // F19: nil = no call logging
	callMeta *CallMetadata  // F19: tenant/account context
}

// Option 调整构造。
type Option func(*Client)

// WithHTTPClient 注入自定义 http.Client (单测指向 httptest server)。
func WithHTTPClient(h *http.Client) Option {
	return func(c *Client) {
		if h != nil {
			c.httpc = h
		}
	}
}

// WithCallLog F19: 启用 runtime 调用日志 (control-plane)。
func WithCallLog(w *CallLogWriter, meta *CallMetadata) Option {
	return func(c *Client) {
		c.callLog = w
		c.callMeta = meta
	}
}

// NewClient 构造绑定到单 runtime 的客户端。
func NewClient(baseURL, token string, opts ...Option) *Client {
	c := &Client{
		baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		token:   token,
		httpc:   &http.Client{Timeout: DefaultTimeout},
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// ---- 请求/响应类型 (ZAP /zap/v1/agents 协议; 与 example agent 对齐) ----

type AgentModelConfig struct {
	Primary   string   `json:"primary,omitempty"`
	Fallbacks []string `json:"fallbacks,omitempty"`
}

type AgentToolsConfig struct {
	Allow []string `json:"allow,omitempty"`
	Deny  []string `json:"deny,omitempty"`
}

// CreateAgentRequest: canonical 字段 `agent_key` (唯一; 与 example agent / admin 协议页一致, doc-12 §13)。
// 项目未上线, 不保留 agentId 兼容 alias。
type CreateAgentRequest struct {
	AgentKey string            `json:"agent_key"`
	Name     string            `json:"name,omitempty"`
	Model    *AgentModelConfig `json:"model,omitempty"`
	Tools    *AgentToolsConfig `json:"tools,omitempty"`
	// SystemPrompt ZAP-1.1 §2.1 `system_prompt` (数字员工人设); 空 = 不发 (runtime 自带默认)。
	SystemPrompt string `json:"system_prompt,omitempty"`
	// Metadata ZAP §2.1 不透明扩展位 (ADR-0037 dsh 消费端: model_service 三元组, 无密钥); nil = 不发。
	Metadata map[string]any `json:"metadata,omitempty"`
}

type CreateAgentResponse struct {
	Ok       bool   `json:"ok"`
	AgentKey string `json:"agent_key"`
	Message  string `json:"message"`
}

// Key 返回 canonical agent_key (无 agentId 兜底; 缺失 → "")。
func (r *CreateAgentResponse) Key() string {
	if r == nil {
		return ""
	}
	return r.AgentKey
}

type AgentInfo struct {
	AgentKey string            `json:"agent_key"`
	Name     string            `json:"name"`
	Model    *AgentModelConfig `json:"model,omitempty"`
	Tools    *AgentToolsConfig `json:"tools,omitempty"`
}

type GetAgentResponse struct {
	Ok    bool       `json:"ok"`
	Agent *AgentInfo `json:"agent"`
}

type ListAgentsRequest struct {
	Page     int
	PageSize int
}

type ListAgentsResponse struct {
	Ok     bool        `json:"ok"`
	Agents []AgentInfo `json:"agents"`
	Total  int         `json:"total"`
}

type UpdateAgentRequest struct {
	Name  string            `json:"name,omitempty"`
	Model *AgentModelConfig `json:"model,omitempty"`
	Tools *AgentToolsConfig `json:"tools,omitempty"`
	// SystemPrompt 同 CreateAgentRequest; 空 = 不改远端人设 (PATCH 语义)。
	SystemPrompt string `json:"system_prompt,omitempty"`
	// Metadata 同 CreateAgentRequest; nil = 不改远端 metadata。
	Metadata map[string]any `json:"metadata,omitempty"`
}

type UpdateAgentResponse struct {
	Ok       bool   `json:"ok"`
	AgentKey string `json:"agent_key"`
	Message  string `json:"message"`
}

func (r *UpdateAgentResponse) Key() string {
	if r == nil {
		return ""
	}
	return r.AgentKey
}

type DeleteAgentResponse struct {
	Ok       bool   `json:"ok"`
	AgentKey string `json:"agent_key"`
	Message  string `json:"message"`
}

type zapErrorResponse struct {
	Ok    bool `json:"ok"`
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// APIError ZAP runtime 调用的归一化错误 (不含 token)。
type APIError struct {
	StatusCode int
	Code       string
	Message    string
}

func (e *APIError) Error() string {
	if e == nil {
		return ""
	}
	if e.Code != "" {
		return fmt.Sprintf("zap http %d [%s]: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("zap http %d: %s", e.StatusCode, e.Message)
}

func (e *APIError) IsConflict() bool {
	if e == nil {
		return false
	}
	if e.StatusCode == http.StatusConflict {
		return true
	}
	low := strings.ToLower(e.Code + " " + e.Message)
	return strings.Contains(low, "already exists") || strings.Contains(low, "already_exists") || strings.Contains(low, "exists")
}

func (e *APIError) IsNotFound() bool {
	if e == nil {
		return false
	}
	if e.StatusCode == http.StatusNotFound {
		return true
	}
	low := strings.ToLower(e.Code + " " + e.Message)
	return strings.Contains(low, "not found") || strings.Contains(low, "not_found") || strings.Contains(low, "does not exist")
}

// IsRetryable: 网络层 (StatusCode==0) 或 5xx → 可重试; 4xx 终态。
func (e *APIError) IsRetryable() bool {
	if e == nil {
		return false
	}
	return e.StatusCode == 0 || e.StatusCode >= 500
}

func (c *Client) CreateAgent(ctx context.Context, req *CreateAgentRequest) (*CreateAgentResponse, error) {
	var out CreateAgentResponse
	if err := c.do(ctx, http.MethodPost, "/zap/v1/agents", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) GetAgent(ctx context.Context, agentID string) (*GetAgentResponse, error) {
	var out GetAgentResponse
	if err := c.do(ctx, http.MethodGet, "/zap/v1/agents/"+url.PathEscape(agentID)+"/card", nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) ListAgents(ctx context.Context, req *ListAgentsRequest) (*ListAgentsResponse, error) {
	path := "/zap/v1/agents"
	if req != nil {
		q := url.Values{}
		if req.Page > 0 {
			q.Set("page", strconv.Itoa(req.Page))
		}
		if req.PageSize > 0 {
			q.Set("pageSize", strconv.Itoa(req.PageSize))
		}
		if enc := q.Encode(); enc != "" {
			path += "?" + enc
		}
	}
	var out ListAgentsResponse
	if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) UpdateAgent(ctx context.Context, agentID string, req *UpdateAgentRequest) (*UpdateAgentResponse, error) {
	var out UpdateAgentResponse
	if err := c.do(ctx, http.MethodPatch, "/zap/v1/agents/"+url.PathEscape(agentID), req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) DeleteAgent(ctx context.Context, agentID string) (*DeleteAgentResponse, error) {
	var out DeleteAgentResponse
	if err := c.do(ctx, http.MethodDelete, "/zap/v1/agents/"+url.PathEscape(agentID), nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// UpsertTenant 幂等同步租户资料到 ZAP runtime。
func (c *Client) UpsertTenant(ctx context.Context, tenantID string, req *IdentityTenantUpsertRequest) (*IdentityTenantUpsertResponse, error) {
	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return nil, &APIError{StatusCode: 0, Message: "UpsertTenant: empty tenant_id"}
	}
	var out IdentityTenantUpsertResponse
	if err := c.do(ctx, http.MethodPut, "/zap/v1/tenants/"+url.PathEscape(tenantID), req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// do 执行请求并解码; 非 2xx → *APIError (不含 token)。
func (c *Client) do(ctx context.Context, method, path string, body any, out any) error {
	start := time.Now()
	operation := zapOperation(path)
	ctx, span := startRuntimeHTTPSpan(ctx, "zap", operation, method, path)
	statusForSpan := 0
	errForSpan := ""
	defer func() { finishRuntimeHTTPSpan(span, statusForSpan, errForSpan) }()
	var reqBodyBytes []byte
	var reqBody io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return &APIError{StatusCode: 0, Message: "marshal request: " + err.Error()}
		}
		reqBodyBytes = buf
		reqBody = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, reqBody)
	if err != nil {
		return &APIError{StatusCode: 0, Message: "build request " + method + " " + path}
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.httpc.Do(req)
	if err != nil {
		errForSpan = "transport error"
		c.logCtrlCall(ctx, operation, method, path, reqBodyBytes, nil, 0, start, errForSpan)
		return &APIError{StatusCode: 0, Message: "transport error"}
	}
	statusForSpan = resp.StatusCode
	defer resp.Body.Close()
	raw, readCode := readJSONResponse(resp)
	if readCode != "" {
		errForSpan = readCode
		c.logCtrlCall(ctx, operation, method, path, reqBodyBytes, nil, resp.StatusCode, start, errForSpan)
		return &APIError{StatusCode: resp.StatusCode, Code: readCode, Message: readCode}
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		apiErr := &APIError{StatusCode: resp.StatusCode, Message: truncate(string(raw), 200)}
		var er zapErrorResponse
		if json.Unmarshal(raw, &er) == nil && er.Error.Code != "" {
			apiErr.Code = er.Error.Code
			apiErr.Message = er.Error.Message
		}
		errForSpan = apiErr.Message
		c.logCtrlCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, errForSpan)
		return apiErr
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			errForSpan = "decode response"
			c.logCtrlCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, errForSpan)
			return &APIError{StatusCode: resp.StatusCode, Message: "decode response: " + err.Error()}
		}
	}
	c.logCtrlCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, "")
	return nil
}

func (c *Client) logCtrlCall(ctx context.Context, operation, method, path string, reqBody, respBody []byte, status int, start time.Time, errMsg string) {
	if c.callLog == nil {
		return
	}
	c.callLog.writeCallLog(ctx, c.callMeta, "zap", operation, method, path, reqBody, respBody, status, int(time.Since(start).Milliseconds()), errMsg, nil)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
