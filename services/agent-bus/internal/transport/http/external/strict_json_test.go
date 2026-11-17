package external

import (
	"strings"
	"testing"

	svcextorg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/externalorg"
)

func TestDecodeStrictJSONRejectsRemovedIdentifierFields(t *testing.T) {
	tests := []struct {
		name string
		body string
		dst  any
	}{
		{"department external_code", `{"name":"研发部","external_code":"old"}`, &svcextorg.CreateDepartmentInput{}},
		{"member employee_id", `{"phone":"13800138000","employee_id":"old"}`, &svcextorg.CreateMemberInput{}},
		{"member department_uuid", `{"phone":"13800138000","department_uuid":"old"}`, &svcextorg.CreateMemberInput{}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := decodeStrictJSON(strings.NewReader(tt.body), tt.dst)
			if err == nil || !strings.Contains(err.Error(), "unknown field") {
				t.Fatalf("removed field must be rejected, got %v", err)
			}
		})
	}
}
