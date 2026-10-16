package a2a

import (
	"context"
	"time"

	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
)

// MaxCycleWalk Phase5 链回溯: 沿 parent_edge_id 链最多回溯 16 跳.
// depth ≤ 5 + DB CHECK depth ≤ 5, 16 给 safe margin.
const MaxCycleWalk = 16

// ChainAnalysis 一次 invoke 的链路分析结果 (Phase5 预算治理输入).
type ChainAnalysis struct {
	Depth             int16     // = len(ancestors); 即将插入 edge 的深度
	RootEdgeID        int64     // 链顶根 id; 0 = 本次即根 (无 parent)
	RootEdgeCreatedAt time.Time // 根的 created_at; RootEdgeID=0 时为零值
	// ReentryCandidate: 候选 to_agent 命中「活跃祖先」(同 agent 出现在链上且该祖先仍
	// running / awaiting_approval)。外部 ZAP 可安全重入; openclaw/hermes 同 pod 不支持并发,
	// 需据此在派发前快速失败 a2a.reentrant_runtime_unsupported。
	ReentryCandidate bool
}

// CycleDetector 沿 parent_edge_id 回溯做链路分析.
//
// Phase5 起**不再「祖先命中即拒绝」**: 是否放行由 service 层按 depth / total_calls /
// chain_timeout / repeated-fingerprint / runtime 重入能力综合治理。本接口只产出分析数据。
type CycleDetector interface {
	AnalyzeChain(ctx context.Context, tenantID int64, parentEdgeID *int64, parentCreatedAt *time.Time, candidateToAgentID int64) (ChainAnalysis, error)
}

// EdgeRepoCycleDetector 用 a2a_call_edges.ListAncestors 实现链路分析.
//
// 实现策略 (与 §14 D28 一致, DB 不强制 self-FK, 在 service 层完成):
//  1. parent 为 nil → root 调用, depth=0, 本次即根.
//  2. 否则: repo.ListAncestors(parent.ID, parent.createdAt, max=MaxCycleWalk)
//     - depth = len(ancestors)
//     - 链顶祖先 (ancestors[last]) 给出 root chain 锚点 (root_edge_id 或其自身 id)
//     - 候选命中仍活跃的祖先 (from/to 相同) → ReentryCandidate=true
type EdgeRepoCycleDetector struct {
	repo doma2a.Repository
}

func NewEdgeRepoCycleDetector(repo doma2a.Repository) *EdgeRepoCycleDetector {
	return &EdgeRepoCycleDetector{repo: repo}
}

func (d *EdgeRepoCycleDetector) AnalyzeChain(ctx context.Context, tenantID int64, parentEdgeID *int64, parentCreatedAt *time.Time, candidate int64) (ChainAnalysis, error) {
	if parentEdgeID == nil || parentCreatedAt == nil {
		// root 调用: depth=0, 本次即根 (RootEdgeID=0 由 service 解释为 self).
		return ChainAnalysis{}, nil
	}
	ancestors, err := d.repo.ListAncestors(ctx, tenantID, *parentEdgeID, *parentCreatedAt, MaxCycleWalk)
	if err != nil {
		return ChainAnalysis{}, err
	}
	ca := ChainAnalysis{Depth: int16(len(ancestors))}
	for _, a := range ancestors {
		if a.ToAgentID == candidate || a.FromAgentID == candidate {
			// 只有仍在执行的祖先才构成同 pod 重入死锁风险; 已终态祖先可安全重入.
			if a.Status == doma2a.StatusRunning || a.Status == doma2a.StatusAwaitingApproval {
				ca.ReentryCandidate = true
			}
		}
	}
	if len(ancestors) > 0 {
		top := ancestors[len(ancestors)-1] // 链顶 (最早祖先) = root chain 锚点
		if top.RootEdgeID != nil {
			ca.RootEdgeID = *top.RootEdgeID
			if top.RootEdgeCreatedAt != nil {
				ca.RootEdgeCreatedAt = *top.RootEdgeCreatedAt
			}
		} else {
			// 链顶自身即根 (其 root_edge_id 为 NULL).
			ca.RootEdgeID = top.ID
			ca.RootEdgeCreatedAt = top.CreatedAt
		}
	}
	return ca, nil
}

// 编译期断言.
var _ CycleDetector = (*EdgeRepoCycleDetector)(nil)
