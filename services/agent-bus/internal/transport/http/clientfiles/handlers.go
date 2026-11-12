// Package clientfiles reuses the Bus chat attachment transport without commercial dependencies.
package clientfiles

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	"net/http"
)

const uploadMaxMemory = 4 * 1024 * 1024

type Handlers struct {
	ChatUpload *drive.ChatUploadSvc
	ChatMedia  *drive.ChatMediaSvc
}

func (h *Handlers) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler) {
	mux.Handle("POST /api/agent-bus/v1/message-files/upload", auth(http.HandlerFunc(h.Upload)))
	mux.Handle("POST /api/agent-bus/v1/message-files/presign", auth(http.HandlerFunc(h.Presign)))
	mux.Handle("POST /api/agent-bus/v1/message-files/confirm", auth(http.HandlerFunc(h.Confirm)))
	mux.Handle("GET /api/agent-bus/v1/message-files/{uuid}/download", auth(http.HandlerFunc(h.Download)))
	mux.Handle("GET /api/agent-bus/v1/message-files/{uuid}/preview", auth(http.HandlerFunc(h.Preview)))
	mux.Handle("POST /api/agent-bus/v1/chat/media", auth(http.HandlerFunc(h.CreateMedia)))
	mux.Handle("GET /api/agent-bus/v1/chat/media/{uuid}/preview", auth(http.HandlerFunc(h.PreviewMedia)))
	mux.Handle("GET /api/agent-bus/v1/chat/media/{uuid}/download", auth(http.HandlerFunc(h.DownloadMedia)))
}
