package verify

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// Real output of Codex 0.154.0 against api.airick.cn on 2026-09-15.
const codexRelayOverloaded = `Reading additional input from stdin...
OpenAI Codex v0.154.0
--------
session id: 01a0a3d4-d2fe-7db1-bbab-88f7cbd358e5
--------
user
Reply with exactly ZHIBAN_L3_OK and nothing else.
ERROR: Reconnecting... 1/5
ERROR: unexpected status 503 Service Unavailable: auth_unavailable: no auth available (providers=codex, model=gpt-5.6-luna; last upstream error: server_is_overloaded: Our servers are currently overloaded. Please try again later.), url: https://api.airick.cn/v1/responses
ERROR: unexpected status 503 Service Unavailable: auth_unavailable: no auth available (providers=codex, model=gpt-5.6-luna; last upstream error: server_is_overloaded: Our servers are currently overloaded. Please try again later.), url: https://api.airick.cn/v1/responses
`

// Claude Code 2.1.272 against a relay answering 503 (fake server, same body).
const claudeRelayOverloaded = `{"type":"result","subtype":"success","is_error":true,"api_error_status":503,"result":"API Error: 503 auth_unavailable: no auth available (providers=claude, model=claude-sonnet-4-6; last upstream error: server_is_overloaded: Our servers are currently overloaded. Please try again later.). This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (api.airick.cn).","session_id":"a7251abb-0907-4300-abf7-8def5d1cf01b"}`

func TestClassifyProbeKeepsTheRelayAnswer(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name, target, output, code, detail string
	}{
		{
			name: "codex 503", target: TargetCodexCLI, output: codexRelayOverloaded,
			code:   "LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE",
			detail: "HTTP 503 · auth_unavailable: no auth available (providers=codex, model=gpt-5.6-luna; last upstream error: server_is_overloaded: Our servers are currently overloaded. Please try again later.)",
		},
		{
			name: "codex retry limit 429", target: TargetCodexCLI,
			output: "ERROR: exceeded retry limit, last status: 429 Too Many Requests\n",
			code:   "LCT-CODEX_CLI-GATEWAY-QUOTA_EXHAUSTED", detail: "HTTP 429 · Too Many Requests",
		},
		{
			name: "codex 401", target: TargetCodexCLI,
			output: "ERROR: unexpected status 401 Unauthorized: Invalid token (request id: 2026091512), url: https://api.airick.cn/v1/responses\n",
			code:   "LCT-CODEX_CLI-AUTH-TOKEN_EXPIRED", detail: "HTTP 401 · Invalid token (request id: 2026091512)",
		},
		{
			name: "codex no channel for model", target: TargetCodexCLI,
			output: "ERROR: unexpected status 503 Service Unavailable: 当前分组 知办AI 下对于模型 gpt-5.6-luna 无可用渠道, url: https://api.airick.cn/v1/responses\n",
			code:   "LCT-CODEX_CLI-GATEWAY-MODEL_DENIED", detail: "HTTP 503 · 当前分组 知办AI 下对于模型 gpt-5.6-luna 无可用渠道",
		},
		{
			name: "claude 503", target: TargetClaudeCLI, output: claudeRelayOverloaded,
			code:   "LCT-CLAUDE_CLI-GATEWAY-UPSTREAM_UNAVAILABLE",
			detail: "HTTP 503 · auth_unavailable: no auth available (providers=claude, model=claude-sonnet-4-6; last upstream error: server_is_overloaded: Our servers are currently overloaded. Please try again later.).",
		},
		{
			name: "claude 429", target: TargetClaudeCLI,
			output: `{"is_error":true,"api_error_status":429,"result":"API Error: Request rejected (429) · insufficient quota"}`,
			code:   "LCT-CLAUDE_CLI-GATEWAY-QUOTA_EXHAUSTED", detail: "HTTP 429 · Request rejected (429) · insufficient quota",
		},
		{
			name: "claude 401", target: TargetClaudeCLI,
			output: `{"is_error":true,"api_error_status":401,"result":"Failed to authenticate. API Error: 401 invalid api key"}`,
			code:   "LCT-CLAUDE_CLI-AUTH-TOKEN_EXPIRED", detail: "HTTP 401 · invalid api key",
		},
		{
			name: "claude non-http error", target: TargetClaudeCLI,
			output: `{"is_error":true,"api_error_status":null,"result":"API Error: Connection refused — a firewall or proxy may be blocking it (ConnectionRefused)"}`,
			code:   "LCT-CLAUDE_CLI-GATEWAY-UNREACHABLE",
		},
		{
			// Unparsed output: digits inside a session id are not a status.
			name: "session id digits", target: TargetCodexCLI,
			output: "session id: 019e-429f-4010-a401\nboom\n",
			code:   "LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH",
		},
	}
	for _, test := range tests {
		code, detail := classifyProbe(test.target, []byte(test.output))
		if code != test.code || detail != test.detail {
			t.Errorf("%s: classifyProbe = %q, %q; want %q, %q", test.name, code, detail, test.code, test.detail)
		}
	}
}

func TestGatewayDetailRedactsAndBounds(t *testing.T) {
	t.Parallel()

	detail := gatewayDetail(gatewayError{
		Status:  401,
		Message: "bad key sk-AbCdEf1234567890 with Authorization: Bearer eyJhbGciOi.payload\x00 and " + strings.Repeat("Z", 48),
	})
	for _, secret := range []string{"sk-AbCdEf1234567890", "eyJhbGciOi", strings.Repeat("Z", 48), "\x00"} {
		if strings.Contains(detail, secret) {
			t.Fatalf("detail leaks %q: %q", secret, detail)
		}
	}
	if !strings.HasPrefix(detail, "HTTP 401 · bad key sk-*** with Authorization: Bearer ***") {
		t.Fatalf("detail = %q", detail)
	}

	long := gatewayDetail(gatewayError{Status: 502, Message: strings.Repeat("上游错误 ", 200)})
	if utf8.RuneCountInString(long) != gatewayDetailMaxRunes || !strings.HasSuffix(long, "…") {
		t.Fatalf("long detail has %d runes: %q", utf8.RuneCountInString(long), long)
	}
	if got := gatewayDetail(gatewayError{Status: 504}); got != "HTTP 504" {
		t.Fatalf("empty message detail = %q", got)
	}
}

// 2026-09-16: two testers' Claude Code (2.0.76 and 2.1.150) has no
// --permission-prompts; the CLI aborts before the relay is reached and the
// probe must drop exactly that option and run again.
func TestUnknownProbeOptionAndDrop(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		output string
		want   string
	}{
		{name: "commander", output: "error: unknown option '--permission-prompts'\n", want: "--permission-prompts"},
		{name: "clap", output: "error: unexpected argument '--no-chrome' found\n\nUsage: codex exec\n", want: "--no-chrome"},
		{name: "unrecognized", output: "Unrecognized flag --tools\n", want: "--tools"},
		{name: "unrelated failure", output: "HTTP 503 no available channel\n", want: ""},
	} {
		option, ok := unknownProbeOption([]byte(tc.output))
		if tc.want == "" {
			if ok {
				t.Errorf("%s: unknownProbeOption = %q, want none", tc.name, option)
			}
			continue
		}
		if !ok || option != tc.want {
			t.Errorf("%s: unknownProbeOption = %q, %v, want %q", tc.name, option, ok, tc.want)
		}
	}

	arguments := []string{"--bare", "--no-session-persistence", "--tools", "", "--permission-prompts", "none",
		"--output-format", "json", "--max-turns", "1", "-p", "hi"}
	reduced, dropped := dropProbeArgument(arguments, "--permission-prompts")
	if !dropped || strings.Contains(strings.Join(reduced, " "), "--permission-prompts") ||
		!strings.Contains(strings.Join(reduced, " "), "--output-format json") || len(reduced) != len(arguments)-2 {
		t.Fatalf("dropProbeArgument(--permission-prompts) = %q, %v", reduced, dropped)
	}
	if _, dropped := dropProbeArgument(arguments, "--output-format"); dropped {
		t.Fatal("a required option must never be dropped")
	}
	if _, dropped := dropProbeArgument(arguments, "--unknown-to-us"); dropped {
		t.Fatal("an option the probe never passes must not be dropped")
	}
}

func TestOutputDetailRedactsAndCaps(t *testing.T) {
	t.Parallel()
	detail := outputDetail([]byte("error: unknown option '--permission-prompts'\n\tAuthorization: Bearer lctd.secret-value\n"))
	if !strings.Contains(detail, "--permission-prompts") || strings.Contains(detail, "lctd.secret-value") ||
		strings.Contains(detail, "\n") {
		t.Fatalf("outputDetail = %q", detail)
	}
	if got := outputDetail([]byte(strings.Repeat("x", 1000))); utf8.RuneCountInString(got) > gatewayDetailMaxRunes {
		t.Fatalf("outputDetail length = %d", utf8.RuneCountInString(got))
	}
}

// What Claude Code 2.1.267 printed on the 2026-09-17 production machine: no
// api_error_status, so the code is UNREACHABLE ("certificate" is a network
// keyword), and the sentence in "result" is what support needs to see.
func TestProbeOutputDetailQuotesClaudeResult(t *testing.T) {
	t.Parallel()
	output := []byte("Warning: no stdin data received in 3s\n" +
		`{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"result":"API Error: Unable to connect to API: SSL certificate verification failed. Check your proxy or corporate SSL certificates","session_id":"0b0f7a52-6a1e-4a7e-9d0e-5a3a1c2d3e4f"}` + "\n")
	if code, detail := classifyProbe(TargetClaudeCLI, output); code != "LCT-CLAUDE_CLI-GATEWAY-UNREACHABLE" || detail != "" {
		t.Fatalf("classifyProbe() = %q, %q", code, detail)
	}
	if got, want := probeOutputDetail(TargetClaudeCLI, output), "API Error: Unable to connect to API: SSL certificate verification failed. Check your proxy or corporate SSL certificates"; got != want {
		t.Fatalf("probeOutputDetail() = %q, want %q", got, want)
	}
	// Anything that is not Claude's JSON falls back to the raw output.
	if got := probeOutputDetail(TargetCodexCLI, []byte("stream error: tls handshake eof\n")); got != "stream error: tls handshake eof" {
		t.Fatalf("probeOutputDetail(codex) = %q", got)
	}
}
