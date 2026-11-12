package clientanalytics

import (
	"context"
	"errors"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

type fakeOverviewReader struct {
	days            int
	now             time.Time
	includeArchived bool
}

func (r *fakeOverviewReader) Overview(_ context.Context, days int, now time.Time, includeArchived bool) (*dom.Overview, error) {
	r.days = days
	r.now = now
	r.includeArchived = includeArchived
	return &dom.Overview{RangeDays: days, DAU: 3, WAU: 8, MAU: 10}, nil
}

func TestOverviewUsesSupportedRange(t *testing.T) {
	repo := &fakeOverviewReader{}
	svc := NewOverview(repo)
	out, err := svc.Overview(context.Background(), 30, false)
	if err != nil {
		t.Fatalf("Overview() error=%v", err)
	}
	if repo.days != 30 || repo.now.IsZero() {
		t.Fatalf("repo args days=%d now=%v", repo.days, repo.now)
	}
	if out.StickinessPct != 30 {
		t.Fatalf("stickiness=%v want 30", out.StickinessPct)
	}
}

func TestOverviewPassesIncludeArchived(t *testing.T) {
	repo := &fakeOverviewReader{}
	if _, err := NewOverview(repo).Overview(context.Background(), 30, true); err != nil {
		t.Fatalf("Overview() error=%v", err)
	}
	if !repo.includeArchived {
		t.Fatalf("includeArchived not propagated")
	}
}

func TestOverviewRejectsUnsupportedRange(t *testing.T) {
	for _, days := range []int{0, 1, 14, 365} {
		_, err := NewOverview(&fakeOverviewReader{}).Overview(context.Background(), days, false)
		if !errors.Is(err, dom.ErrInvalidRange) {
			t.Fatalf("days=%d error=%v want invalid range", days, err)
		}
	}
}
