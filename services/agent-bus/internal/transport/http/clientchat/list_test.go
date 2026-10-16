package clientchat

import (
	"testing"
	"time"

	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
)

// 回归:会话列表 last_message 与 last_message_at 必须同源。
// 之前 transport 只用 WuKong/本地文本回填 last_message,last_message_at 仍硬编码
// PG it.LastMessageAt,导致"摘要是最新消息、时间却是旧值"。

func mkPGAt(t *testing.T) *time.Time {
	t.Helper()
	v := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC) // 明显的旧 PG 值
	return &v
}

// a. WuKong 命中且有文本 → last_message 文本来自 WuKong,last_message_at 用 cs.LastTS,
//
//	而不是 PG it.LastMessageAt。
func TestResolveListLastMessage_WuKongHit_UsesWuKongTextAndTS(t *testing.T) {
	pgAt := mkPGAt(t)
	localTS := time.Date(2021, 5, 5, 5, 5, 5, 0, time.UTC)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt
	it.LastMessageText = "local fallback"
	it.LastMessageTS = &localTS

	const wkUnix int64 = 1700000000
	cs := wukong.ConvSyncItem{LastText: "hi from wukong", LastFromUID: "u1", LastTS: wkUnix}

	lm, at := resolveListLastMessage(it, cs, true)

	m, ok := lm.(map[string]any)
	if !ok {
		t.Fatalf("lastMessage not a map: %T", lm)
	}
	if m["text"] != "hi from wukong" {
		t.Errorf("text = %v, want WuKong text", m["text"])
	}
	if at == nil {
		t.Fatal("lastMessageAt nil, want WuKong ts")
	}
	want := time.Unix(wkUnix, 0).UTC()
	if !at.Equal(want) {
		t.Errorf("lastMessageAt = %v, want %v (WuKong ts)", at, want)
	}
	if at.Equal(*pgAt) {
		t.Error("lastMessageAt must NOT be PG it.LastMessageAt when WuKong hit")
	}
	if at.Equal(localTS) {
		t.Error("lastMessageAt must be WuKong ts, not local message ts, when WuKong hit")
	}
}

// b1. WuKong 不可用/未命中(wkHit=false)但本地有文本 → last_message_at 用 it.LastMessageTS。
func TestResolveListLastMessage_WuKongMiss_UsesLocalTS(t *testing.T) {
	pgAt := mkPGAt(t)
	localTS := time.Date(2022, 6, 6, 6, 6, 6, 0, time.UTC)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt
	it.LastMessageText = "local only"
	it.LastMessageTS = &localTS

	lm, at := resolveListLastMessage(it, wukong.ConvSyncItem{}, false)

	m, ok := lm.(map[string]any)
	if !ok {
		t.Fatalf("lastMessage not a map: %T", lm)
	}
	if m["text"] != "local only" {
		t.Errorf("text = %v, want local text", m["text"])
	}
	if at == nil || !at.Equal(localTS) {
		t.Errorf("lastMessageAt = %v, want local ts %v", at, localTS)
	}
}

// b2. 边界修复:WuKong 命中、无文本(cs.LastText 空)、cs.LastTS>0,且 PG 还存着更旧的
//
//	it.LastMessageText / it.LastMessageTS —— last_message **不得**退回 PG 旧文本(保持 nil),
//	last_message_at 用 WuKong 的 cs.LastTS。与 unread(cs.Unread)同源,杜绝"新未读 + 旧摘要"错配。
func TestResolveListLastMessage_WuKongHitNoText_DoesNotFallBackToPG(t *testing.T) {
	pgAt := mkPGAt(t)
	oldLocalTS := time.Date(2023, 7, 7, 7, 7, 7, 0, time.UTC)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt
	it.LastMessageText = "PG 旧消息"
	it.LastMessageTS = &oldLocalTS

	const wkUnix int64 = 1700000123
	// 命中但 LastText 空(图片/非文本/解析失败);unread 仍由调用方取 cs.Unread。
	cs := wukong.ConvSyncItem{LastText: "", Unread: 9, LastTS: wkUnix}

	lm, at := resolveListLastMessage(it, cs, true)

	if lm != nil {
		t.Errorf("lastMessage = %v, want nil(不得退回 PG 旧文本)", lm)
	}
	if at == nil {
		t.Fatal("lastMessageAt nil, want WuKong ts")
	}
	want := time.Unix(wkUnix, 0).UTC()
	if !at.Equal(want) {
		t.Errorf("lastMessageAt = %v, want WuKong ts %v", at, want)
	}
	if at.Equal(*pgAt) || at.Equal(oldLocalTS) {
		t.Error("lastMessageAt 必须是 WuKong ts,不能是 PG/本地旧时间")
	}
}

// b3. 边界:WuKong 命中、无文本、且无可用 ts(cs.LastTS<=0)→ last_message 仍保持 nil
//
//	(不退回 PG 旧文本),last_message_at 兜底回 PG it.LastMessageAt。
func TestResolveListLastMessage_WuKongHitNoTextNoTS_KeepsPGAt(t *testing.T) {
	pgAt := mkPGAt(t)
	oldLocalTS := time.Date(2023, 7, 7, 7, 7, 7, 0, time.UTC)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt
	it.LastMessageText = "PG 旧消息"
	it.LastMessageTS = &oldLocalTS

	cs := wukong.ConvSyncItem{LastText: "", Unread: 4, LastTS: 0}

	lm, at := resolveListLastMessage(it, cs, true)

	if lm != nil {
		t.Errorf("lastMessage = %v, want nil(不得退回 PG 旧文本)", lm)
	}
	if at == nil || !at.Equal(*pgAt) {
		t.Errorf("lastMessageAt = %v, want PG %v(WuKong 无文本无 ts)", at, pgAt)
	}
}

func TestResolveListUnreadCount_LastReadCoversLastMessage_ReturnsZero(t *testing.T) {
	lastAt := time.Date(2026, 6, 4, 10, 0, 0, 0, time.UTC)
	readAt := lastAt.Add(time.Minute)
	it := domconv.ListItem{LastReadAt: &readAt}
	cs := wukong.ConvSyncItem{Unread: 4}

	if got := resolveListUnreadCount(it, cs, true, &lastAt, nil); got != 0 {
		t.Fatalf("unread = %d, want 0 when last_read_at covers last_message_at", got)
	}
}

func TestResolveListUnreadCount_NewMessageAfterLastRead_KeepsWuKongUnread(t *testing.T) {
	readAt := time.Date(2026, 6, 4, 10, 0, 0, 0, time.UTC)
	lastAt := readAt.Add(time.Minute)
	it := domconv.ListItem{LastReadAt: &readAt}
	cs := wukong.ConvSyncItem{Unread: 2}

	if got := resolveListUnreadCount(it, cs, true, &lastAt, nil); got != 2 {
		t.Fatalf("unread = %d, want WuKong unread for messages after last_read_at", got)
	}
}

func TestResolveListUnreadCount_WuKongMiss_UsesPGButStillHonorsLastRead(t *testing.T) {
	lastAt := time.Date(2026, 6, 4, 10, 0, 0, 0, time.UTC)
	readAt := lastAt
	it := domconv.ListItem{Conversation: domconv.Conversation{UnreadCount: 3}, LastReadAt: &readAt}

	if got := resolveListUnreadCount(it, wukong.ConvSyncItem{}, false, &lastAt, nil); got != 0 {
		t.Fatalf("unread = %d, want 0 when local unread is covered by last_read_at", got)
	}
}

func TestResolveListUnreadCount_RecountAfterReadOverridesHistoricalAccumulation(t *testing.T) {
	readAt := time.Date(2026, 6, 4, 20, 47, 0, 0, time.UTC)
	lastAt := readAt.Add(30 * time.Second)
	it := domconv.ListItem{Conversation: domconv.Conversation{UnreadCount: 0}, LastReadAt: &readAt}
	cs := wukong.ConvSyncItem{Unread: 6}
	recounted := 1
	if got := resolveListUnreadCount(it, cs, true, &lastAt, &recounted); got != 1 {
		t.Fatalf("unread = %d, want recounted unread 1 instead of historical WuKong unread 6", got)
	}
}

func TestResolveListUnreadCount_WuKongHitKeepsAccountUnreadSnapshot(t *testing.T) {
	lastAt := time.Date(2026, 7, 3, 18, 0, 0, 0, time.UTC)
	it := domconv.ListItem{UnreadSnapshot: 1}
	cs := wukong.ConvSyncItem{Unread: 0}

	if got := resolveListUnreadCount(it, cs, true, &lastAt, nil); got != 1 {
		t.Fatalf("unread = %d, want account unread_snapshot when WuKong unread is zero", got)
	}
}

func TestResolveListUnreadCount_LastReadClearsAccountUnreadSnapshot(t *testing.T) {
	lastAt := time.Date(2026, 7, 3, 18, 0, 0, 0, time.UTC)
	readAt := lastAt.Add(time.Second)
	it := domconv.ListItem{UnreadSnapshot: 1, LastReadAt: &readAt}
	cs := wukong.ConvSyncItem{Unread: 0}

	if got := resolveListUnreadCount(it, cs, true, &lastAt, nil); got != 0 {
		t.Fatalf("unread = %d, want 0 when last_read_at covers account unread_snapshot", got)
	}
}

func TestConvListSortAt_EmptyConversationUsesCreatedAt(t *testing.T) {
	createdAt := time.Date(2026, 7, 8, 10, 0, 0, 0, time.UTC)
	msgAt := createdAt.Add(time.Minute)
	it := domconv.ListItem{
		Conversation: domconv.Conversation{CreatedAt: createdAt},
	}

	if got := convListSortAt(it, nil); got == nil || !got.Equal(createdAt) {
		t.Fatalf("sortAt nil-message = %v, want created_at %v", got, createdAt)
	}
	if got := convListSortAt(it, &msgAt); got == nil || !got.Equal(msgAt) {
		t.Fatalf("sortAt with message = %v, want last_message_at %v", got, msgAt)
	}
}

func TestUnreadRecountLimit(t *testing.T) {
	for _, tc := range []struct {
		in   int
		want int
	}{
		{1, 20},
		{20, 20},
		{60, 60},
		{101, 100},
	} {
		if got := unreadRecountLimit(tc.in); got != tc.want {
			t.Fatalf("unreadRecountLimit(%d)=%d, want %d", tc.in, got, tc.want)
		}
	}
}

// P1 排序:列表按最终展示 last_message_at 降序稳定排序。
func TestSortConvListByLastMessageAt(t *testing.T) {
	tNewer := time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC)
	tMid := time.Date(2022, 1, 1, 0, 0, 0, 0, time.UTC)
	tOlder := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

	idOf := func(rows []convListRow) []string {
		out := make([]string, len(rows))
		for i, rr := range rows {
			out[i], _ = rr.row["uuid"].(string)
		}
		return out
	}

	// 1) PG 顺序旧(B 在前), 但 WuKong A 的 last ts 比 B 新 → A 应排前。
	t.Run("WuKong newer reorders ahead of PG order", func(t *testing.T) {
		rows := []convListRow{
			{row: map[string]any{"uuid": "B"}, at: &tMid},   // PG 排在前(旧序)
			{row: map[string]any{"uuid": "A"}, at: &tNewer}, // WuKong 命中更新
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "A" || got[1] != "B" {
			t.Fatalf("order = %v, want [A B]", got)
		}
	})

	// 2) 都用 PG fallback(WuKong miss)→ 按各自 at 降序。
	t.Run("WuKong miss uses PG fallback order", func(t *testing.T) {
		rows := []convListRow{
			{row: map[string]any{"uuid": "old"}, at: &tOlder},
			{row: map[string]any{"uuid": "new"}, at: &tNewer},
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "new" || got[1] != "old" {
			t.Fatalf("order = %v, want [new old]", got)
		}
	})

	// 3) at 为 nil(防御性边界)→ 排最后;有 ts 的按降序在前。
	t.Run("nil activity time sorts last defensively", func(t *testing.T) {
		rows := []convListRow{
			{row: map[string]any{"uuid": "mid"}, at: &tMid},
			{row: map[string]any{"uuid": "none"}, at: nil},
			{row: map[string]any{"uuid": "new"}, at: &tNewer},
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "new" || got[1] != "mid" || got[2] != "none" {
			t.Fatalf("order = %v, want [new mid none]", got)
		}
	})

	// 4) 空的新会话使用 created_at 作为活动时间,应排在旧消息会话前。
	t.Run("new empty conversation sorts by created_at", func(t *testing.T) {
		emptyCreated := time.Date(2026, 7, 8, 10, 0, 0, 0, time.UTC)
		oldMessageAt := time.Date(2026, 6, 23, 10, 0, 0, 0, time.UTC)
		rows := []convListRow{
			{
				row: map[string]any{"uuid": "old-with-message"},
				at:  &oldMessageAt,
			},
			{
				row: map[string]any{"uuid": "new-empty-group"},
				at:  convListSortAt(domconv.ListItem{Conversation: domconv.Conversation{CreatedAt: emptyCreated}}, nil),
			},
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "new-empty-group" || got[1] != "old-with-message" {
			t.Fatalf("order = %v, want [new-empty-group old-with-message]", got)
		}
	})

	// 5) 时间相等 → 稳定排序保持原始(PG)顺序作 tie-break。
	t.Run("equal ts keeps stable PG order", func(t *testing.T) {
		eq := tMid
		rows := []convListRow{
			{row: map[string]any{"uuid": "P"}, at: &eq},
			{row: map[string]any{"uuid": "Q"}, at: &eq},
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "P" || got[1] != "Q" {
			t.Fatalf("order = %v, want [P Q] (stable)", got)
		}
	})

	// 6) F09 P2 v2: pinnedAt 非空整体在前(不论活动时间早晚)。
	t.Run("pinned conversations sort before unpinned regardless of last_message_at", func(t *testing.T) {
		pinAt := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
		rows := []convListRow{
			// X: 普通行, 最新消息时间 newer
			{row: map[string]any{"uuid": "X"}, at: &tNewer},
			// P: 置顶, 但消息时间很旧
			{row: map[string]any{"uuid": "P"}, at: &tOlder, pinnedAt: &pinAt},
		}
		sortConvListByLastMessageAt(rows)
		if got := idOf(rows); got[0] != "P" || got[1] != "X" {
			t.Fatalf("order = %v, want [P X] (pinned 优先, 不论 last_message_at)", got)
		}
	})

	// 7) F09 P2 v2 (CR2 校准): pinned 组内**按活动时间降序**, pinnedAt 不参与组内排序;
	//    普通行同样按活动时间降序。
	t.Run("pinned group sorted by last_message_at (not pinned_at)", func(t *testing.T) {
		pinOld := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
		pinNew := time.Date(2024, 6, 1, 0, 0, 0, 0, time.UTC)
		rows := []convListRow{
			{row: map[string]any{"uuid": "A"}, at: &tOlder},
			// P1 置顶早, 但 last_message_at 更新.
			{row: map[string]any{"uuid": "P1"}, at: &tNewer, pinnedAt: &pinOld},
			{row: map[string]any{"uuid": "B"}, at: &tNewer},
			// P2 置顶晚, 但 last_message_at 较旧.
			{row: map[string]any{"uuid": "P2"}, at: &tOlder, pinnedAt: &pinNew},
		}
		sortConvListByLastMessageAt(rows)
		// pinned 组先 (P1, P2): P1.at=tNewer > P2.at=tOlder → P1 在前 (按 last_message_at).
		// 普通组后 (A, B): B.at=tNewer > A.at=tOlder → B 在前.
		want := []string{"P1", "P2", "B", "A"}
		if got := idOf(rows); !sliceEqual(got, want) {
			t.Fatalf("order = %v, want %v (pinned 组应按 last_message_at, 不是 pinned_at)", got, want)
		}
	})

	// 8) CR2: pinned 行活动时间 nil 时排在 pinned 组最后, 但仍优先于所有 unpinned 行.
	t.Run("pinned with nil activity time sorts last within pinned group", func(t *testing.T) {
		pinAt := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
		rows := []convListRow{
			{row: map[string]any{"uuid": "U"}, at: &tNewer}, // unpinned newer
			{row: map[string]any{"uuid": "PnoMsg"}, at: nil, pinnedAt: &pinAt},
			{row: map[string]any{"uuid": "P"}, at: &tOlder, pinnedAt: &pinAt},
		}
		sortConvListByLastMessageAt(rows)
		want := []string{"P", "PnoMsg", "U"}
		if got := idOf(rows); !sliceEqual(got, want) {
			t.Fatalf("order = %v, want %v", got, want)
		}
	})
}

func sliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// P1 修复:全量候选「先排序再分页」才能让 WuKong 最新会话进首页;
// 「先分页(SQL PG 序)再排序」会把 PG 旧时间的最新会话挡在首页之外。
func TestSortThenPaginate_AvoidsCrossPageMiss(t *testing.T) {
	tNewWK := time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC) // A: WuKong 刚来最新消息
	tMidPG := time.Date(2022, 1, 1, 0, 0, 0, 0, time.UTC) // B: PG 较新

	idOf := func(rows []convListRow) []string {
		out := make([]string, len(rows))
		for i, rr := range rows {
			out[i], _ = rr.row["uuid"].(string)
		}
		return out
	}

	// 全量候选,按 SQL 的 PG 顺序到达:B(PG 较新)在前,A(PG 旧)在后。
	candidatesInPGOrder := func() []convListRow {
		return []convListRow{
			{row: map[string]any{"uuid": "B"}, at: &tMidPG},
			{row: map[string]any{"uuid": "A"}, at: &tNewWK}, // A 的最终时间(WuKong)最新
		}
	}

	// 正确路径:先按最终 last_message_at 排序,再分页 → 首页 limit=1 应是 A。
	t.Run("sort then paginate → newest WuKong conv in first page", func(t *testing.T) {
		rows := candidatesInPGOrder()
		sortConvListByLastMessageAt(rows)
		page := paginateConvRows(rows, 0, 1)
		if got := idOf(page); len(got) != 1 || got[0] != "A" {
			t.Fatalf("first page = %v, want [A] (WuKong 最新会话进首页)", got)
		}
	})

	// 反例(旧 bug):先 SQL 分页(PG 序)再排序 → 首页只有 B,A 被挡在页外。
	t.Run("paginate then sort → misses A (demonstrates old bug)", func(t *testing.T) {
		rows := candidatesInPGOrder()
		page := paginateConvRows(rows, 0, 1) // 先分页:PG 序首页 = B
		sortConvListByLastMessageAt(page)    // 页内再排序也救不回 A
		if got := idOf(page); len(got) != 1 || got[0] != "B" {
			t.Fatalf("buggy first page = %v, want [B](证明先分页再排序会漏 A)", got)
		}
	})

	// 第 2 页(offset=1)拿到被挤下去的 B。
	t.Run("second page returns B", func(t *testing.T) {
		rows := candidatesInPGOrder()
		sortConvListByLastMessageAt(rows)
		page := paginateConvRows(rows, 1, 1)
		if got := idOf(page); len(got) != 1 || got[0] != "B" {
			t.Fatalf("second page = %v, want [B]", got)
		}
	})
}

// paginateConvRows 边界:limit 语义对齐 repo(<=0/>200 → 20),offset 越界返回空。
func TestPaginateConvRows_Bounds(t *testing.T) {
	mk := func(n int) []convListRow {
		out := make([]convListRow, n)
		for i := range out {
			out[i] = convListRow{row: map[string]any{"i": i}}
		}
		return out
	}
	if got := paginateConvRows(mk(5), 10, 2); got != nil {
		t.Fatalf("offset 越界应返回 nil, got len=%d", len(got))
	}
	if got := paginateConvRows(mk(3), 0, 10); len(got) != 3 {
		t.Fatalf("end clamp 到 len, got len=%d want 3", len(got))
	}
	if got := paginateConvRows(mk(50), 0, 0); len(got) != 20 {
		t.Fatalf("limit<=0 → 20, got len=%d", len(got))
	}
}

// c. WuKong 与本地都没有文本 → last_message 为 nil,last_message_at 保留 PG it.LastMessageAt。
func TestResolveListLastMessage_NoSource_KeepsPGLastMessageAt(t *testing.T) {
	pgAt := mkPGAt(t)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt
	it.LastMessageText = ""
	it.LastMessageTS = nil

	lm, at := resolveListLastMessage(it, wukong.ConvSyncItem{}, false)

	if lm != nil {
		t.Errorf("lastMessage = %v, want nil", lm)
	}
	if at == nil || !at.Equal(*pgAt) {
		t.Errorf("lastMessageAt = %v, want PG %v", at, pgAt)
	}
}

// 边界:WuKong 命中有文本但 cs.LastTS<=0 → 文本用 WuKong,时间无可用 WuKong ts 时保留 PG。
func TestResolveListLastMessage_WuKongHitZeroTS_KeepsPG(t *testing.T) {
	pgAt := mkPGAt(t)

	it := domconv.ListItem{}
	it.LastMessageAt = pgAt

	cs := wukong.ConvSyncItem{LastText: "no ts", LastTS: 0}
	lm, at := resolveListLastMessage(it, cs, true)

	m, ok := lm.(map[string]any)
	if !ok {
		t.Fatalf("lastMessage not a map: %T", lm)
	}
	if m["text"] != "no ts" {
		t.Errorf("text = %v, want WuKong text", m["text"])
	}
	if at == nil || !at.Equal(*pgAt) {
		t.Errorf("lastMessageAt = %v, want PG %v when WuKong ts<=0", at, pgAt)
	}
}
