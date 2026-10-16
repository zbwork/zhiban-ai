// package_store.go — F03 v0.9.1 §4.7 SKILL.md zip 对象存储。
//
// 复用平台管理「云盘存储配置」的 active default（drive_storage_defaults），
// 但所有 F03 包对象都落到 bucket 内的独立系统前缀（默认 "skill/"）下，
// 与用户云盘文件 / 头像 / chip preview 资产不混在一起。
//
// Key 形态：
//
//	skill/<skill_uuid>/<version>.zip
//	skill/<skill_uuid>/<version>.skill.md     ← 解压出的 SKILL.md（可选，便于 cdn 调试）
//
// 与 spec §10.1 的对齐：
//   - 上传链路服务端用 IAM AK/SK，不暴露给客户端；admin 表单 multipart → bus
//     直 PUT；
//   - 下载链路签名 URL TTL = AGBUS_SKILL_PACKAGE_CDN_URL_TTL（默认 1h），由
//     `SignDownloadURL` 计算。
package skill

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
)

// PackageStoreConfig 配置 F03 包存储的子目录前缀 + TTL。
type PackageStoreConfig struct {
	Prefix          string        // 例如 "skill/"；空 → 用 "skill/"
	IconPrefix      string        // 图标专用前缀，默认 "skill-icons/"
	CDNDownloadTTL  time.Duration // ≤0 → 1h
	MaxPackageBytes int64         // ≤0 → 50MB
	MaxIconBytes    int64         // ≤0 → 1MB
	UploadScanTTL   time.Duration // 解析 SKILL.md 的超时；≤0 → 30s
}

// PackagePutter 是对象存储 PutObject 必须的最小子集；放在 service 包里
// 仅依赖 object.Store 与一个新增 PutObject 接口。
type PackagePutter interface {
	PutObject(ctx context.Context, key string, body io.Reader, contentLength int64, contentType string) error
}

// StorageResolver 是 drive.StorageResolver 对 PackageStore 暴露的最小接口。
type StorageResolver interface {
	Resolve(ctx context.Context, tenantID int64) (object.Store, error)
}

type internalPresignGetter interface {
	PresignGetInternal(context.Context, object.PresignGetInput) (*object.PresignGetOutput, error)
}

// PackageStore 用平台对象存储存 F03 SKILL.md zip 包。
type PackageStore struct {
	store    object.Store  // PresignGet + Stat + Delete
	putter   PackagePutter // PutObject
	resolver StorageResolver
	tenantID int64
	cfg      PackageStoreConfig
}

// NewPackageStore 构造；store / putter 均必填。
func NewPackageStore(store object.Store, putter PackagePutter, cfg PackageStoreConfig) *PackageStore {
	return &PackageStore{store: store, putter: putter, cfg: normalizePackageStoreConfig(cfg)}
}

// NewPackageStoreWithResolver 构造 resolver-backed PackageStore。
//
// tenantID=0 表示平台级资产，走 drive_storage_defaults 的 active default。
func NewPackageStoreWithResolver(resolver StorageResolver, tenantID int64, cfg PackageStoreConfig) *PackageStore {
	return &PackageStore{resolver: resolver, tenantID: tenantID, cfg: normalizePackageStoreConfig(cfg)}
}

func normalizePackageStoreConfig(cfg PackageStoreConfig) PackageStoreConfig {
	if cfg.Prefix == "" {
		cfg.Prefix = "skill/"
	}
	if !strings.HasSuffix(cfg.Prefix, "/") {
		cfg.Prefix += "/"
	}
	if cfg.IconPrefix == "" {
		cfg.IconPrefix = "skill-icons/"
	}
	if !strings.HasSuffix(cfg.IconPrefix, "/") {
		cfg.IconPrefix += "/"
	}
	if cfg.CDNDownloadTTL <= 0 {
		cfg.CDNDownloadTTL = time.Hour
	}
	if cfg.MaxPackageBytes <= 0 {
		cfg.MaxPackageBytes = 50 * 1024 * 1024
	}
	if cfg.MaxIconBytes <= 0 {
		cfg.MaxIconBytes = 1 * 1024 * 1024
	}
	if cfg.UploadScanTTL <= 0 {
		cfg.UploadScanTTL = 30 * time.Second
	}
	return cfg
}

func (p *PackageStore) storeFor(ctx context.Context) (object.Store, error) {
	if p == nil {
		return nil, errors.New("skill.PackageStore: not configured")
	}
	if p.resolver != nil {
		store, err := p.resolver.Resolve(ctx, p.tenantID)
		if err != nil {
			return nil, fmt.Errorf("resolve platform drive storage: %w", err)
		}
		return store, nil
	}
	if p.store == nil {
		return nil, errors.New("skill.PackageStore: object store not configured")
	}
	return p.store, nil
}

func (p *PackageStore) putterFor(ctx context.Context) (PackagePutter, error) {
	if p == nil {
		return nil, errors.New("skill.PackageStore: not configured")
	}
	if p.resolver != nil {
		store, err := p.resolver.Resolve(ctx, p.tenantID)
		if err != nil {
			return nil, fmt.Errorf("resolve platform drive storage: %w", err)
		}
		putter, ok := store.(PackagePutter)
		if !ok {
			return nil, errors.New("platform drive storage does not support PutObject")
		}
		return putter, nil
	}
	if p.putter == nil {
		return nil, errors.New("skill.PackageStore: putter not configured")
	}
	return p.putter, nil
}

// Key 返回 (skill_uuid, version) 对应的 zip 对象 key。
func (p *PackageStore) Key(skillUUID, version string) string {
	return fmt.Sprintf("%s%s/%s.zip", p.cfg.Prefix, skillUUID, version)
}

// UploadResult 是 Upload 的返回，含写到对象存储后的 key 与计算出的 sha256/size +
// SKILL.md frontmatter 解析出的 input_chips_schema 原文（未解析为 JSON）。
type UploadResult struct {
	StorageKey    string
	StorageSize   int64
	StorageSHA256 string
	// SkillMD 是 zip 内 SKILL.md 文件原文（utf-8）；admin 写入 skill_versions
	// 行的 input_chips_schema_snapshot 字段时由 service 层从 frontmatter 抽出。
	SkillMD string
	// Files 是 zip 解析出的全部文件清单（含文本预览），由 service 层写入
	// skill_version_files 表。spec §4.7 R1（C+ 双轨：对象存储 zip 是真值源、本表是投影）。
	Files []ParsedFile
}

// ParsedFile 是从 zip 解出的一个文件（路径 + 大小 + 文本预览或二进制标记）。
type ParsedFile struct {
	Path        string
	SizeBytes   int64
	SHA256      string // hex
	ContentType string // 由扩展名推断，未识别 → application/octet-stream
	IsBinary    bool   // 通过 NUL 字节嗅探
	Truncated   bool   // 大于 MaxFilePreviewBytes
	ContentText string // is_binary / truncated 时为空
}

// ParsePkg 限制：避免 zip-bomb / 单文件超大塞 PG。
const (
	maxParsedFiles      = 500
	maxParsedTotalBytes = 50 * 1024 * 1024 // 50MB 解压总量
	maxFilePreviewBytes = 1 * 1024 * 1024  // 1MB 单文件预览上限
)

// Upload 把 admin 上传的 zip body 流式落对象存储，同时 tee 出 sha256 + size，
// 落完后再做一次"读取 zip 解出 SKILL.md"的轻量 scan（不强制 frontmatter 解析；
// 给 service 层处理）。
//
// 大小上限校验在读取阶段；超限直接返错且不写对象存储。
func (p *PackageStore) Upload(ctx context.Context, skillUUID, version string, body io.Reader) (*UploadResult, error) {
	if skillUUID == "" || version == "" {
		return nil, errors.New("skill.PackageStore.Upload: skill_uuid+version required")
	}

	limited := io.LimitReader(body, p.cfg.MaxPackageBytes+1) // +1 用于检测溢出
	buf, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read upload body: %w", err)
	}
	if int64(len(buf)) > p.cfg.MaxPackageBytes {
		return nil, fmt.Errorf("skill.package_too_large: %d > max %d", len(buf), p.cfg.MaxPackageBytes)
	}

	sum := sha256.Sum256(buf)
	digest := hex.EncodeToString(sum[:])

	skillMD, err := readSkillMDFromZip(buf)
	if err != nil {
		return nil, fmt.Errorf("skill.package_invalid: %w", err)
	}

	files, err := parseZipFiles(buf)
	if err != nil {
		return nil, fmt.Errorf("skill.package_invalid: %w", err)
	}

	key := p.Key(skillUUID, version)
	putter, err := p.putterFor(ctx)
	if err != nil {
		return nil, err
	}
	if err := putter.PutObject(ctx, key, bytes.NewReader(buf), int64(len(buf)), "application/zip"); err != nil {
		return nil, fmt.Errorf("oss put: %w", err)
	}
	return &UploadResult{
		StorageKey: key, StorageSize: int64(len(buf)),
		StorageSHA256: digest, SkillMD: skillMD, Files: files,
	}, nil
}

// SignDownloadURL 给 (skill_uuid, version) 生成一个签名下载 URL。
//
// TTL 默认 = cfg.CDNDownloadTTL；调用方（ZAP `POST /sessions` body 组装）传 0 用默认。
func (p *PackageStore) SignDownloadURL(ctx context.Context, skillUUID, version string, ttl time.Duration) (string, time.Time, error) {
	if ttl <= 0 {
		ttl = p.cfg.CDNDownloadTTL
	}
	store, err := p.storeFor(ctx)
	if err != nil {
		return "", time.Time{}, err
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key: p.Key(skillUUID, version),
		TTL: ttl,
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return out.URL, out.ExpiresAt, nil
}

// readSkillMDFromZip 在 zip 里寻找 "SKILL.md"（大小写不敏感，根目录或单层子目录），
// 找到 → 返回原文；找不到 → 返错。
func readSkillMDFromZip(buf []byte) (string, error) {
	r, err := zip.NewReader(bytes.NewReader(buf), int64(len(buf)))
	if err != nil {
		return "", fmt.Errorf("zip parse: %w", err)
	}
	for _, f := range r.File {
		name := strings.ToLower(f.Name)
		base := name
		if i := strings.LastIndex(name, "/"); i >= 0 {
			base = name[i+1:]
			rest := name[:i]
			// 仅允许根 + 1 层子目录
			if strings.Count(rest, "/") >= 1 {
				continue
			}
		}
		if base != "skill.md" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return "", fmt.Errorf("zip open SKILL.md: %w", err)
		}
		defer rc.Close()
		body, err := io.ReadAll(io.LimitReader(rc, 1024*1024)) // 1MB 上限够 SKILL.md
		if err != nil {
			return "", fmt.Errorf("zip read SKILL.md: %w", err)
		}
		return string(body), nil
	}
	return "", errors.New("SKILL.md not found in zip")
}

// IconUploadResult 是 UploadIcon 的返回。
type IconUploadResult struct {
	StorageKey string // 形如 "skill-icons/<sha256>.<ext>"，写库时拼 "oss://" 前缀
	StorageURI string // "oss://" + StorageKey，admin 写入 skills.icon_url
	Size       int64
	SHA256     string
}

func (p *PackageStore) UploadIcon(ctx context.Context, body io.Reader, contentType string) (*IconUploadResult, error) {
	if p == nil {
		return nil, errors.New("skill.PackageStore.UploadIcon: not configured")
	}
	return p.UploadImage(ctx, body, contentType, p.cfg.IconPrefix, p.cfg.MaxIconBytes)
}

// UploadImage 把后台上传的图片流落到指定 prefix 下，按内容寻址（sha256.<ext>）。
//
// 大小限制默认复用 cfg.MaxIconBytes（当前 1MB）。content-type 决定扩展名。
func (p *PackageStore) UploadImage(ctx context.Context, body io.Reader, contentType, prefix string, maxBytes int64) (*IconUploadResult, error) {
	if p == nil {
		return nil, errors.New("skill.PackageStore.UploadImage: not configured")
	}
	if maxBytes <= 0 {
		maxBytes = p.cfg.MaxIconBytes
	}
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		prefix = p.cfg.IconPrefix
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	limited := io.LimitReader(body, maxBytes+1)
	buf, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read upload body: %w", err)
	}
	if int64(len(buf)) > maxBytes {
		return nil, fmt.Errorf("skill.icon_too_large: %d > max %d", len(buf), maxBytes)
	}
	if len(buf) == 0 {
		return nil, errors.New("skill.icon_empty")
	}
	ext := iconExtForMIME(contentType)
	if ext == "" {
		return nil, fmt.Errorf("skill.icon_unsupported_mime: %s", contentType)
	}

	sum := sha256.Sum256(buf)
	digest := hex.EncodeToString(sum[:])
	key := prefix + digest + ext

	putter, err := p.putterFor(ctx)
	if err != nil {
		return nil, err
	}
	if err := putter.PutObject(ctx, key, bytes.NewReader(buf), int64(len(buf)), contentType); err != nil {
		return nil, fmt.Errorf("oss put: %w", err)
	}
	return &IconUploadResult{
		StorageKey: key, StorageURI: "oss://" + key,
		Size: int64(len(buf)), SHA256: digest,
	}, nil
}

// SignURL 给任意对象 key（含 IconPrefix / Prefix 下都可）生成一个签名 GET URL。
//
// TTL ≤ 0 时使用 cfg.CDNDownloadTTL。
func (p *PackageStore) SignURL(ctx context.Context, key string, ttl time.Duration) (string, time.Time, error) {
	if ttl <= 0 {
		ttl = p.cfg.CDNDownloadTTL
	}
	store, err := p.storeFor(ctx)
	if err != nil {
		return "", time.Time{}, err
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{Key: key, TTL: ttl})
	if err != nil {
		return "", time.Time{}, err
	}
	return out.URL, out.ExpiresAt, nil
}

// ReadObject reads a controlled object into memory for skill bundle export.
// It accepts only bucket-relative keys (or oss:// keys) below one of the
// supplied prefixes. Arbitrary URLs and redirects are rejected to avoid SSRF.
func (p *PackageStore) ReadObject(ctx context.Context, raw string, maxBytes int64, allowedPrefixes ...string) ([]byte, error) {
	if maxBytes <= 0 {
		return nil, errors.New("skill.PackageStore.ReadObject: max_bytes required")
	}
	key := strings.TrimPrefix(strings.TrimSpace(raw), "oss://")
	if err := validateControlledObjectKey(key, allowedPrefixes); err != nil {
		return nil, err
	}
	store, err := p.storeFor(ctx)
	if err != nil {
		return nil, err
	}
	in := object.PresignGetInput{Key: key, TTL: 5 * time.Minute}
	var signed *object.PresignGetOutput
	if internal, ok := store.(internalPresignGetter); ok {
		signed, err = internal.PresignGetInternal(ctx, in)
	} else {
		signed, err = store.PresignGet(ctx, in)
	}
	if err != nil {
		return nil, fmt.Errorf("presign object: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, signed.URL, nil)
	if err != nil {
		return nil, errors.New("build object download request")
	}
	client := &http.Client{
		Timeout: 60 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("object redirect not allowed")
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.New("object download failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("object download status %d", resp.StatusCode)
	}
	buf, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, errors.New("read object download")
	}
	if int64(len(buf)) > maxBytes {
		return nil, fmt.Errorf("object too large: max %d", maxBytes)
	}
	return buf, nil
}

func validateControlledObjectKey(key string, allowedPrefixes []string) error {
	if key == "" || strings.Contains(key, "://") || strings.HasPrefix(key, "/") ||
		strings.Contains(key, "\\") || strings.ContainsAny(key, "\x00\r\n\t ") ||
		path.Clean(key) != key || strings.Contains(key, "../") {
		return errors.New("skill object key invalid")
	}
	for _, prefix := range allowedPrefixes {
		prefix = strings.TrimSuffix(strings.TrimSpace(prefix), "/") + "/"
		if prefix != "/" && strings.HasPrefix(key, prefix) {
			return nil
		}
	}
	return errors.New("skill object key outside allowed prefixes")
}

func iconExtForMIME(mime string) string {
	switch strings.ToLower(strings.TrimSpace(mime)) {
	case "image/png":
		return ".png"
	case "image/jpeg", "image/jpg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	}
	return ""
}

// ParseSkillMDFrontmatter 拿一个 SKILL.md 原文，抽出最前面那段 YAML/JSON
// frontmatter（约定写法：---\n {...} \n---）。返回的是 frontmatter 原始字节，
// 由调用方按 YAML / JSON 自行解析。无 frontmatter 时返回 nil + nil。
//
// v0.9.1 实现：仅支持 JSON / 类 JSON frontmatter（最简）；YAML 留 v0.9.2。
func ParseSkillMDFrontmatter(md string) ([]byte, error) {
	md = strings.TrimLeft(md, "\ufeff \t\r\n")
	if !strings.HasPrefix(md, "---") {
		return nil, nil
	}
	rest := strings.TrimPrefix(md, "---")
	rest = strings.TrimLeft(rest, "\r\n")
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return nil, fmt.Errorf("frontmatter open without close")
	}
	return []byte(strings.TrimSpace(rest[:end])), nil
}

// parseZipFiles 把已经读入内存的 zip 字节解析成 ParsedFile 切片。
//
// 安全约束（spec §4.7 R1）：
//   - 文件数 ≤ maxParsedFiles（500）
//   - 解压总字节 ≤ maxParsedTotalBytes（50MB），防 zip-bomb
//   - 单文件 > maxFilePreviewBytes（1MB） → Truncated=true，content 留空
//   - 二进制（含 NUL 字节） → IsBinary=true，content 留空
//
// 不返回 zip 里的目录条目（FileInfo().IsDir()）；Path 保留原始 zip 内路径。
func parseZipFiles(buf []byte) ([]ParsedFile, error) {
	r, err := zip.NewReader(bytes.NewReader(buf), int64(len(buf)))
	if err != nil {
		return nil, fmt.Errorf("zip parse: %w", err)
	}
	out := make([]ParsedFile, 0, len(r.File))
	var totalBytes int64
	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		if len(out) >= maxParsedFiles {
			return nil, fmt.Errorf("zip too many files (>%d)", maxParsedFiles)
		}
		if int64(f.UncompressedSize64) > maxFilePreviewBytes && !looksLikeBinaryByExt(f.Name) {
			// 大文件即使是文本也不读全文；只记元信息。
			rc, openErr := f.Open()
			if openErr != nil {
				return nil, fmt.Errorf("zip open %s: %w", f.Name, openErr)
			}
			h := sha256.New()
			n, copyErr := io.Copy(h, io.LimitReader(rc, maxParsedTotalBytes-totalBytes+1))
			_ = rc.Close()
			if copyErr != nil {
				return nil, fmt.Errorf("zip read %s: %w", f.Name, copyErr)
			}
			totalBytes += n
			if totalBytes > maxParsedTotalBytes {
				return nil, fmt.Errorf("zip uncompressed total exceeds %d bytes", maxParsedTotalBytes)
			}
			out = append(out, ParsedFile{
				Path:        f.Name,
				SizeBytes:   n,
				SHA256:      hex.EncodeToString(h.Sum(nil)),
				ContentType: detectContentType(f.Name),
				Truncated:   true,
			})
			continue
		}

		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("zip open %s: %w", f.Name, err)
		}
		data, err := io.ReadAll(io.LimitReader(rc, maxFilePreviewBytes+1))
		_ = rc.Close()
		if err != nil {
			return nil, fmt.Errorf("zip read %s: %w", f.Name, err)
		}
		size := int64(len(data))
		truncated := false
		if size > maxFilePreviewBytes {
			data = data[:maxFilePreviewBytes]
			size = maxFilePreviewBytes
			truncated = true
		}
		totalBytes += size
		if totalBytes > maxParsedTotalBytes {
			return nil, fmt.Errorf("zip uncompressed total exceeds %d bytes", maxParsedTotalBytes)
		}
		sum := sha256.Sum256(data)
		isBinary := looksBinary(data)

		pf := ParsedFile{
			Path:        f.Name,
			SizeBytes:   size,
			SHA256:      hex.EncodeToString(sum[:]),
			ContentType: detectContentType(f.Name),
			IsBinary:    isBinary,
			Truncated:   truncated,
		}
		if !isBinary && !truncated {
			pf.ContentText = string(data)
		}
		out = append(out, pf)
	}
	return out, nil
}

// detectContentType 给 zip 内文件推断 MIME。
//
// 优先用代码内置映射（覆盖技能包里常见的 SKILL.md / py / yaml / json / sh 等），
// 其次 fallback 到 stdlib mime.TypeByExtension（不同 OS 行为不一致：macOS 默认
// 没有 .md/.yaml/.py 注册），最后无扩展名按 base name 兜底。
func detectContentType(name string) string {
	ext := strings.ToLower(path.Ext(name))
	if ct, ok := skillFileExtMime[ext]; ok {
		return ct
	}
	if ct := mime.TypeByExtension(ext); ct != "" {
		if i := strings.Index(ct, ";"); i > 0 {
			ct = strings.TrimSpace(ct[:i])
		}
		return ct
	}
	base := strings.ToLower(path.Base(name))
	switch base {
	case "dockerfile", "makefile", "license", "readme":
		return "text/plain"
	}
	return "application/octet-stream"
}

// skillFileExtMime 内置技能包高频文件类型 → MIME 映射，避免 stdlib 在不同 OS
// 行为漂移。值统一不带 charset 后缀。
var skillFileExtMime = map[string]string{
	".md":       "text/markdown",
	".markdown": "text/markdown",
	".txt":      "text/plain",
	".log":      "text/plain",
	".py":       "text/x-python",
	".js":       "application/javascript",
	".mjs":      "application/javascript",
	".ts":       "application/typescript",
	".jsx":      "text/jsx",
	".tsx":      "text/tsx",
	".json":     "application/json",
	".yaml":     "application/yaml",
	".yml":      "application/yaml",
	".toml":     "application/toml",
	".ini":      "text/plain",
	".cfg":      "text/plain",
	".conf":     "text/plain",
	".env":      "text/plain",
	".sh":       "application/x-sh",
	".bash":     "application/x-sh",
	".zsh":      "application/x-sh",
	".fish":     "application/x-sh",
	".html":     "text/html",
	".htm":      "text/html",
	".css":      "text/css",
	".xml":      "application/xml",
	".sql":      "application/sql",
	".csv":      "text/csv",
	".go":       "text/x-go",
	".java":     "text/x-java",
	".c":        "text/x-c",
	".h":        "text/x-c",
	".cpp":      "text/x-c++",
	".rs":       "text/x-rust",
	".rb":       "text/x-ruby",
	".php":      "application/x-php",
}

// looksBinary 通过前 8KB 是否含 NUL 字节判定，简单但有效。
func looksBinary(data []byte) bool {
	n := len(data)
	if n > 8192 {
		n = 8192
	}
	for i := 0; i < n; i++ {
		if data[i] == 0 {
			return true
		}
	}
	return false
}

// looksLikeBinaryByExt 用扩展名快速排除大概率是二进制的文件，避免大文件白扫。
func looksLikeBinaryByExt(name string) bool {
	ext := strings.ToLower(path.Ext(name))
	switch ext {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico",
		".pdf", ".zip", ".gz", ".tgz", ".tar", ".bz2", ".7z", ".rar",
		".exe", ".dll", ".so", ".dylib", ".bin", ".class", ".jar",
		".mp3", ".mp4", ".mov", ".avi", ".wav", ".ogg", ".flac",
		".woff", ".woff2", ".ttf", ".otf", ".eot":
		return true
	}
	return false
}
