package wukongwh

import (
	"context"
	"strconv"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/mobilepush"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
)

type NotificationEnqueuer interface {
	Enqueue(context.Context, dom.EnqueueInput) (bool, error)
}

// RecentReadChecker 判断某 account 是否刚标过某会话已读(within 时间窗口内)。
// 没有真正的多端 presence 机制,复用已有的"已读"上报当"正在看"的近似信号——
// 2026-08-10 用户反馈:PC/移动端任一端正在看着某会话时,不要给其它端也推通知。
type RecentReadChecker interface {
	IsRecentlyRead(ctx context.Context, tenantID, accountID int64, conversationUUID string, within time.Duration) (bool, error)
}

// recentReadWindow: markRead 距现在多久以内算"正在看"。跟 notificationDebounceWindow(3s)
// 配合——debounce 触发时才做这个判断(不是收到消息那一刻),给"新消息到达时活跃客户端
// 上报已读"留够时间窗口。信号本身是近似的:用户打开会话后一直不动、也没有新消息触发
// 重新上报已读,超过这个窗口就不再被当作"正在看",会退化成照常推送——这是复用已读信号
// 的固有局限,不是 bug。
const recentReadWindow = 10 * time.Second

type NotificationSink struct {
	recipients dom.RecipientResolver
	enqueue    NotificationEnqueuer
	debouncer  *notificationDebouncer
}

func NewNotificationSink(r dom.RecipientResolver, e NotificationEnqueuer, recentRead RecentReadChecker) *NotificationSink {
	gated := NotificationEnqueuer(e)
	if recentRead != nil {
		gated = recentReadGatedEnqueuer{inner: e, recentRead: recentRead, window: recentReadWindow}
	}
	return &NotificationSink{recipients: r, enqueue: e, debouncer: newNotificationDebouncer(gated, notificationDebounceWindow)}
}

// recentReadGatedEnqueuer 在真正 enqueue(debounce 定时器触发那一刻,不是收到消息那一刻)前
// 判断收件人是不是刚标过这个会话已读,是就悄悄丢弃(不 enqueue、不推送),不是错误。
// 只对 chat_message 生效——call_invite(来电必须提醒)/cron_result 不受影响。
type recentReadGatedEnqueuer struct {
	inner      NotificationEnqueuer
	recentRead RecentReadChecker
	window     time.Duration
}

func (g recentReadGatedEnqueuer) Enqueue(ctx context.Context, in dom.EnqueueInput) (bool, error) {
	if in.Kind == "chat_message" {
		convUUID, _ := in.RoutePayload["conversation_uuid"].(string)
		if convUUID != "" {
			recent, err := g.recentRead.IsRecentlyRead(ctx, in.TenantID, in.AccountID, convUUID, g.window)
			if err == nil && recent {
				return false, nil
			}
		}
	}
	return g.inner.Enqueue(ctx, in)
}
func (s *NotificationSink) OnMessage(ctx context.Context, ev Event) error {
	if ev.ContentType == WKRtcCallSignalContentType || ev.ContentType == WKReadReceiptChangedContentType || isCallEventOnlyMixed(ev.ContentType, ev.Blocks) {
		return nil
	}
	if s == nil || s.recipients == nil || s.enqueue == nil {
		return nil
	}
	rs, err := s.recipients.ResolveRecipients(ctx, ev.ChannelID, ev.FromUID)
	if err != nil {
		return err
	}
	body := "发来一条消息"
	if ev.ContentType == WKMixedContentType {
		body = "发来一条富媒体消息"
	}
	if text := strings.TrimSpace(ev.Text); text != "" {
		body = truncateSummary(text, notificationBodySummaryMaxRunes)
	} else if readable := strings.TrimSpace(messageblocks.ReadableText(ev.Blocks)); readable != "" {
		// ev.Text 只在纯文本消息(ContentType=1)非空;EMP 卡片/工具结果等富媒体消息
		// 靠 blocks 兜底摘要,跟会话列表 preview(internal/service/messages/inbox.go)
		// 口径一致,不再统一显示死文案"发来一条消息"——
		// 2026-08-08 用户反馈:通知标题/正文不该是死文案。
		// ReadableText 多个 block 用 \n 拼接,通知正文是单行展示,拍平成空格。
		body = truncateSummary(strings.Join(strings.Fields(readable), " "), notificationBodySummaryMaxRunes)
	}
	for _, r := range rs {
		// 标题统一取真实发送者名(人或数字员工，ResolveRecipients 已经把两种发送者都解析进
		// ConversationTitle)，不再对人/数字员工分别写死"新消息"/"知办AI"——
		// 2026-08-07 用户反馈：数字员工发来的通知标题不该是固定的"知办AI"，看不出是谁发的。
		title := "新消息"
		if r.ConversationTitle != "" {
			title = truncateNotificationTitle(r.ConversationTitle)
		}
		in := dom.EnqueueInput{TenantID: r.TenantID, AccountID: r.AccountID, Kind: "chat_message", DedupKey: "chat:" + ev.MessageID + ":" + strconv.FormatInt(r.AccountID, 10), Title: title, Body: body, RoutePayload: map[string]any{"kind": "chat_message", "conversation_uuid": r.ConversationUUID}}
		// 同一(tenant,account,conversation)在 notificationDebounceWindow 内的多条
		// chat_message 通知合并成一条(取最新内容),不再逐条即时 enqueue——见
		// notification_debounce.go 顶部注释(2026-08-10)。
		s.debouncer.schedule(ctx, debounceKey(r.TenantID, r.AccountID, r.ConversationUUID), in)
	}
	return nil
}

func debounceKey(tenantID, accountID int64, conversationUUID string) string {
	return strconv.FormatInt(tenantID, 10) + ":" + strconv.FormatInt(accountID, 10) + ":" + conversationUUID
}

// notificationBodySummaryMaxRunes 锁屏摘要最多带的正文字数(超过截断加省略号)。
const notificationBodySummaryMaxRunes = 40
const notificationTitleMaxRunes = 128

func truncateNotificationTitle(s string) string {
	r := []rune(s)
	if len(r) <= notificationTitleMaxRunes {
		return s
	}
	return string(r[:notificationTitleMaxRunes-1]) + "…"
}

func truncateSummary(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max]) + "…"
}
