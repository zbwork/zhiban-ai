package clientversion

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientversion"
)

type Service interface {
	List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error)
	Get(ctx context.Context, uuid string) (*dom.Version, error)
	Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error)
	Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error)
	UploadInstaller(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*UploadResult, *dom.Version, error)
	UploadAppcast(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*UploadResult, *dom.Version, error)
	UploadDelta(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, deltaFrom, edSignature string) (*UploadResult, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	UpdateInfo(ctx context.Context, q dom.UpdateQuery) (*dom.UpdateInfo, error)
	DownloadRedirectURL(ctx context.Context, uuid, asset string) (string, error)
	DownloadDeltaRedirectURL(ctx context.Context, uuid, filename string) (string, error)
}

func (s *impl) UploadDelta(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, deltaFrom, edSignature string) (*UploadResult, error) {
	deltaFrom = strings.TrimSpace(deltaFrom)
	edSignature = strings.TrimSpace(edSignature)
	if deltaFrom == "" {
		return nil, dom.ErrMissingDeltaFrom
	}
	decodedSignature, err := base64.StdEncoding.DecodeString(edSignature)
	if err != nil || len(decodedSignature) != 64 {
		return nil, dom.ErrInvalidDeltaSignature
	}
	if s.packages == nil {
		return nil, dom.ErrInstallerStoreMissing
	}
	cur, err := s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
	if err != nil {
		return nil, err
	}
	if cur.Platform != dom.PlatformMacOS {
		return nil, fmt.Errorf("client delta upload: only macos is supported")
	}
	result, err := s.packages.UploadDelta(ctx, cur.UUID, filename, body, size, contentType)
	if err != nil {
		return nil, err
	}
	// 文件落库成功后记录元数据；delta_from / ed_signature 由发布侧（Sparkle
	// appcast）提供，Bus 动态 appcast 原样输出，客户端据此匹配增量包。
	if err := s.repo.AppendDelta(ctx, cur.UUID, dom.DeltaInfo{
		FileName:    result.FileName,
		StorageURI:  result.StorageURI,
		DeltaFrom:   deltaFrom,
		SizeBytes:   result.SizeBytes,
		SHA256:      result.SHA256,
		EdSignature: edSignature,
	}); err != nil {
		return nil, err
	}
	return result, nil
}

type impl struct {
	repo     dom.Repository
	packages *PackageStore
}

func New(repo dom.Repository) Service {
	return &impl{repo: repo}
}

func NewWithPackageStore(repo dom.Repository, packages *PackageStore) Service {
	return &impl{repo: repo, packages: packages}
}

func (s *impl) List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error) {
	f.Platform = normalize(f.Platform)
	f.Arch = normalize(f.Arch)
	f.Channel = normalize(f.Channel)
	f.Status = normalize(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	if f.Platform != "" && !dom.ValidPlatform(f.Platform) {
		return nil, 0, dom.ErrInvalidPlatform
	}
	if f.Arch != "" && !dom.ValidArch(f.Arch) {
		return nil, 0, dom.ErrInvalidArch
	}
	if f.Channel != "" && !dom.ValidChannel(f.Channel) {
		return nil, 0, dom.ErrInvalidChannel
	}
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, 0, dom.ErrInvalidStatus
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	items, total, err := s.repo.List(ctx, f)
	if err != nil {
		return nil, 0, err
	}
	for i := range items {
		s.resolveDownloadURL(ctx, &items[i])
	}
	return items, total, nil
}

func (s *impl) Get(ctx context.Context, uuid string) (*dom.Version, error) {
	item, err := s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
	if err != nil {
		return nil, err
	}
	s.resolveDownloadURL(ctx, item)
	return item, nil
}

func (s *impl) Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	item, err := s.repo.Create(ctx, normalized)
	if err != nil {
		return nil, err
	}
	s.resolveDownloadURL(ctx, item)
	return item, nil
}

func (s *impl) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	uuid = strings.TrimSpace(uuid)
	// An update carries the whole record, so a caller that uploaded a package
	// and then saved a form it had loaded before the upload used to write the
	// package's size and hash back as empty (real releases 1.2.1+12100 on
	// macOS and 1.2.0+12017 on Windows both ended up with length 0, which
	// fails the update check on the client). While the package itself is
	// unchanged, keep what the upload recorded.
	if cur, err := s.repo.GetByUUID(ctx, uuid); err == nil && cur != nil && cur.DownloadURL == normalized.DownloadURL {
		if normalized.FileSizeBytes == 0 {
			normalized.FileSizeBytes = cur.FileSizeBytes
		}
		if normalized.SHA256 == "" {
			normalized.SHA256 = cur.SHA256
		}
	}
	item, err := s.repo.Update(ctx, uuid, normalized)
	if err != nil {
		return nil, err
	}
	s.resolveDownloadURL(ctx, item)
	return item, nil
}

func (s *impl) UploadInstaller(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*UploadResult, *dom.Version, error) {
	uuid = strings.TrimSpace(uuid)
	if s.packages == nil {
		return nil, nil, dom.ErrInstallerStoreMissing
	}
	cur, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, nil, err
	}
	uploaded, err := s.packages.Upload(ctx, uuid, filename, body, size, contentType)
	if err != nil {
		return nil, nil, err
	}
	in := dom.UpsertInput{
		Platform:            cur.Platform,
		Arch:                cur.Arch,
		Channel:             cur.Channel,
		Version:             cur.Version,
		BuildNumber:         cur.BuildNumber,
		Title:               cur.Title,
		ReleaseNotes:        cur.ReleaseNotes,
		DownloadURL:         uploaded.StorageURI,
		AppcastURL:          cur.AppcastURL,
		SparkleEDSignature:  cur.SparkleEDSignature,
		FileSizeBytes:       uploaded.SizeBytes,
		SHA256:              uploaded.SHA256,
		MinOSVersion:        cur.MinOSVersion,
		MinSupportedVersion: cur.MinSupportedVersion,
		IsForced:            cur.IsForced,
		Status:              cur.Status,
		ActorID:             actorID,
	}
	item, err := s.repo.Update(ctx, uuid, in)
	if err != nil {
		return nil, nil, err
	}
	s.resolveDownloadURL(ctx, item)
	return uploaded, item, nil
}

func (s *impl) UploadAppcast(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*UploadResult, *dom.Version, error) {
	uuid = strings.TrimSpace(uuid)
	if s.packages == nil {
		return nil, nil, dom.ErrInstallerStoreMissing
	}
	cur, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, nil, err
	}
	uploaded, err := s.packages.UploadAppcast(ctx, uuid, filename, body, size, contentType)
	if err != nil {
		return nil, nil, err
	}
	in := dom.UpsertInput{
		Platform:            cur.Platform,
		Arch:                cur.Arch,
		Channel:             cur.Channel,
		Version:             cur.Version,
		BuildNumber:         cur.BuildNumber,
		Title:               cur.Title,
		ReleaseNotes:        cur.ReleaseNotes,
		DownloadURL:         cur.DownloadURL,
		AppcastURL:          uploaded.StorageURI,
		SparkleEDSignature:  cur.SparkleEDSignature,
		FileSizeBytes:       cur.FileSizeBytes,
		SHA256:              cur.SHA256,
		MinOSVersion:        cur.MinOSVersion,
		MinSupportedVersion: cur.MinSupportedVersion,
		IsForced:            cur.IsForced,
		Status:              cur.Status,
		ActorID:             actorID,
	}
	item, err := s.repo.Update(ctx, uuid, in)
	if err != nil {
		return nil, nil, err
	}
	s.resolveDownloadURL(ctx, item)
	return uploaded, item, nil
}

func (s *impl) Delete(ctx context.Context, uuid string, actorID int64) error {
	return s.repo.Delete(ctx, strings.TrimSpace(uuid), actorID)
}

func (s *impl) UpdateInfo(ctx context.Context, q dom.UpdateQuery) (*dom.UpdateInfo, error) {
	q.Platform = normalize(q.Platform)
	q.Arch = normalize(q.Arch)
	q.Channel = normalize(q.Channel)
	q.CurrentVersion = strings.TrimSpace(q.CurrentVersion)
	q.CurrentBuildNumber = strings.TrimSpace(q.CurrentBuildNumber)
	if q.Arch == "" {
		q.Arch = dom.ArchUniversal
	}
	if q.Channel == "" {
		q.Channel = dom.ChannelStable
	}
	if !dom.ValidPlatform(q.Platform) {
		return nil, dom.ErrInvalidPlatform
	}
	if !dom.ValidArch(q.Arch) {
		return nil, dom.ErrInvalidArch
	}
	if !dom.ValidChannel(q.Channel) {
		return nil, dom.ErrInvalidChannel
	}
	if q.CurrentVersion == "" {
		return nil, dom.ErrMissingCurrentVer
	}

	candidates, err := s.repo.ListPublishedCandidates(ctx, q.Platform, q.Arch, q.Channel)
	if err != nil {
		return nil, err
	}
	latest := newest(candidates)
	info := &dom.UpdateInfo{
		UpdateAvailable:    false,
		CurrentVersion:     q.CurrentVersion,
		CurrentBuildNumber: q.CurrentBuildNumber,
	}
	if latest == nil {
		return info, nil
	}
	if CompareRelease(latest.Version, latest.BuildNumber, q.CurrentVersion, q.CurrentBuildNumber) > 0 {
		s.resolveDownloadURL(ctx, latest)
		info.UpdateAvailable = true
		info.Latest = latest
	}
	return info, nil
}

func (s *impl) DownloadRedirectURL(ctx context.Context, uuid, asset string) (string, error) {
	uuid = strings.TrimSpace(uuid)
	asset = normalize(asset)
	if uuid == "" {
		return "", dom.ErrMissingDownload
	}
	item, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return "", err
	}
	switch asset {
	case "delta":
		return "", dom.ErrInvalidDownloadAsset
	case "package":
		if strings.TrimSpace(item.DownloadURL) == "" {
			return "", dom.ErrMissingDownload
		}
		return s.signedURL(ctx, item.DownloadURL, installerFilename(item))
	case "appcast":
		if strings.TrimSpace(item.AppcastURL) == "" {
			return "", dom.ErrMissingDownload
		}
		return s.signedURL(ctx, item.AppcastURL, "appcast.xml")
	default:
		return "", dom.ErrInvalidDownloadAsset
	}
}

func (s *impl) DownloadDeltaRedirectURL(ctx context.Context, uuid, filename string) (string, error) {
	uuid = strings.TrimSpace(uuid)
	name := sanitizeFilename(filename)
	if uuid == "" || name == "" || strings.ToLower(filepath.Ext(name)) != ".delta" {
		return "", dom.ErrInvalidDownloadAsset
	}
	item, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return "", err
	}
	if item.Platform != dom.PlatformMacOS || s.packages == nil {
		return "", dom.ErrInvalidDownloadAsset
	}
	for _, delta := range item.Deltas {
		if sanitizeFilename(delta.FileName) != name {
			continue
		}
		storageURI := strings.TrimSpace(delta.StorageURI)
		if storageURI == "" {
			// Compatibility for metadata written before storage_uri was persisted.
			key := strings.TrimSuffix(s.packages.cfg.Prefix, "/") + "/" + uuid + "/deltas/" + name
			storageURI = "oss://" + key
		}
		return s.packages.SignRecordedDeltaURL(ctx, storageURI, item.UUID, name)
	}
	return "", dom.ErrInvalidDownloadAsset
}

func (s *impl) resolveDownloadURL(ctx context.Context, item *dom.Version) {
	if item == nil || item.DownloadURL == "" {
		s.resolveAppcastURL(ctx, item)
		return
	}
	raw := item.DownloadURL
	item.DownloadURLRaw = raw
	if s.packages != nil && strings.HasPrefix(raw, "oss://") {
		filename := installerFilename(item)
		signed, err := s.packages.SignURL(ctx, raw, filename, 0)
		if err == nil && signed != "" {
			item.DownloadURL = signed
		}
	}
	s.resolveAppcastURL(ctx, item)
}

func (s *impl) resolveAppcastURL(ctx context.Context, item *dom.Version) {
	if item == nil || item.AppcastURL == "" {
		return
	}
	raw := item.AppcastURL
	item.AppcastURLRaw = raw
	if s.packages == nil || !strings.HasPrefix(raw, "oss://") {
		return
	}
	signed, err := s.packages.SignURL(ctx, raw, "appcast.xml", 0)
	if err == nil && signed != "" {
		item.AppcastURL = signed
	}
}

func (s *impl) signedURL(ctx context.Context, raw, filename string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", dom.ErrMissingDownload
	}
	if s.packages == nil || !strings.HasPrefix(raw, "oss://") {
		return raw, nil
	}
	return s.packages.SignURL(ctx, raw, filename, 0)
}

func installerFilename(item *dom.Version) string {
	if item == nil {
		return ""
	}
	ext := ".bin"
	switch item.Platform {
	case dom.PlatformMacOS:
		ext = ".dmg"
	case dom.PlatformWindows:
		ext = ".exe"
	case dom.PlatformAndroid:
		ext = ".apk"
	case dom.PlatformIOS:
		ext = ".ipa"
	}
	env := "release"
	if e := strings.ToLower(strings.TrimSpace(os.Getenv("AGBUS_ENV"))); e != "" && e != "prod" && e != "production" {
		env = "test"
	}
	name := fmt.Sprintf("ZhiBanAI_%s_%s_%s_%s", env, item.Version, item.BuildNumber, item.Platform)
	return sanitizeFilename(name + ext)
}

func normalizeInput(in dom.UpsertInput) (dom.UpsertInput, error) {
	in.Platform = normalize(in.Platform)
	in.Arch = normalize(in.Arch)
	in.Channel = normalize(in.Channel)
	in.Status = normalize(in.Status)
	in.Version = strings.TrimSpace(in.Version)
	in.BuildNumber = strings.TrimSpace(in.BuildNumber)
	in.Title = strings.TrimSpace(in.Title)
	in.ReleaseNotes = strings.TrimSpace(in.ReleaseNotes)
	in.DownloadURL = strings.TrimSpace(in.DownloadURL)
	in.AppcastURL = strings.TrimSpace(in.AppcastURL)
	in.SparkleEDSignature = strings.TrimSpace(in.SparkleEDSignature)
	in.SHA256 = strings.TrimSpace(in.SHA256)
	in.MinOSVersion = strings.TrimSpace(in.MinOSVersion)
	in.MinSupportedVersion = strings.TrimSpace(in.MinSupportedVersion)
	if in.Arch == "" {
		in.Arch = dom.ArchUniversal
	}
	if in.Channel == "" {
		in.Channel = dom.ChannelStable
	}
	if in.Status == "" {
		in.Status = dom.StatusDraft
	}
	if in.Title == "" {
		in.Title = in.Version
	}
	if !dom.ValidPlatform(in.Platform) {
		return in, dom.ErrInvalidPlatform
	}
	if !dom.ValidArch(in.Arch) {
		return in, dom.ErrInvalidArch
	}
	if !dom.ValidChannel(in.Channel) {
		return in, dom.ErrInvalidChannel
	}
	if !dom.ValidStatus(in.Status) {
		return in, dom.ErrInvalidStatus
	}
	if in.Version == "" {
		return in, dom.ErrMissingVersion
	}
	if in.BuildNumber == "" {
		return in, dom.ErrMissingBuild
	}
	if in.Status == dom.StatusPublished && in.Platform != dom.PlatformIOS && in.DownloadURL == "" {
		return in, dom.ErrMissingDownload
	}
	if in.FileSizeBytes < 0 {
		in.FileSizeBytes = 0
	}
	return in, nil
}

func newest(items []dom.Version) *dom.Version {
	var selected *dom.Version
	for i := range items {
		item := items[i]
		if selected == nil || CompareRelease(item.Version, item.BuildNumber, selected.Version, selected.BuildNumber) > 0 {
			selected = &item
		}
	}
	return selected
}

// CompareRelease compares left against right, prioritizing numeric build numbers.
func CompareRelease(leftVersion, leftBuild, rightVersion, rightBuild string) int {
	if left, errLeft := strconv.ParseInt(strings.TrimSpace(leftBuild), 10, 64); errLeft == nil {
		if right, errRight := strconv.ParseInt(strings.TrimSpace(rightBuild), 10, 64); errRight == nil && left != right {
			if left > right {
				return 1
			}
			return -1
		}
	}
	return compareVersions(leftVersion, rightVersion)
}

func compareVersions(left, right string) int {
	lparts := versionParts(left)
	rparts := versionParts(right)
	n := len(lparts)
	if len(rparts) > n {
		n = len(rparts)
	}
	for i := 0; i < n; i++ {
		var l, r int
		if i < len(lparts) {
			l = lparts[i]
		}
		if i < len(rparts) {
			r = rparts[i]
		}
		if l > r {
			return 1
		}
		if l < r {
			return -1
		}
	}
	return 0
}

func versionParts(v string) []int {
	fields := strings.FieldsFunc(v, func(r rune) bool { return r < '0' || r > '9' })
	out := make([]int, 0, len(fields))
	for _, field := range fields {
		if field == "" {
			continue
		}
		n, err := strconv.Atoi(field)
		if err != nil {
			n = 0
		}
		out = append(out, n)
	}
	return out
}

func normalize(v string) string {
	return strings.ToLower(strings.TrimSpace(v))
}
