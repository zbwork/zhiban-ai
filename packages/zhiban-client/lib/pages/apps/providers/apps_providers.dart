import 'package:riverpod/riverpod.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/apps/models/app_models.dart';
import 'package:zhiban_client/pages/apps/services/apps_service.dart';

/// F04 应用服务 — riverpod singleton。
final appsBusServiceProvider = Provider<AppsBusService>(
  (ref) => const AppsBusService(),
);

/// 会话内应用列表 — 按 conversationUuid 缓存; 进入会话时 watch 它即可拿列表。
///
/// 服务端会自动 dedupe 通用 + 业务应用; 客户端不再做去重。
final conversationAppsProvider =
    FutureProvider.family<List<ConversationAppItem>, String>((ref, convUuid) async {
  if (convUuid.isEmpty) return const [];
  final svc = ref.watch(appsBusServiceProvider);
  return svc.listConversationApps(convUuid);
});
