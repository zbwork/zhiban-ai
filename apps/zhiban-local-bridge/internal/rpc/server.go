package rpc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"io"
	"math/big"
	"regexp"
	"strings"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

var (
	ErrFrameTooLarge   = errors.New("rpc frame exceeds 1 MiB")
	appVersionPattern  = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$`)
	localePattern      = regexp.MustCompile(`^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$`)
	integerIDPattern   = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)$`)
	opaqueValuePattern = regexp.MustCompile(`^[0-9A-Za-z._+-]+$`)
	signaturePattern   = regexp.MustCompile(`^[0-9A-Za-z_-]+={0,2}$`)
	errorCodePattern   = regexp.MustCompile(`^LCT-[A-Z_]+-[A-Z]+-[A-Z_]+$`)
	maxSafeInteger     = big.NewInt(9_007_199_254_740_991)
)

type Server struct {
	config      Config
	initialized bool
}

func NewServer(config Config) *Server {
	return &Server{config: config}
}

func (s *Server) Serve(ctx context.Context, input io.Reader, output io.Writer) error {
	reader := bufio.NewReader(input)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		frame, err := readFrame(reader)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		response, emit := s.handleFrame(ctx, frame)
		if !emit {
			continue
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			return fmt.Errorf("encode JSON-RPC response: %w", err)
		}
		encoded = append(encoded, '\n')
		if _, err := output.Write(encoded); err != nil {
			return fmt.Errorf("write JSON-RPC response: %w", err)
		}
	}
}

func readFrame(reader *bufio.Reader) ([]byte, error) {
	frame := make([]byte, 0, 4096)
	for {
		fragment, more, err := reader.ReadLine()
		if len(frame)+len(fragment) > MaxFrameBytes {
			return nil, ErrFrameTooLarge
		}
		frame = append(frame, fragment...)
		if err != nil {
			if errors.Is(err, io.EOF) && len(frame) > 0 {
				return frame, nil
			}
			return nil, err
		}
		if !more {
			return frame, nil
		}
	}
}

func (s *Server) handleFrame(ctx context.Context, frame []byte) (Response, bool) {
	nullID := json.RawMessage("null")
	trimmed := bytes.TrimSpace(frame)
	if !json.Valid(trimmed) {
		return errorResponse(nullID, CodeParseError, "Parse error"), true
	}
	if len(trimmed) == 0 || trimmed[0] == '[' {
		return errorResponse(nullID, CodeInvalidRequest, "Invalid Request"), true
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &fields); err != nil || fields == nil {
		return errorResponse(nullID, CodeInvalidRequest, "Invalid Request"), true
	}
	if _, present := fields["id"]; !present {
		return Response{}, false
	}

	var request Request
	if err := decodeStrict(trimmed, &request); err != nil || request.JSONRPC != "2.0" || strings.TrimSpace(request.Method) == "" || !validRequestID(request.ID) {
		return errorResponse(nullID, CodeInvalidRequest, "Invalid Request"), true
	}

	switch request.Method {
	case "initialize":
		return s.initialize(request)
	case "byok.settings":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		if s.config.BYOKSettings == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		var params credential.BYOKSettings
		if decodeStrict(request.Params, &params) != nil {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		result, err := s.config.BYOKSettings(ctx, params)
		if err != nil {
			return errorResponse(request.ID, CodeDomainError, "LCT-BYOK-SETTINGS_FAILED"), true
		}
		return resultResponse(request.ID, result), true
	case "tool.detect":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.detect(ctx, request)
	case "credential.registration.prepare":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.prepareCredential(ctx, request)
	case "credential.registration.commit":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.commitCredential(ctx, request)
	case "credential.status":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.credentialStatus(ctx, request)
	case "credential.clear":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.clearCredential(ctx, request)
	case "config.status":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.configStatus(ctx, request)
	case "config.plan":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.configPlan(ctx, request)
	case "config.execute":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.configExecute(ctx, request)
	case "config.restore":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.configRestore(ctx, request)
	case "project.grant.create":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.projectGrantCreate(ctx, request)
	case "launch.plan":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.launchPlan(ctx, request)
	case "launch.execute":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.launchExecute(ctx, request)
	case "requirements.get", "install.plan", "install.execute", "operation.get", "operation.cancel", "verify.execute", "diagnostics.get_latest", "catalog.apply",
		"network.proxy_status", "network.proxy_apply":
		if !s.initialized {
			return errorResponse(request.ID, CodeNotInitialized, "Bridge not initialized"), true
		}
		return s.dispatchM1G(ctx, request)
	default:
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
}

func (s *Server) initialize(request Request) (Response, bool) {
	if s.initialized {
		return errorResponse(request.ID, CodeAlreadyInitialized, "Bridge already initialized"), true
	}
	var params InitializeParams
	if err := decodeStrict(request.Params, &params); err != nil || !s.validInitialize(params) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	s.initialized = true
	return resultResponse(request.ID, InitializeResult{
		ProtocolVersion:  ProtocolVersion,
		BridgeVersion:    s.config.BridgeVersion,
		SupportedMethods: s.supportedMethods(),
	}), true
}

func (s *Server) supportedMethods() []string {
	methods := make([]string, 0, 12)
	if s.config.BYOKSettings != nil {
		methods = append(methods, "byok.settings")
	}
	if s.config.Detect != nil {
		methods = append(methods, "tool.detect")
	}
	if s.config.CredentialPrepare != nil {
		methods = append(methods, "credential.registration.prepare")
	}
	if s.config.CredentialCommit != nil {
		methods = append(methods, "credential.registration.commit")
	}
	if s.config.CredentialStatus != nil {
		methods = append(methods, "credential.status")
	}
	if s.config.CredentialClear != nil {
		methods = append(methods, "credential.clear")
	}
	if s.config.ConfigStatus != nil {
		methods = append(methods, "config.status")
	}
	if s.config.ConfigPlan != nil {
		methods = append(methods, "config.plan")
	}
	if s.config.ConfigExecute != nil {
		methods = append(methods, "config.execute")
	}
	if s.config.ConfigRestore != nil {
		methods = append(methods, "config.restore")
	}
	if s.config.ProjectGrantCreate != nil {
		methods = append(methods, "project.grant.create")
	}
	if s.config.LaunchPlan != nil {
		methods = append(methods, "launch.plan")
	}
	if s.config.LaunchExecute != nil {
		methods = append(methods, "launch.execute")
	}
	if s.config.Requirements != nil {
		methods = append(methods, "requirements.get")
	}
	if s.config.InstallPlan != nil {
		methods = append(methods, "install.plan")
	}
	if s.config.InstallExecute != nil {
		methods = append(methods, "install.execute")
	}
	if s.config.OperationGet != nil {
		methods = append(methods, "operation.get")
	}
	if s.config.OperationCancel != nil {
		methods = append(methods, "operation.cancel")
	}
	if s.config.VerifyExecute != nil {
		methods = append(methods, "verify.execute")
	}
	if s.config.DiagnosticsLatest != nil {
		methods = append(methods, "diagnostics.get_latest")
	}
	if s.config.CatalogApply != nil {
		methods = append(methods, "catalog.apply")
	}
	if s.config.NetworkProxyStatus != nil {
		methods = append(methods, "network.proxy_status")
	}
	if s.config.NetworkProxyApply != nil {
		methods = append(methods, "network.proxy_apply")
	}
	return methods
}

func (s *Server) validInitialize(params InitializeParams) bool {
	if params.ProtocolVersion != ProtocolVersion || params.Platform != s.config.Platform || params.Arch != s.config.Arch {
		return false
	}
	if !appVersionPattern.MatchString(params.AppVersion) || strings.TrimSpace(s.config.BridgeVersion) == "" {
		return false
	}
	return params.Locale == "" || localePattern.MatchString(params.Locale)
}

func (s *Server) detect(ctx context.Context, request Request) (Response, bool) {
	var params DetectParams
	if err := decodeStrict(request.Params, &params); err != nil || !validToolTarget(params.TargetID) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.Detect == nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	result, err := s.config.Detect(ctx, params.TargetID)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func (s *Server) prepareCredential(ctx context.Context, request Request) (Response, bool) {
	var params CredentialPrepareParams
	if decodeStrict(request.Params, &params) != nil || params.DeviceID == "" ||
		(params.Environment != "dev" && params.Environment != "test" && params.Environment != "prod") {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.CredentialPrepare == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.CredentialPrepare(ctx, params)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func (s *Server) commitCredential(ctx context.Context, request Request) (Response, bool) {
	var params CredentialCommitParams
	if decodeStrict(request.Params, &params) != nil || params.CredentialID == "" || params.DeviceCredential == "" || len(params.ProfileVersions) == 0 {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.CredentialCommit == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	if err := s.config.CredentialCommit(ctx, params); err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, map[string]bool{"stored": true}), true
}

func (s *Server) credentialStatus(ctx context.Context, request Request) (Response, bool) {
	var params emptyParams
	if decodeStrict(request.Params, &params) != nil {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.CredentialStatus == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.CredentialStatus(ctx)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func (s *Server) clearCredential(ctx context.Context, request Request) (Response, bool) {
	var params emptyParams
	if decodeStrict(request.Params, &params) != nil {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.CredentialClear == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	if err := s.config.CredentialClear(ctx); err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, map[string]bool{"cleared": true}), true
}

func (s *Server) configStatus(ctx context.Context, request Request) (Response, bool) {
	var params ConfigTargetParams
	if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.ConfigStatus == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.ConfigStatus(ctx, params.TargetID)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func (s *Server) configPlan(ctx context.Context, request Request) (Response, bool) {
	var params ConfigPlanParams
	if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) ||
		len(params.InstallationID) > 128 ||
		(params.Type != "restore_global" && strings.TrimSpace(params.InstallationID) == "") ||
		(params.Type != "" && params.Type != "enable" && params.Type != "repair" && params.Type != "switch_global" && params.Type != "restore_global") {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.ConfigPlan == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.ConfigPlan(ctx, params)
	return domainResponse(request.ID, result, err), true
}

func (s *Server) configExecute(ctx context.Context, request Request) (Response, bool) {
	var params ConfigExecuteParams
	if decodeStrict(request.Params, &params) != nil || strings.TrimSpace(params.PlanID) == "" || len(params.PlanID) > 128 {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.ConfigExecute == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.ConfigExecute(ctx, params.PlanID)
	return domainResponse(request.ID, result, err), true
}

func (s *Server) configRestore(ctx context.Context, request Request) (Response, bool) {
	var params ConfigTargetParams
	if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.ConfigRestore == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.ConfigRestore(ctx, params.TargetID)
	return domainResponse(request.ID, result, err), true
}

func (s *Server) projectGrantCreate(ctx context.Context, request Request) (Response, bool) {
	var params ProjectGrantCreateParams
	if decodeStrict(request.Params, &params) != nil || !validBookmarkData(params.BookmarkData) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.ProjectGrantCreate == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.ProjectGrantCreate(ctx, params)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func (s *Server) launchPlan(ctx context.Context, request Request) (Response, bool) {
	var params LaunchPlanParams
	if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) ||
		!validOpaqueValue(params.InstallationID) ||
		(params.ProjectGrantID != "" && !validOpaqueValue(params.ProjectGrantID)) ||
		(params.ProjectGrantID == "" && params.Mode != "official") ||
		(params.Mode != "" && params.Mode != "managed" && params.Mode != "official") ||
		(params.Mode != "official" && !validOpaqueValue(params.ProfileVersion)) ||
		(params.Mode == "official" && params.ProfileVersion != "") {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.LaunchPlan == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.LaunchPlan(ctx, params)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

// dispatchM1G routes the M1G methods. Their handlers return contract §6 codes
// as CodeDomainError so the App can act on them; everything else stays an
// opaque internal error.
func (s *Server) dispatchM1G(ctx context.Context, request Request) (Response, bool) {
	if !s.m1gConfigured(request.Method) {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	switch request.Method {
	case "requirements.get":
		var params ConfigTargetParams
		if decodeStrict(request.Params, &params) != nil || !validToolTarget(params.TargetID) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.Requirements == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.Requirements(ctx, params.TargetID)
		return domainResponse(request.ID, result, err), true
	case "install.plan":
		var params InstallPlanParams
		if decodeStrict(request.Params, &params) != nil || !validToolTarget(params.TargetID) || !validInstallMode(params.Mode) ||
			(params.Component != "" && (params.Component != "claude_code_host" || params.Mode != "")) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.InstallPlan == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.InstallPlan(ctx, params)
		return domainResponse(request.ID, result, err), true
	case "install.execute":
		var params InstallExecuteParams
		if decodeStrict(request.Params, &params) != nil || !validOpaqueValue(params.PlanID) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.InstallExecute == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.InstallExecute(ctx, params.PlanID)
		return domainResponse(request.ID, result, err), true
	case "operation.get", "operation.cancel":
		var params OperationParams
		if decodeStrict(request.Params, &params) != nil || !validOpaqueValue(params.OperationID) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		var handler func(context.Context, string) (any, error)
		if request.Method == "operation.cancel" {
			if s.config.OperationCancel != nil {
				handler = s.config.OperationCancel
			}
		} else if s.config.OperationGet != nil {
			handler = s.config.OperationGet
		}
		if handler == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := handler(ctx, params.OperationID)
		return domainResponse(request.ID, result, err), true
	case "verify.execute":
		var params VerifyExecuteParams
		if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) || !validOpaqueValue(params.InstallationID) ||
			(params.Scope != "" && params.Scope != "overlay" && params.Scope != "global") {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.VerifyExecute == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.VerifyExecute(ctx, params)
		return domainResponse(request.ID, result, err), true
	case "diagnostics.get_latest":
		var params ConfigTargetParams
		if decodeStrict(request.Params, &params) != nil || !validConfigTarget(params.TargetID) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.DiagnosticsLatest == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.DiagnosticsLatest(ctx, params.TargetID)
		return domainResponse(request.ID, result, err), true
	case "catalog.apply":
		var params CatalogApplyParams
		if decodeStrict(request.Params, &params) != nil || !validCatalogApply(params) {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		if s.config.CatalogApply == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := s.config.CatalogApply(ctx, params)
		return domainResponse(request.ID, result, err), true
	case "network.proxy_status", "network.proxy_apply":
		var params struct{}
		if len(request.Params) > 0 && string(request.Params) != "null" && decodeStrict(request.Params, &params) != nil {
			return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
		}
		handler := map[string]NetworkProxyFunc{
			"network.proxy_status": s.config.NetworkProxyStatus,
			"network.proxy_apply":  s.config.NetworkProxyApply,
		}[request.Method]
		if handler == nil {
			return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
		}
		result, err := handler(ctx)
		return domainResponse(request.ID, result, err), true
	default:
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
}

func (s *Server) m1gConfigured(method string) bool {
	switch method {
	case "requirements.get":
		return s.config.Requirements != nil
	case "install.plan":
		return s.config.InstallPlan != nil
	case "install.execute":
		return s.config.InstallExecute != nil
	case "operation.get":
		return s.config.OperationGet != nil
	case "operation.cancel":
		return s.config.OperationCancel != nil
	case "verify.execute":
		return s.config.VerifyExecute != nil
	case "diagnostics.get_latest":
		return s.config.DiagnosticsLatest != nil
	case "catalog.apply":
		return s.config.CatalogApply != nil
	case "network.proxy_status":
		return s.config.NetworkProxyStatus != nil
	case "network.proxy_apply":
		return s.config.NetworkProxyApply != nil
	default:
		return false
	}
}

// validInstallMode accepts the four install.plan modes; upgrade and rollback
// only exist once a catalog manager is wired (the installer refuses them
// otherwise with NOT_UPGRADABLE / NOT_ROLLBACKABLE).
func validInstallMode(mode string) bool {
	return mode == "" || mode == "install" || mode == "repair" || mode == "upgrade" || mode == "rollback" || mode == "adopt"
}

// validCatalogApply checks the envelope shape only; verification is the
// installer's job. A cleared catalog (null / absent) carries no kid or
// signature; a present one needs both, bounded and in their alphabets.
func validCatalogApply(params CatalogApplyParams) bool {
	if params.Environment != "dev" && params.Environment != "test" && params.Environment != "prod" {
		return false
	}
	document := bytes.TrimSpace(params.Catalog)
	if len(document) == 0 || string(document) == "null" {
		return params.KID == "" && params.Signature == ""
	}
	if document[0] != '{' || len(document) > MaxFrameBytes {
		return false
	}
	return validOpaqueValue(params.KID) && params.Signature != "" && len(params.Signature) <= 128 && signaturePattern.MatchString(params.Signature)
}

func domainResponse(id json.RawMessage, result any, err error) Response {
	if err == nil {
		return resultResponse(id, result)
	}
	var failure *operation.Failure
	if errors.As(err, &failure) && validErrorCode(failure.Code) {
		return errorResponse(id, CodeDomainError, failure.Code)
	}
	return errorResponse(id, CodeInternalError, "Internal error")
}

func validErrorCode(value string) bool {
	return errorCodePattern.MatchString(value)
}

func (s *Server) launchExecute(ctx context.Context, request Request) (Response, bool) {
	var params LaunchExecuteParams
	if decodeStrict(request.Params, &params) != nil || !validOpaqueValue(params.PlanID) {
		return errorResponse(request.ID, CodeInvalidParams, "Invalid params"), true
	}
	if s.config.LaunchExecute == nil {
		return errorResponse(request.ID, CodeMethodNotFound, "Method not found"), true
	}
	result, err := s.config.LaunchExecute(ctx, params.PlanID)
	if err != nil {
		return errorResponse(request.ID, CodeInternalError, "Internal error"), true
	}
	return resultResponse(request.ID, result), true
}

func validBookmarkData(value string) bool {
	if value == "" || len(value) > base64.StdEncoding.EncodedLen(64<<10)+4 {
		return false
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	return err == nil && len(decoded) > 0 && len(decoded) <= 64<<10
}

func validOpaqueValue(value string) bool {
	return value != "" && len(value) <= 128 && opaqueValuePattern.MatchString(value)
}

// validConfigTarget lists every target the Bridge serves: the two CLIs and,
// since M3, the two desktop application bundles. Each manager decides which
// operations a desktop target supports (no overlay, no managed launch).
func validConfigTarget(targetID string) bool {
	return targetID == "codex_cli" || targetID == "claude_cli" || targetID == "codex_desktop" || targetID == "claude_desktop"
}

// validToolTarget is the same set for detection and installation.
func validToolTarget(targetID string) bool {
	return validConfigTarget(targetID)
}

func decodeStrict(data []byte, destination any) error {
	if len(bytes.TrimSpace(data)) == 0 {
		return errors.New("missing JSON value")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("multiple JSON values")
	}
	return nil
}

func validRequestID(id json.RawMessage) bool {
	trimmed := bytes.TrimSpace(id)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return false
	}
	if trimmed[0] == '"' {
		var value string
		return json.Unmarshal(trimmed, &value) == nil && value != "" && len(value) <= 128
	}
	if !integerIDPattern.Match(trimmed) {
		return false
	}
	value, ok := new(big.Int).SetString(string(trimmed), 10)
	if !ok {
		return false
	}
	return new(big.Int).Abs(value).Cmp(maxSafeInteger) <= 0
}

func resultResponse(id json.RawMessage, result any) Response {
	encoded, err := json.Marshal(result)
	if err != nil {
		return errorResponse(id, CodeInternalError, "Internal error")
	}
	return Response{JSONRPC: "2.0", ID: cloneRawMessage(id), Result: encoded}
}

func errorResponse(id json.RawMessage, code int, message string) Response {
	return Response{
		JSONRPC: "2.0",
		ID:      cloneRawMessage(id),
		Error:   &ErrorObject{Code: code, Message: message},
	}
}

func cloneRawMessage(value json.RawMessage) json.RawMessage {
	return append(json.RawMessage(nil), value...)
}
