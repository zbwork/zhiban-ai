import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../config/app_config.dart';

import 'package:zhiban_client/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_provider_config.dart';
import 'local_api_key_file_store.dart';

/// 模型元数据本地保存；社区版密钥按用户选择保存在私有明文文件。
class ModelServiceStore {
  const ModelServiceStore(
      {SessionService? sessionService,
      FlutterSecureStorage? secureStorage,
      LocalApiKeyFileStore fileStore = const LocalApiKeyFileStore()})
      : _secureStorage = secureStorage,
        _fileStore = fileStore,
        _sessionService = sessionService ?? const SessionService();

  static const _prefsKeyPrefix = 'model_service.providers.v1.';
  static const _orderPrefsKeyPrefix = 'model_service.provider_order.v1.';
  static const _apiKeyPrefix = 'model_service.api_key.';
  // 未登录 (理论上不该发生, 这个页面要求已登录) 时的兜底分区; 绝不能跟真实
  // aid 撞名, 用一个前缀数字/字母都不合法的 JWT aid 的记号即可。
  static const _anonymousScope = 'anon';

  final SessionService _sessionService;
  // Explicit test substitute only; production community storage is a local file.
  final FlutterSecureStorage? _secureStorage;
  final LocalApiKeyFileStore _fileStore;
  static final _apiKeys = <String, String?>{};
  static final _keyReads = <String, Future<String?>>{};

  @visibleForTesting
  static void clearApiKeyMemoryCache() {
    _apiKeys.clear();
    _keyReads.clear();
  }

  static void _invalidateKey(String key) {
    _apiKeys.remove(key);
    _keyReads.remove(key);
  }

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
    if (AppConfig.communityEdition) return 'community-local';
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
    final key = await _apiKeyFor(providerId);
    if (!AppConfig.communityEdition) return prefs.getString(key);
    if (_apiKeys.containsKey(key)) return _apiKeys[key];
    final pending = _keyReads[key];
    if (pending != null) return pending;
    final read = _readSecureKey(key, prefs);
    _keyReads[key] = read;
    try {
      final value = await read;
      // A save/delete may have superseded this read while authorization was open.
      if (identical(_keyReads[key], read)) _apiKeys[key] = value;
      return value;
    } finally {
      if (identical(_keyReads[key], read)) _keyReads.remove(key);
    }
  }

  Future<String?> _readSecureKey(String key, SharedPreferences prefs) async {
    final value = _secureStorage != null
        ? await _secureStorage.read(key: key)
        : await _fileStore.read(key);
    if (value != null) return value;
    final legacy = prefs.getString(key);
    if (legacy != null) {
      await _writeKey(key, legacy);
      await prefs.remove(key);
    }
    return legacy;
  }

  Future<void> setApiKey(String providerId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _apiKeyFor(providerId);
    if (AppConfig.communityEdition) {
      _invalidateKey(key);
      try {
        await _writeKey(key, apiKey);
        await prefs.remove(key);
      } catch (_) {
        _invalidateKey(key);
        rethrow;
      }
      _invalidateKey(key);
      _apiKeys[key] = apiKey;
    } else {
      await prefs.setString(key, apiKey);
    }
  }

  Future<void> deleteApiKey(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _apiKeyFor(providerId);
    if (AppConfig.communityEdition) {
      _invalidateKey(key);
      try {
        if (_secureStorage != null) {
          await _secureStorage.delete(key: key);
        } else {
          await _fileStore.delete(key);
        }
      } finally {
        _invalidateKey(key);
      }
    }
    await prefs.remove(key);
  }

  Future<String> _apiKeyFor(String providerId) async =>
      '$_apiKeyPrefix${await _scope()}.$providerId';

  Future<void> _writeKey(String key, String value) => _secureStorage != null
      ? _secureStorage.write(key: key, value: value)
      : _fileStore.write(key, value);
}
