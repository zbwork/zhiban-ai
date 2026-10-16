import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/analytics_service.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// 登录成功后的统一收尾：放大桌面窗口 + 路由到主页。
/// [resetScope] 为 true 时下一帧重建 ProviderScope（用于切换租户后让所有 provider
/// 重新读取新的会话；同手机号同租户的常规登录直接传 false 避免不必要全局重建）。
void enterHomeAfterLogin(
  BuildContext context, {
  bool resetScope = false
}) {
  if (!context.mounted) return;
  enterHomeAfterLoginWithRouter(GoRouter.of(context), resetScope: resetScope);
}

/// 弹层/会话重建可能卸载原 context；此类调用方须在切换前取得根 router。
void enterHomeAfterLoginWithRouter(
  GoRouter router, {
  bool resetScope = false,
}) {
  // 租户 scope 已确定后再上报，避免多租户登录在 scope/switch 前把事件发到错误租户。
  AnalyticsService.instance.trackActiveUnawaited('login');
  WindowController.instance.showHomeWindow();
  if (resetScope) {
    // 先重建 session ProviderScope, 再进入授权壳层触发 prewarm/WuKong 实时桥接等启动逻辑。
    // 若先 go('/chat') 再下一帧 reset, 云端预热开关开启时 MainLayout 会先发起 /runtime/ensure,
    // 随后旧 PrewarmController 被 dispose, ensure 返回后无法写入浮层状态。
    resetSessionScope();
    router.go(RoutePaths.chat);
    return;
  }
  router.go(RoutePaths.chat);
}

Future<void> openLoginPrivacyPolicy() async {
  await launchUrl(
    Uri.parse(AppConfig.privacyPolicyUrl),
    mode: LaunchMode.externalApplication,
  );
}

Future<void> openLoginUserAgreement() async {
  await launchUrl(
    Uri.parse(AppConfig.userAgreementUrl),
    mode: LaunchMode.externalApplication,
  );
}
