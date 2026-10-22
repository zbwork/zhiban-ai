// Package config defines the community-only startup contract.
package config

import (
	"errors"
	"gopkg.in/yaml.v3"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	AppIssuer         string
	StorageQuotaBytes int64
	HTTP              string
	PostgresDSN       string
	RedisAddr         string
	RedisPassword     string
	JWTPrivateKeyFile string
	JWTIssuer         string
	Model             struct{ Provider, BaseURL, APIKey, Name string }
	Object            struct{ Endpoint, ReadEndpoint, Bucket, AccessKey, SecretKey string }
	WuKong            struct{ URL, Token, WSAddr, TCPAddr string }
}

func Load(path string) (Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return Config{}, err
	}
	defer f.Close()
	return Decode(f)
}
func Decode(r io.Reader) (Config, error) {
	var c Config
	decoder := yaml.NewDecoder(io.LimitReader(r, 65537))
	decoder.KnownFields(true)
	if err := decoder.Decode(&c); err != nil {
		return c, errors.New("invalid community YAML")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return c, errors.New("expected one YAML document")
	}
	for _, value := range []*string{&c.AppIssuer, &c.HTTP, &c.PostgresDSN, &c.RedisAddr, &c.RedisPassword, &c.JWTPrivateKeyFile, &c.JWTIssuer, &c.Model.Provider, &c.Model.BaseURL, &c.Model.APIKey, &c.Model.Name, &c.Object.Endpoint, &c.Object.ReadEndpoint, &c.Object.Bucket, &c.Object.AccessKey, &c.Object.SecretKey, &c.WuKong.URL, &c.WuKong.Token, &c.WuKong.WSAddr, &c.WuKong.TCPAddr} {
		missing := false
		*value = os.Expand(*value, func(key string) string {
			v, ok := os.LookupEnv(key)
			if !ok {
				missing = true
			}
			return v
		})
		if missing {
			return c, errors.New("required configuration environment variable missing")
		}
	}
	if c.AppIssuer != "" {
		u, err := url.Parse(c.AppIssuer)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return c, errors.New("appissuer requires an HTTPS public origin")
		}
		c.AppIssuer = strings.TrimRight(c.AppIssuer, "/")
	}
	if c.StorageQuotaBytes == 0 {
		c.StorageQuotaBytes = 10 << 30
	}
	if c.WuKong.URL != "" {
		u, err := url.Parse(c.WuKong.URL)
		ws, wsErr := url.Parse(c.WuKong.WSAddr)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.TrimSpace(c.WuKong.Token) == "" || wsErr != nil || (ws.Scheme != "ws" && ws.Scheme != "wss") || ws.Host == "" || ws.User != nil || ws.RawQuery != "" || ws.Fragment != "" {
			return c, errors.New("WuKong requires explicit REST URL, client WS address and webhook secret")
		}
	} else if c.WuKong.Token != "" || c.WuKong.WSAddr != "" || c.WuKong.TCPAddr != "" {
		return c, errors.New("incomplete WuKong configuration")
	}
	if c.StorageQuotaBytes < 0 {
		return c, errors.New("positive storage quota required")
	}
	if c.HTTP == "" {
		c.HTTP = "127.0.0.1:8080"
	}
	if _, _, err := net.SplitHostPort(c.HTTP); err != nil {
		return c, errors.New("invalid HTTP listen address")
	}
	if c.PostgresDSN == "" || c.RedisAddr == "" || c.JWTPrivateKeyFile == "" || c.JWTIssuer == "" {
		return c, errors.New("postgresdsn, redisaddr, jwtprivatekeyfile and jwtissuer required")
	}
	if _, _, err := net.SplitHostPort(c.RedisAddr); err != nil {
		return c, errors.New("invalid Redis address")
	}
	if c.Model.Provider == "" {
		c.Model.Provider = "mock"
	}
	switch c.Model.Provider {
	case "mock":
	case "openai-compatible":
		u, err := url.Parse(c.Model.BaseURL)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.TrimSpace(c.Model.Name) == "" || strings.TrimSpace(c.Model.APIKey) == "" {
			return c, errors.New("explicit HTTPS model endpoint, model name and API key required")
		}
	default:
		return c, errors.New("unsupported model provider")
	}
	return c, nil
}
