package localcodingcatalog

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

// Admin periodically checks the npm mirror and official desktop
// release sources, copies verified packages into the object store and publishes
// the current version for all tenants.

const (
	// DefaultAutoSyncInterval / DefaultAutoSyncMinAge are the config defaults.
	DefaultAutoSyncInterval = time.Hour
	DefaultAutoSyncMinAge   = 48 * time.Hour

	AutoSyncRecorded         = "recorded"
	AutoSyncPublishedCurrent = "published_current"
	AutoSyncSkippedExists    = "skipped_exists"
	AutoSyncSkippedNotNewer  = "skipped_not_newer"
	AutoSyncSkippedTooNew    = "skipped_too_new"
	AutoSyncFailed           = "failed"
	AutoSyncSkippedDisabled  = "skipped_disabled"

	// A desktop round can include several large archives.
	autoSyncRoundTimeout = 12 * time.Hour
	// autoSyncKeyRows is more rows than one (target, platform, arch) ever has.
	autoSyncKeyRows = 500
)

// AutoSyncConfig turns the auto sync on (Deps.AutoSync); Admin only.
type AutoSyncConfig struct {
	// Registry is the npm mirror origin (https); empty = DefaultAutoSyncRegistry.
	Registry string
	// MinAge is how long a version of a track that follows "latest" must
	// have been published before it is recorded; <= 0 = DefaultAutoSyncMinAge.
	MinAge time.Duration
	// NPMKeys overrides the npm registry signing keys (tests).
	NPMKeys map[string]string
	// DownloadHosts overrides where tarball downloads may redirect to.
	DownloadHosts []string
	// desktopSync isolates CLI-only tests from official desktop HTTP sources.
	desktopSync func(context.Context) []AutoSyncResult
}

// minAutoSyncInterval keeps a mistyped interval from hammering the mirror.
const minAutoSyncInterval = 10 * time.Minute

// ParseAutoSyncSettings turns the configuration strings
// (config.LocalCodingConfig.AutoSync*) into a config and the round interval.
func ParseAutoSyncSettings(interval, minAge, registry string) (*AutoSyncConfig, time.Duration, error) {
	cfg := &AutoSyncConfig{Registry: strings.TrimSpace(registry), MinAge: DefaultAutoSyncMinAge}
	every := DefaultAutoSyncInterval
	if interval = strings.TrimSpace(interval); interval != "" {
		parsed, err := time.ParseDuration(interval)
		if err != nil || parsed < minAutoSyncInterval {
			return nil, 0, fmt.Errorf("autosync_interval: %q must be a duration of at least %s", interval, minAutoSyncInterval)
		}
		every = parsed
	}
	if minAge = strings.TrimSpace(minAge); minAge != "" {
		parsed, err := time.ParseDuration(minAge)
		if err != nil || parsed <= 0 {
			return nil, 0, fmt.Errorf("autosync_min_age: %q must be a positive duration", minAge)
		}
		cfg.MinAge = parsed
	}
	if cfg.Registry == "" {
		cfg.Registry = DefaultAutoSyncRegistry
	}
	if _, err := newNPMSource(&http.Client{}, cfg.Registry, nil, nil); err != nil {
		return nil, 0, fmt.Errorf("autosync_registry: %w", err)
	}
	return cfg, every, nil
}

// AutoSyncResult is what one round did for one (target, platform, arch).
type AutoSyncResult struct {
	TargetID string `json:"target_id"`
	Platform string `json:"platform"`
	Arch     string `json:"arch"`
	Version  string `json:"version"`
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail,omitempty"`
}

type AutoSyncReport struct {
	StartedAt  time.Time        `json:"started_at"`
	FinishedAt time.Time        `json:"finished_at"`
	Results    []AutoSyncResult `json:"results"`
}

// AutoSyncStatus is what the Admin page shows next to "check now". Running
// and LastReport are those of this process; another replica's round only
// shows through the rows it records.
type AutoSyncStatus struct {
	Enabled          bool            `json:"enabled"`
	Running          bool            `json:"running"`
	LastReport       *AutoSyncReport `json:"last_report,omitempty"`
	DesktopPlatforms []string        `json:"desktop_platforms"`
}

// autoSyncTrack is one tool followed on npm.
type autoSyncTrack struct {
	targetID string
	// pkg carries the dist-tag that names the version to follow.
	pkg string
	tag string
	// soak: the tag moves with every release ("latest"), so a version must
	// have been out for MinAge; a publisher-curated tag ("stable") needs none.
	soak      bool
	platforms []autoSyncPlatform
}

type autoSyncPlatform struct {
	platform string
	arch     string
	// pkg / version name the package document of this platform's tarball.
	pkg     func(version string) (name, pkgVersion string)
	layout  string
	member  string
	program string // the executable inside the tarball that binary_sha256 covers
}

// autoSyncTracks mirrors the Bridge's built-in manifest: Codex ships every
// platform as a suffixed version of @openai/codex and installs as a package
// tree; Claude ships one package per platform carrying the bare executable.
var autoSyncTracks = []autoSyncTrack{
	{
		targetID: dom.TargetCodexCLI, pkg: "@openai/codex", tag: "latest", soak: true,
		platforms: []autoSyncPlatform{
			codexPlatform(dom.PlatformMacOS, dom.ArchArm64, "darwin-arm64", "aarch64-apple-darwin", "codex"),
			codexPlatform(dom.PlatformMacOS, dom.ArchX64, "darwin-x64", "x86_64-apple-darwin", "codex"),
			codexPlatform(dom.PlatformWindows, dom.ArchX64, "win32-x64", "x86_64-pc-windows-msvc", "codex.exe"),
		},
	},
	{
		targetID: dom.TargetClaudeCLI, pkg: "@anthropic-ai/claude-code", tag: "stable",
		platforms: []autoSyncPlatform{
			claudePlatform(dom.PlatformMacOS, dom.ArchArm64, "darwin-arm64", "claude"),
			claudePlatform(dom.PlatformMacOS, dom.ArchX64, "darwin-x64", "claude"),
			claudePlatform(dom.PlatformWindows, dom.ArchX64, "win32-x64", "claude.exe"),
		},
	},
}

func codexPlatform(platform, arch, suffix, triple, executable string) autoSyncPlatform {
	member := "package/vendor/" + triple
	return autoSyncPlatform{
		platform: platform, arch: arch, layout: dom.LayoutTarballTree, member: member,
		program: member + "/bin/" + executable,
		pkg:     func(version string) (string, string) { return "@openai/codex", version + "-" + suffix },
	}
}

func claudePlatform(platform, arch, suffix, executable string) autoSyncPlatform {
	member := "package/" + executable
	return autoSyncPlatform{
		platform: platform, arch: arch, layout: dom.LayoutTarballMember, member: member, program: member,
		pkg: func(version string) (string, string) { return "@anthropic-ai/claude-code-" + suffix, version },
	}
}

// releaseVersionPattern refuses prereleases: a tag pointed at an alpha must
// not reach even the canary tenants unattended.
var releaseVersionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// AutoSync implements Service: one round over every track and platform. A
// failure of one platform is reported in its result and does not stop the rest.
func (s *impl) AutoSync(ctx context.Context) (*AutoSyncReport, error) {
	return s.autoSyncRun(ctx, "scheduled")
}

func (s *impl) autoSyncRun(ctx context.Context, trigger string) (report *AutoSyncReport, runErr error) {
	ctx = autoSyncLogContext(ctx, trigger)
	s.autoSyncLog(ctx, "info", "round_started")
	defer func() { s.autoSyncLogRound(ctx, report, runErr) }()
	if s.autoSync == nil {
		return nil, dom.ErrAutoSyncDisabled
	}
	release, acquired, err := s.repo.TryAutoSyncLock(ctx)
	if err != nil {
		return nil, err
	}
	if !acquired {
		return nil, dom.ErrAutoSyncRunning
	}
	defer release()
	s.autoSyncMu.Lock()
	s.autoSyncRunning = true
	s.autoSyncMu.Unlock()
	defer func() {
		s.autoSyncMu.Lock()
		s.autoSyncRunning = false
		if report != nil {
			s.autoSyncLast = report
		}
		s.autoSyncMu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(ctx, autoSyncRoundTimeout)
	defer cancel()

	registry := s.autoSync.Registry
	if strings.TrimSpace(registry) == "" {
		registry = DefaultAutoSyncRegistry
	}
	keys := s.autoSync.NPMKeys
	if keys == nil {
		keys = DefaultNPMRegistryKeys()
	}
	hosts := s.autoSync.DownloadHosts
	if hosts == nil {
		hosts = defaultAutoSyncDownloadHosts
	}
	s.autoSyncStage(ctx, "configuration")
	source, err := newNPMSource(s.httpClient, registry, hosts, keys)
	if err != nil {
		return nil, err
	}
	report = &AutoSyncReport{StartedAt: s.now()}
	for _, track := range autoSyncTracks {
		discoverCtx := autoSyncItemContext(ctx, track.targetID, "", "", "")
		s.autoSyncStage(discoverCtx, "discover")
		version, published, err := source.tagVersion(discoverCtx, track.pkg, track.tag)
		if err == nil && !releaseVersionPattern.MatchString(version) {
			err = fmt.Errorf("标签 %s 指向的版本号 %q 不是正式版", track.tag, version)
		}
		for _, platform := range track.platforms {
			itemCtx := autoSyncItemContext(ctx, track.targetID, platform.platform, platform.arch, version)
			s.autoSyncStage(itemCtx, "discover")
			result := AutoSyncResult{TargetID: track.targetID, Platform: platform.platform, Arch: platform.arch, Version: version}
			switch {
			case err != nil:
				result.Outcome, result.Detail = AutoSyncFailed, err.Error()
			default:
				result.Outcome, result.Detail = s.autoSyncPlatform(itemCtx, source, track, platform, version, published)
			}
			result.Detail = safeAutoSyncDetail(result.Detail)
			s.autoSyncLogResult(itemCtx, result)
			report.Results = append(report.Results, result)
		}
	}
	desktopSync := s.autoSyncDesktops
	if s.autoSync.desktopSync != nil {
		desktopSync = s.autoSync.desktopSync
	}
	report.Results = append(report.Results, desktopSync(ctx)...)
	report.FinishedAt = s.now()
	return report, nil
}

// StartAutoSync implements Service. The round is detached from the request
// that asked for it; two starts at once end with one round (the second finds
// the lock taken).
func (s *impl) StartAutoSync(ctx context.Context) error {
	if s.autoSync == nil {
		return dom.ErrAutoSyncDisabled
	}
	s.autoSyncMu.Lock()
	running := s.autoSyncRunning
	s.autoSyncMu.Unlock()
	if running {
		return dom.ErrAutoSyncRunning
	}
	go func() { _, _ = s.autoSyncRun(context.WithoutCancel(ctx), "manual") }()
	return nil
}

// AutoSyncStatus implements Service.
func (s *impl) AutoSyncStatus() AutoSyncStatus {
	s.autoSyncMu.Lock()
	defer s.autoSyncMu.Unlock()
	platforms := []string{}
	if s.autoSync != nil {
		platforms = []string{dom.PlatformMacOS, dom.PlatformWindows}
	}
	return AutoSyncStatus{Enabled: s.autoSync != nil, Running: s.autoSyncRunning, LastReport: s.autoSyncLast, DesktopPlatforms: platforms}
}

func (s *impl) autoSyncPlatform(ctx context.Context, source *npmSource, track autoSyncTrack, platform autoSyncPlatform, version string, published time.Time) (string, string) {
	s.autoSyncStage(ctx, "catalog")
	retry, recorded, err := s.autoSyncExisting(ctx, track.targetID, platform.platform, platform.arch, version)
	if err != nil {
		return AutoSyncFailed, "查询目录失败：" + err.Error()
	}
	if recorded && retry == nil {
		return AutoSyncSkippedExists, ""
	}
	rows, _, err := s.repo.List(ctx, dom.Filter{TargetID: track.targetID, Platform: platform.platform, Arch: platform.arch, Limit: autoSyncKeyRows})
	if err != nil {
		return AutoSyncFailed, "查询目录失败：" + err.Error()
	}
	var current *dom.Version
	var stale []dom.Version
	for i := range rows {
		row := rows[i]
		if row.TargetID != track.targetID || row.Platform != platform.platform || row.Arch != platform.arch {
			continue
		}
		if row.Status == dom.StatusCurrent {
			current = &rows[i]
		}
		if row.AutoSynced && (row.Status == dom.StatusDraft || row.Status == dom.StatusCanary) {
			stale = append(stale, row)
		}
	}
	if current != nil && compareReleaseVersions(version, current.Version) <= 0 {
		return AutoSyncSkippedNotNewer, "当前全量版本 " + current.Version
	}
	if track.soak {
		minAge := s.autoSync.MinAge
		if minAge <= 0 {
			minAge = DefaultAutoSyncMinAge
		}
		if published.IsZero() {
			return AutoSyncSkippedTooNew, "镜像站没有给出发布时间，无法确认已发布满 " + minAge.String()
		}
		if age := s.now().Sub(published); age < minAge {
			return AutoSyncSkippedTooNew, fmt.Sprintf("发布 %s，未满 %s", age.Round(time.Hour), minAge)
		}
	}

	if retry != nil && retry.IsObjectStorePackage() {
		return s.autoSyncPublish(ctx, retry, stale)
	}

	name, pkgVersion := platform.pkg(version)
	s.autoSyncStage(ctx, "package_metadata")
	pkg, err := source.packageVersion(ctx, name, pkgVersion)
	if err != nil {
		return AutoSyncFailed, err.Error()
	}
	s.autoSyncLog(ctx, "info", "source_discovered", "source_host", hostOf(pkg.tarball), "expected_bytes", pkg.size)
	s.autoSyncStage(ctx, "download")
	tarball, err := source.download(ctx, pkg)
	if err != nil {
		return AutoSyncFailed, err.Error()
	}
	defer tarball.Close()
	s.autoSyncLog(ctx, "info", "stage_completed", "bytes", tarball.size)
	s.autoSyncStage(ctx, "verify")
	binarySHA, err := tarball.memberSHA256(platform.program)
	if err != nil {
		return AutoSyncFailed, err.Error()
	}

	input := dom.UpsertInput{
		TargetID: track.targetID, Platform: platform.platform, Arch: platform.arch, Version: version,
		Layout: platform.layout, Member: platform.member, BinarySHA256: binarySHA,
		ExternalURL: pkg.tarball, FileSizeBytes: tarball.size, SHA256: tarball.sha256,
		ContractCheckRef: dom.AutoSyncRefPrefix + "npm " + s.now().Format("2006-01-02") +
			" · npm 官方签名与完整性已核；未做网关合同检查；自动全量发布",
		ReleaseNotes: fmt.Sprintf("自动同步：%s 的 %s 标签", track.pkg, track.tag),
	}
	if current != nil {
		input.MinBridgeVersion, input.MinAppVersion, input.ProfileVersion = current.MinBridgeVersion, current.MinAppVersion, current.ProfileVersion
	}
	s.autoSyncStage(ctx, "record")
	item := retry
	if item == nil {
		item, err = s.Create(ctx, input)
		if err != nil {
			return AutoSyncFailed, "录入失败：" + err.Error()
		}
		s.auditEvent(ctx, 0, "local_coding.version_autosynced", item, map[string]any{
			"npm_package": name, "npm_version": pkgVersion, "tag": track.tag,
		})
	} else if item.SHA256 != input.SHA256 || item.FileSizeBytes != input.FileSizeBytes || item.BinarySHA256 != input.BinarySHA256 || item.Layout != input.Layout || item.Member != input.Member {
		return AutoSyncFailed, "同版本内容或布局已变化，保留原草稿，请人工核查"
	}

	if s.packages == nil {
		return AutoSyncFailed, "对象存储未配置，保持草稿"
	}
	if !item.IsObjectStorePackage() {
		if detail := s.autoSyncStore(ctx, item, tarball); detail != "" {
			return AutoSyncFailed, "已录入为草稿，" + detail + "；下一轮重试"
		}
	}
	return s.autoSyncPublish(ctx, item, stale)
}

// Auto-owned drafts and canaries can advance to current. Deleted, manually
// owned, current, previous and withdrawn versions remain excluded.
func (s *impl) autoSyncExisting(ctx context.Context, target, platform, arch, version string) (*dom.Version, bool, error) {
	recorded, err := s.repo.VersionEverRecorded(ctx, target, platform, arch, version)
	if err != nil || !recorded {
		return nil, recorded, err
	}
	rows, _, err := s.repo.List(ctx, dom.Filter{TargetID: target, Platform: platform, Arch: arch, Limit: autoSyncKeyRows})
	if err != nil {
		return nil, true, err
	}
	for _, row := range rows {
		if row.TargetID == target && row.Platform == platform && row.Arch == arch && row.Version == version &&
			(row.Status == dom.StatusDraft || row.Status == dom.StatusCanary) && dom.IsAutoSyncRef(row.ContractCheckRef) {
			return &row, true, nil
		}
	}
	return nil, true, nil
}

func (s *impl) autoSyncPublish(ctx context.Context, item *dom.Version, stale []dom.Version) (string, string) {
	s.autoSyncStage(ctx, "publish")
	fresh, err := s.repo.GetByUUID(ctx, item.UUID)
	if err != nil {
		return AutoSyncFailed, "读取待发布版本失败：" + err.Error()
	}
	if (fresh.Status != dom.StatusDraft && fresh.Status != dom.StatusCanary) || !dom.IsAutoSyncRef(fresh.ContractCheckRef) {
		return AutoSyncSkippedExists, "版本已被人工处理"
	}
	if !fresh.IsObjectStorePackage() {
		return AutoSyncFailed, "安装包尚未存入对象存储，保持草稿"
	}
	// Recheck the visible current after a potentially long download.
	rows, _, err := s.repo.List(ctx, dom.Filter{TargetID: fresh.TargetID, Platform: fresh.Platform, Limit: autoSyncKeyRows})
	if err != nil {
		return AutoSyncFailed, "发布前查询当前版本失败：" + err.Error()
	}
	for _, row := range rows {
		if row.TargetID == fresh.TargetID && row.Platform == fresh.Platform && (row.Arch == fresh.Arch || row.Arch == dom.ArchUniversal) && row.Status == dom.StatusCurrent && compareReleaseVersions(fresh.Version, row.Version) <= 0 {
			return AutoSyncSkippedNotNewer, "当前全量版本 " + row.Version
		}
	}
	if _, err := s.Publish(ctx, item.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		return AutoSyncFailed, "全量发布失败，原当前版本保留，下一轮重试：" + err.Error()
	}
	s.autoSyncLog(ctx, "info", "stage_completed", "package_uuid", item.UUID)
	s.autoSyncStage(ctx, "cleanup")
	// Cleanup only after the new current has committed successfully.

	for _, row := range stale {
		if row.UUID == item.UUID {
			continue
		}
		if detail := s.autoSyncRetire(ctx, row); detail != "" {
			return AutoSyncPublishedCurrent, "已全量发布，旧自动版本清理失败：" + detail
		}
	}
	return AutoSyncPublishedCurrent, ""
}

// autoSyncStore writes the very bytes that were just verified into the
// object store and points the row at them; "" means done.
func (s *impl) autoSyncStore(ctx context.Context, item *dom.Version, tarball *downloaded) string {
	s.autoSyncStage(ctx, "upload")
	fail := func(message string) string {
		message = safeAutoSyncDetail(message)
		if err := s.repo.SetMirrorState(context.WithoutCancel(ctx), item.UUID, dom.MirrorStateFailed, message); err != nil {
			s.autoSyncLog(ctx, "error", "mirror_state_failed", "package_uuid", item.UUID, "detail", safeAutoSyncDetail(err.Error()))
		}
		return message
	}
	if _, err := tarball.file.Seek(0, 0); err != nil {
		return fail("临时文件读取失败：" + err.Error())
	}
	contentType := "application/gzip"
	if item.IsDesktop() {
		contentType = "application/octet-stream"
	}
	uploaded, err := s.packages.Upload(ctx, item.UUID, mirrorFilename(item.StorageURI), tarball.file, tarball.size, contentType)
	if err != nil {
		return fail("写入对象存储失败：" + err.Error())
	}
	if uploaded.SHA256 != tarball.sha256 {
		return fail(fmt.Sprintf("写入对象存储后哈希 %s… 与下载的 %s… 不符", short(uploaded.SHA256), short(tarball.sha256)))
	}
	replaced, err := s.repo.ReplaceStorage(ctx, item.UUID, uploaded.StorageURI, tarball.size, tarball.sha256, 0)
	if err != nil {
		return fail("更新记录失败：" + err.Error())
	}
	s.auditEvent(ctx, 0, "local_coding.package_mirrored", replaced, map[string]any{"automatic": true})
	s.autoSyncLog(ctx, "info", "stage_completed", "bytes", tarball.size, "package_uuid", item.UUID)
	return ""
}

// autoSyncRetire removes an auto-synced row that never became current.
func (s *impl) autoSyncRetire(ctx context.Context, row dom.Version) string {
	fresh, err := s.repo.GetByUUID(ctx, row.UUID)
	if err != nil {
		return "读取旧自动版本失败：" + err.Error()
	}
	if !dom.IsAutoSyncRef(fresh.ContractCheckRef) || (fresh.Status != dom.StatusDraft && fresh.Status != dom.StatusCanary) {
		return ""
	}
	row = *fresh
	if row.Status == dom.StatusCanary {
		if _, err := s.Deprecate(ctx, row.UUID, 0); err != nil {
			return "下线旧的自动版本 " + row.Version + " 失败：" + err.Error()
		}
	}
	if err := s.Delete(ctx, row.UUID, 0); err != nil {
		return "删除旧的自动版本 " + row.Version + " 失败：" + err.Error()
	}
	// Delete itself is not audited (an operator's delete never was); a row the
	// system removes on its own must leave a trace.
	s.auditEvent(ctx, 0, "local_coding.version_autosync_retired", &row, nil)
	return ""
}

// compareReleaseVersions orders dotted numeric versions; a version it cannot
// read sorts lowest, so an unreadable current never blocks a readable newer one.
func compareReleaseVersions(a, b string) int {
	left, leftOK := releaseParts(a)
	right, rightOK := releaseParts(b)
	switch {
	case !leftOK && !rightOK:
		return 0
	case !leftOK:
		return -1
	case !rightOK:
		return 1
	}
	for i := 0; i < len(left) || i < len(right); i++ {
		var l, r int
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		if l != r {
			if l < r {
				return -1
			}
			return 1
		}
	}
	return 0
}

func releaseParts(version string) ([]int, bool) {
	fields := strings.Split(strings.TrimSpace(version), ".")
	parts := make([]int, 0, len(fields))
	for _, field := range fields {
		n, err := strconv.Atoi(field)
		if err != nil || n < 0 {
			return nil, false
		}
		parts = append(parts, n)
	}
	return parts, len(parts) > 0
}
