package marketinglead

import (
	"context"
	"errors"
	"time"
)

const (
	SourceZhibanWWW = "zhiban-www"

	StatusNew       = "new"
	StatusContacted = "contacted"
	StatusQualified = "qualified"
	StatusClosed    = "closed"
	StatusSpam      = "spam"
)

const (
	MaxContactNameLen = 80
	MaxPhoneLen       = 32
	MaxCompanyLen     = 120
	MaxMessageLen     = 255
	MaxPageURLLen     = 1000
	MaxRemarkLen      = 1000
	MaxUserAgentLen   = 512
)

var (
	ErrInvalidPhone        = errors.New("marketing_lead.invalid_phone")
	ErrInvalidSource       = errors.New("marketing_lead.invalid_source")
	ErrInvalidStatus       = errors.New("marketing_lead.invalid_status")
	ErrMissingContactName  = errors.New("marketing_lead.missing_contact_name")
	ErrMissingCompany      = errors.New("marketing_lead.missing_company")
	ErrMissingCode         = errors.New("marketing_lead.missing_verification_code")
	ErrMessageTooLong      = errors.New("marketing_lead.message_too_long")
	ErrRemarkTooLong       = errors.New("marketing_lead.remark_too_long")
	ErrInvalidAssignee     = errors.New("marketing_lead.invalid_assignee")
	ErrVerificationInvalid = errors.New("marketing_lead.verification_invalid")
	ErrVerificationTooMany = errors.New("marketing_lead.verification_too_many")
	ErrRateLimited         = errors.New("marketing_lead.rate_limited")
)

type Lead struct {
	ID             int64      `json:"-"`
	UUID           string     `json:"uuid"`
	ContactName    string     `json:"contact_name"`
	Phone          string     `json:"phone,omitempty"`
	PhoneMasked    string     `json:"phone_masked"`
	Company        string     `json:"company"`
	Message        string     `json:"message"`
	Source         string     `json:"source"`
	PageURL        string     `json:"page_url,omitempty"`
	Status         string     `json:"status"`
	AssignedTo     *int64     `json:"assigned_to,omitempty"`
	AssignedToName string     `json:"assigned_to_name,omitempty"`
	AssignedAt     *time.Time `json:"assigned_at,omitempty"`
	HandledBy      *int64     `json:"handled_by,omitempty"`
	HandledByName  string     `json:"handled_by_name,omitempty"`
	HandledAt      *time.Time `json:"handled_at,omitempty"`
	Remark         string     `json:"remark,omitempty"`
	IPHash         string     `json:"-"`
	UserAgent      string     `json:"user_agent,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type SendCodeInput struct {
	Phone  string
	IPHash string
}

type CreateInput struct {
	ContactName      string
	Phone            string
	VerificationCode string
	Company          string
	Message          string
	Source           string
	PageURL          string
	IPHash           string
	UserAgent        string
}

type UpdateInput struct {
	Status        string
	Remark        string
	AssignedTo    *int64
	AssignedToSet bool
}

type Filter struct {
	Status     string
	Keyword    string
	CreatedGTE *time.Time
	CreatedLTE *time.Time
	Limit      int
	Offset     int
}

type Repository interface {
	Create(ctx context.Context, in CreateInput) (*Lead, error)
	ListPlatform(ctx context.Context, f Filter) ([]Lead, int64, error)
	UpdatePlatform(ctx context.Context, uuid string, actorID int64, in UpdateInput) (*Lead, error)
}

func ValidSource(v string) bool {
	return v == SourceZhibanWWW
}

func ValidStatus(v string) bool {
	switch v {
	case StatusNew, StatusContacted, StatusQualified, StatusClosed, StatusSpam:
		return true
	default:
		return false
	}
}

func MaskPhone(v string) string {
	if len(v) != 11 {
		return v
	}
	return v[:3] + "****" + v[7:]
}
