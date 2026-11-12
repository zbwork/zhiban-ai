package localcodingcatalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

func validateDesktopPackage(p *DesktopPackage, target, platform, arch string) error {
	if p == nil || p.TargetID != target || p.Platform != platform || p.Arch != arch || !releaseVersionPattern.MatchString(p.Version) || p.FileSizeBytes < 0 || p.FileSizeBytes > desktopMaxBytes || !desktopSourceAllowed(target, p.SourceURL) {
		return errors.New("桌面包版本、大小或官方来源无效")
	}
	if p.Platform == dom.PlatformMacOS {
		bundle, team := codexDesktopBundleID, codexDesktopTeamID
		if target == dom.TargetClaudeDesktop {
			bundle, team = claudeDesktopBundleID, claudeDesktopTeamID
		}
		if (arch != dom.ArchArm64 && arch != dom.ArchX64) || p.Layout != dom.LayoutAppBundleZip || !strings.HasSuffix(p.SourceURL, ".zip") || p.BundleIdentifier != bundle || p.TeamIdentifier != team {
			return errors.New("Mac 桌面包身份或格式无效")
		}
	} else if platform != dom.PlatformWindows || arch != dom.ArchX64 || p.Layout != dom.LayoutMSIX || !strings.HasSuffix(p.SourceURL, ".msix") {
		return errors.New("Windows 桌面包平台或格式无效")
	}
	return nil
}

func (s *impl) autoSyncDesktops(ctx context.Context) []AutoSyncResult {
	results := make([]AutoSyncResult, 0, len(desktopTracks))
	cache := map[string]*downloaded{}
	defer func() {
		for _, file := range cache {
			file.Close()
		}
	}()
	for _, track := range desktopTracks {
		result := AutoSyncResult{TargetID: track.target, Platform: track.platform, Arch: track.arch}
		itemCtx, cancel := context.WithTimeout(autoSyncItemContext(ctx, track.target, track.platform, track.arch, ""), 3*time.Hour)
		s.autoSyncStage(itemCtx, "discover")
		probeCtx, probeCancel := context.WithTimeout(itemCtx, 2*time.Minute)
		p, err := s.discoverDesktop(probeCtx, track)
		probeCancel()
		if err == nil {
			err = validateDesktopPackage(p, track.target, track.platform, track.arch)
		}
		if err != nil {
			result.Outcome, result.Detail = AutoSyncFailed, err.Error()
		} else {
			result.Version = p.Version
			itemCtx.Value(autoSyncLogKey{}).(*autoSyncLogState).version = p.Version
			s.autoSyncLog(itemCtx, "info", "source_discovered", "source_host", hostOf(p.SourceURL), "expected_bytes", p.FileSizeBytes)
			result.Outcome, result.Detail = s.autoSyncDesktopPackage(itemCtx, p, cache)
		}
		result.Detail = safeAutoSyncDetail(result.Detail)
		s.autoSyncLogResult(itemCtx, result)
		cancel()
		results = append(results, result)
	}
	return results
}

func (s *impl) autoSyncDesktopPackage(ctx context.Context, p *DesktopPackage, cache map[string]*downloaded) (string, string) {
	s.autoSyncStage(ctx, "catalog")
	item, recorded, err := s.autoSyncExisting(ctx, p.TargetID, p.Platform, p.Arch, p.Version)
	if err != nil {
		return AutoSyncFailed, "查询目录失败：" + err.Error()
	}
	if recorded && item == nil {
		return AutoSyncSkippedExists, ""
	}
	rows, _, err := s.repo.List(ctx, dom.Filter{TargetID: p.TargetID, Platform: p.Platform, Limit: autoSyncKeyRows})
	if err != nil {
		return AutoSyncFailed, "查询目录失败：" + err.Error()
	}
	input := dom.UpsertInput{TargetID: p.TargetID, Platform: p.Platform, Arch: p.Arch, Version: p.Version, Layout: p.Layout, ExternalURL: p.SourceURL, BundleIdentifier: p.BundleIdentifier, TeamIdentifier: p.TeamIdentifier,
		ContractCheckRef: dom.AutoSyncRefPrefix + "desktop " + s.now().Format("2006-01-02") + " · 官方来源、包身份/架构/版本及 SHA-256 已核；发行者签名由客户端安装时校验；自动全量发布",
		ReleaseNotes:     "自动同步官方桌面安装包"}
	var stale []dom.Version
	hasExactCurrent := false
	for _, row := range rows {
		if row.TargetID != p.TargetID || row.Platform != p.Platform || (row.Arch != p.Arch && row.Arch != dom.ArchUniversal) {
			continue
		}
		if row.Status == dom.StatusCurrent {
			if compareReleaseVersions(p.Version, row.Version) <= 0 {
				return AutoSyncSkippedNotNewer, "当前全量版本 " + row.Version
			}
			if row.Arch == p.Arch || !hasExactCurrent {
				input.MinBridgeVersion, input.MinAppVersion, input.ProfileVersion = row.MinBridgeVersion, row.MinAppVersion, row.ProfileVersion
			}
			if row.Arch == p.Arch {
				hasExactCurrent = true
			}
		}
		if row.Arch == p.Arch && dom.IsAutoSyncRef(row.ContractCheckRef) && (row.Status == dom.StatusDraft || row.Status == dom.StatusCanary) {
			stale = append(stale, row)
		}
	}
	if s.packages == nil {
		return AutoSyncFailed, "对象存储未配置，不发布桌面版本"
	}
	if item != nil && item.IsObjectStorePackage() {
		return s.autoSyncPublish(ctx, item, stale)
	}
	key := p.SourceURL + "|" + p.Version
	payload := cache[key]
	if payload == nil {
		s.autoSyncStage(ctx, "download")
		payload, err = s.downloadDesktop(ctx, p)
		if err != nil {
			if item != nil {
				if stateErr := s.repo.SetMirrorState(context.WithoutCancel(ctx), item.UUID, dom.MirrorStateFailed, safeAutoSyncDetail(err.Error())); stateErr != nil {
					s.autoSyncLog(ctx, "error", "mirror_state_failed", "package_uuid", item.UUID, "detail", safeAutoSyncDetail(stateErr.Error()))
				}
			}
			return AutoSyncFailed, err.Error() + "；下一轮重试"
		}
		s.autoSyncLog(ctx, "info", "stage_completed", "bytes", payload.size)
		if cache == nil {
			defer payload.Close()
		} else {
			cache[key] = payload
		}
	}
	s.autoSyncStage(ctx, "verify")
	if p.FileSizeBytes > 0 && payload.size != p.FileSizeBytes {
		return AutoSyncFailed, "下载包大小与官方清单不匹配"
	}
	if err := inspectDesktopArchive(payload, p); err != nil {
		return AutoSyncFailed, err.Error()
	}
	p.SHA256, p.FileSizeBytes = payload.sha256, payload.size
	input.SHA256, input.FileSizeBytes = p.SHA256, p.FileSizeBytes
	if item != nil && (item.SHA256 != p.SHA256 || item.FileSizeBytes != p.FileSizeBytes || item.Layout != p.Layout) {
		return AutoSyncFailed, "同版本内容或布局已变化，保留原草稿，请人工核查"
	}
	s.autoSyncStage(ctx, "record")
	if item == nil {
		item, err = s.Create(ctx, input)
		if err != nil {
			return AutoSyncFailed, "录入失败：" + err.Error()
		}
		s.auditEvent(ctx, 0, "local_coding.version_autosynced", item, map[string]any{"native_signature_verified": false, "verification": "official_source_and_package_metadata", "publisher_signature_check": "client_install", "source_host": hostOf(p.SourceURL)})
	} else {
		fresh, err := s.repo.GetByUUID(ctx, item.UUID)
		if err != nil {
			return AutoSyncFailed, "读取待上传草稿失败：" + err.Error()
		}
		if fresh.Status != dom.StatusDraft || !dom.IsAutoSyncRef(fresh.ContractCheckRef) {
			return AutoSyncSkippedExists, "版本已被人工处理"
		}
		if fresh.SHA256 != p.SHA256 || fresh.FileSizeBytes != p.FileSizeBytes || fresh.Layout != p.Layout {
			return AutoSyncFailed, "下载期间草稿包信息已变化，请人工核查"
		}
		item = fresh
	}
	if detail := s.autoSyncStore(ctx, item, payload); detail != "" {
		return AutoSyncFailed, detail + "；草稿保留，下一轮重试"
	}
	return s.autoSyncPublish(ctx, item, stale)
}

func (s *impl) downloadDesktop(ctx context.Context, p *DesktopPackage) (*downloaded, error) {
	response, err := s.desktopRequest(ctx, p.TargetID, p.SourceURL, desktopConditions(p))
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("桌面包下载 HTTP %d", response.StatusCode)
	}
	if p.ETag != "" && response.Header.Get("ETag") != "" && p.ETag != response.Header.Get("ETag") {
		return nil, errors.New("桌面包 ETag 已变化，请重新检查版本")
	}
	if p.LastModified != "" && response.Header.Get("Last-Modified") != "" && p.LastModified != response.Header.Get("Last-Modified") {
		return nil, errors.New("桌面包更新时间已变化，请重新检查版本")
	}
	if response.ContentLength > desktopMaxBytes || (p.FileSizeBytes > 0 && response.ContentLength >= 0 && response.ContentLength != p.FileSizeBytes) {
		return nil, errors.New("桌面包大小与官方清单不符或超过限制")
	}
	f, err := os.CreateTemp("", "local-coding-desktop-*")
	if err != nil {
		return nil, err
	}
	d := &downloaded{file: f}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(response.Body, desktopMaxBytes+1))
	if err != nil || n == 0 || n > desktopMaxBytes || (p.FileSizeBytes > 0 && n != p.FileSizeBytes) || (response.ContentLength >= 0 && n != response.ContentLength) {
		d.Close()
		if err != nil {
			return nil, fmt.Errorf("桌面包下载中断（已读 %d 字节）：%s", n, safeAutoSyncDetail(err.Error()))
		}
		return nil, fmt.Errorf("桌面包下载不完整或超过大小限制：actual=%d expected=%d content_length=%d", n, p.FileSizeBytes, response.ContentLength)
	}
	d.size, d.sha256 = n, hex.EncodeToString(h.Sum(nil))
	return d, nil
}
