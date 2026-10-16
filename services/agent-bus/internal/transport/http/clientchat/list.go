package clientchat

import (
	"context"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"
)

type ConversationLister interface {
	ListConversations(context.Context, int64, int64, int, int, bool) ([]domconv.ListItem, int64, error)
}
type ListHandler struct {
	Chat           ConversationLister
	WuKongConvSync *wukong.ConversationSyncProxy
	WuKongMsgSync  *wukong.MessageSyncProxy
}

func resolveListLastMessage(it domconv.ListItem, cs wukong.ConvSyncItem, wkHit bool) (lastMessage any, lastMessageAt *time.Time) {
	lastMessageAt = it.LastMessageAt
	if wkHit {
		// WuKong 命中:摘要/时间与 unread 同源,不混入 PG 旧消息。
		if cs.LastText != "" {
			lastMessage = map[string]any{
				"text":     cs.LastText,
				"from_uid": cs.LastFromUID,
				"ts":       cs.LastTS,
			}
		}
		if cs.LastTS > 0 {
			t := time.Unix(cs.LastTS, 0).UTC()
			lastMessageAt = &t
		}
		return lastMessage, lastMessageAt
	}
	// 未命中 WuKong 才用本地 messages 兜底。
	if it.LastMessageText != "" {
		lastMessage = map[string]any{
			"text": it.LastMessageText,
			"ts":   it.LastMessageTS,
		}
		if it.LastMessageTS != nil {
			lastMessageAt = it.LastMessageTS
		}
	}
	return lastMessage, lastMessageAt
}

func resolveListUnreadCount(it domconv.ListItem, cs wukong.ConvSyncItem, wkHit bool, lastMessageAt *time.Time, recountedAfterRead *int) int {
	unread := it.UnreadCount
	if it.UnreadSnapshot > unread {
		unread = it.UnreadSnapshot
	}
	if wkHit {
		unread = cs.Unread
		if it.UnreadSnapshot > unread {
			unread = it.UnreadSnapshot
		}
	}
	if unread <= 0 {
		return 0
	}
	// WuKong Flutter SDK 的 updateRedDot 只清本地 SDK DB, 不回写服务端
	// /conversation/sync unread。Bus 已读接口会写 caller 的 last_read_at;
	// 若 last_read_at 已覆盖当前最终 last_message_at, 说明用户已经在最后
	// 一条消息之后打开过该会话,列表未读应归零。若之后又来了新消息
	// (last_message_at > last_read_at),仍保留 WuKong unread,不压掉真实新消息。
	if it.LastReadAt != nil && lastMessageAt != nil && !lastMessageAt.After(*it.LastReadAt) {
		return 0
	}
	if recountedAfterRead != nil {
		if *recountedAfterRead < 0 {
			return 0
		}
		if it.UnreadSnapshot > *recountedAfterRead {
			return it.UnreadSnapshot
		}
		return *recountedAfterRead
	}
	return unread
}

func suppressClearedListPreview(it domconv.ListItem, lastMessageAt *time.Time) bool {
	return it.ClearedAt != nil && lastMessageAt != nil && !lastMessageAt.After(*it.ClearedAt)
}

func unreadRecountLimit(unread int) int {
	if unread < 20 {
		return 20
	}
	if unread > 100 {
		return 100
	}
	return unread
}

// convListRow 是 listConvos 输出的一行 + 其列表活动时间(排序键)+ pinned_at(主排序键).
//
// pinnedAt: F09 P2 「会话列表操作菜单 v2」, per-account 置顶时间; pinnedAt!=nil 行整体排在普通行之前.
type convListRow struct {
	row      map[string]any
	at       *time.Time
	pinnedAt *time.Time
}

func convListSortAt(it domconv.ListItem, lastMessageAt *time.Time) *time.Time {
	if lastMessageAt != nil {
		return lastMessageAt
	}
	return &it.CreatedAt
}

// sortConvListByLastMessageAt 按 (pinnedAt 非空 优先) + (列表活动时间降序) **稳定**排序。
//
// 契约权威 (CR2 校准, 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」):
//   - pinnedAt!=nil 行整体在 pinnedAt=nil 行之前 (置顶组优先).
//   - **置顶组内仍按列表活动时间降序**(与普通组同一口径), pinnedAt 本身**不参与排序**.
//   - 列表活动时间 = 最终 last_message_at; 若会话从无消息(last_message_at=nil),回退 created_at。
//   - 时间相等 → 稳定排序保持原始(PG)顺序作 tie-break.
//
// 这样 WuKong 全量重排路径与 PG SQL 排序路径输出**位置一致**(SQL 同样用
// (cas.pinned_at IS NOT NULL) DESC, COALESCE(c.last_message_at, c.created_at) DESC).
func sortConvListByLastMessageAt(rows []convListRow) {
	sort.SliceStable(rows, func(i, j int) bool {
		ai, aj := rows[i].pinnedAt != nil, rows[j].pinnedAt != nil
		if ai != aj {
			return ai // pinned 在前
		}
		// 同 pinned 分组内 (都 pinned 或都 unpinned) 按 last_message_at 降序.
		a, b := rows[i].at, rows[j].at
		if a == nil {
			return false
		}
		if b == nil {
			return true
		}
		return a.After(*b)
	})
}

// paginateConvRows 在**全量排序后**的 rows 上按 offset/limit 内存分页。
// limit 语义对齐 repo(<=0 或 >200 → 20);offset 越界返回空。
// 必须在 sortConvListByLastMessageAt 之后调用 —— 「先排序再分页」才能让 WuKong 最新会话进首页;
// 「先分页(SQL)再排序」会把 PG 旧时间的最新会话挡在首页之外。
func paginateConvRows(rows []convListRow, offset, limit int) []convListRow {
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	if offset >= len(rows) {
		return nil
	}
	end := offset + limit
	if end > len(rows) {
		end = len(rows)
	}
	return rows[offset:end]
}

func (h *ListHandler) List(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	includeHidden := r.URL.Query().Get("include_hidden") == "1"
	// P2.1b(ADR-0026):用 WuKong 会话同步回填 last_message / unread_count(WuKong 为时间线真理)。
	// 服务端按**当前账号自己的 uid** 拉(不接受客户端任意 uid);失败则降级。
	// 安全:只回填出现在 participant-filtered 列表里的 room 的 wukong_channel_id,天然不越权。
	// **先做同步**以决定排序口径:WuKong 可用 → 全量候选按最终 last_message_at 排序后分页
	// (修「PG last_message_at 旧、但 WuKong 刚来最新消息」的会话被 SQL 分页挡在首页之外);
	// WuKong 不可用/失败 → 降级为 PG 排序分页(SQL ORDER BY COALESCE(last_message_at, created_at) + LIMIT/OFFSET)。
	var wkConv map[string]wukong.ConvSyncItem
	if h.WuKongConvSync != nil {
		if m, serr := h.WuKongConvSync.SyncForAccount(r.Context(), tid, accID); serr != nil {
			logpkg.Default().Warn(r.Context(), "wukong convsync failed; degrade last/unread + PG sort", "err", serr.Error())
		} else {
			wkConv = m
		}
	}
	sortGlobally := wkConv != nil

	// Round-7 P2-2: hidden 过滤 + CAS 字段下推到 chat.ListConversations (SQL LEFT JOIN)。
	// sortGlobally 时取**全量候选**(limit<0 = 不分页),排序后再内存分页;否则走 SQL 分页。
	// total 由独立 count(*) 计算, 与是否分页无关(语义不变)。注:当前 IM 会话规模可接受全量
	// 内存排序;后续可用物化 WuKong last ts / keyset 优化(不上 migration)。
	fetchLimit, fetchOffset := limit, offset
	if sortGlobally {
		fetchLimit, fetchOffset = -1, 0
	}
	items, total, err := h.Chat.ListConversations(r.Context(), accID, tid, fetchLimit, fetchOffset, includeHidden)
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	// P2 修 502/超时高发:未读重算之前是"每个符合条件的会话都同步打一次 WuKong"
	// 的串行循环——一个用户离线久了攒下几十个未读会话,几十次 x 单次最多 10s
	// (见 wukong.Client 的 http.Client{Timeout: 10s}) 的 WuKong 调用叠起来,
	// 轻松超过网关/客户端超时。先算好每一行需不需要重算+参数,再用有限并发
	// (goroutine 数固定上限,不是每行一个 goroutine)把这些 WuKong 调用摊平打,
	// 而不是一个接一个等。
	type rowPrep struct {
		item            domconv.ListItem
		wkHit           bool
		cs              wukong.ConvSyncItem
		lastMessage     any
		lastMessageAt   *time.Time
		clearedPreview  bool
		needsRecount    bool
		recountedUnread *int
	}
	preps := make([]rowPrep, len(items))
	for i, it := range items {
		var cs wukong.ConvSyncItem
		wkHit := false
		if wkConv != nil && it.WuKongChannelID != "" {
			if c, ok := wkConv[it.WuKongChannelID]; ok {
				cs = c
				wkHit = true
			}
		}
		// last_message 与 last_message_at 同源(见 resolveListLastMessage 注释)。
		lastMessage, lastMessageAt := resolveListLastMessage(it, cs, wkHit)
		clearedPreview := suppressClearedListPreview(it, lastMessageAt)
		if clearedPreview {
			lastMessage = nil
			lastMessageAt = nil
		}
		needsRecount := !clearedPreview && wkHit && cs.Unread > 0 && it.LastReadAt != nil && lastMessageAt != nil &&
			lastMessageAt.After(*it.LastReadAt) && h.WuKongMsgSync != nil &&
			it.WuKongChannelID != "" && it.WuKongChannelType > 0
		preps[i] = rowPrep{
			item: it, wkHit: wkHit, cs: cs, lastMessage: lastMessage,
			lastMessageAt: lastMessageAt, clearedPreview: clearedPreview, needsRecount: needsRecount,
		}
	}

	const recountConcurrency = 8
	sem := make(chan struct{}, recountConcurrency)
	var wg sync.WaitGroup
	for i := range preps {
		if !preps[i].needsRecount {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			it := preps[i].item
			cs := preps[i].cs
			count, ok, cerr := h.WuKongMsgSync.CountPeerMessagesAfterCached(
				r.Context(),
				tid,
				accID,
				it.WuKongChannelID,
				it.WuKongChannelType,
				cs.Recents,
				cs.RawRecentsCount,
				wukong.ConversationSyncMsgCount,
				*it.LastReadAt,
				unreadRecountLimit(cs.Unread),
			)
			if cerr != nil {
				logpkg.Default().Warn(r.Context(), "wukong unread recount failed; keep sync unread",
					"channel_id", it.WuKongChannelID, "err", cerr.Error())
			} else if ok {
				preps[i].recountedUnread = &count
			}
		}(i)
	}
	wg.Wait()

	rows := make([]convListRow, 0, len(items))
	for _, p := range preps {
		it := p.item
		wkHit := p.wkHit
		cs := p.cs
		lastMessage := p.lastMessage
		lastMessageAt := p.lastMessageAt
		clearedPreview := p.clearedPreview
		unread := resolveListUnreadCount(it, cs, wkHit, lastMessageAt, p.recountedUnread)
		if clearedPreview {
			unread = 0
		}
		row := map[string]any{
			"uuid":                   it.UUID,
			"tenant_id":              it.TenantID,
			"account_id":             it.AccountID,
			"digital_employee_id":    it.DigitalEmployeeID,
			"agent_id":               it.AgentUUID,
			"agent_uuid":             it.AgentUUID,
			"agent_name":             it.AgentName,
			"agent_avatar_url":       it.AgentAvatar,
			"agent_position_label":   it.AgentPosition,
			"agent_department_name":  it.AgentDepartment,
			"agent_deleted":          it.AgentDeleted,
			"room_id":                it.RoomID,
			"title":                  it.Title,
			"source":                 it.Source,
			"last_message_at":        lastMessageAt,
			"unread_count":           unread,
			"metadata":               it.Metadata,
			"created_at":             it.CreatedAt,
			"updated_at":             it.UpdatedAt,
			"hidden":                 it.Hidden,
			"cleared_at":             it.ClearedAt,
			"last_read_message_uuid": it.LastReadMessageUUID,
			"unread_snapshot":        it.UnreadSnapshot,
			// F09 P2 「会话列表操作菜单 v2」 per-account state:
			"pinned":        it.Pinned,
			"muted":         it.Muted,
			"marked_unread": it.MarkedUnread,
			// P2.1 统一会话索引字段:
			"kind":                it.Kind,
			"room_uuid":           it.RoomUUID,
			"can_rename_group":    it.CanRenameGroup,
			"wukong_channel_id":   it.WuKongChannelID,
			"wukong_channel_type": it.WuKongChannelType,
			"participants":        it.Participants,
			"avatar":              it.Avatar, // 会话展示头像(direct=对端;agent=agent)
			// P2.1b: WuKong 时间线回填(human_direct/agent_direct/group;拿不到为 null)。
			"last_message": lastMessage,
		}
		rows = append(rows, convListRow{row: row, at: convListSortAt(it, lastMessageAt), pinnedAt: it.PinnedAt})
	}
	// P1: WuKong 可用 → 全量候选按列表活动时间降序稳定排序后再内存分页
	// (修跨页漏最新会话);WuKong 不可用 → rows 已是 SQL 的 PG 排序 + SQL 分页结果,不再重排/切片。
	// 两路 participant/权限/unread/hidden/total 语义均不变。
	if sortGlobally {
		sortConvListByLastMessageAt(rows)
		rows = paginateConvRows(rows, offset, limit)
	}
	enriched := make([]map[string]any, len(rows))
	for i := range rows {
		enriched[i] = rows[i].row
	}
	encode.JSON(w, map[string]any{"items": enriched, "total": total})
}
