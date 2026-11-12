package runtimeenv

import (
	"encoding/json"
	"strings"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
)

func TestClientEnvironmentDoesNotExposeDeploymentCredentials(t *testing.T) {
	secret := "private-fixture-value"
	input := dom.Env{UUID: "env-id", Name: "DSH", Framework: "dsh", Enabled: true,
		APIKeySecretRef: secret, WorkloadAPITokenSecretRef: secret, K8sTokenSecretRef: secret,
		HTTPProxy: secret, HTTPSProxy: secret, PrimaryEndpoint: secret,
		WorkloadEnv: map[string]any{"API_KEY": secret}, Metadata: map[string]any{"nested": secret},
		FrameworkConfig: map[string]any{"secret": secret}, EgressComplianceDocs: map[string]any{"private": secret}}
	result := clientEnv(input)
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatal("deployment credential reached client projection")
	}
	if result.UUID != input.UUID || result.Name != input.Name || result.Framework != input.Framework || !result.Enabled {
		t.Fatal("client selection fields were lost")
	}
	if input.WorkloadEnv["API_KEY"] != secret {
		t.Fatal("projection modified repository data")
	}
}
