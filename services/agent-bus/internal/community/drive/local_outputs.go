package drive

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// LocalOutputs archives files produced by local digital employees into the drive,
// using the same signed-upload and confirm path as commercial Bus.
func LocalOutputs(pool *pgxpool.Pool, storage *Storage, resolver local.OutputAgentResolver) *svc.ZAPSvc {
	if storage == nil {
		return nil
	}
	spaces, folders, files := repo.NewSpaceRepo(pool), repo.NewFolderRepo(pool), repo.NewFileRepo(pool)
	tickets, quotas, acl := repo.NewTicketRepo(pool), repo.NewQuotaRepo(pool), svc.NewACLService(pool)
	upload := svc.NewUploadSvc(pool, spaces, folders, files, tickets, quotas, acl, storage).WithVersions(repo.NewFileVersionRepo(pool))
	snapshot := svc.NewSnapshotSvc(pool, spaces, folders, files, acl, storage)
	return svc.NewZAPSvc(pool, spaces, folders, files, tickets, quotas, storage, agentLookup{agentrepo.New(pool)},
		svc.NewSystemFoldersSvc(pool, spaces, folders), upload, snapshot).WithLocalOutputs(resolver)
}

type agentLookup struct{ repo *agentrepo.Repo }

func (a agentLookup) GetByUUID(ctx context.Context, tenantID int64, agentUUID string) (*svc.ZAPAgentMeta, error) {
	e, err := a.repo.GetByUUID(ctx, agentUUID)
	if err != nil {
		return nil, err
	}
	if e == nil || e.TenantID != tenantID {
		return nil, errors.New("drive: agent tenant mismatch")
	}
	return &svc.ZAPAgentMeta{ID: e.ID, UUID: e.UUID, TenantID: e.TenantID, CreatorID: e.CreatorID, Name: e.Name}, nil
}
