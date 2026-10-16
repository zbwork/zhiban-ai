package chat

import (
	"context"
	"errors"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const (
	supportWelcomeSystemSeed = "support_welcome"
	supportWelcomeFallback   = "您好，我是知办客服。你可以问我知办AI怎么使用，也可以直接告诉我遇到的问题、报错或建议，我会帮你记录并反馈给平台管理员。"
)

type zhibanSupportAgentFinder interface {
	FindZhibanSupportAgent(ctx context.Context, tenantID int64) (*domagent.DigitalEmployee, error)
}

type supportWelcomeMessageLookup interface {
	HasSupportWelcomeMessage(ctx context.Context, conversationID int64) (bool, error)
}

func shouldSeedSupportWelcomeConversation(items []domconv.ListItem, total int64, offset int, includeHidden bool) bool {
	return !includeHidden && offset == 0 && total == 0 && len(items) == 0
}

func (s *impl) seedSupportWelcomeIfFirstVisibleList(ctx context.Context, accountID, tenantID int64) (bool, error) {
	if s.convs == nil || s.agents == nil || s.messages == nil {
		return false, nil
	}
	hiddenItems, hiddenTotal, err := s.convs.ListForAccount(ctx, tenantID, accountID, 1, 0, true)
	if err != nil {
		return false, err
	}
	if hiddenTotal > 0 || len(hiddenItems) > 0 {
		return false, nil
	}

	finder, ok := s.agents.(zhibanSupportAgentFinder)
	if !ok {
		return false, nil
	}
	ag, err := finder.FindZhibanSupportAgent(ctx, tenantID)
	if err != nil {
		if isAppNotFound(err) {
			return false, nil
		}
		return false, err
	}
	if ag == nil || ag.ID <= 0 {
		return false, nil
	}

	conv, created, err := s.resolveOrCreateSupportConversation(ctx, accountID, tenantID, ag)
	if err != nil {
		return false, err
	}
	if conv == nil || conv.ID <= 0 {
		return false, nil
	}

	if lookup, ok := s.messages.(supportWelcomeMessageLookup); ok {
		exists, err := lookup.HasSupportWelcomeMessage(ctx, conv.ID)
		if err != nil {
			return false, err
		}
		if exists {
			return false, nil
		}
	}

	welcome := strings.TrimSpace(ag.WelcomeMsg)
	if welcome == "" {
		welcome = supportWelcomeFallback
	}
	msg, err := s.messages.Append(ctx, &dommsg.Message{
		TenantID:       tenantID,
		ConversationID: conv.ID,
		Role:           "agent",
		SenderAgentID:  &ag.ID,
		Blocks:         []map[string]any{markdownBlock(welcome)},
		Status:         "final",
		Final:          true,
		Metadata: map[string]any{
			"system_seed":  supportWelcomeSystemSeed,
			"auto_welcome": true,
			"agent_key":    supportAgentKey,
		},
	})
	if err != nil {
		if created {
			_ = s.convs.Delete(ctx, conv.ID)
		}
		return false, err
	}
	if err := s.convs.BumpLastMessage(ctx, conv.ID, msg.CreatedAt); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "support welcome: bump last_message_at failed",
			"tenant_id", tenantID, "account_id", accountID, "conversation_id", conv.ID, "err", err.Error())
	}
	return true, nil
}

func (s *impl) resolveOrCreateSupportConversation(ctx context.Context, accountID, tenantID int64, ag *domagent.DigitalEmployee) (*domconv.Conversation, bool, error) {
	existing, err := s.convs.FindActiveSingle(ctx, tenantID, accountID, ag.ID)
	if err == nil {
		return existing, false, nil
	}
	if !isAppNotFound(err) {
		return nil, false, err
	}
	created, err := s.convs.Create(ctx, &domconv.Conversation{
		TenantID:          tenantID,
		AccountID:         accountID,
		DigitalEmployeeID: &ag.ID,
		Title:             ag.Name,
		Source:            "chat",
		Metadata: map[string]any{
			"system_seed": supportWelcomeSystemSeed,
			"agent_key":   supportAgentKey,
		},
	})
	if err == nil {
		return created, true, nil
	}
	if !isUniqueViolation(err) {
		return nil, false, err
	}
	winner, lookupErr := s.convs.FindActiveSingle(ctx, tenantID, accountID, ag.ID)
	if lookupErr == nil {
		return winner, false, nil
	}
	return nil, false, apperr.ErrConflict.Withf("support welcome conversation create lost race: %v", lookupErr)
}

func isAppNotFound(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, apperr.ErrNotFound) {
		return true
	}
	if e, ok := apperr.AsError(err); ok && e.Code == apperr.NotFound {
		return true
	}
	return false
}
