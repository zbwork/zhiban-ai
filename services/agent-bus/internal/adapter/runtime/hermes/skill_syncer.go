// skill_syncer.go -- Hermes controlplane.SkillSyncer implementation.
//
// Follows the same install/uninstall pattern as the OpenClaw skill syncer:
//  1. Fetch package via controlled fetcher (OSS key, not arbitrary URL);
//  2. SHA256 verification (mismatch = terminal, no partial install);
//  3. Unzip -> WorkspaceFile with zip-slip defense + unpacked size limit;
//  4. Write via WorkspaceWriter to /opt/data/skills/<slug>/.
//
// Uninstall removes /opt/data/skills/<slug>/ via WorkspaceRemover.
package hermes

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"path"
	"regexp"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/controlplane"
)

// maxSkillUnpackedBytes caps total unpacked size to defend against zip bombs.
const maxSkillUnpackedBytes = 4 * 52428800 // 200 MiB

// skillSlugRe restricts skill slugs to safe single-path segments: starts with
// alphanumeric, followed by alphanumeric/._-, length 1..128. This inherently
// excludes "", ".", "..", and values containing "/" or "\".
var skillSlugRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// hermesSkillSyncer implements controlplane.SkillSyncer for Hermes.
type hermesSkillSyncer struct {
	workspace    controlplane.WorkspaceWriter
	remover      controlplane.WorkspaceRemover
	fetchPackage func(ctx context.Context, packageKey string) ([]byte, error)
}

// InstallSkill fetches the skill package, verifies SHA256, unzips it, and writes
// the files to <WorkspacePath>/skills/<slug>/ on the target instance.
func (s *hermesSkillSyncer) InstallSkill(ctx context.Context, target controlplane.InstanceTarget, spec controlplane.SkillSpec) error {
	if s.workspace == nil {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_workspace_writer_not_wired"}
	}
	if s.fetchPackage == nil {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_package_fetcher_not_wired"}
	}
	if strings.TrimSpace(spec.WorkspacePath) == "" {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_spec_incomplete"}
	}
	if !skillSlugRe.MatchString(spec.Slug) {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_slug_invalid"}
	}
	if strings.TrimSpace(spec.PackageKey) == "" {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_package_key_empty"}
	}

	// 1) Fetch package via controlled fetcher (OSS key; not arbitrary URL).
	data, err := s.fetchPackage(ctx, spec.PackageKey)
	if err != nil {
		if controlplane.IsRetryable(err) || isSyncError(err) {
			return err
		}
		return &controlplane.SyncError{Retryable: true, Reason: "skill_package_fetch", Cause: err}
	}

	// 2) SHA256 verification (mismatch = terminal, no partial install).
	if h := strings.TrimSpace(spec.SHA256); h != "" {
		sum := sha256.Sum256(data)
		if !strings.EqualFold(hex.EncodeToString(sum[:]), h) {
			return &controlplane.SyncError{Retryable: false, Reason: "skill_package_sha256_mismatch"}
		}
	}

	// 3) Unzip -> WorkspaceFile (zip-slip defense + unpacked size limit).
	root := path.Join(spec.WorkspacePath, "skills", spec.Slug)
	files, err := unzipToWorkspaceFiles(data, root)
	if err != nil {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_package_unzip", Cause: err}
	}
	if len(files) == 0 {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_package_empty"}
	}

	// 4) Write via WorkspaceWriter (paths further constrained by /opt/data/ safety prefix).
	if err := s.workspace.WriteWorkspace(ctx, target, files); err != nil {
		if controlplane.IsRetryable(err) || isSyncError(err) {
			return err
		}
		return &controlplane.SyncError{Retryable: true, Reason: "skill_workspace_write", Cause: err}
	}
	return nil
}

// UninstallSkill removes <WorkspacePath>/skills/<slug>/ from the target instance.
// Idempotent: directory not existing is treated as success by the remover.
func (s *hermesSkillSyncer) UninstallSkill(ctx context.Context, target controlplane.InstanceTarget, spec controlplane.SkillUninstallSpec) error {
	if s.remover == nil {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_remover_not_wired"}
	}
	if strings.TrimSpace(spec.WorkspacePath) == "" {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_spec_incomplete"}
	}
	if !skillSlugRe.MatchString(spec.Slug) {
		return &controlplane.SyncError{Retryable: false, Reason: "skill_slug_invalid"}
	}
	dir := path.Join(spec.WorkspacePath, "skills", spec.Slug)
	if err := s.remover.RemoveDir(ctx, target, dir); err != nil {
		if controlplane.IsRetryable(err) || isSyncError(err) {
			return err
		}
		return &controlplane.SyncError{Retryable: true, Reason: "skill_remove", Cause: err}
	}
	return nil
}

// unzipToWorkspaceFiles unzips data into WorkspaceFile entries rooted at root.
// It defends against zip-slip (entry paths escaping root) and limits total
// unpacked size to maxSkillUnpackedBytes.
func unzipToWorkspaceFiles(data []byte, root string) ([]controlplane.WorkspaceFile, error) {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	rootPrefix := strings.TrimRight(root, "/") + "/"
	var out []controlplane.WorkspaceFile
	var total int64
	for _, f := range zr.File {
		name := f.Name
		if name == "" || strings.HasSuffix(name, "/") {
			continue // skip directory entries
		}
		// Zip-slip defense: cleaned path must stay under root.
		abs := path.Join(root, name)
		if abs != strings.TrimRight(root, "/") && !strings.HasPrefix(abs, rootPrefix) {
			return nil, fmt.Errorf("skill package: entry %q escapes install dir", name)
		}
		rc, oerr := f.Open()
		if oerr != nil {
			return nil, oerr
		}
		total += int64(f.UncompressedSize64)
		if total > maxSkillUnpackedBytes {
			rc.Close()
			return nil, fmt.Errorf("skill package: unpacked size exceeds %d bytes", maxSkillUnpackedBytes)
		}
		body, rerr := io.ReadAll(io.LimitReader(rc, maxSkillUnpackedBytes+1))
		rc.Close()
		if rerr != nil {
			return nil, rerr
		}
		out = append(out, controlplane.WorkspaceFile{AbsPath: abs, Data: body})
	}
	return out, nil
}
