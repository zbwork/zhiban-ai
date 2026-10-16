// Package provider 是 M8 知识库 provider 抽象.
//
// Phase A: 只实现一个 StubKBProvider (见 ./stub), PG tsvector + ILIKE fallback.
// Phase B: DifyKBProvider / TablestoreKBProvider 可实现此接口替换, service / transport 零改动.
//
// 关键约束 (docs/tasks/m8-knowledge-bases.md §4.1):
//   - tenant_id 由 service 层从 session_token 解出后注入 RetrieveReq.TenantID;
//     provider 不接受外部 body 传入的 tenant_id (强制 filter 注入).
//   - service 层负责切片; 把纯 chunks 传给 IngestChunks (与 §4.3 一致).
package provider

import (
	"context"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// Provider 知识库 provider 接口.
//
// Phase A 实现仅 StubKBProvider, 直读 PG kb_chunks; Phase B 切 Dify 时实现切 HTTP 调用.
type Provider interface {
	// Kind 返回 provider 标识 ("stub" / "dify" / ...).
	Kind() string

	// IngestChunks 把 service 层切好的 chunks 写入 provider.
	//
	// Phase A stub: INSERT 到 kb_chunks.
	// Phase B Dify: 把整文 stream 传给 Dify (chunks 由 Dify 自己切, service 退化为透传).
	IngestChunks(ctx context.Context, in IngestReq) (*IngestResult, error)

	// Retrieve 召回; chunks 已按 score DESC 排序.
	//
	// 命中数为 0 时由 provider 自行 fallback (Phase A stub 走 ILIKE 兜底);
	// caller 不需要再做 fallback 编排.
	Retrieve(ctx context.Context, in RetrieveReq) ([]Chunk, error)

	// DeleteDocument 删除 provider 内某文档及其所有 chunk.
	DeleteDocument(ctx context.Context, in DeleteDocumentReq) error
}

// BatchRetriever 是可选优化接口。支持同一 provider 在同一授权上下文中
// 一次召回多个 KB；不支持者继续走单 KB Retrieve。
type BatchRetriever interface {
	RetrieveBatch(ctx context.Context, in []RetrieveReq) (map[int64][]Chunk, error)
}

// IngestReq IngestChunks 入参. tenant_id 由 service 强制注入.
type IngestReq struct {
	TenantID      int64
	KBID          int64
	DocumentID    int64
	ProviderDocID string
	Chunks        []string
	Metadata      map[string]any
}

// IngestResult IngestChunks 返回.
type IngestResult struct {
	ProviderDocID string
	ChunkCount    int
}

// RetrieveReq Retrieve 入参. tenant_id 强制注入; provider 拒受外部传入.
type RetrieveReq struct {
	TenantID  int64
	KBID      int64
	Query     string
	TopK      int
	Threshold float64
	// MetadataFilter 透传到 provider; Phase A stub 不消费.
	MetadataFilter map[string]any
	// UseRerank Phase A stub 不实现.
	UseRerank bool
}

// DeleteDocumentReq DeleteDocument 入参.
type DeleteDocumentReq struct {
	TenantID      int64
	KBID          int64
	DocumentID    int64
	ProviderDocID string
}

// Chunk Retrieve 返回的 chunk.
type Chunk struct {
	UUID       string
	DocumentID int64
	ChunkIndex int
	Content    string
	Score      float64
	// Source 是否走了 fallback ILIKE 路径 ("tsvector" / "ilike"); audit 可用.
	Source string
}

// Logger noop wrapper so provider 可不依赖 *log.Logger 类型.
type Logger = log.Logger
