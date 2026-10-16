// Package fs 实现 OpenClaw 容器内文件系统操作的薄抽象 (Batch 2C T2C.1.D)。
//
// 来源: 移植 legacy `openclawagentapp.dockerWriteFiles` (tar 流写) +
// `removeDirInOpenClaw` (安全删)。
//
// 设计要点:
//
//   - **WriteFiles 用单次 tar 流**: legacy 经验 14+ 次单文件 docker exec 启动开销让
//     CreateAgent 慢到 ~14s; 改 tar 后降到 ~1s。tar header 用 PAX 格式 (支持长路径)。
//   - **RemoveDir 强制前缀校验**: 必须在 /data/.openclaw 下, 防止 caller 误传 / 或
//     被 LFI-style 利用 (虽然 caller 都是内部代码, 仍兜底; 与 legacy
//     `looksLikeAgentDir` 同款)。
//   - **K8s 实现**: 本批 stub, 返回 ErrNotImplementedK8sFS; 接口签名保留, 后续 batch
//     用 k8scli.WriteFilesInPod / ExecInPod rm -rf。
package fs

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// FileWrite 一次写入操作的目标 (绝对路径 + 字节内容)。
type FileWrite struct {
	AbsPath string // 容器内绝对路径, 必须以 / 开头
	Data    []byte
}

// FS 是 OpenClaw 容器内 fs 操作的抽象。
type FS interface {
	// WriteFiles 批量写多份文件到容器内 (tar 流, 一次 round-trip)。
	// 任一目标的 AbsPath 不是绝对路径 -> 返回错误, 不写任何文件。
	WriteFiles(ctx context.Context, writes []FileWrite) error

	// RemoveDir 删除容器内指定绝对路径 (rm -rf)。
	// 必须在 /data/.openclaw 内, 否则返回 ErrUnsafePath。
	RemoveDir(ctx context.Context, absPath string) error
}

// SafePathPrefix WriteFiles 允许操作的路径前缀 (与 legacy 一致)。
const SafePathPrefix = "/data/.openclaw/"

// ErrUnsafePath 收到的路径不满足 OpenClaw 数据目录校验。
var ErrUnsafePath = errors.New("openclaw fs: refused to remove path outside /data/.openclaw/")

// ErrNotImplementedK8sFS K8s 模式 fs 操作在 Batch 2C 未实现。
var ErrNotImplementedK8sFS = errors.New("openclaw fs: K8s fs ops not implemented in Batch 2C")

// LocalFS 本机 docker exec 实现 (Batch 2C 主路径)。
type LocalFS struct {
	ContainerName string
}

// NewLocalFS 构造 local 模式 FS。containerName 为空时默认 "openclaw"。
func NewLocalFS(containerName string) *LocalFS {
	c := strings.TrimSpace(containerName)
	if c == "" {
		c = "openclaw"
	}
	return &LocalFS{ContainerName: c}
}

// WriteFiles 通过 `docker exec -i <container> sh -c 'tar -xpf - -C /'` 批量写。
// tar 文件路径相对 /, 自动建中间目录。
//
// **安全前缀强制**: 每条 AbsPath 必须满足 IsSafePath (在 SafePathPrefix 下且不含 ..);
// 拒绝 /etc / /data/other / /data/.openclaw/../etc 等 -> ErrUnsafePath。
// 防 caller 误传 / LFI 写到容器内任意路径。
func (f *LocalFS) WriteFiles(ctx context.Context, writes []FileWrite) error {
	if len(writes) == 0 {
		return nil
	}
	for i, w := range writes {
		if w.AbsPath == "" || !strings.HasPrefix(w.AbsPath, "/") {
			return fmt.Errorf("openclaw fs: writes[%d].AbsPath must be absolute, got %q", i, w.AbsPath)
		}
		if !IsSafePath(w.AbsPath) {
			return fmt.Errorf("openclaw fs: writes[%d].AbsPath %q: %w", i, w.AbsPath, ErrUnsafePath)
		}
	}

	buf, err := buildTar(writes)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, "docker", "exec", "-i", f.ContainerName,
		"sh", "-c", "tar -xpf - -C /")
	cmd.Stdin = bytes.NewReader(buf)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("openclaw fs WriteFiles: %w (stderr=%s)", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// RemoveDir 通过 `docker exec <container> rm -rf <path>`, 必须在 OpenClaw 数据目录内。
func (f *LocalFS) RemoveDir(ctx context.Context, absPath string) error {
	if !IsSafeRemovePath(absPath) {
		return ErrUnsafePath
	}
	cmd := exec.CommandContext(ctx, "docker", "exec", f.ContainerName, "rm", "-rf", absPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("openclaw fs RemoveDir %s: %w (stderr=%s)", absPath, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// IsSafePath 检查写入路径是否在 SafePathPrefix 下且不含 .. 上跳。
// 写入仍拒绝精确等于 /data/.openclaw，避免把目录当文件写。
func IsSafePath(absPath string) bool {
	if !strings.HasPrefix(absPath, SafePathPrefix) {
		return false
	}
	// 拒绝 .. 上跳 (即使 clean 后仍可能落到 prefix 内, 但宁可拒绝)
	if strings.Contains(absPath, "..") {
		return false
	}
	// 拒绝精确等于 prefix (避免 rm -rf /data/.openclaw/ 把整个 OpenClaw 数据干掉)
	if filepath.Clean(absPath) == filepath.Clean(SafePathPrefix) {
		return false
	}
	return true
}

// IsSafeRemovePath 检查删除路径是否在 OpenClaw 数据目录内。
// 删除允许精确清理 /data/.openclaw，这是实例销毁前的受控运维动作。
func IsSafeRemovePath(absPath string) bool {
	if absPath == "" || strings.Contains(absPath, "..") {
		return false
	}
	clean := filepath.Clean(absPath)
	root := filepath.Clean(SafePathPrefix)
	return clean == root || strings.HasPrefix(clean+"/", SafePathPrefix)
}

// buildTar 把多个 FileWrite 打成 in-memory tar (PAX 格式)。
func buildTar(writes []FileWrite) ([]byte, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	now := time.Now()
	for _, w := range writes {
		clean := filepath.Clean(w.AbsPath)
		rel := strings.TrimPrefix(clean, "/")
		hdr := &tar.Header{
			Name:    rel,
			Mode:    0644,
			Size:    int64(len(w.Data)),
			ModTime: now,
			Format:  tar.FormatPAX,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, fmt.Errorf("tar write header %s: %w", w.AbsPath, err)
		}
		if _, err := tw.Write(w.Data); err != nil {
			return nil, fmt.Errorf("tar write body %s: %w", w.AbsPath, err)
		}
	}
	if err := tw.Close(); err != nil {
		return nil, fmt.Errorf("tar close: %w", err)
	}
	return buf.Bytes(), nil
}

// K8sFS 是 K8s 模式预留 (本批 2C 未实现)。
type K8sFS struct{}

// NewK8sFS 构造 K8s 预留实现。
func NewK8sFS() *K8sFS { return &K8sFS{} }

func (K8sFS) WriteFiles(ctx context.Context, writes []FileWrite) error {
	return ErrNotImplementedK8sFS
}
func (K8sFS) RemoveDir(ctx context.Context, absPath string) error {
	return ErrNotImplementedK8sFS
}
