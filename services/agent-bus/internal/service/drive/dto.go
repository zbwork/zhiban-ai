// dto.go — F06 客户端响应 DTO (snake_case + UUID 寻址).
//
// 背景: bootstrap / folders tree / folders children + folder create/rename/move 旧实现直接
// encode 裸 domain struct (dom.Space/Folder/File), 这些 domain 无 json tag → 输出 PascalCase
// 且泄漏内部字段 (ID/SpaceID/CreatedBy/IsDeleted/StorageKey ...). 本文件提供裁剪后的
// 客户端 DTO + 映射器, 由 transport 层调用; 服务端内部仍用 domain struct, 不受影响.
//
// 契约见 docs/features/F06-drive.md §3.2 + docs/contracts/agent-bus-client-contract.md §4.
package drive

import (
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// SpaceDTO 客户端空间视图 (剔除 ID/TenantID/Owner/Dept/时间戳/软删).
type SpaceDTO struct {
	UUID        string `json:"uuid"`
	Kind        string `json:"kind"` // personal|tenant|department|shared
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      string `json:"status"`
	UsedBytes   int64  `json:"used_bytes"`
}

// FolderDTO 客户端文件夹视图 (UUID 寻址; parent_uuid 由调用方解析; 剔除内部 id/时间戳/软删).
type FolderDTO struct {
	UUID       string `json:"uuid"`
	ParentUUID string `json:"parent_uuid"` // 空 = space 根
	Name       string `json:"name"`
	Kind       string `json:"kind"`               // regular|de_root|de_agent|de_outputs
	AgentID    string `json:"agent_id,omitempty"` // de_agent/de_outputs 时非空
	IsSystem   bool   `json:"is_system"`
	Path       string `json:"path"`
	Sort       int    `json:"sort"`
}

// FileDTO 客户端文件视图 (children 列表用; 不含 storage_key/sha256/内部 id).
type FileDTO struct {
	UUID       string    `json:"uuid"`
	FolderUUID string    `json:"folder_uuid,omitempty"`
	Name       string    `json:"name"`
	MimeType   string    `json:"mime_type"`
	SizeBytes  int64     `json:"size_bytes"`
	Source     string    `json:"source"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// BootstrapDTO POST /drive:bootstrap 客户端响应.
type BootstrapDTO struct {
	Spaces struct {
		Personal    *SpaceDTO  `json:"personal"`
		Tenant      *SpaceDTO  `json:"tenant"`
		Departments []SpaceDTO `json:"departments"`
		Shared      []SpaceDTO `json:"shared"`
	} `json:"spaces"`
}

// FolderTreeDTO GET /drive/spaces/{uuid}/folders/tree 客户端响应.
type FolderTreeDTO struct {
	Items []FolderDTO `json:"items"`
}

// FolderChildrenDTO GET /drive/folders/{uuid}/children 客户端响应.
type FolderChildrenDTO struct {
	Folders []FolderDTO `json:"folders"`
	Files   []FileDTO   `json:"files"`
	Total   int         `json:"total"`
}

// SpaceToDTO 映射单个 space.
func SpaceToDTO(s *dom.Space) *SpaceDTO {
	if s == nil {
		return nil
	}
	return &SpaceDTO{
		UUID:        s.UUID,
		Kind:        string(s.Kind),
		Name:        s.Name,
		Description: s.Description,
		Status:      string(s.Status),
		UsedBytes:   s.UsedBytes,
	}
}

// SpacesToDTO 映射 space 列表.
func SpacesToDTO(in []dom.Space) []SpaceDTO {
	out := make([]SpaceDTO, 0, len(in))
	for i := range in {
		out = append(out, *SpaceToDTO(&in[i]))
	}
	return out
}

// FolderToDTO 映射单个 folder; parentUUID 由调用方提供 (create/move 来自请求, rename 经 repo 反查).
func FolderToDTO(f *dom.Folder, parentUUID string) FolderDTO {
	agentID := ""
	if f.AgentID != nil {
		agentID = *f.AgentID
	}
	return FolderDTO{
		UUID:       f.UUID,
		ParentUUID: parentUUID,
		Name:       f.Name,
		Kind:       string(f.Kind),
		AgentID:    agentID,
		IsSystem:   f.IsSystem,
		Path:       f.Path,
		Sort:       f.Sort,
	}
}

// FoldersTreeToDTO 映射整棵 space folder 列表; 用 id→uuid map 解析每个 folder 的 parent_uuid.
func FoldersTreeToDTO(in []dom.Folder) []FolderDTO {
	idToUUID := make(map[int64]string, len(in))
	for i := range in {
		idToUUID[in[i].ID] = in[i].UUID
	}
	out := make([]FolderDTO, 0, len(in))
	for i := range in {
		parentUUID := ""
		if in[i].ParentID != nil {
			parentUUID = idToUUID[*in[i].ParentID]
		}
		out = append(out, FolderToDTO(&in[i], parentUUID))
	}
	return out
}

// FoldersChildrenToDTO 映射 children folder 列表; 它们的 parent 均为被请求 folder (parentUUID 已知).
func FoldersChildrenToDTO(in []dom.Folder, parentUUID string) []FolderDTO {
	out := make([]FolderDTO, 0, len(in))
	for i := range in {
		out = append(out, FolderToDTO(&in[i], parentUUID))
	}
	return out
}

// FileToDTO 映射单个 file; folderUUID 由调用方提供 (children 来自被请求 folder).
func FileToDTO(f *dom.File, folderUUID string) FileDTO {
	return FileDTO{
		UUID:       f.UUID,
		FolderUUID: folderUUID,
		Name:       f.Name,
		MimeType:   f.MimeType,
		SizeBytes:  f.SizeBytes,
		Source:     string(f.Source),
		CreatedAt:  f.CreatedAt,
		UpdatedAt:  f.UpdatedAt,
	}
}

// FilesToDTO 映射 file 列表 (children 用; folderUUID 同一父).
func FilesToDTO(in []dom.File, folderUUID string) []FileDTO {
	out := make([]FileDTO, 0, len(in))
	for i := range in {
		out = append(out, FileToDTO(&in[i], folderUUID))
	}
	return out
}

// BootstrapToDTO 映射 bootstrap 响应.
func BootstrapToDTO(r *BootstrapResp) *BootstrapDTO {
	var d BootstrapDTO
	d.Spaces.Personal = SpaceToDTO(r.Spaces.Personal)
	d.Spaces.Tenant = SpaceToDTO(r.Spaces.Tenant)
	d.Spaces.Departments = SpacesToDTO(r.Spaces.Departments)
	d.Spaces.Shared = SpacesToDTO(r.Spaces.Shared)
	return &d
}
