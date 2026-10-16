import 'dart:math';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/apps/models/app_models.dart';

/// F04 应用 API 封装 (agent-bus client 域 /api/agent-bus/v1/*)。
///
/// dio.baseUrl 已固定到 `/api/agent-bus/v1`, 这里仅拼业务路径。
/// 参考 docs/contracts/app-oauth2-contract.md。
class AppsBusService {
  const AppsBusService();

  /// 列当前会话可启动的应用；展示层按 bindingKind 选择具体入口。
  Future<List<ConversationAppItem>> listConversationApps(
      String convUuid) async {
    final response = await request.get(
      '/conversations/${Uri.encodeComponent(convUuid)}/apps',
    );
    final raw = responseAsMap(response);
    final items = (raw['apps'] is List) ? raw['apps'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => ConversationAppItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 启动应用 (颁一次性 code, 拼 launch_url) — F04 §3.4。
  ///
  /// [state] CSRF token; 调用方应在传给应用 H5 之前先保存到本地, 用于跟应用 redirect 时回传比对。
  /// [nonce] 可选 OIDC nonce; 写入 id_token 后由应用 H5 后端比对。
  Future<AppLaunchResult> launch({
    required String appUuid,
    String conversationUuid = '',
    required String state,
    String nonce = '',
  }) async {
    final body = {
      if (conversationUuid.isNotEmpty) 'conversation_uuid': conversationUuid,
      'state': state,
      if (nonce.isNotEmpty) 'nonce': nonce,
    };
    final response = await request.post(
      '/apps/${Uri.encodeComponent(appUuid)}/launch',
      data: body,
    );
    final raw = responseAsMap(response);
    return AppLaunchResult.fromJson(raw);
  }
}

/// 工具: 生成强随机 CSRF state (32 hex 字符)。
String generateCsrfState() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 工具: 生成强随机 OIDC nonce (32 hex 字符)。
String generateNonce() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
