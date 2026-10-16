import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/im/human_chat_draft_guard.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';

bool _clearing = false;

Future<void> confirmClearCache(BuildContext context, WidgetRef ref) async {
  if (_clearing) return;
  _clearing = true;
  try {
    final confirmed = await showUiConfirmDialog(context,
        title: '清除缓存',
        description: '将清除当前账号、当前主体在本机的会话列表、聊天记录和回执缓存，'
            '并清理工作台缓存。不会删除服务器记录、切换环境或退出登录，联网后可重新同步。'
            '未发送成功的消息会保留。',
        confirmLabel: '清除',
        cancelLabel: '取消',
        danger: true,
        waitForRemoval: true);
    if (!confirmed || !context.mounted) return;
    final sessions = ref.read(chatProvider).value?.sessions.values;
    if (hasUncommittedHumanChatDrafts ||
        (sessions?.any((s) =>
                s.hasActiveRun ||
                !s.draft.isEmpty ||
                s.pendingFiles.isNotEmpty ||
                s.messages.any((m) =>
                    (m.role == ChatRole.question &&
                        m.status == BubbleStatus.error) ||
                    m.status == BubbleStatus.loading)) ??
            false)) {
      BotToast.showText(text: '请先处理聊天草稿、待发送消息或进行中的任务，再清除缓存');
      return;
    }
    final closeLoading = BotToast.showLoading();
    try {
      await const SessionService().clearCacheStorage();
      // The session reset intentionally unmounts the original settings page.
      BotToast.showText(text: '本地聊天缓存已清除');
    } catch (_) {
      BotToast.showText(text: '缓存未全部清除，请重试');
    } finally {
      closeLoading();
    }
  } finally {
    _clearing = false;
  }
}
