package supportfeedback

import (
	"context"
	"errors"
	"time"
)

const (
	MaxAttachments = 20

	SourceAgentChat      = "agent_chat"
	SourceAdminCreated   = "admin_created"
	SourceSystemDetected = "system_detected"

	CategoryUsageQuestion     = "usage_question"
	CategoryBug               = "bug"
	CategoryProductSuggestion = "product_suggestion"
	CategoryAccountAccess     = "account_access"
	CategoryPerformance       = "performance"
	CategoryOther             = "other"

	PriorityLow    = "low"
	PriorityNormal = "normal"
	PriorityHigh   = "high"
	PriorityUrgent = "urgent"

	StatusOpen       = "open"
	StatusTriaged    = "triaged"
	StatusInProgress = "in_progress"
	StatusResolved   = "resolved"
	StatusClosed     = "closed"
)

var (
	ErrInvalidSource   = errors.New("support_feedback.invalid_source")
	ErrInvalidCategory = errors.New("support_feedback.invalid_category")
	ErrInvalidPriority = errors.New("support_feedback.invalid_priority")
	ErrInvalidStatus   = errors.New("support_feedback.invalid_status")
	ErrMissingTenant   = errors.New("support_feedback.missing_tenant")
	ErrMissingTitle    = errors.New("support_feedback.missing_title")
	ErrMissingBody     = errors.New("support_feedback.missing_description")
	ErrTooManyFiles    = errors.New("support_feedback.too_many_attachments")
	ErrInvalidAssignee = errors.New("support_feedback.invalid_assignee")
)

type Feedback struct {
	ID             int64          `json:"-"`
	UUID           string         `json:"uuid"`
	TenantID       int64          `json:"tenant_id"`
	TenantName     string         `json:"tenant_name,omitempty"`
	AccountID      *int64         `json:"account_id,omitempty"`
	AccountName    string         `json:"account_name,omitempty"`
	AgentID        *int64         `json:"agent_id,omitempty"`
	AgentName      string         `json:"agent_name,omitempty"`
	ConversationID *int64         `json:"conversation_id,omitempty"`
	MessageID      *int64         `json:"message_id,omitempty"`
	Source         string         `json:"source"`
	Category       string         `json:"category"`
	Priority       string         `json:"priority"`
	Status         string         `json:"status"`
	Title          string         `json:"title"`
	Description    string         `json:"description"`
	PageURL        string         `json:"page_url,omitempty"`
	ClientInfo     map[string]any `json:"client_info,omitempty"`
	Attachments    []any          `json:"attachments,omitempty"`
	AssignedTo     *int64         `json:"assigned_to,omitempty"`
	AssignedToName string         `json:"assigned_to_name,omitempty"`
	AssignedAt     *time.Time     `json:"assigned_at,omitempty"`
	HandlerNote    string         `json:"handler_note,omitempty"`
	HandledBy      *int64         `json:"handled_by,omitempty"`
	HandledByName  string         `json:"handled_by_name,omitempty"`
	HandledAt      *time.Time     `json:"handled_at,omitempty"`
	CreatedAt      time.Time      `json:"created_at"`
	UpdatedAt      time.Time      `json:"updated_at"`
}

type CreateInput struct {
	TenantID       int64
	AccountID      *int64
	AgentID        *int64
	ConversationID *int64
	MessageID      *int64
	Source         string
	Category       string
	Priority       string
	Status         string
	Title          string
	Description    string
	PageURL        string
	ClientInfo     map[string]any
	Attachments    []any
}

type UpdateInput struct {
	Status        string
	Priority      string
	HandlerNote   string
	AssignedTo    *int64
	AssignedToSet bool
}

type Filter struct {
	TenantID int64
	Status   string
	Category string
	Priority string
	Keyword  string
	Limit    int
	Offset   int
}

type Repository interface {
	Create(ctx context.Context, in CreateInput) (*Feedback, error)
	LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*Feedback, error)
	ListPlatform(ctx context.Context, f Filter) ([]Feedback, int64, error)
	UpdatePlatform(ctx context.Context, uuid string, actorID int64, in UpdateInput) (*Feedback, error)
}

func ValidSource(v string) bool {
	switch v {
	case SourceAgentChat, SourceAdminCreated, SourceSystemDetected:
		return true
	default:
		return false
	}
}

func ValidCategory(v string) bool {
	switch v {
	case CategoryUsageQuestion, CategoryBug, CategoryProductSuggestion, CategoryAccountAccess, CategoryPerformance, CategoryOther:
		return true
	default:
		return false
	}
}

func ValidPriority(v string) bool {
	switch v {
	case PriorityLow, PriorityNormal, PriorityHigh, PriorityUrgent:
		return true
	default:
		return false
	}
}

func ValidStatus(v string) bool {
	switch v {
	case StatusOpen, StatusTriaged, StatusInProgress, StatusResolved, StatusClosed:
		return true
	default:
		return false
	}
}
