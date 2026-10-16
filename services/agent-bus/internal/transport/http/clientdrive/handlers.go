package clientdrive

import (
	drivev3repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	svcdriv3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	svcfavorite "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/favorite"
)

type Handlers struct {
	Drivev3            *svcdriv3.BootstrapSvc  // Bootstrap + folder tree/children 读接口
	Drivev3Spaces      *drivev3repo.SpaceRepo  // 供 GetByUUID (drivev3_read handler 用)
	Drivev3Folders     *drivev3repo.FolderRepo // 供 GetByUUID
	Drivev3ACL         *svcdriv3.ACLService    // ACL viewer+ checker
	Drivev3Folder      *svcdriv3.FolderSvc
	Drivev3Upload      *svcdriv3.UploadSvc
	Drivev3File        *svcdriv3.FileSvc
	Drivev3Discover    *svcdriv3.DiscoverSvc
	Drivev3Recycle     *svcdriv3.RecycleSvc
	Drivev3SharedSpace *svcdriv3.SharedSpaceSvc
	DriveFavorites     *svcfavorite.Service
}

// Preserve the existing multipart memory threshold; larger data uses temporary files.
const uploadMaxMemory = 4 * 1024 * 1024
