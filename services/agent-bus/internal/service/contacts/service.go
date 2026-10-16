package contacts

import (
	"context"
	"encoding/json"
	"errors"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Service 是 M2 通讯录的对外接口。
//
// 所有方法都需要 caller (含 act_scope=tenant 的租户与部门信息)。
// 不读 ctx.Value, 由 transport 层显式注入。
type Service interface {
	// Tree 返回组织树 + 每个部门的 human/agent 计数 (M2 §4.1 GET /contacts/tree)。
	Tree(ctx context.Context, caller CallerCtx) ([]DepartmentNode, error)

	// List 按部门 / kind / 关键词列出联系人 (M2 §4.1 GET /contacts)。
	List(ctx context.Context, caller CallerCtx, params ListContactsParams) (ListContactsResp, error)

	// Agents 返回数字员工广场, 按 source 分段 (M2 §4.1 GET /contacts/agents)。
	Agents(ctx context.Context, caller CallerCtx, params ListAgentsParams) (AgentsBySource, error)

	// Search 全局搜索 human + agent。
	Search(ctx context.Context, caller CallerCtx, req SearchReq) (SearchResp, error)

	// GetMember 单条 human 详情, 已按 field_mask 裁剪。
	GetMember(ctx context.Context, caller CallerCtx, accountUUID string) (*HumanContact, error)

	// GetAgent 单条 agent 详情。
	GetAgent(ctx context.Context, caller CallerCtx, agentUUID string) (*AgentContact, error)

	// Policy 当前租户的 contact_policies。
	Policy(ctx context.Context, caller CallerCtx) (ContactPolicy, error)

	// CanCreateGroup 拉群预检 (M2 §4.1 POST /contacts/can-create-group); 不创建任何 room。
	CanCreateGroup(ctx context.Context, caller CallerCtx, req CanCreateGroupReq) (CanCreateGroupResp, error)

	// IsTenantAdmin 判断 caller 在当前租户是否拥有 tenant.admin 角色。
	IsTenantAdmin(ctx context.Context, accountID, tenantID int64) (bool, error)

	// ResolveCallerDepartment 兜底解析 caller 真实所属部门 (P1-B 修复):
	// 普通 tenant token 没有 act_workspace_id, 这里从 tenant_memberships.department_id 取。
	// 找不到时返回 0 (无部门归属), 不报错。
	ResolveCallerDepartment(ctx context.Context, accountID, tenantID int64) (int64, error)

	// AssertAgentVisible Batch 2D T2D.3-A: 给 chat / room / 其它"基于 agent_uuid 二次访问"
	// 入口收口可见性。判定与 GET /contacts/agents 100% 一致 (走同一条 IsAgentVisible
	// 路径), 用户拿到 agent_uuid 也无法绕过 visibility_override / contact_enabled /
	// workspace 域 / 平台 agent 隐藏 等隐藏策略。
	//
	// 内部自动 ResolveCallerDepartment, caller 不需要预查; 命中可见 → nil;
	// 不可见 / 不存在统一返 apperr.ErrForbidden ("agent not visible"), **不区分**
	// "不存在" 与 "存在但隐藏", 防止枚举 agent_uuid。
	AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error

	// PrewarmTargets doc-10 登录预热: 返回 caller 可见、已 published/contact_enabled、
	// 且已绑定 runtime_environment_id 的数字员工 (复用同一可见性路径, 见 prewarm_targets.go)。
	PrewarmTargets(ctx context.Context, caller CallerCtx) ([]PrewarmTarget, error)
}

type impl struct {
	conversationCapabilities ConversationCapabilitiesResolver
	pool                     *pgxpool.Pool
	policyCache              *policyCache
	avatarURLResolver        AvatarURLResolver
}

// AvatarURLResolver converts persisted avatar references into client-loadable
// URLs. It is intentionally injected from cmd/bus because contacts.Service must
// not know object-store or media signing details.
type AvatarURLResolver func(ctx context.Context, tenantID int64, raw string) string

// New 构造默认实现, 自带 5min TTL 的 policy 缓存。
// 缓存通过 NOTIFY listener (NewPolicyListener) 与 admin 写路径联动失效。
func New(pool *pgxpool.Pool) Service {
	return &impl{pool: pool, policyCache: newPolicyCache(0)}
}

// SetAvatarURLResolverOnService wires optional avatar URL resolving for Bus
// client DTOs. It is a no-op for non-default implementations used in tests.
func SetAvatarURLResolverOnService(svc Service, resolver AvatarURLResolver) {
	if im, ok := svc.(*impl); ok {
		im.avatarURLResolver = resolver
	}
}

// InvalidatePolicy 由 listener 调用, 失效单个租户的 policy 缓存。
//
// 暴露在 Service 接口之外, 避免被业务路径误用。
func (s *impl) InvalidatePolicy(tenantID int64) {
	if s == nil || s.policyCache == nil {
		return
	}
	if tenantID == 0 {
		s.policyCache.InvalidateAll()
		return
	}
	s.policyCache.Invalidate(tenantID)
}

// =====================================================
// Policy
// =====================================================

func (s *impl) Policy(ctx context.Context, caller CallerCtx) (ContactPolicy, error) {
	if caller.TenantID <= 0 {
		return ContactPolicy{}, apperr.ErrForbidden.Withf("missing tenant")
	}
	return s.policy(ctx, caller.TenantID)
}

func (s *impl) policy(ctx context.Context, tenantID int64) (ContactPolicy, error) {
	if p, ok := s.policyCache.Get(tenantID); ok {
		return p, nil
	}
	p, err := s.fetchPolicy(ctx, tenantID)
	if err != nil {
		return ContactPolicy{}, err
	}
	s.policyCache.Put(tenantID, p)
	return p, nil
}

func (s *impl) fetchPolicy(ctx context.Context, tenantID int64) (ContactPolicy, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT tenant_id, default_landing,
		       default_show_phone, default_show_email, default_show_title,
		       search_scope, who_can_create_group_with_agent,
		       agents_default_invitable, humans_default_invitable, show_platform_agents
		FROM contact_policies WHERE tenant_id=$1`, tenantID)
	var p ContactPolicy
	var phone, email, title string
	if err := row.Scan(&p.TenantID, &p.DefaultLanding, &phone, &email, &title,
		&p.SearchScope, &p.WhoCanCreateGroupWithAgent,
		&p.AgentsDefaultInvitable, &p.HumansDefaultInvitable, &p.ShowPlatformAgents); err != nil {
		if err == pgx.ErrNoRows {
			// 兜底: 使用 schema 默认值, 避免新建租户尚未 seed 时 client 502。
			return ContactPolicy{
				TenantID:                   tenantID,
				DefaultLanding:             "org_tree",
				DefaultShowPhone:           FieldDepartment,
				DefaultShowEmail:           FieldDepartment,
				DefaultShowTitle:           FieldAll,
				SearchScope:                "tenant",
				WhoCanCreateGroupWithAgent: "any_member",
				AgentsDefaultInvitable:     false,
				HumansDefaultInvitable:     true,
				ShowPlatformAgents:         true,
			}, nil
		}
		return ContactPolicy{}, err
	}
	p.DefaultShowPhone = FieldVisibility(phone)
	p.DefaultShowEmail = FieldVisibility(email)
	p.DefaultShowTitle = FieldVisibility(title)
	return p, nil
}

// =====================================================
// Tree
// =====================================================

func (s *impl) Tree(ctx context.Context, caller CallerCtx) ([]DepartmentNode, error) {
	if caller.TenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT d.id, d.uuid, d.parent_id, d.path, d.depth, d.name,
		       (SELECT count(*) FROM tenant_memberships tm
		         WHERE tm.department_id=d.id AND tm.deleted_at IS NULL
		           AND COALESCE((tm.metadata->>'hidden_in_contacts')::boolean, false) = false) AS humans,
		       (SELECT count(*) FROM digital_employees de
		         WHERE de.workspace_id=d.id AND de.deleted_at IS NULL
		           AND de.status='published' AND de.contact_enabled=true
		           AND de.visibility IN ('workspace','tenant')) AS agents
		FROM departments d
		WHERE d.tenant_id=$1 AND d.deleted_at IS NULL
		ORDER BY d.path, d.sort_order, d.id`, caller.TenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	type raw struct {
		ID         int64
		UUID       string
		ParentID   *int64
		Path       string
		Depth      int
		Name       string
		HumanCount int
		AgentCount int
	}
	idToUUID := map[int64]string{}
	all := []raw{}
	for rows.Next() {
		var r raw
		var depth int16
		if err := rows.Scan(&r.ID, &r.UUID, &r.ParentID, &r.Path, &depth, &r.Name,
			&r.HumanCount, &r.AgentCount); err != nil {
			return nil, err
		}
		r.Depth = int(depth)
		all = append(all, r)
		idToUUID[r.ID] = r.UUID
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// 构树 (按 parent_id; 根=parent_id IS NULL 或 parent 不在租户内)
	nodeByID := map[int64]*DepartmentNode{}
	for i := range all {
		r := all[i]
		nodeByID[r.ID] = &DepartmentNode{
			ID: r.UUID, Name: r.Name, Path: r.Path, Depth: r.Depth,
			HumanCount: r.HumanCount, AgentCount: r.AgentCount,
		}
	}
	roots := []DepartmentNode{}
	for _, r := range all {
		n := nodeByID[r.ID]
		if r.ParentID != nil {
			if p, ok := nodeByID[*r.ParentID]; ok {
				n.ParentID = p.ID
				p.Children = append(p.Children, *n)
				continue
			}
		}
		roots = append(roots, *n)
	}
	// HumanCount/AgentCount 改成"这个部门 + 所有子部门"的总数，不再只算直属
	//这一级——只挂了子部门、自己没有直属成员的"文件夹"部门，之前会被误判成
	// 没人（sidebar 判断是否展开/是否在快捷列表里都用了这个数，直属数=0 时
	// 会把明明有下级成员的部门当空部门处理）。按 parent_id 建子节点表递归汇总，
	// 不能用上面 nodeByID[x].Children（那份是浅拷贝，只有 1 层，见上面注释）。
	childIDs := map[int64][]int64{}
	rawByID := map[int64]raw{}
	for _, r := range all {
		rawByID[r.ID] = r
		if r.ParentID != nil {
			childIDs[*r.ParentID] = append(childIDs[*r.ParentID], r.ID)
		}
	}
	subtreeMemo := map[int64][2]int{}
	var subtreeSum func(id int64) [2]int
	subtreeSum = func(id int64) [2]int {
		if v, ok := subtreeMemo[id]; ok {
			return v
		}
		r := rawByID[id]
		sum := [2]int{r.HumanCount, r.AgentCount}
		for _, cid := range childIDs[id] {
			c := subtreeSum(cid)
			sum[0] += c[0]
			sum[1] += c[1]
		}
		subtreeMemo[id] = sum
		return sum
	}
	for _, r := range all {
		sum := subtreeSum(r.ID)
		nodeByID[r.ID].HumanCount = sum[0]
		nodeByID[r.ID].AgentCount = sum[1]
	}

	// 因为 children append 的是 value, 需要把 children 链回填 (浅; 仅 1 层够 M2; 多层用 parent_id 字符串)
	// 简化: 客户端可按 parentId 自行嵌套, 这里同时返回 path 便于前端理解层级。
	// 重新输出"扁平 + 嵌套"两种太啰嗦; M2 客户端按 parentId+path 渲染, 我们这里直接返回所有节点的扁平列表。
	flat := make([]DepartmentNode, 0, len(all))
	for _, r := range all {
		n := nodeByID[r.ID]
		// 不输出 children (避免 value-copy 造成的 children 不一致)
		n.Children = nil
		flat = append(flat, *n)
	}
	_ = roots
	return flat, nil
}

// =====================================================
// List (统一列表)
// =====================================================

func (s *impl) List(ctx context.Context, caller CallerCtx, params ListContactsParams) (ListContactsResp, error) {
	if caller.TenantID <= 0 {
		return ListContactsResp{}, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return ListContactsResp{}, err
	}
	limit := params.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	kind := params.Kind
	if kind == "" {
		kind = "all"
	}

	var deptID int64
	var deptPath string
	if params.DepartmentID != "" {
		var err error
		deptID, deptPath, err = s.deptByUUID(ctx, caller.TenantID, params.DepartmentID)
		if err != nil {
			return ListContactsResp{}, err
		}
	}
	_ = deptPath // not used directly here; agent visibility handled in fetchAgents

	out := ListContactsResp{Items: []any{}}

	if kind == "human" || kind == "all" {
		humans, err := s.fetchHumans(ctx, caller, policy, deptID, params.Q, limit)
		if err != nil {
			return ListContactsResp{}, err
		}
		for i := range humans {
			out.Items = append(out.Items, humans[i])
		}
	}
	if kind == "agent" || kind == "all" {
		agents, err := s.fetchAgentsForList(ctx, caller, policy, deptID, params.Q, limit, "")
		if err != nil {
			return ListContactsResp{}, err
		}
		for i := range agents {
			out.Items = append(out.Items, agents[i])
		}
	}
	// kind=all 时上面 human + agent 各拿了一份 limit, 合并后裁回 limit, 避免越界。
	// cursor 暂未实现 (M2 §4.1 标注为可选), 收到非空 cursor 不报错只忽略。
	if len(out.Items) > limit {
		out.Items = out.Items[:limit]
	}
	return out, nil
}

func (s *impl) deptByUUID(ctx context.Context, tenantID int64, uuid string) (int64, string, error) {
	var id int64
	var path string
	err := s.pool.QueryRow(ctx,
		`SELECT id, path FROM departments WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID).Scan(&id, &path)
	if err == pgx.ErrNoRows {
		return 0, "", apperr.ErrNotFound.Withf("department not found")
	}
	if err != nil {
		return 0, "", err
	}
	return id, path, nil
}

// =====================================================
// Humans
// =====================================================

type humanRow struct {
	AccID       int64
	AccUUID     string
	DisplayName string
	AvatarURL   string
	Phone       string
	Email       string
	Title       string
	DeptID      *int64
	DeptUUID    *string
	DeptName    *string
	MetaJSON    []byte
}

func (s *impl) fetchHumans(ctx context.Context, caller CallerCtx, policy ContactPolicy, deptID int64, q string, limit int) ([]HumanContact, error) {
	args := []any{caller.TenantID}
	where := []string{
		"tm.tenant_id = $1",
		"tm.deleted_at IS NULL",
		"tm.status = 'active'",
		"a.deleted_at IS NULL",
		"COALESCE((tm.metadata->>'hidden_in_contacts')::boolean, false) = false",
	}
	if deptID > 0 {
		args = append(args, deptID)
		where = append(where, "tm.department_id = $"+itoa(len(args)))
	}
	if q != "" {
		args = append(args, "%"+strings.ToLower(q)+"%")
		where = append(where,
			"(LOWER(a.display_name) LIKE $"+itoa(len(args))+
				" OR LOWER(COALESCE(tm.nickname,'')) LIKE $"+itoa(len(args))+
				" OR LOWER(COALESCE(a.email,'')) LIKE $"+itoa(len(args))+
				" OR COALESCE(a.phone,'') LIKE $"+itoa(len(args))+")")
	}
	args = append(args, limit)
	sql := `
		SELECT a.id, a.uuid, COALESCE(NULLIF(tm.nickname,''), a.display_name) AS display_name,
		       COALESCE(a.avatar_url,''), COALESCE(a.phone,''), COALESCE(a.email,''),
		       COALESCE(tm.title,''),
		       d.id, d.uuid, d.name,
		       tm.metadata
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		LEFT JOIN departments d ON d.id = tm.department_id AND d.deleted_at IS NULL
		WHERE ` + strings.Join(where, " AND ") + `
		ORDER BY display_name
		LIMIT $` + itoa(len(args))
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HumanContact{}
	for rows.Next() {
		var r humanRow
		if err := rows.Scan(&r.AccID, &r.AccUUID, &r.DisplayName, &r.AvatarURL,
			&r.Phone, &r.Email, &r.Title,
			&r.DeptID, &r.DeptUUID, &r.DeptName, &r.MetaJSON); err != nil {
			return nil, err
		}
		out = append(out, s.buildHuman(ctx, caller, policy, r))
	}
	return out, rows.Err()
}

func (s *impl) buildHuman(ctx context.Context, caller CallerCtx, policy ContactPolicy, r humanRow) HumanContact {
	meta := MembershipMeta{}
	if len(r.MetaJSON) > 0 {
		_ = json.Unmarshal(r.MetaJSON, &meta)
	}
	mask := ResolveMask(meta.FieldMask, policy)
	sameAccount := r.AccID == caller.AccountID
	sameDept := r.DeptID != nil && caller.DepartmentID > 0 && *r.DeptID == caller.DepartmentID
	subtitleRaw := r.Title
	if meta.PositionLabelOverride != nil {
		subtitleRaw = *meta.PositionLabelOverride
	}
	fields, subtitle := ApplyMask(r.Phone, r.Email, subtitleRaw, mask, sameAccount, sameDept)

	hc := HumanContact{
		Kind:            "human",
		ID:              r.AccUUID,
		DisplayName:     r.DisplayName,
		AvatarURL:       s.resolveAvatarURL(ctx, caller.TenantID, r.AvatarURL),
		Subtitle:        subtitle,
		Fields:          fields,
		Presence:        "offline",
		Badges:          []string{},
		CanChat:         !sameAccount,
		CanInviteToRoom: CanInviteHuman(meta.AllowInviteToGroup, policy),
	}
	if sameAccount {
		hc.ChatDisabledReason = "self"
	}
	if r.DeptUUID != nil {
		hc.DepartmentID = *r.DeptUUID
	}
	if r.DeptName != nil {
		hc.DepartmentName = *r.DeptName
	}
	return hc
}

// =====================================================
// Agents (列表 / 广场)
// =====================================================

type agentRow struct {
	ID                 int64
	UUID               string
	Name               string
	AvatarURL          string
	Intro              string
	PositionLabel      string
	BadgesJSON         []byte
	Source             string
	Status             string
	Visibility         string
	ContactEnabled     bool
	AllowInviteToGroup bool
	SupportsGroupChat  bool
	TenantID           *int64
	WorkspaceID        *int64
	WorkspacePath      *string
	WorkspaceUUID      *string
	WorkspaceName      *string
	CreatorID          *int64
	OverrideHidden     bool
	Skills             []AgentCapabilitySummary
	Apps               []AgentCapabilitySummary
	KnowledgeBases     []AgentKnowledgeBaseSummary
}

// scanAgentRow 把 agentsBaseSelect 那 20 列扫到 agentRow。
// runAgentRows / checkAgentForInvite / 任何后续 caller 都必须走这个 helper,
// 严禁内联 row.Scan(...) — 2026-06-02 codex 返修起因就是 checkAgentForInvite 内联 Scan
// 漏了 &r.Intro 一列, 全部行类型错位 Scan 失败 → published+visible+invitable 的租户副本
// 也被报 agent_not_visible。
type agentRowScanner interface {
	Scan(dest ...any) error
}

func scanAgentRow(s agentRowScanner) (agentRow, error) {
	var r agentRow
	err := s.Scan(&r.ID, &r.UUID, &r.Name, &r.AvatarURL, &r.Intro, &r.PositionLabel,
		&r.BadgesJSON, &r.Source, &r.Status, &r.Visibility,
		&r.ContactEnabled, &r.AllowInviteToGroup, &r.SupportsGroupChat,
		&r.TenantID, &r.WorkspaceID, &r.WorkspacePath, &r.WorkspaceUUID, &r.WorkspaceName,
		&r.CreatorID, &r.OverrideHidden)
	return r, err
}

// agentsBaseSelect 统一从 digital_employees 取 M2 关心的列, 并 join workspace 部门 + visibility_overrides。
const agentsBaseSelect = `
	SELECT de.id, de.uuid, de.name, COALESCE(de.avatar_url,''),
	       COALESCE(de.intro,''), COALESCE(de.position_label,''),
	       de.badges, de.source, de.status, de.visibility,
	       de.contact_enabled, de.allow_invite_to_group, de.supports_group_chat,
	       de.tenant_id, de.workspace_id, d.path, d.uuid, d.name,
	       de.creator_id,
	       COALESCE(ov.hidden, false) AS override_hidden
	FROM digital_employees de
	LEFT JOIN departments d ON d.id = de.workspace_id AND d.deleted_at IS NULL
	LEFT JOIN digital_employee_visibility_overrides ov
	       ON ov.digital_employee_id = de.id AND ov.tenant_id = $1`

// fetchAgentsForList 用于 GET /contacts (混排) — 仅在 caller 租户视角下取可见 agents,
// 可选限定 workspace 部门 (deptID>0)。
func (s *impl) fetchAgentsForList(ctx context.Context, caller CallerCtx, policy ContactPolicy, deptID int64, q string, limit int, _sourceFilter string) ([]AgentContact, error) {
	args := []any{caller.TenantID}
	where := []string{
		"de.deleted_at IS NULL",
		"de.status = 'published'",
		"de.contact_enabled = true",
		// caller 租户内 (含平台预置)
		"(de.tenant_id = $1 OR (de.tenant_id IS NULL AND de.source = 'platform' AND de.visibility = 'platform'))",
	}
	if deptID > 0 {
		// 过滤到该部门 workspace 或祖先 workspace 的 workspace 可见 agent
		args = append(args, deptID)
		where = append(where, "de.workspace_id = $"+itoa(len(args)))
	}
	if q != "" {
		args = append(args, "%"+strings.ToLower(q)+"%")
		where = append(where,
			"(LOWER(de.name) LIKE $"+itoa(len(args))+
				" OR LOWER(COALESCE(de.intro,'')) LIKE $"+itoa(len(args))+")")
	}
	args = append(args, limit)
	sql := agentsBaseSelect + " WHERE " + strings.Join(where, " AND ") +
		" ORDER BY de.name LIMIT $" + itoa(len(args))
	return s.runAgentRows(ctx, caller, policy, sql, args)
}

func (s *impl) runAgentRows(ctx context.Context, caller CallerCtx, policy ContactPolicy, sql string, args []any) ([]AgentContact, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	deptPath, err := s.resolveCallerDeptPath(ctx, caller.DepartmentID)
	if err != nil {
		return nil, err
	}
	callerVis := CallerVisibility{
		AccountID:          caller.AccountID,
		TenantID:           caller.TenantID,
		DepartmentPath:     deptPath,
		ShowPlatformAgents: policy.ShowPlatformAgents,
	}

	visibleRows := []agentRow{}
	for rows.Next() {
		r, err := scanAgentRow(rows)
		if err != nil {
			return nil, err
		}
		in := AgentVisibilityInput{
			Status: r.Status, ContactEnabled: r.ContactEnabled,
			Source: r.Source, Visibility: r.Visibility,
			OverrideHidden: r.OverrideHidden,
		}
		if r.TenantID != nil {
			in.TenantID = *r.TenantID
		}
		if r.WorkspaceID != nil {
			in.WorkspaceID = *r.WorkspaceID
		}
		if r.WorkspacePath != nil {
			in.WorkspacePath = *r.WorkspacePath
		}
		if r.CreatorID != nil {
			in.CreatorID = *r.CreatorID
		}
		visible, _ := IsAgentVisible(in, callerVis)
		if !visible {
			continue
		}
		visibleRows = append(visibleRows, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.hydrateAgentCapabilities(ctx, visibleRows); err != nil {
		return nil, err
	}
	capabilities := map[string]domagent.ConversationCapabilities{}
	if s.conversationCapabilities != nil {
		ids := make([]string, 0, len(visibleRows))
		for _, row := range visibleRows {
			ids = append(ids, row.UUID)
		}
		var err error
		capabilities, err = s.conversationCapabilities.ConversationCapabilities(ctx, caller.TenantID, ids)
		if err != nil {
			return nil, err
		}
	}
	out := make([]AgentContact, 0, len(visibleRows))
	for _, r := range visibleRows {
		contact := s.buildAgent(ctx, caller.TenantID, r, policy)
		contact.ConversationCapabilities = capabilities[r.UUID]
		out = append(out, contact)
	}
	return out, nil
}

func (s *impl) buildAgent(ctx context.Context, tenantID int64, r agentRow, policy ContactPolicy) AgentContact {
	badges := []string{}
	if len(r.BadgesJSON) > 0 {
		_ = json.Unmarshal(r.BadgesJSON, &badges)
	}
	if badges == nil {
		badges = []string{}
	}
	ac := AgentContact{
		Kind:            "agent",
		ID:              r.UUID,
		DisplayName:     r.Name,
		AvatarURL:       s.resolveAvatarURL(ctx, tenantID, r.AvatarURL),
		Subtitle:        r.Intro,
		PositionLabel:   r.PositionLabel,
		Source:          r.Source,
		Skills:          s.resolveCapabilityIconURLs(ctx, tenantID, r.Skills),
		Apps:            s.resolveCapabilityIconURLs(ctx, tenantID, r.Apps),
		KnowledgeBases:  r.KnowledgeBases,
		Badges:          badges,
		Presence:        "offline",
		LifecycleStatus: r.Status,
		CanChat:         true,
		// ADR-0052: 平台员工是租户可直接使用的共享员工；可见性通过
		// IsAgentVisible/租户 override 控制，拉群能力继续服从员工与租户策略。
		CanInviteToRoom:   isInvitableAgentContact(r, policy),
		SupportsGroupChat: r.SupportsGroupChat,
	}
	if r.WorkspaceUUID != nil {
		ac.DepartmentID = *r.WorkspaceUUID
	}
	if r.WorkspaceName != nil {
		ac.DepartmentName = *r.WorkspaceName
	}
	return ac
}

// isInvitableAgentContact 是 ContactDTO.canInviteToRoom 的口径。
// 群聊预检 CanCreateGroup.checkAgentForInvite 用同一组规则手写, 两边任一改就同步改。
func isInvitableAgentContact(r agentRow, policy ContactPolicy) bool {
	return CanInviteAgent(r.AllowInviteToGroup, policy)
}

func (s *impl) resolveAvatarURL(ctx context.Context, tenantID int64, raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || s == nil || s.avatarURLResolver == nil {
		return raw
	}
	if resolved := strings.TrimSpace(s.avatarURLResolver(ctx, tenantID, raw)); resolved != "" {
		return resolved
	}
	return raw
}

func (s *impl) resolveCapabilityIconURLs(ctx context.Context, tenantID int64, items []AgentCapabilitySummary) []AgentCapabilitySummary {
	if len(items) == 0 || s == nil || s.avatarURLResolver == nil {
		return items
	}
	out := make([]AgentCapabilitySummary, len(items))
	copy(out, items)
	for i := range out {
		raw := strings.TrimSpace(out[i].IconURL)
		if raw == "" {
			continue
		}
		if resolved := strings.TrimSpace(s.avatarURLResolver(ctx, tenantID, raw)); resolved != "" {
			out[i].IconURL = resolved
		}
	}
	return out
}

func (s *impl) hydrateAgentCapabilities(ctx context.Context, agents []agentRow) error {
	if s == nil || s.pool == nil || len(agents) == 0 {
		return nil
	}
	ids := make([]int64, 0, len(agents))
	index := make(map[int64]int, len(agents))
	for i := range agents {
		ids = append(ids, agents[i].ID)
		index[agents[i].ID] = i
	}
	skills, err := s.loadAgentSkillSummaries(ctx, ids)
	if err != nil {
		return err
	}
	for agentID, items := range skills {
		if i, ok := index[agentID]; ok {
			agents[i].Skills = items
		}
	}
	apps, err := s.loadAgentAppSummaries(ctx, ids)
	if err != nil {
		return err
	}
	for agentID, items := range apps {
		if i, ok := index[agentID]; ok {
			agents[i].Apps = items
		}
	}
	kbs, err := s.loadAgentKBSummaries(ctx, ids)
	if err != nil {
		return err
	}
	for agentID, items := range kbs {
		if i, ok := index[agentID]; ok {
			agents[i].KnowledgeBases = items
		}
	}
	return nil
}

func (s *impl) loadAgentSkillSummaries(ctx context.Context, agentIDs []int64) (map[int64][]AgentCapabilitySummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT b.agent_id, s.uuid::text, s.code, s.name, COALESCE(s.icon_url,'')
		FROM agent_skill_bindings b
		JOIN skills s ON s.id = b.skill_id
		WHERE b.agent_id = ANY($1)
		  AND s.deleted_at IS NULL
		  AND s.status = 'active'
		ORDER BY b.agent_id, b.sort_order, b.id`, agentIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]AgentCapabilitySummary{}
	for rows.Next() {
		var agentID int64
		var item AgentCapabilitySummary
		if err := rows.Scan(&agentID, &item.ID, &item.Slug, &item.Name, &item.IconURL); err != nil {
			return nil, err
		}
		// skills[] 由 agent_skill_bindings 查询得出，每一项都是真实正式绑定。
		// 显式下发安装态，避免客户端把轻量摘要误当成未安装候选。
		item.IsInstalled = true
		out[agentID] = appendUniqueCapability(out[agentID], item, 6)
	}
	return out, rows.Err()
}

// GroupAgentCapabilities returns display-only skill summaries for a room member card.
// Authorization is intentionally owned by room.Service: it calls this only after proving
// the caller and agent are active participants of the same room. This method is not part
// of the public contacts Service interface and must not be exposed as a directory bypass.
func (s *impl) GroupAgentCapabilities(ctx context.Context, agentID int64) ([]AgentCapabilitySummary, error) {
	if agentID <= 0 {
		return []AgentCapabilitySummary{}, nil
	}
	items, err := s.loadAgentSkillSummaries(ctx, []int64{agentID})
	if err != nil {
		return nil, err
	}
	return items[agentID], nil
}

func (s *impl) loadAgentAppSummaries(ctx context.Context, agentIDs []int64) (map[int64][]AgentCapabilitySummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT b.agent_id, a.uuid::text, a.code, a.name, COALESCE(a.icon_url,'')
		FROM agent_app_bindings b
		JOIN apps a ON a.id = b.app_id
		WHERE b.agent_id = ANY($1)
		  AND a.deleted_at IS NULL
		  AND a.status = 'active'
		  AND COALESCE(a.usage_scope,'all') IN ('all','agent')
		ORDER BY b.agent_id, b.sort_order, b.id`, agentIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]AgentCapabilitySummary{}
	for rows.Next() {
		var agentID int64
		var item AgentCapabilitySummary
		if err := rows.Scan(&agentID, &item.ID, &item.Slug, &item.Name, &item.IconURL); err != nil {
			return nil, err
		}
		out[agentID] = appendUniqueCapability(out[agentID], item, 6)
	}
	return out, rows.Err()
}

func (s *impl) loadAgentKBSummaries(ctx context.Context, agentIDs []int64) (map[int64][]AgentKnowledgeBaseSummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT b.agent_id, k.uuid::text, k.name
		FROM agent_kb_bindings b
		JOIN knowledge_bases k ON k.id = b.kb_id AND k.deleted_at IS NULL
		WHERE b.agent_id = ANY($1)
		  AND b.deleted_at IS NULL
		ORDER BY b.agent_id, b.priority DESC, b.id ASC`, agentIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]AgentKnowledgeBaseSummary{}
	for rows.Next() {
		var agentID int64
		var item AgentKnowledgeBaseSummary
		if err := rows.Scan(&agentID, &item.UUID, &item.Name); err != nil {
			return nil, err
		}
		out[agentID] = appendUniqueKnowledgeBase(out[agentID], item, 6)
	}
	return out, rows.Err()
}

func appendUniqueKnowledgeBase(items []AgentKnowledgeBaseSummary, next AgentKnowledgeBaseSummary, max int) []AgentKnowledgeBaseSummary {
	next.UUID = strings.TrimSpace(next.UUID)
	next.Name = strings.TrimSpace(next.Name)
	if next.Name == "" {
		next.Name = next.UUID
	}
	if next.UUID == "" && next.Name == "" {
		return items
	}
	for _, it := range items {
		if next.UUID != "" && it.UUID == next.UUID {
			return items
		}
		if strings.EqualFold(it.Name, next.Name) {
			return items
		}
	}
	if max > 0 && len(items) >= max {
		return items
	}
	return append(items, next)
}

func appendUniqueCapability(items []AgentCapabilitySummary, next AgentCapabilitySummary, max int) []AgentCapabilitySummary {
	next.Name = strings.TrimSpace(next.Name)
	next.ID = strings.TrimSpace(next.ID)
	next.Slug = strings.TrimSpace(next.Slug)
	next.IconURL = strings.TrimSpace(next.IconURL)
	if next.Name == "" {
		next.Name = next.Slug
	}
	if next.Name == "" {
		return items
	}
	for _, it := range items {
		if next.ID != "" && it.ID == next.ID {
			return items
		}
		if strings.EqualFold(it.Name, next.Name) {
			return items
		}
	}
	if max > 0 && len(items) >= max {
		return items
	}
	return append(items, next)
}

func (s *impl) Agents(ctx context.Context, caller CallerCtx, params ListAgentsParams) (AgentsBySource, error) {
	if caller.TenantID <= 0 {
		return AgentsBySource{}, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return AgentsBySource{}, err
	}
	limit := params.Limit
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	args := []any{caller.TenantID}
	where := []string{
		"de.deleted_at IS NULL",
		"de.status = 'published'",
		"de.contact_enabled = true",
		// ADR-0052: 本租户员工与平台已发布员工共用一套可见性判定；平台行由
		// visibility=platform + visibility override + contact policy 继续做租户级过滤。
		"(de.tenant_id = $1 OR (de.tenant_id IS NULL AND de.source = 'platform' AND de.visibility = 'platform'))",
	}
	if params.Source != "" && params.Source != "all" {
		args = append(args, params.Source)
		where = append(where, "de.source = $"+itoa(len(args)))
	}
	if params.Q != "" {
		args = append(args, "%"+strings.ToLower(params.Q)+"%")
		where = append(where,
			"(LOWER(de.name) LIKE $"+itoa(len(args))+
				" OR LOWER(COALESCE(de.intro,'')) LIKE $"+itoa(len(args))+")")
	}
	args = append(args, limit)
	sql := agentsBaseSelect + " WHERE " + strings.Join(where, " AND ") +
		" ORDER BY de.source, de.name LIMIT $" + itoa(len(args))
	all, err := s.runAgentRows(ctx, caller, policy, sql, args)
	if err != nil {
		return AgentsBySource{}, err
	}
	out := AgentsBySource{Enterprise: []AgentContact{}, Personal: []AgentContact{}, Platform: []AgentContact{}}
	for _, a := range all {
		switch a.Source {
		case "enterprise":
			out.Enterprise = append(out.Enterprise, a)
		case "personal":
			out.Personal = append(out.Personal, a)
		case "platform":
			out.Platform = append(out.Platform, a)
		}
	}
	return out, nil
}

// =====================================================
// Search
// =====================================================

func (s *impl) Search(ctx context.Context, caller CallerCtx, req SearchReq) (SearchResp, error) {
	if caller.TenantID <= 0 {
		return SearchResp{}, apperr.ErrForbidden.Withf("missing tenant")
	}
	if strings.TrimSpace(req.Q) == "" {
		return SearchResp{Members: []HumanContact{}, Agents: []AgentContact{}}, nil
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return SearchResp{}, err
	}
	scope := req.Scope
	if scope == "" {
		scope = policy.SearchScope
	}
	deptID := int64(0)
	if scope == "current_dept" {
		deptID = caller.DepartmentID
	}
	humans, err := s.fetchHumans(ctx, caller, policy, deptID, req.Q, 50)
	if err != nil {
		return SearchResp{}, err
	}
	agents, err := s.fetchAgentsForList(ctx, caller, policy, 0, req.Q, 50, "")
	if err != nil {
		return SearchResp{}, err
	}
	// 如果 scope=tenant (默认), 不返回 platform 段 agents
	if scope == "tenant" {
		filtered := agents[:0]
		for _, a := range agents {
			if a.Source != "platform" {
				filtered = append(filtered, a)
			}
		}
		agents = filtered
	}
	return SearchResp{Members: humans, Agents: agents}, nil
}

// =====================================================
// 单条详情
// =====================================================

func (s *impl) GetMember(ctx context.Context, caller CallerCtx, accountUUID string) (*HumanContact, error) {
	if caller.TenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return nil, err
	}
	row := s.pool.QueryRow(ctx, `
		SELECT a.id, a.uuid, COALESCE(NULLIF(tm.nickname,''), a.display_name),
		       COALESCE(a.avatar_url,''), COALESCE(a.phone,''), COALESCE(a.email,''),
		       COALESCE(tm.title,''),
		       d.id, d.uuid, d.name, tm.metadata
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		LEFT JOIN departments d ON d.id = tm.department_id AND d.deleted_at IS NULL
		WHERE a.uuid=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL AND tm.status='active'
		  AND a.deleted_at IS NULL
		  AND COALESCE((tm.metadata->>'hidden_in_contacts')::boolean,false) = false`,
		accountUUID, caller.TenantID)
	var r humanRow
	if err := row.Scan(&r.AccID, &r.AccUUID, &r.DisplayName, &r.AvatarURL,
		&r.Phone, &r.Email, &r.Title, &r.DeptID, &r.DeptUUID, &r.DeptName, &r.MetaJSON); err != nil {
		if err == pgx.ErrNoRows {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	hc := s.buildHuman(ctx, caller, policy, r)
	return &hc, nil
}

func (s *impl) GetAgent(ctx context.Context, caller CallerCtx, agentUUID string) (*AgentContact, error) {
	if caller.TenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return nil, err
	}
	args := []any{caller.TenantID, agentUUID}
	sql := agentsBaseSelect + " WHERE de.uuid=$2 AND de.deleted_at IS NULL"
	out, err := s.runAgentRows(ctx, caller, policy, sql, args)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, apperr.ErrNotFound
	}
	return &out[0], nil
}

// =====================================================
// CanCreateGroup
// =====================================================

func (s *impl) CanCreateGroup(ctx context.Context, caller CallerCtx, req CanCreateGroupReq) (CanCreateGroupResp, error) {
	if caller.TenantID <= 0 {
		return CanCreateGroupResp{}, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return CanCreateGroupResp{}, err
	}
	// 1) 全局开关: who_can_create_group_with_agent
	hasAgent := false
	for _, p := range req.Participants {
		if p.Kind == "agent" {
			hasAgent = true
			break
		}
	}
	if hasAgent {
		switch policy.WhoCanCreateGroupWithAgent {
		case "disabled":
			return CanCreateGroupResp{
				Allowed: false, ReasonCode: ReasonPermissionDenied,
				Message:             "本租户已禁用包含数字员工的群聊",
				BlockedParticipants: []BlockedParticipant{},
			}, nil
		case "tenant_admin":
			if !caller.IsTenantAdmin {
				return CanCreateGroupResp{
					Allowed: false, ReasonCode: ReasonPermissionDenied,
					Message:             "仅租户管理员可创建包含数字员工的群",
					BlockedParticipants: []BlockedParticipant{},
				}, nil
			}
		}
	}

	// 2) 逐个参与者校验
	blocked := []BlockedParticipant{}
	deptPath, err := s.resolveCallerDeptPath(ctx, caller.DepartmentID)
	if err != nil {
		return CanCreateGroupResp{}, err
	}
	callerVis := CallerVisibility{
		AccountID:          caller.AccountID,
		TenantID:           caller.TenantID,
		DepartmentPath:     deptPath,
		ShowPlatformAgents: policy.ShowPlatformAgents,
	}

	for _, p := range req.Participants {
		switch p.Kind {
		case "human":
			ok, reason := s.checkHumanForInvite(ctx, caller, policy, p.ID)
			if !ok {
				blocked = append(blocked, BlockedParticipant{Kind: "human", ID: p.ID, ReasonCode: reason})
			}
		case "agent":
			ok, reason := s.checkAgentForInvite(ctx, caller, policy, callerVis, p.ID)
			if !ok {
				blocked = append(blocked, BlockedParticipant{Kind: "agent", ID: p.ID, ReasonCode: reason})
			}
		default:
			blocked = append(blocked, BlockedParticipant{Kind: p.Kind, ID: p.ID, ReasonCode: ReasonPermissionDenied})
		}
	}
	if len(blocked) == 0 {
		return CanCreateGroupResp{
			Allowed: true, ReasonCode: ReasonOK,
			Message:             "策略允许; 群聊将在 M5 上线",
			BlockedParticipants: blocked,
		}, nil
	}
	// 选第一条阻断作为顶层 reasonCode/message
	return CanCreateGroupResp{
		Allowed: false, ReasonCode: blocked[0].ReasonCode,
		Message:             reasonMessage(blocked[0].ReasonCode),
		BlockedParticipants: blocked,
	}, nil
}

func reasonMessage(code string) string {
	switch code {
	case ReasonAgentNotInvitable:
		return "该数字员工暂不允许被拉入群聊"
	case ReasonAgentNotVisible:
		return "数字员工不在你可见范围内"
	case ReasonAgentNotPublished:
		return "数字员工未发布"
	case ReasonMemberNotInvitable:
		return "该成员不允许被拉群"
	case ReasonHumanNotFound:
		return "该成员不在你所在租户的通讯录内"
	case ReasonPlatformTemplateNotInvitable:
		return "平台模板不能直接被加入群聊, 请先把它启用为本租户的数字员工"
	case ReasonPermissionDenied:
		return "无权限"
	}
	return "策略阻断"
}

func (s *impl) checkHumanForInvite(ctx context.Context, caller CallerCtx, policy ContactPolicy, accountUUID string) (bool, string) {
	row := s.pool.QueryRow(ctx, `
		SELECT tm.metadata
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		WHERE a.uuid=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL AND tm.status='active'
		  AND a.deleted_at IS NULL
		  AND COALESCE((tm.metadata->>'hidden_in_contacts')::boolean,false) = false`,
		accountUUID, caller.TenantID)
	var meta []byte
	if err := row.Scan(&meta); err != nil {
		// 2026-06-02 改: human 不在 tenant_memberships 内不能复用 agent_not_visible (那是数字员工口径,
		// 客户端按 reason 渲染时会出现"数字员工不可见"这类误导文案); 改成 human_not_found, 文案对人。
		return false, ReasonHumanNotFound
	}
	mm := MembershipMeta{}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &mm)
	}
	if !CanInviteHuman(mm.AllowInviteToGroup, policy) {
		return false, ReasonMemberNotInvitable
	}
	return true, ReasonOK
}

func (s *impl) checkAgentForInvite(ctx context.Context, caller CallerCtx, policy ContactPolicy, callerVis CallerVisibility, agentUUID string) (bool, string) {
	args := []any{caller.TenantID, agentUUID}
	sql := agentsBaseSelect + " WHERE de.uuid=$2 AND de.deleted_at IS NULL"
	// 走 scanAgentRow helper, 保证列顺序与 agentsBaseSelect / runAgentRows 完全一致;
	// 漏一列即所有 published 副本都被错报 agent_not_visible (2026-06-02 codex 返修起因)。
	r, err := scanAgentRow(s.pool.QueryRow(ctx, sql, args...))
	if err != nil {
		return false, ReasonAgentNotVisible
	}
	return judgeAgentInvitability(r, policy, callerVis)
}

// judgeAgentInvitability 把"已 Scan 出来的 agentRow"过两层闸: 可见性 →
// allow_invite_to_group / policy。抽成纯函数是为了:
//   - 单测覆盖 visibility / agent_not_invitable reason 路径
//     不用真实 pgxpool;
//   - 与 ContactDTO.canInviteToRoom 的 isInvitableAgentContact 同源 (该 DTO 不区分原因, 只取最终 bool)。
//
// 顺序就是产品语义: 先看是否对 caller 可见, 再看 allow_invite_to_group / policy。
func judgeAgentInvitability(r agentRow, policy ContactPolicy, callerVis CallerVisibility) (bool, string) {
	in := AgentVisibilityInput{
		Status: r.Status, ContactEnabled: r.ContactEnabled,
		Source: r.Source, Visibility: r.Visibility,
		OverrideHidden: r.OverrideHidden,
	}
	if r.TenantID != nil {
		in.TenantID = *r.TenantID
	}
	if r.WorkspacePath != nil {
		in.WorkspacePath = *r.WorkspacePath
	}
	if r.CreatorID != nil {
		in.CreatorID = *r.CreatorID
	}
	if visible, reason := IsAgentVisible(in, callerVis); !visible {
		return false, reason
	}
	if !CanInviteAgent(r.AllowInviteToGroup, policy) {
		return false, ReasonAgentNotInvitable
	}
	return true, ReasonOK
}

func itoa(i int) string { return strconv.Itoa(i) }

// resolveCallerDeptPath 解析 caller 部门对应的 departments.path; deptID<=0 返 ""。
//
// **fail-closed** (T2D.3-A 返修): 真实 DB 错误 (连接断 / 超时) 一律向上抛, 不再静默忽略。
// ErrNoRows (部门刚被软删) 视为 "caller 当前无部门归属", 返回 "" + nil —— workspace
// 可见性会自动判定为 false, 这是安全的退化方向 (用户看不到 workspace agent, 比误放行好)。
//
// 该函数被 runAgentRows / CanCreateGroup 共享; 之前两处各有一份 `_ = ... .Scan(...)`
// 静默忽略, 任意 DB 抖动都会让 workspace 可见性误判 (见 service.go 历史版本)。
func (s *impl) resolveCallerDeptPath(ctx context.Context, deptID int64) (string, error) {
	if deptID <= 0 {
		return "", nil
	}
	var path string
	err := s.pool.QueryRow(ctx,
		`SELECT path FROM departments WHERE id=$1 AND deleted_at IS NULL`,
		deptID).Scan(&path)
	if err == nil {
		return path, nil
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return "", err
}

// ResolveCallerDepartment 见 Service 接口注释。
func (s *impl) ResolveCallerDepartment(ctx context.Context, accountID, tenantID int64) (int64, error) {
	if accountID <= 0 || tenantID <= 0 {
		return 0, nil
	}
	var did *int64
	err := s.pool.QueryRow(ctx, `
		SELECT department_id FROM tenant_memberships
		WHERE account_id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		accountID, tenantID).Scan(&did)
	if err == pgx.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if did == nil {
		return 0, nil
	}
	return *did, nil
}

// AssertAgentVisible 见 Service 接口注释 (Batch 2D T2D.3-A 可见性收口入口)。
//
// 实现思路: 复用 GetAgent 的 runAgentRows 路径 (含 IsAgentVisible 完整判定),
// 只是丢弃 DTO; 返回 apperr.ErrNotFound 时统一翻成 Forbidden, 不暴露存在性。
//
// caller dept 兜底: 内部自动 ResolveCallerDepartment, 调用方不需要先查; 这样
// chat.Send / room invite 等不需要复制 dept 解析逻辑。
//
// **fail-closed**: ResolveCallerDepartment 返回 DB 错误 (e.g. 连接断) 时一律包成
// InternalError 向上抛, 而不是当 dept=0 继续 —— 否则 workspace 可见性会被误判,
// caller 部门外的 agent 反而可能被错误放行。
func (s *impl) AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error {
	if tenantID <= 0 {
		return apperr.ErrForbidden.Withf("missing tenant")
	}
	deptID, err := s.ResolveCallerDepartment(ctx, accountID, tenantID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err).Withf("resolve caller department")
	}
	caller := CallerCtx{AccountID: accountID, TenantID: tenantID, DepartmentID: deptID}
	_, err = s.GetAgent(ctx, caller, agentUUID)
	if err == nil {
		return nil
	}
	if errors.Is(err, apperr.ErrNotFound) {
		return apperr.ErrForbidden.Withf("agent not visible")
	}
	return err
}

// IsTenantAdmin 检查 caller 是否在 tenantID 内拥有 tenant.admin 角色。
//
// 参考 docs/modules/m1-identity-and-login.md §3.3 角色模型: tenant.admin 在创建租户时实例化,
// scope_kind='tenant' AND tenant_id=<tid>。
func (s *impl) IsTenantAdmin(ctx context.Context, accountID, tenantID int64) (bool, error) {
	if accountID <= 0 || tenantID <= 0 {
		return false, nil
	}
	var ok bool
	err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM role_assignments ra
			JOIN roles r ON r.id = ra.role_id
			WHERE ra.account_id = $1
			  AND ra.deleted_at IS NULL
			  AND (ra.expires_at IS NULL OR ra.expires_at > now())
			  AND r.code = 'tenant.admin'
			  AND r.scope_kind = 'tenant'
			  AND r.tenant_id = $2
		)`, accountID, tenantID).Scan(&ok)
	if err != nil {
		return false, err
	}
	return ok, nil
}
