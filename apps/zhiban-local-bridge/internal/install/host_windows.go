//go:build windows

package install

// Claude Code host component on Windows (M3-W). Claude Desktop keeps it as a
// bare executable: %LOCALAPPDATA%\Claude-3p\claude-code\<version>\claude.exe,
// next to .payload ({"sha256": <exe>, "size": <bytes>}) and .verified holding
// the checksum of the claude.exe.zst stream the app would have downloaded.
// The Bridge decompresses the official stream (or extracts the npmmirror
// tarball's executable), checks Anthropic's Authenticode signature on it in a
// hidden staging folder, then renames it into the version directory and
// writes both markers — exactly the layout that made the app log
// "[CCD] Initialized with version 2.1.260" on the test machine.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

type hostPayload struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

func (m *Manager) placeHostPlatform(ctx context.Context, storage, staging *os.File, component componentPlan, archive *os.File, source Source) (bool, error) {
	stagingPath := staging.Name()
	var payload hostPayload
	derived := false
	switch source.Layout {
	case LayoutHostBinaryZst:
		digest, size, err := claudecode.ExtractHostBinaryZst(ctx, archive, stagingPath)
		if err != nil {
			if ctx.Err() != nil {
				return true, ctx.Err()
			}
			return true, errArchiveInvalid
		}
		payload = hostPayload{SHA256: digest, Size: size}
	case LayoutHostBinaryNPMTgz:
		pin, ok := m.hostPinFor(component, source)
		if !ok || (!pin.Derived && !sha256Pattern.MatchString(pin.BinarySHA256)) {
			return true, errArchiveInvalid
		}
		if err := m.bundleTools.ExtractHostBinary(ctx, archive, stagingPath, pin.BinarySize, pin.BinarySHA256); err != nil {
			if ctx.Err() != nil {
				return true, ctx.Err()
			}
			return true, errArchiveInvalid
		}
		payload = hostPayload{SHA256: pin.BinarySHA256, Size: pin.BinarySize}
		if pin.Derived {
			// No pinned executable hash: record what was extracted (checked by
			// signature and version below).
			digest, size, err := fileSHA256(filepath.Join(stagingPath, claudecode.NPMBinaryName))
			if err != nil {
				return true, errArchiveInvalid
			}
			payload = hostPayload{SHA256: digest, Size: size}
		}
		derived = pin.Derived
	default:
		return true, ErrInvalidManifest
	}
	executable := filepath.Join(stagingPath, claudecode.NPMBinaryName)
	if err := m.bundleTools.VerifyBundle(ctx, executable, claudecode.HostSignatureRequirement()); err != nil {
		if ctx.Err() != nil {
			return true, ctx.Err()
		}
		return true, errPublisherMismatch
	}
	if derived {
		if err := m.checkHostVersion(ctx, executable, component.manifest.Version); err != nil {
			if ctx.Err() != nil {
				return true, ctx.Err()
			}
			return true, errPublisherMismatch
		}
	}

	version := component.manifest.Version
	if err := secureMkdirAt(int(storage.Fd()), version, 0o700); err != nil && !errors.Is(err, syscall.EEXIST) {
		return true, mapPathError(err)
	}
	versionFD, err := secureOpenDirectoryAt(int(storage.Fd()), version)
	if err != nil {
		return true, mapPathError(err)
	}
	versionDir := os.NewFile(uintptr(versionFD), filepath.Join(storage.Name(), version))
	if versionDir == nil {
		_ = secureClose(versionFD)
		return true, errUnsafePath
	}
	defer versionDir.Close()
	if err := validateDirectory(versionDir); err != nil {
		return true, err
	}
	// Whatever a previous attempt (the app's own, or ours) left is moved
	// aside first and restored if anything fails; the markers are rewritten.
	asides := map[string]string{}
	rollback := func() {
		for name, aside := range asides {
			m.restoreAside(versionDir, aside, name)
		}
		_ = secureFsync(int(versionDir.Fd()))
	}
	for _, name := range []string{claudecode.NPMBinaryName, claudecode.PayloadName} {
		aside, err := moveAsideAt(versionDir, name)
		if aside != "" {
			asides[name] = aside
		}
		if err != nil {
			rollback()
			return true, err
		}
	}
	if err := secureUnlinkAt(int(versionDir.Fd()), claudecode.VerifiedName()); err != nil && !errors.Is(err, syscall.ENOENT) {
		rollback()
		return true, mapPathError(err)
	}
	if err := renameHostExecutable(ctx, staging, versionDir, 30*time.Second); err != nil {
		rollback()
		if pathHeldByAnotherProcess(err) {
			return true, operation.Fail(installCode(TargetClaudeDesktop, "COMPONENT_IN_USE"), err)
		}
		if errors.Is(err, syscall.EEXIST) {
			return true, errConflict
		}
		return true, mapPathError(err)
	}
	unplace := func() {
		_ = secureRenameExclusiveAt(int(versionDir.Fd()), claudecode.NPMBinaryName, int(staging.Fd()), claudecode.NPMBinaryName)
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		unplace()
		rollback()
		return true, err
	}
	if err := writeRegularAt(versionDir, claudecode.PayloadName, strings.NewReader(string(encoded)), int64(len(encoded)), 0o644, ""); err != nil {
		unplace()
		rollback()
		return true, err
	}
	checksum := component.artifact.Checksum
	if err := writeRegularAt(versionDir, claudecode.VerifiedName(), strings.NewReader(checksum), int64(len(checksum)), 0o644, ""); err != nil {
		_ = secureUnlinkAt(int(versionDir.Fd()), claudecode.PayloadName)
		unplace()
		rollback()
		return true, err
	}
	for _, aside := range asides {
		_ = os.RemoveAll(filepath.Join(versionDir.Name(), aside))
	}
	_ = secureFsync(int(versionDir.Fd()))
	return true, nil
}

// A freshly verified/version-probed executable can remain briefly held by
// Windows or an on-access scanner. Retry only sharing/access failures; never
// replace an existing target or relax secureRenameExclusiveAt path checks.
func renameHostExecutable(ctx context.Context, staging, versionDir *os.File, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := secureRenameExclusiveAt(int(staging.Fd()), claudecode.NPMBinaryName, int(versionDir.Fd()), claudecode.NPMBinaryName)
		if !pathHeldByAnotherProcess(err) || !time.Now().Before(deadline) {
			return err
		}
		timer := time.NewTimer(200 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
