import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/cron_message_metadata.dart';
import 'package:zhiban_client/pages/chat/widgets/cron_message_chip.dart';

class ChatSystemMessageView extends StatelessWidget {
  const ChatSystemMessageView({
    super.key,
    required this.item
  });

  final ChatSystemConversationItem item;

  @override
  Widget build(BuildContext context) {
    final cronMeta = CronMessageMetadata.tryParse(item.metadata);
    if (cronMeta != null) return _buildCronCard(cronMeta);

    final label =
        item.kind == ChatConversationItemKind.systemPrompt ? '系统提示' : '系统消息';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE4E7EC)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF667085),
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  item.content,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF344054),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// cron 定时任务卡片（2026-06-12 设计稿）：浅蓝底圆角卡撑满消息区，头部
  /// 「⏰ 定时任务 + 任务名标签 ……… 时间 + 已推送」，分隔线下正文为任务提示词。
  Widget _buildCronCard(CronMessageMetadata meta) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: SizedBox(
        key: const ValueKey('cron-message-card'),
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF1F6FF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFCFE0FA)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                  child: CronMessageChip(
                    meta: meta,
                    timeText: _formatTime(item.createdAt),
                  ),
                ),
                Container(height: 1, color: const Color(0xFFD7E4F7)),
                // 正文与头部共用整卡浅蓝底（设计稿）；不再单独铺白色。
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 13),
                  child: SelectableText(
                    item.content,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: Color(0xFF1D2129),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 本地 HH:mm；无时间返回空串（头部不显示时间）。
  static String _formatTime(DateTime? at) {
    if (at == null) return '';
    final dt = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }
}
