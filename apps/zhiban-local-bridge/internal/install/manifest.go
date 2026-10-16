// Package install implements one-click installation of the locked Codex CLI
// and Claude Code CLI versions from their publishers' official release
// channels. Every URL, size and SHA-256 is fixed at build time; the App and the
// server never supply them.
//
// Each asset lists several sources that are tried in order: the publisher's
// direct download, the publisher's own npm package on the official registry,
// and the same npm tarball on the npmmirror.com registry (a byte-identical
// mirror of the official registry that is reachable from networks where the
// first two are not). Integrity never depends on the transport: every source
// carries its own locked size and SHA-256, and the extracted executable is
// additionally checked against the locked binary hash when one is known.
package install

import (
	"errors"
	"net/url"
	"path"
	"regexp"
	"strings"
)

const (
	TargetCodexCLI      = "codex_cli"
	TargetClaudeCLI     = "claude_cli"
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	ArchARM64 = "arm64"
	ArchX64   = "x64"

	// Platforms an asset installs on (the catalog's platform names).
	PlatformMacOS   = "macos"
	PlatformWindows = "windows"

	// LayoutTarballSingle expects a gzip tarball whose only regular file is the
	// executable; LayoutBareBinary expects the executable itself;
	// LayoutTarballMember extracts exactly the named member of a gzip tarball;
	// LayoutAppBundleZip expects a zip whose only top-level entry is the
	// application bundle named by the asset (desktop targets, M3).
	LayoutTarballSingle = "tarball_single"
	LayoutBareBinary    = "bare_binary"
	LayoutTarballMember = "tarball_member"
	LayoutAppBundleZip  = "app_bundle_zip"
	// LayoutTarballTree extracts every regular file below the named member
	// directory of a gzip tarball, keeping relative paths and executable bits:
	// the Codex CLI package (@openai/codex platform tarball, layoutVersion 1)
	// is bin/codex plus bin/codex-code-mode-host, codex-path/rg and
	// codex-resources/, and Codex refuses Code Mode when the host binary is
	// not beside it (2026-09-10 test machines). Codex CLI only.
	LayoutTarballTree = "tarball_tree"
	// LayoutHostBundleTarZst is the Claude Code host bundle (claude.app.tar.zst)
	// Claude Desktop pins; it is never a build-time asset (M3 Task 8).
	LayoutHostBundleTarZst = "host_bundle_tar_zst"
	// LayoutAppBundleDMG expects a disk image whose volume root holds the
	// application bundle named by the asset (the community mirror of Claude
	// Desktop publishes DMGs, M3 Task 9).
	LayoutAppBundleDMG = "app_bundle_dmg"
	// LayoutMSIX is a Windows app package (desktop targets on Windows, M3-W):
	// its Authenticode signature and AppxManifest identity are checked, then
	// the OS registers it (Add-AppxPackage) — the Bridge never unpacks it.
	LayoutMSIX = "msix"
	// LayoutHostBinaryZst is the zstd stream of the bare Claude Code host
	// executable Claude Desktop downloads on Windows (claude.exe.zst); like
	// the other host layouts it is never a build-time asset.
	LayoutHostBinaryZst = "host_binary_zst"
	// LayoutHostBinaryNPMTgz is the bare Claude Code executable inside an
	// @anthropic-ai/claude-code-darwin-<arch> npm tarball; like the host bundle
	// it is never a build-time asset (M3 Task 9).
	LayoutHostBinaryNPMTgz = "host_binary_npm_tgz"

	SourceOfficialOpenAI    = "official_openai"
	SourceOfficialAnthropic = "official_anthropic"

	// Source kinds in fallback order.
	SourceKindOfficial    = "official"
	SourceKindNPMRegistry = "npm_registry"
	SourceKindNPMMirror   = "npm_mirror"
	// SourceKindCommunityMirror is a third-party re-host of the publisher's
	// own installer (github.com/Wangnov/claude-app-mirror). Integrity never
	// rests on it: the fixed size, SHA-256 and the publisher's Developer ID
	// signature are checked exactly as for the official source.
	SourceKindCommunityMirror = "community_mirror"
	// SourceKindZhibanPackage is a package the platform hosts (object storage
	// behind a Bus redirect, a CDN, or an external https address an operator
	// entered) and lists in the signed version catalog. It is never a
	// build-time source: such assets exist only after catalog.apply verified
	// the catalog, and only their downloads may use the catalog's extra hosts.
	SourceKindZhibanPackage = "zhiban_package"

	MinOSVersion = "11.0"

	// Locked release versions (see M1G plan §2 and M3 plan §2).
	LockedCodexVersion         = "0.153.4"
	LockedClaudeVersion        = "2.1.263"
	LockedCodexDesktopVersion  = "26.623.141536"
	LockedClaudeDesktopVersion = "1.46388.4"
	// Windows desktop packages (M3-W, spike 2026-09-10). MSIX versions are
	// four-part (1.49585.0.0); the Bridge compares the first three, which is
	// what the publishers call the release.
	LockedCodexDesktopVersionWindows  = "26.903.8094"
	LockedClaudeDesktopVersionWindows = "1.49585.0"
)

// LockedVersions returns the locked version of every target on a platform;
// the CLIs are the same everywhere, the desktop applications differ.
func LockedVersions(platform string) map[string]string {
	versions := map[string]string{
		TargetCodexCLI:      LockedCodexVersion,
		TargetClaudeCLI:     LockedClaudeVersion,
		TargetCodexDesktop:  LockedCodexDesktopVersion,
		TargetClaudeDesktop: LockedClaudeDesktopVersion,
	}
	if platform == PlatformWindows {
		versions[TargetCodexDesktop] = LockedCodexDesktopVersionWindows
		versions[TargetClaudeDesktop] = LockedClaudeDesktopVersionWindows
	}
	return versions
}

var (
	ErrInvalidManifest = errors.New("install: invalid manifest")

	sha256Pattern     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	sha512Pattern     = regexp.MustCompile(`^[0-9a-f]{128}$`)
	versionPattern    = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	bundleNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._-]*\.app$`)
	bundleIDPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]*$`)
	teamIDPattern     = regexp.MustCompile(`^[A-Z0-9]{10}$`)
	// publisherIDPattern is the 13-character Crockford base32 hash Windows
	// derives from a package's signing certificate.
	publisherIDPattern = regexp.MustCompile(`^[a-z0-9]{13}$`)
)

// Source is one build-time locked download location for an asset.
type Source struct {
	Kind   string
	URL    string
	Size   int64
	SHA256 string
	// SHA512 is only used by a host component tarball derived from the npm
	// registry's signed package document (host_npm_derived.go), which
	// publishes sha512 integrity but no sha256.
	SHA512 string
	Layout string
	Member string
}

// Host returns the source host for display.
func (s Source) Host() string {
	parsed, err := url.Parse(s.URL)
	if err != nil {
		return ""
	}
	return parsed.Hostname()
}

// Validate checks the source is internally consistent.
func (s Source) Validate() error {
	digestOK := sha256Pattern.MatchString(s.SHA256)
	if s.SHA512 != "" {
		// Only a registry-signed host tarball may rely on sha512 alone.
		if !sha512Pattern.MatchString(s.SHA512) {
			return ErrInvalidManifest
		}
		if s.SHA256 == "" && s.Kind == SourceKindNPMMirror && s.Layout == LayoutHostBinaryNPMTgz {
			digestOK = true
		}
	}
	if (s.Kind != SourceKindOfficial && s.Kind != SourceKindNPMRegistry && s.Kind != SourceKindNPMMirror &&
		s.Kind != SourceKindCommunityMirror && s.Kind != SourceKindZhibanPackage) ||
		s.Size <= 0 || !digestOK {
		return ErrInvalidManifest
	}
	switch s.Layout {
	case LayoutTarballSingle, LayoutBareBinary, LayoutAppBundleZip, LayoutAppBundleDMG, LayoutMSIX,
		LayoutHostBundleTarZst, LayoutHostBinaryNPMTgz, LayoutHostBinaryZst:
		if s.Member != "" {
			return ErrInvalidManifest
		}
	case LayoutTarballMember, LayoutTarballTree:
		if s.Member == "" || !safeArchiveName(s.Member) || path.Clean(s.Member) != s.Member {
			return ErrInvalidManifest
		}
	default:
		return ErrInvalidManifest
	}
	parsed, err := url.Parse(s.URL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
		parsed.Fragment != "" || strings.TrimSpace(s.URL) != s.URL {
		return ErrInvalidManifest
	}
	return nil
}

// Asset is one build-time locked executable for a target and architecture.
type Asset struct {
	TargetID string
	// Platform is PlatformMacOS or PlatformWindows; the compiled-in macOS
	// assets predate the field and leave it empty (see PlatformName).
	Platform string
	Arch     string
	Version  string
	Source   string
	// BinarySHA256 is the locked hash of the installed executable itself. When
	// set, every source must yield exactly these bytes.
	BinarySHA256 string
	Sources      []Source
	// Desktop targets only: the bundle name inside an Applications folder and
	// the identifier and publisher Developer ID Team its signature must carry.
	BundleName       string
	BundleIdentifier string
	TeamIdentifier   string
	// BundleAliases are other names the publisher ships the same bundle
	// (identifier and Team unchanged) under: Codex Desktop's official archives
	// became ChatGPT-darwin-*.zip holding ChatGPT.app. A zip may carry any of
	// BundleName and the aliases; repair, upgrade and rollback replace an
	// existing bundle under every one of them (contract §2.7.3).
	BundleAliases []string
	// Windows desktop targets only (M3-W): the MSIX identity the package must
	// declare (AppxManifest Identity Name, and the publisher id the OS derives
	// from the signing certificate — the PackageFamilyName is Name_PublisherID),
	// the Authenticode signer subject CN the package must carry, and whether
	// registering it needs an administrator (Claude Desktop declares a
	// packaged service, so a per-user Add-AppxPackage is refused).
	PackageName        string
	PackagePublisherID string
	SignerName         string
	RequiresElevation  bool
	// FromCatalog marks an asset built from the signed version catalog rather
	// than the compiled-in manifest.
	FromCatalog bool
}

// PackageFamilyName is the Windows package family (Name_PublisherID) of a
// Windows desktop asset, "" for anything else.
func (a Asset) PackageFamilyName() string {
	if a.PackageName == "" || a.PackagePublisherID == "" {
		return ""
	}
	return a.PackageName + "_" + a.PackagePublisherID
}

// PlatformName is the platform the asset installs on, macOS when unset.
func (a Asset) PlatformName() string {
	if a.Platform == "" {
		return PlatformMacOS
	}
	return a.Platform
}

// bundleNames lists every name the asset's bundle may carry, BundleName first.
func (a Asset) bundleNames() []string {
	return append([]string{a.BundleName}, a.BundleAliases...)
}

// IsBundle reports whether the asset installs an application bundle.
func (a Asset) IsBundle() bool {
	return a.TargetID == TargetCodexDesktop || a.TargetID == TargetClaudeDesktop
}

// Primary returns the first (publisher direct) source.
func (a Asset) Primary() Source {
	if len(a.Sources) == 0 {
		return Source{}
	}
	return a.Sources[0]
}

// Host returns the primary download host for display.
func (a Asset) Host() string {
	return a.Primary().Host()
}

// FallbackHosts lists the hosts of every non-primary source for display.
func (a Asset) FallbackHosts() []string {
	hosts := make([]string, 0, len(a.Sources))
	for index, source := range a.Sources {
		if index == 0 {
			continue
		}
		hosts = append(hosts, source.Host())
	}
	return hosts
}

// Validate checks the asset is internally consistent.
func (a Asset) Validate() error {
	if !validTarget(a.TargetID) || (a.Arch != ArchARM64 && a.Arch != ArchX64) ||
		(a.Platform != "" && a.Platform != PlatformMacOS && a.Platform != PlatformWindows) ||
		!versionPattern.MatchString(a.Version) || len(a.Sources) == 0 ||
		(a.Source != SourceOfficialOpenAI && a.Source != SourceOfficialAnthropic) ||
		(a.BinarySHA256 != "" && !sha256Pattern.MatchString(a.BinarySHA256)) {
		return ErrInvalidManifest
	}
	windows := a.PlatformName() == PlatformWindows
	if a.IsBundle() {
		if windows {
			// A Windows desktop asset is identified by its package identity
			// and signer; the macOS bundle facts must be absent.
			if !bundleIDPattern.MatchString(a.PackageName) || !publisherIDPattern.MatchString(a.PackagePublisherID) ||
				strings.TrimSpace(a.SignerName) == "" || strings.ContainsAny(a.SignerName, "\r\n\x00") ||
				a.BinarySHA256 != "" || a.BundleName != "" || len(a.BundleAliases) != 0 || a.BundleIdentifier != "" || a.TeamIdentifier != "" {
				return ErrInvalidManifest
			}
		} else if !bundleNamePattern.MatchString(a.BundleName) || !bundleIDPattern.MatchString(a.BundleIdentifier) ||
			!teamIDPattern.MatchString(a.TeamIdentifier) || a.BinarySHA256 != "" ||
			a.PackageName != "" || a.PackagePublisherID != "" || a.SignerName != "" || a.RequiresElevation {
			return ErrInvalidManifest
		}
		seen := map[string]bool{a.BundleName: true}
		for _, alias := range a.BundleAliases {
			if !bundleNamePattern.MatchString(alias) || seen[alias] {
				return ErrInvalidManifest
			}
			seen[alias] = true
		}
	} else if a.BundleName != "" || len(a.BundleAliases) != 0 || a.BundleIdentifier != "" || a.TeamIdentifier != "" ||
		a.PackageName != "" || a.PackagePublisherID != "" || a.SignerName != "" || a.RequiresElevation {
		return ErrInvalidManifest
	}
	for _, source := range a.Sources {
		if err := source.Validate(); err != nil {
			return err
		}
		bundleLayout := source.Layout == LayoutAppBundleZip || source.Layout == LayoutAppBundleDMG || source.Layout == LayoutMSIX
		if bundleLayout != a.IsBundle() || source.Layout == LayoutHostBundleTarZst || source.Layout == LayoutHostBinaryNPMTgz ||
			source.Layout == LayoutHostBinaryZst {
			return ErrInvalidManifest
		}
		// The package tree is the Codex CLI's install unit; no other target
		// installs a directory.
		if source.Layout == LayoutTarballTree && a.TargetID != TargetCodexCLI {
			return ErrInvalidManifest
		}
		// Packages are a Windows thing, bundles a macOS thing.
		if a.IsBundle() && (source.Layout == LayoutMSIX) != windows {
			return ErrInvalidManifest
		}
	}
	return nil
}

// DefaultAssets returns the locked release assets for macOS.
func DefaultAssets() []Asset {
	const (
		codexNPMARM64 = "codex-0.153.4-darwin-arm64.tgz"
		codexNPMX64   = "codex-0.153.4-darwin-x64.tgz"
		claudeNPMARM  = "claude-code-darwin-arm64-2.1.263.tgz"
		claudeNPMX64  = "claude-code-darwin-x64-2.1.263.tgz"
		// Windows x64 (M2). The npm platform packages hold the same bytes as
		// the publishers' direct downloads: codex.exe inside the tarball hashes
		// to the GitHub release's bare-exe digest and claude.exe to
		// manifest.json platforms.win32-x64.checksum (verified 2026-09-10 on
		// the Windows test machine; both registries served identical tarballs).
		codexNPMWinX64  = "codex-0.153.4-win32-x64.tgz"
		claudeNPMWinX64 = "claude-code-win32-x64-2.1.263.tgz"
		// Desktop applications (M3 plan §2; hashes match the Homebrew cask
		// metadata at the locked versions and the archives verified on the test
		// Mac on 2026-09-09). Claude Desktop ships one universal archive.
		claudeDesktopZip = "https://downloads.claude.ai/releases/darwin/universal/1.46388.4/Claude-50e62f90a2c85243eef42913398f7c8f1534abef.zip"
		// Community mirror of the same release (github.com/Wangnov/claude-app-mirror,
		// synced from downloads.claude.ai by GitHub Actions). Size and hash were
		// computed from our own download on 2026-09-09 and match the mirror's
		// SHA256SUMS.txt; the contained Claude.app is 1.46388.4, signed by Team
		// Q6L2SF6YDW and notarized. downloads.claude.ai is unreachable from
		// mainland China without a proxy, so this is the fallback for the desktop
		// installer (M3 Task 9).
		claudeDesktopMirrorDMG = "https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v1.46388.4/Claude-mac-universal.dmg"
		// GitHub release assets crawl at ~30 KB/s from mainland China (test Mac,
		// 2026-09-09: 354 MB would take ~3 h), so two public GitHub proxies are
		// tried ahead of the direct link: gh-proxy.com measured 12.7 MB/s,
		// ghfast.top 0.5 MB/s. They only relay the same bytes; size, SHA-256
		// and the Developer ID signature are checked exactly as for every source.
		claudeDesktopMirrorViaGHProxy = "https://gh-proxy.com/" + claudeDesktopMirrorDMG
		claudeDesktopMirrorViaGHFast  = "https://ghfast.top/" + claudeDesktopMirrorDMG
		// The same mirror re-hosts Anthropic's Windows MSIX (byte-identical to
		// the downloads.claude.ai file; both hashed on 2026-09-10).
		claudeDesktopWindowsMirror = "https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v1.49585.0/Claude-win-x64.msix"
		codexDesktopARM            = "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.623.141536.zip"
		codexDesktopX64            = "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-26.623.141536.zip"
	)
	claudeDesktop := func(arch string) Asset {
		return Asset{
			TargetID: TargetClaudeDesktop, Arch: arch, Version: LockedClaudeDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: "Claude.app", BundleIdentifier: "com.anthropic.claudefordesktop", TeamIdentifier: "Q6L2SF6YDW",
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutAppBundleZip, URL: claudeDesktopZip,
					Size: 355648442, SHA256: "494c3c6e791c5c0a5041371f8234a6dffa9c9426165d5ef4c7dbcf85ade58617",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutAppBundleDMG, URL: claudeDesktopMirrorViaGHProxy,
					Size: 353897855, SHA256: "c5451dba21b8bf4232f8feffbff946dc7be4d6a64ee22d3190954e16f62444c9",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutAppBundleDMG, URL: claudeDesktopMirrorViaGHFast,
					Size: 353897855, SHA256: "c5451dba21b8bf4232f8feffbff946dc7be4d6a64ee22d3190954e16f62444c9",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutAppBundleDMG, URL: claudeDesktopMirrorDMG,
					Size: 353897855, SHA256: "c5451dba21b8bf4232f8feffbff946dc7be4d6a64ee22d3190954e16f62444c9",
				},
			},
		}
	}
	codexDesktop := func(arch, url string, size int64, sha256 string) Asset {
		return Asset{
			TargetID: TargetCodexDesktop, Arch: arch, Version: LockedCodexDesktopVersion, Source: SourceOfficialOpenAI,
			BundleName: "Codex.app", BundleAliases: []string{"ChatGPT.app"}, BundleIdentifier: "com.openai.codex", TeamIdentifier: "2DC432GLL2",
			Sources: []Source{{Kind: SourceKindOfficial, Layout: LayoutAppBundleZip, URL: url, Size: size, SHA256: sha256}},
		}
	}
	return []Asset{
		// Codex CLI is installed as the publisher's package tree (bin/codex,
		// bin/codex-code-mode-host, codex-path/rg, codex-resources/), which
		// only the @openai/codex platform tarballs carry; the GitHub release
		// archives hold the bare codex binary and are no longer a source.
		// registry.npmjs.org is OpenAI's own channel, npmmirror the mainland
		// China fallback with identical bytes (verified 2026-09-10).
		{
			TargetID: TargetCodexCLI, Arch: ArchARM64, Version: LockedCodexVersion, Source: SourceOfficialOpenAI,
			BinarySHA256: "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3",
			Sources: []Source{
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballTree, Member: "package/vendor/aarch64-apple-darwin",
					URL:    "https://registry.npmjs.org/@openai/codex/-/" + codexNPMARM64,
					Size:   115672312,
					SHA256: "535d301b49131abfda3264f959fb0defa40bbc306976d98ddbc15c424636c55c",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballTree, Member: "package/vendor/aarch64-apple-darwin",
					URL:    "https://registry.npmmirror.com/@openai/codex/-/" + codexNPMARM64,
					Size:   115672312,
					SHA256: "535d301b49131abfda3264f959fb0defa40bbc306976d98ddbc15c424636c55c",
				},
			},
		},
		{
			TargetID: TargetCodexCLI, Arch: ArchX64, Version: LockedCodexVersion, Source: SourceOfficialOpenAI,
			BinarySHA256: "88ecd2cbf8044832a49e7710394d9d328f7205fa5e8c8ebbdd015e002b4f6e21",
			Sources: []Source{
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballTree, Member: "package/vendor/x86_64-apple-darwin",
					URL:    "https://registry.npmjs.org/@openai/codex/-/" + codexNPMX64,
					Size:   123544033,
					SHA256: "5e468958503c60e940b1b1af3fe2064c16fd141f1607111caf99f2c0a0e80725",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballTree, Member: "package/vendor/x86_64-apple-darwin",
					URL:    "https://registry.npmmirror.com/@openai/codex/-/" + codexNPMX64,
					Size:   123544033,
					SHA256: "5e468958503c60e940b1b1af3fe2064c16fd141f1607111caf99f2c0a0e80725",
				},
			},
		},
		{
			TargetID: TargetClaudeCLI, Arch: ArchARM64, Version: LockedClaudeVersion, Source: SourceOfficialAnthropic,
			BinarySHA256: "ef5d2909c8af49f31ab6d5487e90316777bc2fac170adfe8160716caa8aaf4f9",
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutBareBinary,
					URL:    "https://downloads.claude.ai/claude-code-releases/2.1.263/darwin-arm64/claude",
					Size:   199257984,
					SHA256: "ef5d2909c8af49f31ab6d5487e90316777bc2fac170adfe8160716caa8aaf4f9",
				},
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballMember, Member: "package/claude",
					URL:    "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/" + claudeNPMARM,
					Size:   87267290,
					SHA256: "f1c0d2da0e49acdb26f87d9d1a6fd036d03c1d31d9ae8a5682c453c8f127f32e",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballMember, Member: "package/claude",
					URL:    "https://registry.npmmirror.com/@anthropic-ai/claude-code-darwin-arm64/-/" + claudeNPMARM,
					Size:   87267290,
					SHA256: "f1c0d2da0e49acdb26f87d9d1a6fd036d03c1d31d9ae8a5682c453c8f127f32e",
				},
			},
		},
		{
			TargetID: TargetClaudeCLI, Arch: ArchX64, Version: LockedClaudeVersion, Source: SourceOfficialAnthropic,
			BinarySHA256: "a94a8b229fa85c3a316c6b4a35e0aa22bec1aabbd3d1422826ce1d10ddc88751",
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutBareBinary,
					URL:    "https://downloads.claude.ai/claude-code-releases/2.1.263/darwin-x64/claude",
					Size:   208025952,
					SHA256: "a94a8b229fa85c3a316c6b4a35e0aa22bec1aabbd3d1422826ce1d10ddc88751",
				},
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballMember, Member: "package/claude",
					URL:    "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-x64/-/" + claudeNPMX64,
					Size:   91268005,
					SHA256: "9804d73f7e6dfe4d3c1f5cf0816499ea60d5d2e31099d210efe31d7e3fcfaf33",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballMember, Member: "package/claude",
					URL:    "https://registry.npmmirror.com/@anthropic-ai/claude-code-darwin-x64/-/" + claudeNPMX64,
					Size:   91268005,
					SHA256: "9804d73f7e6dfe4d3c1f5cf0816499ea60d5d2e31099d210efe31d7e3fcfaf33",
				},
			},
		},
		// Windows x64 CLIs follow the macOS ones (tests index the first four
		// and the last entry). Codex is the same package tree as on macOS
		// (bin/codex.exe, bin/codex-code-mode-host.exe, codex-path/rg.exe,
		// codex-resources/); GitHub release digests via the releases API.
		{
			TargetID: TargetCodexCLI, Platform: PlatformWindows, Arch: ArchX64, Version: LockedCodexVersion, Source: SourceOfficialOpenAI,
			BinarySHA256: "444a3f0008050605cae73cd9b7a2dcac61294062dfaab56dd20430fd6498518b",
			Sources: []Source{
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballTree, Member: "package/vendor/x86_64-pc-windows-msvc",
					URL:    "https://registry.npmjs.org/@openai/codex/-/" + codexNPMWinX64,
					Size:   141495386,
					SHA256: "05f473573f38b3f4dc9484e6807a511a1bb0e128dfa50816dafc5f79e553cdca",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballTree, Member: "package/vendor/x86_64-pc-windows-msvc",
					URL:    "https://registry.npmmirror.com/@openai/codex/-/" + codexNPMWinX64,
					Size:   141495386,
					SHA256: "05f473573f38b3f4dc9484e6807a511a1bb0e128dfa50816dafc5f79e553cdca",
				},
			},
		},
		{
			TargetID: TargetClaudeCLI, Platform: PlatformWindows, Arch: ArchX64, Version: LockedClaudeVersion, Source: SourceOfficialAnthropic,
			BinarySHA256: "0b35df94c1307004f07b738390bfef8dfca5e9af29aaf6517f305bf086b95b03",
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutBareBinary,
					URL:    "https://downloads.claude.ai/claude-code-releases/2.1.263/win32-x64/claude.exe",
					Size:   218746016,
					SHA256: "0b35df94c1307004f07b738390bfef8dfca5e9af29aaf6517f305bf086b95b03",
				},
				{
					Kind: SourceKindNPMRegistry, Layout: LayoutTarballMember, Member: "package/claude.exe",
					URL:    "https://registry.npmjs.org/@anthropic-ai/claude-code-win32-x64/-/" + claudeNPMWinX64,
					Size:   99788276,
					SHA256: "ced273be517e9afdbc91be4d7923d0bc8f7ce40e439c68db70b8d7015d0fe362",
				},
				{
					Kind: SourceKindNPMMirror, Layout: LayoutTarballMember, Member: "package/claude.exe",
					URL:    "https://registry.npmmirror.com/@anthropic-ai/claude-code-win32-x64/-/" + claudeNPMWinX64,
					Size:   99788276,
					SHA256: "ced273be517e9afdbc91be4d7923d0bc8f7ce40e439c68db70b8d7015d0fe362",
				},
			},
		},
		// Desktop applications are appended so the CLI asset order above stays stable.
		claudeDesktop(ArchARM64),
		claudeDesktop(ArchX64),
		codexDesktop(ArchARM64, codexDesktopARM, 534731967, "d948dc36b8358f5a2924b033fbf08398eea7860dc9e97cb5ab9b354490283a0a"),
		codexDesktop(ArchX64, codexDesktopX64, 494464945, "5a8eb9bca0c021b994e56c93ef3502bdbc105975bcb83f99aef40f2ae56d48cc"),
		// Windows desktop packages (M3-W, 2026-09-10 spike on the Windows test
		// machine): Claude Desktop is Anthropic's own MSIX (also re-hosted by
		// the community mirror, same bytes); the Codex desktop on Windows is
		// the ChatGPT app, a Store-signed MSIX OpenAI publishes for enterprise
		// deployment on a stable link (its hash moves when OpenAI ships a new
		// build; the signed version catalog is the durable channel).
		{
			TargetID: TargetClaudeDesktop, Platform: PlatformWindows, Arch: ArchX64, Version: LockedClaudeDesktopVersionWindows, Source: SourceOfficialAnthropic,
			PackageName: "Claude", PackagePublisherID: "pzs8sxrjxfjjc", SignerName: "Anthropic, PBC", RequiresElevation: true,
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutMSIX,
					URL:    "https://downloads.claude.ai/releases/win32/x64/1.49585.0/Claude-41ad1dff5275eedc8af25989f59f33c5efe14063.msix",
					Size:   277248271,
					SHA256: "dfc789cb60a88a5ba794c25903ebfc0f4552c650a157933b056c984366dbedca",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutMSIX, URL: "https://gh-proxy.com/" + claudeDesktopWindowsMirror,
					Size: 277248271, SHA256: "dfc789cb60a88a5ba794c25903ebfc0f4552c650a157933b056c984366dbedca",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutMSIX, URL: "https://ghfast.top/" + claudeDesktopWindowsMirror,
					Size: 277248271, SHA256: "dfc789cb60a88a5ba794c25903ebfc0f4552c650a157933b056c984366dbedca",
				},
				{
					Kind: SourceKindCommunityMirror, Layout: LayoutMSIX, URL: claudeDesktopWindowsMirror,
					Size: 277248271, SHA256: "dfc789cb60a88a5ba794c25903ebfc0f4552c650a157933b056c984366dbedca",
				},
			},
		},
		{
			TargetID: TargetCodexDesktop, Platform: PlatformWindows, Arch: ArchX64, Version: LockedCodexDesktopVersionWindows, Source: SourceOfficialOpenAI,
			PackageName: "OpenAI.Codex", PackagePublisherID: "2p2nqsd0c76g0", SignerName: "50BDFD77-8903-4850-9FFE-6E8522F64D5B",
			Sources: []Source{
				{
					Kind: SourceKindOfficial, Layout: LayoutMSIX,
					URL:    "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix",
					Size:   769792128,
					SHA256: "f8a845dd58f177fbcd71b01c7831d742fc90855e4b207ee2d8ce3ab5f9bcc30f",
				},
			},
		},
	}
}

// HostNPMPin is a build-time pinned npmmirror tarball of the bare Claude Code
// host executable plus the exact bytes of the executable inside it. Claude
// Desktop's embedded manifest cannot stand in for the member pin: its
// platforms.<arch>.checksum/size describe Anthropic's zstd stream (claude.zst),
// not the raw executable (11914 test Mac: PUBLISHER_MISMATCH because the
// 198 MB member was compared with the 65 MB claude.zst pin).
type HostNPMPin struct {
	Source       Source
	BinarySize   int64
	BinarySHA256 string
	// Derived marks a pin built at run time from the npm registry's signed
	// package document for a host version nobody pinned in advance
	// (host_npm_derived.go). It has no executable size or hash; the tarball
	// is checked against the registry-signed sha512 and the executable
	// against Anthropic's code signature and its reported version.
	Derived bool
}

// Validate checks the pin is internally consistent.
func (p HostNPMPin) Validate() error {
	if p.Derived {
		if p.Source.Layout != LayoutHostBinaryNPMTgz || p.Source.Kind != SourceKindNPMMirror ||
			p.BinarySize != 0 || p.BinarySHA256 != "" || !sha512Pattern.MatchString(p.Source.SHA512) {
			return ErrInvalidManifest
		}
		return p.Source.Validate()
	}
	if p.Source.Layout != LayoutHostBinaryNPMTgz || p.BinarySize <= 0 || !sha256Pattern.MatchString(p.BinarySHA256) {
		return ErrInvalidManifest
	}
	return p.Source.Validate()
}

// DefaultAllowedHosts lists every host a download may touch, including the
// GitHub release and npmmirror CDN redirect targets.
func DefaultAllowedHosts() []string {
	return []string{
		"github.com",
		"objects.githubusercontent.com",
		"release-assets.githubusercontent.com",
		"gh-proxy.com",
		"ghfast.top",
		"downloads.claude.ai",
		"persistent.oaistatic.com",
		"registry.npmjs.org",
		"registry.npmmirror.com",
		"cdn.npmmirror.com",
	}
}
