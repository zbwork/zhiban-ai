import 'package:flutter/cupertino.dart';
import 'package:zhiban_core/chat/chat_reply_reference.dart';

/// F09 引用回复 v1: composer 上方的「引用预览条」.
///
/// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.
///
/// 视觉: 浅灰底 / 6px 圆角 / 左侧细线 + 摘要 / 右侧关闭 icon.
/// 不改输入框样式; 高度 ~36px.
class ChatReplyPreviewBar extends StatelessWidget {
  const ChatReplyPreviewBar({
    super.key,
    required this.reference,
    required this.onCancel,
  });

  final ChatReplyReference reference;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F5F8),
        borderRadius: BorderRadius.circular(6),
        border: const Border(
          left: BorderSide(color: Color(0xFFC0CDDB), width: 2),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '回复 ${reference.senderName.isEmpty ? "对方" : reference.senderName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF86909C),
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reference.summary.isEmpty ? '原消息不可用' : reference.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF4E5969),
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCancel,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(CupertinoIcons.xmark,
                  size: 14, color: Color(0xFF86909C)),
            ),
          ),
        ],
      ),
    );
  }
}

/// F09 引用回复 v1: 气泡内引用块. 显示在正文上方.
///
/// 视觉: 浅灰底 / 左侧 2px 细线 / 「发送人 + 摘要」12px.
/// 点击 → [onTap] (调用方负责定位 + 高亮; 见 pane).
/// 撤回 / 不可用 → 摘要走「原消息不可用」灰色 italic.
class ChatBubbleReplyBlock extends StatelessWidget {
  const ChatBubbleReplyBlock({
    super.key,
    required this.reference,
    this.onTap,
    this.maxWidth = 460,
  });

  final ChatReplyReference reference;
  final VoidCallback? onTap;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final unavailable = reference.isUnavailable ||
        reference.summary == '原消息不可用' ||
        reference.summary.isEmpty;
    final summary = unavailable ? '原消息不可用' : reference.summary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: unavailable ? null : onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F5F8),
            borderRadius: BorderRadius.circular(6),
            border: const Border(
              left: BorderSide(color: Color(0xFFC0CDDB), width: 2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reference.senderName.isNotEmpty)
                Text(
                  reference.senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF86909C),
                    height: 1.1,
                  ),
                ),
              if (reference.senderName.isNotEmpty) const SizedBox(height: 2),
              Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: unavailable
                      ? const Color(0xFF98A2B3)
                      : const Color(0xFF4E5969),
                  fontStyle: unavailable ? FontStyle.italic : FontStyle.normal,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
