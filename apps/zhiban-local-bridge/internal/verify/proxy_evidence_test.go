package verify

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// Missing bypass settings must not turn a usable proxy route into a failure.
func TestProxyConfigurationPreservesTimeoutRetriesAndSuccess(t *testing.T) {
	for _, retry := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "transient failure then success"}[retry], func(t *testing.T) {
			calls := 0
			r := &relay{targetID: TargetCodexCLI}
			f := newFixture(t, successScript, func(c *ManagerConfig) {
				c.ProbeTimeout = 90 * time.Second
				c.ProxyRisk = func(context.Context) bool { return true }
				c.Run = func(ctx context.Context, in Invocation) (Outcome, error) {
					calls++
					deadline, ok := ctx.Deadline()
					if !ok || time.Until(deadline) < 85*time.Second {
						t.Errorf("proxy configuration shortened request deadline: %v", time.Until(deadline))
					}
					if retry && calls == 1 {
						return Outcome{ExitCode: 1, Output: []byte("error sending request: connection refused")}, nil
					}
					return r.run(ctx, in)
				}
			})
			result := f.execute(t, TargetCodexCLI)
			wantCalls := 1
			if retry {
				wantCalls = 2
			}
			if result.State != operation.StateSucceeded || calls != wantCalls {
				t.Fatalf("result=%+v calls=%d want=%d", result, calls, wantCalls)
			}
		})
	}
}

func TestProxyConfigurationDoesNotSuppressWorkingFallback(t *testing.T) {
	for _, target := range []string{TargetCodexCLI, TargetClaudeCLI} {
		t.Run(target, func(t *testing.T) {
			r := &relay{targetID: target, down: map[string]bool{"": true}}
			f := fallbackFixture(t, r)
			f.manager.proxyRisk = func(context.Context) bool { return true }
			result := f.execute(t, target)
			if result.State != operation.StateSucceeded || modelWarning(t, result) == nil || len(r.asked) != 3 {
				t.Fatalf("result=%+v models=%v", result, r.asked)
			}
		})
	}
}

func TestProxyHintRequiresActualNetworkFailureAndPreservesOtherErrors(t *testing.T) {
	for _, tc := range []struct{ name, output, want string }{
		{"network", "error sending request: connection refused", "GATEWAY-PROXY_INTERFERENCE"},
		{"certificate", "error sending request: SSL certificate verification failed", "GATEWAY-UNREACHABLE"},
		{"auth", "ERROR: unexpected status 401 Unauthorized", "AUTH-TOKEN_EXPIRED"},
		{"quota", "ERROR: unexpected status 429 Too Many Requests", "GATEWAY-QUOTA_EXHAUSTED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t, successScript, func(c *ManagerConfig) {
				c.ProxyRisk = func(context.Context) bool { return true }
				c.Run = func(context.Context, Invocation) (Outcome, error) {
					return Outcome{ExitCode: 1, Output: []byte(tc.output)}, nil
				}
			})
			result := f.execute(t, TargetCodexCLI)
			if result.State != operation.StateFailed || result.ErrorCode == nil || !strings.HasSuffix(*result.ErrorCode, "-"+tc.want) {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}
