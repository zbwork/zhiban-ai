package clientlocal

import (
	"net/http"

	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// Register mounts the Local Agent control plane, member model platforms, image, search and file archive routes. Run-scoped routes authenticate with the
// run capability token inside the handler and therefore do not use the account middleware.
func (h *Handlers) Register(mux *http.ServeMux, authT func(http.Handler) http.Handler) {
	const base = "/api/agent-bus/v1/local-runtime"
	mux.Handle("POST "+base+"/devices", authT(http.HandlerFunc(h.localRegister)))
	mux.Handle("POST "+base+"/devices/{device}/revoke", authT(http.HandlerFunc(h.localRevoke)))
	mux.Handle("GET "+base+"/conversations/{conversation}", authT(http.HandlerFunc(h.localConversationState)))
	mux.Handle("GET "+base+"/desktop", authT(http.HandlerFunc(h.localDesktopStatus)))
	mux.Handle("GET "+base+"/approvals", authT(http.HandlerFunc(h.localApprovals)))
	mux.Handle("POST "+base+"/approvals/{id}", authT(http.HandlerFunc(h.localDecideApproval)))
	mux.Handle("GET "+base+"/channel", authT(http.HandlerFunc(h.localChannel)))
	mux.Handle("POST "+base+"/runs/{run}/results", authT(http.HandlerFunc(h.localResults)))
	mux.Handle("POST "+base+"/runs/{run}/archive/{operation}", authT(http.HandlerFunc(h.localResults)))
	mux.HandleFunc("POST "+base+"/runs/{run}/approvals", h.localRunApproval)
	mux.HandleFunc("GET "+base+"/runs/{run}/approvals/{id}", h.localRunApproval)
	mux.HandleFunc("DELETE "+base+"/runs/{run}/approvals/{id}", h.localRunApproval)
	mux.HandleFunc("POST "+base+"/runs/{run}/authorize", h.localAuthorize)
	mux.HandleFunc("POST "+base+"/runs/{run}/model/{protocol...}", h.localModel)
	mux.HandleFunc("POST "+base+"/runs/{run}/files/{operation}", h.localOutput)
	mux.HandleFunc("PUT "+svcdrive.LocalUploadPath, h.localUpload)
	mux.HandleFunc("POST "+base+"/runs/{run}/images", h.localImage)
	mux.HandleFunc("POST "+base+"/runs/{run}/search", h.localSearch)
	mux.Handle("POST /api/agent-bus/v1/model-service/providers/sync", authT(http.HandlerFunc(h.syncModelSources)))
	mux.Handle("GET /api/agent-bus/v1/conversation-models", authT(http.HandlerFunc(h.listConversationModels)))
}
