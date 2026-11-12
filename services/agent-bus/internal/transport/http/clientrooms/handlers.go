package clientrooms

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/directroom"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/room"
	"net/http"
)

type Handlers struct {
	Room       room.Service
	DirectRoom directroom.Service
	Contacts   contacts.Service
}

func (h *Handlers) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler) {
	mux.Handle("POST /api/agent-bus/v1/rooms", auth(http.HandlerFunc(h.Create)))
	mux.Handle("GET /api/agent-bus/v1/rooms/{room_uuid}", auth(http.HandlerFunc(h.Get)))
	mux.Handle("PATCH /api/agent-bus/v1/rooms/{room_uuid}", auth(http.HandlerFunc(h.Rename)))
	mux.Handle("POST /api/agent-bus/v1/rooms/{room_uuid}/participants", auth(http.HandlerFunc(h.AddParticipants)))
	mux.Handle("DELETE /api/agent-bus/v1/rooms/{room_uuid}/participants/{participant_uuid}", auth(http.HandlerFunc(h.RemoveParticipant)))
	mux.Handle("POST /api/agent-bus/v1/rooms/{room_uuid}/messages", auth(http.HandlerFunc(h.SendMessage)))
	mux.Handle("GET /api/agent-bus/v1/rooms/{room_uuid}/messages", auth(http.HandlerFunc(h.ListMessages)))
	if h.DirectRoom != nil {
		mux.Handle("POST /api/agent-bus/v1/direct-rooms", auth(http.HandlerFunc(h.CreateDirect)))
	}
}
