// Package orgwebhook implements tenant org-sync webhook management.
package orgwebhook

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orgwebhook"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Deps struct {
	Repo                dom.Repository
	HTTPClient          *http.Client
	Now                 func() time.Time
	AllowLocalCallbacks bool
}

type Service struct {
	repo                dom.Repository
	client              *http.Client
	now                 func() time.Time
	allowLocalCallbacks bool
}

func New(d Deps) *Service {
	client := d.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &Service{repo: d.Repo, client: client, now: now, allowLocalCallbacks: d.AllowLocalCallbacks}
}

func (s *Service) List(ctx context.Context, tenantID int64) ([]dom.Config, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenantID required")
	}
	return s.repo.List(ctx, tenantID)
}

func (s *Service) Create(ctx context.Context, tenantID int64, in dom.CreateInput) (*dom.Config, string, error) {
	if tenantID <= 0 {
		return nil, "", apperr.ErrInvalidParams.Withf("tenantID required")
	}
	name, err := cleanName(in.Name)
	if err != nil {
		return nil, "", err
	}
	callbackURL, err := s.cleanCallbackURL(in.CallbackURL)
	if err != nil {
		return nil, "", err
	}
	events, err := cleanEventTypes(in.EventTypes)
	if err != nil {
		return nil, "", err
	}
	secret, err := genSigningSecret()
	if err != nil {
		return nil, "", apperr.ErrInternal.Wrap(err)
	}
	desc := strings.TrimSpace(in.Description)
	if len(desc) > 256 {
		return nil, "", apperr.ErrInvalidParams.Withf("description too long")
	}
	row := &dom.Config{
		TenantID:      tenantID,
		Name:          name,
		CallbackURL:   callbackURL,
		SigningSecret: secret,
		Enabled:       in.Enabled,
		EventTypes:    events,
		Description:   desc,
	}
	if err := s.repo.Insert(ctx, row); err != nil {
		return nil, "", err
	}
	return row, secret, nil
}

func (s *Service) Patch(ctx context.Context, tenantID int64, uuid string, in dom.PatchInput) (*dom.Config, error) {
	if tenantID <= 0 || strings.TrimSpace(uuid) == "" {
		return nil, apperr.ErrInvalidParams
	}
	fields := map[string]any{}
	if in.Name != nil {
		name, err := cleanName(*in.Name)
		if err != nil {
			return nil, err
		}
		fields["name"] = name
	}
	if in.CallbackURL != nil {
		callbackURL, err := s.cleanCallbackURL(*in.CallbackURL)
		if err != nil {
			return nil, err
		}
		fields["callback_url"] = callbackURL
	}
	if in.Enabled != nil {
		fields["enabled"] = *in.Enabled
	}
	if in.EventTypes != nil {
		events, err := cleanEventTypes(in.EventTypes)
		if err != nil {
			return nil, err
		}
		fields["event_types"] = events
	}
	if in.Description != nil {
		desc := strings.TrimSpace(*in.Description)
		if len(desc) > 256 {
			return nil, apperr.ErrInvalidParams.Withf("description too long")
		}
		fields["description"] = desc
	}
	return s.repo.Patch(ctx, tenantID, uuid, fields)
}

func (s *Service) Delete(ctx context.Context, tenantID int64, uuid string) error {
	if tenantID <= 0 || strings.TrimSpace(uuid) == "" {
		return apperr.ErrInvalidParams
	}
	return s.repo.SoftDelete(ctx, tenantID, uuid)
}

func (s *Service) RotateSecret(ctx context.Context, tenantID int64, uuid string) (*dom.Config, string, error) {
	if tenantID <= 0 || strings.TrimSpace(uuid) == "" {
		return nil, "", apperr.ErrInvalidParams
	}
	secret, err := genSigningSecret()
	if err != nil {
		return nil, "", apperr.ErrInternal.Wrap(err)
	}
	row, err := s.repo.Patch(ctx, tenantID, uuid, map[string]any{"signing_secret": secret})
	if err != nil {
		return nil, "", err
	}
	return row, secret, nil
}

func (s *Service) Test(ctx context.Context, tenantID int64, uuid string) (*dom.TestResult, error) {
	row, err := s.repo.Get(ctx, tenantID, uuid)
	if err != nil {
		return nil, err
	}
	if err := validateCallbackURL(row.CallbackURL, s.allowLocalCallbacks); err != nil {
		return nil, apperr.ErrInvalidParams.Wrap(err)
	}
	body, err := json.Marshal(map[string]any{
		"event_id":       "test_" + row.UUID,
		"event_type":     dom.EventWebhookTest,
		"tenant_id":      tenantID,
		"entity_uuid":    "",
		"updated_at":     s.now().UTC().Format(time.RFC3339),
		"schema_version": 1,
		"test":           true,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	ts := fmt.Sprintf("%d", s.now().Unix())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, row.CallbackURL, bytes.NewReader(body))
	if err != nil {
		return nil, apperr.ErrInvalidParams.Wrap(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Zhiban-Event-Id", "test_"+row.UUID)
	req.Header.Set("X-Zhiban-Event-Type", dom.EventWebhookTest)
	req.Header.Set("X-Zhiban-Timestamp", ts)
	req.Header.Set("X-Zhiban-Signature", computeHMAC(row.SigningSecret, ts, body))

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, apperr.ErrUpstreamUnavailable.Wrap(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &dom.TestResult{StatusCode: resp.StatusCode, Message: fmt.Sprintf("webhook returned %d", resp.StatusCode)}, nil
	}
	return &dom.TestResult{StatusCode: resp.StatusCode, Message: "ok"}, nil
}

func (s *Service) ListDeliveries(ctx context.Context, tenantID int64, uuid string, limit int) ([]dom.Delivery, error) {
	if tenantID <= 0 || strings.TrimSpace(uuid) == "" {
		return nil, apperr.ErrInvalidParams
	}
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	return s.repo.ListDeliveries(ctx, tenantID, uuid, limit)
}

func cleanName(v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", apperr.ErrInvalidParams.Withf("name required")
	}
	if len(v) > 128 {
		return "", apperr.ErrInvalidParams.Withf("name too long")
	}
	return v, nil
}

func (s *Service) cleanCallbackURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", apperr.ErrInvalidParams.Withf("callback_url required")
	}
	if len(raw) > 2048 {
		return "", apperr.ErrInvalidParams.Withf("callback_url too long")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", apperr.ErrInvalidParams.Wrap(err)
	}
	if u.Scheme != "https" && !(s.allowLocalCallbacks && u.Scheme == "http") {
		return "", apperr.ErrInvalidParams.Withf("callback_url must use https")
	}
	if err := validateCallbackURL(raw, s.allowLocalCallbacks); err != nil {
		return "", apperr.ErrInvalidParams.Wrap(err)
	}
	return raw, nil
}

func cleanEventTypes(in []string) ([]string, error) {
	if in == nil {
		return nil, nil
	}
	seen := map[string]bool{}
	out := []string{}
	allowed := map[string]bool{}
	for _, ev := range dom.AllowedOrgEvents {
		allowed[ev] = true
	}
	for _, ev := range in {
		ev = strings.TrimSpace(ev)
		if ev == "" {
			continue
		}
		if !allowed[ev] {
			return nil, apperr.ErrInvalidParams.Withf("unknown event_type %q", ev)
		}
		if !seen[ev] {
			seen[ev] = true
			out = append(out, ev)
		}
	}
	return out, nil
}

func genSigningSecret() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "whsec_" + base64.RawURLEncoding.EncodeToString(b[:]), nil
}

func computeHMAC(signingSecret, timestamp string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(signingSecret))
	mac.Write([]byte(timestamp))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

func validateCallbackURL(rawURL string, allowLocal bool) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "https" && !(allowLocal && u.Scheme == "http") {
		return fmt.Errorf("scheme must be https")
	}
	host := u.Hostname()
	if !allowLocal && isPrivateHost(host) {
		return fmt.Errorf("SSRF: private/reserved address %s", host)
	}
	return nil
}

func isPrivateHost(host string) bool {
	if host == "localhost" || host == "" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		addrs, err := net.LookupHost(host)
		if err != nil || len(addrs) == 0 {
			return false
		}
		ip = net.ParseIP(addrs[0])
		if ip == nil {
			return false
		}
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		isMetadataIP(ip) || strings.HasPrefix(ip.String(), "0.")
}

func isMetadataIP(ip net.IP) bool {
	meta := net.ParseIP("169.254.169.254")
	return ip.Equal(meta)
}
