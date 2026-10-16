//go:build windows

package install

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsSubjectCommonName(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		`CN="Anthropic, PBC", O="Anthropic, PBC", L=San Francisco, C=US`: "Anthropic, PBC",
		`CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B`:                        "50BDFD77-8903-4850-9FFE-6E8522F64D5B",
		`O=Example, CN=Example Signer, C=US`:                             "Example Signer",
		`OU=Nope`:                                                        "",
		`XCN=Evil, CN=Real`:                                              "Real",
	}
	for subject, want := range cases {
		if got := subjectCommonName(subject); got != want {
			t.Fatalf("subjectCommonName(%q) = %q, want %q", subject, got, want)
		}
	}
}

// TestWindowsRealPackageVerification runs the package checks against a real
// MSIX named by ZB_MSIX (and the signer CN in ZB_SIGNER), printing every
// intermediate value; it is how a PUBLISHER_MISMATCH is diagnosed on a machine.
func TestWindowsRealPackageVerification(t *testing.T) {
	packagePath := os.Getenv("ZB_MSIX")
	if packagePath == "" {
		t.Skip("set ZB_MSIX to a package to verify")
	}
	signer := os.Getenv("ZB_SIGNER")
	script := "$s = Get-AuthenticodeSignature -LiteralPath " + psQuote(packagePath) + "; " +
		"Write-Output ('STATUS=' + $s.Status); Write-Output ('MESSAGE=' + $s.StatusMessage); " +
		"if ($s.SignerCertificate) { Write-Output ('SUBJECT=' + $s.SignerCertificate.Subject) }; exit 0"
	output, code, err := runPowerShell(context.Background(), bundleVerifyTimeout, script)
	t.Logf("raw signature probe: code=%d err=%v\n%s", code, err, output)
	t.Logf("authenticodeVerify(%q) = %v", signer, authenticodeVerify(context.Background(), packagePath, signer))
	identity, err := readAppxIdentity(packagePath)
	t.Logf("readAppxIdentity = %+v, %v", identity, err)
	linked := packagePath + ".linked.msix"
	_ = os.Remove(linked)
	if err := os.Link(packagePath, linked); err != nil {
		t.Logf("os.Link = %v", err)
	} else {
		defer os.Remove(linked)
		t.Logf("authenticodeVerify(link) = %v", authenticodeVerify(context.Background(), linked, signer))
	}
}

func TestWindowsBundleToolsAnswerOnTheRealMachine(t *testing.T) {
	// An empty scratch folder runs nothing; the signature check refuses an
	// unsigned file; the elevation probe answers something for this account.
	inUse, err := processRunsUnder(t.TempDir())
	if err != nil || inUse {
		t.Fatalf("processRunsUnder(empty) = %v, %v", inUse, err)
	}
	unsigned := filepath.Join(t.TempDir(), "plain.exe")
	if err := os.WriteFile(unsigned, []byte("MZ not signed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := authenticodeVerify(context.Background(), unsigned, "Anthropic, PBC"); err == nil {
		t.Fatal("an unsigned file must not verify")
	}
	t.Logf("canElevate = %v", canElevate())
	if _, err := readAppxIdentity(unsigned); err == nil {
		t.Fatal("a non-zip must not parse as a package")
	}
}
