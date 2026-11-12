package marketinglead

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/sms"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/marketinglead"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/smscode"
)

type Service interface {
	SendVerificationCode(ctx context.Context, in dom.SendCodeInput) error
	Create(ctx context.Context, in dom.CreateInput) (*dom.Lead, error)
	ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Lead, int64, error)
	UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Lead, error)
}

type Deps struct {
	Repo  dom.Repository
	Codes *smscode.Store
	SMS   sms.Sender
	Redis *redis.Client
}

type impl struct {
	repo  dom.Repository
	codes *smscode.Store
	sms   sms.Sender
	redis *redis.Client
}

func New(deps Deps) Service {
	return &impl{repo: deps.Repo, codes: deps.Codes, sms: deps.SMS, redis: deps.Redis}
}

var mainlandMobileRe = regexp.MustCompile(`^1\d{10}$`)

func (s *impl) SendVerificationCode(ctx context.Context, in dom.SendCodeInput) error {
	phone := normalizePhone(in.Phone)
	if !validPhone(phone) {
		return dom.ErrInvalidPhone
	}
	if err := s.rateLimit(ctx, "send:phone:"+phone, 5, time.Hour); err != nil {
		return err
	}
	if in.IPHash != "" {
		if err := s.rateLimit(ctx, "send:ip:"+in.IPHash, 20, time.Hour); err != nil {
			return err
		}
	}
	if s.codes == nil || s.sms == nil {
		return apperr.ErrInternal.Withf("marketing lead sms not wired")
	}
	code, err := s.codes.Issue(ctx, smscode.SceneMarketingContact, phone)
	if err != nil {
		if errors.Is(err, smscode.ErrCooldown) {
			return dom.ErrRateLimited
		}
		return err
	}
	return s.sms.Send(ctx, phone, "【知办AI】您的业务咨询验证码: "+code+",5 分钟内有效。")
}

func (s *impl) Create(ctx context.Context, in dom.CreateInput) (*dom.Lead, error) {
	in = normalizeCreate(in)
	if err := validateCreate(in); err != nil {
		return nil, err
	}
	if in.IPHash != "" {
		if err := s.rateLimit(ctx, "submit:ip:"+in.IPHash, 10, time.Hour); err != nil {
			return nil, err
		}
	}
	if err := s.rateLimit(ctx, "submit:phone:"+in.Phone, 5, time.Hour); err != nil {
		return nil, err
	}
	if s.codes == nil {
		return nil, apperr.ErrInternal.Withf("marketing lead smscode not wired")
	}
	if err := s.codes.Verify(ctx, smscode.SceneMarketingContact, in.Phone, in.VerificationCode); err != nil {
		switch {
		case errors.Is(err, smscode.ErrTooMany):
			return nil, dom.ErrVerificationTooMany
		case errors.Is(err, smscode.ErrMismatch):
			return nil, dom.ErrVerificationInvalid
		default:
			return nil, err
		}
	}
	return s.repo.Create(ctx, in)
}

func (s *impl) ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Lead, int64, error) {
	f.Status = strings.TrimSpace(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, 0, dom.ErrInvalidStatus
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	return s.repo.ListPlatform(ctx, f)
}

func (s *impl) UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Lead, error) {
	in.Status = strings.TrimSpace(in.Status)
	in.Remark = strings.TrimSpace(in.Remark)
	if in.Status != "" && !dom.ValidStatus(in.Status) {
		return nil, dom.ErrInvalidStatus
	}
	if len([]rune(in.Remark)) > dom.MaxRemarkLen {
		return nil, dom.ErrRemarkTooLong
	}
	if in.AssignedToSet && in.AssignedTo != nil && *in.AssignedTo <= 0 {
		return nil, dom.ErrInvalidAssignee
	}
	return s.repo.UpdatePlatform(ctx, uuid, actorID, in)
}

func (s *impl) rateLimit(ctx context.Context, key string, max int64, window time.Duration) error {
	if s.redis == nil || key == "" {
		return nil
	}
	k := "agbus:marketing_lead:rl:" + key
	n, err := s.redis.Incr(ctx, k).Result()
	if err != nil {
		return fmt.Errorf("marketinglead.rateLimit: %w", err)
	}
	if n == 1 {
		_ = s.redis.Expire(ctx, k, window).Err()
	}
	if n > max {
		return dom.ErrRateLimited
	}
	return nil
}

func normalizeCreate(in dom.CreateInput) dom.CreateInput {
	in.ContactName = trimLimit(in.ContactName, dom.MaxContactNameLen)
	in.Phone = normalizePhone(in.Phone)
	in.VerificationCode = strings.TrimSpace(in.VerificationCode)
	in.Company = trimLimit(in.Company, dom.MaxCompanyLen)
	in.Message = strings.TrimSpace(in.Message)
	in.Source = strings.TrimSpace(in.Source)
	if in.Source == "" {
		in.Source = dom.SourceZhibanWWW
	}
	in.PageURL = trimLimit(in.PageURL, dom.MaxPageURLLen)
	in.IPHash = strings.TrimSpace(in.IPHash)
	in.UserAgent = trimLimit(in.UserAgent, dom.MaxUserAgentLen)
	return in
}

func validateCreate(in dom.CreateInput) error {
	if in.ContactName == "" {
		return dom.ErrMissingContactName
	}
	if !validPhone(in.Phone) {
		return dom.ErrInvalidPhone
	}
	if in.VerificationCode == "" {
		return dom.ErrMissingCode
	}
	if in.Company == "" {
		return dom.ErrMissingCompany
	}
	if len([]rune(in.Message)) > dom.MaxMessageLen {
		return dom.ErrMessageTooLong
	}
	if !dom.ValidSource(in.Source) {
		return dom.ErrInvalidSource
	}
	return nil
}

func normalizePhone(v string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(v) {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func validPhone(v string) bool {
	return mainlandMobileRe.MatchString(v)
}

func trimLimit(v string, maxRunes int) string {
	v = strings.TrimSpace(v)
	r := []rune(v)
	if len(r) > maxRunes {
		return string(r[:maxRunes])
	}
	return v
}
