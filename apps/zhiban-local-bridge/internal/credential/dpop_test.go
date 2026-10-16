package credential

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestExchangeDPoPProofBindsDeviceCredential(t *testing.T) {
	t.Parallel()

	seed := []byte("0123456789abcdef0123456789abcdef")
	deviceCredential := "lctd." + testCredentialID + "." + strings.Repeat("A", 48)
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	proof, _, err := newDPoPProof(
		seed,
		"POST",
		"https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange",
		deviceCredential,
		now,
		strings.NewReader(strings.Repeat("j", 32)),
	)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(proof, ".")
	if len(parts) != 3 {
		t.Fatalf("proof segments = %d", len(parts))
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims struct {
		TokenHash string `json:"ath"`
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(deviceCredential))
	want := base64.RawURLEncoding.EncodeToString(digest[:])
	if claims.TokenHash != want {
		t.Fatalf("ath = %q, want %q", claims.TokenHash, want)
	}
}

func assertRegistrationProof(t *testing.T, prepared RegistrationPreparation, seed []byte, now time.Time) {
	t.Helper()

	parts := strings.Split(prepared.DPoPProof, ".")
	if len(parts) != 3 {
		t.Fatalf("DPoP segments = %d, want 3", len(parts))
	}
	decode := func(segment string, destination any) {
		t.Helper()
		raw, err := base64.RawURLEncoding.DecodeString(segment)
		if err != nil {
			t.Fatalf("decode DPoP segment: %v", err)
		}
		if err := json.Unmarshal(raw, destination); err != nil {
			t.Fatalf("decode DPoP JSON: %v", err)
		}
	}
	var header struct {
		Type string `json:"typ"`
		Alg  string `json:"alg"`
		JWK  struct {
			KeyType string `json:"kty"`
			Curve   string `json:"crv"`
			X       string `json:"x"`
			D       string `json:"d"`
		} `json:"jwk"`
	}
	decode(parts[0], &header)
	if header.Type != "dpop+jwt" || header.Alg != "EdDSA" || header.JWK.KeyType != "OKP" || header.JWK.Curve != "Ed25519" || header.JWK.D != "" {
		t.Fatalf("DPoP header = %+v", header)
	}
	var claims struct {
		HTTPMethod string `json:"htm"`
		HTTPURI    string `json:"htu"`
		IssuedAt   int64  `json:"iat"`
		JWTID      string `json:"jti"`
		TokenHash  string `json:"ath"`
	}
	decode(parts[1], &claims)
	if claims.HTTPMethod != "POST" || claims.HTTPURI != "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/devices" || claims.IssuedAt != now.Unix() || len(claims.JWTID) < 16 || claims.TokenHash != "" {
		t.Fatalf("DPoP claims = %+v", claims)
	}
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	encodedPublic := base64.RawURLEncoding.EncodeToString(publicKey)
	if header.JWK.X != encodedPublic || string(prepared.DevicePublicJWK) != `{"kty":"OKP","crv":"Ed25519","x":"`+encodedPublic+`"}` {
		t.Fatalf("public JWK mismatch: header=%q result=%s", header.JWK.X, prepared.DevicePublicJWK)
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(publicKey, []byte(parts[0]+"."+parts[1]), signature) {
		t.Fatal("DPoP signature verification failed")
	}
}
