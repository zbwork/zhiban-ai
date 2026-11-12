package localcodingcatalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

// mirrorTimeout bounds one copy; desktop bundles are a few hundred MB and the
// third-party hosts they come from can be very slow from the office network.
const mirrorTimeout = 3 * time.Hour

// mirrorConcurrency caps copies running at once in one process. Admin's
// "搬入全部外链" starts one MirrorPackage per row; each copy spools a whole
// package to the temp dir while the proxied download crawls, so the rest
// wait for a slot (their rows already show running).
const mirrorConcurrency = 2

// mirrorInterruptedMessage is what the operator sees on a row whose copy
// died with the previous Admin process (RecoverInterruptedMirrors).
const mirrorInterruptedMessage = "搬入被服务重启中断，请重新搬入"

// MirrorPackage implements Service. The row must carry an external https
// package with its size and SHA-256 already recorded; the copy verifies both
// before the row is pointed at the object store, so a tampered or changed
// upstream file can never replace what was recorded.
func (s *impl) MirrorPackage(ctx context.Context, uuid string, actorID int64) (*dom.Version, error) {
	uuid = strings.TrimSpace(uuid)
	if s.packages == nil {
		return nil, dom.ErrPackageStoreMissing
	}
	item, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if !item.HasPackage() || !item.IsExternalPackage() {
		return nil, dom.ErrPackageNotExternal
	}
	if item.MirrorState == dom.MirrorStateRunning {
		return nil, dom.ErrMirrorRunning
	}
	if err := s.repo.SetMirrorState(ctx, uuid, dom.MirrorStateRunning, ""); err != nil {
		return nil, err
	}
	item.MirrorState, item.MirrorError = dom.MirrorStateRunning, ""
	if s.mirrorSync {
		s.mirror(context.Background(), *item, actorID)
		return s.repo.GetByUUID(ctx, uuid)
	}
	go s.mirror(context.Background(), *item, actorID)
	return item, nil
}

// RecoverInterruptedMirrors implements Service. A copy exists only in the
// memory of the process that started it, so when this process starts nothing
// of its own can be running yet: every row at running was orphaned by the
// previous process (2026-09-11: an Admin restart mid-copy left rows stuck at
// running until someone cleared them by SQL). Admin runs as one replica; with
// several, a restart of one would also fail-mark its siblings' in-flight
// copies — those still finish (ReplaceStorage marks done) and a retry in the
// meantime only verifies the same bytes again.
func (s *impl) RecoverInterruptedMirrors(ctx context.Context) (int64, error) {
	return s.repo.ResetRunningMirrors(ctx, mirrorInterruptedMessage)
}

func (s *impl) mirror(parent context.Context, item dom.Version, actorID int64) {
	ctx, cancel := context.WithTimeout(parent, mirrorTimeout)
	defer cancel()
	// The outcome is recorded even after the copy's own deadline has passed;
	// a row left at running would block every retry.
	fail := func(message string) {
		_ = s.repo.SetMirrorState(context.WithoutCancel(parent), item.UUID, dom.MirrorStateFailed, message)
	}
	select {
	case s.mirrorSlots <- struct{}{}:
		defer func() { <-s.mirrorSlots }()
	case <-ctx.Done():
		fail("等待搬入名额超时")
		return
	}
	spool, err := s.spoolExternal(ctx, item)
	if err != nil {
		fail(err.Error())
		return
	}
	defer spool.Close()
	uploaded, err := s.packages.Upload(ctx, item.UUID, mirrorFilename(item.StorageURI), spool.file, item.FileSizeBytes, spool.contentType)
	if err != nil {
		fail("写入对象存储失败：" + err.Error())
		return
	}
	if uploaded.SHA256 != item.SHA256 {
		fail(fmt.Sprintf("写入对象存储后哈希 %s… 与记录的 %s… 不符", short(uploaded.SHA256), short(item.SHA256)))
		return
	}
	replaced, err := s.repo.ReplaceStorage(ctx, item.UUID, uploaded.StorageURI, item.FileSizeBytes, item.SHA256, actorID)
	if err != nil {
		fail("更新记录失败：" + err.Error())
		return
	}
	s.auditEvent(ctx, actorID, "local_coding.package_mirrored", replaced, map[string]any{
		"from_host": hostOf(item.StorageURI),
	})
}

// spooled is a verified copy of the external package in the temp dir.
type spooled struct {
	file        *os.File
	contentType string
}

func (p *spooled) Close() {
	name := p.file.Name()
	_ = p.file.Close()
	_ = os.Remove(name)
}

// spoolExternal downloads the external package into a temp file and checks
// the declared size and the recorded SHA-256 before anything touches the
// object store. Spooling is deliberate: the store client has a fixed request
// timeout while the third-party download (through the office proxy) can take
// far longer — streaming one straight into the other timed out on every
// desktop bundle (test environment, 2026-09-11). It also keeps unexpected
// bytes out of local-coding/<uuid>/ altogether.
func (s *impl) spoolExternal(ctx context.Context, item dom.Version) (*spooled, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, item.StorageURI, nil)
	if err != nil {
		return nil, errors.New("来源地址无效")
	}
	request.Header.Set("User-Agent", "agent-bus/local-coding-mirror")
	request.Header.Set("Accept", "application/octet-stream")
	response, err := s.httpClient.Do(request)
	if err != nil {
		return nil, errors.New("下载失败：" + err.Error())
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("来源返回 HTTP %d", response.StatusCode)
	}
	if response.ContentLength < 0 {
		return nil, errors.New("来源未提供 Content-Length，无法核对大小")
	}
	if response.ContentLength != item.FileSizeBytes {
		return nil, fmt.Errorf("来源大小 %d 与记录的 %d 不符", response.ContentLength, item.FileSizeBytes)
	}
	file, err := os.CreateTemp("", "local-coding-mirror-*")
	if err != nil {
		return nil, errors.New("临时文件创建失败：" + err.Error())
	}
	spool := &spooled{file: file, contentType: response.Header.Get("Content-Type")}
	hasher := sha256.New()
	// One byte past the declared size catches a body longer than Content-Length.
	n, err := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(response.Body, item.FileSizeBytes+1))
	if err != nil {
		spool.Close()
		return nil, errors.New("下载失败：" + err.Error())
	}
	if n != item.FileSizeBytes {
		spool.Close()
		return nil, fmt.Errorf("下载到 %d 字节，与记录的 %d 不符", n, item.FileSizeBytes)
	}
	if sum := hex.EncodeToString(hasher.Sum(nil)); sum != item.SHA256 {
		spool.Close()
		return nil, fmt.Errorf("下载内容哈希 %s… 与记录的 %s… 不符", short(sum), short(item.SHA256))
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		spool.Close()
		return nil, errors.New("临时文件读取失败：" + err.Error())
	}
	return spool, nil
}

// mirrorFilename keeps the upstream file name (the last path segment, also
// through proxies such as gh-proxy.com/https://github.com/...) so the object
// key stays recognisable; PackageStore sanitises it.
func mirrorFilename(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "package"
	}
	name := path.Base(parsed.Path)
	if name == "" || name == "." || name == "/" {
		return "package"
	}
	return name
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
