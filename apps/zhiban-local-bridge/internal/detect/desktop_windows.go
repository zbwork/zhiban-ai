//go:build windows

package detect

// Desktop targets on Windows (M3-W). Both applications are app packages the
// OS registers per user; the registry lists every registered package full
// name under the user's package repository together with its root folder
// (C:\Program Files\WindowsApps\<PackageFullName>). A package is the target
// when its identity — Name plus the publisher id Windows derives from the
// signing certificate — matches the locked facts; the OS already verified
// the signature at registration. The version is the release the publisher
// names (the first three parts of the four-part package version).

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/appx"
)

const (
	packageRepositoryKey = `Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages`
	packageRootValue     = "PackageRootFolder"
	maxRegistryKeyName   = 512
	// errorNoMoreItems is ERROR_NO_MORE_ITEMS, which package syscall does not name.
	errorNoMoreItems = syscall.Errno(259)
)

// windowsPackageSpec is the identity of one distribution of a desktop target.
type windowsPackageSpec struct {
	Name        string
	PublisherID string
}

// desktopPackages are build-time facts (M3 plan §10, read from the packages
// on 2026-09-10). Claude Desktop is published both as Anthropic's own MSIX
// (sideloaded, DigiCert code-signing certificate) and through the Store; the
// Codex desktop on Windows is the ChatGPT app.
var desktopPackages = map[string][]windowsPackageSpec{
	TargetClaudeDesktop: {
		{Name: "Claude", PublisherID: "pzs8sxrjxfjjc"},
		{Name: "AnthropicPBC.Claude", PublisherID: "fnn82j28hfe8t"},
	},
	TargetCodexDesktop: {
		{Name: "OpenAI.Codex", PublisherID: "2p2nqsd0c76g0"},
	},
}

func packageMatches(targetID string, full appx.FullName) bool {
	for _, spec := range desktopPackages[targetID] {
		if full.Name == spec.Name && full.PublisherID == spec.PublisherID {
			return true
		}
	}
	return false
}

// discoverPackages lists the registered packages that implement a desktop target.
func (d *WindowsDiscoverer) discoverPackages(targetID string) ([]Candidate, error) {
	if _, ok := desktopPackages[targetID]; !ok {
		return nil, ErrUnsupportedTarget
	}
	names, roots, err := enumeratePackageRepository()
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return nil, nil
		}
		return nil, err
	}
	hostArch := HostArch()
	seen := map[string]struct{}{}
	candidates := make([]Candidate, 0, 1)
	for index, name := range names {
		full, ok := appx.ParseFullName(name)
		if !ok || !packageMatches(targetID, full) || full.Architecture != hostArch {
			continue
		}
		root := strings.TrimSpace(roots[index])
		if root == "" {
			root = filepath.Join(windowsAppsDir(), name)
		}
		root = filepath.Clean(root)
		info, err := d.Stat(root)
		if err != nil || !info.IsDir() {
			continue
		}
		key := strings.ToLower(root)
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		candidates = append(candidates, Candidate{Path: root, RealPath: root, Source: SourceOfficial})
	}
	return candidates, nil
}

func windowsAppsDir() string {
	root := strings.TrimSpace(os.Getenv("ProgramFiles"))
	if root == "" {
		root = `C:\Program Files`
	}
	return filepath.Join(root, "WindowsApps")
}

// enumeratePackageRepository returns every registered package full name and
// its PackageRootFolder value.
func enumeratePackageRepository() ([]string, []string, error) {
	path, err := syscall.UTF16PtrFromString(packageRepositoryKey)
	if err != nil {
		return nil, nil, err
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, path, 0, syscall.KEY_READ|syscall.KEY_ENUMERATE_SUB_KEYS, &key); err != nil {
		return nil, nil, err
	}
	defer syscall.RegCloseKey(key)
	var names, roots []string
	buffer := make([]uint16, maxRegistryKeyName)
	for index := uint32(0); ; index++ {
		length := uint32(len(buffer))
		err := syscall.RegEnumKeyEx(key, index, &buffer[0], &length, nil, nil, nil, nil)
		if errors.Is(err, errorNoMoreItems) {
			break
		}
		if err != nil {
			return nil, nil, err
		}
		name := syscall.UTF16ToString(buffer[:length])
		names = append(names, name)
		roots = append(roots, packageRootFolder(key, name))
	}
	return names, roots, nil
}

func packageRootFolder(repository syscall.Handle, name string) string {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return ""
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(repository, namePtr, 0, syscall.KEY_READ, &key); err != nil {
		return ""
	}
	defer syscall.RegCloseKey(key)
	valuePtr, err := syscall.UTF16PtrFromString(packageRootValue)
	if err != nil {
		return ""
	}
	var valueType, size uint32
	if err := syscall.RegQueryValueEx(key, valuePtr, nil, &valueType, nil, &size); err != nil || size == 0 {
		return ""
	}
	if valueType != syscall.REG_SZ && valueType != syscall.REG_EXPAND_SZ {
		return ""
	}
	buffer := make([]uint16, size/2+1)
	if err := syscall.RegQueryValueEx(key, valuePtr, nil, &valueType, (*byte)(unsafe.Pointer(&buffer[0])), &size); err != nil {
		return ""
	}
	return syscall.UTF16ToString(buffer)
}

// WindowsPackageProber implements ProbeFunc for desktop targets: the version
// comes from the registered folder name and must agree with the manifest the
// folder holds.
type WindowsPackageProber struct{}

func (WindowsPackageProber) Probe(_ context.Context, targetID string, candidate Candidate) (string, error) {
	if !IsDesktopTarget(targetID) {
		return "", ErrUnsupportedTarget
	}
	full, ok := appx.ParseFullName(filepath.Base(filepath.Clean(candidate.RealPath)))
	if !ok || !packageMatches(targetID, full) {
		return "", ErrProbeFailed
	}
	manifest, err := appx.ReadManifestDir(candidate.RealPath)
	if err != nil || manifest.Name != full.Name || manifest.Version != full.Version {
		return "", ErrProbeFailed
	}
	version, ok := appx.ReleaseVersion(full.Version)
	if !ok || !bundleVersionPattern.MatchString(version) {
		return "", ErrVersionUnrecognized
	}
	return version, nil
}

// PackageApplicationID returns the application user model id (Family!AppId)
// the shell activates for a registered package folder.
func PackageApplicationID(root string) (string, bool) {
	full, ok := appx.ParseFullName(filepath.Base(filepath.Clean(root)))
	if !ok {
		return "", false
	}
	manifest, err := appx.ReadManifestDir(root)
	if err != nil {
		return "", false
	}
	return full.FamilyName() + "!" + manifest.AppID, true
}
