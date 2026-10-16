package main

import (
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
)

func TestRuntimeNames(t *testing.T) {
	t.Parallel()

	tests := []struct {
		goos, goarch   string
		platform, arch string
		ok             bool
	}{
		{goos: "darwin", goarch: "arm64", platform: "macos", arch: "arm64", ok: true},
		{goos: "darwin", goarch: "amd64", platform: "macos", arch: "x64", ok: true},
		{goos: "windows", goarch: "amd64", platform: "windows", arch: "x64", ok: true},
		{goos: "linux", goarch: "amd64"},
		{goos: "darwin", goarch: "386"},
		{goos: "windows", goarch: "386"},
	}
	for _, tt := range tests {
		platform, arch, ok := runtimeNames(tt.goos, tt.goarch)
		if platform != tt.platform || arch != tt.arch || ok != tt.ok {
			t.Fatalf("runtimeNames(%q, %q) = %q, %q, %v", tt.goos, tt.goarch, platform, arch, ok)
		}
	}
}

func TestConfigurationProfilesAreLockedAcrossEnvironments(t *testing.T) {
	t.Parallel()

	profiles := configurationProfiles()
	if len(profiles) != 3 {
		t.Fatalf("environments = %v", profiles)
	}
	production := profiles[configuration.EnvironmentProd]
	// codex_cli, claude_cli and claude_desktop; codex_desktop shares the
	// codex_cli profile because both read ~/.codex/config.toml.
	if len(production) != 3 {
		t.Fatalf("production profiles = %+v", production)
	}
	if _, exists := production[configuration.TargetCodexDesktop]; exists {
		t.Fatalf("codex_desktop must share the codex_cli profile: %+v", production)
	}
	if production[configuration.TargetCodexCLI].Version != codexConfigurationProfileVersion ||
		production[configuration.TargetClaudeCLI].Version != claudeConfigurationProfileVersion ||
		production[configuration.TargetClaudeDesktop].Version != claudeConfigurationProfileVersion {
		t.Fatalf("profile versions = %+v", production)
	}
	if production[configuration.TargetCodexCLI].BaseURL != "https://api.airick.cn/v1" ||
		production[configuration.TargetClaudeCLI].BaseURL != "https://api.airick.cn" ||
		production[configuration.TargetClaudeDesktop].BaseURL != "https://api.airick.cn" {
		t.Fatalf("gateway bases = %+v", production)
	}
	if production[configuration.TargetCodexCLI].Model != "gpt-5.6-luna" || production[configuration.TargetClaudeCLI].Model != "claude-sonnet-4-6" ||
		production[configuration.TargetClaudeCLI].Model != production[configuration.TargetClaudeDesktop].Model {
		t.Fatalf("gateway model aliases = %+v", production)
	}
	// Claude Desktop drops non-Claude model ids from its 3P model list, so its
	// alias must look like a Claude model.
	if !strings.HasPrefix(production[configuration.TargetClaudeDesktop].Model, "claude-") {
		t.Fatalf("claude_desktop model alias = %+v", production[configuration.TargetClaudeDesktop])
	}
	for _, asset := range install.DefaultAssets() {
		// The launch / configuration locks come from the same per-platform
		// table the assets are built from; the desktop releases differ per
		// platform, the CLIs do not.
		if asset.Version != install.LockedVersions(asset.PlatformName())[asset.TargetID] {
			t.Fatalf("install asset %+v does not match the launch lock", asset)
		}
	}
	if locks := install.LockedVersions(install.PlatformMacOS); locks[install.TargetCodexCLI] != lockedCodexVersion ||
		locks[install.TargetClaudeCLI] != lockedClaudeVersion || locks[install.TargetCodexDesktop] != lockedCodexDesktopVersion ||
		locks[install.TargetClaudeDesktop] != lockedClaudeDesktopVersion {
		t.Fatalf("macOS locks = %v", locks)
	}
	if locks := install.LockedVersions(install.PlatformWindows); locks[install.TargetCodexCLI] != lockedCodexVersion ||
		locks[install.TargetClaudeCLI] != lockedClaudeVersion || locks[install.TargetCodexDesktop] != install.LockedCodexDesktopVersionWindows ||
		locks[install.TargetClaudeDesktop] != install.LockedClaudeDesktopVersionWindows {
		t.Fatalf("Windows locks = %v", locks)
	}
	if dev, exists := profiles[configuration.EnvironmentDev]; !exists ||
		dev[configuration.TargetCodexCLI] != production[configuration.TargetCodexCLI] ||
		dev[configuration.TargetClaudeCLI] != production[configuration.TargetClaudeCLI] ||
		dev[configuration.TargetClaudeDesktop] != production[configuration.TargetClaudeDesktop] {
		t.Fatalf("dev profiles must use the locked relay with locally issued credentials: %+v", dev)
	}
	// The test environment shares the relay profile so test builds can reach L3.
	if test, exists := profiles[configuration.EnvironmentTest]; !exists ||
		test[configuration.TargetCodexCLI] != production[configuration.TargetCodexCLI] ||
		test[configuration.TargetClaudeCLI] != production[configuration.TargetClaudeCLI] ||
		test[configuration.TargetClaudeDesktop] != production[configuration.TargetClaudeDesktop] {
		t.Fatalf("test profiles = %+v, want the same relay profiles as production", test)
	}
}

func TestCredentialEndpointsAreBuildTimeFixed(t *testing.T) {
	t.Parallel()

	endpoints := credentialEndpoints()
	wants := map[credential.Environment]credential.Endpoints{
		credential.EnvironmentDev: {
			RegisterURL: "http://localhost:8080/api/agent-bus/v1/local-coding-tools/devices",
			ExchangeURL: "http://localhost:8080/api/agent-bus/v1/local-coding-tools/credentials/exchange",
		},
		credential.EnvironmentTest: {
			RegisterURL: "https://aigc-chat-web.yixin.com/api/agent-bus/v1/local-coding-tools/devices",
			ExchangeURL: "https://aigc-chat-web.yixin.com/api/agent-bus/v1/local-coding-tools/credentials/exchange",
		},
		credential.EnvironmentProd: {
			RegisterURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/devices",
			ExchangeURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange",
		},
	}
	if len(endpoints) != len(wants) {
		t.Fatalf("endpoint environments = %d, want %d", len(endpoints), len(wants))
	}
	for environment, want := range wants {
		if got := endpoints[environment]; got != want {
			t.Fatalf("%s endpoints = %+v, want %+v", environment, got, want)
		}
	}
}
