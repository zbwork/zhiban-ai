import 'package:zhiban_client/services/session_service.dart';
import 'dart:convert';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/services/conversation_model_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:uuid/uuid.dart';

import '../models/ai_model_config.dart';
import '../models/ai_provider_config.dart';
import '../models/catalog_entry.dart';
import '../services/model_catalog_loader.dart';
import '../services/model_service_store.dart';

const _uuid = Uuid();

final modelServiceStoreProvider = Provider<ModelServiceStore>((ref) {
  return const ModelServiceStore();
});

/// 内置模型目录（厂商/模型数据 + Logo），只读一次加载，见
/// assets/model_catalog/SOURCE.md 了解数据来源。
final modelCatalogProvider = FutureProvider<ModelCatalog>((ref) {
  return const ModelCatalogLoader().load();
});

/// 当前配置的全部模型服务商列表，来源是本地存储，不发起任何网络请求。
final modelProvidersProvider =
    AsyncNotifierProvider<ModelProvidersNotifier, List<AiProviderConfig>>(
  ModelProvidersNotifier.new,
);

/// 左侧服务商列表的本地拖动顺序（row key 数组，见 [ProviderRow.key]）。
final providerOrderProvider =
    AsyncNotifierProvider<ProviderOrderNotifier, List<String>>(
  ProviderOrderNotifier.new,
);

/// PC 端服务商排序手势是否正在进行。详情表单用它区分普通失焦与拖动手柄
/// 导致的失焦：两者都保存已编辑内容，但排序时不显示“API 密钥已保存”。
final modelServiceReorderGestureProvider = StateProvider<bool>((ref) => false);

class ProviderOrderNotifier extends AsyncNotifier<List<String>> {
  ModelServiceStore get _store => ref.read(modelServiceStoreProvider);

  @override
  Future<List<String>> build() => _store.loadProviderOrder();

  Future<void> setOrder(List<String> order) async {
    state = AsyncData(order);
    await _store.saveProviderOrder(order);
  }

  /// 草稿落地成本地记录后，把持久化顺序里的 `catalog:<id>` 占位符换成真正
  /// 的 local id——不然下次渲染时这个 key 谁都对不上，会被当成"没见过的新
  /// 行"追加到末尾，用户刚拖到前面的位置就白拖了。
  Future<void> replaceKey(String oldKey, String newKey) async {
    final current = state.value ?? const <String>[];
    if (!current.contains(oldKey)) return;
    await setOrder([for (final k in current) k == oldKey ? newKey : k]);
  }

  /// 服务商从未启用切到启用时，把它挪到列表最前面（照抄 Cherry Studio
  /// `ProviderService.update` 的 `isEnabled: false->true` 分支）。列表不再
  /// 强制"已启用整体在前"，所以这一步是唯一让"刚启用"这件事在排序上可见
  /// 的地方——只在真正发生 false->true 跳变时调用一次，重复启用/单纯改配
  /// 置不应该再把它挪一次。
  Future<void> moveToFront(String key) async {
    final current = state.value ?? const <String>[];
    await setOrder([
      key,
      for (final k in current)
        if (k != key) k
    ]);
  }
}

class ModelProvidersNotifier extends AsyncNotifier<List<AiProviderConfig>> {
  ModelServiceStore get _store => ref.read(modelServiceStoreProvider);

  @override
  Future<List<AiProviderConfig>> build() {
    void refresh() => ref.invalidateSelf();
    ConversationModelSources.managedRevision.addListener(refresh);
    ref.onDispose(
        () => ConversationModelSources.managedRevision.removeListener(refresh));
    return _store.loadProviders();
  }

  Future<void> _persist(List<AiProviderConfig> next) async {
    final tokenFuture = const SessionService().getToken();
    final previous = state.value ?? const <AiProviderConfig>[];
    final before = {for (final p in previous) p.id: jsonEncode(p.toJson())};
    final ids = next.map((p) => p.id).toSet();
    final changes = [
      for (final p in next)
        if (before[p.id] != jsonEncode(p.toJson())) p,
      for (final p in previous)
        if (!ids.contains(p.id)) p.copyWith(enabled: false),
    ];
    state = AsyncData(next);
    final token = await tokenFuture;
    if (!ref.mounted) return;
    await _store.saveProviders(next);
    if (changes.isNotEmpty) await _publishConfiguration(changes, token);
  }

  Future<void> _publishConfiguration(
      List<AiProviderConfig> changes, String? token) async {
    try {
      if (token == null || !ref.mounted) return;
      await ConversationModelSources().sync(
          publishLocalConfiguration: true,
          changes: changes,
          expectedToken: token);
    } catch (_) {
      BotToast.showText(text: '配置已保存在本机，服务端同步失败，请重新保存后再使用');
    }
  }

  Future<void> initializeManagedProvider(CatalogProviderEntry entry,
      List<AiModelConfig> models, String scope) async {
    if (!ref.mounted) return;
    final current = state.value ?? const <AiProviderConfig>[];
    final matches = current.where((p) => p.catalogId == entry.id);
    final existing = matches.isEmpty ? null : matches.first;
    final provider = existing ??
        AiProviderConfig(
          // Managed providers have one stable local identity per catalog. The
          // Bus also canonicalizes this identity for cross-device convergence.
          id: 'managed:${entry.id}',
          name: entry.name,
          baseUrl: entry.baseUrl,
          catalogId: entry.id,
        );
    final existingByModel = {
      for (final model in provider.models) model.modelId: model,
    };
    final seen = <String>{};
    final currentModels = <AiModelConfig>[];
    for (final model in models) {
      if (!seen.add(model.modelId)) continue;
      final old = existingByModel[model.modelId];
      currentModels.add(old == null
          ? model
          : old.copyWith(
              groupName: model.groupName,
              capabilities: model.capabilities,
              displayName: old.displayName == old.modelId
                  ? model.displayName
                  : old.displayName));
    }
    final initialized = provider.copyWith(
      enabled: existing == null ? true : provider.enabled,
      models: currentModels,
      managedSetupScopes: {...provider.managedSetupScopes, scope},
    );
    final next = [
      for (final p in current) p.id == initialized.id ? initialized : p,
      if (existing == null) initialized
    ];
    final changed = existing == null ||
        jsonEncode(provider.toJson()) != jsonEncode(initialized.toJson());
    if (!changed) {
      state = AsyncData(next);
      return;
    }
    final token = await const SessionService().getToken();
    final saved = await _store.saveManagedSetup(next, scope);
    if (!ref.mounted || !saved) return;
    state = AsyncData(next);
    await _publishConfiguration([initialized], token);
    if (existing == null) {
      await ref
          .read(providerOrderProvider.notifier)
          .replaceKey('catalog:${entry.id}', initialized.id);
    }
  }

  /// 新建一个 Provider；[apiKey] 非空时一并写入安全存储。
  Future<AiProviderConfig> addProvider({
    required String name,
    String baseUrl = '',
    String? apiKey,
    String? catalogId,
  }) async {
    final current = state.value ?? const <AiProviderConfig>[];
    final provider = AiProviderConfig(
      id: _uuid.v4(),
      name: name,
      baseUrl: baseUrl,
      enabled: false,
      models: const <AiModelConfig>[],
      catalogId: catalogId,
    );
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      await _store.setApiKey(provider.id, apiKey.trim());
    }
    await _persist([...current, provider]);
    return provider;
  }

  /// 目录里的厂商在左侧列表默认全部展示，但**光点开看看不落地**——只有用户
  /// 真正做了一次配置动作（保存密钥/地址、勾选启用、添加模型……）才调用这个
  /// 方法把草稿落成本地记录。已经落过地（本地已有同 catalogId 的记录）直接
  /// 复用，不会重复创建。
  Future<String> materializeFromCatalog(CatalogProviderEntry entry) async {
    final current = state.value ?? const <AiProviderConfig>[];
    for (final p in current) {
      if (p.catalogId == entry.id) return p.id;
    }
    final created = await addProvider(
      name: entry.name,
      baseUrl: entry.baseUrl,
      catalogId: entry.id,
    );
    await ref
        .read(providerOrderProvider.notifier)
        .replaceKey('catalog:${entry.id}', created.id);
    return created.id;
  }

  Future<void> updateProvider(AiProviderConfig updated) async {
    final current = state.value ?? const <AiProviderConfig>[];
    await _persist([
      for (final p in current) p.id == updated.id ? updated : p
    ]);
  }

  /// 未启用->启用这一跳变会把它挪到列表最前面（[ProviderOrderNotifier.
  /// moveToFront]，照抄 Cherry Studio 的行为）；重复启用（本来就是 enabled
  /// 再设一次 true）或者关闭都不触发挪位，维持用户当前手动排好的顺序。
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    final current = state.value ?? const <AiProviderConfig>[];
    final wasEnabled = current.any((p) => p.id == providerId && p.enabled);
    await _persist([
      for (final p in current)
        p.id == providerId ? p.copyWith(enabled: enabled) : p,
    ]);
    if (enabled && !wasEnabled) {
      await ref.read(providerOrderProvider.notifier).moveToFront(providerId);
    }
  }

  Future<void> addModel(String providerId, AiModelConfig model) async {
    final current = state.value ?? const <AiProviderConfig>[];
    await _persist([
      for (final p in current)
        p.id == providerId ? p.copyWith(models: [...p.models, model]) : p,
    ]);
  }

  /// 「获取模型列表」批量添加：一次性 persist，避免逐条 addModel 连续写盘。
  /// 按 [AiModelConfig.modelId] 去重——已经在本地列表里的模型标识直接跳过，
  /// 不产生重复条目。
  Future<void> addModels(String providerId, List<AiModelConfig> models) async {
    if (models.isEmpty) return;
    final current = state.value ?? const <AiProviderConfig>[];
    await _persist([
      for (final p in current)
        if (p.id == providerId)
          p.copyWith(models: [
            ...p.models,
            for (final model in models)
              if (!p.models.any((m) => m.modelId == model.modelId)) model,
          ])
        else
          p,
    ]);
  }

  /// Only a complete, successful user-requested catalog may remove stale rows.
  /// Keep the current objects so user names, order and model options survive.
  Future<void> retainAvailableModels(AiProviderConfig expected,
      Set<String> availableIds, String expectedScope) async {
    if (!ref.mounted) return;
    final current = state.value ?? const <AiProviderConfig>[];
    final matches = current.where((p) => p.id == expected.id);
    if (matches.isEmpty) return;
    final provider = matches.first;
    if (provider.baseUrl != expected.baseUrl ||
        provider.catalogId != expected.catalogId) {
      return;
    }
    final kept = provider.models
        .where((model) => availableIds.contains(model.modelId))
        .toList();
    if (kept.length == provider.models.length) return;
    final next = [
      for (final p in current)
        p.id == provider.id ? p.copyWith(models: kept) : p,
    ];
    // The store rechecks the captured account/tenant before writing preferences.
    final saved = await _store.saveManagedSetup(next, expectedScope);
    if (ref.mounted && saved) state = AsyncData(next);
  }

  Future<void> updateModel(String providerId, AiModelConfig model) async {
    final current = state.value ?? const <AiProviderConfig>[];
    await _persist([
      for (final p in current)
        if (p.id == providerId)
          p.copyWith(models: [
            for (final m in p.models) m.id == model.id ? model : m],
          )
        else
          p,
    ]);
  }

  Future<void> removeModel(String providerId, String modelId) async {
    final current = state.value ?? const <AiProviderConfig>[];
    await _persist([
      for (final p in current)
        if (p.id == providerId)
          p.copyWith(
            models: p.models.where((m) => m.id != modelId).toList()
          )
        else
          p,
    ]);
  }

  Future<void> setApiKey(String providerId, String apiKey) async {
    final token = await const SessionService().getToken();
    await _store.setApiKey(providerId, apiKey);
    await _publishConfiguration(
        (state.value ?? const <AiProviderConfig>[])
            .where((p) => p.id == providerId)
            .toList(),
        token);
  }

  Future<String?> readApiKey(String providerId) {
    return _store.getApiKey(providerId);
  }
}

/// 详情面板当前展示的对象：要么是已经落地的本地记录（[localId]），要么是
/// 用户刚点开、还没做任何配置动作的目录草稿（[catalogEntry]），二选一。
class ModelServiceSelection {
  const ModelServiceSelection.local(String id)
      : localId = id,
        catalogEntry = null;

  const ModelServiceSelection.draft(CatalogProviderEntry entry)
      : localId = null,
        catalogEntry = entry;

  final String? localId;
  final CatalogProviderEntry? catalogEntry;
}

/// 当前在设置页里选中查看/编辑的服务商（仅桌面端左右分栏布局使用）。
final selectedModelServiceSelectionProvider =
    StateProvider<ModelServiceSelection?>((ref) => null);
