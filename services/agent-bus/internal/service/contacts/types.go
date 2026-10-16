// Package contacts 实现 M2 通讯录与可见性。
//
// 详见 docs/modules/m2-contacts-and-visibility.md §4。
// 服务端按 caller 的 act_scope + workspace 过滤可见性, 不靠客户端隐藏;
// 字段级可见性裁剪也在序列化层完成 (见 field_mask.go)。
package contacts

import domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"

import "time"

// FieldVisibility 字段级可见性枚举: all / department / self / hidden。
type FieldVisibility string

const (
	FieldAll        FieldVisibility = "all"
	FieldDepartment FieldVisibility = "department"
	FieldSelf       FieldVisibility = "self"
	FieldHidden     FieldVisibility = "hidden"
)

// IsValid 判断 4 档枚举。
func (f FieldVisibility) IsValid() bool {
	switch f {
	case FieldAll, FieldDepartment, FieldSelf, FieldHidden:
		return true
	}
	return false
}

// FieldMask 三个字段的可见性配置 (phone/email/title)。
// 来源优先级: 成员 metadata.field_mask > contact_policies 默认。
type FieldMask struct {
	Phone FieldVisibility `json:"phone"`
	Email FieldVisibility `json:"email"`
	Title FieldVisibility `json:"title"`
}

// MembershipMeta 成员级 metadata 约定 (M2 §3.3)。
type MembershipMeta struct {
	HiddenInContacts      bool                       `json:"hidden_in_contacts"`
	AllowInviteToGroup    *bool                      `json:"allow_invite_to_group,omitempty"`
	FieldMask             map[string]FieldVisibility `json:"field_mask,omitempty"`
	PositionLabelOverride *string                    `json:"position_label_override,omitempty"`
}

// ContactPolicy 租户级通讯录配置。
type ContactPolicy struct {
	TenantID                   int64           `json:"tenantId"`
	DefaultLanding             string          `json:"defaultLanding"` // org_tree / agent_plaza
	DefaultShowPhone           FieldVisibility `json:"defaultShowPhone"`
	DefaultShowEmail           FieldVisibility `json:"defaultShowEmail"`
	DefaultShowTitle           FieldVisibility `json:"defaultShowTitle"`
	SearchScope                string          `json:"searchScope"` // current_dept / tenant / tenant_plus_platform_agents
	WhoCanCreateGroupWithAgent string          `json:"whoCanCreateGroupWithAgent"`
	AgentsDefaultInvitable     bool            `json:"agentsDefaultInvitable"`
	HumansDefaultInvitable     bool            `json:"humansDefaultInvitable"`
	ShowPlatformAgents         bool            `json:"showPlatformAgents"`
}

// PolicyDefaults 把 policy 转成 FieldMask 默认值。
func (p ContactPolicy) PolicyDefaults() FieldMask {
	return FieldMask{
		Phone: p.DefaultShowPhone,
		Email: p.DefaultShowEmail,
		Title: p.DefaultShowTitle,
	}
}

// HumanContactFields 已按 field_mask 裁剪过的 human 可见字段。
// 仅当当前 caller 有权看的字段才出现 (空字符串/空 map 表示不返回, 由 marshal 决定 omitempty)。
type HumanContactFields struct {
	Phone string `json:"phone,omitempty"`
	Email string `json:"email,omitempty"`
}

// HumanContact 与 docs/contracts/agent-bus-client-contract.md §2 + M2 §4.2 对齐。
type HumanContact struct {
	Kind               string             `json:"kind"` // 固定 "human"
	ID                 string             `json:"id"`   // account uuid
	DisplayName        string             `json:"displayName"`
	AvatarURL          string             `json:"avatarUrl,omitempty"`
	Subtitle           string             `json:"subtitle,omitempty"`
	DepartmentID       string             `json:"departmentId,omitempty"` // department uuid
	DepartmentName     string             `json:"departmentName,omitempty"`
	Fields             HumanContactFields `json:"fields"`
	Presence           string             `json:"presence"` // M2 固定 offline
	Badges             []string           `json:"badges"`   // M2 通常空
	CanChat            bool               `json:"canChat"`
	ChatDisabledReason string             `json:"chatDisabledReason,omitempty"`
	CanInviteToRoom    bool               `json:"canInviteToRoom"`
}

// AgentCapabilitySummary 是客户端数字员工卡片展示用的轻量能力摘要。
// 只包含可展示字段, 不暴露技能包地址、应用启动凭证、运行参数或内部路径。
type AgentCapabilitySummary struct {
	ID          string `json:"id,omitempty"`
	Name        string `json:"name"`
	Slug        string `json:"slug,omitempty"`
	IconURL     string `json:"iconUrl,omitempty"`
	IsInstalled bool   `json:"isInstalled,omitempty"`
}

// AgentKnowledgeBaseSummary 是客户端数字员工卡片展示用的知识库摘要。
type AgentKnowledgeBaseSummary struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
}

// AgentContact M2 §4.2 agent 形态。
type AgentContact struct {
	domagent.ConversationCapabilities
	Kind               string                      `json:"kind"` // 固定 "agent"
	ID                 string                      `json:"id"`   // digital_employee uuid
	DisplayName        string                      `json:"displayName"`
	AvatarURL          string                      `json:"avatarUrl,omitempty"`
	Subtitle           string                      `json:"subtitle,omitempty"`
	PositionLabel      string                      `json:"positionLabel,omitempty"`
	DepartmentID       string                      `json:"departmentId,omitempty"`
	DepartmentName     string                      `json:"departmentName,omitempty"`
	Source             string                      `json:"source"` // enterprise / personal / platform
	Skills             []AgentCapabilitySummary    `json:"skills,omitempty"`
	Apps               []AgentCapabilitySummary    `json:"apps,omitempty"`
	KnowledgeBases     []AgentKnowledgeBaseSummary `json:"knowledge_bases,omitempty"`
	Badges             []string                    `json:"badges"`
	Presence           string                      `json:"presence"` // M2 固定 offline
	LifecycleStatus    string                      `json:"lifecycleStatus"`
	CanChat            bool                        `json:"canChat"`
	ChatDisabledReason string                      `json:"chatDisabledReason,omitempty"`
	CanInviteToRoom    bool                        `json:"canInviteToRoom"`
	SupportsGroupChat  bool                        `json:"supportsGroupChat"`
}

// DepartmentNode 组织树节点。
type DepartmentNode struct {
	ID         string           `json:"id"` // department uuid
	Name       string           `json:"name"`
	ParentID   string           `json:"parentId,omitempty"`
	Path       string           `json:"path"`
	Depth      int              `json:"depth"`
	HumanCount int              `json:"humanCount"`
	AgentCount int              `json:"agentCount"`
	Children   []DepartmentNode `json:"children,omitempty"`
}

// ListContactsParams 统一列表参数。
type ListContactsParams struct {
	DepartmentID string // department uuid; 空表示根 (无 dept_id 过滤)
	Kind         string // human / agent / all (default all)
	Q            string
	Limit        int    // 默认 50, 上限 200
	Cursor       string // 简单分页: "<id>"; 空表示首页
}

// ContactItem 列表元素 (kind 决定 Human/Agent 二选一)。
type ContactItem struct {
	Human *HumanContact `json:"-"`
	Agent *AgentContact `json:"-"`
}

// ListContactsResp 统一列表返回。
type ListContactsResp struct {
	Items      []any  `json:"items"` // 元素是 HumanContact 或 AgentContact
	NextCursor string `json:"nextCursor,omitempty"`
}

// ListAgentsParams 数字员工广场参数。
type ListAgentsParams struct {
	Source string // enterprise / personal / platform / all
	Q      string
	Limit  int
	Cursor string
}

// AgentsBySource 按来源分组返回 (M2 §7.1 数字员工 Tab 直接渲染)。
type AgentsBySource struct {
	Enterprise []AgentContact `json:"enterprise"`
	Personal   []AgentContact `json:"personal"`
	Platform   []AgentContact `json:"platform"`
}

// SearchReq POST /contacts/search body。
type SearchReq struct {
	Q     string `json:"q"`
	Scope string `json:"scope,omitempty"` // 覆盖 policy.search_scope; 空时取 policy
}

// SearchResp 搜索返回 (员工 / 数字员工 两段)。
type SearchResp struct {
	Members []HumanContact `json:"members"`
	Agents  []AgentContact `json:"agents"`
}

// CanCreateGroupReq POST /contacts/can-create-group body。
type CanCreateGroupReq struct {
	Participants []GroupParticipant `json:"participants"`
}

// GroupParticipant 拉群预检参与者。
type GroupParticipant struct {
	Kind string `json:"kind"` // human / agent
	ID   string `json:"id"`   // account uuid 或 digital_employee uuid
}

// CanCreateGroupResp 拉群预检结果。M2 不创建 room。
type CanCreateGroupResp struct {
	Allowed             bool                 `json:"allowed"`
	ReasonCode          string               `json:"reasonCode"`
	Message             string               `json:"message"`
	BlockedParticipants []BlockedParticipant `json:"blockedParticipants"`
}

// BlockedParticipant 阻断条目。
type BlockedParticipant struct {
	Kind       string `json:"kind"`
	ID         string `json:"id"`
	ReasonCode string `json:"reasonCode"`
}

// ReasonCode M2 §4.1 最小集合。
//
// 2026-06-02 扩展 (用户反馈群聊错误诊断不准): human 与 agent 阻断必须各自的 reason code,
// 避免 "human 没在 tenant_memberships 里" 被错误归到 ReasonAgentNotVisible 报"数字员工不可见"
// 这种文案误导。doc-15 platform template live-link 入群隔离也走独立 code。
const (
	ReasonOK                           = "ok"
	ReasonPermissionDenied             = "permission_denied"
	ReasonAgentNotInvitable            = "agent_not_invitable"
	ReasonAgentNotVisible              = "agent_not_visible"
	ReasonAgentNotPublished            = "agent_not_published"
	ReasonMemberNotInvitable           = "member_not_invitable"
	ReasonHumanNotFound                = "human_not_found"                 // 2026-06-02: human 不在本租户 tenant_memberships 里 / 已软删 / hidden_in_contacts=true
	ReasonPlatformTemplateNotInvitable = "platform_template_not_invitable" // 历史兼容；ADR-0052 后不再因平台来源触发
)

// CallerCtx 服务层使用的 caller 视角, 由 transport 注入。
//
// AccountID/TenantID 必填; DepartmentID 为 caller 所在部门 (用于 field_mask=department 判定);
// IsTenantAdmin 影响"创建含 Agent 的群"开关。
type CallerCtx struct {
	AccountID     int64
	TenantID      int64
	DepartmentID  int64
	IsTenantAdmin bool
}

// stamp helper
type stamps struct {
	CreatedAt time.Time
	UpdatedAt time.Time
}
