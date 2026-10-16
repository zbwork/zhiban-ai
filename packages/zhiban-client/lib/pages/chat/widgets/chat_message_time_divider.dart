import 'package:flutter/cupertino.dart';

/// 消息时间展示(P2,仅客户端)。人↔人与群聊 pane 共用本组件 + 同一纯函数格式化。
///
/// 只在消息**之间**插入小号灰色时间分隔(不在气泡内塞时间、不改气泡/输入框/布局骨架)。

/// 相邻两条消息是否需要在 [timestampMs] 这条**之前**插入时间分隔。
/// - 第一条([prevTimestampMs] == null)→ 显示;
/// - 间隔 ≥ 5min → 显示;
/// - `timestampMs <= 0`(无有效时间)→ 不显示(避免崩 / 错误时间)。
/// 单位归一见 [_normalizeToMillis]。
bool shouldShowTimeDivider({int? prevTimestampMs, required int timestampMs}) {
  final cur = _normalizeToMillis(timestampMs);
  if (cur <= 0) return false;
  if (prevTimestampMs == null) return true;
  final prev = _normalizeToMillis(prevTimestampMs);
  if (prev <= 0) return true; // 上一条无有效时间 → 本条作为新组首条显示
  return (cur - prev) >= _gapMillis;
}

const int _gapMillis = 5 * 60 * 1000; // 5 分钟

/// 把 `ImMessage.timestamp` 归一到**毫秒**。当前混用:SDK 消息为秒、本地占位为毫秒,
/// 复用既有 `>1e12 毫秒 / >1e9 秒` 量级判定(与 chat_providers `_resolveOccurredAtIso` 一致)。
int _normalizeToMillis(int ts) {
  if (ts <= 0) return 0;
  if (ts > 1000000000000) return ts; // 已是毫秒
  if (ts > 1000000000) return ts * 1000; // 秒 → 毫秒
  return ts; // 兜底:很小的值原样(测试可注入小毫秒)
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// 中文 IM 常见的会话内时间文案。[now] 作纯函数参数(不写死日期,便于测试)。
/// `timestampMs <= 0` → 空串(调用方据此不显示)。
/// - 当天:`HH:mm`
/// - 昨天:`昨天 HH:mm`
/// - 当年非昨天:`MM月dd日 HH:mm`
/// - 跨年:`yyyy年MM月dd日 HH:mm`
String formatMessageTime(int timestampMs, {required DateTime now}) {
  final ms = _normalizeToMillis(timestampMs);
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final hm = '${_two(t.hour)}:${_two(t.minute)}';

  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(t.year, t.month, t.day);
  final diffDays = today.difference(thatDay).inDays;

  if (diffDays == 0 && t.year == now.year) {
    return hm; // 当天
  }
  if (diffDays == 1) {
    return '昨天 $hm'; // 昨天
  }
  if (t.year == now.year) {
    return '${_two(t.month)}月${_two(t.day)}日 $hm'; // 当年非昨天
  }
  return '${t.year}年${_two(t.month)}月${_two(t.day)}日 $hm'; // 跨年
}

/// 消息之间的小号灰色时间分隔行(居中)。
class ChatMessageTimeDivider extends StatelessWidget {
  const ChatMessageTimeDivider({
    super.key,
    required this.timestampMs,
    this.now,
  });

  final int timestampMs;

  /// 测试可注入;生产用 `DateTime.now()`。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final label = formatMessageTime(timestampMs, now: now ?? DateTime.now());
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0AA)),
        ),
      ),
    );
  }
}
