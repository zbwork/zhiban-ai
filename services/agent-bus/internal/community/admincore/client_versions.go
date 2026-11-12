package admincore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientversion"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type clientVersionListResp struct {
	Items  []dom.Version `json:"items"`
	Total  int64         `json:"total"`
	Limit  int           `json:"limit"`
	Offset int           `json:"offset"`
}

type clientVersionUploadResp struct {
	StorageURI  string      `json:"storage_uri"`
	DownloadURL string      `json:"download_url"`
	FileName    string      `json:"file_name"`
	SizeBytes   int64       `json:"size_bytes"`
	SHA256      string      `json:"sha256"`
	Item        dom.Version `json:"item"`
}

type clientVersionReq struct {
	Platform            string `json:"platform"`
	Arch                string `json:"arch"`
	Channel             string `json:"channel"`
	Version             string `json:"version"`
	BuildNumber         string `json:"build_number"`
	Title               string `json:"title"`
	ReleaseNotes        string `json:"release_notes"`
	DownloadURL         string `json:"download_url"`
	AppcastURL          string `json:"appcast_url"`
	SparkleEDSignature  string `json:"sparkle_ed_signature"`
	FileSizeBytes       int64  `json:"file_size_bytes"`
	SHA256              string `json:"sha256"`
	MinOSVersion        string `json:"min_os_version"`
	MinSupportedVersion string `json:"min_supported_version"`
	IsForced            bool   `json:"is_forced"`
	Status              string `json:"status"`
}

func (h *Handlers) listClientVersions(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	sort := q.Get("sort")
	if sort != "build_number" && sort != "-build_number" {
		sort = ""
	}
	filter := dom.Filter{
		Platform: q.Get("platform"),
		Arch:     q.Get("arch"),
		Channel:  q.Get("channel"),
		Status:   q.Get("status"),
		Keyword:  q.Get("q"),
		Limit:    limit,
		Offset:   offset,
		SortBy:   sort,
	}
	items, total, err := h.ClientVersion.List(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	for i := range items {
		rewriteClientVersionShortLinks(r, &items[i])
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, clientVersionListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

func (h *Handlers) getClientVersion(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	item, err := h.ClientVersion.Get(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	rewriteClientVersionShortLinks(r, item)
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) createClientVersion(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	var req clientVersionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.ClientVersion.Create(r.Context(), req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	rewriteClientVersionShortLinks(r, item)
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) patchClientVersion(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	var req clientVersionReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.ClientVersion.Update(r.Context(), uuid, req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	rewriteClientVersionShortLinks(r, item)
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) uploadClientVersionInstaller(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
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
	uploaded, item, err := h.ClientVersion.UploadInstaller(
		r.Context(),
		uuid,
		header.Filename,
		header.Header.Get("Content-Type"),
		file,
		header.Size,
		middleware.MustAccountID(r.Context()),
	)
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	rewriteClientVersionShortLinks(r, item)
	encode.JSON(w, clientVersionUploadResp{
		StorageURI:  uploaded.StorageURI,
		DownloadURL: item.DownloadURL,
		FileName:    uploaded.FileName,
		SizeBytes:   uploaded.SizeBytes,
		SHA256:      uploaded.SHA256,
		Item:        *item,
	})
}

func (h *Handlers) uploadClientVersionAppcast(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	if err := r.ParseMultipartForm(4 << 20); err != nil {
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
	uploaded, item, err := h.ClientVersion.UploadAppcast(
		r.Context(),
		uuid,
		header.Filename,
		header.Header.Get("Content-Type"),
		file,
		header.Size,
		middleware.MustAccountID(r.Context()),
	)
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	rewriteClientVersionShortLinks(r, item)
	encode.JSON(w, clientVersionUploadResp{
		StorageURI:  uploaded.StorageURI,
		DownloadURL: item.AppcastURL,
		FileName:    uploaded.FileName,
		SizeBytes:   uploaded.SizeBytes,
		SHA256:      uploaded.SHA256,
		Item:        *item,
	})
}

func (h *Handlers) uploadClientVersionDelta(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := strings.TrimSpace(r.PathValue("uuid"))
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
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
	// delta_from: 旧版本 CFBundleVersion（Sparkle 生成 delta 时确定）；ed_signature:
	// Sparkle 对 delta 文件的 EdDSA 签名。两者由发布侧在 appcast 中提供，后台仅存储透传。
	deltaFrom := strings.TrimSpace(r.FormValue("delta_from"))
	edSignature := strings.TrimSpace(r.FormValue("ed_signature"))
	uploaded, err := h.ClientVersion.UploadDelta(r.Context(), uuid, header.Filename, header.Header.Get("Content-Type"), file, header.Size, deltaFrom, edSignature)
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	// Admin and Bus can use different origins. The upload receipt exposes the
	// storage URL already signed by PackageStore; the Bus owns stable feed URLs.
	publicURL := uploaded.DownloadURL
	encode.JSON(w, map[string]any{
		"storage_uri":  uploaded.StorageURI,
		"download_url": publicURL,
		"file_name":    uploaded.FileName,
		"size_bytes":   uploaded.SizeBytes,
		"sha256":       uploaded.SHA256,
		"delta_from":   deltaFrom,
		"ed_signature": edSignature,
	})
}

// downloadClientVersionPackage 给已上传安装包的版本一个后台可点的下载入口
// （之前只显示"已上传"状态文字，没有实际下载方式）。复用 Bus 端已有的
// DownloadRedirectURL（内部对 oss:// 签临时 URL），跟客户端下载走同一套签名
// 逻辑，只是入口换成 /api/admin/v1/*，不直接把 Bus API 地址暴露给 admin 前端
// （边界：admin 只调 /api/admin/v1/*）。
//
// 这里返回 JSON{download_url} 而不是像 Bus 端那样直接 302：前端要带
// Authorization header 才能过 platformPerm，只能用 fetch（不能靠浏览器原生
// 导航/window.open，那样不带鉴权头），但 fetch 默认会跟着 302 走到跨域的签名
// OSS URL 上——那一跳没有 CORS 头，fetch 直接失败（真实验证过：Network 面板
// 里 download-package 后面紧跟一个到 s3.test.yixin.com 的失败请求）。改成
// JSON 返回签名 URL，前端再用 window.open 做一次普通页面跳转去下载
// （跳转不受 CORS 限制，只有 fetch/XHR 才受限），两跳都能过。
func (h *Handlers) downloadClientVersionPackage(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := strings.TrimSpace(r.PathValue("uuid"))
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	target, err := h.ClientVersion.DownloadRedirectURL(r.Context(), uuid, "package")
	if err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	encode.JSON(w, map[string]any{"download_url": target})
}

func (h *Handlers) deleteClientVersion(w http.ResponseWriter, r *http.Request) {
	if h.ClientVersion == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client version service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	if err := h.ClientVersion.Delete(r.Context(), uuid, middleware.MustAccountID(r.Context())); err != nil {
		encode.JSONError(w, mapClientVersionError(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (r clientVersionReq) toInput(actorID int64) dom.UpsertInput {
	return dom.UpsertInput{
		Platform:            r.Platform,
		Arch:                r.Arch,
		Channel:             r.Channel,
		Version:             r.Version,
		BuildNumber:         r.BuildNumber,
		Title:               r.Title,
		ReleaseNotes:        r.ReleaseNotes,
		DownloadURL:         r.DownloadURL,
		AppcastURL:          r.AppcastURL,
		SparkleEDSignature:  r.SparkleEDSignature,
		FileSizeBytes:       r.FileSizeBytes,
		SHA256:              r.SHA256,
		MinOSVersion:        r.MinOSVersion,
		MinSupportedVersion: r.MinSupportedVersion,
		IsForced:            r.IsForced,
		Status:              r.Status,
		ActorID:             actorID,
	}
}

func mapClientVersionError(err error) error {
	switch {
	case errors.Is(err, dom.ErrMissingDeltaFrom):
		return apperr.ErrInvalidParams.Withf(dom.ErrMissingDeltaFrom.Error())
	case errors.Is(err, dom.ErrInvalidDeltaSignature):
		return apperr.ErrInvalidParams.Withf(dom.ErrInvalidDeltaSignature.Error())
	case errors.Is(err, dom.ErrInvalidPlatform),
		errors.Is(err, dom.ErrInvalidArch),
		errors.Is(err, dom.ErrInvalidChannel),
		errors.Is(err, dom.ErrInvalidStatus),
		errors.Is(err, dom.ErrMissingVersion),
		errors.Is(err, dom.ErrMissingBuild),
		errors.Is(err, dom.ErrMissingDownload),
		errors.Is(err, dom.ErrMissingCurrentVer):
		return apperr.ErrInvalidParams.Wrap(err)
	case errors.Is(err, dom.ErrInstallerStoreMissing):
		return apperr.ErrUpstreamUnavailable.Withf("client installer storage not configured")
	case errors.Is(err, dom.ErrDuplicateBuild):
		return apperr.ErrConflict.Withf("该构建号已存在 (platform/arch/channel/build_number 已有一条记录)")
	default:
		return err
	}
}

func rewriteClientVersionShortLinks(r *http.Request, item *dom.Version) {
	if item == nil {
		return
	}
	// admin 前端只调 /api/admin/v1/*（边界见 docs/architecture/agent-bus-boundaries.md），
	// 不能直接把 Bus API 地址下发给它去 fetch/跳转；这里跟 bus 包里同名函数的区别
	// 就是短链前缀换成 admin 自己的下载路由。
	base := requestBaseURL(r)
	if strings.HasPrefix(item.DownloadURLRaw, "oss://") {
		item.DownloadURL = base + "/api/admin/v1/platform/client-versions/" + item.UUID + "/download-package"
	}
	if strings.HasPrefix(item.AppcastURLRaw, "oss://") {
		item.AppcastURL = base + "/api/agent-bus/v1/app/client-versions/" + item.UUID + "/download-appcast"
	}
}

func requestBaseURL(r *http.Request) string {
	// 反向代理没转发 X-Forwarded-Proto 时默认按 https 拼——admin 域名只支持
	// HTTPS，兜底成 http 会拼出被 Android cleartext 策略拦截的下载链接
	// （同一个坑见 bus 包 app_update.go 的 requestBaseURL，2026-08-20 真实反馈）。
	proto := firstHeaderValue(r.Header.Get("X-Forwarded-Proto"))
	if proto == "" {
		proto = "https"
		if strings.HasPrefix(r.Host, "127.0.0.1:") || strings.HasPrefix(r.Host, "localhost:") || r.Host == "127.0.0.1" || r.Host == "localhost" {
			proto = "http"
		}
	}
	host := firstHeaderValue(r.Header.Get("X-Forwarded-Host"))
	if host == "" {
		host = r.Host
	}
	if host == "" && r.URL != nil {
		host = r.URL.Host
	}
	return strings.TrimRight(proto+"://"+host, "/")
}

func firstHeaderValue(value string) string {
	if i := strings.Index(value, ","); i >= 0 {
		value = value[:i]
	}
	return strings.TrimSpace(value)
}
