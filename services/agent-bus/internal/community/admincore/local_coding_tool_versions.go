package admincore

// F31 · 本地编程工具版本目录（docs/features/F31-local-coding-tools-version-catalog-plan.md §3）。
// 平台管理员建版本草稿 → 上传包 → 发布（灰度到指定租户 / 全量）→ 下线。
// 权限复用 platform.client_version.*（同一"平台发布物"家族，不新增权限码）。

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type localCodingToolVersionListResp struct {
	Items  []dom.Version `json:"items"`
	Total  int64         `json:"total"`
	Limit  int           `json:"limit"`
	Offset int           `json:"offset"`
}

type localCodingToolVersionReq struct {
	TargetID         string `json:"target_id"`
	Platform         string `json:"platform"`
	Arch             string `json:"arch"`
	Version          string `json:"version"`
	Layout           string `json:"layout"`
	Member           string `json:"member"`
	BinarySHA256     string `json:"binary_sha256"`
	BundleIdentifier string `json:"bundle_identifier"`
	TeamIdentifier   string `json:"team_identifier"`
	MinBridgeVersion string `json:"min_bridge_version"`
	MinAppVersion    string `json:"min_app_version"`
	ProfileVersion   string `json:"profile_version"`
	ContractCheckRef string `json:"contract_check_ref"`
	ReleaseNotes     string `json:"release_notes"`
	ExternalURL      string `json:"external_url"`
	FileSizeBytes    int64  `json:"file_size_bytes"`
	SHA256           string `json:"sha256"`
}

func (r localCodingToolVersionReq) toInput(actorID int64) dom.UpsertInput {
	return dom.UpsertInput{
		TargetID: r.TargetID, Platform: r.Platform, Arch: r.Arch, Version: r.Version,
		Layout: r.Layout, Member: r.Member, BinarySHA256: r.BinarySHA256,
		BundleIdentifier: r.BundleIdentifier, TeamIdentifier: r.TeamIdentifier,
		MinBridgeVersion: r.MinBridgeVersion, MinAppVersion: r.MinAppVersion,
		ProfileVersion: r.ProfileVersion, ContractCheckRef: r.ContractCheckRef,
		ReleaseNotes: r.ReleaseNotes, ExternalURL: r.ExternalURL,
		FileSizeBytes: r.FileSizeBytes, SHA256: r.SHA256, ActorID: actorID,
	}
}

type localCodingToolVersionPublishReq struct {
	Mode      string  `json:"mode"`
	TenantIDs []int64 `json:"tenant_ids"`
}

func (h *Handlers) listLocalCodingToolVersions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	filter := dom.Filter{
		TargetID: q.Get("target_id"), Platform: q.Get("platform"), Arch: q.Get("arch"),
		Status: q.Get("status"), Keyword: q.Get("q"), Limit: limit, Offset: offset,
	}
	items, total, err := h.LocalCodingCatalog.List(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, localCodingToolVersionListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

func (h *Handlers) getLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	item, err := h.LocalCodingCatalog.Get(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) createLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	var req localCodingToolVersionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.LocalCodingCatalog.Create(r.Context(), req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) patchLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	var req localCodingToolVersionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.LocalCodingCatalog.Update(r.Context(), r.PathValue("uuid"), req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) uploadLocalCodingToolPackage(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("parse multipart: %v", err))
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("missing file field: %v", err))
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("empty file"))
		return
	}
	item, err := h.LocalCodingCatalog.UploadPackage(
		r.Context(), r.PathValue("uuid"), header.Filename, header.Header.Get("Content-Type"),
		file, header.Size, middleware.MustAccountID(r.Context()),
	)
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) publishLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	var req localCodingToolVersionPublishReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.LocalCodingCatalog.Publish(r.Context(), r.PathValue("uuid"), dom.PublishInput{
		Mode: req.Mode, TenantIDs: req.TenantIDs, ActorID: middleware.MustAccountID(r.Context()),
	})
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) deprecateLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	item, err := h.LocalCodingCatalog.Deprecate(r.Context(), r.PathValue("uuid"), middleware.MustAccountID(r.Context()))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

// mirrorLocalCodingToolPackage copies an external package into the platform
// object store in the background; the row's mirror_state reports progress.
func (h *Handlers) mirrorLocalCodingToolPackage(w http.ResponseWriter, r *http.Request) {
	item, err := h.LocalCodingCatalog.MirrorPackage(r.Context(), r.PathValue("uuid"), middleware.MustAccountID(r.Context()))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

// startLocalCodingAutoSync is the operator's "check for new versions now".
// A round downloads several hundred MB, so it only starts here; the page
// polls getLocalCodingAutoSync for the outcome.
func (h *Handlers) startLocalCodingAutoSync(w http.ResponseWriter, r *http.Request) {
	if err := h.LocalCodingCatalog.StartAutoSync(r.Context()); err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	encode.JSONStatus(w, http.StatusAccepted, map[string]any{"status": h.LocalCodingCatalog.AutoSyncStatus()})
}

func (h *Handlers) getLocalCodingAutoSync(w http.ResponseWriter, _ *http.Request) {
	encode.JSON(w, map[string]any{"status": h.LocalCodingCatalog.AutoSyncStatus()})
}

func (h *Handlers) deleteLocalCodingToolVersion(w http.ResponseWriter, r *http.Request) {
	if err := h.LocalCodingCatalog.Delete(r.Context(), r.PathValue("uuid"), middleware.MustAccountID(r.Context())); err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// downloadLocalCodingToolPackage lets an operator fetch any uploaded package
// (draft included) for verification. Like client-versions it answers JSON
// with a short-lived signed URL instead of a 302: the admin web must call
// this with the bearer header (fetch), then window.open the URL; a redirect
// onto the cross-origin object store would fail the fetch's CORS read.
func (h *Handlers) downloadLocalCodingToolPackage(w http.ResponseWriter, r *http.Request) {
	target, err := h.LocalCodingCatalog.AdminPackageURL(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, mapLocalCodingCatalogError(err))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, map[string]string{"download_url": target})
}

func mapLocalCodingCatalogError(err error) error {
	switch {
	case errors.Is(err, dom.ErrInvalidTarget),
		errors.Is(err, dom.ErrInvalidPlatform),
		errors.Is(err, dom.ErrInvalidArch),
		errors.Is(err, dom.ErrInvalidLayout),
		errors.Is(err, dom.ErrInvalidStatus),
		errors.Is(err, dom.ErrMissingVersion),
		errors.Is(err, dom.ErrMissingMember),
		errors.Is(err, dom.ErrInvalidSHA256),
		errors.Is(err, dom.ErrInvalidPublishMode),
		errors.Is(err, dom.ErrCanaryTenantsMissing):
		return apperr.ErrInvalidParams.Wrap(err)
	case errors.Is(err, dom.ErrNotDraft):
		return apperr.ErrConflict.Withf("只有草稿可以修改；已发布版本只有包是外链时才能补传同一个文件")
	case errors.Is(err, dom.ErrNotPublished):
		return apperr.ErrConflict.Withf("该版本未发布，无需下线")
	case errors.Is(err, dom.ErrDuplicateVersion):
		return apperr.ErrConflict.Withf("同一目标 / 平台 / 架构下已有该版本")
	case errors.Is(err, dom.ErrCanaryTenantOverlap):
		return apperr.ErrConflict.Withf("所选租户已在另一个灰度版本里")
	case errors.Is(err, dom.ErrPackageMissing):
		return apperr.ErrConflict.Withf("发布前请先上传包")
	case errors.Is(err, dom.ErrContractCheckMissing):
		return apperr.ErrConflict.Withf("发布前请填写合同检查记录")
	case errors.Is(err, dom.ErrMissingBinarySHA):
		return apperr.ErrConflict.Withf("命令行工具与运行组件发布前必须填写裸二进制 SHA-256")
	case errors.Is(err, dom.ErrPackageStoreMissing):
		return apperr.ErrUpstreamUnavailable.Withf("平台对象存储未配置，无法上传或下载包")
	case errors.Is(err, dom.ErrPackageNotDownloadable):
		return apperr.ErrNotFound.Withf("该版本没有可下载的包")
	case errors.Is(err, dom.ErrPackageNotExternal):
		return apperr.ErrConflict.Withf("该版本的包不是外链，无需搬入对象存储")
	case errors.Is(err, dom.ErrMirrorRunning):
		return apperr.ErrConflict.Withf("正在搬入对象存储，请稍候刷新")
	case errors.Is(err, dom.ErrMirrorMismatch):
		return apperr.ErrConflict.Withf("文件与记录的大小或 SHA-256 不符，未替换")
	case errors.Is(err, dom.ErrAutoSyncDisabled):
		return apperr.ErrConflict.Withf("自动同步未开启（AGBUS_LOCAL_CODING_AUTOSYNC_ENABLED）")
	case errors.Is(err, dom.ErrAutoSyncRunning):
		return apperr.ErrConflict.Withf("正在检查新版本，请稍候刷新")
	default:
		return err
	}
}
