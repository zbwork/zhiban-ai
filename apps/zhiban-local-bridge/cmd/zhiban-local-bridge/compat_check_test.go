//go:build compatcheck

package main

// Compatibility check for new Codex CLI / Claude Code releases (F31 §12.4
// "新版本兼容性检查"). It runs the production switch_global, post-switch probe,
// verify.execute (global scope, one real gateway request) and restore_global
// code paths against a real executable inside a throwaway HOME, so a release
// that changes its configuration format, --version output or credential
// helper handling is caught before users upgrade into it. The user's own
// configuration is never read or written.
//
//	ZHIBAN_COMPAT_CODEX=latest ZHIBAN_COMPAT_CLAUDE=latest \
//	  go test -tags compatcheck -run TestCompatibility -v -count=1 -timeout 30m ./cmd/zhiban-local-bridge
//
// ZHIBAN_COMPAT_CODEX / ZHIBAN_COMPAT_CLAUDE: "latest", a version such as
// "0.154.0" (downloaded from npmmirror, integrity checked, cached), or the
// absolute path of an installed executable; unset skips that tool.
// The gateway token comes from ZHIBAN_COMPAT_TOKEN or from a device-authorized
// Bridge (`credential get --target <target>`): ZHIBAN_COMPAT_BRIDGE, by
// default the one inside /Applications/知办AI.app on macOS.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/gatewaymodels"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/netproxy"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/verify"
)

const (
	compatRegistry       = "https://registry.npmmirror.com"
	compatInstallationID = "compat-check"
	compatMacBridge      = "/Applications/知办AI.app/Contents/Helpers/ZhibanLocalBridge.app/Contents/MacOS/zhiban-local-bridge"
	compatOutputTail     = 4096
	// The original configuration a user typically already has; the switch
	// must keep it and the restore must give it back byte for byte.
	compatCodexOriginal  = "model = \"gpt-5.5\"\napproval_policy = \"on-request\"\n\n[projects.\"/tmp/compat\"]\ntrust_level = \"trusted\"\n"
	compatClaudeOriginal = "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(git status)\"\n    ]\n  },\n  \"includeCoAuthoredBy\": false\n}\n"
)

// TestMain doubles as the credential helper the switch writes into the
// configuration: a copy of this test binary prints the token file beside it.
func TestMain(m *testing.M) {
	if len(os.Args) == 5 && os.Args[1] == "credential" && os.Args[2] == "get" && os.Args[3] == "--target" {
		os.Exit(compatHelper(os.Args[4]))
	}
	os.Exit(m.Run())
}

func compatHelper(targetID string) int {
	executable, err := os.Executable()
	if err != nil {
		return 1
	}
	token, err := os.ReadFile(filepath.Join(filepath.Dir(executable), "token-"+targetID))
	if err != nil {
		return 1
	}
	if _, err := os.Stdout.Write(append(bytes.TrimSpace(token), '\n')); err != nil {
		return 1
	}
	return 0
}

func TestCompatibility(t *testing.T) {
	tools := []struct {
		env, targetID, name string
	}{
		{"ZHIBAN_COMPAT_CODEX", configuration.TargetCodexCLI, "Codex CLI"},
		{"ZHIBAN_COMPAT_CLAUDE", configuration.TargetClaudeCLI, "Claude Code"},
	}
	ran := false
	for _, tool := range tools {
		spec := strings.TrimSpace(os.Getenv(tool.env))
		if spec == "" {
			continue
		}
		ran = true
		t.Run(tool.targetID, func(t *testing.T) {
			runCompatibility(t, tool.targetID, tool.name, spec)
		})
	}
	if !ran {
		t.Skip("set ZHIBAN_COMPAT_CODEX and/or ZHIBAN_COMPAT_CLAUDE (latest, a version, or an executable path)")
	}
}

func runCompatibility(t *testing.T, targetID, name, spec string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	platform, arch, ok := runtimeNames(runtime.GOOS, runtime.GOARCH)
	if !ok {
		t.Fatalf("unsupported runtime %s/%s", runtime.GOOS, runtime.GOARCH)
	}
	realHome, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}

	// 1. The executable and the version detect.execute would report.
	executable, expectedVersion := compatExecutable(ctx, t, targetID, spec, platform, arch)
	version, err := detect.VersionProber{Timeout: 10 * time.Second, HomeDir: home}.Probe(ctx, targetID,
		detect.Candidate{Path: executable, RealPath: executable})
	if err != nil {
		t.Fatalf("[版本识别] 失败：%v\n--version 原始输出：\n%s", err, compatRawOutput(ctx, executable, home, "--version"))
	}
	if expectedVersion != "" && version != expectedVersion {
		t.Fatalf("[版本识别] 读到 %s，下载的是 %s（--version 输出格式可能变了）", version, expectedVersion)
	}
	t.Logf("%s %s（%s）", name, version, executable)
	if minimum, tooOld := catalog.MinimumSwitchVersion(targetID, version); tooOld {
		t.Fatalf("[最低版本] %s 低于可切换的最低版本 %s，App 会拦下切换", version, minimum)
	}

	// 2. The helper (a copy of this binary) and the gateway token beside it.
	token := compatToken(ctx, t, targetID)
	helper := filepath.Join(root, "helper", "zhiban-compat-helper"+filepath.Ext(os.Args[0]))
	compatCopyExecutable(t, helper)
	if err := os.WriteFile(filepath.Join(filepath.Dir(helper), "token-"+targetID), []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	configPath := filepath.Join(home, ".codex", "config.toml")
	original := compatCodexOriginal
	if targetID == configuration.TargetClaudeCLI {
		configPath = filepath.Join(home, ".claude", "settings.json")
		original = compatClaudeOriginal
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}

	nodeLookup := shellenv.NewLoginShellLookup(realHome)
	installation := configuration.Installation{
		TargetID: targetID, InstallationID: compatInstallationID, Executable: executable, Version: version,
	}
	newConfigurations := func(probe func(context.Context, configuration.Installation) error) *configuration.Manager {
		config := configuration.ManagerConfig{
			HomeDir:           home,
			HelperExecutable:  helper,
			NodeLookup:        nodeLookup,
			Profiles:          configurationProfiles(),
			SupportedVersions: install.LockedVersions(platform),
			ProbeGlobal:       probe,
			ResolveInstallation: func(context.Context, string, string) (configuration.Installation, error) {
				return installation, nil
			},
			ResolveAuthorization: func(_ context.Context, target string) (configuration.AuthorizationProfile, error) {
				return configuration.AuthorizationProfile{
					Environment:    configuration.EnvironmentProd,
					ProfileVersion: configurationProfiles()[configuration.EnvironmentProd][target].Version,
				}, nil
			},
		}
		if targetID == configuration.TargetCodexCLI {
			client := credential.NewSecureHTTPClient()
			config.CodexExecutables = func(context.Context) ([]string, error) { return []string{executable}, nil }
			config.GatewayModelIDs = func(ctx context.Context, _ string, baseURL string) ([]string, error) {
				return gatewaymodels.List(ctx, client, baseURL, token)
			}
		}
		manager, err := configuration.NewManager(config)
		if err != nil {
			t.Fatalf("configuration manager: %v", err)
		}
		return manager
	}
	configurations := newConfigurations(nil)

	// 3. switch_global with the production post-switch probe.
	started := time.Now()
	plan, err := configurations.PlanWithType(ctx, targetID, compatInstallationID, configuration.PlanTypeSwitchGlobal)
	if err != nil {
		t.Fatalf("[切换] 生成切换计划失败：%v", err)
	}
	status, err := configurations.Execute(ctx, plan.PlanID)
	if err != nil {
		compatDiagnoseSwitch(ctx, t, newConfigurations, targetID, home, configPath)
		t.Fatalf("[切换] 写入后自检失败（%v）：新版本读不了知办写入的配置，诊断输出见上", err)
	}
	if status.CurrentService != configuration.ServiceZhiban {
		t.Fatalf("[切换] 切换后当前服务是 %q", status.CurrentService)
	}
	switched, _ := os.ReadFile(configPath)
	t.Logf("[切换] 通过（%s），写入后的配置：\n%s", time.Since(started).Round(100*time.Millisecond), switched)
	if targetID == configuration.TargetCodexCLI {
		if bytes.Contains(switched, []byte("model_catalog_json")) {
			t.Logf("[模型目录] 已写入")
		} else {
			t.Logf("[模型目录] 未写入：Codex 导出内置模型目录失败或网关没返回模型；切换本身不受影响，模型菜单会回落 Codex 内置目录，建议人工看一眼")
		}
	}

	// 4. verify.execute (global scope): one real request through the helper.
	var (
		mu             sync.Mutex
		lastInvocation verify.Invocation
		lastOutcome    verify.Outcome
	)
	registry := operation.NewRegistry()
	defer registry.Shutdown(5 * time.Second)
	var gatewayURLs []string
	for _, byTarget := range configurationProfiles() {
		for _, profile := range byTarget {
			gatewayURLs = append(gatewayURLs, profile.BaseURL)
		}
	}
	proxy := netproxy.NewManager(netproxy.Config{HomeDir: realHome, GatewayURLs: gatewayURLs, Lookup: nodeLookup})
	verifier, err := verify.NewManager(verify.ManagerConfig{
		HomeDir:             home,
		Operations:          registry,
		ConfigurationStatus: configurations.Status,
		NodeLookup:          nodeLookup,
		ProxyEnvironment:    proxy.ProbeEnvironment,
		ProxyRisk:           proxy.EnvNeedsFix,
		TempRoot:            root,
		ResolveInstallation: func(context.Context, string, string) (verify.Installation, error) {
			return verify.Installation{
				TargetID: targetID, InstallationID: compatInstallationID, Executable: executable, Version: version,
			}, nil
		},
		ManagedArguments: func(ctx context.Context, target, profileVersion string) ([]string, error) {
			resolved, err := configurations.ResolveLaunchConfiguration(ctx, target, profileVersion)
			return resolved.Arguments, err
		},
		ExchangeToken:      func(context.Context, string) (string, error) { return token, nil },
		RecordVerification: configurations.RecordVerification,
		RecordGlobal:       configurations.RecordGlobalVerification,
		RefreshGlobal:      configurations.RefreshGlobalModelCatalog,
		Run: func(ctx context.Context, invocation verify.Invocation) (verify.Outcome, error) {
			outcome, err := verify.RunProcess(ctx, invocation)
			mu.Lock()
			lastInvocation, lastOutcome = invocation, outcome
			mu.Unlock()
			return outcome, err
		},
	})
	if err != nil {
		t.Fatalf("verify manager: %v", err)
	}
	started = time.Now()
	envelope, err := verifier.Execute(ctx, targetID, compatInstallationID, verify.ScopeGlobal)
	if err != nil {
		t.Fatalf("[真实请求] 启动失败：%v", err)
	}
	for envelope.State == operation.StateRunning {
		select {
		case <-ctx.Done():
			t.Fatalf("[真实请求] 超时")
		case <-time.After(500 * time.Millisecond):
		}
		if envelope, err = registry.Get(envelope.OperationID); err != nil {
			t.Fatalf("[真实请求] %v", err)
		}
	}
	if envelope.State != operation.StateSucceeded {
		code := ""
		if envelope.ErrorCode != nil {
			code = *envelope.ErrorCode
		}
		mu.Lock()
		invocation, outcome := lastInvocation, lastOutcome
		mu.Unlock()
		t.Fatalf("[真实请求] 失败 %s（%s）\n%s\n命令：%s %s\n退出码 %d，超时 %v\n输出（末尾）：\n%s",
			code, time.Since(started).Round(100*time.Millisecond), compatVerdict(envelope.ErrorDetail), invocation.Executable,
			strings.Join(invocation.Arguments, " "), outcome.ExitCode, outcome.TimedOut, compatTail(outcome.Output))
	}
	t.Logf("[真实请求] 通过（%s）", time.Since(started).Round(100*time.Millisecond))

	// 5. restore_global gives the original file back.
	plan, err = configurations.PlanWithType(ctx, targetID, "", configuration.PlanTypeRestoreGlobal)
	if err != nil {
		t.Fatalf("[恢复] 生成恢复计划失败：%v", err)
	}
	if status, err = configurations.Execute(ctx, plan.PlanID); err != nil || status.CurrentService == configuration.ServiceZhiban {
		t.Fatalf("[恢复] 失败：%v（当前服务 %q）", err, status.CurrentService)
	}
	restored, _ := os.ReadFile(configPath)
	if string(restored) != original {
		t.Fatalf("[恢复] 恢复后的配置和原来不一致：\n%s", restored)
	}
	t.Logf("[恢复] 通过，原配置逐字节还原")
}

// compatDiagnoseSwitch repeats the switch with a probe that keeps the output
// and never fails, so the rendered file stays for inspection.
func compatDiagnoseSwitch(ctx context.Context, t *testing.T,
	newConfigurations func(func(context.Context, configuration.Installation) error) *configuration.Manager,
	targetID, home, configPath string) {
	t.Helper()
	var output string
	manager := newConfigurations(func(ctx context.Context, installation configuration.Installation) error {
		arguments := []string{"--version"}
		if targetID == configuration.TargetCodexCLI {
			arguments = []string{"mcp", "list"}
		}
		output = compatRawOutput(ctx, installation.Executable, home, arguments...)
		return nil
	})
	plan, err := manager.PlanWithType(ctx, targetID, compatInstallationID, configuration.PlanTypeSwitchGlobal)
	if err != nil {
		t.Logf("诊断：重新生成计划失败：%v", err)
		return
	}
	if _, err := manager.Execute(ctx, plan.PlanID); err != nil {
		t.Logf("诊断：写入失败：%v", err)
		return
	}
	rendered, _ := os.ReadFile(configPath)
	t.Logf("诊断：写入的配置：\n%s\n自检命令输出：\n%s", rendered, output)
}

// compatRawOutput runs the executable the way the Bridge's quiet probes do
// (isolated HOME, CODEX_HOME inside it) and returns combined output.
func compatRawOutput(ctx context.Context, executable, home string, arguments ...string) string {
	runCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	command := exec.CommandContext(runCtx, executable, arguments...)
	command.Dir = home
	command.Env = shellenv.PrependPath([]string{
		"HOME=" + home, "USERPROFILE=" + home, "CODEX_HOME=" + filepath.Join(home, ".codex"),
		"PATH=" + os.Getenv("PATH"), "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8",
	}, shellenv.NodeDirs(ctx, executable, nil))
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	err := command.Run()
	text := compatTail(output.Bytes())
	if err != nil {
		text += fmt.Sprintf("\n（%v）", err)
	}
	return text
}

// compatVerdict separates a gateway that answered with an HTTP error (the
// Bridge's error_detail) from a probe that never got a usable answer.
func compatVerdict(detail *string) string {
	if detail != nil {
		return "结论：请求已到达网关，中转站返回「" + *detail + "」；新版本读配置、调用凭证助手都正常，兼容性未能最终确认，网关恢复后重跑"
	}
	return "结论：请求没能正常完成，可能是新版本不兼容（配置格式、凭证助手、协议），需要看下面的输出"
}

func compatTail(output []byte) string {
	if len(output) > compatOutputTail {
		output = output[len(output)-compatOutputTail:]
	}
	return string(output)
}

func compatToken(ctx context.Context, t *testing.T, targetID string) string {
	t.Helper()
	if token := strings.TrimSpace(os.Getenv("ZHIBAN_COMPAT_TOKEN")); token != "" {
		if !credential.ValidAccessToken(token) {
			t.Fatal("ZHIBAN_COMPAT_TOKEN is not a valid gateway token")
		}
		return token
	}
	bridge := strings.TrimSpace(os.Getenv("ZHIBAN_COMPAT_BRIDGE"))
	if bridge == "" && runtime.GOOS == "darwin" {
		bridge = compatMacBridge
	}
	if bridge == "" {
		t.Fatal("set ZHIBAN_COMPAT_TOKEN or ZHIBAN_COMPAT_BRIDGE (the installed zhiban-local-bridge)")
	}
	runCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	command := exec.CommandContext(runCtx, bridge, "credential", "get", "--target", targetID)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	token := strings.TrimSpace(stdout.String())
	if err != nil || !credential.ValidAccessToken(token) {
		t.Fatalf("[凭证] 从 %s 取不到网关凭证（%s）：先在知办 App 登录并打开一次本地开发工具页，或设置 ZHIBAN_COMPAT_TOKEN",
			bridge, strings.TrimSpace(stderr.String()))
	}
	return token
}

func compatCopyExecutable(t *testing.T, destination string) {
	t.Helper()
	source, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, content, 0o700); err != nil {
		t.Fatal(err)
	}
}

// compatExecutable resolves spec to an executable: an existing absolute path
// is used as is (its version is whatever it reports); otherwise spec is an
// npm version or dist-tag downloaded from npmmirror.
func compatExecutable(ctx context.Context, t *testing.T, targetID, spec, platform, arch string) (string, string) {
	t.Helper()
	if filepath.IsAbs(spec) {
		resolved, err := filepath.EvalSymlinks(spec)
		if err != nil {
			t.Fatalf("executable %s: %v", spec, err)
		}
		return resolved, ""
	}
	npmPlatform := map[string]string{"macos/arm64": "darwin-arm64", "macos/x64": "darwin-x64", "windows/x64": "win32-x64"}[platform+"/"+arch]
	var mainPackage, binary string
	switch targetID {
	case configuration.TargetCodexCLI:
		mainPackage, binary = "@openai/codex", "codex"
	default:
		mainPackage, binary = "@anthropic-ai/claude-code", "claude"
	}
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	version := compatDocument(ctx, t, mainPackage+"/"+spec).Version
	if version == "" {
		t.Fatalf("[下载] npmmirror 上找不到 %s@%s", mainPackage, spec)
	}
	// Codex publishes each platform as a version of the main package
	// ("0.154.0-darwin-arm64"); Claude Code as separate packages.
	platformDocument := mainPackage + "/" + version + "-" + npmPlatform
	if targetID == configuration.TargetClaudeCLI {
		platformDocument = mainPackage + "-" + npmPlatform + "/" + version
	}
	cacheRoot, err := os.UserCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(cacheRoot, "zhiban-local-bridge-compat", strings.NewReplacer("@", "", "/", "_").Replace(platformDocument))
	if _, err := os.Stat(filepath.Join(directory, ".complete")); err != nil {
		document := compatDocument(ctx, t, platformDocument)
		t.Logf("[下载] %s（%d MB）", document.Dist.Tarball, document.Dist.Size>>20)
		_ = os.RemoveAll(directory)
		compatDownload(ctx, t, document, directory)
	}
	var found string
	_ = filepath.WalkDir(directory, func(path string, entry os.DirEntry, err error) error {
		if err == nil && found == "" && entry.Type().IsRegular() && entry.Name() == binary {
			found = path
		}
		return nil
	})
	if found == "" {
		t.Fatalf("[下载] %s 里找不到可执行文件 %s（包结构可能变了）", directory, binary)
	}
	return found, version
}

type compatNPMDocument struct {
	Version string `json:"version"`
	Dist    struct {
		Tarball   string `json:"tarball"`
		Integrity string `json:"integrity"`
		Size      int64  `json:"size"`
	} `json:"dist"`
}

func compatDocument(ctx context.Context, t *testing.T, path string) compatNPMDocument {
	t.Helper()
	body := compatGet(ctx, t, compatRegistry+"/"+path, 8<<20)
	var document compatNPMDocument
	if err := json.Unmarshal(body, &document); err != nil {
		t.Fatalf("[下载] %s: %v", path, err)
	}
	return document
}

func compatGet(ctx context.Context, t *testing.T, url string, limit int64) []byte {
	t.Helper()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("[下载] %s: %v", url, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("[下载] %s: HTTP %d", url, response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil || int64(len(body)) > limit {
		t.Fatalf("[下载] %s: read failed (%v)", url, err)
	}
	return body
}

func compatDownload(ctx context.Context, t *testing.T, document compatNPMDocument, directory string) {
	t.Helper()
	expected, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(document.Dist.Integrity, "sha512-"))
	if err != nil || !strings.HasPrefix(document.Dist.Integrity, "sha512-") || len(expected) != sha512.Size {
		t.Fatalf("[下载] integrity %q unusable", document.Dist.Integrity)
	}
	tarball := compatGet(ctx, t, document.Dist.Tarball, 1<<30)
	if digest := sha512.Sum512(tarball); !bytes.Equal(digest[:], expected) {
		t.Fatalf("[下载] %s sha512 与 npm 记录不一致", document.Dist.Tarball)
	}
	if err := compatExtract(tarball, directory); err != nil {
		_ = os.RemoveAll(directory)
		t.Fatalf("[下载] 解包失败：%v", err)
	}
	if err := os.WriteFile(filepath.Join(directory, ".complete"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func compatExtract(tarball []byte, directory string) error {
	compressed, err := gzip.NewReader(bytes.NewReader(tarball))
	if err != nil {
		return err
	}
	reader := tar.NewReader(compressed)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(filepath.FromSlash(header.Name))
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe entry %q", header.Name)
		}
		path := filepath.Join(directory, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			mode := os.FileMode(0o644)
			if header.Mode&0o111 != 0 {
				mode = 0o755
			}
			file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(file, reader)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
	}
}
