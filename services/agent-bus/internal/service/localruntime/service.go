package localruntime

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"mime"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

type ModelSelection struct {
	Model    string
	Protocol string
	Binding  string
}
type RecoverySelection struct {
	Slot     int    `json:"slot"`
	Model    string `json:"model"`
	Protocol string `json:"protocol"`
	Binding  string `json:"binding"`
	Label    string `json:"label"`
}

// RecoveryPlanner plans this turn's model recovery. allowFallback is the user's
// explicit consent to switch models: without it the plan must contain only the
// selected model, so a failure surfaces as "pick another model" instead of the
// runtime silently executing on something the user never chose (decision Q3).
type RecoveryPlanner interface {
	PlanLocalRecovery(ctx context.Context, scope dom.Scope, employeeID int64, ref string, allowFallback bool) ([]RecoverySelection, error)
}
type ModelSelector interface {
	SelectLocalModel(context.Context, dom.Scope, int64, string) (ModelSelection, error)
}

type Service struct {
	repo   dom.Repository
	key    []byte
	models ModelSelector
}

func New(repo dom.Repository, signingKey []byte, models ModelSelector) (*Service, error) {
	if repo == nil || len(signingKey) < 32 || models == nil {
		return nil, dom.ErrDenied
	}
	// Domain-separate from JWT and other uses of the configured signing secret.
	h := hmac.New(sha256.New, signingKey)
	_, _ = h.Write([]byte("zhiban-local-runtime-v1"))
	return &Service{repo: repo, key: h.Sum(nil), models: models}, nil
}

// Registration exposes a short-lived ticket, never a persistent client secret.
type Registration struct {
	*dom.Device
	ConnectToken     string    `json:"connect_token"`
	ConnectExpiresAt time.Time `json:"connect_expires_at"`
}
type connectClaims struct {
	Audience     string `json:"aud"`
	Account      int64  `json:"account"`
	Tenant       int64  `json:"tenant"`
	Session      string `json:"session"`
	Installation string `json:"installation"`
	Device       string `json:"device"`
	Generation   int64  `json:"generation"`
	Expires      int64  `json:"exp"`
}

func (s *Service) Register(ctx context.Context, scope dom.Scope, platform, installationID string, versions ...int) (*Registration, error) {
	version := 1
	if len(versions) > 0 && versions[0] != 0 {
		version = versions[0]
	}
	if version != 1 && version != 2 {
		return nil, dom.ErrDenied
	}
	id, err := uuid.Parse(installationID)
	if err != nil || id == uuid.Nil || (platform != "darwin" && platform != "win32") {
		return nil, dom.ErrDenied
	}
	device, err := s.repo.Register(ctx, scope, id.String(), platform)
	if err != nil {
		return nil, err
	}

	if remote, ok := s.repo.(dom.RemoteRepository); ok {
		if err = remote.SetProtocolVersion(ctx, scope, device.UUID, version); err != nil {
			return nil, err
		}
	}
	device.ProtocolVersion = version
	expires := time.Now().Add(time.Minute).Truncate(time.Second)
	return &Registration{Device: device, ConnectToken: s.connectTicket(device, scope, expires), ConnectExpiresAt: expires}, nil
}

func (s *Service) connectTicket(device *dom.Device, scope dom.Scope, expires time.Time) string {
	data, _ := json.Marshal(connectClaims{Audience: "local-connect", Account: scope.AccountID, Tenant: scope.TenantID, Session: scope.SessionUUID, Installation: device.InstallationID, Device: device.UUID, Generation: device.Generation, Expires: expires.Unix()})
	payload := "lct_" + base64.RawURLEncoding.EncodeToString(data)
	h := hmac.New(sha256.New, s.key)
	_, _ = h.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(h.Sum(nil))
}

// The ticket's generation is consumed atomically by repository compare-and-increment.
func (s *Service) Connect(ctx context.Context, scope dom.Scope, deviceID string, generation int64, token string) (*dom.Device, error) {
	if len(token) > 4096 || !strings.HasPrefix(token, "lct_") {
		return nil, dom.ErrDenied
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, dom.ErrDenied
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, dom.ErrDenied
	}
	h := hmac.New(sha256.New, s.key)
	_, _ = h.Write([]byte(parts[0]))
	if !hmac.Equal(signature, h.Sum(nil)) {
		return nil, dom.ErrDenied
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(parts[0], "lct_"))
	if err != nil {
		return nil, dom.ErrDenied
	}
	var c connectClaims
	if json.Unmarshal(data, &c) != nil || c.Audience != "local-connect" || c.Account != scope.AccountID || c.Tenant != scope.TenantID || c.Session != scope.SessionUUID || c.Device != deviceID || c.Generation != generation || generation < 0 || c.Expires <= time.Now().Unix() || c.Expires > time.Now().Add(time.Minute).Unix() {
		return nil, dom.ErrDenied
	}
	device, err := s.repo.GetDevice(ctx, scope, deviceID)
	if err != nil {
		return nil, err
	}
	if c.Installation == "" || c.Installation != device.InstallationID {
		return nil, dom.ErrDenied
	}
	return s.repo.Connect(ctx, scope, deviceID, generation)
}

func (s *Service) Heartbeat(ctx context.Context, scope dom.Scope, deviceID string, generation int64) error {
	return s.repo.Heartbeat(ctx, scope, deviceID, generation)
}
func (s *Service) Revoke(ctx context.Context, scope dom.Scope, deviceID string) error {
	return s.repo.Revoke(ctx, scope, deviceID)
}

func (s *Service) Disconnect(ctx context.Context, scope dom.Scope, deviceID string, generation int64) error {
	return s.repo.Disconnect(ctx, scope, deviceID, generation)
}
func (s *Service) Expire(ctx context.Context) (int64, error) { return s.repo.ExpireTasks(ctx) }

func (s *Service) Ready(ctx context.Context, scope dom.Scope, deviceID string, employeeID int64, hint string) (string, error) {
	device, err := s.repo.GetDevice(ctx, scope, deviceID)
	if err != nil {
		return "", err
	}
	if device.Generation <= 0 || time.Since(device.SeenAt) > 15*time.Second {
		return "", dom.ErrOffline
	}
	if preparer, ok := s.models.(interface {
		PrepareLocalModel(context.Context, dom.Scope, int64, string) (ModelSelection, error)
	}); ok {
		selected, err := preparer.PrepareLocalModel(ctx, scope, employeeID, hint)
		logpkg.Default().Info(ctx, "local_runtime.ready_model", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device_id", deviceID, "employee_id", employeeID, "hint", boundedModelDiagnostic(hint), "model", boundedModelDiagnostic(selected.Model), "protocol", selected.Protocol, "binding_present", selected.Binding != "", "error", errString(err))
		return selected.Model, err
	}
	selected, err := s.models.SelectLocalModel(ctx, scope, employeeID, hint)
	logpkg.Default().Info(ctx, "local_runtime.ready_model", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device_id", deviceID, "employee_id", employeeID, "hint", boundedModelDiagnostic(hint), "model", boundedModelDiagnostic(selected.Model), "protocol", selected.Protocol, "binding_present", selected.Binding != "", "error", errString(err))
	return selected.Model, err
}

func boundedModelDiagnostic(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 200 {
		return value[:200]
	}
	return value
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return boundedModelDiagnostic(err.Error())
}

type claims struct {
	Audience string `json:"aud"`
	Run      string `json:"run"`
	Device   string `json:"device"`
	Account  int64  `json:"account"`
	Tenant   int64  `json:"tenant"`
	Session  string `json:"session"`
}

func (s *Service) capability(task *dom.Task) string {
	data, _ := json.Marshal(claims{Audience: "local-run", Run: task.UUID, Device: task.DeviceUUID, Account: task.Scope.AccountID, Tenant: task.Scope.TenantID, Session: task.Scope.SessionUUID})
	payload := base64.RawURLEncoding.EncodeToString(data)
	h := hmac.New(sha256.New, s.key)
	_, _ = h.Write([]byte(payload))
	return "lrt_" + payload + "." + base64.RawURLEncoding.EncodeToString(h.Sum(nil))
}

func digest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Create is called only by the existing chat dispatch path, never by device transport messages.
func (s *Service) Create(ctx context.Context, task dom.Task) (*dom.Task, error) {
	if task.Scope.AccountID <= 0 || task.Scope.TenantID <= 0 || task.Scope.SessionUUID == "" || len(task.Payload) > 512*1024 {
		return nil, dom.ErrDenied
	}
	if err := s.requester(ctx, &task); err != nil {
		return nil, err
	}
	selected, err := s.models.SelectLocalModel(ctx, task.Scope, task.EmployeeID, task.Model)
	if err != nil {
		logpkg.Default().Warn(ctx, "local_runtime.task_model_rejected", "run_uuid", task.UUID, "message_uuid", task.MessageUUID, "stream_id", task.StreamID, "account_id", task.Scope.AccountID, "tenant_id", task.Scope.TenantID, "requested_model", boundedModelDiagnostic(task.Model), "error", errString(err))
		return nil, err
	}
	var payload map[string]any
	if err = json.Unmarshal(task.Payload, &payload); err != nil || payload == nil {
		return nil, dom.ErrDenied
	}
	if selected.Model == "" || selected.Binding == "" {
		return nil, dom.ErrDenied
	}
	if task.LocalEngine == "" {
		task.LocalEngine = dom.EngineDSH
	}
	if task.LocalEngine != dom.EngineDSH && task.LocalEngine != dom.EngineCodex {
		return nil, dom.ErrDenied
	}
	if task.LocalEngine == dom.EngineCodex && selected.Protocol != "openai-compatible" {
		return nil, dom.ErrDenied
	}
	payload["model_protocol"] = selected.Protocol
	payload["model_binding"] = selected.Binding
	delete(payload, "model_recovery")
	if planner, ok := s.models.(RecoveryPlanner); ok && task.LocalEngine == dom.EngineDSH {
		// Consent is per turn and comes from the client that showed the prompt; it is
		// never inherited from a previous turn or stored on the employee.
		allowFallback, _ := payload["allow_model_fallback"].(bool)
		plan, e := planner.PlanLocalRecovery(ctx, task.Scope, task.EmployeeID, selected.Model, allowFallback)
		if e != nil {
			return nil, e
		}
		payload["model_recovery"] = plan
	}
	task.Payload, err = json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	task.UUID = uuid.NewString()
	task.Model = selected.Model
	task.ExpiresAt = time.Now().Add(15 * time.Minute)
	task.TokenHash = digest(s.capability(&task))
	logpkg.Default().Info(ctx, "local_runtime.task_created", "run_uuid", task.UUID, "message_uuid", task.MessageUUID, "stream_id", task.StreamID, "account_id", task.Scope.AccountID, "tenant_id", task.Scope.TenantID, "employee_id", task.EmployeeID, "model", boundedModelDiagnostic(task.Model), "protocol", selected.Protocol, "binding_present", selected.Binding != "")
	return s.repo.CreateTask(ctx, &task)
}

type Delivery struct {
	Task       dom.Task `json:"task"`
	Capability string   `json:"capability"`
}

func (s *Service) Pending(ctx context.Context, scope dom.Scope, deviceID string, generation int64) ([]Delivery, error) {
	tasks, err := s.repo.PendingTasks(ctx, scope, deviceID, generation)
	if err != nil {
		return nil, err
	}
	out := make([]Delivery, 0, len(tasks))
	for _, task := range tasks {
		out = append(out, Delivery{Task: task, Capability: s.capability(&task)})
	}
	return out, nil
}
func (s *Service) Accept(ctx context.Context, scope dom.Scope, deviceID string, generation int64, runID string, fence int64) error {
	return s.repo.AcceptTask(ctx, scope, deviceID, generation, runID, fence)
}

func (s *Service) AuthorizeRun(ctx context.Context, token, runID string, fence int64) (*dom.Task, error) {
	if !strings.HasPrefix(token, "lrt_") || len(token) > 2048 {
		return nil, dom.ErrDenied
	}
	parts := strings.Split(strings.TrimPrefix(token, "lrt_"), ".")
	if len(parts) != 2 {
		return nil, dom.ErrDenied
	}
	mac, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, dom.ErrDenied
	}
	h := hmac.New(sha256.New, s.key)
	_, _ = h.Write([]byte(parts[0]))
	if !hmac.Equal(mac, h.Sum(nil)) {
		return nil, dom.ErrDenied
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, dom.ErrDenied
	}
	var c claims
	if json.Unmarshal(data, &c) != nil || c.Audience != "local-run" || c.Run != runID {
		return nil, dom.ErrDenied
	}
	scope := dom.Scope{AccountID: c.Account, TenantID: c.Tenant, SessionUUID: c.Session}
	task, err := s.repo.GetTask(ctx, scope, runID)
	if err != nil {
		return nil, err
	}
	if (task.CurrentEngine != "" && task.CurrentEngine != task.LocalEngine) || task.DeviceUUID != c.Device || task.Fence != fence || (task.Status != "dispatched" && task.Status != "accepted") || !task.ExpiresAt.After(time.Now()) || !hmac.Equal([]byte(digest(token)), []byte(task.TokenHash)) {
		return nil, dom.ErrDenied
	}
	if err := s.requester(ctx, task); err != nil {
		return nil, err
	}
	device, err := s.repo.GetDevice(ctx, scope, c.Device)
	if err != nil {
		return nil, err
	}
	if !dom.SupportsEngine(device, task.LocalEngine) {
		return nil, dom.ErrUpgradeRequired
	}
	if (task.RequesterSessionUUID != "" && device.ProtocolVersion < 2) || time.Since(device.SeenAt) > 15*time.Second {
		return nil, dom.ErrOffline
	}
	// Recheck employee ownership and model availability after edits or tenant/member suspension.
	selected, err := s.models.SelectLocalModel(ctx, scope, task.EmployeeID, task.Model)
	if ctx.Err() != nil {
		return nil, dom.ErrOffline
	}
	if err != nil || !MatchesModel(task, selected) {
		return nil, dom.ErrDenied
	}
	return task, nil
}

func (s *Service) Append(ctx context.Context, scope dom.Scope, deviceID string, generation int64, event dom.Event) (int64, error) {
	if event.Seq <= 0 || len(event.Data) > 1024*1024 || !json.Valid(event.Data) {
		return 0, dom.ErrDenied
	}
	switch event.Name {
	case "message.created", "message.block.delta", "message.reasoning", "message.tool_call", "message.tool_result", "message.completed", "message.failed", "message.cancelled":
	default:
		return 0, dom.ErrDenied
	}
	var data map[string]json.RawMessage
	if json.Unmarshal(event.Data, &data) != nil || data == nil {
		return 0, dom.ErrDenied
	}
	task, err := s.repo.GetTask(ctx, scope, event.RunUUID)
	if err != nil {
		return 0, err
	}
	// The transport does not let a device inject into another message, even in its own conversation.
	var messageID string
	if json.Unmarshal(data["message_id"], &messageID) != nil || messageID != task.MessageUUID {
		return 0, dom.ErrDenied
	}
	if event.Name == "message.completed" || ((event.Name == "message.failed" || event.Name == "message.cancelled") && data["blocks"] != nil) {
		var blocks []map[string]any
		if json.Unmarshal(data["blocks"], &blocks) != nil || validateLocalArtifacts(task, blocks) != nil {
			return 0, dom.ErrDenied
		}
	}
	if event.Name == "message.block.delta" {
		var delta struct {
			Type   string           `json:"type"`
			Blocks []map[string]any `json:"blocks"`
		}
		decodeErr := json.Unmarshal(data["block_delta"], &delta)
		if delta.Type == "local_artifacts" {
			if decodeErr != nil || delta.Blocks == nil || validateLocalArtifacts(task, delta.Blocks) != nil {
				return 0, dom.ErrDenied
			}
			for _, block := range delta.Blocks {
				if block["local_artifact"] == nil {
					return 0, dom.ErrDenied
				}
			}
		}
	}
	if event.Name == "message.completed" || event.Name == "message.failed" || event.Name == "message.cancelled" {
		var code, message string
		_ = json.Unmarshal(data["error_code"], &code)
		_ = json.Unmarshal(data["error_message"], &message)
		logpkg.Default().Info(ctx, "local_runtime.terminal_event", "run_uuid", event.RunUUID, "message_uuid", messageID, "event", event.Name, "seq", event.Seq, "error_code", boundedModelDiagnostic(code), "error_message", boundedModelDiagnostic(message))
	}
	return s.repo.AppendEvent(ctx, scope, deviceID, generation, event)
}

// Artifact identity belongs to this device/task's conversation. Never persist a supplied OS path.
func validateLocalArtifacts(task *dom.Task, blocks []map[string]any) error {
	summaries, files := 0, 0
	for _, b := range blocks {
		if b["local_artifact"] != nil {
			files++
		}
	}
	for _, b := range blocks {
		if b["type"] != "local_delivery" {
			continue
		}
		summaries++
		count, ok := b["verified_count"].(float64)
		required, valid := b["required_count"].(float64)
		if summaries > 1 || len(b) != 4 || !ok || !valid || files == 0 || count != float64(files) || required < 0 || required > 32 || required != math.Trunc(required) || (b["status"] != "complete" && b["status"] != "partial") || (b["status"] == "complete" && (required == 0 || count < required)) {
			return dom.ErrDenied
		}
	}
	for _, block := range blocks {
		raw, exists := block["local_artifact"]
		if !exists {
			continue
		}
		kind, _ := block["type"].(string)
		ref, ok := raw.(map[string]any)
		if !ok || len(ref) != 3 || (kind != "file" && kind != "image") {
			return dom.ErrDenied
		}
		id, _ := ref["artifact_id"].(string)
		device, _ := ref["device_id"].(string)
		hash, _ := ref["sha256"].(string)
		if _, err := uuid.Parse(id); err != nil {
			return dom.ErrDenied
		}
		decoded, err := hex.DecodeString(hash)
		if err != nil || len(decoded) != 32 || strings.ToLower(hash) != hash || device != task.DeviceUUID {
			return dom.ErrDenied
		}
		name, _ := block["name"].(string)
		size, validSize := block["size"].(float64)
		mimeValue, _ := block["mime"].(string)
		mediaType, params, mimeErr := mime.ParseMediaType(mimeValue)
		if !validSize || size != math.Trunc(size) || mimeErr != nil || len(params) != 0 || mediaType != mimeValue || !strings.Contains(mediaType, "/") || strings.IndexFunc(name, unicode.IsControl) >= 0 || name == "" || len(name) > 255 || strings.ContainsAny(name, "/\\:\x00") || size < 0 || size > 128*1024*1024 {
			return dom.ErrDenied
		}
		if status, exists := block["archive_status"]; exists {
			if status != "synced" && status != "failed" {
				return dom.ErrDenied
			}
			if status == "synced" {
				id, _ := block["drive_file_id"].(string)
				if _, err := uuid.Parse(id); err != nil {
					return dom.ErrDenied
				}
			}
		}
		for key := range block {
			switch key {
			case "type", "name", "mime", "size", "local_artifact", "archive_status", "drive_file_id":
			default:
				return dom.ErrDenied
			}
		}
	}
	return nil
}

func (s *Service) Task(ctx context.Context, scope dom.Scope, id string) (*dom.Task, error) {
	return s.repo.GetTask(ctx, scope, id)
}
func (s *Service) Events(ctx context.Context, scope dom.Scope, id string, after int64) ([]dom.Event, error) {
	return s.repo.Events(ctx, scope, id, after)
}
func (s *Service) Cancel(ctx context.Context, scope dom.Scope, id string) error {
	return s.repo.CancelTask(ctx, scope, id)
}

// MatchesModel prevents credential/source changes from silently rerouting an active turn.
func MatchesModel(task *dom.Task, selected ModelSelection) bool {
	var p struct {
		Binding  string `json:"model_binding"`
		Protocol string `json:"model_protocol"`
	}
	return json.Unmarshal(task.Payload, &p) == nil && selected.Model == task.Model && p.Protocol == selected.Protocol && p.Binding != "" && hmac.Equal([]byte(p.Binding), []byte(selected.Binding))
}
