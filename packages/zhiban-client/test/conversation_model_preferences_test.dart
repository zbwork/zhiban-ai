import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'local_agent_design_test.dart' show ModelMenuAdapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'catalog revision and internal run binding preserve platform/model choice',
      () {
    const stable = 'msel:platform:Z3B0LTY';
    final items = [
      LlmModelOption.fromJson(
          {'id': stable, 'label': 'GPT 6', 'model_id': 'gpt-6'})
    ];
    for (final saved in [
      'mref:platform:9:Z3B0LTY',
      'mbnd:platform:binding:Z3B0LTY',
      stable
    ]) {
      final state = ConversationModels.resolve(items, saved);
      expect(state.ready, isTrue);
      expect(state.selected, stable);
    }
    final removed = ConversationModels.resolve([], stable);
    expect(removed.selected, stable);
    expect(removed.ready, isFalse);
    expect(removed.canAttemptSend, isTrue);
    expect(removed.error, contains('请切换模型'));
    final otherPlatform =
        ConversationModels.resolve(items, 'msel:other:Z3B0LTY');
    expect(otherPlatform.ready, isFalse);
    expect(otherPlatform.selected, 'msel:other:Z3B0LTY');

    final legacyRaw = ConversationModels.resolve(items, 'gpt-6');
    expect(legacyRaw.ready, isTrue);
    expect(legacyRaw.selected, stable);
  });
  test(
      'only manual choices persist across refresh, restart and conversation adoption',
      () async {
    final claims = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'user',
      'aid': 1,
      'sid': 'session',
      'act_scope': 'tenant:tenant'
    })));
    SharedPreferences.setMockInitialValues(
        {AppConfig.storageTokenKey: 'x.$claims.x'});
    final adapter = ModelMenuAdapter();
    final previous = sensitiveRequest.httpClientAdapter;
    sensitiveRequest.httpClientAdapter = adapter;
    addTearDown(() => sensitiveRequest.httpClientAdapter = previous);
    final models = ConversationModels();
    addTearDown(models.dispose);
    final agent =
        AgentItem.fromJson({'uuid': 'agent', 'supports_model_selection': true});
    final prefs = await SharedPreferences.getInstance();
    await models.load(agent, 'draft');
    expect(models.state(agent.agentId, 'draft').selected, '第一模型');
    expect(models.state(agent.agentId, 'draft').manuallySelected, isFalse);
    await models.adopt(agent.agentId, 'draft', 'created');
    expect(
        prefs.getKeys().where((key) => key.startsWith('conversation_model:')),
        isEmpty);
    // A changing default is not pinned by an automatic preference write.
    adapter.models = ['0新默认', '第二模型', '第一模型'];
    await models.load(agent, 'created');
    expect(models.state(agent.agentId, 'created').selected, '0新默认');
    await models.select(agent.agentId, 'created', '第一模型');
    await models.adopt(agent.agentId, 'created', 'final');
    models.clear();
    await models.load(agent, 'final');
    expect(models.state(agent.agentId, 'final').selected, '第一模型');
    expect(models.state(agent.agentId, 'final').manuallySelected, isTrue);
    expect(
        prefs
            .getKeys()
            .where((key) => key.startsWith('conversation_model:'))
            .length,
        2);
  });
}
