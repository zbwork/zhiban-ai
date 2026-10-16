package beebridge

import (
	"context"
	"errors"
)

var (
	ErrBindingMissing   = errors.New("beebridge: tenant PAT is not ready")
	ErrTokenMissing     = errors.New("beebridge: register the member token ID before starting the runtime")
	ErrIdentityMismatch = errors.New("beebridge: credential owner does not match tenant")
	ErrRebind           = errors.New("beebridge: existing user or member token cannot be rebound")
	ErrAccessDenied     = errors.New("beebridge: tenant or member is inactive")
	ErrDisabled         = errors.New("beebridge: member key is disabled or awaiting status synchronization")
	ErrCipher           = errors.New("beebridge: credential encryption is unavailable or invalid")
	ErrTokenNotReady    = errors.New("beebridge: token is disabled, expired or exhausted")
)

// Sensitive records are internal storage values, never transport DTOs.
type TenantBinding struct {
	UserID        int64
	PATCiphertext []byte
	Status        string
}

type MemberCredential struct {
	TokenID            int64
	KeyCiphertext      []byte
	DisableReasons     []string
	SyncPending        bool
	MemberActive       bool
	TenantInactive     bool
	MembershipInactive bool
}

// Callbacks execute under repository-owned per-tenant/member serialization.
// Every mutation of a member's status intent must use the same member lock.
// Session implementations and transaction handles must not escape callbacks.
type CredentialStore interface {
	WithTenant(context.Context, int64, func(TenantSession) error) error
	WithMember(context.Context, int64, int64, func(MemberSession) error) error
}
type TenantSession interface {
	Binding(context.Context) (TenantBinding, error)
	SaveBinding(context.Context, int64, []byte) error
}
type MemberSession interface {
	Binding(context.Context) (TenantBinding, error)
	Credential(context.Context) (MemberCredential, error)
	SaveKey(context.Context, int64, []byte, int64) error
	SaveIntent(context.Context, []string, bool) error
}

type TenantMemberState struct {
	AccountID   int64
	SyncPending bool
}
type TenantCredentialLister interface {
	TenantMemberStates(context.Context, int64) (members []TenantMemberState, hasHistory bool, err error)
}
