package drive

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"time"

	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const LocalUploadHeader = "X-Local-Upload-Ticket"
const LocalUploadPath = "/api/agent-bus/v1/local-runtime/uploads"
const LocalUploadMaxBytes int64 = 128 * 1024 * 1024

type localUploadProxy struct {
	url string
	key []byte
}
type localUploadClaims struct {
	Scope   local.Scope    `json:"scope"`
	Task    local.Task     `json:"task"`
	File    LocalOutputReq `json:"file"`
	Expires int64          `json:"exp"`
}

// ConfigureLocalUploadProxy uses a configured origin, never Host/Forwarded headers.
// The key is shared by replicas but domain-separated from login/run credentials.
func (s *ZAPSvc) ConfigureLocalUploadProxy(origin string, signingKey []byte) error {
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(origin), "/"))
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" || len(signingKey) < 32 {
		return fmt.Errorf("local upload requires a valid Bus origin and signing key")
	}
	loopback := u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost" || u.Hostname() == "::1"
	if u.Scheme != "https" && !(u.Scheme == "http" && loopback) {
		return fmt.Errorf("local upload Bus origin must use HTTPS (HTTP only on loopback)")
	}
	h := hmac.New(sha256.New, signingKey)
	_, _ = h.Write([]byte("zhiban-local-output-upload-v1"))
	s.localUpload = &localUploadProxy{url: u.String() + LocalUploadPath, key: h.Sum(nil)}
	return nil
}

func (s *ZAPSvc) proxyLocalSignature(task *local.Task, req LocalOutputReq, result *ZAPPresignResp) (*ZAPPresignResp, error) {
	if s.localUpload == nil || result.Uploaded {
		return result, nil
	}
	expires := time.Now().Add(10 * time.Minute)
	if result.ExpiresAt.Before(expires) {
		expires = result.ExpiresAt
	}
	claims := localUploadClaims{Scope: task.Scope, File: req, Expires: expires.Unix(), Task: local.Task{
		UUID: task.UUID, DeviceUUID: task.DeviceUUID, EmployeeUUID: task.EmployeeUUID, LocalEngine: task.LocalEngine, Fence: task.Fence,
	}}
	data, err := json.Marshal(claims)
	if err != nil {
		return nil, err
	}
	payload := base64.RawURLEncoding.EncodeToString(data)
	h := hmac.New(sha256.New, s.localUpload.key)
	_, _ = h.Write([]byte(payload))
	token := payload + "." + base64.RawURLEncoding.EncodeToString(h.Sum(nil))
	result.UploadURL = s.localUpload.url
	result.UploadHeaders = map[string]string{LocalUploadHeader: token, "Content-Type": strings.ToLower(strings.TrimSpace(req.MimeType))}
	result.ExpiresAt = expires
	result.ExpiresIn = int(time.Until(expires).Seconds())
	return result, nil
}

func (s *ZAPSvc) localUploadClaims(token string) (*localUploadClaims, error) {
	if s.localUpload == nil || len(token) > 16384 {
		return nil, apperr.ErrForbidden
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, apperr.ErrForbidden
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, apperr.ErrForbidden
	}
	h := hmac.New(sha256.New, s.localUpload.key)
	_, _ = h.Write([]byte(parts[0]))
	if !hmac.Equal(sig, h.Sum(nil)) {
		return nil, apperr.ErrForbidden
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, apperr.ErrForbidden
	}
	var claims localUploadClaims
	if json.Unmarshal(data, &claims) != nil || claims.Expires <= time.Now().Unix() || claims.Expires > time.Now().Add(10*time.Minute).Unix() {
		return nil, apperr.ErrForbidden
	}
	claims.Task.Scope = claims.Scope
	return &claims, nil
}

// UploadLocalOutput accepts only a signed snapshot. It never accepts a storage key
// or destination URL from the caller, and does not finalize the file (confirm does).
func (s *ZAPSvc) UploadLocalOutput(ctx context.Context, token, mime string, length int64, body io.Reader) error {
	claims, err := s.localUploadClaims(token)
	if err != nil {
		return err
	}
	task, req := &claims.Task, claims.File
	ticket, _, err := s.localOutputScope(ctx, task, req)
	if err != nil {
		return err
	}
	if body == nil || strings.ToLower(strings.TrimSpace(mime)) != strings.ToLower(strings.TrimSpace(req.MimeType)) || (length >= 0 && length != req.FileSize) {
		return apperr.ErrInvalidParams
	}
	stored, err := s.localOutputStoredTicket(ctx, task, req, ticket)
	if err != nil {
		return err
	}
	if stored.Status != "pending" || !stored.ExpiresAt.After(time.Now()) {
		return apperr.ErrForbidden
	}
	// A bounded, private temporary file prevents buffering 128 MiB per request and
	// ensures invalid hashes/lengths never reach object storage.
	f, err := os.CreateTemp("", "zhiban-local-upload-*")
	if err != nil {
		return apperr.ErrInternal
	}
	defer os.Remove(f.Name())
	defer f.Close()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, hash), io.LimitReader(body, req.FileSize+1))
	if err != nil {
		return apperr.ErrInvalidParams
	}
	if n != req.FileSize || hex.EncodeToString(hash.Sum(nil)) != req.SHA256 {
		return apperr.ErrInvalidParams
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if _, err = s.localUploadClaims(token); err != nil {
		return err
	}
	if _, _, err = s.localOutputScope(ctx, task, req); err != nil {
		return err
	}
	stored, err = s.localOutputStoredTicket(ctx, task, req, ticket)
	if err != nil {
		return err
	}
	if stored.Status != "pending" || !stored.ExpiresAt.After(time.Now()) {
		return apperr.ErrForbidden
	}
	if _, err = f.Seek(0, io.SeekStart); err != nil {
		return apperr.ErrInternal
	}
	store, err := s.storage.Resolve(ctx, task.Scope.TenantID)
	if err != nil {
		return err
	}
	putter, ok := store.(interface {
		PutObject(context.Context, string, io.Reader, int64, string) error
	})
	if !ok {
		return apperr.ErrInternal.Withf("drive.proxy_upload_not_supported")
	}
	if err = putter.PutObject(ctx, stored.StagingKey, f, req.FileSize, stored.DeclaredMime); err != nil {
		return apperr.ErrUpstreamUnavailable.Withf("drive.proxy_upload_failed")
	}
	return nil
}
