package beebridge

import (
	"context"
	"time"
)

const (
	GroupFree = "知办AI-free"
	GroupPaid = "知办AI"
)

type ExpenseDelivery struct {
	SubscriptionID string    `json:"subscription_id"`
	UserID         string    `json:"user_id"`
	EndpointURL    string    `json:"endpoint_url"`
	Interval       int       `json:"interval_seconds"`
	Status         string    `json:"status"`
	Version        string    `json:"version"`
	EnabledFrom    time.Time `json:"enabled_from"`
	SecretSet      bool      `json:"secret_configured"`
}
type ExpenseDeliveryState struct {
	Configured   bool             `json:"configured"`
	Subscription *ExpenseDelivery `json:"subscription"`
}
type ExpenseDeliveryRequest struct {
	EndpointURL string `json:"endpoint_url"`
	Interval    int    `json:"interval_seconds"`
	Status      string `json:"status"`
	Version     string `json:"version"`
}
type ExpenseDeliveryResult struct {
	Subscription ExpenseDelivery `json:"subscription"`
	Secret       string          `json:"secret"`
	// The rotation endpoint returns secret + version without a subscription.
	Version string `json:"version,omitempty"`
}

type TenantLifecycle struct {
	TenantID                int64
	UserID                  int64
	PATCiphertext           []byte
	DesiredGroup            string
	AppliedGroup            string
	GroupSyncStatus         string
	SubscriptionID          string
	SigningSecretCiphertext []byte
	EndpointURL             string
	Interval                int
	RemoteVersion           string
	SubscriptionStatus      string
	ProvisionStatus         string
	IdempotencyKey          string
	SecretRotationKey       string
}

type LifecycleStore interface {
	ListLifecycleCandidates(context.Context, int64, int) ([]TenantLifecycle, error)
	ListTenantTokenIDs(context.Context, int64) ([]int64, error)
	SaveGroupState(context.Context, int64, string, string, string) error
	EnsureSubscriptionIntent(context.Context, TenantLifecycle) (TenantLifecycle, error)
	// PrepareSecretRotation pins the request version until the secret is saved.
	// An empty result means another worker already saved the secret or stopped the operation for review.
	PrepareSecretRotation(context.Context, int64, string) (string, error)
	SaveSubscription(context.Context, int64, ExpenseDelivery, []byte) error
	SaveLifecycleError(context.Context, int64, string, string) error
}

type SecretCipher interface {
	Encrypt([]byte) ([]byte, error)
	Decrypt([]byte) ([]byte, error)
}
