// composer.go — F04 §3.3 客户端会话内应用列表 + §3.4 launch endpoint 业务逻辑。
package app

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	pkgoauth2 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2"
)

// ListConversationApps 返回当前 conversation 应该 expose 的应用列表 (通用 ∪ 业务)。
//
// 决策规则:
//   - 通用应用 (tenant_app_settings.is_universal=true AND is_enabled=true): 出现在所有 conversation
//   - 业务应用 (agent_app_bindings): legacy 会话按 conv.digital_employee_id；room-backed
//     会话仅 human-agent direct 的唯一 active Agent 命中，human-direct / group 跳过
//
// 不 dedup — 一个 app 同时是通用 + 挂在某 agent 时, 业务绑定优先 (binding_kind=agent_bound)。
func (s *Service) ListConversationApps(ctx context.Context, in dom.ConversationAppListInput) ([]dom.ConversationAppItem, error) {
	if s.deps.Conversations == nil {
		return nil, apperr.ErrInternal.Withf("conversations repo not wired")
	}
	conv, err := s.deps.Conversations.GetByUUID(ctx, in.ConversationUUID)
	if err != nil {
		return nil, err
	}
	if conv.TenantID != in.TenantID {
		return nil, apperr.ErrForbidden.Withf("conversation not in caller tenant")
	}
	accessible, err := s.deps.Conversations.AccessibleByAccount(ctx, in.TenantID, in.AccountID, in.ConversationUUID)
	if err != nil {
		return nil, err
	}
	if !accessible {
		return nil, apperr.ErrForbidden.Withf("conversation not accessible")
	}

	// 加载分类一次性 (后续 JOIN 用 map)
	cats, _, err := s.deps.Categories.List(ctx, in.TenantID, 200, 0)
	if err != nil {
		return nil, err
	}
	catByID := map[int64]dom.Category{}
	for _, c := range cats {
		catByID[c.ID] = c
	}

	out := []dom.ConversationAppItem{}
	seenAppID := map[int64]bool{}

	// 通用应用优先。它们属于用户入口 / 工作台口径，agent_chat 里也应保留为 universal。
	universals, err := s.deps.Settings.ListUniversalByTenant(ctx, in.TenantID)
	if err != nil {
		return nil, err
	}
	for _, u := range universals {
		a, err := s.deps.Apps.GetByID(ctx, u.AppID)
		if err != nil || (a.TenantID != 0 && a.TenantID != in.TenantID) || a.Status != "active" {
			continue
		}
		if !canUseInEndUserEntry(a) {
			continue
		}
		out = append(out, buildItem(*a, "universal", "", u.SortOrder, catByID))
		seenAppID[a.ID] = true
	}

	// 数字员工绑定仅补充 agent-only / 非通用应用，供关联应用 chip launch 校验使用。
	agentID, err := s.resolveConversationAgentID(ctx, in.TenantID, conv)
	if err != nil {
		return nil, err
	}
	if agentID != nil {
		bindings, err := s.deps.Bindings.ListByAgent(ctx, *agentID)
		if err != nil {
			return nil, err
		}
		// 取该 agent 的 UUID (反向打到结果里)
		agent, agErr := s.deps.Agents.GetByID(ctx, *agentID)
		agentUUID := ""
		if agErr == nil && agent != nil {
			agentUUID = agent.UUID
		}
		for _, b := range bindings {
			if seenAppID[b.AppID] {
				continue
			}
			a, err := s.deps.Apps.GetByID(ctx, b.AppID)
			if err != nil || (a.TenantID != 0 && a.TenantID != in.TenantID) || a.Status != "active" {
				continue
			}
			if !canUseInAgentBinding(a) {
				continue
			}
			out = append(out, buildItem(*a, "agent_bound", agentUUID, b.SortOrder, catByID))
			seenAppID[a.ID] = true
		}
	}
	return out, nil
}

// resolveConversationAgentID 兼容两代会话模型：legacy 非 room 会话使用旧 FK；
// room-backed 会话只接受同租户 active human-agent direct room 的唯一 active Agent。
// 任一关系不明确均返回 nil，让 Agent 绑定应用保持 default-deny。
func (s *Service) resolveConversationAgentID(ctx context.Context, tenantID int64, conv *domconv.Conversation) (*int64, error) {
	if conv.RoomID == nil {
		return conv.DigitalEmployeeID, nil
	}
	if s.deps.ConversationRooms == nil {
		return nil, nil
	}

	room, err := s.deps.ConversationRooms.GetByID(ctx, *conv.RoomID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil
		}
		return nil, err
	}
	if room.TenantID != tenantID || room.RoomKind != domroom.KindDirect || room.Status != "active" ||
		room.Metadata["direct_room_kind"] != "human-agent" {
		return nil, nil
	}

	participants, err := s.deps.ConversationRooms.ListParticipants(ctx, room.ID)
	if err != nil {
		return nil, err
	}
	var agentID *int64
	for _, participant := range participants {
		if participant.Kind != domroom.ParticipantAgent {
			continue
		}
		if participant.AgentID == nil || *participant.AgentID <= 0 || agentID != nil {
			return nil, nil
		}
		id := *participant.AgentID
		agentID = &id
	}
	return agentID, nil
}

func buildItem(a dom.App, kind, agentUUID string, sort int, catByID map[int64]dom.Category) dom.ConversationAppItem {
	item := dom.ConversationAppItem{
		UUID:        a.UUID,
		Name:        a.Name,
		IconURL:     a.IconURL,
		Color:       a.Color,
		DisplayMode: a.DisplayMode,
		BindingKind: kind,
		AgentUUID:   agentUUID,
		SortOrder:   sort,
	}
	if a.CategoryID != nil {
		if c, ok := catByID[*a.CategoryID]; ok {
			item.CategoryUUID = c.UUID
			item.CategoryName = c.Name
		}
	}
	return item
}

// =====================================================
// Launch — 颁一次性 code, 拼 launch_url
// =====================================================

// Launch 用户点应用启动: 校验可见性 → 落 app_oauth_codes → 拼 launch_url。
//
// 步骤:
//  1. 找 app 行 + 校 status=active
//  2. 找 app 的 oauth_client (取默认 redirect_uri / scopes)
//  3. 校 caller 对该 app 在该 conversation 中可见 (走 ListConversationApps 同款逻辑)
//  4. 生成 plaintext code (32 base62), 落 sha256(code) 进 app_oauth_codes
//  5. 拼 launch_url = app.launch_uri + ?code=...&state=...&iss=...
func (s *Service) Launch(ctx context.Context, in dom.LaunchInput) (*dom.LaunchResult, error) {
	a, err := s.deps.Apps.GetByUUID(ctx, in.TenantID, in.AppUUID)
	if err != nil {
		return nil, err
	}
	if a.Status != "active" {
		return nil, apperr.ErrForbidden.Withf("app status=%s", a.Status)
	}
	if a.OAuthClientID == nil {
		return nil, apperr.ErrInternal.Withf("app %q has no oauth_client", in.AppUUID)
	}
	oc, err := s.deps.OAuthClients.GetByID(ctx, *a.OAuthClientID)
	if err != nil {
		return nil, err
	}
	if oc.Status != "active" {
		return nil, apperr.ErrForbidden.Withf("oauth_client status=%s", oc.Status)
	}
	if len(oc.RedirectURIs) == 0 {
		return nil, apperr.ErrInternal.Withf("oauth_client has no redirect_uri")
	}

	// 校可见性: 如果 conversation_uuid 给了, 检查该 app 在该 conversation 的列表中
	var conversationID *int64
	if in.ConversationUUID != "" {
		visible, convID, err := s.checkAppVisibleInConversation(ctx, in.TenantID, in.AccountID, a.ID, in.ConversationUUID)
		if err != nil {
			return nil, err
		}
		if !visible {
			return nil, apperr.ErrForbidden.Withf("app not accessible in this conversation")
		}
		conversationID = &convID
	}
	// 没 conversation_uuid (v0.2 工作台外启动) — v0.1 暂不允许
	if conversationID == nil && in.ConversationUUID == "" {
		// v0.1: 必须挂 conversation
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid required (v0.1; v0.2 will support workbench launch)")
	}

	// 生成 code (32 base62)
	codeBody, err := pkgoauth2.GenRandomCode(32)
	if err != nil {
		return nil, fmt.Errorf("gen code: %w", err)
	}
	plaintextWithPrefix := "ac_" + codeBody
	codeHash := pkgoauth2.HashSecret(plaintextWithPrefix)

	// 选 redirect_uri: 用第一个 (v0.1 不支持客户端指定; v0.2 加 ?redirect_uri= 参数)
	redirectURI := oc.RedirectURIs[0]

	// 落库
	codeRow := &dom.OAuthCode{
		CodeHash:       codeHash,
		OAuthClientID:  oc.ID,
		TenantID:       in.TenantID,
		AccountID:      in.AccountID,
		ConversationID: conversationID,
		RedirectURI:    redirectURI,
		Scopes:         oc.Scopes,
		State:          in.State,
		Nonce:          in.Nonce,
		ExpiresAt:      s.now().Add(s.deps.AuthCodeTTL),
	}
	if err := s.deps.OAuthCodes.Insert(ctx, codeRow); err != nil {
		return nil, fmt.Errorf("insert code: %w", err)
	}
	s.audit(ctx, "audit.app.launch", in.TenantID, "app.launch:"+codeRow.CodeHash, map[string]any{
		"resource_kind":      "app",
		"resource_uuid":      a.UUID,
		"app_uuid":           a.UUID,
		"conversation_uuid":  in.ConversationUUID,
		"code_hash_prefix":   codeHashPrefix(codeHash),
		"oauth_client_id":    oc.ClientID,
		"display_mode":       a.DisplayMode,
		"redirect_uri_count": len(oc.RedirectURIs),
	})

	// 拼 launch_url
	q := url.Values{}
	q.Set("code", plaintextWithPrefix)
	if in.State != "" {
		q.Set("state", in.State)
	}
	q.Set("iss", s.deps.DiscoveryBaseURL)

	launchURL := a.LaunchURI
	if strings.Contains(launchURL, "?") {
		launchURL += "&" + q.Encode()
	} else {
		launchURL += "?" + q.Encode()
	}

	return &dom.LaunchResult{
		LaunchURL:   launchURL,
		DisplayMode: a.DisplayMode,
		ExpiresIn:   int(s.deps.AuthCodeTTL.Seconds()),
	}, nil
}

func codeHashPrefix(codeHash string) string {
	if len(codeHash) <= 12 {
		return codeHash
	}
	return codeHash[:12]
}

// checkAppVisibleInConversation 校验某 app 在指定 conversation 中是否对该用户可见。
// 返 (visible, conversationID, error)。
func (s *Service) checkAppVisibleInConversation(ctx context.Context, tenantID, accountID, appID int64, conversationUUID string) (bool, int64, error) {
	items, err := s.ListConversationApps(ctx, dom.ConversationAppListInput{
		ConversationUUID: conversationUUID,
		AccountID:        accountID,
		TenantID:         tenantID,
	})
	if err != nil {
		return false, 0, err
	}
	conv, err := s.deps.Conversations.GetByUUID(ctx, conversationUUID)
	if err != nil {
		return false, 0, err
	}
	for _, it := range items {
		// items 的 UUID 是 app UUID; 我们要按 app ID 匹配
		// 再去 fetch app — 这步可以靠 it.UUID 直接 GetByUUID
		a, err := s.deps.Apps.GetByUUID(ctx, tenantID, it.UUID)
		if err != nil {
			if errors.Is(err, apperr.ErrNotFound) {
				continue
			}
			return false, 0, err
		}
		if a.ID == appID {
			return true, conv.ID, nil
		}
	}
	return false, conv.ID, nil
}
