import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

void main() {
  test('agent failed history page remains retryable without skipping a page',
      () async {
    final service = _HistoryService();
    final container = ProviderContainer(overrides: [
      chatProvider.overrideWith(_SeededChat.new),
      chatServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    await container.read(chatProvider.future);
    final notifier = container.read(chatProvider.notifier);
    await expectLater(
        notifier.loadMoreHistory(reportErrors: true), throwsStateError);
    var session = container.read(chatProvider).requireValue.activeSession!;
    expect(session.isLoadingHistory, isFalse);
    expect(session.hasMoreHistory, isTrue);
    service.fail = false;
    await notifier.loadMoreHistory(reportErrors: true);
    session = container.read(chatProvider).requireValue.activeSession!;
    expect(service.pages, [2, 2]);
    expect(session.hasMoreHistory, isFalse);
    expect(session.isLoadingHistory, isFalse);
  });
}

class _SeededChat extends ChatNotifier {
  @override
  Future<ChatWorkspaceState> build() async =>
      ChatWorkspaceState(activeConversationId: 'conversation', sessions: {
        'conversation': ChatSessionState(
            conversationId: 'conversation',
            hasMoreHistory: true,
            messages: [
              ChatMessage(role: ChatRole.question, content: 'local message')
            ]),
      });
}

class _HistoryService extends OpenClawChatService {
  bool fail = true;
  final pages = <int>[];

  @override
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async {
    pages.add(page);
    if (fail) throw StateError('offline');
    return [];
  }
}
