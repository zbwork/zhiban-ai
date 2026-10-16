package credential

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type doerFunc func(*http.Request) (*http.Response, error)

func (fn doerFunc) Do(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func authorizedStore() *memoryStore {
	return &memoryStore{
		identity: &Identity{
			SchemaVersion: identitySchemaVersion, DeviceID: testDeviceID,
			PrivateKeySeed: []byte("0123456789abcdef0123456789abcdef"),
		},
		authorization: &Authorization{
			SchemaVersion: authorizationSchemaVersion, DeviceID: testDeviceID,
			CredentialID:     testCredentialID,
			DeviceCredential: "lctd." + testCredentialID + "." + strings.Repeat("A", 48),
			Environment:      EnvironmentProd,
			ProfileVersions:  map[string]string{TargetCodexCLI: "2026.09.07.1"},
		},
	}
}

func TestExchangeTokenUsesStoredEndpointProfileAndDPoP(t *testing.T) {
	t.Parallel()

	store := authorizedStore()
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	client := doerFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodPost || request.URL.String() != "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange" {
			t.Fatalf("request target = %s %s", request.Method, request.URL)
		}
		if request.Header.Get("Authorization") != "ZhibanDevice "+store.authorization.DeviceCredential {
			t.Fatal("authorization header mismatch")
		}
		if request.Header.Get("Content-Type") != "application/json" || request.Header.Get("Accept") != "application/json" {
			t.Fatalf("request headers = %v", request.Header)
		}
		assertExchangeProofATH(t, request.Header.Get("DPoP"), store.authorization.DeviceCredential)
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		if string(body) != `{"target_id":"codex_cli","profile_version":"2026.09.07.1"}` {
			t.Fatalf("request body = %s", body)
		}
		return exchangeHTTPResponse(http.StatusOK, "no-store", `{"success":true,"code":0,"message":"ok","data":{"access_token":"short-lived.jwt.token","token_type":"Bearer","expires_at":"2026-09-07T10:15:00Z"}}`), nil
	})
	manager, err := NewManager(ManagerConfig{
		Store: store,
		Endpoints: map[Environment]Endpoints{EnvironmentProd: {
			RegisterURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/devices",
			ExchangeURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange",
		}},
		Now: func() time.Time { return now }, Random: strings.NewReader(strings.Repeat("r", 64)), HTTPClient: client,
	})
	if err != nil {
		t.Fatal(err)
	}
	token, err := manager.ExchangeToken(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("ExchangeToken() error = %v", err)
	}
	if token != "short-lived.jwt.token" {
		t.Fatalf("token = %q", token)
	}
}

func TestExchangeTokenFailsClosedOnMissingAuthorizationAndInvalidResponse(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		store     Store
		response  *http.Response
		clientErr error
		want      error
	}{
		{name: "missing authorization", store: &memoryStore{}, want: ErrAuthorizationMissing},
		{name: "network failure", store: authorizedStore(), clientErr: errors.New("dial failed"), want: ErrExchangeUnavailable},
		{name: "redirect", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusFound, "no-store", `{}`), want: ErrExchangeRejected},
		{name: "missing no-store", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusOK, "", `{"success":true}`), want: ErrInvalidExchangeResponse},
		// 换票被拒要说真话(2026-09-20):只有 401 才是"设备授权失效"。
		{name: "device credential refused", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusUnauthorized, "no-store", `{"success":false,"code":40100,"message":"local_coding.device_unauthorized"}`), want: ErrExchangeRejected},
		{name: "out of credit", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"success":false,"code":40300,"message":"local_coding.insufficient_credit","traceId":"t-1"}`), want: ErrInsufficientCredit},
		{name: "member key disabled", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"success":false,"code":40300,"message":"local_coding.member_key_disabled"}`), want: ErrMemberKeyDisabled},
		{name: "member key denied by an older Bus", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"success":false,"code":40300,"message":"local_coding.member_key_denied"}`), want: ErrMemberKeyDisabled},
		{name: "member key status still synchronizing", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"success":false,"code":40300,"message":"local_coding.member_key_syncing"}`), want: ErrExchangeUnavailable},
		{name: "forbidden without a known reason", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"success":false,"code":40300,"message":"forbidden"}`), want: ErrExchangeRejected},
		{name: "forbidden with an unreadable body", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `<html>blocked</html>`), want: ErrExchangeRejected},
		{name: "forbidden with an oversized body", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusForbidden, "no-store", `{"message":"`+strings.Repeat("x", maxExchangeRefusalBytes)+`"}`), want: ErrExchangeRejected},
		{name: "rate limited", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusTooManyRequests, "no-store", `{"success":false,"code":42900,"message":"local_coding.rate_limited"}`), want: ErrExchangeUnavailable},
		{name: "upstream unavailable", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusBadGateway, "no-store", `{"success":false,"code":50200,"message":"upstream unavailable"}`), want: ErrExchangeUnavailable},
		// 网关/反代自己回的 5xx 不带 no-store,也不该被说成"协议不匹配"。
		{name: "gateway error page", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusServiceUnavailable, "", `<html>503</html>`), want: ErrExchangeUnavailable},
		{name: "unknown response field", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusOK, "no-store", `{"success":true,"code":0,"message":"ok","unexpected":"secret"}`), want: ErrInvalidExchangeResponse},
		{name: "wrong token type", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusOK, "no-store", `{"success":true,"code":0,"message":"ok","data":{"access_token":"token","token_type":"Basic","expires_at":"2026-09-07T10:15:00Z"}}`), want: ErrInvalidExchangeResponse},
		{name: "expired token", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusOK, "no-store", `{"success":true,"code":0,"message":"ok","data":{"access_token":"token","token_type":"Bearer","expires_at":"2026-09-07T09:59:59Z"}}`), want: ErrInvalidExchangeResponse},
		{name: "oversized body", store: authorizedStore(), response: exchangeHTTPResponse(http.StatusOK, "no-store", strings.Repeat("x", maxExchangeResponseBytes+1)), want: ErrInvalidExchangeResponse},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := doerFunc(func(*http.Request) (*http.Response, error) { return test.response, test.clientErr })
			manager, err := NewManager(ManagerConfig{
				Store: test.store,
				Endpoints: map[Environment]Endpoints{EnvironmentProd: {
					RegisterURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/devices",
					ExchangeURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange",
				}},
				Now: func() time.Time { return now }, Random: strings.NewReader(strings.Repeat("s", 64)), HTTPClient: client,
			})
			if err != nil {
				t.Fatal(err)
			}
			token, err := manager.ExchangeToken(context.Background(), TargetCodexCLI)
			if !errors.Is(err, test.want) {
				t.Fatalf("ExchangeToken() error = %v, want %v", err, test.want)
			}
			if token != "" {
				t.Fatalf("failed exchange returned token %q", token)
			}
		})
	}
}

func TestSecureHTTPClientDisablesProxyAndRedirects(t *testing.T) {
	t.Parallel()

	client := NewSecureHTTPClient()
	transport, ok := client.Transport.(*http.Transport)
	if !ok || transport.Proxy != nil {
		t.Fatalf("secure transport proxy = %#v", client.Transport)
	}
	request, err := http.NewRequest(http.MethodGet, "https://zb.qkfintech.cn/redirect", nil)
	if err != nil {
		t.Fatal(err)
	}
	if client.CheckRedirect == nil || !errors.Is(client.CheckRedirect(request, nil), http.ErrUseLastResponse) {
		t.Fatal("secure client must reject redirects")
	}
}

func exchangeHTTPResponse(status int, cacheControl, body string) *http.Response {
	header := make(http.Header)
	header.Set("Content-Type", "application/json")
	if cacheControl != "" {
		header.Set("Cache-Control", cacheControl)
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body))}
}

func assertExchangeProofATH(t *testing.T, proof, deviceCredential string) {
	t.Helper()
	parts := strings.Split(proof, ".")
	if len(parts) != 3 {
		t.Fatalf("DPoP proof segments = %d", len(parts))
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims struct {
		HTTPMethod string `json:"htm"`
		HTTPURI    string `json:"htu"`
		TokenHash  string `json:"ath"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(deviceCredential))
	if claims.HTTPMethod != http.MethodPost || claims.HTTPURI != "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange" || claims.TokenHash != base64.RawURLEncoding.EncodeToString(digest[:]) {
		t.Fatalf("DPoP claims = %+v", claims)
	}
}
