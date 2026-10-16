package beebridge

import "context"

// LoginRecord is private storage; never serialize it in ordinary tenant APIs.
type LoginRecord struct {
	ResetOperationID    string
	ResetStage          string
	UserID              int64
	Username            string
	ProvisionStatus     string
	InitializationStage string
	PasswordCiphertext  []byte
}

type LoginInfoStore interface {
	ReadLoginInfo(context.Context, int64) (LoginRecord, error)
}

// LoginInfo is only returned by the dedicated, audited platform endpoint.
type LoginInfo struct {
	ResetOperationID    string `json:"reset_operation_id"`
	ResetStage          string `json:"reset_stage"`
	TenantID            int64  `json:"tenant_id"`
	UserID              int64  `json:"user_id"`
	Username            string `json:"username"`
	ProvisionStatus     string `json:"provision_status"`
	InitializationStage string `json:"initialization_stage"`
	PasswordSaved       bool   `json:"password_saved"`
	Password            string `json:"password"`
}
