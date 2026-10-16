package modelsource

import (
	"context"
	"errors"
)

var ErrDenied = errors.New("model_source.unavailable")
var ErrConfiguration = errors.New("model_source.configuration_unavailable")

type Model struct {
	ToolUse  bool   `json:"tool_use"`
	ID       string `json:"id"`
	Label    string `json:"label"`
	Enabled  bool   `json:"enabled"`
	Modality string `json:"modality"`
}
type Config struct {
	ID        string            `json:"id"`
	CatalogID string            `json:"catalog_id"`
	Name      string            `json:"name"`
	Enabled   bool              `json:"enabled"`
	Protocol  string            `json:"protocol"`
	BaseURL   string            `json:"base_url"`
	APIKey    string            `json:"api_key"`
	Models    []Model           `json:"models"`
	Headers   map[string]string `json:"headers"`
}
type Stored struct {
	UUID        string
	SourceID    string
	Version     int64
	Fingerprint string
	Enabled     bool
	Ciphertext  []byte
}
type Scope struct{ TenantID, AccountID int64 }
type Repository interface {
	Replace(context.Context, Scope, []Stored) ([]Stored, error)
	List(context.Context, Scope) ([]Stored, error)
	Get(context.Context, Scope, string) (*Stored, error)
	RunActive(context.Context, Scope, int64, string) (bool, error)
	// Reconcile reads and transforms a member's sources under the settings lock.
	// The callback returns only changed existing rows, preserving their UUIDs.
	Reconcile(context.Context, Scope, func([]Stored) ([]Stored, error)) ([]Stored, error)
}

type RuntimeBinding struct {
	Model      string `json:"model"`
	Protocol   string `json:"protocol"`
	BaseURL    string `json:"base_url"`
	APIKey     string `json:"api_key"`
	ProviderID string `json:"provider_id"`
}
