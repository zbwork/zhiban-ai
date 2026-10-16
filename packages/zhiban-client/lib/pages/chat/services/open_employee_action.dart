import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

/// `open_employee:{显示名}` action 块的容器层实现（F26 助手间衔接, 2026-07-24,
/// 如创业助手代账建账完成通知的「找财税助手」）。
///
/// 点击 = 本地切到该数字员工的单聊会话，不走 `/chat/respond` 回灌：
/// - 已有会话直接复用；没有会话时查通讯录目录，create-on-first-send；
/// - 找不到同名员工 toast 兜底（环境间改名不致点击无响应）；
/// - 移动端不在会话详情页时补一跳 `/chat/conversation`；桌面端选中态
///   切换后聊天面板原地更新，无需导航。
Future<void> openEmployeeConversationFromAction(
  BuildContext context,
  WidgetRef ref,
  String actionId,
) async {
  const prefix = 'open_employee:';
  final name = actionId.startsWith(prefix)
      ? actionId.substring(prefix.length).trim()
      : '';
  try {
    await openAgentConversationByName(ref, name);
  } on StateError catch (e) {
    BotToast.showText(text: e.message);
    return;
  } catch (_) {
    BotToast.showText(text: '暂时无法打开会话，请稍后再试');
    return;
  }
  if (!context.mounted || !PlatformUtils.isMobile) return;
  if (GoRouterState.of(context).matchedLocation !=
      RoutePaths.chatConversation) {
    context.push(RoutePaths.chatConversation);
  }
}
