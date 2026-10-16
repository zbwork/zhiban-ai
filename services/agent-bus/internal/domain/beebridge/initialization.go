package beebridge

import (
	"context"
	"errors"
)

var ErrInitializationReview = errors.New("beebridge: initialization requires verification; do not recreate resources")

// Initialization is private storage, never an API DTO. PasswordCiphertext is
// retained after PAT binding for audited platform credential access.
type Initialization struct {
	Stage              string `json:"stage,omitempty"`
	Name               string `json:"name,omitempty"`
	PasswordCiphertext []byte `json:"password_ciphertext,omitempty"`
	ActorID            int64  `json:"actor_id,omitempty"`
}

type InitializationSnapshot struct {
	Progress Initialization
	Binding  TenantBinding
	TokenID  int64
}

// accountID=0 addresses the tenant itself (trusted service/admin only). Positive
// account IDs must be active members before reads or committed CAS mutations.
type InitializationStore interface {
	ReadInitialization(context.Context, int64, int64) (InitializationSnapshot, error)
	CompareInitialization(context.Context, int64, int64, Initialization, Initialization) (bool, error)
}
