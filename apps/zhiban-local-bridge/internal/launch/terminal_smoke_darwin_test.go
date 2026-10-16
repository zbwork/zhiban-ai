//go:build darwin && cgo

package launch

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	terminalSmokeEnabledEnv = "ZHIBAN_RUN_TERMINAL_SMOKE"
	terminalSmokeProfile    = "2026.09.07.1"
)

type terminalSmokeState struct {
	HomeDir    string `json:"home_dir"`
	ProjectDir string `json:"project_dir"`
	Executable string `json:"executable"`
	ResultPath string `json:"result_path"`
}

func TestMain(m *testing.M) {
	if terminalSmokeChildRequested(os.Args[1:]) {
		os.Exit(runTerminalSmokeChild(os.Args[1:]))
	}
	os.Exit(m.Run())
}

func TestMacOSTerminalLaunchSmoke(t *testing.T) {
	if os.Getenv(terminalSmokeEnabledEnv) != "1" {
		t.Skip("set " + terminalSmokeEnabledEnv + "=1 to open a real Terminal window")
	}
	if err := runMacOSTerminalSmoke(t); err != nil {
		t.Fatal(err)
	}
}

func terminalSmokeChildRequested(arguments []string) bool {
	return len(arguments) == 4 && arguments[0] == "launch" && arguments[1] == "consume" &&
		arguments[2] == "--ticket" && validOpaqueID(arguments[3])
}

func runTerminalSmokeChild(arguments []string) int {
	ticketID := arguments[3]
	statePath := terminalSmokeStatePath(ticketID)
	encoded, err := os.ReadFile(statePath)
	if err != nil {
		return 1
	}
	_ = os.Remove(statePath)

	var state terminalSmokeState
	if err := json.Unmarshal(encoded, &state); err != nil || validateTerminalSmokeState(state) != nil {
		return 1
	}
	helper, err := os.Executable()
	if err != nil {
		writeTerminalSmokeFailure(state.ResultPath, "helper_unavailable")
		return 1
	}
	helper, err = filepath.EvalSymlinks(helper)
	if err != nil {
		writeTerminalSmokeFailure(state.ResultPath, "helper_unavailable")
		return 1
	}
	store, err := NewFileTicketStore(state.HomeDir, DefaultLaunchRoot(state.HomeDir), helper)
	if err != nil {
		writeTerminalSmokeFailure(state.ResultPath, "ticket_store_failed")
		return 1
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: state.HomeDir,
		SupportedVersions: map[string]string{
			TargetCodexCLI:  "0.153.4",
			TargetClaudeCLI: "2.1.263",
		},
		ResolveBookmark: NewMacOSBookmarkResolver(),
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: state.Executable, Version: "0.153.4"}, nil
		},
		ResolveCurrentInstallation: func(_ context.Context, targetID string) ([]Installation, error) {
			return []Installation{{TargetID: targetID, InstallationID: "terminal-smoke-current", Executable: state.Executable, Version: "0.153.4"}}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--profile", "zhiban-ai-managed"}}, nil
		},
		Tickets: store,
		Execute: NewMacOSExecutor(),
	})
	if err != nil {
		writeTerminalSmokeFailure(state.ResultPath, "manager_initialization_failed")
		return 1
	}
	environment := append(os.Environ(),
		"OPENAI_API_KEY=terminal-smoke-secret",
		"OPENAI_BASE_URL=https://terminal-smoke.invalid",
		"CODEX_HOME=/tmp/terminal-smoke-override",
		"DYLD_INSERT_LIBRARIES=/tmp/terminal-smoke.dylib",
	)
	if err := manager.Consume(context.Background(), ticketID, environment); err != nil {
		writeTerminalSmokeFailure(state.ResultPath, "consume_failed")
		return 1
	}
	return 0
}

func runMacOSTerminalSmoke(t *testing.T) error {
	t.Helper()
	rawHome := t.TempDir()
	home, err := filepath.EvalSymlinks(rawHome)
	if err != nil {
		return fmt.Errorf("resolve temporary home: %w", err)
	}
	project := filepath.Join(home, "terminal-smoke-project")
	binDir := filepath.Join(home, "bin")
	if err := os.Mkdir(project, 0o700); err != nil {
		return fmt.Errorf("create temporary project: %w", err)
	}
	if err := os.Mkdir(binDir, 0o700); err != nil {
		return fmt.Errorf("create temporary bin: %w", err)
	}
	resultPath := filepath.Join(home, "terminal-smoke-result.txt")
	executable := filepath.Join(binDir, "codex")
	if err := writeTerminalSmokeCLI(executable, resultPath); err != nil {
		return err
	}
	bookmark, err := createBookmarkForTest(project)
	if err != nil {
		return fmt.Errorf("create project bookmark: %w", err)
	}
	helper, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve test helper: %w", err)
	}
	helper, err = filepath.EvalSymlinks(helper)
	if err != nil {
		return fmt.Errorf("resolve test helper real path: %w", err)
	}
	store, err := NewFileTicketStore(home, DefaultLaunchRoot(home), helper)
	if err != nil {
		return fmt.Errorf("create file ticket store: %w", err)
	}

	actualOpen := NewMacOSTerminalOpener(home)
	var ticketID string
	var stateFiles []string
	defer func() {
		for _, path := range stateFiles {
			_ = os.Remove(path)
		}
	}()
	manager, err := NewManager(ManagerConfig{
		HomeDir: home,
		SupportedVersions: map[string]string{
			TargetCodexCLI:  "0.153.4",
			TargetClaudeCLI: "2.1.263",
		},
		ResolveBookmark: NewMacOSBookmarkResolver(),
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "0.153.4"}, nil
		},
		ResolveCurrentInstallation: func(_ context.Context, targetID string) ([]Installation, error) {
			return []Installation{{TargetID: targetID, InstallationID: "terminal-smoke-current", Executable: executable, Version: "0.153.4"}}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--profile", "zhiban-ai-managed"}}, nil
		},
		Tickets: store,
		OpenTerminal: func(ctx context.Context, scriptPath string) error {
			value := strings.TrimSuffix(filepath.Base(scriptPath), ".command")
			if !validOpaqueID(value) {
				return ErrTerminalLaunchFailed
			}
			ticketID = value
			statePath := terminalSmokeStatePath(value)
			stateFiles = append(stateFiles, statePath)
			if err := writeExclusiveJSON(statePath, terminalSmokeState{
				HomeDir: home, ProjectDir: project, Executable: executable, ResultPath: resultPath,
			}); err != nil {
				return ErrTerminalLaunchFailed
			}
			return actualOpen(ctx, scriptPath)
		},
		Execute: NewMacOSExecutor(),
	})
	if err != nil {
		return fmt.Errorf("create launch manager: %w", err)
	}
	grant, err := manager.CreateProjectGrant(context.Background(), base64.StdEncoding.EncodeToString(bookmark))
	if err != nil {
		return fmt.Errorf("create project grant: %w", err)
	}
	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "terminal-smoke-installation",
		ProjectGrantID: grant.ProjectGrantID, ProfileVersion: terminalSmokeProfile,
	})
	if err != nil {
		return fmt.Errorf("create launch plan: %w", err)
	}
	result, err := manager.Execute(context.Background(), plan.LaunchPlanID)
	if err != nil {
		return fmt.Errorf("open Terminal: %w", err)
	}
	if result.State != "launched" || result.TargetID != TargetCodexCLI || ticketID == "" {
		return fmt.Errorf("unexpected launch result: state=%q target=%q", result.State, result.TargetID)
	}
	evidence, err := waitForTerminalSmokeResult(resultPath, 20*time.Second)
	if err != nil {
		return err
	}
	if failure := evidence["error"]; failure != "" {
		return fmt.Errorf("Terminal child failed: %s", failure)
	}
	want := map[string]string{
		"pwd":                      project,
		"arg_count":                "2",
		"arg_1":                    "--profile",
		"arg_2":                    "zhiban-ai-managed",
		"home":                     home,
		"codex_home":               filepath.Join(home, ".codex"),
		"openai_api_key_present":   "unset",
		"openai_base_url_present":  "unset",
		"dyld_insert_libs_present": "unset",
	}
	for key, expected := range want {
		if actual := evidence[key]; actual != expected {
			return fmt.Errorf("Terminal evidence %s=%q, want %q", key, actual, expected)
		}
	}
	if err := manager.Consume(context.Background(), ticketID, nil); !errors.Is(err, ErrTicketNotFound) {
		return fmt.Errorf("ticket replay error = %v, want %v", err, ErrTicketNotFound)
	}
	return nil
}

func validateTerminalSmokeState(state terminalSmokeState) error {
	if !filepath.IsAbs(state.HomeDir) || state.HomeDir == string(filepath.Separator) ||
		!pathInside(state.ProjectDir, state.HomeDir) || !pathInside(state.Executable, state.HomeDir) ||
		!pathInside(state.ResultPath, state.HomeDir) {
		return errors.New("invalid terminal smoke state")
	}
	return nil
}

func terminalSmokeStatePath(ticketID string) string {
	return filepath.Join("/tmp", "zhiban-terminal-smoke-"+ticketID+".json")
}

func writeExclusiveJSON(path string, value any) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	remove := true
	defer func() {
		_ = file.Close()
		if remove {
			_ = os.Remove(path)
		}
	}()
	if err := json.NewEncoder(file).Encode(value); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	remove = false
	return nil
}

func writeTerminalSmokeCLI(executable, resultPath string) error {
	temporaryResult := resultPath + ".tmp"
	script := "#!/bin/sh\n" +
		"umask 077\n" +
		"{\n" +
		"  printf 'pwd=%s\\n' \"$PWD\"\n" +
		"  printf 'arg_count=%s\\n' \"$#\"\n" +
		"  printf 'arg_1=%s\\n' \"${1-}\"\n" +
		"  printf 'arg_2=%s\\n' \"${2-}\"\n" +
		"  printf 'home=%s\\n' \"${HOME-}\"\n" +
		"  printf 'codex_home=%s\\n' \"${CODEX_HOME-}\"\n" +
		"  if [ \"${OPENAI_API_KEY+x}\" = x ]; then printf 'openai_api_key_present=set\\n'; else printf 'openai_api_key_present=unset\\n'; fi\n" +
		"  if [ \"${OPENAI_BASE_URL+x}\" = x ]; then printf 'openai_base_url_present=set\\n'; else printf 'openai_base_url_present=unset\\n'; fi\n" +
		"  if [ \"${DYLD_INSERT_LIBRARIES+x}\" = x ]; then printf 'dyld_insert_libs_present=set\\n'; else printf 'dyld_insert_libs_present=unset\\n'; fi\n" +
		"} > " + shellQuoteFixed(temporaryResult) + "\n" +
		"/bin/chmod 600 " + shellQuoteFixed(temporaryResult) + "\n" +
		"/bin/mv " + shellQuoteFixed(temporaryResult) + " " + shellQuoteFixed(resultPath) + "\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		return fmt.Errorf("create fake CLI: %w", err)
	}
	return nil
}

func waitForTerminalSmokeResult(path string, timeout time.Duration) (map[string]string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		encoded, err := os.ReadFile(path)
		if err == nil {
			return parseTerminalSmokeEvidence(string(encoded)), nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("read Terminal evidence: %w", err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil, errors.New("timed out waiting for Terminal evidence")
}

func parseTerminalSmokeEvidence(value string) map[string]string {
	result := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(value), "\n") {
		key, item, ok := strings.Cut(line, "=")
		if ok && key != "" {
			result[key] = item
		}
	}
	return result
}

func writeTerminalSmokeFailure(path, code string) {
	_ = os.WriteFile(path, []byte("error="+code+"\n"), 0o600)
}
