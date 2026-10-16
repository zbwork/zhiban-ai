//go:build darwin

package install

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	bundleExtractTimeout = 10 * time.Minute
	bundleVerifyTimeout  = 5 * time.Minute
	bundleAssessTimeout  = 2 * time.Minute
	bundleInUseTimeout   = 10 * time.Second
	maxToolOutputBytes   = 64 << 10
)

// defaultBundleTools uses the fixed system tools; every argument is either a
// literal or a path the Bridge computed itself.
func defaultBundleTools() BundleTools {
	return BundleTools{
		ExtractZip:   dittoExtract,
		ExtractDMG:   hdiutilExtract,
		VerifyBundle: codesignVerifyRequirement,
		AssessBundle: spctlAssess,
		BundleInUse:  processRunsInsideBundle,
	}
}

func runTool(ctx context.Context, timeout time.Duration, executable string, arguments ...string) ([]byte, error) {
	toolContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command := exec.CommandContext(toolContext, executable, arguments...)
	command.Env = []string{"LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
	var stdout, stderr limitedBuffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		if toolContext.Err() != nil {
			err = fmt.Errorf("系统工具超时或取消（限时 %s）: %w", timeout, toolContext.Err())
		}
		return stdout.Bytes(), nativeToolFailure(filepath.Base(executable), err, string(stderr.Bytes()), arguments)
	}
	return stdout.Bytes(), nil
}

// dittoExtract unpacks a zip archive the way Finder does, preserving symlinks,
// permissions, extended attributes and resource forks of the bundle.
func dittoExtract(ctx context.Context, zipPath, destinationDir string) error {
	_, err := runTool(ctx, bundleExtractTimeout, "/usr/bin/ditto", "-x", "-k", zipPath, destinationDir)
	return err
}

// hdiutilExtract mounts a disk image read-only at a private mount point inside
// the (0700) staging folder, copies the named bundle out with ditto and
// detaches the image again. -noverify skips hdiutil's own checksum pass: the
// download was already checked against the pinned size and SHA-256.
func hdiutilExtract(ctx context.Context, dmgPath, destinationDir string, bundleNames []string) error {
	mountPoint := filepath.Join(destinationDir, ".mnt")
	if err := os.Mkdir(mountPoint, 0o700); err != nil {
		return err
	}
	if _, err := runTool(ctx, bundleExtractTimeout, "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
		"-mountpoint", mountPoint, dmgPath); err != nil {
		_ = os.Remove(mountPoint)
		return err
	}
	defer func() {
		_, _ = runTool(context.Background(), bundleAssessTimeout, "/usr/bin/hdiutil", "detach", mountPoint, "-force")
		_ = os.Remove(mountPoint)
	}()
	bundleName := ""
	for _, candidate := range bundleNames {
		info, err := os.Lstat(filepath.Join(mountPoint, candidate))
		if err != nil || !info.IsDir() {
			continue
		}
		if bundleName != "" {
			return errArchiveInvalid
		}
		bundleName = candidate
	}
	if bundleName == "" {
		return errArchiveInvalid
	}
	source := filepath.Join(mountPoint, bundleName)
	_, err := runTool(ctx, bundleExtractTimeout, "/usr/bin/ditto", source, filepath.Join(destinationDir, bundleName))
	return err
}

// codesignVerifyRequirement validates the whole bundle (nested code included)
// and checks the designated requirement.
func codesignVerifyRequirement(ctx context.Context, bundlePath, requirement string) error {
	_, err := runTool(ctx, bundleVerifyTimeout, "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2",
		"--test-requirement", "="+requirement, bundlePath)
	return err
}

// spctlAssess asks Gatekeeper whether the bundle may execute.
func spctlAssess(ctx context.Context, bundlePath string) error {
	_, err := runTool(ctx, bundleAssessTimeout, "/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", bundlePath)
	return err
}

// processRunsInsideBundle scans the process table for an executable inside the
// bundle. macOS prints the full executable path in the comm column.
func processRunsInsideBundle(bundlePath string) (bool, error) {
	output, err := runTool(context.Background(), bundleInUseTimeout, "/bin/ps", "-axo", "comm=")
	if err != nil {
		return false, err
	}
	return bundleListedInProcesses(output, bundlePath), nil
}

// bundleListedInProcesses reports whether a `ps -axo comm=` listing holds a
// process that really keeps the app alive: an executable in Contents/MacOS/,
// or Squirrel's ShipIt, which swaps the bundle after the app has quit.
//
// Everything else inside the bundle is ignored on purpose. Helper processes
// outlive the application: Chrome keeps Claude Desktop's native messaging host
// running while Claude is closed (2026-09-15), and Codex Desktop leaves
// crash-reporter helpers under Contents/Frameworks/…/Helpers/ behind for hours
// (2026-09-16, a tester whose upgrade reported TARGET_IN_USE with ChatGPT
// quit). Replacing a bundle under such a helper is what the publishers' own
// updaters do; refusing the upgrade left users with no way out.
func bundleListedInProcesses(output []byte, bundlePath string) bool {
	root := filepath.Clean(bundlePath)
	executables := root + "/Contents/MacOS/"
	frameworks := root + "/Contents/Frameworks/"
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		executable := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(executable, executables) {
			return true
		}
		if strings.HasPrefix(executable, frameworks) && strings.Contains(executable, "ShipIt") {
			return true
		}
	}
	return false
}

// limitedBuffer keeps at most maxToolOutputBytes of a tool's output.
type limitedBuffer struct {
	buffer bytes.Buffer
}

func (b *limitedBuffer) Write(data []byte) (int, error) {
	remaining := maxToolOutputBytes - b.buffer.Len()
	if remaining > 0 {
		if len(data) > remaining {
			b.buffer.Write(data[:remaining])
		} else {
			b.buffer.Write(data)
		}
	}
	return len(data), nil
}

func (b *limitedBuffer) Bytes() []byte { return b.buffer.Bytes() }

var _ io.Writer = (*limitedBuffer)(nil)
