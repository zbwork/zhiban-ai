import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart'
    show EmpBlocksRespondHandler;
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'chat_assistant_message_view.dart';
import 'message_bubble/message_bubble.dart';
import 'package:flutter/material.dart';

class ChatConversationPairView extends StatelessWidget {
  const ChatConversationPairView({
    super.key,
    required this.item,
    this.maxWidth,
    this.onOpenAttachment,
    this.onStop,
    this.userAvatarUrl,
    this.agentAvatarUrl,
    this.conversationUuid,
    this.respondHandler,
    this.skillIconUrls = const {},
  });

  final ChatPairConversationItem item;
  final double? maxWidth;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  /// assistant bubble loading 时状态条上的"停止"按钮回调，
  /// 由 [ChatMessageList] 透传自 [ChatSessionView.onStop]。
  final VoidCallback? onStop;

  /// 用户/智能体头像 URL，分别用于右侧/左侧头像。
  final String? userAvatarUrl;
  final String? agentAvatarUrl;

  /// ADR-0028 — HITL 上下文 (conversation uuid + 提交回调)。
  final String? conversationUuid;
  final EmpBlocksRespondHandler? respondHandler;
  final Map<String, String> skillIconUrls;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (item.userMessage != null)
          MessageBubble(
            item: item.userMessage!,
            maxWidth: maxWidth,
            onOpenAttachment: onOpenAttachment,
            avatarUrl: userAvatarUrl,
            skillIconUrls: skillIconUrls,
          ),
        if (item.assistantMessage != null)
          ChatAssistantMessageView(
            item: item.assistantMessage!,
            maxWidth: maxWidth,
            onOpenAttachment: onOpenAttachment,
            onStop: onStop,
            avatarUrl: agentAvatarUrl,
            conversationUuid: conversationUuid,
            respondHandler: respondHandler,
          ),
      ],
    );
  }
}
