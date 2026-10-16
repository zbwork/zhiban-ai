import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:zhiban_core/im/im_client.dart';

/// 发送态最小指示器(WuKongIM reliability P0 的 UI 最小闭环)。
///
/// 只对**自己发出**的消息显示:
/// - [ImSendStatus.pending] → 极小的发送中转圈;
/// - [ImSendStatus.failed]  → 红色感叹号 + tooltip(失败原因,空则「发送失败」);
/// - [ImSendStatus.sent]    → 不显示任何额外状态(保持现状)。
///
/// 对端消息([isPeer] = true)恒不显示。组件自带右间距与垂直微调,
/// 放进气泡 Row 时直接前置即可,sent/对端时收缩为 0 不占位,不影响既有气泡视觉。
///
/// [onRetry] 非空且为 failed 时,红色失败标识可点击触发重发(P1,仅文本由调用方保证);
/// tooltip 仍展示错误。pending/sent/对端无点击。
class ChatSendStatusIndicator extends StatelessWidget {
  const ChatSendStatusIndicator({
    super.key,
    required this.isPeer,
    required this.status,
    required this.errorMessage,
    this.onRetry,
  });

  final bool isPeer;
  final ImSendStatus status;
  final String errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // 不改变对端消息展示;sent 不显示额外状态。
    if (isPeer || status == ImSendStatus.sent) {
      return const SizedBox.shrink();
    }

    final Widget icon;
    switch (status) {
      case ImSendStatus.pending:
        icon = const SizedBox(
          width: 14,
          height: 14,
          child: CupertinoActivityIndicator(radius: 7),
        );
      case ImSendStatus.failed:
        Widget failedIcon = const Icon(
          CupertinoIcons.exclamationmark_circle_fill,
          size: 16,
          color: Color(0xFFF53F3F),
        );
        // failed 且提供 onRetry → 点击重发(样式不变,仅加可点区域)。
        if (onRetry != null) {
          failedIcon = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRetry,
            child: failedIcon,
          );
        }
        icon = Tooltip(
          message: errorMessage.isNotEmpty ? errorMessage : '发送失败',
          child: failedIcon,
        );
      case ImSendStatus.sent:
        return const SizedBox.shrink();
    }

    // 放在自己气泡左侧、与首行文本大致对齐;自带右间距。
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 6),
      child: icon,
    );
  }
}
