package imconnection

import "testing"

func TestShouldRecordReconnect(t *testing.T) {
	tests := []struct {
		name           string
		previousCID    int64
		currentCID     int64
		previousStatus string
		want           bool
	}{
		{name: "same live connection", previousCID: 8, currentCID: 8, previousStatus: "online", want: false},
		{name: "live connection replaced", previousCID: 8, currentCID: 9, previousStatus: "online", want: true},
		{name: "backfill previously missing id", previousCID: 0, currentCID: 9, previousStatus: "online", want: false},
		{name: "offline connection returns", previousCID: 8, currentCID: 8, previousStatus: "offline", want: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldRecordReconnect(tt.previousCID, tt.currentCID, tt.previousStatus); got != tt.want {
				t.Fatalf("shouldRecordReconnect()=%v, want %v", got, tt.want)
			}
		})
	}
}

func TestReconnectReason(t *testing.T) {
	tests := []struct {
		name           string
		previousCID    int64
		currentCID     int64
		previousStatus string
		want           string
	}{
		{name: "offline connection returns", previousCID: 8, currentCID: 9, previousStatus: "offline", want: "returned_after_missing_snapshots"},
		{name: "online connection replaced", previousCID: 8, currentCID: 9, previousStatus: "online", want: "connection_replaced"},
		{name: "same online connection", previousCID: 8, currentCID: 8, previousStatus: "online", want: ""},
		{name: "missing id backfill", previousCID: 0, currentCID: 9, previousStatus: "online", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := reconnectReason(tt.previousCID, tt.currentCID, tt.previousStatus); got != tt.want {
				t.Fatalf("reconnectReason()=%q, want %q", got, tt.want)
			}
		})
	}
}

func TestNormalizeEventReason(t *testing.T) {
	zero, eight, nine := int64(0), int64(8), int64(9)
	tests := []struct {
		name        string
		eventType   string
		reason      string
		previousCID *int64
		currentCID  int64
		want        string
	}{
		{name: "legacy missing ids were offline recovery", eventType: "reconnected", reason: "connection_replaced", previousCID: &zero, currentCID: 0, want: "returned_after_missing_snapshots"},
		{name: "same valid id was offline recovery", eventType: "reconnected", reason: "connection_replaced", previousCID: &eight, currentCID: 8, want: "returned_after_missing_snapshots"},
		{name: "different ids remain replacement", eventType: "reconnected", reason: "connection_replaced", previousCID: &eight, currentCID: 9, want: "connection_replaced"},
		{name: "other event remains unchanged", eventType: "disconnected", reason: "missing_two_snapshots", previousCID: &nine, currentCID: 9, want: "missing_two_snapshots"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := normalizeEventReason(tt.eventType, tt.reason, tt.previousCID, tt.currentCID); got != tt.want {
				t.Fatalf("normalizeEventReason()=%q, want %q", got, tt.want)
			}
		})
	}
}
