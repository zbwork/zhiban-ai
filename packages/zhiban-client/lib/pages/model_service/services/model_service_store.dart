import 'dart:convert';

import 'package:zhiban_client/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_provider_config.dart';

/// 模型服务配置的本地持久化。
///
/// Provider/Model 元数据（名称、baseUrl、模型列表……）和 API Key 都存
/// `SharedPreferences`，API Key 按 provider id 分开存取，不和上面那份
/// JSON 混在一起落盘（方便单独删除/覆盖，不必整份反序列化）。
///
/// API Key 未走 `flutter_secure_storage`（Keychain）：本地调试构建走
/// ad-hoc 签名，二进制哈希每次编译都变，macOS 会把每次 `flutter run` 都当
/// 成新 App 要求重新授权钥匙串，"始终允许"不生效——反复弹系统授权框。换成
/// `SharedPreferences` 后不再触发钥匙串弹窗，代价是本机文件系统层面明文
/// 存储，不再有 Keychain 的加密保护（BYOK 用户需知悉此权衡）。
///
/// **按账号隔离**：所有 key 都拼了当前登录账号的 `aid`（JWT claim, 跨租户切换
/// 不变——见 `SessionService.getAccountId` 注释）。这是 BYOK 用户自己配的第三方
/// API Key，同一台设备换人登录 / 切租户都不能看到上一个人的配置。用 `aid` 而不是
/// `act_tid`，是因为"模型服务"是这个人的东西，不是某个租户的东西，人切租户时应该
/// 还能用自己配的模型服务；但换成另一个手机号登录就必须完全隔离。
///
/// 这里只做本地配置的增删改查，不发起任何网络请求。
class ModelServiceStore {
  const ModelServiceStore({SessionService? sessionService})
      : _sessionService = sessionService ?? const SessionService();

  static const _prefsKeyPrefix = 'model_service.providers.v1.';
  static const _orderPrefsKeyPrefix = 'model_service.provider_order.v1.';
  static const _apiKeyPrefix = 'model_service.api_key.';
  // 未登录 (理论上不该发生, 这个页面要求已登录) 时的兜底分区; 绝不能跟真实
  // aid 撞名, 用一个前缀数字/字母都不合法的 JWT aid 的记号即可。
  static const _anonymousScope = 'anon';

  final SessionService _sessionService;

  Future<String?> managedScope() => _sessionService.getAccountTenantScope();

  /// Capture the destination account; a tenant switch must not redirect a late
  /// initialization write into the new user's preferences.
  Future<bool> saveManagedSetup(
      List<AiProviderConfig> providers, String expectedScope) async {
    final prefs = await SharedPreferences.getInstance();
    if (await managedScope() != expectedScope) return false;
    final account = expectedScope.split(':').first;
    return prefs.setString(_prefsKeyPrefix + account,
        jsonEncode(providers.map((p) => p.toJson()).toList()));
  }

  Future<String> _scope() async {
    final aid = await _sessionService.getAccountId();
    return (aid == null || aid.isEmpty) ? _anonymousScope : aid;
  }

  Future<List<AiProviderConfig>> loadProviders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyPrefix + await _scope());
    if (raw == null || raw.isEmpty) return const <AiProviderConfig>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <AiProviderConfig>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AiProviderConfig.fromJson)
          .toList();
    } catch (_) {
      // 本地配置损坏时不崩溃启动流程，当作空列表处理，用户可以重新配置。
      return const <AiProviderConfig>[];
    }
  }

  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(providers.map((p) => p.toJson()).toList());
    await prefs.setString(_prefsKeyPrefix + await _scope(), raw);
  }

  /// 左侧服务商列表的本地展示顺序——只存一份 row key 数组（本地记录用
  /// id，还没落地的目录草稿用 `catalog:<id>`），不含任何厂商元数据本身，
  /// 拖动排序跟"这个 provider 到底有哪些配置"是两件独立的事。
  Future<List<String>> loadProviderOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_orderPrefsKeyPrefix + await _scope()) ??
        const <String>[];
  }

  Future<void> saveProviderOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_orderPrefsKeyPrefix + await _scope(), order);
  }

  Future<String?> getApiKey(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(await _apiKeyFor(providerId));
  }

  Future<void> setApiKey(String providerId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _apiKeyFor(providerId), apiKey);
  }

  Future<void> deleteApiKey(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(await _apiKeyFor(providerId));
  }

  Future<String> _apiKeyFor(String providerId) async =>
      '$_apiKeyPrefix${await _scope()}.$providerId';
}
