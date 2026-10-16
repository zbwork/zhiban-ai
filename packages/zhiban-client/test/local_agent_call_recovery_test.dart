import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_dual_channel.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_conversation_content.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/services/local_runtime_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

final local = AgentItem.fromJson(
    {'uuid': 'employee', 'name': '本地助手', 'execution_locus': 'local'});
final cloud = AgentItem.fromJson(
    {'uuid': 'employee', 'name': '云端助手', 'execution_locus': 'cloud'});
const bad = ConversationItem(
    conversationId: 'bad-room-conv',
    title: '本地助手',
    agentId: 'employee',
    agentName: '本地助手',
    kind: 'agent_direct',
    roomUuid: 'old-room',
    wukongChannelId: 'old-channel');
const original = ConversationItem(
    conversationId: 'original-conv',
    title: '本地助手',
    agentId: 'employee',
    agentName: '本地助手');

class _Service extends OpenClawChatService {
  List<ConversationItem> items = [bad, original];
  Future<List<ConversationItem>> Function()? load;
  Future<List<ConversationItem>> Function(int page, int pageSize)? pageLoad;
  int prepareCalls = 0;
  @override
  Future<List<ConversationItem>> listAllConversations(
          {int page = 1,
          int pageSize = 40,
          bool includeHidden = false}) async =>
      pageLoad != null
          ? await pageLoad!(page, pageSize)
          : load != null
              ? await load!()
              : items;
  @override
  Future<List<AgentItem>> listAgents() async => [local];
  @override
  Future<AgentDirectPrepareResult> prepareAgentDirectWuKong(
      String agentUuid) async {
    prepareCalls++;
    return const AgentDirectPrepareResult(
        conversationUuid: 'cloud-conv',
        roomUuid: 'cloud-room',
        wukongChannelId: 'cloud-channel',
        wukongChannelType: 2,
        agentUuid: 'employee');
  }

  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}
}

class _Chat extends ChatNotifier {
  @override
  Future<ChatState> build() async => const ChatWorkspaceState.initial()
          .copyWith(activeConversationId: bad.conversationId, sessions: {
        bad.conversationId: ChatSessionState(conversationId: bad.conversationId)
      });
  @override
  Future<void> selectConversation(String conversationId) async {
    debugSeedSession(conversationId);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<(ProviderContainer, WidgetRef, _Service)> boot(WidgetTester tester,
      {bool chatPage = false, List<String>? notices}) async {
    final service = _Service();
    final container = ProviderContainer(overrides: [
      chatServiceProvider.overrideWithValue(service),
      chatProvider.overrideWith(_Chat.new),
      selectedAgentOrFallbackProvider.overrideWithValue(local),
      localDesktopOnlineProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);
    await container.read(conversationsProvider.future);
    await container.read(chatProvider.future);
    await container.read(selectedAgentProvider.future);
    container.read(selectedAgentProvider.notifier).select(local);
    late WidgetRef widgetRef;
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Scaffold(body: Consumer(builder: (context, ref, _) {
          widgetRef = ref;
          return chatPage
              ? ChatConversationContent(onNotify: notices?.add)
              : const SizedBox();
        })))));
    await tester.pump();
    return (container, widgetRef, service);
  }

  testWidgets(
      'chat voice and video never prepare or switch a local conversation',
      (tester) async {
    final notices = <String>[];
    final (container, _, service) =
        await boot(tester, chatPage: true, notices: notices);
    final view = tester.widget<ChatSessionView>(find.byType(ChatSessionView));
    expect(view.sendReady, isFalse);
    expect(find.text('返回文字对话'), findsOneWidget);
    await tester.tap(find.byTooltip('语音通话'));
    await tester.tap(find.byTooltip('视频通话'));
    await tester.pump();
    expect(notices,
        [localAgentCallUnavailableMessage, localAgentCallUnavailableMessage]);
    expect(service.prepareCalls, 0);
    expect(container.read(chatProvider).requireValue.activeConversationId,
        bad.conversationId);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('contacts call entry rejects local before any state change',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    await expectLater(
        openAgentDirectConversation(ref, agent: local, prepareWuKong: true),
        throwsStateError);
    expect(service.prepareCalls, 0);
    expect(container.read(chatProvider).requireValue.activeConversationId,
        bad.conversationId);
  });

  testWidgets(
      'recovery finds original single hidden by sidebar dedupe, without old room metadata',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    expect(
        container
            .read(conversationsProvider)
            .requireValue
            .single
            .conversationId,
        bad.conversationId);
    final result = await openAgentDirectConversation(ref,
        agent: local, expectedActiveConversationId: bad.conversationId);
    expect(result.conversationId, original.conversationId);
    final recovered = container.read(conversationsProvider).requireValue.single;
    expect(recovered.kind, 'single');
    expect(recovered.roomUuid, isNull);
    expect(recovered.wukongChannelId, isNull);
    expect(container.read(chatProvider).requireValue.activeConversationId,
        original.conversationId);
    expect(service.items, [bad, original],
        reason: 'server records must remain unchanged');
    expect(service.prepareCalls, 0);
  });

  testWidgets(
      'no original single recovers to pending, never a group or another employee',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    service.items = [
      bad,
      original.copyWith(
          conversationId: 'group', kind: 'group', roomUuid: 'group'),
      original.copyWith(conversationId: 'other', agentId: 'other')
    ];
    final result = await openAgentDirectConversation(ref,
        agent: local, expectedActiveConversationId: bad.conversationId);
    expect(result.conversationId, pendingConversationFor(local.agentId));
    expect(container.read(conversationsProvider).requireValue.single.roomUuid,
        isNull);
  });

  testWidgets('failed recovery query preserves current selection',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    service.load = () => Future.error(StateError('network'));
    await expectLater(
        openAgentDirectConversation(ref,
            agent: local, expectedActiveConversationId: bad.conversationId),
        throwsStateError);
    expect(container.read(chatProvider).requireValue.activeConversationId,
        bad.conversationId);
    expect(
        container
            .read(conversationsProvider)
            .requireValue
            .single
            .conversationId,
        bad.conversationId);
  });

  testWidgets('recovery searches later pages for original history',
      (tester) async {
    final (_, ref, service) = await boot(tester);
    final pages = <int>[];
    service.pageLoad = (page, pageSize) async {
      pages.add(page);
      return page == 1
          ? List.generate(
              pageSize,
              (i) => original.copyWith(
                  conversationId: 'other-$i', agentId: 'other-$i'))
          : [original];
    };
    final result = await openAgentDirectConversation(ref,
        agent: local, expectedActiveConversationId: bad.conversationId);
    expect(result.conversationId, original.conversationId);
    expect(pages, [1, 2]);
  });

  testWidgets('late recovery cannot steal selection from another conversation',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    final response = Completer<List<ConversationItem>>();
    service.load = () => response.future;
    final recovering = openAgentDirectConversation(ref,
        agent: local, expectedActiveConversationId: bad.conversationId);
    container.read(chatProvider.notifier).debugSeedSession('other-conv');
    final rejected = expectLater(recovering, throwsStateError);
    response.complete([original]);
    await rejected;
    expect(container.read(chatProvider).requireValue.activeConversationId,
        'other-conv');
  });

  testWidgets('cloud call still prepares and selects room conversation',
      (tester) async {
    final (container, ref, service) = await boot(tester);
    final result = await openAgentDirectConversation(ref,
        agent: cloud, prepareWuKong: true);
    expect(service.prepareCalls, 1);
    expect(result.roomUuid, 'cloud-room');
    expect(container.read(chatProvider).requireValue.activeConversationId,
        'cloud-conv');
  });
}
