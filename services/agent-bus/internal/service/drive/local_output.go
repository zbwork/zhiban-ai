package drive

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/drivefilename"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// LocalOutputReq carries only a snapshot identity; destination is derived from the authorized task.
type LocalOutputReq struct {
	ArtifactID string `json:"artifact_id"`
	SHA256     string `json:"sha256"`
	FileName   string `json:"file_name"`
	FileSize   int64  `json:"file_size"`
	MimeType   string `json:"mime_type"`
}

func localOutputTicket(task *local.Task, req LocalOutputReq) (string, error) {
	if task == nil || task.Scope.AccountID <= 0 || task.Scope.TenantID <= 0 || task.EmployeeUUID == "" || task.UUID == "" {
		return "", apperr.ErrForbidden
	}
	if _, err := uuid.Parse(req.ArtifactID); err != nil {
		return "", apperr.ErrInvalidParams
	}
	hash, err := hex.DecodeString(req.SHA256)
	if err != nil || len(hash) != 32 || strings.ToLower(req.SHA256) != req.SHA256 || req.FileSize <= 0 || req.FileSize > 128*1024*1024 {
		return "", apperr.ErrInvalidParams
	}
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("local-output:"+task.UUID+":"+req.ArtifactID+":"+req.SHA256)).String(), nil
}

// WithLocalOutputs wires the independent task authorization boundary. Cloud ZAP lookup is unchanged.
func (s *ZAPSvc) WithLocalOutputs(resolver local.OutputAgentResolver) *ZAPSvc {
	s.localOutputs = resolver
	return s
}

func (s *ZAPSvc) localOutputScope(ctx context.Context, task *local.Task, req LocalOutputReq) (ticket, name string, err error) {
	ticket, err = localOutputTicket(task, req)
	if err != nil {
		return "", "", err
	}
	if s.localOutputs == nil {
		return "", "", apperr.ErrForbidden
	}
	name, err = s.localOutputs.ResolveOutputAgent(ctx, task)
	if errors.Is(err, local.ErrDenied) {
		return "", "", apperr.ErrForbidden
	}
	if err != nil {
		return "", "", apperr.ErrInternal.Wrap(err)
	}
	if strings.TrimSpace(name) == "" {
		name = task.EmployeeUUID
	}
	return ticket, name, nil
}

func (s *ZAPSvc) SignLocalOutput(ctx context.Context, task *local.Task, req LocalOutputReq) (*ZAPPresignResp, error) {
	ticket, name, err := s.localOutputScope(ctx, task, req)
	if err != nil {
		return nil, err
	}
	result, err := s.presignForOwner(ctx, task.Scope.TenantID, task.Scope.AccountID, task.EmployeeUUID, name, ZAPPresignReq{FileName: req.FileName, FileSize: req.FileSize, MimeType: req.MimeType}, ticket, true)
	if err != nil {
		return nil, err
	}
	if s.localUpload != nil && !result.Uploaded {
		stored, err := s.localOutputStoredTicket(ctx, task, req, ticket)
		if err != nil {
			return nil, err
		}
		if stored.ExpiresAt.Before(result.ExpiresAt) {
			result.ExpiresAt = stored.ExpiresAt
		}
	}
	return s.proxyLocalSignature(task, req, result)
}

func (s *ZAPSvc) ConfirmLocalOutput(ctx context.Context, task *local.Task, req LocalOutputReq) (*ZAPFileDTO, error) {
	ticket, _, err := s.localOutputScope(ctx, task, req)
	if err != nil {
		return nil, err
	}

	stored, err := s.localOutputStoredTicket(ctx, task, req, ticket)
	if err != nil {
		return nil, err
	}
	folder, err := s.resolveDeOutputs(ctx, task.Scope.TenantID, task.Scope.AccountID, task.EmployeeUUID)
	if err != nil {
		return nil, err
	}
	if stored.Status == "done" {
		file, err := s.files.GetByOutputStorageKey(ctx, task.Scope.AccountID, folder.ID, stored.FinalKey)
		if err != nil {
			return nil, err
		}
		space, err := s.spaces.GetByID(ctx, file.SpaceID)
		if err != nil {
			return nil, err
		}
		return &ZAPFileDTO{UUID: file.UUID, SpaceUUID: space.UUID, FolderUUID: folder.UUID, Name: file.Name, MimeType: file.MimeType, FileSize: file.SizeBytes, StorageKey: file.StorageKey, SourceKind: "agent_output", CreatedAt: file.CreatedAt}, nil
	}
	// Caller cannot substitute a ticket from another run/artifact, even for the same employee.
	return s.confirmForOwner(ctx, task.Scope.TenantID, task.Scope.AccountID, ZAPConfirmReq{PresignTicket: ticket, FileName: req.FileName, FileSize: req.FileSize, MimeType: req.MimeType, Checksum: req.SHA256, MessageUUID: task.MessageUUID})
}

func (s *ZAPSvc) localOutputStoredTicket(ctx context.Context, task *local.Task, req LocalOutputReq, ticket string) (*dom.UploadTicket, error) {
	stored, err := s.tickets.GetByFileUUID(ctx, ticket)
	if err != nil {
		return nil, err
	}
	folder, err := s.resolveDeOutputs(ctx, task.Scope.TenantID, task.Scope.AccountID, task.EmployeeUUID)
	if err != nil {
		return nil, err
	}
	if stored.TenantID != task.Scope.TenantID || stored.AccountID != task.Scope.AccountID || stored.FolderID == nil || *stored.FolderID != folder.ID || stored.Source != dom.FileSourceAgentOutput || stored.DeclaredName != drivefilename.Sanitize(req.FileName) || stored.DeclaredSize != req.FileSize || stored.DeclaredMime != strings.ToLower(strings.TrimSpace(req.MimeType)) {
		return nil, apperr.ErrForbidden
	}
	return stored, nil
}
