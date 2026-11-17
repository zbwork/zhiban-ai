package contacts

import (
	"context"
	"testing"
)

func TestProjectedPositionStillHonorsContactOverrideAndMask(t *testing.T) {
	for _, tc := range []struct{ name, meta, want string }{
		{"current primary", `{}`, "current primary position"},
		{"explicit override", `{"position_label_override":"public role"}`, "public role"},
		{"explicit empty override", `{"position_label_override":""}`, ""},
		{"hidden title", `{"field_mask":{"title":"hidden"}}`, ""},
		{"self only for another member", `{"field_mask":{"title":"self"}}`, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &impl{}
			contact := s.buildHuman(context.Background(), CallerCtx{AccountID: 1, TenantID: 10}, ContactPolicy{DefaultShowTitle: FieldAll}, humanRow{AccID: 2, Title: "current primary position", MetaJSON: []byte(tc.meta)})
			if contact.Subtitle != tc.want {
				t.Fatalf("title=%q want=%q", contact.Subtitle, tc.want)
			}
		})
	}
}
