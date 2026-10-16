// link_from_drive.go · B-5-1 §A5.7 把 caller drive_files 内容 ingest 到 KB.
//
// 流程:
//  1. KB 访问 + 写权限校 (assertKBAccess + assertCanModify, 与 UploadDocument 同款);
//  2. DriveFiles.GetDriveFileForRead(caller, driveFileUUID) → 拿到 file 元 + 一次性 GET URL;
//     该接口已做 caller/tenant owner 校验 (drive.Service.GetFile 内部 assertFileOwned);
//  3. MIME / size 闸 (与 UploadDocument 一致);
//  4. http.Get(URL) 拉字节, 大小 cap = driveLinkCap;
//  5. 复用 UploadDocument 流程 (PG tx + provider IngestChunks + audit).
//
// Dify 不可达 / degraded 由 UploadDocument 路径透传 kb.provider_degraded.
//
// 失败模式:
//   - DriveFiles nil → kb.link.unavailable (装配遗漏, 不应到生产);
//   - drive 反查 forbidden / 404 → 透传;
//   - HTTP fetch 失败 → kb.link.fetch_failed;
//   - 内容 > driveLinkCap → kb.document_too_large.
package knowledge

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ErrCodeLinkUnavailable · DriveFiles dep nil 时返这条.
const ErrCodeLinkUnavailable = "kb.link.unavailable"

// ErrCodeLinkFetchFailed · drive presigned URL HTTP GET 失败.
const ErrCodeLinkFetchFailed = "kb.link.fetch_failed"

// driveFetchHTTPClient · 短超时 HTTP client; 复用即可 (无外部依赖).
var driveFetchHTTPClient = &http.Client{
	Timeout: 30 * time.Second,
}

func (s *impl) LinkFromDrive(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, driveFileUUID, kbFolderUUID string) (*DocumentDTO, error) {
	if strings.TrimSpace(driveFileUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("drive_file_uuid required")
	}
	if s.driveFiles == nil {
		return nil, apperr.New(apperr.InternalError, ErrCodeLinkUnavailable).
			Withf("knowledge LinkFromDrive: DriveFileLookup dep not wired")
	}
	// KB 访问 + 写权限
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}

	// drive 反查 (含 owner / tenant 校验) + presign GET.
	snap, err := s.driveFiles.GetDriveFileForRead(ctx, accountID, tenantID, driveFileUUID)
	if err != nil {
		return nil, err
	}
	if snap == nil {
		return nil, apperr.ErrForbidden
	}

	// MIME / size 闸 (与 UploadDocument 完全一致).
	mime := strings.ToLower(strings.TrimSpace(snap.MimeType))
	if mime == "" {
		mime = "text/plain"
	}
	if !isAllowedDocMIME(mime) {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocFormat).
			Withf("mime %q not supported; allowed: %s", mime, allowedDocMIMEDescription())
	}
	cap := s.driveLinkCap
	if cap <= 0 {
		cap = s.cfg.DocMaxBytes
	}
	if snap.FileSize > cap {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocTooLarge).
			Withf("size %d > limit %d", snap.FileSize, cap)
	}

	// HTTP GET drive presigned URL → bytes (LimitReader 防过大).
	content, ferr := fetchDriveBytes(ctx, snap.DownloadURL, cap)
	if ferr != nil {
		return nil, ferr
	}
	if int64(len(content)) > cap {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocTooLarge).
			Withf("fetched size %d > limit %d", len(content), cap)
	}

	title := strings.TrimSpace(snap.FileName)
	if title == "" {
		title = "untitled.txt"
	}
	// 复用 UploadDocument: 该路径已含 status='ingesting' → IngestChunks → finalize ok/failed
	// + audit + kb.provider_degraded 映射 (round-3 P1-4 已落).
	return s.UploadDocument(ctx, accountID, tenantID, perms, kb.UUID, UploadDocReq{
		Title:        title,
		MimeType:     mime,
		Content:      content,
		KBFolderUUID: kbFolderUUID,
	})
}

// fetchDriveBytes · 抓 drive presigned URL → []byte, 带 LimitReader cap.
func fetchDriveBytes(ctx context.Context, url string, maxBytes int64) ([]byte, error) {
	if strings.TrimSpace(url) == "" {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLinkFetchFailed).
			Withf("drive download_url empty")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLinkFetchFailed).
			Withf("new request: %v", err)
	}
	resp, err := driveFetchHTTPClient.Do(req)
	if err != nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLinkFetchFailed).
			Withf("http get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLinkFetchFailed).
			Withf("http status %d", resp.StatusCode)
	}
	// LimitReader: 多读 1 字节用于判越界.
	limited := io.LimitReader(resp.Body, maxBytes+1)
	buf, err := io.ReadAll(limited)
	if err != nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLinkFetchFailed).
			Withf("read body: %v", err)
	}
	return buf, nil
}

// 编译期断言: errors 包未使用时不让 import 浮动.
var _ = errors.Is
var _ = fmt.Sprintf
