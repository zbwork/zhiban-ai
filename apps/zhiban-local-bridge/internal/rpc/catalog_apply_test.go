package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

func TestCatalogApplyAndUpgradeModes(t *testing.T) {
	t.Parallel()

	var applied []CatalogApplyParams
	var planned []InstallPlanParams
	server := NewServer(Config{
		BridgeVersion: "0.4.0-test", Platform: "macos", Arch: "arm64",
		Detect: func(_ context.Context, targetID string) (any, error) {
			return map[string]any{"target_id": targetID}, nil
		},
		CatalogApply: func(_ context.Context, params CatalogApplyParams) (any, error) {
			applied = append(applied, params)
			if params.KID == "lc-catalog-bad" {
				return nil, operation.Fail("LCT-BRIDGE-CATALOG-UNTRUSTED_KEY", errors.New("no key"))
			}
			if len(params.Catalog) == 0 || string(bytes.TrimSpace(params.Catalog)) == "null" {
				return map[string]any{"applied": false}, nil
			}
			return map[string]any{"applied": true}, nil
		},
		InstallPlan: func(_ context.Context, params InstallPlanParams) (any, error) {
			planned = append(planned, params)
			return map[string]any{"plan_id": "p1", "mode": params.Mode}, nil
		},
	})

	catalogJSON := `{"schema":1,"issued_at":"2026-09-10T00:00:00Z","expires_at":"2026-09-17T00:00:00Z","platform":"macos","arch":"arm64","allowed_hosts":[],"targets":{}}`
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		// valid apply
		`{"jsonrpc":"2.0","id":1,"method":"catalog.apply","params":{"environment":"test","kid":"lc-catalog-test","signature":"c2ln","catalog":` + catalogJSON + `}}`,
		// clear
		`{"jsonrpc":"2.0","id":2,"method":"catalog.apply","params":{"environment":"test","catalog":null}}`,
		// bad environment
		`{"jsonrpc":"2.0","id":3,"method":"catalog.apply","params":{"environment":"staging","kid":"k","signature":"c2ln","catalog":` + catalogJSON + `}}`,
		// catalog present but no signature
		`{"jsonrpc":"2.0","id":4,"method":"catalog.apply","params":{"environment":"test","kid":"k","catalog":` + catalogJSON + `}}`,
		// signature outside base64url alphabet
		`{"jsonrpc":"2.0","id":5,"method":"catalog.apply","params":{"environment":"test","kid":"k","signature":"c2ln!!","catalog":` + catalogJSON + `}}`,
		// catalog that is not an object
		`{"jsonrpc":"2.0","id":6,"method":"catalog.apply","params":{"environment":"test","kid":"k","signature":"c2ln","catalog":[1]}}`,
		// domain error passthrough
		`{"jsonrpc":"2.0","id":7,"method":"catalog.apply","params":{"environment":"test","kid":"lc-catalog-bad","signature":"c2ln","catalog":` + catalogJSON + `}}`,
		// upgrade / rollback are valid install.plan modes now; reinstall is not
		`{"jsonrpc":"2.0","id":8,"method":"install.plan","params":{"target_id":"codex_cli","mode":"upgrade"}}`,
		`{"jsonrpc":"2.0","id":9,"method":"install.plan","params":{"target_id":"claude_cli","mode":"rollback"}}`,
		`{"jsonrpc":"2.0","id":10,"method":"install.plan","params":{"target_id":"codex_cli","mode":"reinstall"}}`,
	}, "\n") + "\n"

	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 11 {
		t.Fatalf("responses = %d: %s", len(responses), stdout.String())
	}
	var init InitializeResult
	if err := json.Unmarshal(responses[0].Result, &init); err != nil {
		t.Fatalf("decode initialize: %v", err)
	}
	if !contains(init.SupportedMethods, "catalog.apply") || !contains(init.SupportedMethods, "install.plan") {
		t.Fatalf("supported methods = %v", init.SupportedMethods)
	}
	if responses[1].Error != nil || responses[2].Error != nil {
		t.Fatalf("valid applies errored: %+v %+v", responses[1].Error, responses[2].Error)
	}
	for _, index := range []int{3, 4, 5, 6} {
		if responses[index].Error == nil || responses[index].Error.Code != CodeInvalidParams {
			t.Fatalf("response %d = %+v, want invalid params", index, responses[index])
		}
	}
	if responses[7].Error == nil || responses[7].Error.Code != CodeDomainError || responses[7].Error.Message != "LCT-BRIDGE-CATALOG-UNTRUSTED_KEY" {
		t.Fatalf("domain error response = %+v", responses[7])
	}
	if len(applied) != 3 || applied[0].Environment != "test" || applied[0].KID != "lc-catalog-test" || applied[0].Signature != "c2ln" ||
		string(applied[0].Catalog) != catalogJSON || string(bytes.TrimSpace(applied[1].Catalog)) != "null" || applied[1].KID != "" {
		t.Fatalf("applied params = %+v", applied)
	}
	if responses[8].Error != nil || responses[9].Error != nil || len(planned) != 2 || planned[0].Mode != "upgrade" || planned[1].Mode != "rollback" {
		t.Fatalf("install.plan upgrade/rollback = %+v %+v planned=%+v", responses[8], responses[9], planned)
	}
	if responses[10].Error == nil || responses[10].Error.Code != CodeInvalidParams {
		t.Fatalf("install.plan reinstall = %+v, want invalid params", responses[10])
	}
}

func TestCatalogApplyUnavailableWithoutManager(t *testing.T) {
	t.Parallel()
	server := NewServer(Config{BridgeVersion: "0.4.0-test", Platform: "macos", Arch: "arm64",
		Detect: func(_ context.Context, targetID string) (any, error) {
			return map[string]any{"target_id": targetID}, nil
		},
	})
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"catalog.apply","params":{"environment":"test","catalog":null}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	responses := decodeResponses(t, stdout.String())
	var init InitializeResult
	_ = json.Unmarshal(responses[0].Result, &init)
	if contains(init.SupportedMethods, "catalog.apply") {
		t.Fatalf("catalog.apply advertised without a manager: %v", init.SupportedMethods)
	}
	if responses[1].Error == nil || responses[1].Error.Code != CodeMethodNotFound {
		t.Fatalf("catalog.apply without manager = %+v", responses[1])
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
