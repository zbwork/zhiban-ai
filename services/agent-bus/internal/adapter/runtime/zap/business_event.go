package zap

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// DecodeBusinessEvent reuses the ZAP HTTP parser for durable device envelopes.
// It accepts a single business event, never native engine protocol data.
func DecodeBusinessEvent(name string, data json.RawMessage) (SSEEvent, error) {
	if len(data) > 1024*1024 || strings.ContainsAny(name, "\r\n") || !json.Valid(data) {
		return SSEEvent{}, errors.New("invalid ZAP business event")
	}
	var event SSEEvent
	err := parseSSE(bytes.NewBufferString(fmt.Sprintf("event: %s\ndata: %s\n\n", name, data)), func(value SSEEvent) (bool, error) { event = value; return true, nil })
	if errors.Is(err, ErrSSEStopByHandler) {
		err = nil
	}
	return event, err
}
