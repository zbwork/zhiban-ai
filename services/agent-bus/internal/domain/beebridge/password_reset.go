package beebridge

import (
	"context"
	"errors"
)

var ErrResetConflict = errors.New("beebridge: password reset requires existing operation recovery")

// PasswordReset is private durable state, never a response DTO.
type PasswordReset struct {
	OperationID          string   `json:"operation_id,omitempty"`
	PreviousOperationIDs []string `json:"previous_operation_ids,omitempty"`
	Stage                string   `json:"stage,omitempty"`
	UserID               int64    `json:"user_id,omitempty"`
	Username             string   `json:"username,omitempty"`
	ActorID              int64    `json:"actor_id,omitempty"`
	Ciphertext           []byte   `json:"ciphertext,omitempty"`
	ModelKeyChecked      bool     `json:"model_key_checked,omitempty"`
}

type ResetSnapshot struct {
	UserID             int64
	Username           string
	PATCiphertext      []byte
	ModelKeyCiphertext []byte
	Operation          PasswordReset
}

type PasswordResetStore interface {
	ReadPasswordReset(context.Context, int64) (ResetSnapshot, error)
	// Committed CAS. savePassword also atomically updates the permanent password.
	ComparePasswordReset(ctx context.Context, tenantID, userID int64, old, next PasswordReset, savePassword bool) (bool, error)
}

type PasswordResetResult struct {
	OperationID      string `json:"operation_id"`
	Status           string `json:"status"`
	Message          string `json:"message"`
	PasswordSaved    bool   `json:"password_saved"`
	LoginVerified    bool   `json:"login_verified"`
	PATVerified      bool   `json:"pat_verified"`
	ModelKeyChecked  bool   `json:"model_key_checked"`
	ModelKeyVerified bool   `json:"model_key_verified"`
}
