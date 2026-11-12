package localcodingcatalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// npm source of the CLI auto sync (plan §2.2). The mirror is not trusted: a
// package document counts only when the npm registry's own signature over
// name@version:integrity verifies, and the tarball only when it hashes to
// that integrity. Same scheme and key as the Bridge's derived host pin
// (apps/zhiban-local-bridge/internal/install/host_npm_derived.go).

const (
	// DefaultAutoSyncRegistry mirrors npm's documents including signatures
	// and is reachable from mainland China.
	DefaultAutoSyncRegistry = "https://registry.npmmirror.com"

	npmDocumentMaxBytes = 1 << 20
	npmTarballMaxBytes  = 512 << 20
	npmDocumentTimeout  = 20 * time.Second
	npmIntegrityPrefix  = "sha512-"
)

// defaultAutoSyncDownloadHosts are where the mirror's tarball address may
// redirect to, next to the registry host itself.
var defaultAutoSyncDownloadHosts = []string{"cdn.npmmirror.com"}

// DefaultNPMRegistryKeys are the npm registry's package signing keys by key
// id (https://registry.npmjs.org/-/npm/v1/keys, fetched 2026-09-15; the key
// with no expiry).
func DefaultNPMRegistryKeys() map[string]string {
	return map[string]string{
		"SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+HOKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g==",
	}
}

// npmTagDocument is what /<package>/<tag> answers. publish_time is a mirror
// extension (milliseconds) and is not signed; it only feeds the soak period.
type npmTagDocument struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	PublishTime int64  `json:"publish_time"`
}

type npmPackageDocument struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Dist    struct {
		Tarball    string `json:"tarball"`
		Integrity  string `json:"integrity"`
		Size       int64  `json:"size"`
		Signatures []struct {
			KeyID string `json:"keyid"`
			Sig   string `json:"sig"`
		} `json:"signatures"`
	} `json:"dist"`
}

// npmPackage is a verified package version: where its tarball is and what
// it must hash to.
type npmPackage struct {
	tarball string
	size    int64
	sha512  []byte
}

type npmSource struct {
	registry string
	client   *http.Client
	keys     map[string]string
}

// newNPMSource derives a client from base that refuses to leave the registry
// and its download hosts, also across redirects.
func newNPMSource(base *http.Client, registry string, downloadHosts []string, keys map[string]string) (*npmSource, error) {
	registry = strings.TrimRight(strings.TrimSpace(registry), "/")
	parsed, err := url.Parse(registry)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return nil, errors.New("auto sync registry must be an https origin")
	}
	allowed := map[string]struct{}{parsed.Hostname(): {}}
	for _, host := range downloadHosts {
		if host = strings.ToLower(strings.TrimSpace(host)); host != "" {
			allowed[host] = struct{}{}
		}
	}
	client := *base
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if _, ok := allowed[strings.ToLower(request.URL.Hostname())]; !ok || request.URL.Scheme != "https" {
			return fmt.Errorf("redirect to %s is outside the allow list", request.URL.Host)
		}
		return nil
	}
	return &npmSource{registry: registry, client: &client, keys: keys}, nil
}

// tagVersion resolves a dist-tag to its version and the mirror's publish time
// (zero when the mirror does not report one).
func (n *npmSource) tagVersion(ctx context.Context, pkg, tag string) (string, time.Time, error) {
	var doc npmTagDocument
	if err := n.getJSON(ctx, n.registry+"/"+pkg+"/"+tag, &doc); err != nil {
		return "", time.Time{}, err
	}
	if doc.Name != pkg || strings.TrimSpace(doc.Version) == "" {
		return "", time.Time{}, errors.New("标签文档与包名不符")
	}
	var published time.Time
	if doc.PublishTime > 0 {
		published = time.UnixMilli(doc.PublishTime)
	}
	return doc.Version, published, nil
}

// packageVersion fetches and verifies one package version document.
func (n *npmSource) packageVersion(ctx context.Context, name, version string) (*npmPackage, error) {
	var doc npmPackageDocument
	if err := n.getJSON(ctx, n.registry+"/"+name+"/"+version, &doc); err != nil {
		return nil, err
	}
	if doc.Name != name || doc.Version != version {
		return nil, errors.New("包文档与请求的包名 / 版本不符")
	}
	if doc.Dist.Tarball != npmTarballURL(n.registry, name, version) {
		return nil, errors.New("包文档里的下载地址不是该版本的规范地址")
	}
	if doc.Dist.Size <= 0 || doc.Dist.Size > npmTarballMaxBytes {
		return nil, fmt.Errorf("包文档声明的大小 %d 不在允许范围内", doc.Dist.Size)
	}
	if !strings.HasPrefix(doc.Dist.Integrity, npmIntegrityPrefix) {
		return nil, errors.New("包文档缺少 sha512 完整性值")
	}
	digest, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(doc.Dist.Integrity, npmIntegrityPrefix))
	if err != nil || len(digest) != sha512.Size {
		return nil, errors.New("包文档的 sha512 完整性值无效")
	}
	message := sha256.Sum256([]byte(name + "@" + version + ":" + doc.Dist.Integrity))
	signed := false
	for _, signature := range doc.Dist.Signatures {
		encoded, ok := n.keys[signature.KeyID]
		if !ok {
			continue
		}
		public, err := parseNPMPublicKey(encoded)
		if err != nil {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(signature.Sig)
		if err != nil {
			continue
		}
		if ecdsa.VerifyASN1(public, message[:], raw) {
			signed = true
			break
		}
	}
	if !signed {
		return nil, errors.New("npm 官方签名校验未通过")
	}
	return &npmPackage{tarball: doc.Dist.Tarball, size: doc.Dist.Size, sha512: digest}, nil
}

// npmTarballURL is the canonical tarball address of a (scoped) package version.
func npmTarballURL(registry, name, version string) string {
	base := name[strings.LastIndex(name, "/")+1:]
	return registry + "/" + name + "/-/" + base + "-" + version + ".tgz"
}

func parseNPMPublicKey(encoded string) (*ecdsa.PublicKey, error) {
	der, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	public, ok := parsed.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("not an ECDSA key")
	}
	return public, nil
}

func (n *npmSource) getJSON(ctx context.Context, rawURL string, into any) error {
	ctx, cancel := context.WithTimeout(ctx, npmDocumentTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return errors.New("镜像站地址无效")
	}
	request.Header.Set("User-Agent", "agent-bus/local-coding-autosync")
	request.Header.Set("Accept", "application/json")
	response, err := n.client.Do(request)
	if err != nil {
		return errors.New("读取镜像站失败：" + err.Error())
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("镜像站返回 HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, npmDocumentMaxBytes+1))
	if err != nil {
		return errors.New("读取镜像站失败：" + err.Error())
	}
	if len(body) > npmDocumentMaxBytes {
		return errors.New("镜像站文档过大")
	}
	if err := json.Unmarshal(body, into); err != nil {
		return errors.New("镜像站文档不是有效 JSON")
	}
	return nil
}

// downloaded is a verified tarball in the temp dir.
type downloaded struct {
	file   *os.File
	size   int64
	sha256 string
}

func (d *downloaded) Close() {
	name := d.file.Name()
	_ = d.file.Close()
	_ = os.Remove(name)
}

// download spools the tarball and accepts it only at the declared size and
// the signed sha512; the SHA-256 it returns is of those same bytes.
func (n *npmSource) download(ctx context.Context, pkg *npmPackage) (*downloaded, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, pkg.tarball, nil)
	if err != nil {
		return nil, errors.New("下载地址无效")
	}
	request.Header.Set("User-Agent", "agent-bus/local-coding-autosync")
	request.Header.Set("Accept", "application/octet-stream")
	response, err := n.client.Do(request)
	if err != nil {
		return nil, errors.New("下载失败：" + err.Error())
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("下载失败：来源返回 HTTP %d", response.StatusCode)
	}
	file, err := os.CreateTemp("", "local-coding-autosync-*")
	if err != nil {
		return nil, errors.New("临时文件创建失败：" + err.Error())
	}
	result := &downloaded{file: file}
	strong, plain := sha512.New(), sha256.New()
	// One byte past the declared size catches a body longer than dist.size.
	written, err := io.Copy(io.MultiWriter(file, strong, plain), io.LimitReader(response.Body, pkg.size+1))
	if err != nil {
		result.Close()
		return nil, errors.New("下载失败：" + err.Error())
	}
	if written != pkg.size {
		result.Close()
		return nil, fmt.Errorf("下载到 %d 字节，与包文档声明的大小 %d 不符", written, pkg.size)
	}
	if !bytes.Equal(strong.Sum(nil), pkg.sha512) {
		result.Close()
		return nil, errors.New("下载内容与签名过的完整性值（sha512）不符")
	}
	result.size, result.sha256 = written, hex.EncodeToString(plain.Sum(nil))
	return result, nil
}

// memberSHA256 hashes one regular file of the gzip tarball without writing
// anything to disk, so archive paths never reach the file system.
func (d *downloaded) memberSHA256(member string) (string, error) {
	if _, err := d.file.Seek(0, io.SeekStart); err != nil {
		return "", errors.New("临时文件读取失败：" + err.Error())
	}
	zipped, err := gzip.NewReader(d.file)
	if err != nil {
		return "", errors.New("包不是有效的 gzip")
	}
	defer zipped.Close()
	archive := tar.NewReader(zipped)
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			return "", fmt.Errorf("包里没有可执行文件 %s", member)
		}
		if err != nil {
			return "", errors.New("包不是有效的 tar")
		}
		if header.Name != member {
			continue
		}
		if header.Typeflag != tar.TypeReg || header.Size <= 0 {
			return "", fmt.Errorf("包里的可执行文件 %s 不是普通文件", member)
		}
		hasher := sha256.New()
		if _, err := io.Copy(hasher, io.LimitReader(archive, header.Size)); err != nil {
			return "", errors.New("读取可执行文件失败：" + err.Error())
		}
		return hex.EncodeToString(hasher.Sum(nil)), nil
	}
}
