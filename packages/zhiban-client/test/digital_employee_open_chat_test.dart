import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_capability_chip_row.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_detail_header.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_empty_state.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_action_menu.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_actions.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// doc-13 §A 二次返修：点击数字员工打开单聊的回归测试。
/// 覆盖：默认选中不被第一条抢 / pending 不触发 getHistory(404) / 头像名覆盖 /
/// 空态无 OpenClaw / header 无「在线」/ 进入页不触发 legacy。

class _FakeSvc extends OpenClawChatService {
  _FakeSvc(this.items, {this.agents = const []});
  List<ConversationItem> items;
  final List<AgentItem> agents;
  List<ConversationItem> hiddenItems = const [];
  final List<String> getHistoryCalls = [];
  final List<String> legacyCalls = [];
  final List<String> markReadCalls = [];
  final List<String> showCalls = [];

  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async =>
      includeHidden ? [...items, ...hiddenItems] : items;

  @override
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async {
    getHistoryCalls.add(conversationId);
    return const [];
  }

  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {
    markReadCalls.add(conversationId);
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    items = items
        .where((item) => item.conversationId != conversationId)
        .toList(growable: false);
  }

  @override
  Future<void> showConversation(String conversationId) async {
    showCalls.add(conversationId);
    final found = hiddenItems
        .where((item) => item.conversationId == conversationId)
        .toList(growable: false);
    hiddenItems = hiddenItems
        .where((item) => item.conversationId != conversationId)
        .toList(growable: false);
    for (final item in found) {
      items = [
        item.copyWith(hidden: false),
        ...items.where((e) => e.conversationId != item.conversationId),
      ];
    }
  }

  // selectConversation → selectByConversationId 会读 agentsProvider(→ listAgents); 测试里返空, 不打网络。
  @override
  Future<List<AgentItem>> listAgents() async => agents;

  // 进入数字员工单聊**不得**触发这些 legacy `/app/openclaw-agent/*` 调用：记下即视为失败信号。
  @override
  Future<OpenClawInstanceState> bootstrapInstance() async {
    legacyCalls.add('bootstrapInstance');
    return const OpenClawInstanceState(
        instanceStatus: 'running',
        message: '',
        defaultAgentReady: true,
        gatewayReady: true);
  }

  @override
  Future<OpenClawInstanceState> getInstanceStatus() async {
    legacyCalls.add('getInstanceStatus');
    return const OpenClawInstanceState(
        instanceStatus: 'running',
        message: '',
        defaultAgentReady: true,
        gatewayReady: true);
  }
}

class _FakeImClient implements ImClient {
  final List<String> markReadCalls = [];

  @override
  String? get connectedUid => 'me';
  @override
  ImConnectionStatus get connectionStatus => ImConnectionStatus.connected;
  @override
  bool get isRealtimeConnected => true;
  @override
  Stream<ImConnectionStatus> listenConnectionStatus() => const Stream.empty();
  @override
  Future<void> init() async {}
  @override
  Future<void> login(ImConnInfo info) async {}
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> logout() async {}
  @override
  Future<List<ImConversation>> getConversationList() async => const [];
  @override
  Future<List<ImMessage>> getHistoryMessages(String channelId, int channelType,
          {int limit = 30,
          int beforeMessageSeq = 0,
          String? conversationUuid,
          String? clearedAt}) async =>
      const [];
  @override
  Future<void> sendTextMessage(String channelId, int channelType, String text,
      {List<Map<String, dynamic>>? mentions}) async {}
  @override
  Future<void> sendImageMessage(String channelId, int channelType,
      {required String url,
      required String fileUuid,
      String refUuid = '',
      String name = '',
      int width = 0,
      int height = 0}) async {}
  @override
  Future<void> sendFileMessage(String channelId, int channelType,
      {required String url,
      required String fileUuid,
      required String refUuid,
      required String name,
      int size = 0,
      String mime = ''}) async {}
  @override
  Future<void> sendMixedMessage(String channelId, int channelType,
      {required List<ImMessageBlock> blocks,
      String summary = '',
      List<Map<String, dynamic>>? mentions,
      Map<String, dynamic>? reply}) async {}
  @override
  Stream<ImMessage> listenMessages() => const Stream.empty();
  @override
  Stream<ImConversationEvent> listenConversationEvents() =>
      const Stream.empty();
  @override
  Future<int> unreadCount() async => 0;
  @override
  Future<void> markRead(String channelId, int channelType) async {
    markReadCalls.add('$channelId:$channelType');
  }

  @override
  Future<void> dispose() async {}
}

ConversationItem _conv(String id, String agentId,
    {String name = 'conv', String? avatar}) {
  return ConversationItem(
    conversationId: id,
    title: name,
    agentId: agentId,
    agentName: name,
    agentAvatarUrl: avatar,
    convAvatar: avatar,
    kind: 'single',
  );
}

AgentItem _agent(String id, String name, String avatar,
    {String positionLabel = '',
    String departmentName = '',
    String runtimeEnvironmentUuid = '',
    List<AgentSkillItem> skills = const [],
    List<AgentAppItem> apps = const [],
    bool supportsSkillBindings = true,
    bool canManageSkills = false,
    String welcomeMsg = ''}) {
  return AgentItem(
    agentId: id,
    name: name,
    description: '',
    avatarUrl: avatar,
    positionLabel: positionLabel,
    departmentName: departmentName,
    runtimeEnvironmentUuid: runtimeEnvironmentUuid,
    status: 'active',
    isDefault: false,
    syncStatus: 'synced',
    lastSyncedAt: null,
    skills: skills,
    apps: apps,
    supportsSkillBindings: supportsSkillBindings,
    canManageSkills: canManageSkills,
    welcomeMsg: welcomeMsg,
  );
}

ConversationItem _groupConv(String id, String agentId,
    {String name = '群聊', String channelId = 'ch-1', int unread = 0}) {
  return ConversationItem(
    conversationId: id,
    title: name,
    agentId: agentId, // 群里含该 agent → fromJson 会写 agentId(本 bug 根因)
    agentName: name,
    kind: 'group',
    roomUuid: 'room-$id',
    wukongChannelId: channelId,
    wukongChannelType: 2,
    unreadCount: unread,
  );
}

ConversationItem _humanDirectConv(String id,
    {String name = '同事', String channelId = 'hd-1', int unread = 0}) {
  return ConversationItem(
    conversationId: id,
    title: name,
    agentId: '',
    agentName: name,
    kind: 'human_direct',
    wukongChannelId: channelId,
    wukongChannelType: 2,
    unreadCount: unread,
  );
}

/// 假 catalog notifier:返回固定目录,避免测试触发 /contacts/agents 网络。
class _FakeCatalog extends DigitalEmployeeCatalogNotifier {
  _FakeCatalog(this._cat);
  final DigitalEmployeeCatalog _cat;
  @override
  Future<DigitalEmployeeCatalog> build() async => _cat;
}

const _emptyCatalog = DigitalEmployeeCatalog(personal: [], enterprise: []);

class _FakeContactsService extends ContactsService {
  const _FakeContactsService(this.visibleAgents);

  final List<AgentItem> visibleAgents;

  @override
  Future<ContactAgent> agent(String agentUuid, {bool silent = false}) async {
    for (final agent in visibleAgents) {
      if (agent.agentId == agentUuid) return ContactAgent.fromAgentItem(agent);
    }
    throw StateError('agent not found');
  }
}

/// 桩 ChatNotifier:只返初始态,不挂 conversations 监听/刷新 timer。
/// 侧栏 build 仅读 chatAsync.isLoading/hasValue/activeConversationId;group/human_direct
/// 分支也不调 chatProvider,所以桩足够,且避免列表变更触发一次性刷新 timer 残留。
class _FakeChat extends ChatNotifier {
  @override
  Future<ChatState> build() async => const ChatState.initial();
}

/// 最小化会话列表宿主(不 autoSelect,不带搜索头),只挂
/// [ChatConversationActionsMixin] + [ConversationListPanel],用于验证
/// 点击 group/human_direct 行后清未读 + 上报已读 + 设置对应选择态——
/// 对齐生产代码里 mobile_chat_page.dart 的 _MobileConversationList 形状。
class _TestConversationList extends ConsumerStatefulWidget {
  const _TestConversationList();

  @override
  ConsumerState<_TestConversationList> createState() =>
      _TestConversationListState();
}

class _TestConversationListState extends ConsumerState<_TestConversationList>
    with ChatConversationActionsMixin<_TestConversationList> {
  @override
  ValueChanged<String>? get onConversationTapped => null;

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final conversations =
        conversationsAsync.asData?.value ?? const <ConversationItem>[];
    return ConversationListPanel(
      selectedConversationId: null,
      conversations: conversations,
      loadingConversations: conversationsAsync.isLoading,
      onConversationSelected: selectConversation,
      menuCallbacks: ConversationMenuCallbacks(
        onTogglePin: togglePin,
        onToggleMute: toggleMute,
        onMarkRead: markConversationRead,
        onMarkUnread: markUnread,
        onHide: hideConversation,
        onRenameGroup: renameGroup,
      ),
    );
  }
}

/// 装一个真实会话列表(autoSelect 关掉,避免首屏自动选第一条干扰),
/// 用于验证点击 group/human_direct 行后清未读 + 上报已读 + 设置对应选择态。
Future<ProviderContainer> _bootSidebar(_FakeSvc fake,
    {_FakeImClient? im}) async {
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => fake),
    contactsServiceProvider
        .overrideWithValue(_FakeContactsService(fake.agents)),
    wukongImClientProvider.overrideWithValue(im ?? _FakeImClient()),
    digitalEmployeeCatalogProvider
        .overrideWith(() => _FakeCatalog(_emptyCatalog)),
    chatProvider.overrideWith(() => _FakeChat()),
  ]);
  await c.read(conversationsProvider.future);
  await c.read(chatProvider.future);
  return c;
}

Future<ProviderContainer> _boot(_FakeSvc fake,
    {DigitalEmployeeCatalog catalog = _emptyCatalog}) async {
  final visibleAgents = <String, AgentItem>{
    for (final agent in fake.agents) agent.agentId: agent,
    for (final item in catalog.all) item.agent.agentId: item.agent,
  }.values.toList(growable: false);
  final c = ProviderContainer(
    overrides: [
      chatServiceProvider.overrideWith((ref) => fake),
      contactsServiceProvider
          .overrideWithValue(_FakeContactsService(visibleAgents)),
      // selectedAgentOrFallbackProvider 现 watch catalog 补 skills/apps;测试里固定它,
      // 既避免网络又能按需注入 capability-rich 目录。
      digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog(catalog)),
    ],
  );
  await c.read(conversationsProvider.future);
  await c.read(chatProvider.future);
  await c.read(agentsProvider.future);
  await c.read(
      digitalEmployeeCatalogProvider.future); // 确保 catalog 已就绪(skills/apps 补齐)
  return c;
}

void main() {
  for (final locus in ['local', 'cloud']) {
    test(
        'conversation hydration preserves $locus execution and authoritative model selection',
        () async {
      final current = _agent('a1', '助手', '').copyWith(
          executionLocus: locus,
          supportsModelSelection: true,
          modelSource: 'byok',
          modelServiceModelId: 'bound-model');
      final stale = _agent('a1', '旧目录', '');
      for (final catalog in [
        _emptyCatalog,
        DigitalEmployeeCatalog(
            personal: [DigitalEmployeeCatalogItem.personal(stale)],
            enterprise: const [])
      ]) {
        final c = await _boot(
            _FakeSvc([_conv('conv-local', 'a1')], agents: [current]),
            catalog: catalog);
        await c.read(chatProvider.notifier).selectConversation('conv-local');
        final selected = c.read(selectedAgentOrFallbackProvider)!;
        expect(selected.executionLocus, locus);
        expect(selected.hasConversationModels, true);
        expect(selected.modelSource, 'byok');
        expect(selected.modelServiceModelId, 'bound-model');
        c.dispose();
      }
    });
  }

  test(
      'enterprise catalog preserves model capability without management ownership',
      () async {
    final rich = _agent('enterprise-agent', '企业助手', '').copyWith(
        supportsModelSelection: true,
        modelSource: 'byok',
        modelServiceModelId: 'bound-model');
    final c = await _boot(
        _FakeSvc([_conv('enterprise-chat', 'enterprise-agent')], agents: []),
        catalog: DigitalEmployeeCatalog(
            personal: [],
            enterprise: [DigitalEmployeeCatalogItem.personal(rich)]));
    addTearDown(c.dispose);
    await c.read(chatProvider.notifier).selectConversation('enterprise-chat');
    final selected = c.read(selectedAgentOrFallbackProvider)!;
    expect(selected.hasConversationModels, true);
    expect(selected.modelSource, 'byok');
    expect(selected.modelServiceModelId, 'bound-model');
  });

  group('open DE single-chat — provider behavior (doc-13 §A 二次返修)', () {
    test(
        'selecting a non-first conversation stays active (not stolen by first)',
        () async {
      final convA = _conv('conv-a', 'a1', name: '甲', avatar: 'a.png');
      final convT = _conv('conv-t', 'a2', name: '乙', avatar: 'b.png');
      final fake = _FakeSvc([convA, convT]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-t');
      expect(c.read(chatProvider).asData!.value.activeConversationId, 'conv-t');
    });

    test(
        'selectedAgentOrFallback returns active conversation agent, not conversations.first',
        () async {
      final convA = _conv('conv-a', 'a1', name: '甲', avatar: 'a.png');
      final convT = _conv('conv-t', 'a2', name: '乙', avatar: 'b.png');
      final fake = _FakeSvc([convA, convT]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-t');
      final agent = c.read(selectedAgentOrFallbackProvider);
      expect(agent?.agentId, 'a2'); // 目标会话的 agent, 不是 conversations.first(a1)
    });

    test('active conversation agent 从 /agents 补齐运行环境 UUID', () async {
      final fake = _FakeSvc(
        [_conv('conv-a', 'a1', name: '甲')],
        agents: [
          _agent(
            'a1',
            '甲',
            'a.png',
            runtimeEnvironmentUuid: 'runtime-a'
          ),
        ],
      );
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-a');
      expect(
        c.read(selectedAgentOrFallbackProvider)?.runtimeEnvironmentUuid,
        'runtime-a',
      );
    });

    test('active conversation agent 从 /agents 补齐配置欢迎语', () async {
      final fake = _FakeSvc(
        [_conv('conv-a', 'a1', name: '甲')],
        agents: [
          _agent(
            'a1',
            '甲',
            'a.png',
            welcomeMsg: '欢迎找我处理事务。'
          )
        ],
      );
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-a');
      expect(
        c.read(selectedAgentOrFallbackProvider)?.welcomeMsg,
        '欢迎找我处理事务。'
      );
    });

    test('/agents 空 skills 覆盖较旧目录缓存，移除后会话不再回填技能', () async {
      final staleCatalogAgent = _agent(
        'a1',
        '甲',
        'a.png',
        skills: [
          const AgentSkillItem(
            slug: 'removed-skill',
            skillName: '已移除技能',
            status: 'active',
            isInstalled: true,
            iconUrl: '',
          ),
        ],
      );
      final fake = _FakeSvc(
        [_conv('conv-a', 'a1', name: '甲')],
        agents: [_agent('a1', '甲', 'a.png', skills: const [])],
      );
      final c = await _boot(
        fake,
        catalog: DigitalEmployeeCatalog(
          personal: [DigitalEmployeeCatalogItem.personal(staleCatalogAgent)],
          enterprise: const [],
        ),
      );
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-a');
      expect(c.read(selectedAgentOrFallbackProvider)?.skills, isEmpty);
    });

    test(
        'opening a pending agent conversation does NOT call getHistory (no 404), even across refresh',
        () async {
      final fake = _FakeSvc(const []);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).upsertAgentConversation(
            agent: _agent('a1', '周芷涵', 'real.png'),
            conversationId: pendingConversationFor('a1'),
          );
      await c.read(chatProvider.notifier).selectConversation(
            pendingConversationFor('a1')
          );
      expect(
        c.read(chatProvider).asData!.value.activeConversationId,
        pendingConversationFor('a1'),
      );
      // refresh 触发 _maybeAppendIncoming —— 之前的 404 真凶在这里对 pending getHistory。
      await c.read(conversationsProvider.notifier).refresh();

      expect(
        fake.getHistoryCalls.where((id) => isPendingConversation(id)),
        isEmpty,
        reason: 'pending 会话不能拉历史(服务端无此会话→404)',
      );
      expect(fake.legacyCalls, isEmpty,
          reason: '进入数字员工单聊不得触发 legacy /app/openclaw-agent/*');
    });

    test('selecting an agent conversation clears stale group pane selection',
        () async {
      final fake = _FakeSvc(const []);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(selectedGroupProvider.notifier).state = const GroupSelection(
        conversationId: 'group-1',
        roomUuid: 'room-1',
        channelId: 'ch-1',
        channelType: 2,
        title: '旧群聊',
        participants: [],
      );

      await c.read(chatProvider.notifier).selectConversation(
            pendingConversationFor('a1')
          );

      expect(c.read(selectedGroupProvider), isNull);
      expect(
        c.read(chatProvider).asData!.value.activeConversationId,
        pendingConversationFor('a1'),
      );
    });

    test(
        'upsertAgentConversation overrides server robot avatar/name with current AgentItem',
        () async {
      final robot = _conv('conv-1', 'a1', name: '旧名', avatar: 'robot.png');
      final fake = _FakeSvc([robot]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).upsertAgentConversation(
            agent: _agent('a1', '周芷涵', 'real.png'),
            conversationId: 'conv-1',
          );
      final list = c.read(conversationsProvider).asData!.value;
      expect(list.first.conversationId, 'conv-1');
      expect(list.first.agentId, 'a1');
      expect(list.first.agentAvatarUrl, 'real.png');
      expect(list.first.convAvatar, 'real.png');
      expect(list.first.title, '周芷涵');
      expect(list.first.agentName, '周芷涵');
    });

    test(
        'upsertAgentConversation preserves existing avatar when agent has none',
        () async {
      final existing = _conv('conv-1', 'a1',
          name: '林知行',
          avatar: '/api/agent-bus/v1/assets/agent-avatars/lin.jpg');
      final fake = _FakeSvc([existing]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).upsertAgentConversation(
            agent: _agent('a1', '林知行', ''),
            conversationId: 'conv-1',
          );

      final item = c.read(conversationsProvider).asData!.value.first;
      expect(item.agentAvatarUrl,
          '/api/agent-bus/v1/assets/agent-avatars/lin.jpg');
      expect(item.convAvatar, '/api/agent-bus/v1/assets/agent-avatars/lin.jpg');
    });

    test(
        'upsertAgentConversation keeps only one row for the same digital employee',
        () async {
      final robot = _conv('old-1', 'a1', name: '你好啊', avatar: 'robot.png');
      final current = _conv('conv-1', 'a1', name: '旧名', avatar: 'old.png');
      final fake = _FakeSvc([robot, current]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).upsertAgentConversation(
            agent: _agent('a1', '许文博', 'real.png'),
            conversationId: 'conv-1',
          );
      final list = c.read(conversationsProvider).asData!.value;
      expect(list.where((e) => e.agentId == 'a1'), hasLength(1));
      expect(list.first.conversationId, 'conv-1');
      expect(list.first.title, '许文博');
      expect(list.first.agentAvatarUrl, 'real.png');
      expect(list.any((e) => e.title == '你好啊'), isFalse);
    });

    test(
        'refresh re-applies current selected agent avatar over server placeholder',
        () async {
      // server 返回机器人头像的 placeholder; selectedAgent 是真人头像。
      final robot = _conv('conv-1', 'a1', name: '旧名', avatar: 'robot.png');
      final fake = _FakeSvc([robot]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c
          .read(selectedAgentProvider.notifier)
          .select(_agent('a1', '周芷涵', 'real.png'));
      await c.read(conversationsProvider.notifier).refresh();
      final item = c
          .read(conversationsProvider)
          .asData!
          .value
          .firstWhere((e) => e.agentId == 'a1');
      expect(item.agentAvatarUrl, 'real.png'); // 不回退机器人头像
      expect(item.title, '周芷涵');
    });

    test('refresh enriches all agent rows from catalog, not only selected',
        () async {
      final fake = _FakeSvc([
        _conv('conv-1', 'a1', name: '旧周', avatar: 'robot.png'),
        _conv('conv-2', 'a2', name: '旧林', avatar: 'robot.png'),
      ]);
      final c = await _boot(
        fake,
        catalog: DigitalEmployeeCatalog(
          personal: [
            DigitalEmployeeCatalogItem.personal(
                _agent('a1', '周芷涵', 'zhou.png')),
            DigitalEmployeeCatalogItem.personal(_agent('a2', '林知行', 'lin.png')),
          ],
          enterprise: const [],
        ),
      );
      addTearDown(c.dispose);

      await c.read(conversationsProvider.notifier).refresh();
      final list = c.read(conversationsProvider).asData!.value;
      final zhou = list.firstWhere((e) => e.agentId == 'a1');
      final lin = list.firstWhere((e) => e.agentId == 'a2');
      expect(zhou.agentAvatarUrl, 'zhou.png');
      expect(zhou.convAvatar, 'zhou.png');
      expect(zhou.title, '周芷涵');
      expect(lin.agentAvatarUrl, 'lin.png');
      expect(lin.convAvatar, 'lin.png');
      expect(lin.title, '林知行');
    });

    test('deleting active agent conversation clears current chat', () async {
      final real = _conv('conv-1', 'a1', name: '周芷涵', avatar: 'real.png');
      final other = _conv('conv-2', 'a2', name: '李娜', avatar: 'lina.png');
      final fake = _FakeSvc([real, other]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      c.read(selectedAgentProvider.notifier).select(
            _agent('a1', '周芷涵', 'real.png')
          );
      await c.read(chatProvider.notifier).selectConversation('conv-1');

      await c.read(chatProvider.notifier).deleteConversation('conv-1');

      final activeId = c.read(chatProvider).asData!.value.activeConversationId;
      expect(activeId, isNull);
      final list = c.read(conversationsProvider).asData!.value;
      expect(list.any((item) => item.conversationId == 'conv-1'), isFalse);
      expect(list.any((item) => isPendingConversation(item.conversationId)),
          isFalse);
      expect(c.read(selectedAgentProvider).asData!.value, isNull);
    });
  });

  group('chat entry state fixes (Codex P2)', () {
    test(
        'isReusableAgentDirectConversation: 只认 agent 单聊, 排除群聊/人↔人/pending/异 agent',
        () {
      expect(
          isReusableAgentDirectConversation(_conv('c1', 'a1'), 'a1'), isTrue);
      // 含 a1 的群聊不算单聊(本 bug 根因)。
      expect(isReusableAgentDirectConversation(_groupConv('g1', 'a1'), 'a1'),
          isFalse);
      expect(isReusableAgentDirectConversation(_humanDirectConv('h1'), 'a1'),
          isFalse);
      expect(
          isReusableAgentDirectConversation(_conv('c1', 'a1'), 'a2'), isFalse);
      expect(
          isReusableAgentDirectConversation(
              _conv(pendingConversationFor('a1'), 'a1'), 'a1'),
          isFalse);
    });

    test('数字员工入口: 只有"含该 agent 的群聊" → 不复用群聊 id (走 pending)', () {
      // gallery/contacts 用同一 isReusableAgentDirectConversation 查找既有单聊。
      final list = <ConversationItem>[_groupConv('group-1', 'a1')];
      final reuse = list.cast<ConversationItem?>().firstWhere(
            (c) => isReusableAgentDirectConversation(c!, 'a1'),
            orElse: () => null,
          );
      expect(reuse, isNull); // 不复用群聊 → 入口改用 pending:a1, 左侧不高亮群聊
    });

    test('selectConversation(groupId) → 走群聊选择态, 不进入 agent chat 混合态', () async {
      final fake = _FakeSvc([_groupConv('group-1', 'a1')]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('group-1');
      expect(c.read(selectedGroupProvider)?.conversationId, 'group-1');
      expect(c.read(selectedHumanDirectProvider), isNull);
      // 不把 group id 当 agent chat 打开:active 不变成 group-1, 不拉历史。
      expect(c.read(chatProvider).asData!.value.activeConversationId,
          isNot('group-1'));
      expect(fake.getHistoryCalls, isEmpty);
    });

    test('回归: 选群聊不污染 selectedAgentProvider', () async {
      final fake = _FakeSvc([_groupConv('group-1', 'a1')]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('group-1');
      expect(c.read(selectedGroupProvider)?.conversationId, 'group-1');
      // group 分支提前 return, 不 selectByConversationId → 没把群里的 agent 设成单聊 selected。
      expect(c.read(selectedAgentProvider).asData?.value, isNull);
    });

    test('回归: selectConversation(humanDirectId) → 走人↔人选择态, 不拉 legacy',
        () async {
      final fake = _FakeSvc([_humanDirectConv('hd-1')]);
      final c = await _boot(fake);
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('hd-1');
      expect(c.read(selectedHumanDirectProvider)?.conversationId, 'hd-1');
      expect(c.read(selectedGroupProvider), isNull);
      expect(fake.getHistoryCalls, isEmpty);
    });

    test('从已有 agent 会话进入: selectedAgentOrFallback 用 catalog 补齐 skills/apps',
        () async {
      final fake = _FakeSvc([_conv('conv-a', 'a1', name: '陈启航')]);
      final rich = _agent('a1', '陈启航', '',
          runtimeEnvironmentUuid: 'runtime-a',
          skills: const [
            AgentSkillItem(
                slug: 's1',
                skillName: '合同风险检查',
                status: 'active',
                isInstalled: true,
                iconUrl: ''),
          ],
          apps: const [
            AgentAppItem(
                id: 'calendar', slug: 'calendar', name: '日程', iconUrl: ''),
          ]);
      final c = await _boot(fake,
          catalog: DigitalEmployeeCatalog(
            personal: [DigitalEmployeeCatalogItem.personal(rich)],
            enterprise: const [],
          ));
      addTearDown(c.dispose);

      await c.read(chatProvider.notifier).selectConversation('conv-a');
      final agent = c.read(selectedAgentOrFallbackProvider);
      expect(agent?.agentId, 'a1');
      expect(agent?.runtimeEnvironmentUuid, 'runtime-a');
      expect(agent?.skills.map((e) => e.skillName), contains('合同风险检查'));
      expect(agent?.apps.map((e) => e.name), contains('日程'));
    });
  });

  group('right-side subject follows active conversation (stale selected)', () {
    ConversationItem singleConv(String id, String agentId, String name,
        {String pos = '', String dept = ''}) {
      return ConversationItem(
        conversationId: id,
        title: name,
        agentId: agentId,
        agentName: name,
        agentPositionLabel: pos,
        agentDepartmentName: dept,
        kind: 'single',
      );
    }

    AgentSkillItem skill(String n) => AgentSkillItem(
        slug: n,
        skillName: n,
        status: 'active',
        isInstalled: true,
        iconUrl: '');
    AgentAppItem app(String n) =>
        AgentAppItem(id: n, slug: n, name: n, iconUrl: '');

    // 两个数字员工:陈启航(a1, 销售) / 许文博(a2, 法务),catalog 各带不同 skills/apps;
    // `/contacts/agents` 转成的 catalog AgentItem 没有技能管理权限字段，`/agents`
    // 才是 canManageSkills / supportsSkillBindings 的权威来源。切换 active 会话后必须合并两者。
    Future<ProviderContainer> bootStaleSelected() async {
      final a1 = _agent('a1', '陈启航', 'chen.png',
          positionLabel: '销售顾问',
          departmentName: '销售部',
          skills: [skill('销售话术生成')],
          apps: [app('日程')]);
      final a2 = _agent('a2', '许文博', 'xu.png',
          positionLabel: '法务顾问',
          departmentName: '法务部',
          skills: [skill('合同风险检查')],
          apps: [app('问卷调查')],
          canManageSkills: true);
      final fake = _FakeSvc(
        [
          singleConv('conv-chen', 'a1', '陈启航', pos: '销售顾问', dept: '销售部'),
          singleConv('conv-xu', 'a2', '许文博', pos: '法务顾问', dept: '法务部'),
        ],
        agents: [a1, a2],
      );
      final c = await _boot(fake,
          catalog: DigitalEmployeeCatalog(
            personal: [
              DigitalEmployeeCatalogItem.personal(a1),
              // 模拟 ContactAgent.toAgentItem：目录对象没有 /agents 权限字段。
              DigitalEmployeeCatalogItem.personal(
                a2.copyWith(canManageSkills: false),
              ),
            ],
            enterprise: const [],
          ));
      c.read(selectedAgentProvider.notifier).select(a1); // 旧 selected = 陈启航
      return c;
    }

    test(
        'stale selected(a1) 不覆盖 active conversation(a2): agent/skills/apps 取 a2',
        () async {
      final c = await bootStaleSelected();
      addTearDown(c.dispose);
      await c.read(chatProvider.notifier).selectConversation('conv-xu');
      final agent = c.read(selectedAgentOrFallbackProvider);
      expect(agent?.agentId, 'a2');
      expect(agent?.name, '许文博');
      expect(agent?.skills.map((e) => e.skillName), contains('合同风险检查'));
      expect(agent?.skills.map((e) => e.skillName), isNot(contains('销售话术生成')));
      expect(agent?.apps.map((e) => e.name), contains('问卷调查'));
      expect(agent?.apps.map((e) => e.name), isNot(contains('日程')));
    });

    test('header 主语跟随 active: name/部门/职位 取 a2', () async {
      final c = await bootStaleSelected();
      addTearDown(c.dispose);
      await c.read(chatProvider.notifier).selectConversation('conv-xu');
      final agent = c.read(selectedAgentOrFallbackProvider);
      expect(agent?.name, '许文博');
      expect(agent?.departmentName, '法务部');
      expect(agent?.positionLabel, '法务顾问');
    });

    test('active 会话缺部门职位时,同 agent catalog 补齐 header 元数据', () async {
      final fake = _FakeSvc([
        singleConv('conv-zhou', 'a3', '周芷涵')
      ]);
      final stale = _agent('a1', '陈启航', 'chen.png',
          positionLabel: '销售顾问', departmentName: '销售部');
      final richZhou = _agent('a3', '周芷涵', 'zhou.png',
          positionLabel: '数字员工', departmentName: '主管');
      final c = await _boot(fake,
          catalog: DigitalEmployeeCatalog(
            personal: [DigitalEmployeeCatalogItem.personal(richZhou)],
            enterprise: const [],
          ));
      addTearDown(c.dispose);
      c.read(selectedAgentProvider.notifier).select(stale);

      await c.read(chatProvider.notifier).selectConversation('conv-zhou');
      final agent = c.read(selectedAgentOrFallbackProvider);
      expect(agent?.agentId, 'a3');
      expect(agent?.name, '周芷涵');
      expect(agent?.departmentName, '主管');
      expect(agent?.positionLabel, '数字员工');
      expect(agent?.departmentName, isNot('销售部'));
      expect(agent?.positionLabel, isNot('销售顾问'));
    });

    testWidgets('ChatDetailHeader 显示许文博, 不停留陈启航', (tester) async {
      final c = await bootStaleSelected();
      addTearDown(c.dispose);
      await c.read(chatProvider.notifier).selectConversation('conv-xu');
      final agent = c.read(selectedAgentOrFallbackProvider);
      await tester.pumpWidget(ProviderScope(
        overrides: [selectedAgentOrFallbackProvider.overrideWithValue(agent)],
        child: const MaterialApp(
            home: Scaffold(body: ChatDetailHeader(title: '许文博'))),
      ));
      await tester.pump();
      expect(find.text('许文博'), findsOneWidget);
      expect(find.text('陈启航'), findsNothing);
      expect(find.text('法务部 · 法务顾问'), findsOneWidget);
    });

    testWidgets('已删除数字员工顶部展示删除状态且运行位置使用禁用灰', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAgentOrFallbackProvider.overrideWithValue(
              _agent('a2', '许文博', 'xu.png').copyWith(executionLocus: 'local'),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ChatDetailHeader(
                title: '许文博',
                agentDeleted: true
              ),
            ),
          ),
        ),
      );

      expect(find.text('许文博'), findsOneWidget);
      expect(find.text('本地'), findsOneWidget);
      expect(find.text('已删除'), findsOneWidget);
      expect(find.text('离线'), findsNothing);

      final context = tester.element(find.byType(ChatDetailHeader));
      final colors = Theme.of(context).colorScheme;
      final computer = tester.widget<Icon>(
        find.byIcon(CupertinoIcons.desktopcomputer),
      );
      expect(
        computer.color,
        colors.onSurfaceVariant.withValues(alpha: 0.55)
      );
      final locusLabel = tester.widget<Text>(find.text('本地'));
      expect(locusLabel.style?.color, colors.onSurfaceVariant);
    });

    test('chips 跟随 active: 只用 a2 的 skills/apps', () async {
      final c = await bootStaleSelected();
      addTearDown(c.dispose);
      await c.read(chatProvider.notifier).selectConversation('conv-xu');
      final agent = c.read(selectedAgentOrFallbackProvider)!;
      expect(agent.skills.single.skillName, '合同风险检查');
      expect(agent.apps.single.name, '问卷调查');
      expect(agent.supportsSkillBindings, isTrue);
      expect(agent.canManageSkills, isTrue);
    });

    test('group pane 接管时不被旧 selected(a1) 污染 → provider 返回 null', () async {
      final c = await bootStaleSelected(); // selected = a1
      addTearDown(c.dispose);
      c.read(selectedGroupProvider.notifier).state = const GroupSelection(
        conversationId: 'group-1',
        roomUuid: 'r',
        channelId: 'ch',
        channelType: 2,
        title: '群',
        participants: [],
      );
      expect(c.read(selectedAgentOrFallbackProvider), isNull);
    });

    test('human direct pane 接管时不被旧 selected(a1) 污染 → provider 返回 null',
        () async {
      final c = await bootStaleSelected(); // selected = a1
      addTearDown(c.dispose);
      c.read(selectedHumanDirectProvider.notifier).state =
          const HumanDirectSelection(
        conversationId: 'hd-1',
        roomUuid: 'room-hd-1',
        peerAccountUuid: 'peer-hd-1',
        channelId: 'ch',
        channelType: 2,
        title: '同事',
      );
      expect(c.read(selectedAgentOrFallbackProvider), isNull);
    });

    test('sidebar 高亮优先级跟右侧 pane 一致:human direct 优先于 stale group', () {
      final selected = resolveSidebarSelectedConversationId(
        highlightActive: true,
        selectedGroup: const GroupSelection(
          conversationId: 'group-1',
          roomUuid: 'r',
          channelId: 'g',
          channelType: 2,
          title: '群',
          participants: [],
        ),
        selectedHumanDirect: const HumanDirectSelection(
          conversationId: 'hd-1',
          roomUuid: 'room-hd-1',
          peerAccountUuid: 'peer-hd-1',
          channelId: 'h',
          channelType: 2,
          title: '李娜',
        ),
        activeConversationId: 'group-1',
      );
      expect(selected, 'hd-1');
    });
  });

  group('open DE single-chat — widgets (doc-13 §A 二次返修)', () {
    test('welcome resolver prefers configured text and falls back with name',
        () {
      expect(
        digitalEmployeeWelcomeMessage(
          _agent('a1', '创业助手', '', welcomeMsg: '  欢迎来到创业空间。  '),
        ),
        '欢迎来到创业空间。',
      );
      expect(
        digitalEmployeeWelcomeMessage(_agent('a1', '创业助手', '')),
        '你好，我是你的得力小帮手-创业助手，繁琐事务我来承接，让工作轻松一点。',
      );
    });

    testWidgets('empty agent chat renders default greeting, not welcome cards',
        (tester) async {
      final greeting = digitalEmployeeWelcomeMessage(_agent('a1', '创业助手', ''));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 640,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'pending:a1',
                ),
                controller: RichPromptController(),
                focusNode: FocusNode(),
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
                emptyStateMessage: greeting,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(greeting), findsOneWidget);
      expect(find.textContaining('开始和'), findsNothing);
      expect(find.textContaining('了解能力'), findsNothing);
      expect(find.textContaining('交给'), findsNothing);
      expect(find.textContaining('OpenClaw'), findsNothing);
    });

    testWidgets('已删除数字员工以只读说明条替换整套输入区', (tester) async {
      var sendCount = 0;
      final focusNode = FocusNode();
      final controller = RichPromptController();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      controller.text = '不应展示的草稿';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 640,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-deleted',
                ),
                composerEnabled: false,
                controller: controller,
                focusNode: focusNode,
                runtimeControls: const Text('运行配置'),
                runtimeApprovals: const Text('审批请求'),
                agentSkills: const [
                  AgentSkillItem(
                    slug: 'contract-risk',
                    skillName: '合同风险检查',
                    status: 'active',
                    isInstalled: true,
                  ),
                ],
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) => sendCount++,
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('该数字员工已删除，无法继续发送消息'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(AgentCapabilityChipRow), findsNothing);
      expect(find.text('运行配置'), findsNothing);
      expect(find.text('审批请求'), findsNothing);
      expect(find.text('合同风险检查'), findsNothing);
      expect(find.text('不应展示的草稿'), findsNothing);
      expect(focusNode.hasFocus, isFalse);
      expect(sendCount, 0);
    });

    testWidgets('ChatDetailHeader does NOT show 在线 online label',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAgentOrFallbackProvider.overrideWithValue(
              _agent('a1', '周芷涵', 'real.png', positionLabel: '法务助理'),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ChatDetailHeader(title: '对话')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('在线'), findsNothing);
      expect(find.text('周芷涵'), findsOneWidget);
    });

    testWidgets('agent capability row renders only current agent skills/apps',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: const [
                AgentSkillItem(
                  slug: 'contract-risk',
                  skillName: '合同风险检查',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
              ],
              apps: const [
                AgentAppItem(
                  id: 'calendar',
                  slug: 'calendar',
                  name: '日程',
                  iconUrl: '',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('合同风险检查'), findsOneWidget);
      expect(find.text('日程'), findsOneWidget);
      expect(find.text('高德地图工具'), findsNothing);
      expect(find.text('邮件智能处理'), findsNothing);
    });

    testWidgets('agent capability row uses bound skill and app iconUrl',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: const [
                AgentSkillItem(
                  slug: 'contract-risk',
                  skillName: '合同风险检查',
                  status: 'active',
                  isInstalled: true,
                  iconUrl:
                      '/api/agent-bus/v1/assets/app-icons/zhiban-demo-schedule.png',
                ),
              ],
              apps: const [
                AgentAppItem(
                  id: 'calendar',
                  slug: 'calendar',
                  name: '日程',
                  iconUrl:
                      '/api/agent-bus/v1/assets/app-icons/zhiban-demo-survey.png',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final icons = tester.widgetList<UiNetworkImage>(
        find.byType(UiNetworkImage),
      );
      expect(icons, hasLength(2));
      expect(
        icons.map((image) => image.imageUrl),
        containsAll(<String>[
          'http://localhost:8080/api/agent-bus/v1/assets/app-icons/zhiban-demo-schedule.png',
          'http://localhost:8080/api/agent-bus/v1/assets/app-icons/zhiban-demo-survey.png',
        ]),
      );
    });

    testWidgets(
        'agent capability row caps inline chips and opens overflow menu',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: const [
                AgentSkillItem(
                  slug: 's1',
                  skillName: '技能一',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
                AgentSkillItem(
                  slug: 's2',
                  skillName: '技能二',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
                AgentSkillItem(
                  slug: 's3',
                  skillName: '技能三',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
                AgentSkillItem(
                  slug: 's4',
                  skillName: '客户拜访纪要与下一步跟进建议自动生成和复盘',
                  status: 'active',
                  isInstalled: true,
                  iconUrl:
                      '/api/agent-bus/v1/assets/app-icons/zhiban-demo-schedule.png',
                ),
              ],
              apps: const [
                AgentAppItem(id: 'a1', slug: 'a1', name: '应用一', iconUrl: ''),
                AgentAppItem(id: 'a2', slug: 'a2', name: '应用二', iconUrl: ''),
                AgentAppItem(id: 'a3', slug: 'a3', name: '应用三', iconUrl: ''),
                AgentAppItem(id: 'a4', slug: 'a4', name: '应用四', iconUrl: ''),
              ],
            ),
          ),
        ),
      );

      expect(find.text('技能一'), findsOneWidget);
      expect(find.text('技能三'), findsOneWidget);
      expect(find.text('客户拜访纪要与下一步跟进建议自动生成和复盘'), findsNothing);
      expect(find.text('更多技能'), findsOneWidget);
      expect(find.text('应用四'), findsNothing);
      expect(find.text('更多应用'), findsOneWidget);

      await tester.tap(find.text('更多技能'));
      await tester.pump();
      expect(find.text('客户拜访纪要与下一步跟进建议自动生成和复盘'), findsOneWidget);
      final popoverSize = tester
          .getSize(find.byKey(const ValueKey('agent_capability_popover')));
      expect(popoverSize.width, inInclusiveRange(236, 420));
      final menuIcons = tester.widgetList<UiNetworkImage>(
        find.descendant(
          of: find.byKey(const ValueKey('agent_capability_popover')),
          matching: find.byType(UiNetworkImage),
        ),
      );
      expect(
        menuIcons.map((image) => image.imageUrl),
        contains(
          'http://localhost:8080/api/agent-bus/v1/assets/app-icons/zhiban-demo-schedule.png',
        ),
      );
    });

    testWidgets(
        'non-ZAP row always shows more skills and hover lists all skills',
        (tester) async {
      var addCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: const [
                AgentSkillItem(
                  slug: 's1',
                  skillName: '技能一',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
              ],
              apps: const [],
              onAddSkill: () => addCount++,
            ),
          ),
        ),
      );

      expect(find.text('更多技能'), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.text('更多技能')));
      await tester.pump();

      final popover = find.byKey(const ValueKey('agent_capability_popover'));
      expect(popover, findsOneWidget);
      expect(
        find.descendant(of: popover, matching: find.text('技能一')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: popover, matching: find.text('添加技能')),
        findsOneWidget,
      );
      final skillText = tester.widget<Text>(find.descendant(
        of: popover,
        matching: find.text('技能一')),
      );
      final addText = tester.widget<Text>(find.descendant(
        of: popover,
        matching: find.text('添加技能')),
      );
      expect(skillText.style?.fontSize, 14);
      expect(addText.style?.fontSize, 14);
      final decoration =
          tester.widget<Container>(popover).decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(10));

      await tester.tap(find.descendant(
        of: popover,
        matching: find.text('添加技能')),
      );
      await tester.pump();
      expect(addCount, 1);
    });

    testWidgets('non-owner can browse skills but cannot add', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: [],
              apps: []
            ),
          ),
        ),
      );

      await tester.tap(find.text('更多技能'));
      await tester.pump();
      expect(find.text('暂无关联技能'), findsOneWidget);
      expect(find.text('添加技能'), findsNothing);
    });

    testWidgets('ZAP row does not show more skills', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: [
                AgentSkillItem(
                  slug: 's1',
                  skillName: '技能一',
                  status: 'active',
                  isInstalled: true,
                  iconUrl: '',
                ),
              ],
              apps: [],
              supportsSkillBindings: false,
            ),
          ),
        ),
      );

      expect(find.text('技能一'), findsOneWidget);
      expect(find.text('更多技能'), findsNothing);
    });

    testWidgets('support builtin with no capabilities hides the entire row',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AgentCapabilityChipRow(
              skills: [],
              apps: [],
              supportsSkillBindings: false,
            ),
          ),
        ),
      );

      expect(find.text('更多技能'), findsNothing);
      expect(find.text('暂无关联技能'), findsNothing);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('agent capability row reserves space after agent data loads',
        (tester) async {
      final messages = List<ChatMessage>.generate(
        6,
        (i) => ChatMessage(
          messageId: 'a$i',
          role: ChatRole.answer,
          content: '',
          status: BubbleStatus.error,
        ),
      );
      // workspace/sessions 模型：消息按会话分区构造（契约 C1）。
      final state = ChatWorkspaceState(
        activeConversationId: 'conv-a',
        sessions: {
          'conv-a':
              ChatSessionState(conversationId: 'conv-a', messages: messages),
        },
      );

      Widget build({required bool withCapabilities}) {
        return MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 620,
              child: ChatSessionView(
                state: state,
                agentSkills: withCapabilities
                    ? const [
                        AgentSkillItem(
                          slug: 's1',
                          skillName: '合同风险检查',
                          status: 'active',
                          isInstalled: true,
                          iconUrl: '',
                        ),
                        AgentSkillItem(
                          slug: 's2',
                          skillName: '周报自动整理',
                          status: 'active',
                          isInstalled: true,
                          iconUrl: '',
                        ),
                      ]
                    : const [],
                agentApps: withCapabilities
                    ? const [
                        AgentAppItem(
                          id: 'calendar',
                          slug: 'calendar',
                          name: '日程',
                          iconUrl: '',
                        ),
                      ]
                    : const [],
                controller: RichPromptController(),
                focusNode: FocusNode(),
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(build(withCapabilities: false));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(build(withCapabilities: true));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      final lastErrorBottom = tester.getBottomLeft(find.text('出错').last).dy;
      final capabilityTop = tester.getTopLeft(find.text('合同风险检查')).dy;
      expect(lastErrorBottom, lessThan(capabilityTop));
    });

    testWidgets('tapping an inline skill selects it as a skill tag',
        (tester) async {
      String? sentText;
      List<String>? sentSkillSlugs;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                agentSkills: const [
                  AgentSkillItem(
                    slug: 'sales-copy',
                    skillName: '销售话术生成',
                    status: 'active',
                    isInstalled: true,
                    iconUrl:
                        '/api/agent-bus/v1/assets/skill-icons/sales-copy.png',
                  ),
                ],
                agentApps: const [
                  AgentAppItem(
                    id: 'calendar',
                    slug: 'calendar',
                    name: '日程',
                    iconUrl: '',
                  ),
                ],
                controller: RichPromptController(),
                focusNode: FocusNode(),
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (text, skillSlugs) {
                  sentText = text;
                  sentSkillSlugs = skillSlugs;
                },
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('销售话术生成'));
      await tester.pump();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, isEmpty);
      expect(find.text('销售话术生成'), findsNWidgets(2));
      expect(
        tester
            .widgetList<UiNetworkImage>(find.byType(UiNetworkImage))
            .where((image) => image.imageUrl.endsWith('/sales-copy.png')),
        hasLength(2),
      );

      await tester.enterText(find.byType(TextField), '帮我写');
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.paperplane_fill));
      await tester.pump();

      expect(sentText, '帮我写');
      expect(sentSkillSlugs, ['sales-copy']);
    });

    testWidgets('tapping an overflow skill selects it and closes menu',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                agentSkills: const [
                  AgentSkillItem(
                    slug: 's1',
                    skillName: '技能一',
                    status: 'active',
                    isInstalled: true,
                    iconUrl: '',
                  ),
                  AgentSkillItem(
                    slug: 's2',
                    skillName: '技能二',
                    status: 'active',
                    isInstalled: true,
                    iconUrl: '',
                  ),
                  AgentSkillItem(
                    slug: 's3',
                    skillName: '技能三',
                    status: 'active',
                    isInstalled: true,
                    iconUrl: '',
                  ),
                  AgentSkillItem(
                    slug: 's4',
                    skillName: '技能四',
                    status: 'active',
                    isInstalled: true,
                    iconUrl: '',
                  ),
                ],
                controller: RichPromptController(),
                focusNode: FocusNode(),
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('技能四'), findsNothing);
      await tester.tap(find.text('更多技能'));
      await tester.pump();
      expect(find.text('技能四'), findsOneWidget);

      await tester.tap(find.text('技能四'));
      await tester.pump();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, isEmpty);
      expect(find.text('技能四'), findsOneWidget);
    });

    testWidgets('tapping an app capability launches app without editing input',
        (tester) async {
      AgentAppItem? launchedApp;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                agentApps: const [
                  AgentAppItem(
                    id: 'calendar',
                    slug: 'calendar',
                    name: '日程',
                    iconUrl: '',
                  ),
                ],
                controller: RichPromptController(),
                focusNode: FocusNode(),
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onLaunchApp: (app, _) => launchedApp = app,
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('日程'));
      await tester.pump();

      expect(launchedApp?.id, 'calendar');
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, isEmpty);
    });

    testWidgets('ChatDetailHeader subtitle renders 部门 · 职位 when both set',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAgentOrFallbackProvider.overrideWithValue(
              _agent('a1', '许文博', 'real.png',
                  positionLabel: '知识库问答顾问', departmentName: '技术部'),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ChatDetailHeader(title: '对话')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('许文博'), findsOneWidget);
      expect(find.text('技术部 · 知识库问答顾问'), findsOneWidget);
      expect(find.text('在线'), findsNothing);
    });

    testWidgets(
        'ChatDetailHeader subtitle falls back to 部门 only when 职位 missing',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAgentOrFallbackProvider.overrideWithValue(
              _agent('a1', '许文博', 'real.png', departmentName: '技术部'),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ChatDetailHeader(title: '对话')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('技术部'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });
  });

  group('点击 group / human_direct 清未读(会话列表未读/已读修复)', () {
    Widget buildSidebar(ProviderContainer c) => UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                height: 640,
                child: _TestConversationList(),
              ),
            ),
          ),
        );

    testWidgets('已删除数字员工的左侧会话行不展示删除标签', (tester) async {
      final fake = _FakeSvc([
        const ConversationItem(
          conversationId: 'conv-deleted',
          title: '许文博',
          agentId: 'agent-xu',
          agentName: '许文博',
          agentAvatarUrl: 'xu.png',
          agentDeleted: true,
          kind: 'single',
        ),
      ]);
      final c = await _bootSidebar(fake);

      await tester.pumpWidget(buildSidebar(c));
      await tester.pumpAndSettle();

      expect(find.text('许文博'), findsOneWidget);
      expect(find.text('已删除'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });

    testWidgets('点击 group 会话 → 本地未读清零 + 上报已读 + 设 selectedGroupProvider',
        (tester) async {
      final fake = _FakeSvc([_groupConv('group-1', 'a1', unread: 3)]);
      final im = _FakeImClient();
      final c = await _bootSidebar(fake, im: im);

      await tester.pumpWidget(buildSidebar(c));
      await tester.pumpAndSettle();

      expect(find.text('群聊'), findsOneWidget);
      await tester.tap(find.text('群聊'));
      await tester
          .pump(const Duration(milliseconds: 200)); // 让行点击 180ms 释放 timer 触发完
      await tester.pump();

      // 仍走 GroupChatPane 选择态(不回退 legacy agent chat)。
      expect(c.read(selectedGroupProvider)?.conversationId, 'group-1');
      expect(c.read(selectedHumanDirectProvider), isNull);
      // 左侧本地 badge 即时清零。
      final item = c
          .read(conversationsProvider)
          .asData!
          .value
          .firstWhere((e) => e.conversationId == 'group-1');
      expect(item.unreadCount, 0);
      // 上报 Bus 已读一次。
      expect(fake.markReadCalls, contains('group-1'));
      // 上报 WuKong channel 已读一次,否则下次 conversations refresh 会把 unread 拉回来。
      expect(im.markReadCalls, contains('ch-1:2'));
      // 不污染 legacy:active 不变成 group id,不拉历史。
      expect(c.read(chatProvider).asData!.value.activeConversationId,
          isNot('group-1'));
      expect(fake.getHistoryCalls, isEmpty);

      // 收尾:卸载侧栏并 dispose 容器,取消 chatProvider 监听 conversations 变更后
      // 排的一次性刷新 timer(否则 end-of-body !timersPending 断言失败)。
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });

    testWidgets(
        '点击 human_direct 会话 → 本地未读清零 + 上报已读 + 设 selectedHumanDirectProvider',
        (tester) async {
      final fake = _FakeSvc([_humanDirectConv('hd-1', unread: 2)]);
      final im = _FakeImClient();
      final c = await _bootSidebar(fake, im: im);

      await tester.pumpWidget(buildSidebar(c));
      await tester.pumpAndSettle();

      expect(find.text('同事'), findsOneWidget);
      await tester.tap(find.text('同事'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(c.read(selectedHumanDirectProvider)?.conversationId, 'hd-1');
      expect(c.read(selectedGroupProvider), isNull);
      final item = c
          .read(conversationsProvider)
          .asData!
          .value
          .firstWhere((e) => e.conversationId == 'hd-1');
      expect(item.unreadCount, 0);
      expect(fake.markReadCalls, contains('hd-1'));
      expect(im.markReadCalls, contains('hd-1:2'));
      expect(c.read(chatProvider).asData!.value.activeConversationId,
          isNot('hd-1'));
      expect(fake.getHistoryCalls, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  });
}
