package localcodingcatalog

import (
	"archive/zip"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

const desktopMaxBytes int64 = 4 << 30
const desktopMetadataMax int64 = 4 << 20
const codexDesktopBase = "https://persistent.oaistatic.com/codex-app-prod/"
const claudeWindowsLatest = "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"

// DesktopPackage contains source and archive metadata, NOT a signature attestation.
type DesktopPackage struct {
	TargetID, Platform, Arch, Version, Layout, SourceURL string
	FileSizeBytes                                        int64
	SHA256, BundleIdentifier, TeamIdentifier             string
	ETag, LastModified                                   string
}

type desktopTrack struct{ target, platform, arch string }

var desktopTracks = []desktopTrack{
	{dom.TargetCodexDesktop, dom.PlatformMacOS, dom.ArchArm64},
	{dom.TargetCodexDesktop, dom.PlatformMacOS, dom.ArchX64},
	{dom.TargetClaudeDesktop, dom.PlatformMacOS, dom.ArchArm64},
	{dom.TargetClaudeDesktop, dom.PlatformMacOS, dom.ArchX64},
	{dom.TargetCodexDesktop, dom.PlatformWindows, dom.ArchX64},
	{dom.TargetClaudeDesktop, dom.PlatformWindows, dom.ArchX64},
}

func desktopSourceAllowed(target, raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || u.RawQuery != "" || u.Fragment != "" || strings.ContainsAny(u.Path, "\\\x00") || strings.Contains(u.Path, "..") {
		return false
	}
	if target == dom.TargetCodexDesktop {
		return u.Host == "persistent.oaistatic.com" && strings.HasPrefix(u.Path, "/codex-app-prod/")
	}
	return target == dom.TargetClaudeDesktop && u.Host == "downloads.claude.ai" && strings.HasPrefix(u.Path, "/releases/")
}

func (s *impl) desktopRequest(ctx context.Context, target, raw string, headers http.Header) (*http.Response, error) {
	allowed := func(raw string) bool {
		return desktopSourceAllowed(target, raw) || (target == dom.TargetClaudeDesktop && raw == claudeWindowsLatest)
	}
	if !allowed(raw) {
		return nil, errors.New("桌面安装包来源不在官方白名单内")
	}
	client := *s.httpClient
	client.CheckRedirect = func(r *http.Request, via []*http.Request) error {
		if len(via) >= 5 || !allowed(r.URL.String()) {
			return errors.New("桌面下载跳转不在官方来源内")
		}
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	req.Header = headers.Clone()
	if req.Header == nil {
		req.Header = make(http.Header)
	}
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("User-Agent", "zhiban-desktop-sync/2")
	response, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("官方桌面包请求失败：%s", safeAutoSyncDetail(err.Error()))
	}
	if response.Header.Get("Content-Encoding") != "" && response.Header.Get("Content-Encoding") != "identity" {
		response.Body.Close()
		return nil, errors.New("官方来源返回了不支持的内容编码")
	}
	return response, nil
}

func (s *impl) desktopMetadata(ctx context.Context, target, raw string) ([]byte, error) {
	r, err := s.desktopRequest(ctx, target, raw, nil)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("官方更新清单 HTTP %d", r.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, desktopMetadataMax+1))
	if err != nil || int64(len(b)) > desktopMetadataMax {
		return nil, errors.New("官方更新清单读取失败或过大")
	}
	return b, nil
}

func (s *impl) discoverDesktop(ctx context.Context, t desktopTrack) (*DesktopPackage, error) {
	p := &DesktopPackage{TargetID: t.target, Platform: t.platform, Arch: t.arch}
	if t.platform == dom.PlatformWindows {
		p.Layout = dom.LayoutMSIX
		p.SourceURL = codexDesktopBase + "ChatGPT-x64.msix"
		if t.target == dom.TargetClaudeDesktop {
			p.SourceURL = claudeWindowsLatest
		}
		reader, err := s.desktopRemoteArchive(ctx, p)
		if err != nil {
			return nil, err
		}
		version, err := desktopMSIXVersion(reader, t.target, t.arch)
		if err != nil {
			return nil, err
		}
		p.Version = version
		return p, nil
	}
	p.Layout = dom.LayoutAppBundleZip
	p.BundleIdentifier, p.TeamIdentifier = codexDesktopBundleID, codexDesktopTeamID
	if t.target == dom.TargetCodexDesktop {
		feed := codexDesktopBase + "appcast.xml"
		if t.arch == dom.ArchX64 {
			feed = codexDesktopBase + "appcast-x64.xml"
		}
		data, err := s.desktopMetadata(ctx, t.target, feed)
		if err != nil {
			return nil, err
		}
		var doc struct {
			Items []struct {
				Version   string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle shortVersionString"`
				Channel   string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle channel"`
				Hardware  string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle hardwareRequirements"`
				Enclosure struct {
					URL   string `xml:"url,attr"`
					Size  int64  `xml:"length,attr"`
					Delta string `xml:"deltaFrom,attr"`
				} `xml:"enclosure"`
			} `xml:"channel>item"`
		}
		if xml.Unmarshal(data, &doc) != nil {
			return nil, errors.New("Codex 更新清单格式无效")
		}
		for _, item := range doc.Items {
			if !releaseVersionPattern.MatchString(item.Version) || item.Channel != "" || item.Enclosure.Delta != "" || item.Enclosure.Size <= 0 || item.Enclosure.Size > desktopMaxBytes {
				continue
			}
			if item.Hardware != "" && item.Hardware != t.arch && !(t.arch == dom.ArchX64 && item.Hardware == "x86_64") {
				continue
			}
			u := item.Enclosure.URL
			if !desktopSourceAllowed(t.target, u) || !strings.HasSuffix(u, ".zip") || !strings.Contains(u, "-darwin-"+t.arch+"-") {
				continue
			}
			if p.Version == "" || compareReleaseVersions(item.Version, p.Version) > 0 {
				p.Version, p.SourceURL, p.FileSizeBytes = item.Version, u, item.Enclosure.Size
			}
		}
	} else {
		p.BundleIdentifier, p.TeamIdentifier = claudeDesktopBundleID, claudeDesktopTeamID
		data, err := s.desktopMetadata(ctx, t.target, "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json")
		if err != nil {
			return nil, err
		}
		var doc struct {
			Current  string `json:"currentRelease"`
			Releases []struct {
				Version string `json:"version"`
				Update  struct {
					Version string `json:"version"`
					URL     string `json:"url"`
				} `json:"updateTo"`
			} `json:"releases"`
		}
		if json.Unmarshal(data, &doc) != nil || !releaseVersionPattern.MatchString(doc.Current) {
			return nil, errors.New("Claude 更新清单格式或版本无效")
		}
		for _, release := range doc.Releases {
			u := release.Update.URL
			if release.Version == doc.Current && release.Update.Version == doc.Current && desktopSourceAllowed(t.target, u) && strings.Contains(u, "/darwin/universal/"+doc.Current+"/") && strings.HasSuffix(u, ".zip") {
				p.Version, p.SourceURL = doc.Current, u
				break
			}
		}
	}
	if p.Version == "" {
		return nil, errors.New("官方清单没有受支持的稳定版完整安装包")
	}
	return p, nil
}

func desktopConditions(p *DesktopPackage) http.Header {
	h := make(http.Header)
	if p.ETag != "" && !strings.HasPrefix(p.ETag, "W/") {
		h.Set("If-Match", p.ETag)
	} else if p.LastModified != "" {
		h.Set("If-Unmodified-Since", p.LastModified)
	}
	return h
}

// Range reads only ZIP metadata for discovery; bytes of unchanged MSIX packages
// are not downloaded every hour. No cache or OS-specific executable is needed.
func (s *impl) desktopRemoteArchive(ctx context.Context, p *DesktopPackage) (*zip.Reader, error) {
	r, err := s.desktopRequest(ctx, p.TargetID, p.SourceURL, http.Header{"Range": {"bytes=0-0"}})
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	var size int64
	if r.StatusCode != http.StatusPartialContent {
		return nil, errors.New("官方安装包未返回正确的 Range 响应")
	}
	if _, err := fmt.Sscanf(r.Header.Get("Content-Range"), "bytes 0-0/%d", &size); err != nil || size <= 0 || size > desktopMaxBytes || r.Header.Get("Content-Range") != "bytes 0-0/"+strconv.FormatInt(size, 10) {
		return nil, errors.New("官方安装包大小或 Range 无效")
	}
	if b, err := io.ReadAll(io.LimitReader(r.Body, 2)); err != nil || len(b) != 1 {
		return nil, errors.New("官方安装包 Range 内容不完整")
	}
	p.SourceURL = r.Request.URL.String()
	if !desktopSourceAllowed(p.TargetID, p.SourceURL) || !strings.HasSuffix(p.SourceURL, ".msix") {
		return nil, errors.New("官方 Windows 来源未指向 MSIX")
	}
	p.FileSizeBytes, p.ETag, p.LastModified = size, r.Header.Get("ETag"), r.Header.Get("Last-Modified")
	if len(desktopConditions(p)) == 0 {
		return nil, errors.New("官方安装包缺少 ETag/Last-Modified，无法一致读取版本")
	}
	reader := &desktopRangeReader{ctx: ctx, service: s, pkg: p}
	z, err := zip.NewReader(reader, size)
	if err != nil {
		return nil, errors.New("无法读取官方 MSIX 目录：" + err.Error())
	}
	return z, nil
}

type desktopRangeReader struct {
	ctx      context.Context
	service  *impl
	pkg      *DesktopPackage
	read     int64
	requests int
	blocks   map[int64][]byte
}

func (r *desktopRangeReader) ReadAt(b []byte, off int64) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	if off < 0 || off >= r.pkg.FileSizeBytes {
		return 0, io.EOF
	}
	wanted := len(b)
	if int64(wanted) > r.pkg.FileSizeBytes-off {
		b = b[:r.pkg.FileSizeBytes-off]
	}
	if len(b) > int(desktopMetadataMax) {
		return 0, errors.New("MSIX 单次读取超限")
	}
	if r.blocks == nil {
		r.blocks = make(map[int64][]byte)
	}
	const blockSize int64 = 256 << 10
	n := 0
	for n < len(b) {
		start := (off + int64(n)) / blockSize * blockSize
		block, ok := r.blocks[start]
		if !ok {
			size := min(blockSize, r.pkg.FileSizeBytes-start)
			block = make([]byte, int(size))
			if err := r.readRange(block, start); err != nil {
				return n, err
			}
			r.blocks[start] = block
		}
		n += copy(b[n:], block[off+int64(n)-start:])
	}
	if n < wanted {
		return n, io.EOF
	}
	return n, nil
}

// archive/zip reads central directories in small chunks. Cache aligned ranges
// so a large real installer does not issue hundreds of HTTP requests.
func (r *desktopRangeReader) readRange(b []byte, off int64) error {
	r.read += int64(len(b))
	r.requests++
	if r.read > 16<<20 || len(b) > int(desktopMetadataMax) || r.requests > 64 {
		return errors.New("MSIX 版本清单读取超限")
	}
	h := desktopConditions(r.pkg)
	end := off + int64(len(b)) - 1
	h.Set("Range", fmt.Sprintf("bytes=%d-%d", off, end))
	response, err := r.service.desktopRequest(r.ctx, r.pkg.TargetID, r.pkg.SourceURL, h)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 206 || response.Header.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", off, end, r.pkg.FileSizeBytes) {
		return errors.New("MSIX Range 不匹配或上游包已变化")
	}
	if r.pkg.ETag != "" && response.Header.Get("ETag") != "" && r.pkg.ETag != response.Header.Get("ETag") {
		return errors.New("MSIX ETag 已变化")
	}
	if r.pkg.LastModified != "" && response.Header.Get("Last-Modified") != "" && r.pkg.LastModified != response.Header.Get("Last-Modified") {
		return errors.New("MSIX 更新时间已变化")
	}
	_, err = io.ReadFull(response.Body, b)
	if err != nil {
		return err
	}
	var extra [1]byte
	if m, err := response.Body.Read(extra[:]); m != 0 || (err != nil && err != io.EOF) {
		return errors.New("MSIX Range 内容无效")
	}
	return nil
}
