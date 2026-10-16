package appx

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
)

const claudeManifest = `<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10">
  <Identity Name="Claude" Publisher="CN=&quot;Anthropic, PBC&quot;, O=&quot;Anthropic, PBC&quot;, C=US" Version="1.49585.0.0" ProcessorArchitecture="x64" />
  <Properties><DisplayName>Claude</DisplayName></Properties>
  <Applications>
    <Application Id="Claude" Executable="app\Claude.exe" EntryPoint="Windows.FullTrustApplication" />
  </Applications>
</Package>`

func TestParseFullNameAndReleaseVersion(t *testing.T) {
	t.Parallel()
	full, ok := ParseFullName("Claude_1.49585.0.0_x64__pzs8sxrjxfjjc")
	if !ok || full.Name != "Claude" || full.Version != "1.49585.0.0" || full.Architecture != "x64" || full.ResourceID != "" || full.PublisherID != "pzs8sxrjxfjjc" {
		t.Fatalf("ParseFullName = %+v, %v", full, ok)
	}
	if full.FamilyName() != "Claude_pzs8sxrjxfjjc" {
		t.Fatalf("FamilyName = %q", full.FamilyName())
	}
	codex, ok := ParseFullName("OpenAI.Codex_26.903.8094.0_x64__2p2nqsd0c76g0")
	if !ok || codex.Name != "OpenAI.Codex" || codex.FamilyName() != "OpenAI.Codex_2p2nqsd0c76g0" {
		t.Fatalf("ParseFullName(codex) = %+v, %v", codex, ok)
	}
	for _, bad := range []string{"", "Claude_1.2.3_x64__pzs8sxrjxfjjc", "Claude_1.2.3.4_x64_pzs8sxrjxfjjc", "Claude_1.2.3.4_x64__PZS8SXRJXFJJC", "a_b_c_d_e_f"} {
		if _, ok := ParseFullName(bad); ok {
			t.Fatalf("ParseFullName(%q) accepted", bad)
		}
	}
	if release, ok := ReleaseVersion("26.903.8094.0"); !ok || release != "26.903.8094" {
		t.Fatalf("ReleaseVersion = %q, %v", release, ok)
	}
	if _, ok := ReleaseVersion("1.2.3"); ok {
		t.Fatal("three-part version is not a package version")
	}
}

func TestReadManifestDirAndPackage(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ManifestName), []byte(claudeManifest), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, err := ReadManifestDir(root)
	if err != nil || manifest.Name != "Claude" || manifest.Version != "1.49585.0.0" || manifest.Architecture != "x64" ||
		manifest.AppID != "Claude" || manifest.Publisher != `CN="Anthropic, PBC", O="Anthropic, PBC", C=US` {
		t.Fatalf("ReadManifestDir = %+v, %v", manifest, err)
	}
	packagePath := filepath.Join(root, "Claude.msix")
	file, err := os.Create(packagePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, content := range map[string]string{"app/Claude.exe": "MZ", ManifestName: claudeManifest} {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	fromPackage, err := ReadManifestPackage(packagePath)
	if err != nil || fromPackage != manifest {
		t.Fatalf("ReadManifestPackage = %+v, %v", fromPackage, err)
	}
	if _, err := ReadManifestDir(t.TempDir()); err == nil {
		t.Fatal("missing manifest must fail")
	}
	if _, err := ParseManifest([]byte(`<Package><Identity Name="X" Version="1.0.0.0"/></Package>`)); err == nil {
		t.Fatal("manifest without an application must fail")
	}
}
