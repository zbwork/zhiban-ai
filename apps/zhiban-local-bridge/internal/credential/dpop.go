package credential

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

type publicJWK struct {
	KeyType string `json:"kty"`
	Curve   string `json:"crv"`
	X       string `json:"x"`
}

type dpopHeader struct {
	Type string    `json:"typ"`
	Alg  string    `json:"alg"`
	JWK  publicJWK `json:"jwk"`
}

type dpopClaims struct {
	HTTPMethod string `json:"htm"`
	HTTPURI    string `json:"htu"`
	IssuedAt   int64  `json:"iat"`
	JWTID      string `json:"jti"`
	TokenHash  string `json:"ath,omitempty"`
}

func newDPoPProof(seed []byte, method, endpoint, accessToken string, now time.Time, random io.Reader) (string, json.RawMessage, error) {
	if len(seed) != ed25519.SeedSize || method != "POST" || endpoint == "" || random == nil {
		return "", nil, ErrInvalidData
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	defer zeroBytes(privateKey)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	jwk := publicJWK{
		KeyType: "OKP",
		Curve:   "Ed25519",
		X:       base64.RawURLEncoding.EncodeToString(publicKey),
	}
	headerJSON, err := json.Marshal(dpopHeader{Type: "dpop+jwt", Alg: "EdDSA", JWK: jwk})
	if err != nil {
		return "", nil, fmt.Errorf("credential: encode DPoP header: %w", err)
	}
	jtiBytes := make([]byte, 16)
	if _, err := io.ReadFull(random, jtiBytes); err != nil {
		return "", nil, fmt.Errorf("credential: generate DPoP jti: %w", err)
	}
	claims := dpopClaims{
		HTTPMethod: method,
		HTTPURI:    endpoint,
		IssuedAt:   now.UTC().Unix(),
		JWTID:      base64.RawURLEncoding.EncodeToString(jtiBytes),
	}
	zeroBytes(jtiBytes)
	if accessToken != "" {
		digest := sha256.Sum256([]byte(accessToken))
		claims.TokenHash = base64.RawURLEncoding.EncodeToString(digest[:])
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", nil, fmt.Errorf("credential: encode DPoP claims: %w", err)
	}
	encodedHeader := base64.RawURLEncoding.EncodeToString(headerJSON)
	encodedClaims := base64.RawURLEncoding.EncodeToString(claimsJSON)
	signingInput := encodedHeader + "." + encodedClaims
	signature := ed25519.Sign(privateKey, []byte(signingInput))
	proof := strings.Join([]string{signingInput, base64.RawURLEncoding.EncodeToString(signature)}, ".")
	zeroBytes(signature)
	publicJSON, err := json.Marshal(jwk)
	if err != nil {
		return "", nil, errors.Join(ErrInvalidData, err)
	}
	return proof, json.RawMessage(publicJSON), nil
}

func zeroBytes(value []byte) {
	for index := range value {
		value[index] = 0
	}
}
