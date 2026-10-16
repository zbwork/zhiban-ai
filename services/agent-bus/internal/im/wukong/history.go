package wukong

import (
	"encoding/json"
	"strconv"
	"time"
)

// FilterSyncMessagesAfter applies the caller clear-history watermark.
func FilterSyncMessagesAfter(data any, after time.Time) any {
	obj, ok := data.(map[string]any)
	if !ok {
		return data
	}
	list, ok := obj["messages"].([]any)
	if !ok || len(list) == 0 {
		return data
	}
	kept := make([]any, 0, len(list))
	for _, item := range list {
		msg, ok := item.(map[string]any)
		if !ok {
			continue
		}
		ts, ok := asWuKongTimestamp(msg["timestamp"])
		if !ok {
			continue
		}
		if wuKongTimestampTime(ts).After(after) {
			kept = append(kept, item)
		}
	}
	obj["messages"] = kept
	return obj
}

func asWuKongTimestamp(v any) (int64, bool) {
	switch t := v.(type) {
	case int64:
		return t, t > 0
	case int:
		return int64(t), t > 0
	case float64:
		return int64(t), t > 0
	case json.Number:
		n, err := t.Int64()
		return n, err == nil && n > 0
	case string:
		n, err := strconv.ParseInt(t, 10, 64)
		if err != nil {
			return 0, false
		}
		return n, n > 0
	default:
		return 0, false
	}
}

func wuKongTimestampTime(ts int64) time.Time {
	switch {
	case ts >= 1_000_000_000_000_000:
		return time.UnixMicro(ts)
	case ts >= 1_000_000_000_000:
		return time.UnixMilli(ts)
	default:
		return time.Unix(ts, 0)
	}
}
