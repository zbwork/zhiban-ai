import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/providers/task_provider.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';
import 'package:zhiban_client/routes/route_paths.dart';

Future<void> openTaskRunInChat(
    BuildContext context, WidgetRef ref, CronRunEntry entry,
    {required bool asPage}) async {
  try {
    // 优先走"已落库的主会话 + cron 消息 uuid"快路径：cron-done webhook 已经
    // 把执行结果写到主会话 conversation_messages，新版 listJobRuns 直接返回
    // conversationUuid + messageUuid，前端无需再调 openRunChat 端点。
    String? convUuid = (entry.conversationUuid ?? '').trim().isEmpty
        ? null
        : entry.conversationUuid;
    String? msgUuid =
        (entry.messageUuid ?? '').trim().isEmpty ? null : entry.messageUuid;

    if (convUuid == null) {
      // 老数据兜底：调 openRunChat 让后端反查（命中既有消息）或新建独立会话。
      final response =
          await ref.read(taskPageProvider.notifier).openRunChat(entry);
      convUuid = response.conversationId;
      msgUuid = response.messageUuid?.trim().isEmpty == false
          ? response.messageUuid
          : null;
    }
    if (!context.mounted) return;

    if (msgUuid != null) {
      // 走"按消息居中"深度跳转：后端按 created_at 切窗，目标前后各 20 条；
      // 处理用户对话累计几千上万条时，普通 selectConversation 只加载首页
      // 找不到目标气泡的问题。loadMoreHistory 仍可继续上拉更早历史。
      await ref.read(chatProvider.notifier).selectConversationAtMessage(
            conversationId: convUuid,
            messageUuid: msgUuid,
          );
    } else {
      // 没有 messageUuid（cron 兜底新建独立会话路径）：走普通 selectConversation。
      await ref.read(chatProvider.notifier).selectConversation(convUuid);
    }
    if (!context.mounted) return;
    if (asPage) {
      context.push(RoutePaths.chatConversation);
    } else {
      context.go(RoutePaths.chat);
    }
  } catch (e) {
    if (!context.mounted) return;
    BotToast.showText(text: taskUserMessage(e));
  }
}
