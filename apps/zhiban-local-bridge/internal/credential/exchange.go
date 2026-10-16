package credential

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"strings"
	"time"
)

const maxExchangeResponseBytes = 64 << 10

// maxExchangeRefusalBytes bounds how much of a refused exchange is read: the
// body only has to carry one machine-readable reason.
const maxExchangeRefusalBytes = 4 << 10

// Reasons Bus puts in `message` when it refuses an exchange with 403
// (local-coding-tools-contract §换票被拒要说真话).
const (
	refusalInsufficientCredit = "local_coding.insufficient_credit"
	refusalMemberKeyDisabled  = "local_coding.member_key_disabled"
	refusalMemberKeyDenied    = "local_coding.member_key_denied" // Bus before 2026-09-20
	refusalMemberKeySyncing   = "local_coding.member_key_syncing"
)

type HTTPDoer interface {
	Do(*http.Request) (*http.Response, error)
}

type exchangeRequest struct {
	TargetID       string `json:"target_id"`
	ProfileVersion string `json:"profile_version"`
}

type exchangeResponse struct {
	Success bool                 `json:"success"`
	Code    int                  `json:"code"`
	Message string               `json:"message"`
	Data    exchangeResponseData `json:"data"`
	TraceID string               `json:"traceId,omitempty"`
}

type exchangeResponseData struct {
	AccessToken string    `json:"access_token"`
	TokenType   string    `json:"token_type"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func NewSecureHTTPClient() *http.Client {
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          4,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		ExpectContinueTimeout: time.Second,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}
	return &http.Client{
		Transport: transport,
		Timeout:   20 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func (m *Manager) ExchangeToken(ctx context.Context, targetID string) (string, error) {
	if !validTarget(targetID) {
		return "", ErrProfileUnsupported
	}
	identity, err := m.store.LoadIdentity(ctx)
	if errors.Is(err, ErrNotFound) {
		return "", ErrAuthorizationMissing
	}
	if err != nil {
		return "", err
	}
	defer zeroBytes(identity.PrivateKeySeed)
	if err := validateIdentity(identity); err != nil {
		return "", err
	}
	authorization, err := m.store.LoadAuthorization(ctx)
	if errors.Is(err, ErrNotFound) {
		return "", ErrAuthorizationMissing
	}
	if err != nil {
		return "", err
	}
	if err := validateAuthorization(authorization); err != nil || authorization.DeviceID != identity.DeviceID {
		return "", ErrInvalidData
	}
	scopeTarget := ScopeTarget(targetID)
	profileVersion, ok := authorization.ProfileVersions[scopeTarget]
	if !ok || !validSafeVersion(profileVersion) {
		return "", ErrProfileUnsupported
	}
	endpoint, ok := m.endpoints[authorization.Environment]
	if !ok {
		return "", ErrInvalidData
	}
	proof, _, err := newDPoPProof(identity.PrivateKeySeed, http.MethodPost, endpoint.ExchangeURL, authorization.DeviceCredential, m.now(), m.random)
	if err != nil {
		return "", err
	}
	body, err := json.Marshal(exchangeRequest{TargetID: scopeTarget, ProfileVersion: profileVersion})
	if err != nil {
		return "", ErrInvalidData
	}
	defer zeroBytes(body)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.ExchangeURL, bytes.NewReader(body))
	if err != nil {
		return "", ErrInvalidData
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "ZhibanDevice "+authorization.DeviceCredential)
	request.Header.Set("DPoP", proof)
	response, err := m.httpClient.Do(request)
	if err != nil {
		return "", ErrExchangeUnavailable
	}
	if response == nil || response.Body == nil {
		return "", ErrInvalidExchangeResponse
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= http.StatusInternalServerError {
		// Rate limiting and server-side failures pass on their own. They are
		// classified before the no-store check because a gateway's own error
		// page does not carry that header.
		return "", ErrExchangeUnavailable
	}
	if !hasNoStore(response.Header.Values("Cache-Control")) {
		return "", ErrInvalidExchangeResponse
	}
	if response.StatusCode != http.StatusOK {
		return "", exchangeRefusal(response)
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return "", ErrInvalidExchangeResponse
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxExchangeResponseBytes+1))
	if err != nil || len(raw) == 0 || len(raw) > maxExchangeResponseBytes {
		zeroBytes(raw)
		return "", ErrInvalidExchangeResponse
	}
	defer zeroBytes(raw)
	var decoded exchangeResponse
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return "", ErrInvalidExchangeResponse
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return "", ErrInvalidExchangeResponse
	}
	if !decoded.Success || decoded.Code != 0 || decoded.Data.TokenType != "Bearer" || !ValidAccessToken(decoded.Data.AccessToken) {
		return "", ErrInvalidExchangeResponse
	}
	now := m.now()
	if !decoded.Data.ExpiresAt.After(now) || decoded.Data.ExpiresAt.After(now.Add(16*time.Minute)) {
		return "", ErrInvalidExchangeResponse
	}
	return decoded.Data.AccessToken, nil
}

// exchangeRefusal tells a withheld member key apart from a refused device.
// Only a 403 that names one of the known reasons is treated specially; every
// other refusal stays ErrExchangeRejected, as it was before reasons existed.
func exchangeRefusal(response *http.Response) error {
	if response.StatusCode != http.StatusForbidden {
		return ErrExchangeRejected
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxExchangeRefusalBytes+1))
	if err != nil || len(raw) == 0 || len(raw) > maxExchangeRefusalBytes {
		return ErrExchangeRejected
	}
	var refusal struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &refusal); err != nil {
		return ErrExchangeRejected
	}
	switch strings.TrimSpace(refusal.Message) {
	case refusalInsufficientCredit:
		return ErrInsufficientCredit
	case refusalMemberKeyDisabled, refusalMemberKeyDenied:
		return ErrMemberKeyDisabled
	case refusalMemberKeySyncing:
		return ErrExchangeUnavailable
	default:
		return ErrExchangeRejected
	}
}

func hasNoStore(values []string) bool {
	for _, value := range values {
		for _, directive := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(directive), "no-store") {
				return true
			}
		}
	}
	return false
}

func ValidAccessToken(value string) bool {
	if value == "" || len(value) > 16<<10 {
		return false
	}
	for _, char := range value {
		if char <= 0x20 || char == 0x7f {
			return false
		}
	}
	return true
}
