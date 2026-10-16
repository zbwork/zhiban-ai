// admin_quotas.go — F06 Phase B admin: tenant quota summary + per-account upsert.
//
// 2 个对外方法:
//
//	GetTenantSummary  租户总额度 + per-account 列表 (用 ListAccountQuotasByTenant + SumAccountUsedBytesByTenant 兜底用量)
//	UpsertAccountQuota 设置 per-account quota (quota_bytes=-1 表示恢复继承)
//
// 不实现 SetTenantQuota — 按 user 拍定: 平台 admin 才能改租户总额度;
// 这里 admin 只读总额度, 改总额走 platform 端点 (后续 slice).
//
// ACL: 由 admin handler tenantPerm("tenant.drive.manage_quota") 把关.
package drive

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// AdminQuotaSvc Phase A2 admin: tenant quota summary + per-account upsert.
type AdminQuotaSvc struct {
	pool   *pgxpool.Pool
	quotas *drepo.QuotaRepo
}

// NewAdminQuotaSvc 构造.
func NewAdminQuotaSvc(pool *pgxpool.Pool, q *drepo.QuotaRepo) *AdminQuotaSvc {
	return &AdminQuotaSvc{pool: pool, quotas: q}
}

// AdminAccountQuotaItem 单 account quota 行 (response).
type AdminAccountQuotaItem struct {
	AccountID      int64  `json:"account_id"`
	AccountName    string `json:"account_name,omitempty"`
	EmployeeID     string `json:"employee_id,omitempty"`
	DepartmentName string `json:"department_name,omitempty"`
	Contact        string `json:"contact,omitempty"`
	Status         string `json:"status,omitempty"`
	QuotaBytes     int64  `json:"quota_bytes"` // -1 表示不设独立上限
	UsedBytes      int64  `json:"used_bytes"`
}

// AdminTenantQuotaSummary GET /api/admin/v1/tenant/drive/quotas response.
//
// tenant_quota_bytes 字段语义:
//   - tenant quota 行存在 → 真值; -1 表示无限
//   - 不存在 → nil (前端展示"无限制")
//
// items: per-account 行 (含未显式 set quota 但有 used_bytes 的账号 — 用 -1 表示继承)
type AdminTenantQuotaSummary struct {
	TenantID         int64                   `json:"tenant_id"`
	TenantQuotaBytes *int64                  `json:"tenant_quota_bytes,omitempty"`
	TenantUsedBytes  int64                   `json:"tenant_used_bytes"`
	Items            []AdminAccountQuotaItem `json:"items"`
}

// GetTenantSummary 返回本租户配额汇总 + per-account 列表.
// 列表合并: 显式 set quota 的 account (drive_quotas 行) 与 仅有 used_bytes 的 account (从 drive_files 聚合).
func (s *AdminQuotaSvc) GetTenantSummary(ctx context.Context, tenantID int64) (*AdminTenantQuotaSummary, error) {
	out := &AdminTenantQuotaSummary{TenantID: tenantID, Items: []AdminAccountQuotaItem{}}

	// 1. tenant-level row (可选)
	tq, err := s.quotas.GetForTenant(ctx, tenantID)
	if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if tq != nil {
		quota := tq.QuotaBytes
		out.TenantQuotaBytes = &quota
	}
	tenantUsed, err := s.quotas.SumTenantUsedBytes(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out.TenantUsedBytes = tenantUsed

	// 2. account-level rows (显式 set)
	rows, err := s.quotas.ListAccountQuotasByTenant(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 3. used_bytes 聚合 (从 drive_files; 兜底未显式 set quota 的账号)
	used, err := s.quotas.SumAccountUsedBytesByTenant(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	seen := make(map[int64]bool, len(rows))
	for i := range rows {
		q := &rows[i]
		if q.SubjectID == nil {
			continue
		}
		aid := *q.SubjectID
		item := AdminAccountQuotaItem{
			AccountID:  aid,
			QuotaBytes: q.QuotaBytes,
			UsedBytes:  q.UsedBytes, // drive_quotas.used_bytes 已实时维护; 若历史漂移可参考 used[aid]
		}
		// 如果 drive_quotas.used_bytes 显著少于 files 聚合值, 用聚合值兜底 (避免显示假"已用 0").
		if u, ok := used[aid]; ok && u > item.UsedBytes {
			item.UsedBytes = u
		}
		out.Items = append(out.Items, item)
		seen[aid] = true
	}

	// 把"只有用量没有 quota 行"的 account 也加入 (quota_bytes=-1 表示继承)
	for aid, u := range used {
		if seen[aid] {
			continue
		}
		out.Items = append(out.Items, AdminAccountQuotaItem{
			AccountID:  aid,
			QuotaBytes: -1,
			UsedBytes:  u,
		})
	}
	if err := s.attachAccountMeta(ctx, tenantID, out.Items); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	sort.SliceStable(out.Items, func(i, j int) bool {
		li := out.Items[i].AccountName
		if li == "" {
			li = fmt.Sprintf("account#%d", out.Items[i].AccountID)
		}
		lj := out.Items[j].AccountName
		if lj == "" {
			lj = fmt.Sprintf("account#%d", out.Items[j].AccountID)
		}
		if li == lj {
			return out.Items[i].AccountID < out.Items[j].AccountID
		}
		return li < lj
	})
	return out, nil
}

func (s *AdminQuotaSvc) attachAccountMeta(ctx context.Context, tenantID int64, items []AdminAccountQuotaItem) error {
	if len(items) == 0 {
		return nil
	}
	ids := make([]int64, 0, len(items))
	for _, it := range items {
		ids = append(ids, it.AccountID)
	}
	rows, err := s.pool.Query(ctx, `
SELECT a.id,
       COALESCE(NULLIF(tm.nickname,''), NULLIF(a.display_name,''), NULLIF(a.username,''), NULLIF(a.email,''), NULLIF(a.phone,''), '') AS account_name,
       COALESCE(tm.employee_id, '') AS employee_id,
       COALESCE(d.name, '') AS department_name,
       COALESCE(NULLIF(a.phone,''), NULLIF(a.email,''), NULLIF(a.username,''), '') AS contact,
       COALESCE(NULLIF(tm.status,''), NULLIF(a.status,''), '') AS status
  FROM accounts a
  LEFT JOIN tenant_memberships tm
    ON tm.tenant_id = $1
   AND tm.account_id = a.id
   AND tm.deleted_at IS NULL
  LEFT JOIN departments d ON d.id = tm.department_id
 WHERE a.id = ANY($2::bigint[])
   AND a.deleted_at IS NULL
`, tenantID, ids)
	if err != nil {
		return fmt.Errorf("AdminQuotaSvc.attachAccountMeta query: %w", err)
	}
	defer rows.Close()

	type meta struct {
		name       string
		employeeID string
		dept       string
		contact    string
		status     string
	}
	byID := make(map[int64]meta, len(ids))
	for rows.Next() {
		var id int64
		var m meta
		if err := rows.Scan(&id, &m.name, &m.employeeID, &m.dept, &m.contact, &m.status); err != nil {
			return fmt.Errorf("AdminQuotaSvc.attachAccountMeta scan: %w", err)
		}
		byID[id] = m
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("AdminQuotaSvc.attachAccountMeta rows: %w", err)
	}
	for i := range items {
		m := byID[items[i].AccountID]
		items[i].AccountName = m.name
		items[i].EmployeeID = m.employeeID
		items[i].DepartmentName = m.dept
		items[i].Contact = m.contact
		items[i].Status = m.status
	}
	return nil
}

// UpsertAccountQuota 设置单 account 的 quota_bytes.
//   - quotaBytes >= 0: 设置硬限额
//   - quotaBytes == -1: 表示"恢复继承租户额度" — DB 仍写 -1, AddUsedBytesAtomicTx 已识别 -1 = 无限,
//     但租户总额检查在 service 层另一路径完成 (Phase 2.2c upload.go)
//
// updatedBy = admin caller account id.
func (s *AdminQuotaSvc) UpsertAccountQuota(ctx context.Context, tenantID, accountID, quotaBytes, updatedBy int64) error {
	if accountID <= 0 {
		return apperr.ErrInvalidParams.Withf("account_id required")
	}
	if quotaBytes < -1 {
		return apperr.ErrInvalidParams.Withf("quota_bytes must be >= -1 (-1 = inherit)")
	}
	if err := s.quotas.UpsertAccountQuota(ctx, tenantID, accountID, quotaBytes, updatedBy); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("AdminQuotaSvc.UpsertAccountQuota: %w", err))
	}
	return nil
}

// 用 dom 避免 unused import warning (helper file 不直接用 dom; 间接通过 drepo.QuotaRepo)
var _ = dom.QuotaSubjectAccount
