package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/app"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/diagnostics"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/gatewaymodels"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/launch"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/netproxy"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellpath"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/verify"
)

var (
	bridgeVersion        = "0.3.0-dev"
	devClientAPIBaseURL  = "http://localhost:8080/api/agent-bus/v1"
	testClientAPIBaseURL = "https://aigc-chat-web.yixin.com/api/agent-bus/v1"
	prodClientAPIBaseURL = "https://zb.qkfintech.cn/api/agent-bus/v1"

	codexConfigurationProfileVersion  = "2026.09.07.1"
	claudeConfigurationProfileVersion = "2026.09.07.1"
	// The gateway relay serves both protocols on api.airick.cn (the same
	// account as api.beeaicloud.com). Codex (CLI and desktop, OpenAI protocol)
	// pins the GPT alias the key is authorised for.
	prodCodexGatewayBaseURL  = "https://api.airick.cn/v1"
	prodClaudeGatewayBaseURL = "https://api.airick.cn"
	prodGatewayModelAlias    = "gpt-5.6-luna"
	// Claude Code and Claude Desktop (Anthropic protocol) pin the Claude route
	// the relay exposes for the key. Claude Desktop only lists models whose ids
	// look like Claude models (spike S2: "gpt-5.6-luna" is removed from
	// inferenceModels at launch); Claude Code used the GPT alias until the
	// relay's Claude group accepted `thinking` (verified 2026-09-09: the group
	// serves claude-sonnet-4-6 / claude-opus-4-6 with thinking on all three
	// protocols), after which both Claude targets share this alias.
	prodClaudeModelAlias       = "claude-sonnet-4-6"
	lockedCodexVersion         = install.LockedCodexVersion
	lockedClaudeVersion        = install.LockedClaudeVersion
	lockedCodexDesktopVersion  = install.LockedCodexDesktopVersion
	lockedClaudeDesktopVersion = install.LockedClaudeDesktopVersion
)

// verifyFallbackModels are the preferred fallbacks when the configured model
// fails on the relay's side, so one model's route being down is not reported
// as the relay being down (contract §2.7 L3 备用模型). Picked 2026-09-20 from
// what the relay's 知办AI group serves: all answered within 2–4 s, on both
// protocols. They are only a preference: the relay groups keys by plan and
// the free group serves neither Claude one (2026-09-21), so the verifier
// picks from the models the member's key can see (VisibleModels below).
var verifyFallbackModels = map[string][]string{
	verify.TargetCodexCLI:  {"gpt-5.6-terra", "gpt-5.5"},
	verify.TargetClaudeCLI: {"claude-sonnet-5", "claude-haiku-4-5-20251001"},
}

func main() {
	platform, arch, ok := runtimeNames(runtime.GOOS, runtime.GOARCH)
	if !ok {
		_, _ = fmt.Fprintln(os.Stderr, "unsupported bridge runtime")
		os.Exit(2)
	}
	arguments := os.Args[1:]
	if len(arguments) == 0 {
		// Claude Desktop on Windows runs its credential helper with no
		// arguments: a copy of this binary under the helper name is that
		// helper (configuration.ClaudeDesktopHelperExecutable).
		if executable, err := os.Executable(); err == nil &&
			strings.EqualFold(filepath.Base(executable), configuration.ClaudeDesktopHelperExecutable) {
			arguments = []string{"credential", "get", "--target", configuration.TargetClaudeDesktop}
		}
	}
	homeDir, err := os.UserHomeDir()
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	detector, err := detect.NewSystemDetector(homeDir)
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	credentials, err := credential.NewManager(credential.ManagerConfig{
		Store:     credential.NewSystemCredentialStore(),
		Endpoints: credentialEndpoints(),
	})
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	helperExecutable, err := os.Executable()
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	if resolvedHelper, resolveErr := filepath.EvalSymlinks(helperExecutable); resolveErr == nil {
		helperExecutable = resolvedHelper
	}
	// npm-installed CLIs need the user's Node runtime on PATH when the Bridge
	// runs them (post-switch probe, L3 verification); contract §2.7.
	nodeLookup := shellenv.NewLoginShellLookup(homeDir)
	// The system proxy intercepting the gateway (contract §2.7 network.*): the
	// exemption only ever names the compiled gateway hosts.
	var gatewayURLs []string
	for _, byTarget := range configurationProfiles() {
		for _, profile := range byTarget {
			gatewayURLs = append(gatewayURLs, profile.BaseURL)
		}
	}
	networkProxy := netproxy.NewManager(netproxy.Config{
		HomeDir: homeDir, GatewayURLs: gatewayURLs, Lookup: nodeLookup,
	})
	modelListClient := credential.NewSecureHTTPClient()
	configurations, err := configuration.NewManager(configuration.ManagerConfig{
		HomeDir:          homeDir,
		HelperExecutable: helperExecutable,
		NodeLookup:       nodeLookup,
		// The Codex model catalog (contract §2.7.2 "模型选择"): every trusted
		// Codex sharing ~/.codex/config.toml, and the relay group's model ids.
		CodexExecutables: func(ctx context.Context) ([]string, error) {
			var paths []string
			for _, target := range []string{configuration.TargetCodexCLI, configuration.TargetCodexDesktop} {
				found, detectErr := detector.TrustedExecutables(ctx, target)
				if detectErr != nil {
					return nil, detectErr
				}
				paths = append(paths, found...)
			}
			return paths, nil
		},
		GatewayModelIDs: func(ctx context.Context, targetID, baseURL string) ([]string, error) {
			token, exchangeErr := credentials.ExchangeToken(ctx, targetID)
			if exchangeErr != nil {
				return nil, exchangeErr
			}
			return gatewaymodels.List(ctx, modelListClient, baseURL, token)
		},
		Profiles: configurationProfiles(),
		// The desktop applications are different releases per platform
		// (install.LockedVersions); the CLIs are the same everywhere.
		SupportedVersions: install.LockedVersions(platform),
		ResolveInstallation: func(ctx context.Context, targetID, installationID string) (configuration.Installation, error) {
			resolved, resolveErr := detector.ResolveInstallation(ctx, targetID, installationID)
			if resolveErr != nil {
				return configuration.Installation{}, configuration.ErrInstallationChanged
			}
			return configuration.Installation{
				TargetID: resolved.TargetID, InstallationID: resolved.InstallationID,
				Executable: resolved.RealPath, Version: resolved.Version,
			}, nil
		},
		ResolveAuthorization: func(ctx context.Context, targetID string) (configuration.AuthorizationProfile, error) {
			profile, profileErr := credentials.ConfigurationProfile(ctx, targetID)
			if profileErr != nil {
				if errors.Is(profileErr, credential.ErrAuthorizationMissing) {
					return configuration.AuthorizationProfile{}, configuration.ErrAuthorizationMissing
				}
				return configuration.AuthorizationProfile{}, configuration.ErrProfileUnavailable
			}
			return configuration.AuthorizationProfile{
				Environment: configuration.Environment(profile.Environment), ProfileVersion: profile.ProfileVersion,
			}, nil
		},
	})
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	tickets, err := launch.NewFileTicketStore(homeDir, launch.DefaultLaunchRoot(homeDir), helperExecutable)
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	launches, err := launch.NewManager(launch.ManagerConfig{
		HomeDir:           homeDir,
		SupportedVersions: install.LockedVersions(platform),
		ResolveBookmark:   launch.NewMacOSBookmarkResolver(),
		ResolveInstallation: func(ctx context.Context, targetID, installationID string) (launch.Installation, error) {
			resolved, resolveErr := detector.ResolveInstallation(ctx, targetID, installationID)
			if resolveErr != nil {
				return launch.Installation{}, launch.ErrInstallationChanged
			}
			return launch.Installation{
				TargetID: resolved.TargetID, InstallationID: resolved.InstallationID,
				Executable: resolved.RealPath, Version: resolved.Version,
			}, nil
		},
		ResolveCurrentInstallation: func(ctx context.Context, targetID string) ([]launch.Installation, error) {
			resolved, resolveErr := detector.ResolveCurrentInstallations(ctx, targetID)
			if resolveErr != nil {
				return nil, launch.ErrInstallationChanged
			}
			installations := make([]launch.Installation, 0, len(resolved))
			for _, item := range resolved {
				installations = append(installations, launch.Installation{
					TargetID: item.TargetID, InstallationID: item.InstallationID,
					Executable: item.RealPath, Version: item.Version,
				})
			}
			return installations, nil
		},
		ResolveConfiguration: func(ctx context.Context, targetID, profileVersion string) (launch.Configuration, error) {
			resolved, resolveErr := configurations.ResolveLaunchConfiguration(ctx, targetID, profileVersion)
			if resolveErr != nil {
				return launch.Configuration{}, launch.ErrConfigurationChanged
			}
			return launch.Configuration{
				TargetID: resolved.TargetID, ProfileVersion: resolved.ProfileVersion,
				Arguments: resolved.Arguments,
			}, nil
		},
		Tickets:         tickets,
		OpenTerminal:    launch.NewMacOSTerminalOpener(homeDir),
		Execute:         launch.NewMacOSExecutor(),
		OpenApplication: launch.NewMacOSApplicationOpener(),
	})
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	// Persistent so the failure an operation records survives into the next
	// Bridge process the App starts to read it.
	recorder := diagnostics.NewPersistentRecorder(bridgeVersion, nil, diagnostics.DefaultPath(homeDir))
	operations := operation.NewRegistry(operation.WithObserver(recorder.Observe))
	installs, err := install.NewManager(install.ManagerConfig{
		HomeDir: homeDir, Platform: platform, Arch: arch, BridgeVersion: bridgeVersion,
		Assets: install.DefaultAssets(), Detect: detector.Detect, Operations: operations,
		// M3 Task 8: component installs read the pinned Claude Code host
		// manifest from the installed Claude.app.
		ResolveInstallation: detector.ResolveInstallation,
		// F31 version catalog: the last applied catalog survives the process.
		CatalogStore: catalog.NewStore(catalog.DefaultPath(homeDir)),
		// 接管安装(mode=adopt):落位后还要让用户自己的终端解析到这一份。
		EnsureShellResolves: shellPathEnsurer(homeDir, nodeLookup).Ensure,
	})
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	verifier, err := verify.NewManager(verify.ManagerConfig{
		NodeLookup:          nodeLookup,
		ProxyEnvironment:    networkProxy.ProbeEnvironment,
		ProxyRisk:           networkProxy.EnvNeedsFix,
		GatewayUnreachable:  networkProxy.DirectPathUnreachable,
		TrafficDiverted:     networkProxy.TrafficDiverted,
		FallbackModels:      verifyFallbackModels,
		HomeDir:             homeDir,
		Operations:          operations,
		ConfigurationStatus: configurations.Status,
		ComponentsReady: func(ctx context.Context, targetID string) error {
			state, err := detector.Detect(ctx, targetID)
			if err != nil {
				return err
			}
			for _, component := range state.Components {
				if component.State != claudecode.StatePresent {
					return fmt.Errorf("component %s is %s", component.ID, component.State)
				}
			}
			return nil
		},
		ResolveInstallation: func(ctx context.Context, targetID, installationID string) (verify.Installation, error) {
			resolved, resolveErr := detector.ResolveInstallation(ctx, targetID, installationID)
			if resolveErr != nil {
				return verify.Installation{}, resolveErr
			}
			return verify.Installation{
				TargetID: resolved.TargetID, InstallationID: resolved.InstallationID,
				Executable: resolved.RealPath, Version: resolved.Version,
			}, nil
		},
		ManagedArguments: func(ctx context.Context, targetID, profileVersion string) ([]string, error) {
			resolved, resolveErr := configurations.ResolveLaunchConfiguration(ctx, targetID, profileVersion)
			if resolveErr != nil {
				return nil, resolveErr
			}
			return resolved.Arguments, nil
		},
		ExchangeToken:      credentials.ExchangeToken,
		RecordVerification: configurations.RecordVerification,
		RecordGlobal:       configurations.RecordGlobalVerification,
		RefreshGlobal:      configurations.RefreshGlobalModelCatalog,
		DefaultModels: map[string]string{
			verify.TargetCodexCLI: prodGatewayModelAlias, verify.TargetClaudeCLI: prodClaudeModelAlias,
		},
		// One OpenAI-style list serves both families: the relay answers
		// {base}/models with every model of the key's group.
		VisibleModels: func(ctx context.Context, targetID string) ([]string, error) {
			token, exchangeErr := credentials.ExchangeToken(ctx, targetID)
			if exchangeErr != nil {
				return nil, exchangeErr
			}
			return gatewaymodels.List(ctx, modelListClient, prodCodexGatewayBaseURL, token)
		},
	})
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "bridge initialization failed")
		os.Exit(1)
	}
	os.Exit(app.Run(context.Background(), arguments, os.Stdin, os.Stdout, os.Stderr, app.Config{
		BridgeVersion:  bridgeVersion,
		Platform:       platform,
		Arch:           arch,
		Detector:       detector,
		Credentials:    credentials,
		Configurations: configurations,
		Launches:       launches,
		Installs:       installs,
		Catalog:        installs,
		Verifier:       verifier,
		Operations:     operations,
		Diagnostics:    recorder,
		NetworkProxy:   networkProxy,
	}))
}

// configurationProfiles returns the build-time gateway profiles. The test
// environment (test Bus + test builds such as 11903) uses the same relay as
// production because there is no separate test relay. Local dev uses that same
// relay with credentials issued by the loopback Bus, bound to the dev environment.
func configurationProfiles() map[configuration.Environment]map[string]configuration.GatewayProfile {
	relay := map[string]configuration.GatewayProfile{
		configuration.TargetCodexCLI: {
			Version: codexConfigurationProfileVersion, BaseURL: prodCodexGatewayBaseURL, Model: prodGatewayModelAlias,
		},
		configuration.TargetClaudeCLI: {
			Version: claudeConfigurationProfileVersion, BaseURL: prodClaudeGatewayBaseURL, Model: prodClaudeModelAlias,
		},
		// Codex Desktop shares the codex_cli profile (same config.toml);
		// both Claude targets use the Claude-named route (see prodClaudeModelAlias).
		configuration.TargetClaudeDesktop: {
			Version: claudeConfigurationProfileVersion, BaseURL: prodClaudeGatewayBaseURL, Model: prodClaudeModelAlias,
		},
	}
	return map[configuration.Environment]map[string]configuration.GatewayProfile{
		configuration.EnvironmentDev:  relay,
		configuration.EnvironmentTest: relay,
		configuration.EnvironmentProd: relay,
	}
}

func credentialEndpoints() map[credential.Environment]credential.Endpoints {
	return map[credential.Environment]credential.Endpoints{
		credential.EnvironmentDev:  endpointPair(devClientAPIBaseURL),
		credential.EnvironmentTest: endpointPair(testClientAPIBaseURL),
		credential.EnvironmentProd: endpointPair(prodClientAPIBaseURL),
	}
}

func endpointPair(clientAPIBaseURL string) credential.Endpoints {
	base := strings.TrimRight(clientAPIBaseURL, "/")
	return credential.Endpoints{
		RegisterURL: base + "/local-coding-tools/devices",
		ExchangeURL: base + "/local-coding-tools/credentials/exchange",
	}
}

func runtimeNames(goos, goarch string) (string, string, bool) {
	switch goos {
	case "darwin":
		switch goarch {
		case "arm64":
			return "macos", "arm64", true
		case "amd64":
			return "macos", "x64", true
		}
	case "windows":
		if goarch == "amd64" {
			return "windows", "x64", true
		}
	}
	return "", "", false
}

// shellPathEnsurer arranges the user's own PATH for an adopted target: on Unix
// through the same login-shell lookup the rest of the Bridge asks "which copy
// does the user actually run", on Windows through the per-user PATH.
func shellPathEnsurer(homeDir string, lookup *shellenv.LoginShellLookup) *shellpath.Ensurer {
	ensurer := &shellpath.Ensurer{
		HomeDir: homeDir,
		// 与配置备份同一个目录(.../local-coding-tools/backups),按平台由目录路径推出。
		BackupDir: filepath.Join(filepath.Dir(filepath.Dir(catalog.DefaultPath(homeDir))), "backups"),
	}
	// Windows 没有登录 shell(lookup 为 nil):那边看的是注册表里的用户 PATH,
	// 由 shellpath 自己读写。
	if lookup != nil {
		ensurer.Shell = lookup.Shell
		ensurer.Lookup = lookup.Lookup
		ensurer.Invalidate = lookup.Invalidate
	}
	return ensurer
}
