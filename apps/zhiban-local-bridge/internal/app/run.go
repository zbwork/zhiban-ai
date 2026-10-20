package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/diagnostics"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/launch"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/netproxy"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/rpc"
)

const operationShutdownTimeout = 10 * time.Second

type ToolDetector interface {
	Detect(context.Context, string) (detect.State, error)
}

type CredentialManager interface {
	PrepareRegistration(context.Context, string, credential.Environment) (credential.RegistrationPreparation, error)
	CommitRegistration(context.Context, credential.RegistrationCommit) error
	Status(context.Context) (credential.Status, error)
	ClearAuthorization(context.Context) error
	ExchangeToken(context.Context, string) (string, error)
}

type ConfigurationManager interface {
	Status(context.Context, string) (configuration.Status, error)
	Plan(context.Context, string, string) (configuration.Plan, error)
	PlanWithType(context.Context, string, string, string) (configuration.Plan, error)
	Execute(context.Context, string) (configuration.Status, error)
	Restore(context.Context, string) (configuration.Status, error)
}

type ProjectLaunchManager interface {
	CreateProjectGrant(context.Context, string) (launch.ProjectGrant, error)
	Plan(context.Context, launch.PlanRequest) (launch.Plan, error)
	Execute(context.Context, string) (launch.ExecuteResult, error)
	Consume(context.Context, string, []string) error
}

type InstallManager interface {
	Requirements(context.Context, string) (install.Requirements, error)
	Plan(context.Context, string, string) (install.Plan, error)
	// PlanComponent plans a runtime component install (M3 Task 8).
	PlanComponent(context.Context, string, string) (install.Plan, error)
	Execute(context.Context, string) (operation.Envelope, error)
}

type VerifyManager interface {
	Execute(context.Context, string, string, string) (operation.Envelope, error)
}

type Config struct {
	Community      *credential.CommunityManager
	BridgeVersion  string
	Platform       string
	Arch           string
	Detector       ToolDetector
	Credentials    CredentialManager
	Configurations ConfigurationManager
	Launches       ProjectLaunchManager
	Installs       InstallManager
	Verifier       VerifyManager
	Operations     *operation.Registry
	Diagnostics    *diagnostics.Recorder
	// Catalog is optional: it adds catalog.apply and the upgrade / rollback
	// fields of tool.detect (F31 version catalog plan §4).
	Catalog CatalogManager
	// NetworkProxy is optional: it adds network.proxy_status / apply /
	// revert (contract §2.7, system proxy intercepting the gateway).
	NetworkProxy NetworkProxyManager
}

// NetworkProxyManager is the network.* surface (netproxy.Manager).
type NetworkProxyManager interface {
	Status(ctx context.Context) (netproxy.Status, error)
	Apply(ctx context.Context) (netproxy.Status, error)
}

// supportedRuntime reports whether the Bridge supports this platform/arch pair:
// macOS on arm64 or x64, and Windows on x64 (F31 M2).
func supportedRuntime(platform, arch string) bool {
	switch platform {
	case "macos":
		return arch == "arm64" || arch == "x64"
	case "windows":
		return arch == "x64"
	default:
		return false
	}
}

func Run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer, config Config) int {
	if !supportedRuntime(config.Platform, config.Arch) {
		_, _ = io.WriteString(stderr, "unsupported bridge runtime\n")
		return 2
	}
	if len(args) != 0 {
		if len(args) == 4 && args[0] == "credential" && args[1] == "get" && args[2] == "--target" &&
			credential.IsTarget(args[3]) && config.Credentials != nil {
			return runCredentialHelper(ctx, args[3], stdout, stderr, config.Credentials)
		}
		if len(args) == 4 && args[0] == "launch" && args[1] == "consume" && args[2] == "--ticket" && config.Launches != nil {
			if err := config.Launches.Consume(ctx, args[3], os.Environ()); err != nil {
				_, _ = io.WriteString(stderr, "LCT-LAUNCH-TICKET_INVALID\n")
				return 1
			}
			return 0
		}
		_, _ = io.WriteString(stderr, "unsupported bridge invocation\n")
		return 2
	}
	if config.Detector == nil {
		_, _ = io.WriteString(stderr, "unsupported bridge runtime\n")
		return 2
	}

	rpcConfig := rpc.Config{
		BridgeVersion: config.BridgeVersion,
		Platform:      config.Platform,
		Arch:          config.Arch,
		Detect: func(ctx context.Context, targetID string) (any, error) {
			state, err := config.Detector.Detect(ctx, targetID)
			if err != nil {
				return nil, fmt.Errorf("detect target: %w", err)
			}
			if config.Diagnostics != nil && state.ErrorCode != "" {
				config.Diagnostics.Record(targetID, diagnostics.KindDetect, "detect", state.ErrorCode)
			}
			return state, nil
		},
	}
	if config.Community != nil {
		rpcConfig.BYOKSettings = func(ctx context.Context, params credential.BYOKSettings) (any, error) {
			return config.Community.Settings(ctx, params)
		}
	}
	if config.Credentials != nil {
		rpcConfig.CredentialPrepare = func(ctx context.Context, params rpc.CredentialPrepareParams) (any, error) {
			return config.Credentials.PrepareRegistration(ctx, params.DeviceID, credential.Environment(params.Environment))
		}
		rpcConfig.CredentialCommit = func(ctx context.Context, params rpc.CredentialCommitParams) error {
			return config.Credentials.CommitRegistration(ctx, credential.RegistrationCommit{
				CredentialID: params.CredentialID, DeviceCredential: params.DeviceCredential, ProfileVersions: params.ProfileVersions,
			})
		}
		rpcConfig.CredentialStatus = func(ctx context.Context) (any, error) {
			return config.Credentials.Status(ctx)
		}
		rpcConfig.CredentialClear = config.Credentials.ClearAuthorization
	}
	if config.Configurations != nil {
		rpcConfig.ConfigStatus = func(ctx context.Context, targetID string) (any, error) {
			return config.Configurations.Status(ctx, targetID)
		}
		rpcConfig.ConfigPlan = func(ctx context.Context, params rpc.ConfigPlanParams) (any, error) {
			plan, err := config.Configurations.PlanWithType(ctx, params.TargetID, params.InstallationID, params.Type)
			if errors.Is(err, configuration.ErrPolicyConflict) {
				code := "LCT-" + strings.ToUpper(params.TargetID) + "-CONFIG-POLICY_CONFLICT"
				if config.Diagnostics != nil {
					config.Diagnostics.Record(params.TargetID, diagnostics.KindConfig, "plan", code)
				}
				return nil, operation.Fail(code, err)
			}
			if code := configurationFailureCode(params.TargetID, err); code != "" {
				if config.Diagnostics != nil {
					config.Diagnostics.Record(params.TargetID, diagnostics.KindConfig, "plan", code)
				}
				return nil, operation.Fail(code, err)
			}
			if err == nil && plan.Action == configuration.ActionConflict && config.Diagnostics != nil {
				config.Diagnostics.Record(params.TargetID, diagnostics.KindConfig, "plan", "LCT-"+strings.ToUpper(params.TargetID)+"-CONFIG-CONFLICT")
			}
			return plan, err
		}
		rpcConfig.ConfigExecute = func(ctx context.Context, planID string) (any, error) {
			status, err := config.Configurations.Execute(ctx, planID)
			if err != nil {
				return nil, configurationWriteFailure(config.Diagnostics, status.TargetID, err)
			}
			return status, nil
		}
		rpcConfig.ConfigRestore = func(ctx context.Context, targetID string) (any, error) {
			status, err := config.Configurations.Restore(ctx, targetID)
			if err != nil {
				return nil, configurationWriteFailure(config.Diagnostics, targetID, err)
			}
			return status, nil
		}
	}
	if config.Launches != nil {
		rpcConfig.ProjectGrantCreate = func(ctx context.Context, params rpc.ProjectGrantCreateParams) (any, error) {
			return config.Launches.CreateProjectGrant(ctx, params.BookmarkData)
		}
		rpcConfig.LaunchPlan = func(ctx context.Context, params rpc.LaunchPlanParams) (any, error) {
			return config.Launches.Plan(ctx, launch.PlanRequest{
				TargetID: params.TargetID, InstallationID: params.InstallationID,
				ProjectGrantID: params.ProjectGrantID, ProfileVersion: params.ProfileVersion, Mode: params.Mode,
			})
		}
		rpcConfig.LaunchExecute = func(ctx context.Context, planID string) (any, error) {
			result, err := config.Launches.Execute(ctx, planID)
			if err != nil && config.Diagnostics != nil {
				if code := launchErrorCode(result.TargetID, err); code != "" {
					config.Diagnostics.Record(result.TargetID, diagnostics.KindLaunch, "execute", code)
				}
			}
			return result, err
		}
	}
	if config.Installs != nil {
		rpcConfig.Requirements = func(ctx context.Context, targetID string) (any, error) {
			return config.Installs.Requirements(ctx, targetID)
		}
		rpcConfig.InstallPlan = func(ctx context.Context, params rpc.InstallPlanParams) (any, error) {
			if params.Component != "" {
				return config.Installs.PlanComponent(ctx, params.TargetID, params.Component)
			}
			return config.Installs.Plan(ctx, params.TargetID, params.Mode)
		}
		rpcConfig.InstallExecute = func(ctx context.Context, planID string) (any, error) {
			return config.Installs.Execute(ctx, planID)
		}
	}
	if config.Catalog != nil {
		wireCatalog(&rpcConfig, config.Catalog)
	}
	if config.NetworkProxy != nil {
		rpcConfig.NetworkProxyStatus = func(ctx context.Context) (any, error) { return config.NetworkProxy.Status(ctx) }
		rpcConfig.NetworkProxyApply = func(ctx context.Context) (any, error) { return config.NetworkProxy.Apply(ctx) }
	}
	if config.Operations != nil {
		rpcConfig.OperationGet = func(_ context.Context, operationID string) (any, error) {
			return operationResult(config.Operations.Get(operationID))
		}
		rpcConfig.OperationCancel = func(_ context.Context, operationID string) (any, error) {
			return operationResult(config.Operations.Cancel(operationID))
		}
	}
	if config.Verifier != nil {
		rpcConfig.VerifyExecute = func(ctx context.Context, params rpc.VerifyExecuteParams) (any, error) {
			return config.Verifier.Execute(ctx, params.TargetID, params.InstallationID, params.Scope)
		}
	}
	if config.Diagnostics != nil {
		rpcConfig.DiagnosticsLatest = func(_ context.Context, targetID string) (any, error) {
			return config.Diagnostics.Latest(targetID), nil
		}
	}
	server := rpc.NewServer(rpcConfig)
	serveErr := server.Serve(ctx, stdin, stdout)
	if config.Operations != nil {
		// The session is over: cancel every running operation and wait for
		// their cleanup hooks so no partial download survives the process.
		config.Operations.Shutdown(operationShutdownTimeout)
	}
	if serveErr != nil {
		_, _ = io.WriteString(stderr, "bridge protocol error\n")
		return 1
	}
	return 0
}

// configurationDomainCode maps user-actionable global-switch failures to
// contract codes; other errors stay opaque.
func configurationDomainCode(targetID string, err error) string {
	prefix := "LCT-" + strings.ToUpper(targetID) + "-CONFIG-"
	switch {
	case errors.Is(err, configuration.ErrUnsafePath):
		return prefix + "UNSAFE_PATH"
	case errors.Is(err, configuration.ErrGlobalNotSwitched):
		return prefix + "NOT_SWITCHED"
	case errors.Is(err, configuration.ErrGlobalConflict):
		return prefix + "CONFLICT"
	case errors.Is(err, configuration.ErrGlobalParseFailed):
		return prefix + "PARSE_FAILED"
	case errors.Is(err, configuration.ErrVersionTooOld):
		return prefix + "VERSION_TOO_OLD"
	case errors.Is(err, configuration.ErrAuthorizationMissing):
		return "LCT-" + strings.ToUpper(targetID) + "-AUTH-DEVICE_MISSING"
	default:
		return ""
	}
}

// configurationWriteFailure reports why writing a configuration failed
// (contract §2.7.2 "写入失败的错误码与自动重试") and records it, so an execute
// that loses a race with a tool rewriting its own file no longer surfaces as
// an opaque internal error with nothing in the diagnostics.
func configurationWriteFailure(recorder *diagnostics.Recorder, targetID string, err error) error {
	owner := targetID
	if owner == "" {
		owner = "bridge"
	}
	code := configurationFailureCode(owner, err)
	if recorder != nil && targetID != "" {
		recorded := code
		if recorded == "" {
			recorded = "LCT-" + strings.ToUpper(targetID) + "-CONFIG-EXECUTE_FAILED"
		}
		recorder.Record(targetID, diagnostics.KindConfig, "execute", recorded)
	}
	if code == "" {
		return err
	}
	return operation.Fail(code, err)
}

// configurationFailureCode classifies the config failures the App acts on, for
// both plan and execute (contract §2.7.2 "写入失败的错误码与自动重试").
func configurationFailureCode(targetID string, err error) string {
	prefix := "LCT-" + strings.ToUpper(targetID) + "-CONFIG-"
	switch {
	case errors.Is(err, configuration.ErrRollbackFailed):
		return prefix + "ROLLBACK_FAILED"
	case errors.Is(err, configuration.ErrValidationFailed):
		return prefix + "VALIDATION_FAILED"
	case errors.Is(err, configuration.ErrPreconditionChanged):
		return prefix + "PRECONDITION_CHANGED"
	case errors.Is(err, configuration.ErrPlanNotFound), errors.Is(err, configuration.ErrPlanExpired):
		return prefix + "PLAN_EXPIRED"
	case errors.Is(err, configuration.ErrInstallationChanged):
		return prefix + "INSTALLATION_CHANGED"
	case configuration.IsFileInUse(err):
		return prefix + "FILE_IN_USE"
	default:
		return configurationDomainCode(targetID, err)
	}
}

func operationResult(envelope operation.Envelope, err error) (any, error) {
	if err != nil {
		if errors.Is(err, operation.ErrNotFound) || errors.Is(err, operation.ErrInvalidInput) {
			return nil, operation.Fail("LCT-BRIDGE-OPERATION-NOT_FOUND", err)
		}
		return nil, err
	}
	return envelope, nil
}

func launchErrorCode(targetID string, err error) string {
	if targetID == "" {
		return ""
	}
	prefix := "LCT-" + strings.ToUpper(targetID) + "-LAUNCH-"
	switch {
	case errors.Is(err, launch.ErrProjectPermissionDenied), errors.Is(err, launch.ErrProjectChanged):
		return prefix + "PROJECT_PERMISSION_DENIED"
	case errors.Is(err, launch.ErrTerminalLaunchFailed), errors.Is(err, launch.ErrProcessLaunchFailed), errors.Is(err, launch.ErrTicketStoreFailed):
		return prefix + "PROCESS_FAILED"
	case errors.Is(err, launch.ErrInstallationChanged), errors.Is(err, launch.ErrConfigurationChanged):
		return prefix + "POLICY_CONFLICT"
	default:
		return ""
	}
}

func runCredentialHelper(ctx context.Context, targetID string, stdout, stderr io.Writer, manager CredentialManager) int {
	token, err := manager.ExchangeToken(ctx, targetID)
	if err != nil || !credential.ValidAccessToken(token) {
		_, _ = io.WriteString(stderr, helperErrorCode(targetID, err)+"\n")
		return 1
	}
	if _, err := io.WriteString(stdout, token+"\n"); err != nil {
		return 1
	}
	return 0
}

func helperErrorCode(targetID string, err error) string {
	prefix := "LCT-CODEX_CLI"
	if targetID == credential.TargetClaudeCLI {
		prefix = "LCT-CLAUDE_CLI"
	}
	switch {
	case errors.Is(err, credential.ErrExchangeRejected):
		return prefix + "-AUTH-DEVICE_REVOKED"
	case errors.Is(err, credential.ErrInsufficientCredit):
		return prefix + "-AUTH-INSUFFICIENT_CREDIT"
	case errors.Is(err, credential.ErrMemberKeyDisabled):
		return prefix + "-AUTH-MEMBER_KEY_DISABLED"
	case errors.Is(err, credential.ErrProfileUnsupported):
		return prefix + "-AUTH-SCOPE_DENIED"
	case errors.Is(err, credential.ErrExchangeUnavailable):
		return prefix + "-GATEWAY-UNREACHABLE"
	case errors.Is(err, credential.ErrInvalidExchangeResponse):
		return prefix + "-GATEWAY-PROTOCOL_MISMATCH"
	default:
		return prefix + "-AUTH-DEVICE_MISSING"
	}
}
