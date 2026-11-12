package localcodingcatalog

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Signer signs the catalog with an Ed25519 key. The Bridge embeds the public
// key per environment and verifies the signature over CanonicalJSON(catalog).
type Signer struct {
	priv ed25519.PrivateKey
	kid  string
}

// NewSignerFromBase64 accepts either a 32-byte seed or a 64-byte private key,
// base64 (standard or URL, padded or not). kid names the key in the catalog.
func NewSignerFromBase64(encoded, kid string) (*Signer, error) {
	raw, err := decodeBase64Any(strings.TrimSpace(encoded))
	if err != nil {
		return nil, fmt.Errorf("catalog signing key: %w", err)
	}
	var priv ed25519.PrivateKey
	switch len(raw) {
	case ed25519.SeedSize:
		priv = ed25519.NewKeyFromSeed(raw)
	case ed25519.PrivateKeySize:
		priv = ed25519.PrivateKey(raw)
	default:
		return nil, errors.New("catalog signing key: need 32-byte seed or 64-byte private key")
	}
	kid = strings.TrimSpace(kid)
	if kid == "" {
		kid = "lc-catalog"
	}
	return &Signer{priv: priv, kid: kid}, nil
}

func (s *Signer) KeyID() string { return s.kid }

// PublicKeyBase64 is what gets embedded into the Bridge build.
func (s *Signer) PublicKeyBase64() string {
	return base64.StdEncoding.EncodeToString(s.priv.Public().(ed25519.PublicKey))
}

// Sign returns the base64url (unpadded) signature over payload.
func (s *Signer) Sign(payload []byte) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(s.priv, payload))
}

// Verify is the Bridge-side counterpart, kept here so the two stay in lockstep.
func Verify(publicKeyBase64, signature string, payload []byte) bool {
	pub, err := decodeBase64Any(publicKeyBase64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(signature, "="))
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), payload, sig)
}

// CanonicalJSON produces the byte form that is signed: keys sorted at every
// level, no insignificant whitespace, no HTML escaping, integers preserved
// (decoded with UseNumber so sizes never become floats).
func CanonicalJSON(v any) ([]byte, error) {
	first, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(first))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimRight(out.Bytes(), "\n"), nil
}

func decodeBase64Any(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("empty")
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if raw, err := enc.DecodeString(s); err == nil {
			return raw, nil
		}
	}
	return nil, errors.New("not base64")
}
