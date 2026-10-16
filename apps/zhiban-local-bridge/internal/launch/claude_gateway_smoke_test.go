package launch

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	claudeGatewaySmokeEnabledEnv = "ZHIBAN_RUN_CLAUDE_GATEWAY_SMOKE"
	claudeGatewaySmokeVersion    = "2.1.263"
	claudeGatewaySmokeToken      = "zhiban-local-smoke-token"
	claudeGatewaySmokeResponse   = "LOCAL_CLAUDE_SMOKE_OK"
)

type claudeGatewaySmokeRecorder struct {
	mu              sync.Mutex
	messageRequests int
	authenticated   bool
	streaming       bool
	issues          []string
}

func TestClaudeCodeLoopbackGatewaySmoke(t *testing.T) {
	if os.Getenv(claudeGatewaySmokeEnabledEnv) != "1" {
		t.Skip("set " + claudeGatewaySmokeEnabledEnv + "=1 to run the installed Claude Code against a loopback stub")
	}
	if err := runClaudeCodeLoopbackGatewaySmoke(t); err != nil {
		t.Fatal(err)
	}
}

func runClaudeCodeLoopbackGatewaySmoke(t *testing.T) error {
	t.Helper()
	claudePath, err := exec.LookPath("claude")
	if err != nil {
		return errorsForClaudeSmoke("installed Claude Code was not found")
	}
	claudePath, err = filepath.EvalSymlinks(claudePath)
	if err != nil {
		return errorsForClaudeSmoke("installed Claude Code path could not be resolved")
	}
	info, err := os.Stat(claudePath)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return errorsForClaudeSmoke("installed Claude Code path is not an executable file")
	}

	rawHome := t.TempDir()
	home, err := filepath.EvalSymlinks(rawHome)
	if err != nil {
		return fmt.Errorf("resolve temporary home: %w", err)
	}
	project := filepath.Join(home, "empty-project")
	temporary := filepath.Join(home, "tmp")
	if err := os.Mkdir(project, 0o700); err != nil {
		return fmt.Errorf("create empty project: %w", err)
	}
	if err := os.Mkdir(temporary, 0o700); err != nil {
		return fmt.Errorf("create temporary directory: %w", err)
	}
	environment := claudeGatewaySmokeEnvironment(home, temporary)
	versionCommand := exec.Command(claudePath, "--version")
	versionCommand.Env = environment
	versionOutput, err := versionCommand.CombinedOutput()
	if err != nil || !strings.HasPrefix(strings.TrimSpace(string(versionOutput)), claudeGatewaySmokeVersion+" ") {
		return fmt.Errorf("Claude Code version mismatch: %s", safeClaudeSmokeOutput(string(versionOutput), home, ""))
	}

	recorder := &claudeGatewaySmokeRecorder{}
	server := httptest.NewServer(http.HandlerFunc(recorder.handle))
	defer server.Close()
	helperPath := filepath.Join(home, "credential-helper")
	helperMarker := filepath.Join(home, "credential-helper-invoked")
	if err := writeClaudeGatewaySmokeCredentialHelper(helperPath, helperMarker); err != nil {
		return err
	}
	settingsPath := filepath.Join(home, "managed-settings.json")
	settings := map[string]any{
		"$schema":      "https://json.schemastore.org/claude-code-settings.json",
		"apiKeyHelper": shellQuoteFixed(helperPath) + " credential get --target claude_cli",
		"env": map[string]string{
			"ANTHROPIC_BASE_URL": server.URL,
		},
	}
	encodedSettings, err := json.Marshal(settings)
	if err != nil {
		return fmt.Errorf("encode managed settings: %w", err)
	}
	if err := os.WriteFile(settingsPath, append(encodedSettings, '\n'), 0o600); err != nil {
		return fmt.Errorf("write managed settings: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, claudePath,
		"--bare",
		"--restricted",
		"--no-session-persistence",
		"--no-chrome",
		"--settings", settingsPath,
		"--setting-sources", "",
		"--strict-mcp-config",
		"--mcp-config", `{"mcpServers":{}}`,
		"--tools", "",
		"--permission-prompts", "none",
		"--output-format", "json",
		"--max-turns", "1",
		"-p", "Reply with exactly LOCAL_CLAUDE_SMOKE_OK.",
	)
	command.Dir = project
	command.Env = environment
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return errorsForClaudeSmoke("Claude Code loopback request timed out")
		}
		return fmt.Errorf("Claude Code loopback request failed: %v; stderr=%s", err, safeClaudeSmokeOutput(stderr.String(), home, server.URL))
	}
	if _, err := os.Stat(helperMarker); err != nil {
		return errorsForClaudeSmoke("Claude Code did not invoke the managed credential helper")
	}
	messageRequests, authenticated, streaming, issues := recorder.snapshot()
	if len(issues) != 0 {
		return fmt.Errorf("loopback gateway contract failed: %s", strings.Join(issues, ", "))
	}
	if messageRequests != 1 || !authenticated || !streaming {
		return fmt.Errorf("loopback gateway evidence requests=%d authenticated=%t streaming=%t", messageRequests, authenticated, streaming)
	}
	if !strings.Contains(stdout.String(), claudeGatewaySmokeResponse) {
		return fmt.Errorf("Claude Code output did not contain the fixed response: %s", safeClaudeSmokeOutput(stdout.String(), home, server.URL))
	}
	if strings.Contains(stdout.String(), claudeGatewaySmokeToken) || strings.Contains(stderr.String(), claudeGatewaySmokeToken) {
		return errorsForClaudeSmoke("Claude Code exposed the test credential in process output")
	}
	return nil
}

func claudeGatewaySmokeEnvironment(home, temporary string) []string {
	return []string{
		"HOME=" + home,
		"TMPDIR=" + temporary,
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"LANG=en_US.UTF-8",
		"NO_PROXY=127.0.0.1,localhost",
		"no_proxy=127.0.0.1,localhost",
		"HTTP_PROXY=http://127.0.0.1:1",
		"HTTPS_PROXY=http://127.0.0.1:1",
		"http_proxy=http://127.0.0.1:1",
		"https_proxy=http://127.0.0.1:1",
		"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
	}
}

func writeClaudeGatewaySmokeCredentialHelper(path, marker string) error {
	script := "#!/bin/sh\n" +
		"if [ \"$#\" -ne 4 ] || [ \"${1-}\" != credential ] || [ \"${2-}\" != get ] || [ \"${3-}\" != --target ] || [ \"${4-}\" != claude_cli ]; then exit 2; fi\n" +
		"/usr/bin/touch " + shellQuoteFixed(marker) + "\n" +
		"printf '%s\\n' " + shellQuoteFixed(claudeGatewaySmokeToken) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		return fmt.Errorf("write temporary credential helper: %w", err)
	}
	return nil
}

func (r *claudeGatewaySmokeRecorder) handle(writer http.ResponseWriter, request *http.Request) {
	switch request.URL.Path {
	case "/v1/messages/count_tokens":
		if !r.checkAuthentication(request) {
			http.Error(writer, `{"type":"error","error":{"type":"authentication_error","message":"invalid test credential"}}`, http.StatusUnauthorized)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"input_tokens":1}`))
	case "/v1/messages":
		r.handleMessages(writer, request)
	default:
		r.addIssue("unexpected endpoint " + request.URL.Path)
		http.NotFound(writer, request)
	}
}

func (r *claudeGatewaySmokeRecorder) handleMessages(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		r.addIssue("messages method was not POST")
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	authenticated := r.checkAuthentication(request)
	var payload struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		r.addIssue("messages body was invalid JSON")
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	if payload.Model == "" {
		r.addIssue("messages model was empty")
		payload.Model = "claude-local-smoke"
	}
	r.mu.Lock()
	r.messageRequests++
	r.authenticated = r.authenticated || authenticated
	r.streaming = r.streaming || payload.Stream
	r.mu.Unlock()
	if !authenticated {
		http.Error(writer, `{"type":"error","error":{"type":"authentication_error","message":"invalid test credential"}}`, http.StatusUnauthorized)
		return
	}
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("Cache-Control", "no-cache")
	writer.Header().Set("X-Request-Id", "req_local_smoke")
	writeClaudeSmokeSSE(writer, "message_start", map[string]any{
		"type": "message_start",
		"message": map[string]any{
			"id": "msg_local_smoke", "type": "message", "role": "assistant", "content": []any{},
			"model": payload.Model, "stop_reason": nil, "stop_sequence": nil,
			"usage": map[string]int{"input_tokens": 1, "output_tokens": 0},
		},
	})
	writeClaudeSmokeSSE(writer, "content_block_start", map[string]any{
		"type": "content_block_start", "index": 0,
		"content_block": map[string]string{"type": "text", "text": ""},
	})
	writeClaudeSmokeSSE(writer, "content_block_delta", map[string]any{
		"type": "content_block_delta", "index": 0,
		"delta": map[string]string{"type": "text_delta", "text": claudeGatewaySmokeResponse},
	})
	writeClaudeSmokeSSE(writer, "content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
	writeClaudeSmokeSSE(writer, "message_delta", map[string]any{
		"type":  "message_delta",
		"delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil},
		"usage": map[string]int{"output_tokens": 5},
	})
	writeClaudeSmokeSSE(writer, "message_stop", map[string]string{"type": "message_stop"})
}

func (r *claudeGatewaySmokeRecorder) checkAuthentication(request *http.Request) bool {
	ok := request.Header.Get("X-Api-Key") == claudeGatewaySmokeToken &&
		request.Header.Get("Authorization") == "Bearer "+claudeGatewaySmokeToken
	if !ok {
		r.addIssue("authentication headers did not match the helper credential")
	}
	return ok
}

func (r *claudeGatewaySmokeRecorder) addIssue(issue string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.issues = append(r.issues, issue)
}

func (r *claudeGatewaySmokeRecorder) snapshot() (int, bool, bool, []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.messageRequests, r.authenticated, r.streaming, append([]string(nil), r.issues...)
}

func writeClaudeSmokeSSE(writer http.ResponseWriter, event string, value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(writer, "event: %s\ndata: %s\n\n", event, encoded)
	if flusher, ok := writer.(http.Flusher); ok {
		flusher.Flush()
	}
}

func safeClaudeSmokeOutput(value, home, gateway string) string {
	value = strings.ReplaceAll(value, claudeGatewaySmokeToken, "[redacted]")
	if home != "" {
		value = strings.ReplaceAll(value, home, "[temp-home]")
	}
	if gateway != "" {
		value = strings.ReplaceAll(value, gateway, "[loopback]")
	}
	value = strings.TrimSpace(value)
	if len(value) > 2000 {
		return value[:2000] + "..."
	}
	return value
}

func errorsForClaudeSmoke(message string) error {
	return fmt.Errorf("claude gateway smoke: %s", message)
}
