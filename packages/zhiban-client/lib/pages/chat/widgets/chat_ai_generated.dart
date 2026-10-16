import 'package:zhiban_core/im/im_client.dart';
import 'chat_mixed_message_bubble.dart';

/// Keep historical employee replies identifiable after membership disappears.
bool isAiGeneratedImContent(ImMessage message, {String? senderKind}) {
  if (message.isRevoked || isCallEventLikeMessage(message)) return false;
  // WuKong failed payloads contain only the Bus safe error notice, not
  // retained model output (unlike single-chat failed messages).
  if (message.agentMessageStatus == 'failed') return false;
  if (message.agentMessageStatus.isNotEmpty &&
      !const {'final', 'completed', 'awaiting_user', 'cancelled'}
          .contains(message.agentMessageStatus)) {
    return false;
  }
  final isAgent = senderKind == 'agent' ||
      (senderKind == null &&
          RegExp(r'^t_[^_]+_a_.+$').hasMatch(message.fromUid));
  return isAgent &&
      (message.text.trim().isNotEmpty ||
          message.empBlocks.isNotEmpty ||
          message.blocks.isNotEmpty ||
          message.mediaUrl.isNotEmpty);
}
