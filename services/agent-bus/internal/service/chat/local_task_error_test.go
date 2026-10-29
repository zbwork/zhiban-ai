package chat

import (
	"errors"
	"fmt"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"testing"
)

func TestLocalTaskCreateError(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code string
	}{
		{dom.ErrModelUnavailable, "local_runtime.model_unavailable"},
		{errors.Join(dom.ErrModelUnavailable, dom.ErrDenied), "local_runtime.model_unavailable"},
		{dom.ErrOffline, "local_runtime.device_offline"},
		{dom.ErrDenied, "local_runtime.denied"},
		{dom.ErrConflict, "local_runtime.conflict"},
		{errors.New("SECRET"), "local_runtime.task_create_failed"},
	} {
		code, msg := localTaskCreateError(fmt.Errorf("wrapped: %w", tc.err))
		if code != tc.code || msg == "" {
			t.Fatalf("got %s %s want %s", code, msg, tc.code)
		}
	}
}
