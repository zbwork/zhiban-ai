import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/services/conversation_model_order.dart';
import 'package:zhiban_client/services/conversation_models.dart';

void main() {
  const siliconFirst = LlmModelOption(
      id: 'sf-1', label: 'same', providerId: 'silicon', providerName: '硅基流动');
  const beeFirst = LlmModelOption(
      id: 'bee-1',
      label: 'same',
      providerId: 'member-platform-uuid',
      providerName: 'BeeBridge');
  const other =
      LlmModelOption(id: 'other-1', label: 'other', providerId: 'other');
  const beeSecond = LlmModelOption(
      id: 'bee-2',
      label: 'bee second',
      providerId: 'member-platform-uuid',
      providerName: 'BeeBridge');
  const siliconSecond = LlmModelOption(
      id: 'sf-2',
      label: 'sf second',
      providerId: 'silicon',
      providerName: '硅基流动');
  const source = [siliconFirst, beeFirst, other, beeSecond, siliconSecond];
  test(
      'groups platforms stably with BeeBridge first and does not mutate source',
      () {
    final ordered = orderConversationModels(source);
    expect(ordered.map((m) => m.id),
        ['bee-2', 'bee-1', 'sf-1', 'sf-2', 'other-1']);
    expect(source.first.id, 'sf-1');
    expect(orderConversationModels(ordered), ordered);
  });
  test(
      'local and cloud shared defaults follow platform order without replacing saved choices',
      () {
    expect(ConversationModels.resolve(source, '').selected, 'bee-2');
    expect(ConversationModels.resolve(source, 'sf-1').selected, 'sf-1');
    expect(ConversationModels.resolve(source, 'removed').ready, isFalse);
    expect(
        ConversationModels.resolve([siliconFirst, other], '').selected, 'sf-1');
    expect(ConversationModels.resolve([], '').ready, isFalse);
  });
  test('legacy BeeBridge provider ID works without a platform name', () {
    const legacy =
        LlmModelOption(id: 'legacy', label: 'model', providerId: 'beebridge');
    expect(orderConversationModels([siliconFirst, legacy]).first, legacy);
  });
  test(
      'names sort ascending without case sensitivity and same names stay stable',
      () {
    const models = [
      LlmModelOption(id: 'z', label: 'gpt-6-astra', providerId: 'beebridge'),
      LlmModelOption(id: 'b', label: 'GPT-5.4', providerId: 'beebridge'),
      LlmModelOption(id: 'a', label: ' gpt-5.4 ', providerId: 'beebridge'),
      LlmModelOption(id: 'c', label: 'claude-opus', providerId: 'beebridge'),
    ];
    expect(
        orderConversationModels(models).map((m) => m.id), ['c', 'b', 'a', 'z']);
  });
}
