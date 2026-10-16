package contacts

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

type ConversationCapabilitiesResolver interface {
	ConversationCapabilities(context.Context, int64, []string) (map[string]dom.ConversationCapabilities, error)
}

func SetConversationCapabilitiesResolver(svc Service, resolver ConversationCapabilitiesResolver) {
	if s, ok := svc.(*impl); ok {
		s.conversationCapabilities = resolver
	}
}
