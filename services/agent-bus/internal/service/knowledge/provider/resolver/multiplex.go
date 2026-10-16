package resolver

import (
	"context"
	"errors"
	"fmt"

	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	provider "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
)

// KBLookup · multiplex 用; 给定 KB ID 反查行, 决定走哪个 Provider.
type KBLookup interface {
	GetKBByID(ctx context.Context, id int64) (*domkb.KnowledgeBase, error)
}

// MultiplexProvider 包装 Resolver, 在每次调用前按 KBID 反查 KB → Resolve → 实际 provider.
//
// 设计目的:
//   - 让 knowledge.Service 单一 provider 字段保持不变 (不重构 service);
//   - 路由责任集中在 Resolver + multiplex 一层;
//   - 任何 Resolve 失败 → 返 ErrDegraded (业务层映射成 kb.provider_degraded);
//   - Kind() 返 "multiplex" 仅 debug 用.
type MultiplexProvider struct {
	logger   *log.Logger
	resolver *Resolver
	kbs      KBLookup
}

// NewMultiplex 构造. 若 kbs 为 nil 仅在调用方传完整 KB 上下文时可用 (退化为按 default provider 路由).
func NewMultiplex(logger *log.Logger, r *Resolver, kbs KBLookup) *MultiplexProvider {
	return &MultiplexProvider{logger: logger, resolver: r, kbs: kbs}
}

func (m *MultiplexProvider) Kind() string { return "multiplex" }

func (m *MultiplexProvider) IngestChunks(ctx context.Context, in provider.IngestReq) (*provider.IngestResult, error) {
	p, err := m.resolveByKBID(ctx, in.KBID)
	if err != nil {
		return nil, err
	}
	return p.IngestChunks(ctx, in)
}

func (m *MultiplexProvider) Retrieve(ctx context.Context, in provider.RetrieveReq) ([]provider.Chunk, error) {
	p, err := m.resolveByKBID(ctx, in.KBID)
	if err != nil {
		return nil, err
	}
	return p.Retrieve(ctx, in)
}

func (m *MultiplexProvider) RetrieveBatch(ctx context.Context, in []provider.RetrieveReq) (map[int64][]provider.Chunk, error) {
	if len(in) == 0 {
		return nil, nil
	}
	providers := make([]provider.Provider, 0, len(in))
	for _, req := range in {
		p, err := m.resolveByKBID(ctx, req.KBID)
		if err != nil {
			return nil, err
		}
		providers = append(providers, p)
	}
	first := providers[0]
	sameProvider := true
	for _, p := range providers[1:] {
		if p != first {
			sameProvider = false
			break
		}
	}
	if sameProvider {
		if batcher, ok := first.(provider.BatchRetriever); ok {
			return batcher.RetrieveBatch(ctx, in)
		}
	}
	out := make(map[int64][]provider.Chunk, len(in))
	for i, req := range in {
		chunks, err := providers[i].Retrieve(ctx, req)
		if err != nil {
			return nil, err
		}
		out[req.KBID] = chunks
	}
	return out, nil
}

func (m *MultiplexProvider) DeleteDocument(ctx context.Context, in provider.DeleteDocumentReq) error {
	p, err := m.resolveByKBID(ctx, in.KBID)
	if err != nil {
		return err
	}
	return p.DeleteDocument(ctx, in)
}

func (m *MultiplexProvider) resolveByKBID(ctx context.Context, kbID int64) (provider.Provider, error) {
	if m.kbs == nil {
		// 退化: 没有 KB lookup, 调用 Resolver 用空 KB 走 default provider.
		// (主要给单测兜底; 生产 cmd/bus 总是传 kbs.)
		return m.resolver.Resolve(ctx, &domkb.KnowledgeBase{})
	}
	kb, err := m.kbs.GetKBByID(ctx, kbID)
	if err != nil || kb == nil {
		if m.logger != nil {
			m.logger.Warn(ctx, "multiplex kb lookup failed", "kb_id", kbID, "err", err)
		}
		return nil, fmt.Errorf("%w: kb lookup", ErrDegraded)
	}
	return m.resolver.Resolve(ctx, kb)
}

// Ensure MultiplexProvider satisfies provider.Provider.
var _ provider.Provider = (*MultiplexProvider)(nil)
var _ provider.BatchRetriever = (*MultiplexProvider)(nil)

// guard: silence unused import warnings if errors package isn't otherwise referenced.
var _ = errors.New
