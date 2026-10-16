import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

/// 假 chat service：listAllConversations 返回可控列表，不打网络。
class _FakeChatService extends OpenClawChatService {
  _FakeChatService(this.items);
  List<ConversationItem> items;
  Future<List<ConversationItem>> Function()? listAllConversationsOverride;
  Future<List<AgentItem>> Function()? listAgentsOverride;

  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async {
    final override = listAllConversationsOverride;
    if (override != null) return override();
    return items;
  }

  @override
  Future<List<AgentItem>> listAgents() async {
    final override = listAgentsOverride;
    if (override == null) return const <AgentItem>[];
    return override();
  }
}

ConversationItem _real(String id, String agentId, {String title = 'real'}) {
  return ConversationItem(
    conversationId: id,
    title: title,
    agentId: agentId,
    agentName: title,
    kind: 'single',
  );
}

ConversationItem _group(String id, String agentId, {String title = 'group'}) {
  return ConversationItem(
    conversationId: id,
    title: title,
    agentId: agentId,
    agentName: title,
    kind: 'group',
    roomUuid: 'room-$id',
    wukongChannelId: 'ch-$id',
    wukongChannelType: 2,
  );
}

Future<(ProviderContainer, ConversationsNotifier, _FakeChatService)> _boot(
  List<ConversationItem> initial,
) async {
  final fake = _FakeChatService(initial);
  final container = ProviderContainer(
    overrides: [chatServiceProvider.overrideWith((ref) => fake)],
  );
  await container.read(conversationsProvider.future);
  return (container, container.read(conversationsProvider.notifier), fake);
}

List<ConversationItem> _list(ProviderContainer c) =>
    c.read(conversationsProvider).asData!.value;

void main() {
  group('ConversationItem.pendingAgent', () {
    test('builds renderable pending item (title/avatar/agentId/kind)', () {
      final item = ConversationItem.pendingAgent(
        conversationId: 'pending:a1',
        agentUuid: 'a1',
        name: '周芷涵',
        avatarUrl: 'http://avatar/1.jpg',
      );
      expect(item.conversationId, 'pending:a1');
      expect(item.title, '周芷涵');
      expect(item.agentName, '周芷涵');
      expect(item.agentId, 'a1');
      expect(item.agentAvatarUrl, 'http://avatar/1.jpg');
      expect(item.kind, 'single');
      expect(isPendingConversation(item.conversationId), isTrue);
    });

    test('empty name falls back to 数字员工 (no blank title)', () {
      final item = ConversationItem.pendingAgent(
          conversationId: 'pending:a2', agentUuid: 'a2', name: '');
      expect(item.title, '数字员工');
    });
  });

  group('ConversationsNotifier pending list (doc-13 §A P0)', () {
    test('ensurePendingAgent inserts a selectable pending bar', () async {
      final (c, n, _) = await _boot(const []);
      addTearDown(c.dispose);
      n.ensurePendingAgent(pendingConversationItem(
          agentUuid: 'a1', name: '周芷涵', avatarUrl: 'http://x'));
      final list = _list(c);
      expect(list.length, 1);
      expect(list.first.conversationId, pendingConversationFor('a1'));
      expect(list.first.title, '周芷涵');
      expect(list.first.agentId, 'a1');
    });

    test('ensurePendingAgent de-dups + skips when real conversation exists',
        () async {
      final (c, n, _) = await _boot([_real('conv-1', 'a1')]);
      addTearDown(c.dispose);
      // agent a1 已有真实会话 → 不插 pending。
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: 'X'));
      expect(_list(c).length, 1);
      expect(_list(c).first.conversationId, 'conv-1');
      // agent a2 无真实会话 → 插 pending; 重复调用不再加。
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a2', name: 'Y'));
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a2', name: 'Y'));
      expect(_list(c).where((x) => x.agentId == 'a2').length, 1);
    });

    test('ensurePendingAgent ignores group rows that contain the same agent',
        () async {
      final (c, n, _) = await _boot([_group('group-1', 'a1')]);
      addTearDown(c.dispose);

      n.ensurePendingAgent(pendingConversationItem(
          agentUuid: 'a1', name: '周芷涵', avatarUrl: 'http://x'));

      final list = _list(c);
      expect(list.map((x) => x.conversationId), contains('group-1'));
      expect(list.map((x) => x.conversationId),
          contains(pendingConversationFor('a1')));
      expect(list.first.conversationId, pendingConversationFor('a1'));
    });

    test('adoptPending upgrades pending → real, no duplicate', () async {
      final (c, n, _) = await _boot(const []);
      addTearDown(c.dispose);
      n.ensurePendingAgent(pendingConversationItem(
          agentUuid: 'a1', name: '周芷涵', avatarUrl: 'http://x'));
      n.adoptPending(pendingConversationFor('a1'), 'real-1');
      final list = _list(c);
      expect(list.length, 1);
      expect(list.first.conversationId, 'real-1');
      expect(list.first.title, '周芷涵'); // 标题/头像保留
      expect(list.first.agentAvatarUrl, 'http://x');
      expect(list.where((x) => isPendingConversation(x.conversationId)).isEmpty,
          isTrue);
    });

    test('adoptPending keeps group rows that contain the same agent', () async {
      final (c, n, _) = await _boot([_group('group-1', 'a1')]);
      addTearDown(c.dispose);

      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      n.adoptPending(pendingConversationFor('a1'), 'real-1');

      final list = _list(c);
      expect(list.map((x) => x.conversationId), contains('group-1'));
      expect(list.map((x) => x.conversationId), contains('real-1'));
      expect(list.where((x) => isPendingConversation(x.conversationId)).isEmpty,
          isTrue);
    });

    test('adoptPending preserves agent-direct room metadata for RTC buttons',
        () async {
      final (c, n, _) = await _boot(const []);
      addTearDown(c.dispose);

      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      n.adoptPending(
        pendingConversationFor('a1'),
        'real-1',
        roomUuid: 'room-1',
        wukongChannelId: 't_1_d_hash',
        wukongChannelType: 2,
        kind: 'agent_direct',
      );

      final conv = _list(c).single;
      expect(conv.conversationId, 'real-1');
      expect(conv.kind, 'agent_direct');
      expect(conv.roomUuid, 'room-1');
      expect(conv.wukongChannelId, 't_1_d_hash');
      expect(conv.wukongChannelType, 2);
    });

    test('refresh preserves un-adopted pending; drops it once real exists',
        () async {
      final (c, n, fake) = await _boot(const []);
      addTearDown(c.dispose);
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      // server 还没有该会话 → refresh 保留 pending。
      await n.refresh();
      expect(
          _list(c).where((x) => isPendingConversation(x.conversationId)).length,
          1);
      // server 现在返回该 agent 的真实会话 → refresh 去掉 pending，仅留真实。
      fake.items = [_real('real-1', 'a1')];
      await n.refresh();
      final list = _list(c);
      expect(list.length, 1);
      expect(list.first.conversationId, 'real-1');
      expect(list.where((x) => isPendingConversation(x.conversationId)).isEmpty,
          isTrue);
    });

    test('refresh keeps active pending until send response adopts real uuid',
        () async {
      final (c, n, fake) = await _boot(const []);
      addTearDown(c.dispose);

      final pendingId = pendingConversationFor('a1');
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      c.read(activePendingConversationProvider.notifier).state = pendingId;

      // The server-side send path has already created/resolved the real
      // conversation, but ChatNotifier has not received /chat/send response yet.
      // Keep the active pending row so sidebar selection does not flicker.
      fake.items = [_real('real-1', 'a1')];
      await n.refresh();
      var list = _list(c);
      expect(list.map((x) => x.conversationId), contains(pendingId));
      expect(list.map((x) => x.conversationId), isNot(contains('real-1')));
      expect(list.length, 1);
      expect(list.first.conversationId, pendingId);

      n.adoptPending(pendingId, 'real-1');
      list = _list(c);
      expect(list.map((x) => x.conversationId), isNot(contains(pendingId)));
      expect(list.first.conversationId, 'real-1');
    });

    test(
        'refresh reads active pending after list call to avoid stale overwrite',
        () async {
      final (c, n, fake) = await _boot(const []);
      addTearDown(c.dispose);

      final pendingId = pendingConversationFor('a1');
      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      c.read(activePendingConversationProvider.notifier).state = pendingId;

      final serverResult = Completer<List<ConversationItem>>();
      fake.listAllConversationsOverride = () => serverResult.future;
      final refreshFuture = n.refresh();

      // /chat/send returns while refresh is waiting for the server list:
      // ChatNotifier clears active pending and adopts the real conversation.
      c.read(activePendingConversationProvider.notifier).state = null;
      n.adoptPending(pendingId, 'real-1');
      expect(_list(c).first.conversationId, 'real-1');

      serverResult.complete([_real('real-1', 'a1')]);
      await refreshFuture;

      final list = _list(c);
      expect(list.length, 1);
      expect(list.first.conversationId, 'real-1');
      expect(list.map((x) => x.conversationId), isNot(contains(pendingId)));
    });

    test(
        'refresh preserves pending when server only has a group containing agent',
        () async {
      final (c, n, fake) = await _boot([_group('group-1', 'a1')]);
      addTearDown(c.dispose);

      n.ensurePendingAgent(pendingConversationItem(agentUuid: 'a1', name: '周'));
      await n.refresh();
      var list = _list(c);
      expect(list.map((x) => x.conversationId), contains('group-1'));
      expect(list.map((x) => x.conversationId),
          contains(pendingConversationFor('a1')));

      fake.items = [_group('group-1', 'a1'), _real('real-1', 'a1')];
      await n.refresh();
      list = _list(c);
      expect(list.map((x) => x.conversationId), contains('group-1'));
      expect(list.map((x) => x.conversationId), contains('real-1'));
      expect(list.where((x) => isPendingConversation(x.conversationId)).isEmpty,
          isTrue);
    });

    test(
        'clicking agent first then creating a group keeps both conversation rows',
        () async {
      final (c, n, fake) = await _boot(const []);
      addTearDown(c.dispose);

      n.ensurePendingAgent(pendingConversationItem(
          agentUuid: 'a1', name: '周芷涵', avatarUrl: 'http://x'));
      fake.items = [_group('group-1', 'a1')];
      await n.refresh();

      final list = _list(c);
      expect(list.map((x) => x.conversationId),
          contains(pendingConversationFor('a1')));
      expect(list.map((x) => x.conversationId), contains('group-1'));
    });

    test('cold-start list re-enriches avatar when agent profile loads',
        () async {
      final agentProfiles = Completer<List<AgentItem>>();
      final fake = _FakeChatService([
        ConversationItem.fromJson(const {
          'uuid': 'conv-1',
          'title': '个人助手',
          'agent_id': 'agent-1',
          'agent_name': '个人助手',
          'agent_avatar_url': '/portrait/default/nan.png',
          'avatar': '/portrait/default/nan.png',
          'kind': 'single',
        }),
      ])
        ..listAgentsOverride = () => agentProfiles.future;
      final container = ProviderContainer(
        overrides: [chatServiceProvider.overrideWith((ref) => fake)],
      );
      addTearDown(container.dispose);

      await container.read(conversationsProvider.future);
      expect(_list(container).single.convAvatar, isNull);

      agentProfiles.complete([
        const AgentItem(
          agentId: 'agent-1',
          name: '个人助手',
          description: '',
          avatarUrl: '/message-files/avatar-1/preview',
          status: 'active',
          isDefault: false,
          syncStatus: 'synced',
          lastSyncedAt: null,
        ),
      ]);
      await container.read(agentsProvider.future);
      await Future<void>.delayed(Duration.zero);

      final enriched = await container.read(conversationsProvider.future);
      expect(enriched.single.convAvatar, '/message-files/avatar-1/preview');
      expect(enriched.single.agentAvatarUrl, '/message-files/avatar-1/preview',
        );
      },
    );
    });
  }
