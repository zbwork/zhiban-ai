package contacts

import "strings"

// AgentVisibilityInput 是判断单条 agent 是否对 caller 可见所需的最小输入。
//
// 全部字段都是数字员工实体上的列, 不携带任何业务逻辑。
type AgentVisibilityInput struct {
	Status         string // draft/published/grayed/archived
	ContactEnabled bool
	Source         string // enterprise/personal/platform
	Visibility     string // private/workspace/tenant/platform
	TenantID       int64  // platform agent 时为 0
	WorkspaceID    int64  // workspace 可见时必填; 其它可为 0
	WorkspacePath  string // departments.path, 用于 caller 部门祖先链匹配
	CreatorID      int64  // private 可见性必填
	OverrideHidden bool   // platform agent 在 caller 租户被隐藏
}

// CallerVisibility 是 caller 在某租户视角下做可见性判断的最小输入。
type CallerVisibility struct {
	AccountID          int64
	TenantID           int64
	DepartmentPath     string // caller 所在部门 path; 空表示无部门
	ShowPlatformAgents bool   // 来自 contact_policies.show_platform_agents
}

// IsAgentVisible 判定单条 agent 是否对 caller 可见 (M2 §4.3 伪代码)。
//
// 返回 (visible, reasonCode)。reasonCode 仅在 visible=false 时有意义,
// 给 can-create-group 等需要解释原因的接口使用。
func IsAgentVisible(in AgentVisibilityInput, caller CallerVisibility) (bool, string) {
	if in.Status != "published" {
		return false, ReasonAgentNotPublished
	}
	if !in.ContactEnabled {
		return false, ReasonAgentNotVisible
	}
	switch in.Visibility {
	case "private":
		if in.CreatorID != caller.AccountID {
			return false, ReasonAgentNotVisible
		}
	case "workspace":
		if in.WorkspacePath == "" {
			return false, ReasonAgentNotVisible
		}
		if !pathContains(caller.DepartmentPath, in.WorkspacePath) {
			return false, ReasonAgentNotVisible
		}
	case "tenant":
		if in.TenantID == 0 || in.TenantID != caller.TenantID {
			return false, ReasonAgentNotVisible
		}
	case "platform":
		if !caller.ShowPlatformAgents {
			return false, ReasonAgentNotVisible
		}
		if in.OverrideHidden {
			return false, ReasonAgentNotVisible
		}
	default:
		return false, ReasonAgentNotVisible
	}
	return true, ReasonOK
}

// pathContains 判断 callerPath 是否落在 agentWorkspacePath 之内 (即 caller 部门是 agent workspace 的同节点或子节点)。
//
// departments.path 形如 "/1/3/7/", agent 的 workspace path 是 "/1/3/", 则 caller "/1/3/7/" 命中。
// 兼容尾部斜杠存在/缺失。
func pathContains(callerPath, workspacePath string) bool {
	if callerPath == "" || workspacePath == "" {
		return false
	}
	c := normalizePath(callerPath)
	w := normalizePath(workspacePath)
	return c == w || strings.HasPrefix(c, w)
}

func normalizePath(p string) string {
	if !strings.HasSuffix(p, "/") {
		p = p + "/"
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

// CanInviteAgent 判定一条已可见的 agent 是否可被拉入群 (用于 ContactDTO.canInviteToRoom 与 can-create-group)。
//
// 业务: agent 自身允许 + 租户 policy 不禁用群聊功能。
// 注意: agent 是否真的能"进入"群依赖 supports_group_chat (M5 才生效); M2 这里只看通讯录侧策略。
func CanInviteAgent(allowInviteToGroup bool, policy ContactPolicy) bool {
	if policy.WhoCanCreateGroupWithAgent == "disabled" {
		return false
	}
	return allowInviteToGroup
}

// CanInviteHuman 判定一条 human 是否可被任意成员拉群。
// 来源: 成员 metadata.allow_invite_to_group, 缺省取 policy.HumansDefaultInvitable。
func CanInviteHuman(memberAllow *bool, policy ContactPolicy) bool {
	if memberAllow != nil {
		return *memberAllow
	}
	return policy.HumansDefaultInvitable
}
