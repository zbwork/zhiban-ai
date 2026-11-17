package clientlocal

import (
	"context"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type LocalSkillReader interface {
	ReadTaskSkill(context.Context, *dom.Task, string) ([]byte, error)
}

func (h *Handlers) localSkillPackage(w http.ResponseWriter, r *http.Request) {
	task, _, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	if h.Skills == nil {
		localError(w, dom.ErrOffline)
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), task.ExpiresAt)
	defer cancel()
	bytes, err := h.Skills.ReadTaskSkill(ctx, task, r.PathValue("skill"))
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.Itoa(len(bytes)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(bytes)
}
