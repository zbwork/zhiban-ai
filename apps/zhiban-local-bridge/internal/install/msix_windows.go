//go:build windows

package install

// MSIX registration (M3-W). After the download passed the locked size and
// SHA-256, the package's Authenticode signature and AppxManifest identity are
// checked against the asset, then Windows registers it for the current user
// (Add-AppxPackage). A packaged service requires elevation, including newer
// Codex versions whose old asset metadata does not declare it. The desktop
// pipeline obtains consent before downloading. The Bridge never runs elevated.

import (
	"archive/zip"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"os"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	packageRegisterTimeout = 15 * time.Minute
	maxAppxManifestBytes   = 4 << 20
	// errorCancelled is ERROR_CANCELLED: the user declined the UAC prompt.
	errorCancelled = 1223
)

// appxIdentity is what the package declares about itself.
type appxIdentity struct {
	Name              string
	Publisher         string
	Version           string
	Arch              string
	AppID             string
	RequiresElevation bool
}

type appxManifest struct {
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
	Capabilities struct {
		Capability []struct {
			Name string `xml:"Name,attr"`
		} `xml:"Capability"`
	} `xml:"Capabilities"`
}

// readAppxIdentity parses AppxManifest.xml out of an MSIX (a zip).
func readAppxIdentity(packagePath string) (appxIdentity, error) {
	reader, err := zip.OpenReader(packagePath)
	if err != nil {
		return appxIdentity{}, errArchiveInvalid
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name != "AppxManifest.xml" {
			continue
		}
		if file.UncompressedSize64 > maxAppxManifestBytes {
			return appxIdentity{}, errArchiveInvalid
		}
		content, err := file.Open()
		if err != nil {
			return appxIdentity{}, errArchiveInvalid
		}
		data, err := io.ReadAll(io.LimitReader(content, maxAppxManifestBytes+1))
		_ = content.Close()
		if err != nil || len(data) > maxAppxManifestBytes {
			return appxIdentity{}, errArchiveInvalid
		}
		return parseAppxManifest(data)
	}
	return appxIdentity{}, errArchiveInvalid
}

func parseAppxManifest(data []byte) (appxIdentity, error) {
	var manifest appxManifest
	if err := xml.Unmarshal(data, &manifest); err != nil {
		return appxIdentity{}, errArchiveInvalid
	}
	identity := appxIdentity{
		Name: manifest.Identity.Name, Publisher: manifest.Identity.Publisher,
		Version: manifest.Identity.Version, Arch: strings.ToLower(manifest.Identity.ProcessorArchitecture),
	}
	if len(manifest.Applications.Application) > 0 {
		identity.AppID = manifest.Applications.Application[0].ID
	}
	for _, capability := range manifest.Capabilities.Capability {
		if capability.Name == "packagedServices" || capability.Name == "localSystemServices" {
			identity.RequiresElevation = true
		}
	}
	if identity.Name == "" || identity.Version == "" || identity.AppID == "" {
		return appxIdentity{}, errArchiveInvalid
	}
	return identity, nil
}

// installPackage is the Windows counterpart of placeBundle + detect for a
// downloaded, size- and hash-verified MSIX.
func (m *Manager) installPackage(ctx context.Context, report *operation.Reporter, plan pendingPlan, downloadPath string, registration packageRegistration) (any, error) {
	asset := plan.asset
	targetID := asset.TargetID
	mode := plan.public.Mode
	// The scratch download has a random name; the signature interface and
	// the deployment API pick their handlers by extension, so the same bytes
	// are exposed under a .msix name (a hard link in the downloads folder)
	// for the duration of the install.
	packagePath := downloadPath + ".msix"
	_ = os.Remove(packagePath)
	if err := os.Link(downloadPath, packagePath); err != nil {
		return nil, m.mapPlaceError(targetID, err)
	}
	defer os.Remove(packagePath)
	if err := m.bundleTools.VerifyBundle(ctx, packagePath, asset.SignerName); err != nil {
		debugLog("installPackage %s: signature check failed: %v", targetID, err)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, m.mapPlaceError(targetID, errPublisherMismatch)
	}
	identity, err := readAppxIdentity(packagePath)
	debugLog("installPackage %s: identity=%+v err=%v want name=%s version=%s. arch=%s", targetID, identity, err, asset.PackageName, asset.Version, windowsPackageArch(asset.Arch))
	if err != nil || identity.Name != asset.PackageName || !strings.HasPrefix(identity.Version, asset.Version+".") ||
		identity.Arch != windowsPackageArch(asset.Arch) {
		return nil, m.mapPlaceError(targetID, errArchiveInvalid)
	}
	if registration == nil {
		return nil, operation.Fail(installCode(targetID, "AUTHORIZATION_FAILED"), errors.New("missing pre-download authorization"))
	}
	err = registration.Register(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, operation.Fail(installCode(targetID, "REGISTRATION_FAILED"), err)
	}
	result, err := m.detectInstalled(ctx, report, targetID, asset)
	if err != nil {
		if switchingMode(mode) && ctx.Err() == nil {
			return nil, operation.Fail(installCode(targetID, switchFailure(mode)), err)
		}
		return nil, err
	}
	if switchingMode(mode) {
		result.PreviousVersion = plan.fromVersion
		result.PublisherAutoUpdateMayOverride = true
	}
	return result, nil
}
