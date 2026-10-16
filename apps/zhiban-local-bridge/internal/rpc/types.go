package rpc

import (
	"context"
	"encoding/json"
)

const (
	ProtocolVersion = "1.0"
	MaxFrameBytes   = 1 << 20

	CodeParseError         = -32700
	CodeInvalidRequest     = -32600
	CodeMethodNotFound     = -32601
	CodeInvalidParams      = -32602
	CodeInternalError      = -32603
	CodeNotInitialized     = -32002
	CodeAlreadyInitialized = -32003
	// CodeDomainError carries exactly one contract §6 error code in message.
	CodeDomainError = -32000
)

type DetectFunc func(context.Context, string) (any, error)
type CredentialPrepareFunc func(context.Context, CredentialPrepareParams) (any, error)
type CredentialCommitFunc func(context.Context, CredentialCommitParams) error
type CredentialStatusFunc func(context.Context) (any, error)
type CredentialClearFunc func(context.Context) error
type ConfigStatusFunc func(context.Context, string) (any, error)
type ConfigPlanFunc func(context.Context, ConfigPlanParams) (any, error)
type ConfigExecuteFunc func(context.Context, string) (any, error)
type ConfigRestoreFunc func(context.Context, string) (any, error)
type ProjectGrantCreateFunc func(context.Context, ProjectGrantCreateParams) (any, error)
type LaunchPlanFunc func(context.Context, LaunchPlanParams) (any, error)
type LaunchExecuteFunc func(context.Context, string) (any, error)
type RequirementsFunc func(context.Context, string) (any, error)
type InstallPlanFunc func(context.Context, InstallPlanParams) (any, error)
type InstallExecuteFunc func(context.Context, string) (any, error)
type OperationGetFunc func(context.Context, string) (any, error)
type OperationCancelFunc func(context.Context, string) (any, error)
type VerifyExecuteFunc func(context.Context, VerifyExecuteParams) (any, error)
type DiagnosticsLatestFunc func(context.Context, string) (any, error)
type CatalogApplyFunc func(context.Context, CatalogApplyParams) (any, error)

type Config struct {
	BridgeVersion      string
	Platform           string
	Arch               string
	Detect             DetectFunc
	CredentialPrepare  CredentialPrepareFunc
	CredentialCommit   CredentialCommitFunc
	CredentialStatus   CredentialStatusFunc
	CredentialClear    CredentialClearFunc
	ConfigStatus       ConfigStatusFunc
	ConfigPlan         ConfigPlanFunc
	ConfigExecute      ConfigExecuteFunc
	ConfigRestore      ConfigRestoreFunc
	ProjectGrantCreate ProjectGrantCreateFunc
	LaunchPlan         LaunchPlanFunc
	LaunchExecute      LaunchExecuteFunc
	Requirements       RequirementsFunc
	InstallPlan        InstallPlanFunc
	InstallExecute     InstallExecuteFunc
	OperationGet       OperationGetFunc
	OperationCancel    OperationCancelFunc
	VerifyExecute      VerifyExecuteFunc
	DiagnosticsLatest  DiagnosticsLatestFunc
	// CatalogApply verifies and applies the signed version catalog (F31
	// version catalog plan §4); when set, install.plan also accepts the
	// upgrade and rollback modes.
	CatalogApply CatalogApplyFunc
	// NetworkProxy* detect and fix the system proxy intercepting the Zhiban
	// gateway (contract §2.7 network.*). Optional.
	NetworkProxyStatus NetworkProxyFunc
	NetworkProxyApply  NetworkProxyFunc
}

// NetworkProxyFunc handles a parameterless network.proxy_* method.
type NetworkProxyFunc func(context.Context) (any, error)

type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *ErrorObject    `json:"error,omitempty"`
}

type ErrorObject struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type InitializeParams struct {
	ProtocolVersion string `json:"protocol_version"`
	AppVersion      string `json:"app_version"`
	Platform        string `json:"platform"`
	Arch            string `json:"arch"`
	Locale          string `json:"locale,omitempty"`
}

type InitializeResult struct {
	ProtocolVersion  string   `json:"protocol_version"`
	BridgeVersion    string   `json:"bridge_version"`
	SupportedMethods []string `json:"supported_methods"`
}

type DetectParams struct {
	TargetID string `json:"target_id"`
}

// CatalogApplyParams is the envelope the Bus returned, forwarded verbatim,
// plus the App's environment (which selects the trusted keys). A null or
// absent catalog clears the applied catalog; kid and signature are then empty.
type CatalogApplyParams struct {
	Environment string          `json:"environment"`
	KID         string          `json:"kid,omitempty"`
	Signature   string          `json:"signature,omitempty"`
	Catalog     json.RawMessage `json:"catalog"`
}

type CredentialPrepareParams struct {
	DeviceID    string `json:"device_id"`
	Environment string `json:"environment"`
}

type CredentialCommitParams struct {
	CredentialID     string            `json:"credential_id"`
	DeviceCredential string            `json:"device_credential"`
	ProfileVersions  map[string]string `json:"profile_versions"`
}

type ConfigTargetParams struct {
	TargetID string `json:"target_id"`
}

type ConfigPlanParams struct {
	TargetID       string `json:"target_id"`
	InstallationID string `json:"installation_id"`
	Type           string `json:"type,omitempty"`
}

type ConfigExecuteParams struct {
	PlanID string `json:"plan_id"`
}

type ProjectGrantCreateParams struct {
	BookmarkData string `json:"bookmark_data"`
}

type LaunchPlanParams struct {
	TargetID       string `json:"target_id"`
	InstallationID string `json:"installation_id"`
	ProjectGrantID string `json:"project_grant_id,omitempty"`
	ProfileVersion string `json:"profile_version,omitempty"`
	Mode           string `json:"mode,omitempty"`
}

type LaunchExecuteParams struct {
	PlanID string `json:"plan_id"`
}

type InstallPlanParams struct {
	TargetID string `json:"target_id"`
	Mode     string `json:"mode,omitempty"`
	// Component requests a runtime component install instead of the tool
	// itself (M3 Task 8: "claude_code_host" for claude_desktop); Mode must be
	// empty then.
	Component string `json:"component,omitempty"`
}

type InstallExecuteParams struct {
	PlanID string `json:"plan_id"`
}

type OperationParams struct {
	OperationID string `json:"operation_id"`
}

type VerifyExecuteParams struct {
	TargetID       string `json:"target_id"`
	InstallationID string `json:"installation_id"`
	Scope          string `json:"scope,omitempty"`
}

type emptyParams struct{}
