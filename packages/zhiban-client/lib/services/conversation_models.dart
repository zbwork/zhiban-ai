import 'dart:convert';
import 'local_runtime_api.dart';
import 'package:flutter/foundation.dart';
import 'conversation_model_sources.dart';
import 'conversation_model_order.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/services/local_agent_service.dart';

class ConversationModelState {
  const ConversationModelState(
      {this.models = const [],
      this.selected = '',
      this.manuallySelected = false,
      this.loading = false,
      this.error = ''});
  final List<LlmModelOption> models;
  final String selected;
  final bool manuallySelected;
  final bool loading;
  final String error;
  bool get canAttemptSend => !loading && (ready || error.isNotEmpty);
  String get selectionLabel {
    final item = models.where((m) => m.id == selected).firstOrNull;
    if (item != null) return item.label;
    try {
      final ref = stableConversationModel(selected).split(':');
      if (ref.length == 3 && ref.first == 'msel') {
        return utf8.decode(base64Url.decode(base64Url.normalize(ref.last)));
      }
    } catch (_) {/* Older/raw IDs use their original label. */}
    return selected.isEmpty ? '选择模型' : selected;
  }

  String get unavailableMessage => selected.isEmpty
      ? '当前账号没有可用模型，请检查模型服务。'
      : '当前模型「$selectionLabel」已不可用，请切换模型后重试。';
  bool get ready =>
      !loading &&
      error.isEmpty &&
      selected.isNotEmpty &&
      models.any((m) => m.id == selected);
}

String stableConversationModel(String value) {
  final parts = value.split(':');
  if (parts.length == 4 && (parts.first == 'mref' || parts.first == 'mbnd')) {
    return 'msel:${parts[1]}:${parts[3]}';
  }
  return value;
}

/// UI readiness and account-scoped preferences. Bus remains the model authorization authority.
class ConversationModels extends ChangeNotifier {
  ConversationModels();
  static final instance = ConversationModels();
  final _states = <String, ConversationModelState>{};
  int _generation = 0;
  final _requests = <String, int>{};
  String _key(String agent, String conversation) => '$agent:$conversation';
  ConversationModelState state(String agent, String conversation) =>
      _states[_key(agent, conversation)] ?? const ConversationModelState();
  void clear() {
    _generation++;
    _states.clear();
    _requests.clear();
    notifyListeners();
  }

  Future<String> _preference(String agent, String conversation) async {
    final prefs = await SharedPreferences.getInstance();
    final identity = LocalAgentService.identity(
        prefs.getString(AppConfig.storageTokenKey) ?? '');
    if (identity == null) throw StateError('请重新登录后选择模型');
    return 'conversation_model:${AppConfig.apiUrl()}:${identity['tenant']}:${identity['account']}:$agent:$conversation';
  }

  static ConversationModelState resolve(
      List<LlmModelOption> models, String saved) {
    final available =
        orderConversationModels(models.where((m) => m.id.trim().isNotEmpty));
    // Preferences created before model-source bindings used the provider's
    // raw model_id. Resolve that legacy value to the current opaque id so a
    // production refresh cannot send a raw model name to the local runtime.
    final matched = available.where((m) {
      if (stableConversationModel(m.id) == stableConversationModel(saved)) {
        return true;
      }
      return m.modelId.trim().isNotEmpty && m.modelId.trim() == saved.trim();
    }).firstOrNull;
    if (saved.isNotEmpty && matched == null) {
      final missing = ConversationModelState(
          models: available, selected: saved, manuallySelected: true);
      return ConversationModelState(
          models: available,
          selected: saved,
          manuallySelected: true,
          error: missing.unavailableMessage);
    }
    if (available.isEmpty) {
      return const ConversationModelState(error: '当前账号没有可用模型，请检查模型服务');
    }
    return ConversationModelState(
        models: available,
        manuallySelected: saved.isNotEmpty,
        selected: matched?.id ?? available.first.id);
  }

  /// Update every already-loaded conversation without silently replacing a
  /// selected model that the provider removed.
  void applyCatalog(List<LlmModelOption> models) {
    for (final key in _states.keys.toList()) {
      final previous = _states[key]!;
      _requests[key] = (_requests[key] ?? 0) + 1;
      final next = resolve(models, previous.selected);
      _states[key] = ConversationModelState(
          models: next.models,
          selected: next.selected,
          manuallySelected: previous.manuallySelected,
          error: next.error);
    }
    notifyListeners();
  }

  Future<void> load(AgentItem agent, String conversation,
      {bool refresh = false}) async {
    final key = _key(agent.agentId, conversation);
    final generation = _generation;
    final request = (_requests[key] ?? 0) + 1;
    _requests[key] = request;
    final previous = state(agent.agentId, conversation);
    _states[key] = ConversationModelState(
        models: previous.models,
        selected: previous.selected,
        manuallySelected: previous.manuallySelected,
        loading: true);
    notifyListeners();
    try {
      final preference = await _preference(agent.agentId, conversation);
      final prefs = await SharedPreferences.getInstance();
      var saved = prefs.getString(preference) ?? '';
      if (agent.executionLocus == 'local') {
        // The desktop helper may be temporarily offline. That must not prevent
        // refreshing the account model catalog: otherwise a cached raw model
        // name remains selected forever and every send is rejected in prod.
        try {
          final remote = await LocalRuntimeApi().conversation(conversation);
          if (saved.isEmpty && '${remote['model'] ?? ''}'.isNotEmpty) {
            saved = '${remote['model']}';
          }
        } catch (_) {
          // Keep the saved preference and continue with the remote catalog.
        }
      }
      final models = refresh
          ? (await ConversationModelSources().refreshManaged()).items
          : await ConversationModelSources()
              .sync(publishLocalConfiguration: false);
      if (_generation != generation ||
          _requests[key] != request ||
          preference != await _preference(agent.agentId, conversation)) {
        return;
      }
      if (refresh) {
        applyCatalog(models);
        if (saved.isEmpty && previous.selected.isNotEmpty) {
          saved = previous.selected;
        }
      }
      final next = resolve(models, saved);
      _states[key] =
          refresh && !previous.manuallySelected && previous.selected == saved
              ? ConversationModelState(
                  models: next.models,
                  selected: next.selected,
                  error: next.error)
              : next;
    } catch (_) {
      if (_generation != generation || _requests[key] != request) return;
      _states[key] = ConversationModelState(
          models: previous.models,
          selected: previous.selected,
          manuallySelected: previous.manuallySelected,
          error: '模型列表加载失败，请重试或检查模型服务');
    }
    notifyListeners();
  }

  Future<void> select(String agent, String conversation, String model) async {
    final old = state(agent, conversation);
    if (!old.models.any((m) => m.id == model)) throw StateError('模型不可用');
    final generation = _generation;
    final key = _key(agent, conversation);
    final request = (_requests[key] ?? 0) + 1;
    _requests[key] = request;
    final preference = await _preference(agent, conversation);
    final prefs = await SharedPreferences.getInstance();
    if (generation != _generation || _requests[key] != request) return;
    await prefs.setString(preference, model);
    if (generation != _generation || _requests[key] != request) return;
    _states[_key(agent, conversation)] = ConversationModelState(
        models: old.models, selected: model, manuallySelected: true);
    notifyListeners();
  }

  Future<void> adopt(String agent, String previous, String next) async {
    final old = state(agent, previous);
    if (!old.ready || previous == next) return;
    _states[_key(agent, next)] = old;
    if (old.manuallySelected) {
      await select(agent, next, old.selected);
    } else {
      notifyListeners();
    }
  }
}
