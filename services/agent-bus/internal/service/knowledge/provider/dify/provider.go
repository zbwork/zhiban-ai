// Package dify · M8B Dify KBProvider 实现.
//
// 与 docs/tasks/agent-bus-admin-backend-completion-before-zhiban-app-cutover.md §A3 对齐.
//
// 关键约束:
//   - tenant_id 由 service 层强制注入 RetrieveReq.TenantID; provider 不接受外部 body 传入.
//   - Dify Retrieval 调用前**强制**注入 metadata filter:
//     tenant_id = ctx.tenant_id
//     business_kb_id IN (...)
//     scope IN ('tenant','user' if owner=caller)
//   - 生产 fail-closed: Dify 不可达 → 直接返 ErrProviderDegraded (业务层转 kb.provider_degraded);
//     stub fallback 仅在 AGBUS_KB_ALLOW_STUB_FALLBACK=1 时生效.
package dify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	provider "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
)

// Config · Dify provider 启动配置. ApiToken 由 Bus 启动期从 secret manager 解析.
type Config struct {
	EndpointURL      string
	APIToken         string
	WorkspaceID      string
	TenantDatasetID  string // 租户共享 dataset (scope='tenant')
	UserDatasetID    string // 用户私 dataset (scope='user')
	DefaultTopK      int
	DefaultThreshold float64
	UseRerank        bool
	HTTPClient       *http.Client
}

// Provider · Dify HTTP KBProvider.
type Provider struct {
	cfg Config
}

// ErrProviderDegraded · Dify 不可达 / 5xx / 超时; 生产环境业务层应转 kb.provider_degraded.
var ErrProviderDegraded = errors.New("dify: provider degraded (upstream unreachable or 5xx)")

// New · 构造 Dify provider; cfg 任一关键字段为空 → 返 error (由 wiring 层 fail-fast).
func New(cfg Config) (*Provider, error) {
	if cfg.EndpointURL == "" {
		return nil, errors.New("dify: empty endpoint")
	}
	if cfg.APIToken == "" {
		return nil, errors.New("dify: empty api token (forgot secret-manager resolve?)")
	}
	if cfg.TenantDatasetID == "" || cfg.UserDatasetID == "" {
		return nil, errors.New("dify: tenant_dataset_id / user_dataset_id required")
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 10 * time.Second}
	}
	if cfg.DefaultTopK == 0 {
		cfg.DefaultTopK = 5
	}
	if cfg.DefaultThreshold == 0 {
		cfg.DefaultThreshold = 0.4
	}
	cfg.EndpointURL = normalizeEndpoint(cfg.EndpointURL)
	return &Provider{cfg: cfg}, nil
}

// normalizeEndpoint · 接受带 /v1 与不带 /v1 两种形式, 统一 strip 尾 / 再 strip 末尾的 "/v1",
// 让 provider 内部用 "/v1/datasets/..." 拼接子路径时不会出现 "//v1/v1/datasets/...".
//
// 见 docs/pitfalls/dify-ingest-not-in-pg-tx.md §"endpoint normalize"。
func normalizeEndpoint(in string) string {
	v := strings.TrimSpace(in)
	v = strings.TrimRight(v, "/")
	if strings.HasSuffix(v, "/v1") {
		v = strings.TrimSuffix(v, "/v1")
	}
	v = strings.TrimRight(v, "/")
	return v
}

// Kind · "dify".
func (p *Provider) Kind() string { return "dify" }

// IngestChunks · v1 不在 provider 内做切片; 把 chunks 传给 Dify document/create_by_text.
//
// 业务约定:
//   - 强制注入 metadata.tenant_id / metadata.business_kb_id / metadata.scope.
//   - dataset 路由: scope='user' → UserDatasetID; scope='tenant' / 'workspace' / 'private' → TenantDatasetID.
func (p *Provider) IngestChunks(ctx context.Context, in provider.IngestReq) (*provider.IngestResult, error) {
	if in.TenantID == 0 {
		return nil, fmt.Errorf("dify: tenant_id required (forgot service-level injection?)")
	}
	dsID := p.routeDataset(metadataString(in.Metadata, "scope"))
	if len(in.Chunks) == 0 {
		return &provider.IngestResult{ProviderDocID: "", ChunkCount: 0}, nil
	}
	// 把多个 chunks 串联为单个文档 (v1 简化; 后续 Dify 自动切片).
	text := strings.Join(in.Chunks, "\n\n")
	metadata := map[string]any{
		"tenant_id":      in.TenantID,
		"business_kb_id": in.KBID,
	}
	for k, v := range in.Metadata {
		metadata[k] = v
	}
	body := map[string]any{
		"name":               fmt.Sprintf("kb-%d-doc-%d", in.KBID, in.DocumentID),
		"text":               text,
		"indexing_technique": "high_quality",
		"process_rule":       map[string]any{"mode": "automatic"},
		"metadata":           metadata,
	}
	type respData struct {
		Document struct {
			ID string `json:"id"`
		} `json:"document"`
	}
	var out respData
	if err := p.postJSON(ctx, "/v1/datasets/"+dsID+"/document/create_by_text", body, &out); err != nil {
		return nil, err
	}
	return &provider.IngestResult{ProviderDocID: out.Document.ID, ChunkCount: len(in.Chunks)}, nil
}

// Retrieve · 调 Dify /datasets/{id}/retrieve, 强制注入 tenant_id metadata filter.
func (p *Provider) Retrieve(ctx context.Context, in provider.RetrieveReq) ([]provider.Chunk, error) {
	if in.TenantID == 0 {
		return nil, fmt.Errorf("dify: tenant_id required (forgot service-level injection?)")
	}
	dsID := p.routeDataset(metadataString(in.MetadataFilter, "scope"))

	filters := []map[string]any{
		{"key": "tenant_id", "value": in.TenantID, "operator": "eq"},
	}
	if in.KBID != 0 {
		filters = append(filters, map[string]any{"key": "business_kb_id", "value": in.KBID, "operator": "eq"})
	}
	if v, ok := in.MetadataFilter["scope"]; ok {
		filters = append(filters, map[string]any{"key": "scope", "value": v, "operator": "eq"})
	}
	if v, ok := in.MetadataFilter["owner_user_id"]; ok {
		filters = append(filters, map[string]any{"key": "owner_user_id", "value": v, "operator": "eq"})
	}

	topK := in.TopK
	if topK <= 0 {
		topK = p.cfg.DefaultTopK
	}
	threshold := in.Threshold
	if threshold <= 0 {
		threshold = p.cfg.DefaultThreshold
	}
	body := map[string]any{
		"query": in.Query,
		"retrieval_model": map[string]any{
			"search_method":           "hybrid_search",
			"top_k":                   topK,
			"score_threshold_enabled": threshold > 0,
			"score_threshold":         threshold,
			"reranking_enable":        p.cfg.UseRerank || in.UseRerank,
		},
		"metadata_condition": map[string]any{
			"logical_operator": "and",
			"conditions":       filters,
		},
	}
	type record struct {
		Content string  `json:"content"`
		Score   float64 `json:"score"`
		Segment struct {
			ID         string         `json:"id"`
			DocumentID string         `json:"document_id"`
			Position   int            `json:"position"`
			Metadata   map[string]any `json:"metadata"`
		} `json:"segment"`
	}
	var resp struct {
		Records []record `json:"records"`
	}
	if err := p.postJSON(ctx, "/v1/datasets/"+dsID+"/retrieve", body, &resp); err != nil {
		return nil, err
	}
	out := make([]provider.Chunk, 0, len(resp.Records))
	for _, rec := range resp.Records {
		out = append(out, provider.Chunk{
			UUID:       rec.Segment.ID,
			ChunkIndex: rec.Segment.Position,
			Content:    rec.Content,
			Score:      rec.Score,
			Source:     "dify_hybrid",
		})
	}
	return out, nil
}

// DeleteDocument · 调 Dify DELETE /datasets/{id}/documents/{providerDocID}.
//
// Codex round-5 P1-1 业务路径 fail-closed (含 404):
//   - 任意 4xx (401/403/404/422/429/...) 与 5xx / EOF / 网络错 → ErrProviderDegraded wrap
//     → service.mapProviderErr → kb.provider_degraded;
//   - **不再** 对 404 做 "幂等成功" 处理: 404 可能是 dataset 错配 / endpoint 错配 / token 失效 /
//     provider doc 已被外部清理等多种原因; 沉默吞掉会让上层误以为删除成功, 影响审计与
//     用户感知。所有 4xx 一律按 provider 不可用对待, 上游审计补偿 / admin reaper 后续处理。
//   - HealthCheck 用本方法以外的独立 HTTP, 保留 4xx 细节给 admin diagnosis.
func (p *Provider) DeleteDocument(ctx context.Context, in provider.DeleteDocumentReq) error {
	if in.TenantID == 0 {
		return fmt.Errorf("dify: tenant_id required")
	}
	if in.ProviderDocID == "" {
		return fmt.Errorf("dify: empty provider_doc_id")
	}
	dsID := p.routeDataset("") // delete 不路由 scope; 由 ProviderDocID 唯一定位
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete,
		p.cfg.EndpointURL+"/v1/datasets/"+dsID+"/documents/"+in.ProviderDocID, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+p.cfg.APIToken)
	resp, err := p.cfg.HTTPClient.Do(req)
	if err != nil {
		return wrapDegraded(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: delete %d: %s", ErrProviderDegraded, resp.StatusCode, truncate(string(raw), 200))
	}
	return nil
}

// HealthCheck · admin /platform/kb-providers/{uuid}/health-check 用; 简单调
// GET /v1/datasets 看连通性. 成功返 nil; 失败返 error (调用方写 health_message 列).
func (p *Provider) HealthCheck(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.EndpointURL+"/v1/datasets", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+p.cfg.APIToken)
	resp, err := p.cfg.HTTPClient.Do(req)
	if err != nil {
		return wrapDegraded(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		return ErrProviderDegraded
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("dify health %d", resp.StatusCode)
	}
	return nil
}

func (p *Provider) routeDataset(scope string) string {
	if scope == "user" {
		return p.cfg.UserDatasetID
	}
	return p.cfg.TenantDatasetID
}

func metadataString(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, _ := m[key].(string)
	return v
}

func wrapDegraded(err error) error {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return err
	}
	return fmt.Errorf("%w: %v", ErrProviderDegraded, err)
}

func (p *Provider) postJSON(ctx context.Context, path string, body any, out any) error {
	bs, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("dify: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.EndpointURL+path, bytes.NewReader(bs))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+p.cfg.APIToken)
	resp, err := p.cfg.HTTPClient.Do(req)
	if err != nil {
		return wrapDegraded(err)
	}
	defer resp.Body.Close()
	// Codex round-4 P1-4: 业务 RPC (postJSON 服务于 IngestChunks/Retrieve) 任何 4xx/5xx
	// 都视为 provider 不可用 → wrap ErrProviderDegraded → service.mapProviderErr → kb.provider_degraded.
	// 401/403 (鉴权) / 404 (dataset 不存在或路径错) / 429 (限流) / 422 (参数不被接受) 一律 fail-closed.
	// HealthCheck 路径走单独 HTTP, 保留具体 status 给 admin diagnosis.
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: %d on %s: %s", ErrProviderDegraded, resp.StatusCode, path, truncate(string(raw), 200))
	}
	if out != nil {
		raw, _ := io.ReadAll(resp.Body)
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("dify: decode %s: %w", path, err)
		}
	}
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
