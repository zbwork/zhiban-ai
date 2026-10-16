package install

// Host component entries of the signed catalog (target claude_code_host,
// F31 version catalog plan §4). The host version is dictated by the installed
// Claude.app's embedded manifest, so a catalog entry is only ever used when
// its version equals the pinned one; it then adds platform-hosted sources
// next to the official base URL and the compiled-in npm pin. That way a new
// Claude Desktop that pins a new host version can be served by adding a
// catalog row instead of shipping a Bridge (mainland China cannot reach
// downloads.claude.ai, the only place Anthropic publishes the bundle).
//
// Trust: the archive is checked against the catalog's size and SHA-256 like
// every catalog source; the npm layout additionally checks the executable's
// SHA-256 from the entry and, as for the compiled-in pin, Anthropic's
// Developer ID signature before the bundle is arranged. A host_bundle_tar_zst
// entry must carry exactly the checksum the app manifest expects, because
// the .verified marker Claude Desktop reads is written from that manifest.

import (
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

// hostCatalogEntry is one claude_code_host version the catalog serves.
type hostCatalogEntry struct {
	version      string
	sources      []Source
	binarySHA256 string
}

// hostCatalogEntries converts the catalog's claude_code_host target (current
// and previous) into entries keyed by version. Entries that cannot be used
// safely (foreign layout, npm layout without an executable hash, invalid
// source) are dropped rather than failing the whole catalog.
func hostCatalogEntries(target catalog.Target) map[string]hostCatalogEntry {
	entries := map[string]hostCatalogEntry{}
	for _, version := range []*catalog.Version{target.Current, target.Previous} {
		if version == nil {
			continue
		}
		if version.Layout != LayoutHostBinaryNPMTgz && version.Layout != LayoutHostBundleTarZst {
			continue
		}
		if version.Layout == LayoutHostBinaryNPMTgz && !sha256Pattern.MatchString(version.BinarySHA256) {
			continue
		}
		entry := hostCatalogEntry{version: version.Version, binarySHA256: version.BinarySHA256}
		for _, source := range version.Sources {
			converted := Source{
				Kind: SourceKindZhibanPackage, Layout: version.Layout,
				URL: source.URL, Size: source.Size, SHA256: source.SHA256,
			}
			if converted.Validate() != nil {
				continue
			}
			entry.sources = append(entry.sources, converted)
		}
		if len(entry.sources) == 0 {
			continue
		}
		entries[entry.version] = entry
	}
	return entries
}

// catalogHostSources lists the catalog sources for the pinned host version.
// A bundle-layout source must describe the very archive the app manifest
// pins (same size and checksum); npm-layout sources are paired with the
// entry's executable hash at placement time (hostPinFor).
func (m *Manager) catalogHostSources(version string, artifact claudecode.Artifact) []Source {
	state := m.currentCatalog()
	if state == nil {
		return nil
	}
	entry, ok := state.hostEntries[version]
	if !ok {
		return nil
	}
	sources := make([]Source, 0, len(entry.sources))
	for _, source := range entry.sources {
		if source.Layout == LayoutHostBundleTarZst && (source.SHA256 != artifact.Checksum || source.Size != artifact.Size) {
			continue
		}
		sources = append(sources, source)
	}
	return sources
}

// hostPinFor returns the executable pin an npm-layout source must satisfy:
// the compiled-in pin when the download came from it, else the catalog
// entry's hash for the pinned host version (size unknown, hash-only).
func (m *Manager) hostPinFor(component componentPlan, source Source) (HostNPMPin, bool) {
	if component.npmPin != nil && component.npmPin.Source.URL == source.URL {
		return *component.npmPin, true
	}
	state := m.currentCatalog()
	if state == nil {
		return HostNPMPin{}, false
	}
	entry, ok := state.hostEntries[component.manifest.Version]
	if !ok {
		return HostNPMPin{}, false
	}
	for _, candidate := range entry.sources {
		if candidate.Layout == LayoutHostBinaryNPMTgz && candidate.URL == source.URL {
			return HostNPMPin{Source: candidate, BinarySize: 0, BinarySHA256: entry.binarySHA256}, true
		}
	}
	return HostNPMPin{}, false
}
