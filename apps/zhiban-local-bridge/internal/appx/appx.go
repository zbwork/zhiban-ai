// Package appx knows the shape of Windows app packages (MSIX) as far as the
// Bridge needs it: the package full name the OS registers a package under,
// and the identity an AppxManifest.xml declares. It is pure Go so the parsing
// is tested on every platform; only the callers are Windows-specific.
package appx

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	// ManifestName is the manifest's file name inside a package and its
	// registered folder.
	ManifestName     = "AppxManifest.xml"
	maxManifestBytes = 4 << 20
)

var (
	ErrInvalid = errors.New("appx: invalid package identity")

	namePattern      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]*$`)
	publisherPattern = regexp.MustCompile(`^[a-z0-9]{13}$`)
	versionPattern   = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`)
)

// FullName is a registered package's folder name taken apart:
// Name_Version_Architecture_ResourceId_PublisherId.
type FullName struct {
	Name         string
	Version      string
	Architecture string
	ResourceID   string
	PublisherID  string
}

// FamilyName is Name_PublisherId, the identity that survives updates.
func (f FullName) FamilyName() string { return f.Name + "_" + f.PublisherID }

// ParseFullName splits a package full name such as
// Claude_1.49585.0.0_x64__pzs8sxrjxfjjc.
func ParseFullName(value string) (FullName, bool) {
	parts := strings.Split(value, "_")
	if len(parts) != 5 {
		return FullName{}, false
	}
	full := FullName{Name: parts[0], Version: parts[1], Architecture: strings.ToLower(parts[2]), ResourceID: parts[3], PublisherID: parts[4]}
	if !namePattern.MatchString(full.Name) || !versionPattern.MatchString(full.Version) ||
		full.Architecture == "" || !publisherPattern.MatchString(full.PublisherID) {
		return FullName{}, false
	}
	return full, true
}

// ReleaseVersion drops the fourth (revision) component of a four-part package
// version: 1.49585.0.0 → 1.49585.0, the number the publisher calls the release.
func ReleaseVersion(version string) (string, bool) {
	if !versionPattern.MatchString(version) {
		return "", false
	}
	parts := strings.Split(version, ".")
	return strings.Join(parts[:3], "."), true
}

// Manifest is what AppxManifest.xml declares about the package.
type Manifest struct {
	Name         string
	Publisher    string
	Version      string
	Architecture string
	// AppID is the first <Application Id>; with the family name it forms the
	// application user model id the shell launches (Family!AppID).
	AppID string
}

type manifestXML struct {
	Identity struct {
		Name                  string `xml:"Name,attr"`
		Publisher             string `xml:"Publisher,attr"`
		Version               string `xml:"Version,attr"`
		ProcessorArchitecture string `xml:"ProcessorArchitecture,attr"`
	} `xml:"Identity"`
	Applications struct {
		Application []struct {
			ID string `xml:"Id,attr"`
		} `xml:"Application"`
	} `xml:"Applications"`
}

// ParseManifest decodes AppxManifest.xml content.
func ParseManifest(data []byte) (Manifest, error) {
	var decoded manifestXML
	if err := xml.Unmarshal(data, &decoded); err != nil {
		return Manifest{}, ErrInvalid
	}
	manifest := Manifest{
		Name: decoded.Identity.Name, Publisher: decoded.Identity.Publisher, Version: decoded.Identity.Version,
		Architecture: strings.ToLower(decoded.Identity.ProcessorArchitecture),
	}
	if len(decoded.Applications.Application) > 0 {
		manifest.AppID = decoded.Applications.Application[0].ID
	}
	if !namePattern.MatchString(manifest.Name) || !versionPattern.MatchString(manifest.Version) || manifest.AppID == "" {
		return Manifest{}, ErrInvalid
	}
	return manifest, nil
}

// ReadManifestDir reads the manifest of a registered package's folder.
func ReadManifestDir(root string) (Manifest, error) {
	path := filepath.Join(filepath.Clean(root), ManifestName)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxManifestBytes {
		return Manifest{}, ErrInvalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, ErrInvalid
	}
	return ParseManifest(data)
}

// ReadManifestPackage reads the manifest inside an MSIX file (a zip).
func ReadManifestPackage(packagePath string) (Manifest, error) {
	reader, err := zip.OpenReader(packagePath)
	if err != nil {
		return Manifest{}, ErrInvalid
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name != ManifestName {
			continue
		}
		if file.UncompressedSize64 > maxManifestBytes {
			return Manifest{}, ErrInvalid
		}
		content, err := file.Open()
		if err != nil {
			return Manifest{}, ErrInvalid
		}
		data, err := io.ReadAll(io.LimitReader(content, maxManifestBytes+1))
		_ = content.Close()
		if err != nil || len(data) > maxManifestBytes {
			return Manifest{}, ErrInvalid
		}
		return ParseManifest(data)
	}
	return Manifest{}, ErrInvalid
}
