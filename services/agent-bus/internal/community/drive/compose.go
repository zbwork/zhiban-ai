// Package drive composes the shared drive services for community deployments.
package drive

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/storage/oss"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	account "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	favorites "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/favorite"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/favorite"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientdrive"
	"net/url"
)

type Storage struct{ store object.Store }

func (s *Storage) Resolve(ctx context.Context, tenantID int64) (object.Store, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s == nil || s.store == nil {
		return nil, apperr.ErrUpstreamUnavailable.Withf("object storage not configured")
	}
	return s.store, nil
}
func NewStorage(c config.Config) (*Storage, error) {
	o := c.Object
	if o.Endpoint == "" && o.ReadEndpoint == "" && o.Bucket == "" && o.AccessKey == "" && o.SecretKey == "" {
		return nil, nil
	}
	u, err := url.Parse(o.Endpoint)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("invalid object storage endpoint")
	}
	if o.ReadEndpoint != "" {
		u, err := url.Parse(o.ReadEndpoint)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return nil, errors.New("invalid object storage read endpoint")
		}
	}
	store, err := oss.New(oss.Config{Endpoint: o.Endpoint, ReadEndpoint: o.ReadEndpoint, Bucket: o.Bucket, AccessKeyID: o.AccessKey, SecretAccessKey: o.SecretKey, ForcePathStyle: true})
	if err != nil {
		return nil, err
	}
	return &Storage{store: store}, nil
}
func Compose(pool *pgxpool.Pool, storage *Storage) *clientdrive.Handlers {
	if storage == nil {
		panic("object storage required")
	}
	spaces, folders, files := repo.NewSpaceRepo(pool), repo.NewFolderRepo(pool), repo.NewFileRepo(pool)
	recycle, quotas, versions := repo.NewRecycleRepo(pool), repo.NewQuotaRepo(pool), repo.NewFileVersionRepo(pool)
	acl, aclRepo, accounts := svc.NewACLService(pool), repo.NewACLRepo(pool), account.New(pool)
	fileSvc := svc.NewFileSvc(pool, spaces, folders, files, recycle, acl, storage).WithQuotas(quotas).WithVersions(versions)
	return &clientdrive.Handlers{
		Drivev3:       svc.NewBootstrapSvc(pool, spaces, folders, files, acl).WithSystemFolders(svc.NewSystemFoldersSvc(pool, spaces, folders)),
		Drivev3Spaces: spaces, Drivev3Folders: folders, Drivev3ACL: acl,
		Drivev3Folder:      svc.NewFolderSvc(pool, spaces, folders, recycle, acl).WithFiles(files),
		Drivev3Upload:      svc.NewUploadSvc(pool, spaces, folders, files, repo.NewTicketRepo(pool), quotas, acl, storage).WithVersions(versions),
		Drivev3File:        fileSvc,
		Drivev3Discover:    svc.NewDiscoverSvc(pool, spaces, folders, files, acl).WithACLRepo(aclRepo).WithOwnerLookup(accounts),
		Drivev3Recycle:     svc.NewRecycleSvc(pool, spaces, folders, files, quotas, recycle, acl, storage).WithDeletedByLookup(accounts),
		Drivev3SharedSpace: svc.NewSharedSpaceSvc(spaces, acl).WithMembers(aclRepo, accountLookup{accounts}),
		DriveFavorites:     favorite.New(favorites.New(pool), fileSvc, nil),
	}
}

type accountLookup struct{ accounts *account.Repo }

func (l accountLookup) ResolveByUUID(ctx context.Context, uuid string, tenantID int64) (int64, error) {
	a, err := l.accounts.GetByUUID(ctx, uuid)
	if err != nil {
		return 0, err
	}
	if _, err = l.accounts.GetMembership(ctx, a.ID, tenantID); err != nil {
		return 0, apperr.ErrNotFound
	}
	return a.ID, nil
}
func (l accountLookup) UUIDsByIDs(ctx context.Context, ids []int64) (map[int64]string, error) {
	accounts, err := l.accounts.ListByIDs(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string, len(accounts))
	for _, a := range accounts {
		out[a.ID] = a.UUID
	}
	return out, nil
}
