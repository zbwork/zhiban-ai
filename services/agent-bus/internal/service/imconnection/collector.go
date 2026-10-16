package imconnection

import (
	"context"
	"fmt"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/imconnection"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
)

const (
	pageSize       = 500
	maxConnections = 100000
)

type Source interface {
	ListConnections(ctx context.Context, offset, limit int) (wukong.ConnectionPage, error)
}

type Collector struct {
	source Source
	store  dom.Store
	now    func() time.Time
}

func NewCollector(source Source, store dom.Store) *Collector {
	return &Collector{source: source, store: store, now: time.Now}
}

// RunOnce 先完整读取所有分页，再原子应用快照。任何分页失败都只更新采集器错误，
// 不触碰连接状态，避免把 WuKong/网络故障误判为全员离线。
func (c *Collector) RunOnce(ctx context.Context) error {
	at := c.now().UTC()
	observations := make([]dom.Observation, 0, pageSize)
	for offset := 0; ; offset += pageSize {
		page, err := c.source.ListConnections(ctx, offset, pageSize)
		if err != nil {
			_ = c.store.MarkCollectorFailure(ctx, at, "WuKong /connz unavailable")
			return err
		}
		for _, conn := range page.Connections {
			if observation, ok := toObservation(conn); ok {
				observations = append(observations, observation)
			}
		}
		if len(observations) > maxConnections {
			_ = c.store.MarkCollectorFailure(ctx, at, "WuKong /connz exceeds safety limit")
			return fmt.Errorf("wukong connz exceeds %d connections", maxConnections)
		}
		count := len(page.Connections)
		total := page.Total
		if total <= 0 {
			total = page.NumConnections
		}
		if count == 0 || count < pageSize || (total > 0 && offset+count >= total) {
			break
		}
	}
	return c.store.ApplySnapshot(ctx, observations, at, at.Add(-60*time.Second))
}

func (c *Collector) Cleanup(ctx context.Context) error {
	return c.store.CleanupEvents(ctx, c.now().UTC().Add(-30*24*time.Hour))
}

func toObservation(conn wukong.ConnectionInfo) (dom.Observation, bool) {
	tenantID, kind, subjectUUID, ok := wukong.ParseNamespacedID(strings.TrimSpace(conn.UID))
	if !ok || tenantID <= 0 {
		return dom.Observation{}, false
	}
	subjectKind := "unknown"
	switch kind {
	case "u":
		subjectKind = "human"
	case "a":
		subjectKind = "agent"
	}
	deviceID := strings.TrimSpace(conn.DeviceID)
	deviceKey := fmt.Sprintf("flag:%d", conn.DeviceFlag)
	masked := "设备标识缺失"
	available := deviceID != ""
	if available {
		deviceKey = hashDeviceID(deviceID)
		masked = maskDeviceID(deviceID)
	}
	return dom.Observation{
		TenantID: tenantID, UID: strings.TrimSpace(conn.UID), SubjectKind: subjectKind,
		SubjectUUID: subjectUUID, DeviceKey: deviceKey, DeviceIDMasked: masked,
		DeviceIDAvailable: available, DeviceFlag: conn.DeviceFlag, DeviceLevel: conn.DeviceLevel,
		ConnectionID: conn.CID, ProtocolVersion: safeText(string(conn.Version), 64),
		ConnectedAt: parseWuKongTime(conn.Start), LastActivityAt: parseWuKongTime(conn.LastActivity),
	}, true
}

func maskDeviceID(value string) string {
	runes := []rune(value)
	if len(runes) <= 6 {
		return "••••"
	}
	return string(runes[:3]) + "••••" + string(runes[len(runes)-3:])
}

func safeText(value string, limit int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return value
}

func parseWuKongTime(value string) *time.Time {
	value = strings.TrimSpace(value)
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			parsed = parsed.UTC()
			return &parsed
		}
	}
	return nil
}
