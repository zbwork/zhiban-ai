//go:build darwin

package netproxy

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

func TestShellBlockReplaceIsIdempotentAndKeepsUserContent(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "dotfiles-zshrc")
	original := "export PATH=/opt/bin:$PATH\nalias ll='ls -l'\n"
	if err := os.WriteFile(real, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, ".zshrc")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	hosts := []string{"api.airick.cn", ".airick.cn"}
	for i := 0; i < 2; i++ {
		if err := replaceBlock(link, posixBlock(hosts)); err != nil {
			t.Fatal(err)
		}
	}
	content, _ := os.ReadFile(real)
	if strings.Count(string(content), blockBegin) != 1 || !strings.HasPrefix(string(content), original) {
		t.Fatalf("after apply:\n%s", content)
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("symlinked dotfile was replaced")
	}
	if info, _ := os.Stat(real); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
	if got := stripBlock(string(content)); got != original {
		t.Fatalf("user content changed: %q", got)
	}
}

func TestParseScutilProxyPrefersHTTPS(t *testing.T) {
	output := []byte("<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 7890\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 1\n  HTTPSPort : 7897\n  HTTPSProxy : 127.0.0.1\n}\n")
	if got := parseScutilProxy(output); !got.Enabled || got.Endpoint != "127.0.0.1:7897" {
		t.Fatalf("got %+v", got)
	}
	if got := parseScutilProxy([]byte("<dictionary> {\n  HTTPSEnable : 0\n}\n")); got.Enabled {
		t.Fatalf("disabled proxy reported enabled: %+v", got)
	}
}

// A login shell that loads nvm takes about two seconds to start (2026-09-17
// production Mac: 1.7–2.2 s) and used to be killed by the lookup's timeout.
// "Could not read NO_PROXY" then counted as "not exempted": the card asked for
// a fix that was already in place, and 修复并重试 could never clear it. When
// the shell does not answer, the block Zhiban wrote is what is judged.
func TestShellCoverageFallsBackToTheMarkedBlockWhenTheShellNeverAnswers(t *testing.T) {
	hosts := []string{"api.airick.cn", ".airick.cn", "airick.cn"}
	fakeShell := func(t *testing.T, dir, body string) string {
		path := filepath.Join(dir, "zsh") // the base name selects ~/.zshrc
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		return path
	}
	shellCovered := func(home, shell string, timeout time.Duration) bool {
		lookup := &shellenv.LoginShellLookup{HomeDir: home, Shell: shell, Timeout: timeout, TTL: time.Minute}
		platform := &darwinPlatform{homeDir: home, lookup: lookup}
		return platform.coverage(context.Background(), hosts)["shell"]
	}

	t.Run("silent shell, block in place", func(t *testing.T) {
		home := t.TempDir()
		if err := replaceBlock(filepath.Join(home, ".zshrc"), posixBlock(hosts)); err != nil {
			t.Fatal(err)
		}
		if !shellCovered(home, fakeShell(t, t.TempDir(), "sleep 5"), 300*time.Millisecond) {
			t.Fatal("a shell that timed out hid the block Zhiban wrote")
		}
	})
	t.Run("silent shell, no block", func(t *testing.T) {
		home := t.TempDir()
		if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte("export PATH=/opt/bin:$PATH\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if shellCovered(home, fakeShell(t, t.TempDir(), "sleep 5"), 300*time.Millisecond) {
			t.Fatal("nothing exempts the gateway here")
		}
	})
	t.Run("silent shell, block of an older gateway", func(t *testing.T) {
		home := t.TempDir()
		if err := replaceBlock(filepath.Join(home, ".zshrc"), posixBlock([]string{"old.example"})); err != nil {
			t.Fatal(err)
		}
		if shellCovered(home, fakeShell(t, t.TempDir(), "sleep 5"), 300*time.Millisecond) {
			t.Fatal("the block names another gateway")
		}
	})
	t.Run("answering shell is believed over the file", func(t *testing.T) {
		home := t.TempDir()
		if err := replaceBlock(filepath.Join(home, ".zshrc"), posixBlock(hosts)); err != nil {
			t.Fatal(err)
		}
		// The shell answers and its NO_PROXY lacks the hosts (something later
		// in the startup files overwrote it): that is a real gap.
		answers := `printf '\n__ZHIBAN_ENV__NO_PROXY=%s\n' 'localhost'; printf '\n__ZHIBAN_ENV__no_proxy=%s\n' ''`
		// A generous timeout: the first exec of a freshly written script can
		// take a few hundred milliseconds on macOS.
		if shellCovered(home, fakeShell(t, t.TempDir(), answers), 10*time.Second) {
			t.Fatal("an answering shell without the hosts must not be covered by the file alone")
		}
	})
}

func TestParseScutilExceptionsAndNetworksetupListings(t *testing.T) {
	scutil := []byte("<dictionary> {\n  ExceptionsList : <array> {\n    0 : 127.0.0.1\n    1 : *.local\n    2 : *.airick.cn\n    3 : airick.cn\n  }\n  HTTPSEnable : 1\n  HTTPSPort : 7897\n  HTTPSProxy : 127.0.0.1\n}\n")
	if got := parseScutilExceptions(scutil); len(got) != 4 || got[2] != "*.airick.cn" || got[3] != "airick.cn" {
		t.Fatalf("parseScutilExceptions = %v", got)
	}
	if got := parseScutilExceptions([]byte("<dictionary> {\n  HTTPEnable : 0\n}\n")); len(got) != 0 {
		t.Fatalf("no ExceptionsList = %v", got)
	}
	services := []byte("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\n\n")
	if got := parseNetworkServices(services); len(got) != 2 || got[0] != "Wi-Fi" || got[1] != "USB 10/100/1000 LAN" {
		t.Fatalf("parseNetworkServices = %v", got)
	}
	if got := parseBypassDomains([]byte("127.0.0.1\n*.local\n<local>\n")); len(got) != 3 || got[2] != "<local>" {
		t.Fatalf("parseBypassDomains = %v", got)
	}
	if got := parseBypassDomains([]byte("There aren't any bypass domains set on Wi-Fi.\n")); len(got) != 0 {
		t.Fatalf("empty bypass list = %v", got)
	}
}
