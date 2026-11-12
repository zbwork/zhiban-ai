package admincore

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domim "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/imconnection"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// WuKongStatusHandler exposes platform-only WuKongIM operational status.
type WuKongStatusHandler struct {
	Pool        *pgxpool.Pool
	Cfg         WuKongConfig
	Client      *wukong.Client
	Connections domim.Store
}

func (h *WuKongStatusHandler) Overview(w http.ResponseWriter, r *http.Request) {
	if h.Connections == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("im connection store not wired"))
		return
	}
	out, err := h.Connections.Overview(r.Context())
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, out)
}

func (h *WuKongStatusHandler) ConnectionsList(w http.ResponseWriter, r *http.Request) {
	if h.Connections == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("im connection store not wired"))
		return
	}
	q := r.URL.Query()
	page, pageSize := positiveInt(q.Get("page"), 1, 1000000), positiveInt(q.Get("page_size"), 20, 100)
	search := strings.TrimSpace(q.Get("q"))
	if len([]rune(search)) > 128 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("q is too long"))
		return
	}
	if raw := q.Get("status"); raw != "" && raw != "online" && raw != "offline" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("status must be online or offline"))
		return
	}
	filter := domim.StateFilter{
		Query: search, Status: q.Get("status"),
		Anomalous: q.Get("anomalous") == "true", Offset: (page - 1) * pageSize, Limit: pageSize,
	}
	if raw := q.Get("tenant_id"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id must be a positive integer"))
			return
		}
		filter.TenantID = value
	}
	if raw := q.Get("device_flag"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("device_flag must be an integer"))
			return
		}
		filter.DeviceFlag = &value
	}
	items, total, err := h.Connections.ListStates(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "page": page, "page_size": pageSize})
}

func (h *WuKongStatusHandler) ConnectionDetail(w http.ResponseWriter, r *http.Request) {
	if h.Connections == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("im connection store not wired"))
		return
	}
	id, err := uuid.Parse(r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid connection uuid"))
		return
	}
	out, err := h.Connections.GetState(r.Context(), id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.ErrNotFound.Withf("connection not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, out)
}

func (h *WuKongStatusHandler) Events(w http.ResponseWriter, r *http.Request) {
	if h.Connections == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("im connection store not wired"))
		return
	}
	q := r.URL.Query()
	page, pageSize := positiveInt(q.Get("page"), 1, 1000000), positiveInt(q.Get("page_size"), 20, 100)
	if raw := q.Get("event_type"); raw != "" && raw != "connected" && raw != "reconnected" && raw != "disconnected" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("unsupported event_type"))
		return
	}
	filter := domim.EventFilter{EventType: q.Get("event_type"), Offset: (page - 1) * pageSize, Limit: pageSize}
	if raw := q.Get("state_uuid"); raw != "" {
		id, err := uuid.Parse(raw)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid state_uuid"))
			return
		}
		filter.StateUUID = id
	}
	if raw := q.Get("tenant_id"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id must be a positive integer"))
			return
		}
		filter.TenantID = value
	}
	items, total, err := h.Connections.ListEvents(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "page": page, "page_size": pageSize})
}

func positiveInt(raw string, fallback, max int) int {
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	if value > max {
		return max
	}
	return value
}

type wukongConfigResp struct {
	Enabled                 bool   `json:"enabled"`
	APIAddrConfigured       bool   `json:"api_addr_configured"`
	TCPAddr                 string `json:"tcp_addr,omitempty"`
	WSAddr                  string `json:"ws_addr,omitempty"`
	WebhookSecretConfigured bool   `json:"webhook_secret_configured"`
	WebhookIPAllowlist      string `json:"webhook_ip_allowlist,omitempty"`
}

type wukongProbeResp struct {
	Status    string `json:"status"`
	LatencyMS int64  `json:"latency_ms"`
	Message   string `json:"message,omitempty"`
}

type wukongStatsResp struct {
	RoomsLinked24h          int `json:"rooms_linked_24h"`
	RoomsLinkedTotal        int `json:"rooms_linked_total"`
	AgentTriggersLast24h    int `json:"agent_triggers_last_24h"`
	WebhookRejectsLast24h   int `json:"webhook_rejects_last_24h"`
	AgentRepliesLast24hBest int `json:"agent_replies_last_24h_best_effort"`
}

func (h *WuKongStatusHandler) Config(w http.ResponseWriter, r *http.Request) {
	encode.JSON(w, wukongConfigResp{
		Enabled:                 h.Cfg.Enabled,
		APIAddrConfigured:       strings.TrimSpace(h.Cfg.APIAddr) != "",
		TCPAddr:                 h.Cfg.TCPAddr,
		WSAddr:                  h.Cfg.WSAddr,
		WebhookSecretConfigured: strings.TrimSpace(h.Cfg.WebhookSecretRef) != "",
		WebhookIPAllowlist:      h.Cfg.WebhookIPAllowlist,
	})
}

func (h *WuKongStatusHandler) Probe(w http.ResponseWriter, r *http.Request) {
	if !h.Cfg.Enabled {
		encode.JSON(w, wukongProbeResp{Status: "disabled", Message: "WuKongIM 未启用"})
		return
	}
	if h.Client == nil {
		encode.JSON(w, wukongProbeResp{Status: "error", Message: "WuKongIM client 未装配"})
		return
	}
	start := time.Now()
	_, err := h.Client.SyncConversations(r.Context(), "agent-bus-admin-probe", 1)
	elapsed := time.Since(start).Milliseconds()
	if err != nil {
		encode.JSON(w, wukongProbeResp{Status: "error", LatencyMS: elapsed, Message: err.Error()})
		return
	}
	encode.JSON(w, wukongProbeResp{Status: "ok", LatencyMS: elapsed})
}

func (h *WuKongStatusHandler) Stats(w http.ResponseWriter, r *http.Request) {
	if h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("wukong status pool not wired"))
		return
	}
	var out wukongStatsResp
	err := h.Pool.QueryRow(r.Context(), `
SELECT
  COALESCE((SELECT count(*) FROM rooms
    WHERE deleted_at IS NULL AND COALESCE(wukong_channel_id, '') <> ''
      AND created_at > now() - interval '24 hours'), 0)::int AS rooms_linked_24h,
  COALESCE((SELECT count(*) FROM rooms
    WHERE deleted_at IS NULL AND COALESCE(wukong_channel_id, '') <> ''), 0)::int AS rooms_linked_total,
  COALESCE((SELECT count(*) FROM agent_trigger_log
    WHERE substrate='wukong' AND received_at > now() - interval '24 hours'), 0)::int AS agent_triggers_last_24h,
  COALESCE((SELECT count(*) FROM agent_trigger_log
    WHERE substrate='wukong' AND decision='rejected' AND received_at > now() - interval '24 hours'), 0)::int AS webhook_rejects_last_24h,
  COALESCE((SELECT count(*) FROM agent_trigger_log
    WHERE substrate='wukong' AND decision='triggered' AND received_at > now() - interval '24 hours'), 0)::int AS agent_replies_best_effort
`).Scan(
		&out.RoomsLinked24h,
		&out.RoomsLinkedTotal,
		&out.AgentTriggersLast24h,
		&out.WebhookRejectsLast24h,
		&out.AgentRepliesLast24hBest,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, out)
}

// WuKongConfig mirrors the original status fields without importing commercial config.
type WuKongConfig struct {
	Enabled bool `yaml:"enabled"`
	// APIAddr WuKong 特权 REST,形如 http://127.0.0.1:31021(仅 agent-bus 用)。
	APIAddr string `yaml:"api_addr"`
	// TCPAddr / WSAddr 通告给客户端的长连接地址(下发到 /im/credentials)。
	TCPAddr string `yaml:"tcp_addr"` // e.g. 127.0.0.1:31022
	WSAddr  string `yaml:"ws_addr"`  // e.g. ws://127.0.0.1:31023
	// WebhookSecretRef 内网 secret 校验(env://VAR / value://...);WuKong webhook 默认无签名,
	// 由部署在内网 + 本 secret(Header 比对)保证只接受可信来源。
	WebhookSecretRef string `yaml:"webhook_secret_ref"`
	// WebhookIPAllowlist CIDR csv;空 = 不限。
	WebhookIPAllowlist string `yaml:"webhook_ip_allowlist"`
	// CredentialTTLHours 客户端连接凭证(/im/credentials 的 wukong.expires_at)建议刷新 TTL(小时)。
	// 默认 24。即便底层 token 长期有效,也回一个刷新建议时间,客户端据此统一连接状态机。
	CredentialTTLHours int `yaml:"credential_ttl_hours"`
}
