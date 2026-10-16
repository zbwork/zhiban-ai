package install

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	testDesktopVersion = "1.46388.4"
	testDesktopBundle  = "Claude.app"
	testDesktopID      = "com.anthropic.claudefordesktop"
	testDesktopTeam    = "Q6L2SF6YDW"
	badSealMarker      = "Contents/BAD_SIGNATURE"
	badAssessMarker    = "Contents/BAD_ASSESS"
)

// testBundleSignature stands in for `codesign -dv`: the Team is whatever the
// bundle's Contents/team.txt says.
func testBundleSignature(_ context.Context, bundlePath string) (detect.BundleSignature, error) {
	team, err := os.ReadFile(filepath.Join(bundlePath, "Contents", "team.txt"))
	if err != nil {
		return detect.BundleSignature{}, err
	}
	return detect.BundleSignature{Identifier: testDesktopID, TeamIdentifier: strings.TrimSpace(string(team))}, nil
}

// testBundleSeal stands in for `codesign --verify`: a BAD_SIGNATURE marker
// breaks the seal.
func testBundleSeal(_ context.Context, bundlePath string) error {
	if _, err := os.Stat(filepath.Join(bundlePath, badSealMarker)); err == nil {
		return errors.New("code object is not signed at all")
	}
	return nil
}

// testVerifyBundle stands in for the deep verification with a requirement.
func testVerifyBundle(ctx context.Context, bundlePath, requirement string) error {
	if err := testBundleSeal(ctx, bundlePath); err != nil {
		return err
	}
	if !strings.Contains(requirement, `"`+testDesktopTeam+`"`) ||
		(!strings.Contains(requirement, `"`+testDesktopID+`"`) && !strings.Contains(requirement, `"`+claudecode.BundleIdentifier+`"`)) {
		return errors.New("requirement does not name the publisher")
	}
	return nil
}

// testAssessBundle stands in for `spctl --assess`.
func testAssessBundle(_ context.Context, bundlePath string) error {
	if _, err := os.Stat(filepath.Join(bundlePath, badAssessMarker)); err == nil {
		return errors.New("rejected")
	}
	return nil
}

// fakeBundleZip builds a deterministic archive with <bundle>/Contents/… plus
// optional failure markers.
func fakeBundleZip(t *testing.T, markers ...string) []byte {
	t.Helper()
	return fakeBundleZipNamed(t, testDesktopBundle, markers...)
}

// fakeBundleZipNamed is fakeBundleZip with the bundle stored under bundleName.
func fakeBundleZipNamed(t *testing.T, bundleName string, markers ...string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	stamp := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	add := func(name string, mode os.FileMode, content string) {
		header := &zip.FileHeader{Name: bundleName + "/" + name, Method: zip.Deflate, Modified: stamp}
		header.SetMode(mode)
		file, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	add("Contents/Info.plist", 0o644, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>`+testDesktopID+`</string>
	<key>CFBundleShortVersionString</key>
	<string>`+testDesktopVersion+`</string>
	<key>CFBundleVersion</key>
	<string>`+testDesktopVersion+`</string>
</dict>
</plist>
`)
	add("Contents/MacOS/Claude", 0o755, "#!/bin/sh\nexit 0\n")
	add("Contents/team.txt", 0o644, testDesktopTeam+"\n")
	for _, marker := range markers {
		add(marker, 0o644, "x\n")
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// newDesktopFixture serves archive as the Claude Desktop asset next to the CLI assets.
func newDesktopFixture(t *testing.T, archive []byte) *fixture {
	t.Helper()
	return newDesktopFixtureWithAliases(t, archive, nil)
}

// newDesktopFixtureWithAliases also lets the asset's bundle carry the alias
// names (the way Codex Desktop ships as ChatGPT.app).
func newDesktopFixtureWithAliases(t *testing.T, archive []byte, aliases []string) *fixture {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/claude-desktop.zip", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(archive)))
		_, _ = w.Write(archive)
	})
	return newFixture(t, mux, func(assets map[string]Asset) {
		base := strings.TrimSuffix(assets[TargetCodexCLI].Sources[0].URL, "/codex.tar.gz")
		assets[TargetClaudeDesktop] = Asset{
			TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: testDesktopBundle, BundleAliases: aliases, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
			Sources: []Source{{Kind: SourceKindOfficial, URL: base + "/claude-desktop.zip", Size: int64(len(archive)), SHA256: digestOf(archive), Layout: LayoutAppBundleZip}},
		}
	})
}

const testDesktopAlias = "ClaudeNext.app"

// writeDamagedDesktopBundle puts a recognisable but damaged Claude Desktop
// bundle at dir/name.
func writeDamagedDesktopBundle(t *testing.T, dir, name string) string {
	t.Helper()
	bundle := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	for file, content := range map[string]string{
		"Contents/Info.plist":   `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop</string><key>CFBundleShortVersionString</key><string>1.0.0</string></dict></plist>`,
		"Contents/team.txt":     testDesktopTeam + "\n",
		badSealMarker:           "x\n",
		"Contents/MacOS/Claude": "#!/bin/sh\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bundle, file), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return bundle
}

func TestDesktopInstallPlacesBundleUnderTheArchiveAliasName(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixtureWithAliases(t, fakeBundleZipNamed(t, testDesktopAlias), []string{testDesktopAlias})
	final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if info, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopAlias)); err != nil || !info.IsDir() {
		t.Fatalf("bundle not placed under the archive's name: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopBundle)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("nothing may be placed under the primary name: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}
	state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != detect.UIStateInstalledUnmanaged || state.InstalledVersion != testDesktopVersion {
		t.Fatalf("Detect() after alias install = %+v, %v", state, err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeInstall); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan(install) after alias install error = %v", err)
	}
}

func TestDesktopRepairReplacesBundleUnderTheOtherName(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	// Codex.app installed, the new archive holds ChatGPT.app: the old bundle
	// must go, not stay next to the new one.
	f := newDesktopFixtureWithAliases(t, fakeBundleZipNamed(t, testDesktopAlias), []string{testDesktopAlias})
	old := writeDamagedDesktopBundle(t, f.systemApplications, testDesktopBundle)
	if state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop); err != nil || state.UIState != detect.UIStateRepairable {
		t.Fatalf("Detect(damaged) = %+v, %v", state, err)
	}
	final := f.runInstall(t, TargetClaudeDesktop, ModeRepair)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Lstat(old); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old bundle under the primary name must be removed: %v", err)
	}
	if info, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopAlias)); err != nil || !info.IsDir() {
		t.Fatalf("new bundle not placed under the archive's name: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("aside or staging left behind: %v", hidden)
	}
	state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != detect.UIStateInstalledUnmanaged || state.InstalledVersion != testDesktopVersion {
		t.Fatalf("Detect() after repair = %+v, %v", state, err)
	}
	f.assertNoScratch(t)
}

func TestDesktopRepairUnderOtherNameRestoresOldBundleWhenRejected(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixtureWithAliases(t, fakeBundleZipNamed(t, testDesktopAlias, badAssessMarker), []string{testDesktopAlias})
	old := writeDamagedDesktopBundle(t, f.systemApplications, testDesktopBundle)
	final := f.runInstall(t, TargetClaudeDesktop, ModeRepair)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Stat(filepath.Join(old, badSealMarker)); err != nil {
		t.Fatalf("old bundle must be back under its own name: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopAlias)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejected bundle must not stay installed: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("aside or staging left behind: %v", hidden)
	}
}

func TestDesktopInstallRejectsArchiveWithUnknownBundleName(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixtureWithAliases(t, fakeBundleZipNamed(t, "Other.app"), []string{testDesktopAlias})
	final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if entries, _ := os.ReadDir(f.systemApplications); len(entries) != 0 {
		t.Fatalf("nothing may be placed: %v", entries)
	}
}

func hiddenEntries(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	var hidden []string
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".zhiban-") {
			hidden = append(hidden, entry.Name())
		}
	}
	return hidden
}

func TestInstallDesktopBundleIntoSystemApplications(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixture(t, fakeBundleZip(t))

	before, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || before.UIState != detect.UIStateNotInstalled || before.FormFactor != detect.FormFactorDesktop {
		t.Fatalf("Detect() before = %+v, %v", before, err)
	}
	requirements, err := f.manager.Requirements(context.Background(), TargetClaudeDesktop)
	if err != nil || !requirements.Satisfied || requirements.InstallLocationKind != installLocationKindApplications ||
		requirements.DownloadHost != "127.0.0.1" || requirements.Version != testDesktopVersion {
		t.Fatalf("Requirements() = %+v, %v", requirements, err)
	}

	final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result, ok := final.Result.(Result)
	if !ok || result.ToolState.UIState != detect.UIStateInstalledUnmanaged || result.ToolState.InstalledVersion != testDesktopVersion ||
		result.ToolState.InstallSource != detect.SourceOfficial || result.ToolState.FormFactor != detect.FormFactorDesktop {
		t.Fatalf("install result = %#v", final.Result)
	}
	bundle := filepath.Join(f.systemApplications, testDesktopBundle)
	if info, err := os.Lstat(bundle); err != nil || !info.IsDir() {
		t.Fatalf("bundle not placed: %v", err)
	}
	if info, err := os.Stat(filepath.Join(bundle, "Contents", "MacOS", "Claude")); err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("bundle executable = %v, %v", info, err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}
	if entries, _ := os.ReadDir(f.userApplications); len(entries) != 0 {
		t.Fatalf("user Applications must stay untouched: %v", entries)
	}
	f.assertNoScratch(t)

	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeInstall); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan(install) after install error = %v", err)
	}
	if requirements, _ := f.manager.Requirements(context.Background(), TargetClaudeDesktop); requirements.Satisfied || !contains(requirements.Issues, IssueTargetConflict) {
		t.Fatalf("Requirements() after install = %+v", requirements)
	}
}

func TestRepairDesktopBundleReplacesDamagedBundle(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixture(t, fakeBundleZip(t))
	if final := f.runInstall(t, TargetClaudeDesktop, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	bundle := filepath.Join(f.systemApplications, testDesktopBundle)
	marker := filepath.Join(bundle, badSealMarker)
	if err := os.WriteFile(marker, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	damaged, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || damaged.UIState != detect.UIStateRepairable || damaged.ErrorCode != "LCT-CLAUDE_DESKTOP-DETECT-DAMAGED" {
		t.Fatalf("Detect(damaged) = %+v, %v", damaged, err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeInstall); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan(install) on damaged error = %v", err)
	}

	final := f.runInstall(t, TargetClaudeDesktop, ModeRepair)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("damaged bundle must be replaced, marker still present: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("aside or staging left behind: %v", hidden)
	}
	after, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || after.UIState != detect.UIStateInstalledUnmanaged || after.InstalledVersion != testDesktopVersion {
		t.Fatalf("Detect(after repair) = %+v, %v", after, err)
	}
	f.assertNoScratch(t)
}

func TestDesktopRepairRefusedWhileApplicationRuns(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixture(t, fakeBundleZip(t))
	if final := f.runInstall(t, TargetClaudeDesktop, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	bundle := filepath.Join(f.systemApplications, testDesktopBundle)
	if err := os.WriteFile(filepath.Join(bundle, badSealMarker), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.inUse.Store(true)
	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeRepair); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-TARGET_IN_USE") {
		t.Fatalf("Plan(repair) while running error = %v", err)
	}
	f.inUse.Store(false)
	f.inUseCheckBroken.Store(true)
	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeRepair); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-RUNNING_CHECK_FAILED") {
		t.Fatalf("Plan(repair) with a broken check error = %v", err)
	}
	f.inUseCheckBroken.Store(false)
	if _, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeRepair); err != nil {
		t.Fatalf("Plan(repair) after quit error = %v", err)
	}
}

func TestDesktopInstallRejectsBundleFailingSignatureOrGatekeeper(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	for _, tc := range []struct {
		name   string
		marker string
	}{
		{name: "signature", marker: badSealMarker},
		{name: "gatekeeper", marker: badAssessMarker},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newDesktopFixture(t, fakeBundleZip(t, tc.marker))
			final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
			if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
				t.Fatalf("final = %+v code=%s", final, describeCode(final.ErrorCode))
			}
			if final.ErrorDetail == nil || *final.ErrorDetail == "" {
				t.Fatal("native failure lost its diagnostic detail")
			}
			if _, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopBundle)); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("rejected bundle must not be installed: %v", err)
			}
			if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
				t.Fatalf("staging left behind: %v", hidden)
			}
			f.assertNoScratch(t)
			state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
			if err != nil || state.UIState != detect.UIStateNotInstalled {
				t.Fatalf("Detect() after rejection = %+v, %v", state, err)
			}
		})
	}
}

func TestDesktopRepairKeepsOldBundleWhenReplacementIsRejected(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	// The served archive fails Gatekeeper; an existing (damaged) bundle must
	// survive the failed repair untouched.
	f := newDesktopFixture(t, fakeBundleZip(t, badAssessMarker))
	bundle := filepath.Join(f.systemApplications, testDesktopBundle)
	if err := os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"Contents/Info.plist":   `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop</string><key>CFBundleShortVersionString</key><string>1.0.0</string></dict></plist>`,
		"Contents/team.txt":     testDesktopTeam + "\n",
		badSealMarker:           "x\n",
		"Contents/MacOS/Claude": "#!/bin/sh\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bundle, name), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop); err != nil || state.UIState != detect.UIStateRepairable {
		t.Fatalf("Detect(damaged) = %+v, %v", state, err)
	}
	final := f.runInstall(t, TargetClaudeDesktop, ModeRepair)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Stat(filepath.Join(bundle, badSealMarker)); err != nil {
		t.Fatalf("old bundle must be back in place: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("aside or staging left behind: %v", hidden)
	}
}

func TestDesktopInstallFallsBackToUserApplications(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newDesktopFixture(t, fakeBundleZip(t))
	// The fixture treats everything as writable; use the real check so a
	// read-only system folder is honoured.
	f.manager.writable = defaultWritable
	if err := os.Chmod(f.systemApplications, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(f.systemApplications, 0o755) })

	requirements, err := f.manager.Requirements(context.Background(), TargetClaudeDesktop)
	if err != nil || !requirements.Satisfied || requirements.InstallLocationKind != installLocationKindUserApplications {
		t.Fatalf("Requirements() = %+v, %v", requirements, err)
	}
	final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if info, err := os.Lstat(filepath.Join(f.userApplications, testDesktopBundle)); err != nil || !info.IsDir() {
		t.Fatalf("bundle not placed in user Applications: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(f.systemApplications, testDesktopBundle)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("system Applications must stay untouched: %v", err)
	}
	state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != detect.UIStateInstalledUnmanaged || state.InstalledVersion != testDesktopVersion {
		t.Fatalf("Detect() after user install = %+v, %v", state, err)
	}
}

func TestBundleRequirementAndAssetValidation(t *testing.T) {
	t.Parallel()
	asset := Asset{TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
		BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
		Sources: []Source{{Kind: SourceKindOfficial, URL: "https://downloads.claude.ai/x.zip", Size: 1, SHA256: strings.Repeat("a", 64), Layout: LayoutAppBundleZip}}}
	if err := asset.Validate(); err != nil {
		t.Fatalf("valid desktop asset rejected: %v", err)
	}
	requirement := bundleRequirement(asset)
	if !strings.Contains(requirement, `anchor apple generic`) || !strings.Contains(requirement, `certificate leaf[subject.OU] = "Q6L2SF6YDW"`) ||
		!strings.Contains(requirement, `identifier "com.anthropic.claudefordesktop"`) {
		t.Fatalf("requirement = %s", requirement)
	}
	bad := asset
	bad.TeamIdentifier = "short"
	if err := bad.Validate(); err == nil {
		t.Fatal("bad team id accepted")
	}
	bad = asset
	bad.Sources[0].Layout = LayoutBareBinary
	if err := bad.Validate(); err == nil {
		t.Fatal("desktop asset with non-bundle layout accepted")
	}
	bad = asset
	bad.TargetID = TargetClaudeCLI
	if err := bad.Validate(); err == nil {
		t.Fatal("cli asset with bundle fields accepted")
	}
	bad = asset
	bad.BinarySHA256 = strings.Repeat("b", 64)
	if err := bad.Validate(); err == nil {
		t.Fatal("desktop asset with binary hash accepted")
	}
	// The cases above share asset's Sources slice (one of them changed its
	// layout); the alias cases start from a fresh one.
	asset.Sources = []Source{{Kind: SourceKindOfficial, URL: "https://downloads.claude.ai/x.zip", Size: 1, SHA256: strings.Repeat("a", 64), Layout: LayoutAppBundleZip}}
	aliased := asset
	aliased.BundleAliases = []string{testDesktopAlias}
	if err := aliased.Validate(); err != nil {
		t.Fatalf("desktop asset with an alias rejected: %v", err)
	}
	for _, aliases := range [][]string{{testDesktopBundle}, {testDesktopAlias, testDesktopAlias}, {"../Evil.app"}, {"NoSuffix"}} {
		bad = asset
		bad.BundleAliases = aliases
		if err := bad.Validate(); err == nil {
			t.Fatalf("aliases %q accepted", aliases)
		}
	}
	bad = asset
	bad.TargetID, bad.BundleName, bad.BundleIdentifier, bad.TeamIdentifier = TargetClaudeCLI, "", "", ""
	bad.BundleAliases = []string{testDesktopAlias}
	bad.Sources = []Source{{Kind: SourceKindOfficial, URL: "https://downloads.claude.ai/x", Size: 1, SHA256: strings.Repeat("a", 64), Layout: LayoutBareBinary}}
	bad.BinarySHA256 = strings.Repeat("a", 64)
	if err := bad.Validate(); err == nil {
		t.Fatal("cli asset with bundle aliases accepted")
	}
	// Codex Desktop's official archives now hold ChatGPT.app (26.908.70816).
	for _, builtIn := range DefaultAssets() {
		if builtIn.TargetID == TargetCodexDesktop && builtIn.PlatformName() == PlatformMacOS &&
			(builtIn.BundleName != "Codex.app" || len(builtIn.BundleAliases) != 1 || builtIn.BundleAliases[0] != "ChatGPT.app") {
			t.Fatalf("Codex Desktop bundle names = %q + %q", builtIn.BundleName, builtIn.BundleAliases)
		}
	}
}
