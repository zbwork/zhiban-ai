import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/window/window_controller.dart';

Future<void> performLogoutToLogin(
  BuildContext context, {
  String failurePrefix = '退出登录失败',
}) async {
  try {
    await const SessionService().clearSessionStorage();
    if (!context.mounted) return;
    WindowController.instance.showLoginWindow();
    context.go(RoutePaths.login);
  } catch (error) {
    if (!context.mounted) return;
    BotToast.showText(text: '$failurePrefix：$error');
  }
}
