import 'package:flutter/cupertino.dart';

import 'package:zhiban_core/chat/cron_message_metadata.dart';

/// CronMessageChip · F08 §8.2 #11 · 定时任务卡片头部行（2026-06-12 按设计稿重排）。
///
/// 布局：⏰ 图标 + 「定时任务」 + 任务名小标签 + (右侧) 时间 + 投递状态。
///  - trigger        → 状态「已推送」绿色 ✓
///  - failureNotice  → 状态「执行失败」红色 ⚠
/// 卡片容器（浅色底）由调用方 ChatSystemMessageView 提供，本组件只负责头部行。
class CronMessageChip extends StatelessWidget {
  const CronMessageChip({
    super.key,
    required this.meta,
    this.timeText,
    this.onTap,
  });

  final CronMessageMetadata meta;

  /// 右侧时间（HH:mm）；空则不显示。
  final String? timeText;

  /// 可选: 点击头部跳转任务详情/run 详情 (调用方决定路由)。
  final VoidCallback? onTap;

  static const _blue = Color(0xFF1D63F2);
  static const _green = Color(0xFF12B76A);
  static const _red = Color(0xFFB42318);

  @override
  Widget build(BuildContext context) {
    final isFailure = meta.isFailureNotice;
    final jobName = meta.displayJobLabel;
    // 2026-06-12 run 终态语义: 状态与历史执行结果一致。
    //  - failureNotice 或 runStatus=failed → 执行失败 (红)
    //  - runStatus=running/queued → 执行中 (橙)
    //  - runStatus=cancelled → 已停止 (中性)
    //  - succeeded / 老消息 (无 runStatus) → 已推送 (绿)
    final rs = meta.runStatus;
    final bool statusFailed = isFailure || rs == 'failed';
    final bool statusCancelled = !statusFailed && rs == 'cancelled';
    final bool statusRunning =
        !statusFailed && (rs == 'running' || rs == 'queued');
    final Color statusColor = statusFailed
        ? _red
        : statusCancelled
            ? CupertinoColors.secondaryLabel.resolveFrom(context)
            : statusRunning
                ? const Color(0xFFE08A1F)
                : _green;
    final IconData statusIcon = statusFailed
        ? CupertinoIcons.exclamationmark_circle_fill
        : statusCancelled
            ? CupertinoIcons.stop_circle
            : statusRunning
                ? CupertinoIcons.clock_fill
                : CupertinoIcons.checkmark_circle_fill;
    final String statusLabel = statusFailed
        ? '执行失败'
        : statusCancelled
            ? '已停止'
            : statusRunning
                ? '执行中'
                : '已推送';

    // 左侧组（图标+标题+任务名胶囊）整体 Expanded，时间/状态留在外层行尾。
    // 不能让胶囊直接用 Flexible(flex:1) 和 Spacer 并列：两者平分剩余空间，
    // 胶囊用不完的配额会堆到行尾，导致「已推送」永远贴不到最右。
    final leading = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                isFailure ? const Color(0xFFFEE4E2) : const Color(0xFFE2EDFF),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            CupertinoIcons.alarm,
            size: 15,
            color: isFailure ? _red : _blue,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '定时任务',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isFailure ? _red : const Color(0xFF1D2129),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color:
                  isFailure ? const Color(0xFFFFF1F3) : const Color(0xFFE5EFFD),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              jobName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: const TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Color(0xFF667085),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: leading),
        const SizedBox(width: 12),
        if ((timeText ?? '').isNotEmpty) ...[
          Text(
            timeText!,
            style: const TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
          ),
          const SizedBox(width: 10),
        ],
        Icon(statusIcon, size: 13, color: statusColor),
        const SizedBox(width: 3),
        Text(
          statusLabel,
          style: TextStyle(fontSize: 12, color: statusColor)
        ),
      ],
    );

    if (onTap == null) {
      return KeyedSubtree(
        key: const ValueKey('cron-message-chip'),
        child: row
      );
    }
    return MouseRegion(
      key: const ValueKey('cron-message-chip'),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      ),
    );
  }
}
