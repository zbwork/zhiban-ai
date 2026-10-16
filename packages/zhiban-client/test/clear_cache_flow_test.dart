import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/im/human_chat_draft_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/settings/clear_cache_flow.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Chat extends ChatNotifier {
  _Chat(this.initial);
  final ChatState initial;
  @override
  Future<ChatState> build() async => initial;
}

void main() {
  test('human/group unsaved state registry follows live state and disposal',
      () {
    var unsaved = true;
    bool read() => unsaved;
    HumanChatDraftGuard.register(read);
    expect(hasUncommittedHumanChatDrafts, isTrue);
    unsaved = false;
    expect(hasUncommittedHumanChatDrafts, isFalse);
    unsaved = true;
    HumanChatDraftGuard.unregister(read);
    expect(hasUncommittedHumanChatDrafts, isFalse);
  });
  for (final scenario in [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (true, false, true)
  ]) {
    final (confirm, draft, humanDraft) = scenario;
    testWidgets(
        'confirmation=$confirm draft=$draft human=$humanDraft respects cache deletion boundary',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      bool readHumanDraft() => humanDraft;
      HumanChatDraftGuard.register(readHumanDraft);
      addTearDown(() => HumanChatDraftGuard.unregister(readHumanDraft));
      debugClearImCacheOverride = () async {
        calls++;
        expect(find.byType(UiConfirmDialog), findsNothing);
      };
      addTearDown(() => debugClearImCacheOverride = null);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatProvider.overrideWith(() => _Chat(draft
              ? const ChatState(sessions: {
                  'draft': ChatSessionState(
                      conversationId: 'draft',
                      draft: ChatComposerDraft(
                          revision: 1, text: 'unsent', hasContent: true))
                })
              : const ChatState.initial()))
        ],
        child: MaterialApp(
          builder: BotToastInit(),
          navigatorObservers: [BotToastNavigatorObserver()],
          home: Consumer(builder: (context, ref, _) {
            ref.watch(chatProvider);
            return Scaffold(
                body: TextButton(
                    onPressed: () => confirmClearCache(context, ref),
                    child: const Text('清理入口')));
          }),
        ),
      ));
      await tester.tap(find.text('清理入口'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会删除服务器记录'), findsOneWidget);
      await tester.tap(find.text(confirm ? '清除' : '取消'));
      await tester.pump();
      expect(calls, 0);
      await tester.pumpAndSettle();
      expect(calls, confirm && !draft && !humanDraft ? 1 : 0);
      expect(tester.takeException(), isNull);
      BotToast.cleanAll();
      await tester.pumpAndSettle();
    });
  }
}
