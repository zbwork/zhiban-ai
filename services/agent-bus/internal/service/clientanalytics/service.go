package clientanalytics

import (
	"context"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

var eventNamePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{1,63}$`)
var customEventPattern = regexp.MustCompile(`^custom_[a-z][a-z0-9_]{1,47}$`)
var propertyKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
var errorFingerprintPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var emailValuePattern = regexp.MustCompile(`(?i)\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b`)
var phoneValuePattern = regexp.MustCompile(`\b1[3-9][0-9]{9}\b`)
var bearerValuePattern = regexp.MustCompile(`(?i)\bbearer\s+[a-z0-9._~+/=\-]+`)
var uuidValuePattern = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b`)
var secretAssignmentValuePattern = regexp.MustCompile(`(?i)\b(access_token|refresh_token|token|secret|password|authorization)\s*[:=]\s*([^\s&]+)`)
var urlQueryValuePattern = regexp.MustCompile(`(?i)([?&][a-z0-9_.\-]+)=([^&\s]+)`)
var sensitiveKeyPattern = regexp.MustCompile(`(?i)(phone|mobile|email|token|secret|password|authorization|content|message|query|filename|file_name)`)

var allowedEvents = map[string]map[string]bool{
	"app_active": {"source": true},
	"app_error": {
		"error_type": true, "error_message": true, "stacktrace": true,
		"fingerprint": true, "mechanism": true, "severity": true,
	},
}

type service struct{ repo dom.Repository }

func New(repo dom.Repository) dom.Service { return &service{repo: repo} }

func (s *service) Record(ctx context.Context, tenantID, accountID int64, events []dom.Event) error {
	if tenantID <= 0 || accountID <= 0 || len(events) == 0 || len(events) > 20 {
		return dom.ErrInvalidEvent
	}
	for i := range events {
		e := &events[i]
		e.Name = strings.TrimSpace(e.Name)
		e.Platform = strings.ToLower(strings.TrimSpace(e.Platform))
		e.AppVersion = strings.TrimSpace(e.AppVersion)
		allowed, registered := allowedEvents[e.Name]
		isCustom := customEventPattern.MatchString(e.Name)
		if _, err := uuid.Parse(e.EventID); err != nil {
			return dom.ErrInvalidEvent
		}
		if _, err := uuid.Parse(e.SessionID); err != nil {
			return dom.ErrInvalidEvent
		}
		if (!registered && !isCustom) || e.SchemaVersion != 1 || !eventNamePattern.MatchString(e.Name) || !validPlatform(e.Platform) || len(e.AppVersion) > 32 || len(e.Properties) > 20 {
			return dom.ErrInvalidEvent
		}
		if e.Name == "app_active" && len(e.Properties) != 1 {
			return dom.ErrInvalidEvent
		}
		if e.Name == "app_error" && len(e.Properties) != 6 {
			return dom.ErrInvalidEvent
		}
		if isCustom && len(e.Properties) > 10 {
			return dom.ErrInvalidEvent
		}
		if e.OccurredAt.IsZero() || e.OccurredAt.Before(time.Now().Add(-7*24*time.Hour)) || e.OccurredAt.After(time.Now().Add(10*time.Minute)) {
			return dom.ErrInvalidEvent
		}
		for key, value := range e.Properties {
			if isCustom {
				if !validCustomProperty(key, value) {
					return dom.ErrInvalidEvent
				}
				continue
			}
			if !allowed[key] || !validProperty(e.Name, key, value) {
				return dom.ErrInvalidEvent
			}
		}
	}
	return s.repo.InsertBatch(ctx, tenantID, accountID, events)
}

func validProperty(eventName, key string, value any) bool {
	if eventName == "app_active" && key == "source" {
		source, ok := value.(string)
		return ok && (source == "launch" || source == "login" || source == "resume")
	}
	if eventName == "app_error" {
		return validErrorProperty(key, value)
	}
	return validShortValue(value)
}

func validCustomProperty(key string, value any) bool {
	if !propertyKeyPattern.MatchString(key) || sensitiveKeyPattern.MatchString(key) || !validShortValue(value) {
		return false
	}
	text, ok := value.(string)
	return !ok || !containsSensitiveValue(text)
}

func validErrorProperty(key string, value any) bool {
	text, ok := value.(string)
	if !ok || containsSensitiveValue(text) {
		return false
	}
	switch key {
	case "error_type":
		return len(text) > 0 && len(text) <= 128
	case "error_message":
		return len(text) <= 512
	case "stacktrace":
		return len(text) <= 8192
	case "fingerprint":
		return errorFingerprintPattern.MatchString(text)
	case "mechanism":
		return text == "flutter" || text == "platform" || text == "manual"
	case "severity":
		return text == "error" || text == "fatal" || text == "warn"
	default:
		return false
	}
}

func containsSensitiveValue(value string) bool {
	if emailValuePattern.MatchString(value) || phoneValuePattern.MatchString(value) || bearerValuePattern.MatchString(value) || uuidValuePattern.MatchString(value) {
		return true
	}
	for _, match := range secretAssignmentValuePattern.FindAllStringSubmatch(value, -1) {
		if len(match) == 3 && match[2] != "[redacted]" {
			return true
		}
	}
	for _, match := range urlQueryValuePattern.FindAllStringSubmatch(value, -1) {
		if len(match) == 3 && match[2] != "[redacted]" {
			return true
		}
	}
	withoutRedactedUsers := strings.ReplaceAll(value, "/Users/[redacted]/", "")
	withoutRedactedUsers = strings.ReplaceAll(withoutRedactedUsers, `C:\Users\[redacted]\`, "")
	return strings.Contains(withoutRedactedUsers, "/Users/") || strings.Contains(strings.ToLower(withoutRedactedUsers), `c:\users\`)
}

func validPlatform(platform string) bool {
	switch platform {
	case "android", "ios", "macos", "windows":
		return true
	default:
		return false
	}
}

func validShortValue(value any) bool {
	switch v := value.(type) {
	case string:
		return len(v) <= 64
	case bool, float64, int, int64:
		return true
	default:
		return false
	}
}
