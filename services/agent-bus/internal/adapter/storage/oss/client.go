package oss

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
)

// Config 是 oss.Store 的构造参数. Drive / media 路径通常由 DB storage resolver 构造.
//
// 必填:
//   - Endpoint  写 endpoint, e.g. https://oss-cn-hangzhou.aliyuncs.com (AliYun) /
//     https://s3.us-east-1.amazonaws.com    (AWS) / http://127.0.0.1:9000 (MinIO) /
//     http://storage.example.com; 用于 PUT / HEAD / DELETE.
//   - Bucket
//   - AccessKeyID / SecretAccessKey
//
// 选填:
//   - ReadEndpoint    读 endpoint (PresignGet / download / preview), e.g.
//     http://s3.test.yixin.com; 留空时复用 Endpoint
//     (单 endpoint 部署不破坏). 与 Endpoint 不同时, 仅 host 部分
//     被替换, region / bucket / SigV4 签名仍按写 endpoint 算 — 一般
//     是同一组 AK/SK 的反向代理 / CDN 边缘读取 endpoint.
//   - Region          默认 us-east-1; AliYun OSS 用 cn-hangzhou 等
//   - ForcePathStyle  MinIO / S3 path-style endpoint 必填 true
//   - PresignPutTTL   默认 5min (M7 §9)
//   - PresignGetTTL   默认 10min
//   - HTTPClient      Delete 用; nil = http.DefaultClient
//   - Kind            上报 message_files.storage_kind / drive_files.storage_kind 用 (默认 "oss")
type Config struct {
	Endpoint        string // 写 endpoint
	ReadEndpoint    string // 读 endpoint; 空 → fallback Endpoint
	Region          string
	Bucket          string
	AccessKeyID     string
	SecretAccessKey string
	ForcePathStyle  bool
	PresignPutTTL   time.Duration
	PresignGetTTL   time.Duration
	HTTPClient      *http.Client
	Kind            string
}

// WriteEndpoint 返回写 endpoint.
func (c Config) WriteEndpoint() string { return c.Endpoint }

// EffectiveReadEndpoint 返回有效读 endpoint (空 → fallback Endpoint).
func (c Config) EffectiveReadEndpoint() string {
	if strings.TrimSpace(c.ReadEndpoint) == "" {
		return c.Endpoint
	}
	return c.ReadEndpoint
}

// Store 是 object.Store 接口的真实云存储实现 (M7 Phase A).
//
// 不持有 SDK 客户端: 全部 presign / sign 都走 sigv4.go 的 pure-stdlib 实现; delete 通过
// net/http 直接 DELETE 一个 presigned URL.
type Store struct {
	cfg Config
}

// New 构造一个 oss.Store; 缺必填字段 / endpoint 不合法 → 返错 (cmd/bus 启动 fail fast).
func New(cfg Config) (*Store, error) {
	if cfg.Endpoint == "" {
		return nil, errors.New("oss.New: endpoint required")
	}
	if cfg.Bucket == "" {
		return nil, errors.New("oss.New: bucket required")
	}
	if cfg.AccessKeyID == "" || cfg.SecretAccessKey == "" {
		return nil, errors.New("oss.New: access key id / secret required")
	}
	if cfg.Region == "" {
		cfg.Region = "us-east-1"
	}
	if cfg.PresignPutTTL <= 0 {
		cfg.PresignPutTTL = 5 * time.Minute
	}
	if cfg.PresignGetTTL <= 0 {
		cfg.PresignGetTTL = 10 * time.Minute
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 5 * time.Minute}
	}
	if cfg.Kind == "" {
		cfg.Kind = "oss"
	}
	if _, err := url.Parse(cfg.Endpoint); err != nil {
		return nil, fmt.Errorf("oss.New: invalid endpoint %q: %w", cfg.Endpoint, err)
	}
	if cfg.ReadEndpoint != "" {
		if _, err := url.Parse(cfg.ReadEndpoint); err != nil {
			return nil, fmt.Errorf("oss.New: invalid read_endpoint %q: %w", cfg.ReadEndpoint, err)
		}
	}
	return &Store{cfg: cfg}, nil
}

// Kind 返回 message_files.storage_kind / drive_files.storage_kind 写入的值.
func (s *Store) Kind() string { return s.cfg.Kind }

// PresignPut presign 一次 PUT URL.
func (s *Store) PresignPut(_ context.Context, in object.PresignPutInput) (*object.PresignPutOutput, error) {
	if in.Key == "" {
		return nil, errors.New("oss.PresignPut: key required")
	}
	ttl := in.TTL
	if ttl <= 0 {
		ttl = s.cfg.PresignPutTTL
	}
	res, err := presign(presignerInput{
		Method:          "PUT",
		Endpoint:        s.cfg.Endpoint,
		Bucket:          s.cfg.Bucket,
		Key:             in.Key,
		Region:          s.cfg.Region,
		AccessKeyID:     s.cfg.AccessKeyID,
		SecretAccessKey: s.cfg.SecretAccessKey,
		Expires:         ttl,
		Now:             time.Now(),
		ContentType:     in.ContentType,
		ForcePathStyle:  s.cfg.ForcePathStyle,
	})
	if err != nil {
		return nil, err
	}
	return &object.PresignPutOutput{
		URL:       res.URL,
		Headers:   res.Headers,
		ExpiresAt: res.ExpiresAt,
	}, nil
}

// PresignGet presign 一次 GET URL.
func (s *Store) PresignGet(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	return s.presignGetWithEndpoint(in, s.cfg.EffectiveReadEndpoint())
}

// PresignGetInternal presigns a GET URL against the write/internal endpoint.
//
// Client-facing downloads must keep using PresignGet so they honor read_endpoint.
// Server-side consumers running inside the cluster (for example OpenClaw input
// preparation) can use this to avoid depending on the public/CDN read endpoint.
func (s *Store) PresignGetInternal(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	return s.presignGetWithEndpoint(in, s.cfg.Endpoint)
}

func (s *Store) presignGetWithEndpoint(in object.PresignGetInput, endpoint string) (*object.PresignGetOutput, error) {
	if in.Key == "" {
		return nil, errors.New("oss.PresignGet: key required")
	}
	ttl := in.TTL
	if ttl <= 0 {
		ttl = s.cfg.PresignGetTTL
	}
	disp := ""
	if in.FileName != "" || !in.Inline {
		mode := "attachment"
		if in.Inline {
			mode = "inline"
		}
		fn := escapeFileName(in.FileName)
		switch {
		case fn == "":
			disp = mode
		case isASCII(fn):
			disp = mode + "; filename=\"" + fn + "\""
		default:
			// 非 ASCII 文件名 (中文截图名等) 按 RFC 5987 filename* 编码——
			// 裸 UTF-8 塞 quoted-string 是非法 header, 部分浏览器会拒识
			// disposition 退化为下载 (2026-07-21 admin 材料预览实锤)。
			disp = mode + "; filename=\"file\"; filename*=UTF-8''" +
				url.PathEscape(fn)
		}
	}
	res, err := presign(presignerInput{
		Method:                     "GET",
		Endpoint:                   endpoint,
		Bucket:                     s.cfg.Bucket,
		Key:                        in.Key,
		Region:                     s.cfg.Region,
		AccessKeyID:                s.cfg.AccessKeyID,
		SecretAccessKey:            s.cfg.SecretAccessKey,
		Expires:                    ttl,
		Now:                        time.Now(),
		ResponseContentDisposition: disp,
		ResponseContentType:        in.ContentType,
		ForcePathStyle:             s.cfg.ForcePathStyle,
	})
	if err != nil {
		return nil, err
	}
	return &object.PresignGetOutput{URL: res.URL, ExpiresAt: res.ExpiresAt}, nil
}

// PutObject 服务端直传：用 presign 出来的 PUT URL，由 bus 进程把 body 直接 PUT 到对象存储。
//
// 用途场景：admin 上传 SKILL.md 包等少数"必须服务端校验后落 OSS"的路径
// （客户端直传走 PresignPut + 客户端 HTTP PUT 即可，不必走这条）。
//
// body 必须可一次性消费；contentLength 必须准确（OSS / S3 sigv4 要求）。contentType 留空 → "application/octet-stream"。
func (s *Store) PutObject(ctx context.Context, key string, body io.Reader, contentLength int64, contentType string) error {
	if key == "" {
		return errors.New("oss.PutObject: key required")
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	res, err := presign(presignerInput{
		Method:          "PUT",
		Endpoint:        s.cfg.Endpoint,
		Bucket:          s.cfg.Bucket,
		Key:             key,
		Region:          s.cfg.Region,
		AccessKeyID:     s.cfg.AccessKeyID,
		SecretAccessKey: s.cfg.SecretAccessKey,
		Expires:         s.cfg.PresignPutTTL,
		Now:             time.Now(),
		ContentType:     contentType,
		ForcePathStyle:  s.cfg.ForcePathStyle,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, res.URL, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	if contentLength > 0 {
		req.ContentLength = contentLength
	}
	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	return fmt.Errorf("oss.PutObject: status %d for key %q", resp.StatusCode, key)
}

// Stat HEAD object; 取 Content-Length / Content-Type / ETag (M7 Phase A 返修第二轮).
//
// 实现: presign 一个 HEAD URL → http.Client.Do(HEAD).
// 200 → 解析 header 填 *object.Stat; 404 → object.ErrNotFound; 其它 → error.
//
// AWS S3 / AliYun OSS / MinIO 都在 HEAD response 返 Content-Length & Content-Type,
// 与 GET response 一致 (RFC 7231 §4.3.2).
func (s *Store) Stat(ctx context.Context, key string) (*object.Stat, error) {
	if key == "" {
		return nil, errors.New("oss.Stat: key required")
	}
	res, err := presign(presignerInput{
		Method:          "HEAD",
		Endpoint:        s.cfg.Endpoint,
		Bucket:          s.cfg.Bucket,
		Key:             key,
		Region:          s.cfg.Region,
		AccessKeyID:     s.cfg.AccessKeyID,
		SecretAccessKey: s.cfg.SecretAccessKey,
		Expires:         2 * time.Minute,
		Now:             time.Now(),
		ForcePathStyle:  s.cfg.ForcePathStyle,
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, res.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		out := &object.Stat{
			Size:        resp.ContentLength,
			ContentType: resp.Header.Get("Content-Type"),
			ETag:        strings.Trim(resp.Header.Get("ETag"), "\""),
		}
		return out, nil
	case http.StatusNotFound:
		return nil, object.ErrNotFound
	default:
		return nil, fmt.Errorf("oss.Stat: status %d for key %q", resp.StatusCode, key)
	}
}

// Copy F06 Phase 2.M: 服务端 in-place copy.
//
// 走 SigV4 header 模式 (`signHeaderAuthRequest`) — query-string 模式无法签 x-amz-copy-source 自定义头.
// 请求形式: PUT https://<bucket>.<endpoint>/<dstKey>
// Headers: x-amz-copy-source = "/<bucket>/<srcKey>" (URI-encoded), x-amz-date, x-amz-content-sha256 (emptyHash)
// 空 body → payloadHash = emptyHashHex.
//
// 200/2xx → ok; 404 (srcKey 不存在) → object.ErrNotFound; 其它 → error.
func (s *Store) Copy(ctx context.Context, srcKey, dstKey string) error {
	if srcKey == "" || dstKey == "" {
		return errors.New("oss.Copy: src/dst key required")
	}
	baseURL, host, pathPrefix, err := buildHost(s.cfg.Endpoint, s.cfg.Bucket, s.cfg.ForcePathStyle)
	if err != nil {
		return err
	}
	dstURL := baseURL + pathPrefix + uriEncodeKey(dstKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, dstURL, nil)
	if err != nil {
		return err
	}
	req.URL.Host = host // buildHost 内已包含, 兼容性赋值
	// x-amz-copy-source: /<bucket>/<srcKey>, srcKey 必须 URI-encode (保留 /).
	req.Header.Set("X-Amz-Copy-Source", "/"+s.cfg.Bucket+"/"+uriEncodeKey(srcKey))
	signHeaderAuthRequest(req, s.cfg.SecretAccessKey, s.cfg.AccessKeyID, s.cfg.Region, emptyHashHex, time.Now())

	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		// S3 Copy 200 仍可能在 body 报错 (PreconditionFailed 等); 简单读取后判 <Error/>.
		body, _ := io.ReadAll(resp.Body)
		if bytes.Contains(body, []byte("<Error>")) {
			return fmt.Errorf("oss.Copy: 2xx with <Error> body: %s", string(body))
		}
		return nil
	case resp.StatusCode == http.StatusNotFound:
		return object.ErrNotFound
	default:
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("oss.Copy: status %d for %q→%q: %s", resp.StatusCode, srcKey, dstKey, string(body))
	}
}

// =====================================================
// F06 Phase 2.M: multipart upload (Init / PresignPart / Complete / Abort)
// =====================================================

// initiateMultipartResult S3 InitiateMultipartUpload XML 响应.
type initiateMultipartResult struct {
	XMLName  xml.Name `xml:"InitiateMultipartUploadResult"`
	Bucket   string   `xml:"Bucket"`
	Key      string   `xml:"Key"`
	UploadID string   `xml:"UploadId"`
}

// completePart Complete 请求 body 的 <Part> 子节点.
type completePart struct {
	XMLName    xml.Name `xml:"Part"`
	PartNumber int      `xml:"PartNumber"`
	ETag       string   `xml:"ETag"`
}

// completeMultipartUpload Complete 请求 body 根节点.
type completeMultipartUpload struct {
	XMLName xml.Name       `xml:"CompleteMultipartUpload"`
	Parts   []completePart `xml:"Part"`
}

// InitMultipart F06 Phase 2.M: POST <bucket>/<key>?uploads → 解析 XML 返 UploadId.
func (s *Store) InitMultipart(ctx context.Context, key, contentType string) (string, error) {
	if key == "" {
		return "", errors.New("oss.InitMultipart: key required")
	}
	baseURL, host, pathPrefix, err := buildHost(s.cfg.Endpoint, s.cfg.Bucket, s.cfg.ForcePathStyle)
	if err != nil {
		return "", err
	}
	full := baseURL + pathPrefix + uriEncodeKey(key) + "?uploads="
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, full, nil)
	if err != nil {
		return "", err
	}
	req.URL.Host = host
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	signHeaderAuthRequest(req, s.cfg.SecretAccessKey, s.cfg.AccessKeyID, s.cfg.Region, emptyHashHex, time.Now())
	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("oss.InitMultipart: status %d for key %q: %s", resp.StatusCode, key, string(body))
	}
	var out initiateMultipartResult
	if err := xml.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("oss.InitMultipart: parse XML: %w (body=%s)", err, string(body))
	}
	if out.UploadID == "" {
		return "", fmt.Errorf("oss.InitMultipart: empty UploadId in response: %s", string(body))
	}
	return out.UploadID, nil
}

// PresignPart F06 Phase 2.M: PUT <bucket>/<key>?partNumber=N&uploadId=X presigned URL.
// 与现有 PresignPut 走相同 query-mode 签名, ExtraQuery 把 partNumber / uploadId 一并签入.
func (s *Store) PresignPart(_ context.Context, key, uploadID string, partNumber int, ttl time.Duration) (string, error) {
	if key == "" || uploadID == "" {
		return "", errors.New("oss.PresignPart: key + uploadID required")
	}
	if partNumber <= 0 {
		return "", errors.New("oss.PresignPart: partNumber must be >= 1")
	}
	if ttl <= 0 {
		ttl = s.cfg.PresignPutTTL
	}
	extra := url.Values{}
	extra.Set("partNumber", strconv.Itoa(partNumber))
	extra.Set("uploadId", uploadID)
	res, err := presign(presignerInput{
		Method:          "PUT",
		Endpoint:        s.cfg.Endpoint,
		Bucket:          s.cfg.Bucket,
		Key:             key,
		Region:          s.cfg.Region,
		AccessKeyID:     s.cfg.AccessKeyID,
		SecretAccessKey: s.cfg.SecretAccessKey,
		Expires:         ttl,
		Now:             time.Now(),
		ForcePathStyle:  s.cfg.ForcePathStyle,
		ExtraQuery:      extra,
	})
	if err != nil {
		return "", err
	}
	return res.URL, nil
}

// CompleteMultipart F06 Phase 2.M: POST <bucket>/<key>?uploadId=X + XML body.
// SigV4 header-mode 签名 (payloadHash = sha256(xml body)).
func (s *Store) CompleteMultipart(ctx context.Context, key, uploadID string, parts []object.MultipartPart) error {
	if key == "" || uploadID == "" {
		return errors.New("oss.CompleteMultipart: key + uploadID required")
	}
	if len(parts) == 0 {
		return errors.New("oss.CompleteMultipart: parts empty")
	}
	body := completeMultipartUpload{Parts: make([]completePart, 0, len(parts))}
	for _, p := range parts {
		body.Parts = append(body.Parts, completePart{PartNumber: p.PartNumber, ETag: p.ETag})
	}
	xmlBytes, err := xml.Marshal(body)
	if err != nil {
		return fmt.Errorf("oss.CompleteMultipart: marshal: %w", err)
	}
	xmlBytes = append([]byte(xml.Header), xmlBytes...)

	baseURL, host, pathPrefix, err := buildHost(s.cfg.Endpoint, s.cfg.Bucket, s.cfg.ForcePathStyle)
	if err != nil {
		return err
	}
	full := baseURL + pathPrefix + uriEncodeKey(key) + "?uploadId=" + url.QueryEscape(uploadID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, full, bytes.NewReader(xmlBytes))
	if err != nil {
		return err
	}
	req.URL.Host = host
	req.ContentLength = int64(len(xmlBytes))
	req.Header.Set("Content-Type", "application/xml")
	payloadHash := sha256Hex(xmlBytes)
	signHeaderAuthRequest(req, s.cfg.SecretAccessKey, s.cfg.AccessKeyID, s.cfg.Region, payloadHash, time.Now())

	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("oss.CompleteMultipart: status %d for key %q: %s", resp.StatusCode, key, string(respBody))
	}
	// 2xx 仍可能在 body 报 <Error> (S3 spec).
	if bytes.Contains(respBody, []byte("<Error>")) {
		return fmt.Errorf("oss.CompleteMultipart: 2xx with <Error> body: %s", string(respBody))
	}
	return nil
}

// AbortMultipart F06 Phase 2.M: DELETE <bucket>/<key>?uploadId=X.
// 204/2xx + 404 都视为成功 (idempotent).
func (s *Store) AbortMultipart(ctx context.Context, key, uploadID string) error {
	if key == "" || uploadID == "" {
		return errors.New("oss.AbortMultipart: key + uploadID required")
	}
	baseURL, host, pathPrefix, err := buildHost(s.cfg.Endpoint, s.cfg.Bucket, s.cfg.ForcePathStyle)
	if err != nil {
		return err
	}
	full := baseURL + pathPrefix + uriEncodeKey(key) + "?uploadId=" + url.QueryEscape(uploadID)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, full, nil)
	if err != nil {
		return err
	}
	req.URL.Host = host
	signHeaderAuthRequest(req, s.cfg.SecretAccessKey, s.cfg.AccessKeyID, s.cfg.Region, emptyHashHex, time.Now())

	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	body, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("oss.AbortMultipart: status %d for key %q uploadID %q: %s", resp.StatusCode, key, uploadID, string(body))
}

// Delete 删一个对象 (M7 §4.3 物理删 commit 后 best-effort).
//
// 实现: presign 一个 DELETE URL → http.Client.Do(DELETE).
// 服务器 404 不视为错误 (idempotent); 5xx / 网络错返错 → 上层调用方写 audit.drive.delete_object_failed.
func (s *Store) Delete(ctx context.Context, key string) error {
	if key == "" {
		return errors.New("oss.Delete: key required")
	}
	res, err := presign(presignerInput{
		Method:          "DELETE",
		Endpoint:        s.cfg.Endpoint,
		Bucket:          s.cfg.Bucket,
		Key:             key,
		Region:          s.cfg.Region,
		AccessKeyID:     s.cfg.AccessKeyID,
		SecretAccessKey: s.cfg.SecretAccessKey,
		Expires:         5 * time.Minute,
		Now:             time.Now(),
		ForcePathStyle:  s.cfg.ForcePathStyle,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, res.URL, nil)
	if err != nil {
		return err
	}
	resp, err := s.cfg.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// 2xx + 404 视为成功 (S3 / OSS 删不存在对象返 204 / 200; 部分实现返 404).
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	return fmt.Errorf("oss.Delete: status %d for key %q", resp.StatusCode, key)
}

// escapeFileName 防 Content-Disposition 头注入: 替换 " 和换行.
func escapeFileName(s string) string {
	s = strings.ReplaceAll(s, "\"", "")
	s = strings.ReplaceAll(s, "\n", "")
	s = strings.ReplaceAll(s, "\r", "")
	return s
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 0x7f {
			return false
		}
	}
	return true
}
