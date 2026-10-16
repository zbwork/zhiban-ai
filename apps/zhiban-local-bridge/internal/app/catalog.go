package app

import (
	"context"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/rpc"
)

// CatalogManager applies the signed version catalog and reports upgrade /
// rollback availability for a detected tool (F31 version catalog plan §4).
// The install manager implements it.
type CatalogManager interface {
	ApplyCatalog(context.Context, install.CatalogApplyInput) (install.CatalogStatus, error)
	Availability(context.Context, string, detect.State) install.Availability
}

// detectWithAvailability is the tool.detect result once a catalog manager is
// wired: the detected state plus available_version / rollback_version /
// update_available. Both parts marshal flat.
type detectWithAvailability struct {
	detect.State
	install.Availability
}

// wireCatalog adds catalog.apply and decorates tool.detect with the catalog's
// availability fields. It must run after rpcConfig.Detect is set.
func wireCatalog(rpcConfig *rpc.Config, catalogs CatalogManager) {
	rpcConfig.CatalogApply = func(ctx context.Context, params rpc.CatalogApplyParams) (any, error) {
		return catalogs.ApplyCatalog(ctx, install.CatalogApplyInput{
			Environment: params.Environment,
			Signed:      catalog.Signed{Catalog: params.Catalog, KID: params.KID, Signature: params.Signature},
		})
	}
	inner := rpcConfig.Detect
	if inner == nil {
		return
	}
	rpcConfig.Detect = func(ctx context.Context, targetID string) (any, error) {
		result, err := inner(ctx, targetID)
		if err != nil {
			return nil, err
		}
		state, ok := result.(detect.State)
		if !ok {
			return result, nil
		}
		return detectWithAvailability{State: state, Availability: catalogs.Availability(ctx, targetID, state)}, nil
	}
}
