//go:build windows

package install

import (
	"bufio"
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Exercise the real embedded worker and named-pipe protocol, without elevating
// or installing anything. ZB_MSIX optionally adds real package verification,
// with only the final Add-AppxPackage call intercepted.
func TestRegistrationWorkerProtocol(t *testing.T) {
	cases := []string{"disconnect", "invalid command", "wrong hash", "unsigned package"}
	if os.Getenv("ZB_MSIX") != "" {
		cases = append(cases, "verified package")
	}
	for _, test := range cases {
		t.Run(test, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			account, err := user.Current()
			if err != nil {
				t.Fatal(err)
			}
			pipeName, err := randomName("zhiban-msix-test-")
			if err != nil {
				t.Fatal(err)
			}
			// Quotes, spaces, non-ASCII and shell metacharacters must stay data.
			path := filepath.Join(t.TempDir(), "安装 ' $() ` package.msix")
			payload := []byte("unsigned fixture; never a package")
			digest := fmt.Sprintf("%x", sha256.Sum256(payload))
			if test == "wrong hash" {
				digest = strings.Repeat("0", 64)
			}
			asset := Asset{PackageName: "OpenAI.Codex", Version: "26.930.7945", Arch: ArchX64, SignerName: "test", Sources: []Source{{Layout: LayoutMSIX, Size: int64(len(payload)), SHA256: digest}}}
			sentinel := filepath.Join(t.TempDir(), "verified.txt")
			if test == "verified package" {
				path = os.Getenv("ZB_MSIX")
				identity, err := readAppxIdentity(path)
				if err != nil {
					t.Fatal(err)
				}
				digest, size, err := fileSHA256(path)
				if err != nil {
					t.Fatal(err)
				}
				asset.PackageName, asset.Version, asset.Arch = identity.Name, identity.Version[:strings.LastIndex(identity.Version, ".")], identity.Arch
				asset.SignerName = os.Getenv("ZB_SIGNER")
				asset.Sources = []Source{{Layout: LayoutMSIX, Size: size, SHA256: digest}}
			}
			script := packageRegistrationScript(asset, path, ModeInstall, pipeName, account.Uid)
			script = strings.Replace(script, "    # Only a numeric", "    Write-Output $_.Exception.Message\n    # Only a numeric", 1)
			if test == "verified package" {
				// Only the final OS registration is intercepted in this test.
				script = "function Add-AppxPackage { param($Path, $ErrorAction) $locked=$false; try { $h=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $h.Dispose() } catch [IO.IOException] { $locked=$true }; if(-not $locked){throw 'package was writable'}; [IO.File]::WriteAllText(" + psQuote(sentinel) + ",'verified and locked') };\n" + script
			}
			done := make(chan struct{})
			var output []byte
			var code int
			var runErr error
			go func() { output, code, runErr = runPowerShell(ctx, 90*time.Second, script); close(done) }()
			worker := &windowsPackageRegistration{cancel: cancel, done: done}
			defer worker.Close()
			for worker.pipe == nil {
				select {
				case <-ctx.Done():
					t.Fatalf("worker did not connect: %v", ctx.Err())
				case <-done:
					t.Fatalf("worker exited before authorization: code=%d err=%v output=%s", code, runErr, output)
				case <-time.After(50 * time.Millisecond):
					worker.pipe, _ = os.OpenFile(`\\.\pipe\`+pipeName, os.O_RDWR, 0)
				}
			}
			worker.reader = bufio.NewReader(worker.pipe)
			if line, err := worker.readLine(ctx); err != nil || line != "ready" {
				t.Fatalf("ready=%q err=%v", line, err)
			}
			// No package exists yet. Readiness must precede even the download.
			if _, err := os.Stat(path); test != "verified package" && !os.IsNotExist(err) {
				t.Fatal("package unexpectedly exists")
			}
			switch test {
			case "verified package":
				if err := worker.Register(ctx); err != nil {
					<-done
					t.Fatalf("%v output=%s", err, output)
				}
				if _, err := os.Stat(sentinel); err != nil {
					t.Fatal("registration was not reached", err)
				}
			case "disconnect":
				_ = worker.pipe.Close()
			case "invalid command":
				_, _ = worker.pipe.Write([]byte("run arbitrary command\n"))
			default:
				if err := os.WriteFile(path, payload, 0600); err != nil {
					t.Fatal(err)
				}
				if err := worker.Register(ctx); err == nil {
					t.Fatal("invalid package accepted")
				}
			}
			select {
			case <-ctx.Done():
				t.Fatal("worker survived cancellation or rejection")
			case <-done:
				want := 0
				if test == "wrong hash" || test == "unsigned package" {
					want = 3
				}
				if code != want || runErr != nil {
					t.Fatalf("exit=%d want=%d err=%v output=%s", code, want, runErr, output)
				}
			}
		})
	}
}

// Opt-in test for a human-operated Windows desktop. It asks for consent then
// immediately releases the worker; it never downloads or registers a package.
func TestInteractiveEarlyAuthorization(t *testing.T) {
	if os.Getenv("ZB_UAC_HANDSHAKE") != "1" {
		t.Skip("set ZB_UAC_HANDSHAKE=1 only for interactive consent testing")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	asset := Asset{TargetID: TargetCodexDesktop, Platform: PlatformWindows, Arch: ArchX64, PackageName: "OpenAI.Codex", SignerName: "50BDFD77-8903-4850-9FFE-6E8522F64D5B", Version: "26.930.7945", Sources: []Source{{Layout: LayoutMSIX, Size: 1, SHA256: strings.Repeat("0", 64)}}}
	path := filepath.Join(t.TempDir(), "not-downloaded.msix")
	w, reason, err := startPackageRegistration(ctx, asset, path, ModeInstall)
	if err != nil {
		t.Fatalf("%s: %v", reason, err)
	}
	w.Close()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("unexpected package download")
	}
	select {
	case <-w.done:
	case <-time.After(5 * time.Second):
		t.Fatal("worker launcher did not close")
	}
	t.Log("Consent accepted before download; worker closed without installation")
}
