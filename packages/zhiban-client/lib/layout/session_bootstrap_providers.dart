import 'package:zhiban_client/services/local_agent_service.dart';
import 'dart:async';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/local_coding_tools/providers/local_coding_tools_provider.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_background_maintenance.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';

/// 当前登录会话的运行环境预热入口。
///
/// Provider 的缓存承担 once-per-session 语义：同一 session scope 内即使
/// MainLayout 重复 build 也只执行一次；切换企业重建 ProviderScope 后会重新执行。
final sessionPrewarmBootstrapProvider = Provider<void>((ref) {
  Future.microtask(() async {
    if (!ref.mounted) return;
    if (!ref.read(cloudRuntimePrewarmEnabledProvider)) return;
    try {
      await ref.read(managedModelServiceProvider.future);
    } catch (_) {/* Prewarm reports its own recoverable error. */}
    if (!ref.mounted) return;
    unawaited(ref.read(prewarmControllerProvider.notifier).startOnce());
  });
});

/// 当前登录会话的 IM 实时桥接入口。
///
/// 桥接实例及其订阅跟随 session ProviderScope 生命周期，切换企业时先 dispose
/// 旧租户连接，再在新 scope 中创建新租户连接。
final sessionRealtimeBootstrapProvider = Provider<void>((ref) {
  ref.watch(conversationRealtimeBridgeProvider);
});

/// F31 · 本地开发工具后台维护入口(2026-09-15):登录后稍等片刻,静默修复本机
/// Codex / Claude 自动更新后知办配置或 Claude 桌面端运行组件跟不上的问题,用户
/// 不必打开「本地开发工具」页面。只修复、不切换,见 [LocalCodingBackgroundMaintenance]。
/// 每个会话 scope 一次;切换企业重建 ProviderScope 后会再跑一次。
final localCodingMaintenanceBootstrapProvider = Provider<void>((ref) {
  if (!(PlatformUtils.isMacOS || PlatformUtils.isWindows) ||
      !AppConfig.localCodingToolsEnabled) {
    return;
  }
  // 重新登录后自动重新接入(2026-09-18):同一个人回来时不必进页面点「修复并重试」。
  // 只做设备接入这一步,很轻,不必等后台维护那 20 秒。
  final reconnectTimer = Timer(const Duration(seconds: 3), () {
    if (!ref.mounted) return;
    unawaited(ref.read(localCodingToolsServiceProvider).reconnectIfSameIdentity());
  });
  ref.onDispose(reconnectTimer.cancel);
  // 避开启动时的预热与首屏请求。
  final timer = Timer(const Duration(seconds: 20), () {
    if (!ref.mounted) return;
    final maintenance = LocalCodingBackgroundMaintenance(
        ref.read(localCodingToolsServiceProvider));
    unawaited(maintenance.run().catchError((Object _) {}));
  });
  ref.onDispose(timer.cancel);
});

/// Start once per authenticated desktop session, independent of the selected chat.
final sessionLocalAgentStarterProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    final local = LocalAgentService.instance;
    if (local.supported) await local.ensureReady();
  };
});

final sessionLocalAgentBootstrapProvider = Provider<void>((ref) {
  Future.microtask(() async {
    if (!ref.mounted) return;
    try {
      await ref.read(sessionLocalAgentStarterProvider)();
    } catch (_) {
      // The service publishes startup status and owns bounded recovery.
    }
  });
});
