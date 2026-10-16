// Package membership 提供租户成员 CRUD。
//
// 设计要点：
//   - 邀请成员 = 邀请已有账号 或 用 phone/email 新建账号并加入
//   - 一个账号可属于多个租户；删除成员只是软删 tenant_memberships，不删 accounts
//   - Batch 2B T2B.3: 新账号密码 = crypto/rand 一次性临时密码，明文仅 InviteResult 返回一次；
//     audit payload 不含明文；must_change_password=true 由 admin_accounts 行强制改密
//   - Disable / Enable 通过 Update + status='disabled' / 'active' 实现，service 内部映射 audit topic
package membership

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	tenantadminguard "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenantadmin"
)

var jsonMarshal = json.Marshal

// Member 一条租户成员记录（聚合账号 + 成员关系）。
type Member struct {
	MembershipID   int64              `json:"membership_id"`
	AccountID      int64              `json:"account_id"`
	UUID           string             `json:"uuid"`
	Email          string             `json:"email,omitempty"`
	Phone          string             `json:"phone,omitempty"`
	Username       string             `json:"username,omitempty"`
	DisplayName    string             `json:"display_name"`
	AvatarURL      string             `json:"avatar_url,omitempty"`
	Status         string             `json:"status"`         // membership status: invited/active/suspended/left
	AccountStatus  string             `json:"account_status"` // accounts.status
	DepartmentID   *int64             `json:"department_id,omitempty"`
	DepartmentName string             `json:"department_name,omitempty"`
	Title          string             `json:"title,omitempty"`
	EmployeeID     string             `json:"employee_id,omitempty"`
	JoinedAt       string             `json:"joined_at,omitempty"`
	Roles          []string           `json:"roles,omitempty"`
	ContactFields  ContactFieldsInput `json:"contact_fields"`
}

// InviteInput 邀请成员入参。
//
// Batch 2B T2B.3 决策（与 T2B.1 对齐）：不再接受调用方自带 password。
// 当本次新建账号时，后端 crypto/rand 生成一次性临时密码；明文仅在 InviteResult 返回一次。
type InviteInput struct {
	Phone        string `json:"phone"`
	Email        string `json:"email"`
	DisplayName  string `json:"display_name"`
	Title        string `json:"title"`
	EmployeeID   string `json:"employee_id"`
	DepartmentID *int64 `json:"department_id"`
	RoleCode     string `json:"role_code"` // 默认空 = 不分配角色（普通员工）

	// F28 codex 第 3 轮 P2：H5 token join 路径的审计 actor 与 invited_by 解耦。
	// invitedBy 参数继续写 tenant_memberships.invited_by（归因给 token 创建人），
	// 但 audit.member.invited 的 actor 用下面覆盖（system/invite_token/account_id=0）。
	// 零值 = 保持 admin 后台/手机号直加的历史行为（tenant_admin/invitedBy）。
	// json:"-"：仅服务端内部路径可设，请求 body 不可注入。
	AuditActorKind      string `json:"-"`
	AuditActingAs       string `json:"-"`
	AuditActorAccountID *int64 `json:"-"`
}

// InviteResult Invite 的响应：含 Member + 一次性凭据（仅新建账号时）。
type InviteResult struct {
	Member               *Member `json:"member"`
	AccountReused        bool    `json:"account_reused"`
	AdminInitialPassword string  `json:"initial_password,omitempty"` // 明文，仅本次返回；复用账号时空字串
}

// UpdateInput 更新成员入参。
type UpdateInput struct {
	DisplayName  *string `json:"display_name"`
	Title        *string `json:"title"`
	EmployeeID   *string `json:"employee_id"`
	DepartmentID *int64  `json:"department_id"`
	Status       *string `json:"status"`
}

// ContactFieldsInput M2 §5.3 admin 写入成员 metadata 子集。
//
// 任意指针字段为 nil 表示不修改; field_mask 一旦给出, 表示对该 key 全量覆盖
// (内部仅 phone/email/title 三键, 不设深度合并)。
type ContactFieldsInput struct {
	HiddenInContacts      *bool             `json:"hidden_in_contacts,omitempty"`
	AllowInviteToGroup    *bool             `json:"allow_invite_to_group,omitempty"`
	FieldMask             map[string]string `json:"field_mask,omitempty"`
	PositionLabelOverride *string           `json:"position_label_override,omitempty"`
}

// Service 成员服务。
//
// Batch 2B T2B.3：
//   - Invite 返回 *InviteResult（含一次性 initial_password）；handler 据此弹凭据 modal
//   - Update 支持 status 字段；status='active'<->'disabled' 转换由 service 检测并发对应 audit topic
//   - Remove 保留作为 admin 内部清理路径（DELETE /tenant/members/:id）；前端 v1 不暴露按钮
type Service interface {
	List(ctx context.Context, tenantID int64, departmentID int64, keyword string, limit, offset int) ([]Member, int64, error)
	Get(ctx context.Context, tenantID, membershipID int64) (*Member, error)
	Invite(ctx context.Context, tenantID, invitedBy int64, in InviteInput) (*InviteResult, error)
	Update(ctx context.Context, tenantID, actorAccountID, membershipID int64, in UpdateInput) (*Member, error)
	Remove(ctx context.Context, tenantID, actorAccountID, membershipID int64) error
	// M2 §5.3: 写入 tenant_memberships.metadata 通讯录配置
	UpdateContactFields(ctx context.Context, tenantID, membershipID int64, in ContactFieldsInput) error
}

type impl struct {
	pool             *pgxpool.Pool
	pub              domevt.Publisher
	quota            dombilling.EntitlementChecker
	revokeIMSessions IMSessionRevokeFunc
}

type departmentRowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// resolveDepartmentID keeps every membership inside the current tenant's
// organization tree. Omitted input falls back to the tenant's oldest active
// root department, matching the member-invite contract in F01/F28.
func resolveDepartmentID(ctx context.Context, q departmentRowQuerier, tenantID int64, requested *int64) (int64, error) {
	var departmentID int64
	if requested != nil {
		err := q.QueryRow(ctx, `
			SELECT id FROM departments
			 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`, *requested, tenantID).Scan(&departmentID)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.ErrInvalidParams.Withf("部门不存在或不属于当前租户")
		}
		if err != nil {
			return 0, err
		}
		return departmentID, nil
	}

	err := q.QueryRow(ctx, `
		SELECT id FROM departments
		 WHERE tenant_id=$1 AND parent_id IS NULL AND deleted_at IS NULL
		 ORDER BY id LIMIT 1`, tenantID).Scan(&departmentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, apperr.ErrInternal.Withf("当前租户缺少根部门，无法保存成员")
	}
	if err != nil {
		return 0, err
	}
	return departmentID, nil
}

type Option func(*impl)

func WithEntitlementChecker(q dombilling.EntitlementChecker) Option {
	return func(s *impl) { s.quota = q }
}

// IMSessionRevokeFunc invalidates the member's tenant-scoped IM sessions.
// The service keeps this substrate-neutral; cmd/admin supplies the WuKong adapter.
type IMSessionRevokeFunc func(ctx context.Context, tenantID int64, accountUUID string) error

func WithIMSessionRevoker(revoke IMSessionRevokeFunc) Option {
	return func(s *impl) { s.revokeIMSessions = revoke }
}

func SetEntitlementCheckerOnService(svc Service, q dombilling.EntitlementChecker) {
	if im, ok := svc.(*impl); ok {
		im.quota = q
	}
}

func New(pool *pgxpool.Pool, pub domevt.Publisher, opts ...Option) Service {
	s := &impl{pool: pool, pub: pub}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// generateTempPassword 后端生成 18 字符 URL-safe 一次性临时密码（与 tenant.Provision 一致）。
// 失败时返回 error，调用方必须回滚事务，不允许产生空 / 弱密码继续写库（Batch 2B closeout #4）。
func generateTempPassword() (string, error) {
	var raw [12]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", apperr.ErrInternal.Withf("generate temp password: crypto/rand failed: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// notifyConfigChange 发 PG NOTIFY 让 bus contacts listener 即时感知成员变更（M2 §8）。
// 多实例契约：所有 bus 实例 1s 内收到 payload。失败 silently。
func (s *impl) notifyConfigChange(ctx context.Context, payload string) {
	_, _ = s.pool.Exec(ctx, `SELECT pg_notify('config_change', $1)`, payload)
}

// auditAfter 短 tx best-effort 发 audit 事件（actor 默认 tenant_admin）。
func (s *impl) auditAfter(ctx context.Context, topic string, tenantID, actorAccountID int64, idempKey string, data map[string]any) {
	s.auditAfterAs(ctx, topic, tenantID, actorAccountID, "tenant_admin", "", idempKey, data)
}

// auditAfterAs 同 auditAfter，但 actor_kind / acting_as 由调用方指定
// （F28 H5 token join = system/invite_token，codex 第 3 轮 P2）。
func (s *impl) auditAfterAs(ctx context.Context, topic string, tenantID, actorAccountID int64, actorKind, actingAs, idempKey string, data map[string]any) {
	if s.pub == nil {
		return
	}
	parts := strings.SplitN(topic, ".", 3)
	domain := ""
	eventKind := ""
	if len(parts) >= 2 {
		domain = parts[1]
	}
	if len(parts) >= 3 {
		eventKind = parts[2]
	}
	dataB, _ := json.Marshal(data)
	if len(dataB) == 0 {
		dataB = []byte("{}")
	}
	resourceKind, _ := data["resource_kind"].(string)
	resourceUUID, _ := data["resource_uuid"].(string)
	payload, _ := json.Marshal(map[string]any{
		"actor_kind":    actorKind,
		"acting_as":     actingAs,
		"domain":        domain,
		"event_kind":    eventKind,
		"severity":      "info",
		"resource_kind": resourceKind,
		"resource_uuid": resourceUUID,
		"account_id":    actorAccountID,
		"data":          json.RawMessage(dataB),
	})
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	_ = s.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: idempKey,
		Payload:        payload,
	})
	_ = tx.Commit(ctx)
}

const baseSelect = `
	SELECT tm.id, a.id, a.uuid, COALESCE(a.email,''), COALESCE(a.phone,''), COALESCE(a.username,''),
	       COALESCE(NULLIF(tm.nickname,''), a.display_name), COALESCE(a.avatar_url,''), tm.status, a.status,
	       tm.department_id, COALESCE(d.name, ''),
	       COALESCE(
	         (SELECT p.name
	            FROM tenant_member_positions mp
	            JOIN tenant_positions p ON p.id = mp.position_id
	           WHERE mp.membership_id = tm.id
	             AND mp.is_primary = true
	             AND p.deleted_at IS NULL
	           ORDER BY mp.id
	           LIMIT 1),
	         NULLIF(tm.title,''),
	         ''
	       ), COALESCE(tm.employee_id,''),
	       to_char(tm.joined_at, 'YYYY-MM-DD HH24:MI'),
	       COALESCE(
	         (SELECT array_agg(r.code) FROM role_assignments ra
	          JOIN roles r ON r.id = ra.role_id
	          WHERE ra.account_id = a.id
	            AND ra.scope_kind IN ('tenant','workspace')
	            AND ra.tenant_id = tm.tenant_id
		            AND ra.deleted_at IS NULL),
	         '{}'
	       ) AS role_codes,
	       COALESCE(tm.metadata, '{}'::jsonb) AS membership_metadata
	FROM tenant_memberships tm
	JOIN accounts a ON a.id = tm.account_id
	LEFT JOIN departments d ON d.id = tm.department_id
`

func decodeContactFields(metadata []byte) ContactFieldsInput {
	var fields ContactFieldsInput
	// metadata 还承载其他成员扩展字段。这里只解码通讯录白名单，避免 Admin API
	// 把整段 metadata 暴露给前端；历史脏值按“未配置”回退，不阻断成员列表。
	_ = json.Unmarshal(metadata, &fields)
	return fields
}

func scanMember(row pgx.Row) (*Member, error) {
	var m Member
	var joinedAt *string
	var roles []string
	var metadata []byte
	if err := row.Scan(&m.MembershipID, &m.AccountID, &m.UUID, &m.Email, &m.Phone, &m.Username,
		&m.DisplayName, &m.AvatarURL, &m.Status, &m.AccountStatus,
		&m.DepartmentID, &m.DepartmentName,
		&m.Title, &m.EmployeeID, &joinedAt, &roles, &metadata); err != nil {
		return nil, err
	}
	if joinedAt != nil {
		m.JoinedAt = *joinedAt
	}
	m.Roles = roles
	m.ContactFields = decodeContactFields(metadata)
	return &m, nil
}

func (s *impl) List(ctx context.Context, tenantID int64, departmentID int64, keyword string, limit, offset int) ([]Member, int64, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	args := []any{tenantID}
	where := `tm.tenant_id = $1 AND tm.deleted_at IS NULL AND a.deleted_at IS NULL`
	if departmentID > 0 {
		args = append(args, departmentID)
		where += " AND tm.department_id = $2"
	}
	if keyword != "" {
		args = append(args, "%"+keyword+"%")
		where += ` AND (COALESCE(NULLIF(tm.nickname,''), a.display_name) ILIKE $` + itoa(len(args)) + ` OR a.phone ILIKE $` + itoa(len(args)) + ` OR a.email ILIKE $` + itoa(len(args)) + `)`
	}

	args = append(args, limit, offset)
	listSelect := strings.Replace(baseSelect, "\n\tFROM tenant_memberships", ", COUNT(*) OVER()\n\tFROM tenant_memberships", 1)
	rows, err := s.pool.Query(ctx, listSelect+`
		WHERE `+where+`
		ORDER BY tm.id DESC
		LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []Member{}
	var total int64
	for rows.Next() {
		var m Member
		var joinedAt *string
		var roles []string
		var metadata []byte
		if err := rows.Scan(&m.MembershipID, &m.AccountID, &m.UUID, &m.Email, &m.Phone, &m.Username,
			&m.DisplayName, &m.AvatarURL, &m.Status, &m.AccountStatus,
			&m.DepartmentID, &m.DepartmentName,
			&m.Title, &m.EmployeeID, &joinedAt, &roles, &metadata, &total); err != nil {
			return nil, 0, err
		}
		if joinedAt != nil {
			m.JoinedAt = *joinedAt
		}
		m.Roles = roles
		m.ContactFields = decodeContactFields(metadata)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := s.pool.QueryRow(ctx, `
		SELECT count(*)
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		WHERE `+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (s *impl) Get(ctx context.Context, tenantID, membershipID int64) (*Member, error) {
	row := s.pool.QueryRow(ctx, baseSelect+`
		WHERE tm.id = $1 AND tm.tenant_id = $2 AND tm.deleted_at IS NULL`, membershipID, tenantID)
	m, err := scanMember(row)
	if err != nil {
		return nil, apperr.ErrNotFound
	}
	return m, nil
}

func (s *impl) Invite(ctx context.Context, tenantID, invitedBy int64, in InviteInput) (*InviteResult, error) {
	phone := strings.TrimSpace(in.Phone)
	email := strings.TrimSpace(in.Email)
	if phone == "" && email == "" {
		return nil, apperr.ErrInvalidParams.Withf("手机号或邮箱至少填一个")
	}
	displayName := strings.TrimSpace(in.DisplayName)
	if displayName == "" {
		if phone != "" {
			displayName = phone
		} else {
			displayName = email
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// F28 §4.4: 租户级 advisory lock 串行化入企, 让下面 "已是成员 + member_limit
	// count→check→insert" 原子。H5 邀请链接群发后并发自助加入是现实场景, 无锁会超卖。
	// 锁命名对齐 runtimeprewarm 惯例: hashtextextended('<ns>:<id>', 0)。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('member_invite:tenant:' || $1::bigint::text, 0))`, tenantID); err != nil {
		return nil, err
	}

	// 1. 找/建 account
	var accountID int64
	var accountUUID string
	if phone != "" {
		_ = tx.QueryRow(ctx, `SELECT id, uuid FROM accounts WHERE phone=$1 AND deleted_at IS NULL`, phone).Scan(&accountID, &accountUUID)
	}
	if accountID == 0 && email != "" {
		_ = tx.QueryRow(ctx, `SELECT id, uuid FROM accounts WHERE LOWER(email)=LOWER($1) AND deleted_at IS NULL`, email).Scan(&accountID, &accountUUID)
	}
	accountReused := accountID > 0
	var initialPassword string
	if accountID == 0 {
		// 后端生成一次性临时密码 (Batch 2B T2B.3 决策)
		pwd, pwdErr := generateTempPassword()
		if pwdErr != nil {
			return nil, pwdErr
		}
		initialPassword = pwd
		ph, hashErr := crypto.HashPassword(initialPassword)
		if hashErr != nil {
			return nil, hashErr
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO accounts (phone, email, display_name, password_hash, password_set_at, status, locale, timezone)
			VALUES (NULLIF($1,''), NULLIF($2,''), $3, $4, now(), 'active', 'zh-CN', 'Asia/Shanghai')
			RETURNING id, uuid`, phone, email, displayName, ph).Scan(&accountID, &accountUUID); err != nil {
			return nil, err
		}
		// admin_accounts 行：让首次登录走强制改密
		if _, err := tx.Exec(ctx, `
			INSERT INTO admin_accounts (account_id, is_platform, must_change_password, last_password_change)
			VALUES ($1, false, true, now())
			ON CONFLICT (account_id) DO NOTHING`, accountID); err != nil {
			return nil, err
		}
	}

	// 2. 已是成员，或曾被移出后等待恢复？
	//
	// tenant_memberships 对 (account_id, tenant_id) 是全表唯一；Remove 只软删原行。
	// 因此重新邀请必须锁住并恢复原 membership，不能忽略软删行后再 INSERT。
	var existingMembershipID int64
	var existingSoftDeleted bool
	err = tx.QueryRow(ctx, `
		SELECT id, deleted_at IS NOT NULL
		  FROM tenant_memberships
		 WHERE account_id=$1 AND tenant_id=$2
		 FOR UPDATE`, accountID, tenantID).Scan(&existingMembershipID, &existingSoftDeleted)
	switch {
	case err == nil && !existingSoftDeleted:
		return nil, apperr.ErrConflict.Withf("该账号已是本租户成员")
	case err == nil:
		// 软删 membership 在本事务后续原地恢复。
	case errors.Is(err, pgx.ErrNoRows):
		existingMembershipID = 0
	default:
		return nil, err
	}

	if s.quota != nil {
		var activeCount int64
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM tenant_memberships
			 WHERE tenant_id=$1 AND status='active' AND deleted_at IS NULL`, tenantID).Scan(&activeCount); err != nil {
			return nil, err
		}
		if err := s.quota.EnsureWithinLimit(ctx, tenantID, "member_limit", activeCount, 1); err != nil {
			return nil, err
		}
	}

	departmentID, err := resolveDepartmentID(ctx, tx, tenantID, in.DepartmentID)
	if err != nil {
		return nil, err
	}

	// 3. 新建或恢复 membership
	membershipID := existingMembershipID
	membershipReactivated := existingMembershipID > 0
	// invited_by = NULL when invitedBy<=0 (system / 测试场景)，避免 FK 0->accounts 错误
	var invitedByParam any
	if invitedBy > 0 {
		invitedByParam = invitedBy
	}
	if membershipReactivated {
		if _, err := tx.Exec(ctx, `
			UPDATE tenant_memberships
			   SET department_id=$3,
			       title=NULLIF($4,''),
			       employee_id=NULLIF($5,''),
			       nickname=NULLIF($6,''),
			       status='active',
			       joined_at=now(),
			       invited_by=$7,
			       updated_at=now(),
			       deleted_at=NULL
			 WHERE id=$1 AND tenant_id=$2`,
			membershipID, tenantID, departmentID, in.Title, in.EmployeeID, displayName, invitedByParam); err != nil {
			return nil, err
		}
		// 职位属于一次任职周期；重新邀请后只采用本次随后显式分配的职位。
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_member_positions WHERE membership_id=$1`, membershipID); err != nil {
			return nil, err
		}
	} else {
		if err := tx.QueryRow(ctx, `
			INSERT INTO tenant_memberships (account_id, tenant_id, department_id, title, employee_id, nickname, status, joined_at, invited_by)
			VALUES ($1, $2, $3, NULLIF($4,''), NULLIF($5,''), NULLIF($6,''), 'active', now(), $7)
			RETURNING id`,
			accountID, tenantID, departmentID, in.Title, in.EmployeeID, displayName, invitedByParam).Scan(&membershipID); err != nil {
			return nil, err
		}
	}

	// 4. M1 §3.3.2: 邀请只建 membership 不自动发角色。
	//    新成员可以登 zhiban-app, 但不能登 Admin Web (除非显式分配角色)。
	//    如果调用方在 InviteInput.RoleCode 显式指定了角色, 只允许分配当前租户内角色。
	//    codex F28 第 4 轮 P2: 显式指定的角色查不到时必须回滚报错, 不允许静默吞掉
	//    ErrNoRows 提交一个"在 /auth/me 看不到租户"的无角色 membership。
	if roleCode := strings.TrimSpace(in.RoleCode); roleCode != "" {
		var roleID int64
		if err := tx.QueryRow(ctx, `
			SELECT id FROM roles
			 WHERE scope_kind='tenant' AND code=$1
			   AND tenant_id = $2
			   AND deleted_at IS NULL
			 LIMIT 1`, roleCode, tenantID).Scan(&roleID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, apperr.ErrInternal.Withf("角色 %s 在租户 %d 内不存在（种子缺失或已删除）", roleCode, tenantID)
			}
			return nil, err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO role_assignments (account_id, role_id, scope_kind, tenant_id)
			VALUES ($1, $2, 'tenant', $3)`, accountID, roleID, tenantID); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	// NOTIFY + audit (best-effort 短 tx)。actor 允许被 F28 token join 覆盖为
	// system/invite_token（invited_by 归因保留在 membership 行与 data 内）。
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, accountID))
	auditActorKind := in.AuditActorKind
	if auditActorKind == "" {
		auditActorKind = "tenant_admin"
	}
	auditActorID := invitedBy
	if in.AuditActorAccountID != nil {
		auditActorID = *in.AuditActorAccountID
	}
	auditIdempotencyKey := fmt.Sprintf("member.invited:%d:%d", tenantID, accountID)
	if membershipReactivated {
		// 同一 membership 可跨多个任职周期恢复；每次重新邀请都必须留下独立审计事件。
		auditIdempotencyKey = fmt.Sprintf("member.reinvited:%d:%d:%d", tenantID, membershipID, time.Now().UnixNano())
	}
	s.auditAfterAs(ctx, "audit.member.invited", tenantID, auditActorID,
		auditActorKind, in.AuditActingAs,
		auditIdempotencyKey,
		map[string]any{
			"resource_kind":          "tenant_membership",
			"resource_uuid":          accountUUID,
			"target_account_id":      accountID,
			"membership_id":          membershipID,
			"display_name":           displayName,
			"phone_present":          phone != "",
			"account_reused":         accountReused,
			"membership_reactivated": membershipReactivated,
			"department_id":          departmentID,
			"invited_by":             invitedBy,
		})

	m, err := s.Get(ctx, tenantID, membershipID)
	if err != nil {
		return nil, err
	}
	return &InviteResult{
		Member:               m,
		AccountReused:        accountReused,
		AdminInitialPassword: initialPassword, // 复用账号时为空
	}, nil
}

func (s *impl) Update(ctx context.Context, tenantID, actorAccountID, membershipID int64, in UpdateInput) (*Member, error) {
	cur, err := s.Get(ctx, tenantID, membershipID)
	if err != nil {
		return nil, err
	}
	title := cur.Title
	employeeID := cur.EmployeeID
	requestedDepartmentID := cur.DepartmentID
	status := cur.Status
	var displayNameParam any
	if in.DisplayName != nil {
		displayNameParam = strings.TrimSpace(*in.DisplayName)
	}
	if in.Title != nil {
		title = *in.Title
	}
	if in.EmployeeID != nil {
		employeeID = *in.EmployeeID
	}
	if in.DepartmentID != nil {
		requestedDepartmentID = in.DepartmentID
	}
	if in.Status != nil && *in.Status != "" {
		status = *in.Status
	}
	// 把用户友好的 "disabled" 映射成 schema CHECK 允许的 "suspended"
	// （schema enum: invited / active / suspended / left；详见 0001_init_identity.up.sql）
	if status == "disabled" {
		status = "suspended"
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	departmentID, err := resolveDepartmentID(ctx, tx, tenantID, requestedDepartmentID)
	if err != nil {
		return nil, err
	}
	if status != "active" {
		if err := tenantadminguard.EnsureMemberStatusChangeAllowed(
			ctx, tx, tenantID, actorAccountID, cur.AccountID, status,
		); err != nil {
			return nil, err
		}
	}
	tag, err := tx.Exec(ctx, `
		UPDATE tenant_memberships
		SET nickname=CASE WHEN $1::text IS NULL THEN nickname ELSE NULLIF($1::text,'') END,
		    title=NULLIF($2,''), employee_id=NULLIF($3,''), department_id=$4, status=$5, updated_at=now()
		WHERE id=$6 AND tenant_id=$7 AND deleted_at IS NULL`,
		displayNameParam, title, employeeID, departmentID, status, membershipID, tenantID)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != 1 {
		return nil, apperr.ErrNotFound
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	var imRevokeErr error
	if status != "active" && s.revokeIMSessions != nil {
		imRevokeErr = s.revokeIMSessions(ctx, tenantID, cur.UUID)
	}
	// NOTIFY + audit topic：根据 status 转换决定 disabled / enabled / updated
	// status="suspended" 对外语义即"已禁用"；UI / API 接受 'disabled' 别名（service 已做映射）
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, cur.AccountID))
	topic := "audit.member.updated"
	if cur.Status != status {
		switch status {
		case "suspended":
			topic = "audit.member.disabled"
		case "active":
			if cur.Status == "suspended" {
				topic = "audit.member.enabled"
			}
		}
	}
	s.auditAfter(ctx, topic, tenantID, actorAccountID,
		fmt.Sprintf("%s:%d:%d:%d", topic, tenantID, membershipID, cur.AccountID),
		map[string]any{
			"resource_kind":     "tenant_membership",
			"resource_uuid":     cur.UUID,
			"membership_id":     membershipID,
			"target_account_id": cur.AccountID,
			"old_status":        cur.Status,
			"new_status":        status,
		})
	if imRevokeErr != nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, "membership.im_session_revoke_failed").Wrap(imRevokeErr)
	}
	return s.Get(ctx, tenantID, membershipID)
}

func (s *impl) Remove(ctx context.Context, tenantID, actorAccountID, membershipID int64) error {
	// 软删 membership；同步吊销该账号在本租户的角色
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var accountID int64
	var accountUUID string
	if err := tx.QueryRow(ctx, `
		SELECT tm.account_id, a.uuid::text
		  FROM tenant_memberships tm
		  JOIN accounts a ON a.id=tm.account_id
		 WHERE tm.id=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL`,
		membershipID, tenantID).Scan(&accountID, &accountUUID); err != nil {
		return apperr.ErrNotFound
	}
	if err := tenantadminguard.EnsureMemberRemovalAllowed(
		ctx, tx, tenantID, actorAccountID, accountID,
	); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `
		UPDATE tenant_memberships
		   SET deleted_at=now(), status='left', updated_at=now()
		 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		membershipID, tenantID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return apperr.ErrNotFound
	}
	if _, err := tx.Exec(ctx, `
		UPDATE role_assignments SET deleted_at=now()
		WHERE account_id=$1 AND tenant_id=$2 AND scope_kind IN ('tenant','workspace') AND deleted_at IS NULL`,
		accountID, tenantID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+strconv.FormatInt(accountID, 10)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, accountID))
	s.auditAfter(ctx, "audit.member.removed", tenantID, actorAccountID,
		fmt.Sprintf("member.removed:%d:%d", tenantID, membershipID),
		map[string]any{
			"resource_kind":     "tenant_membership",
			"membership_id":     membershipID,
			"target_account_id": accountID,
		})
	if s.revokeIMSessions != nil {
		if err := s.revokeIMSessions(ctx, tenantID, accountUUID); err != nil {
			return apperr.New(apperr.UpstreamUnavailable, "membership.im_session_revoke_failed").Wrap(err)
		}
	}
	return nil
}

// UpdateContactFields M2 §5.3: 写 tenant_memberships.metadata 通讯录子键。
//
// 实现策略: 用 jsonb || 浅合并; field_mask / position_label_override 给出即覆盖整个 key,
// 未给出的 key 保留。
func (s *impl) UpdateContactFields(ctx context.Context, tenantID, membershipID int64, in ContactFieldsInput) error {
	patch := map[string]any{}
	if in.HiddenInContacts != nil {
		patch["hidden_in_contacts"] = *in.HiddenInContacts
	}
	if in.AllowInviteToGroup != nil {
		patch["allow_invite_to_group"] = *in.AllowInviteToGroup
	}
	if in.FieldMask != nil {
		// 校验字段值
		for k, v := range in.FieldMask {
			switch k {
			case "phone", "email", "title":
			default:
				return apperr.ErrInvalidParams.Withf("field_mask 不允许的字段: %s", k)
			}
			switch v {
			case "all", "department", "self", "hidden":
			default:
				return apperr.ErrInvalidParams.Withf("field_mask.%s 非法值: %s", k, v)
			}
		}
		patch["field_mask"] = in.FieldMask
	}
	if in.PositionLabelOverride != nil {
		if *in.PositionLabelOverride == "" {
			patch["position_label_override"] = nil
		} else {
			patch["position_label_override"] = *in.PositionLabelOverride
		}
	}
	if len(patch) == 0 {
		return nil
	}
	patchJSON, _ := jsonMarshal(patch)
	var accountID int64
	err := s.pool.QueryRow(ctx, `
		UPDATE tenant_memberships
		SET metadata = COALESCE(metadata,'{}'::jsonb) || $1::jsonb,
		    updated_at = now()
		WHERE id=$2 AND tenant_id=$3 AND deleted_at IS NULL
		RETURNING account_id`,
		string(patchJSON), membershipID, tenantID).Scan(&accountID)
	if err == pgx.ErrNoRows {
		return apperr.ErrNotFound
	}
	if err != nil {
		return err
	}
	// M2 §8: NOTIFY config_change membership:<tid>:<account_id>
	if _, nerr := s.pool.Exec(ctx, `SELECT pg_notify('config_change', $1)`,
		"membership:"+strconv.FormatInt(tenantID, 10)+":"+strconv.FormatInt(accountID, 10)); nerr != nil {
		_ = nerr
	}
	return nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	negative := false
	if n < 0 {
		negative = true
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if negative {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
