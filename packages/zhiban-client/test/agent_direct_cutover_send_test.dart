import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/services/conversation_models.dart';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_dual_channel.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';

/// ChatNotifier.send() 的 agent-direct cutover **接线**测试:经 debugAgentDirectSendOverride 注入
/// streamReady / fallback / failed,验证分支(不双跑、fallback 旧 /chat/send、失败提示)。
/// 双通道**决策逻辑**由 agent_direct_dual_channel_test.dart 覆盖;此处只测 send() 的接线。

class _SendFakeSvc extends OpenClawChatService {
  int sendMessageCalls = 0;
  int sendRoomMessageCalls = 0;
  int listConversationCalls = 0;
  int listAgentCalls = 0;
  final List<String> streamIds = [];
  final List<String> stopCalls = [];
  List<ChatFileItem> lastFiles = const [];
  List<ImMessageBlock> lastBlocks = const [];
  String lastPrompt = '';
  String lastRoomUuid = '';
  String? lastModelHint;
  Object? sendMessageError;
  List<ChatMessage> history = const [];

  @override
  Future<List<ConversationItem>> listAllConversations(
      {int page = 1, int pageSize = 40, bool includeHidden = false}) async {
    listConversationCalls++;
    return const [];
  }

  @override
  Future<List<AgentItem>> listAgents() async {
    listAgentCalls++;
    return const [];
  }

  @override
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async =>
      history;
  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}
  @override
  Future<OpenClawInstanceState> bootstrapInstance() async =>
      const OpenClawInstanceState(
          instanceStatus: 'running',
          message: '',
          defaultAgentReady: true,
          gatewayReady: true);
  @override
  Future<OpenClawInstanceState> getInstanceStatus() async =>
      const OpenClawInstanceState(
          instanceStatus: 'running',
          message: '',
          defaultAgentReady: true,
          gatewayReady: true);

  @override
  Future<SendMessageResponse> sendMessage({
    String? modelHint,
    String? localDeviceId,
    String? localContextId,
    String? conversationId,
    String? agentUuid,
    required String prompt,
    List<ChatFileItem> files = const [],
    List<String> skillSlugs = const [],
    List<ImMessageBlock> blocks = const [],
  }) async {
    sendMessageCalls++;
    final error = sendMessageError;
    if (error != null) throw error;
    lastPrompt = prompt;
    lastFiles = files;
    lastBlocks = blocks;
    return const SendMessageResponse(
      messageId: 'old-am',
      streamId: 'old-stream',
      conversationId: 'old-conv',
      status: '',
      agentId: '',
    );
  }

  @override
  Future<SendMessageResponse> sendRoomMessage({
    String? modelHint,
    List<ImMessageBlock> blocks = const [],
    required String roomUuid,
    required String prompt,
    List<ChatFileItem> files = const [],
  }) async {
    sendRoomMessageCalls++;
    lastModelHint = modelHint;
    lastBlocks = blocks;
    lastRoomUuid = roomUuid;
    lastPrompt = prompt;
    lastFiles = files;
    return const SendMessageResponse(
      messageId: '',
      streamId: 'room-stream',
      conversationId: 'conv-room-backed',
      status: '',
      agentId: '',
      userMessageUuid: 'room-user-message',
    );
  }

  @override
  Future<void> streamMessage({
    required String streamId,
    required Future<void> Function(Map<String, dynamic> json) onEvent,
    required Future<void> Function() onDone,
    ChatStreamCancelHandle? cancelHandle,
  }) async {
    streamIds.add(streamId);
    await onDone();
  }

  @override
  Future<void> stopMessage({required String messageId}) async {
    stopCalls.add(messageId);
  }
}

class _FakeImClient implements ImClient {
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
  Future<void> markRead(String channelId, int channelType) async {}
  @override
  Future<void> dispose() async {}
}

class _FakeCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() async =>
      const DigitalEmployeeCatalog(personal: [], enterprise: []);
}

AgentItem _agent(String id) => AgentItem(
      agentId: id,
      name: '数字员工',
      description: '',
      avatarUrl: '',
      positionLabel: '',
      departmentName: '',
      status: 'active',
      isDefault: false,
      syncStatus: 'synced',
      lastSyncedAt: null,
      skills: const [],
      apps: const [],
    );

Future<ProviderContainer> _bootSendable(_SendFakeSvc fake) async {
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => fake),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
    wukongImClientProvider.overrideWithValue(_FakeImClient()),
  ]);
  await c.read(conversationsProvider.future);
  await c.read(chatProvider.future);
  c.read(conversationsProvider.notifier).upsertAgentConversation(
        agent: _agent('a1'),
        conversationId: pendingConversationFor('a1'),
      );
  await c.read(chatProvider.notifier).selectConversation(
        pendingConversationFor('a1')
      );
  return c;
}

Future<ProviderContainer> _bootExistingRoomBackedAgentDirect(
    _SendFakeSvc fake) async {
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => fake),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
    wukongImClientProvider.overrideWithValue(_FakeImClient()),
  ]);
  await c.read(conversationsProvider.future);
  await c.read(chatProvider.future);
  c.read(conversationsProvider.notifier).state = const AsyncData([
    ConversationItem(
      conversationId: 'conv-room-backed',
      title: '周芷涵',
      agentId: 'a1',
      agentName: '周芷涵',
      kind: 'agent_direct',
      roomUuid: 'room-1',
      wukongChannelId: 't_1_d_room_1',
      wukongChannelType: 2,
    ),
  ]);
  await c.read(chatProvider.notifier).selectConversation('conv-room-backed');
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cloud model selection retains room send transport and forwards model',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      ConversationModels.instance.clear();
    });
    final claims = base64Url.encode(utf8.encode(jsonEncode(
        {'sub': 'user', 'sid': 'session', 'act_scope': 'tenant:tenant'})));
    SharedPreferences.setMockInitialValues(
        {AppConfig.storageTokenKey: 'x.$claims.x'});
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final agent = _agent('a1').copyWith(
        supportsModelSelection: true,
        modelSource: 'byok',
        modelServiceModelId: 'selected-model');
    c.read(selectedAgentProvider.notifier).select(agent);
    await ConversationModels.instance.load(agent, 'conv-room-backed');
    var imCalled = false;
    c.read(chatProvider.notifier).debugAgentDirectSendOverride =
        (_, __, ___) async {
      imCalled = true;
      return AgentDirectSendOutcome.fallback();
    };
    await c
        .read(chatProvider.notifier)
        .send('model test', skillSlugs: ['qa-skill']);
    expect(fake.sendRoomMessageCalls, 1);
    expect(fake.lastModelHint, 'selected-model');
    expect(fake.lastBlocks.any((b) => b.isSkill && b.skillSlug == 'qa-skill'),
        true);
    expect(fake.sendMessageCalls, 0);
    expect(imCalled, false);
  });

  test('streamReady → 不调旧 /chat/send,订阅返回的 stream_id', () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async =>
            AgentDirectSendOutcome.streamReady(
              streamId: 'new-stream',
              agentMessageUuid: 'new-am',
              conversationUuid: 'new-conv',
            );

    await notifier.send('你好');

    expect(fake.sendMessageCalls, 0, reason: '双通道成功 → 不得调旧 /chat/send');
    expect(fake.streamIds, contains('new-stream'));
    expect(fake.streamIds, isNot(contains('old-stream')));
  });

  test('新会话发送后只本地升级 pending,不全量 refresh 对话列表', () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async =>
            AgentDirectSendOutcome.streamReady(
              streamId: 'new-stream',
              agentMessageUuid: 'new-am',
              conversationUuid: 'new-conv',
            );
    final before = fake.listConversationCalls;

    await notifier.send('你好');
    await Future<void>.delayed(Duration.zero);

    expect(fake.listConversationCalls, before);
    expect(
      c.read(conversationsProvider).asData?.value.first.conversationId,
      'new-conv',
      reason: 'pending 会话应通过本地 adopt 升级,不靠重新拉列表',
    );
  });

  test('Agent 回复结束后不 refresh 对话列表', () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async =>
            AgentDirectSendOutcome.streamReady(
              streamId: 'room-stream',
              agentMessageUuid: 'room-am',
              conversationUuid: 'conv-room-backed',
              roomUuid: 'room-1',
              wukongChannelId: 't_1_d_room_1',
              wukongChannelType: 2,
            );
    final before = fake.listConversationCalls;

    await notifier.send('你好');
    await Future<void>.delayed(const Duration(milliseconds: 3200));

    expect(fake.listConversationCalls, before);
  });

  test('agent-direct attach 返回前 stop，迟到 streamReady 只能停止不能复活', () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    final outcome = Completer<AgentDirectSendOutcome>();
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) => outcome.future;

    final sending = notifier.send('立即停止');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(chatProvider).asData?.value.isSending, isTrue);

    await notifier.stop();
    final stopped = c.read(chatProvider).asData!.value;
    expect(stopped.isSending, isFalse);
    expect(stopped.messages.last.isLoading, isFalse);

    outcome.complete(AgentDirectSendOutcome.streamReady(
      streamId: 'late-agent-direct-stream',
      agentMessageUuid: 'late-agent-direct-am',
      conversationUuid: 'conv-room-backed',
      roomUuid: 'room-1',
      wukongChannelId: 't_1_d_room_1',
      wukongChannelType: 2,
    ));
    await sending;
    await Future<void>.delayed(Duration.zero);

    expect(fake.stopCalls, contains('late-agent-direct-am'));
    expect(fake.streamIds, isNot(contains('late-agent-direct-stream')),
        reason: '停止后的迟到 attach 结果不得重新订阅 SSE');
    expect(c.read(chatProvider).asData?.value.isSending, isFalse);
  });

  test('fallback → 走旧 /chat/send + 订阅其 stream_id', () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async => AgentDirectSendOutcome.fallback();

    await notifier.send('你好');

    expect(fake.sendMessageCalls, 1, reason: 'fallback → 旧 /chat/send');
    expect(fake.streamIds, contains('old-stream'));
  });

  test('fallback → skill block 仍随 /chat/send 发送并保留在乐观消息', () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async => AgentDirectSendOutcome.fallback();

    await notifier.send(
      '这是什么技能',
      skillSlugs: const ['forge-persona'],
      blocks: const [
        ImMessageBlock(
          kind: ImMessageBlockKind.skill,
          skillSlug: 'forge-persona',
          name: '蒸馏.skill',
        ),
        ImMessageBlock(
          kind: ImMessageBlockKind.text,
          text: '这是什么技能'
        ),
      ],
    );

    expect(fake.sendMessageCalls, 1);
    expect(fake.lastBlocks.where((b) => b.isSkill).single.name, '蒸馏.skill');
    final question = c
        .read(chatProvider)
        .asData
        ?.value
        .messages
        .firstWhere((message) => message.isQuestion);
    expect(question?.selectedSkillLabels, const ['蒸馏.skill']);
  });

  test('fallback send error → 展示可操作中文配置提示', () async {
    final fake = _SendFakeSvc()
      ..sendMessageError = DioException(
        requestOptions: RequestOptions(path: '/chat/send'),
        error:
            'conflict: chat.agent_unavailable: agent unpublished or invite-disabled',
      );
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async => AgentDirectSendOutcome.fallback();

    await notifier.send('你好');

    final st = c.read(chatProvider).asData?.value;
    expect(st?.isSending, isFalse);
    expect(st?.errorMessage, contains('管理后台「数字员工」'));
    expect(st?.messages.last.content, contains('允许加入群聊/对话邀请'));
  });

  test('room-backed agent-direct fallback → 不再调旧 /chat/send', () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async => AgentDirectSendOutcome.fallback();

    await notifier.send('你好');

    expect(fake.sendMessageCalls, 0,
        reason: 'room-backed agent_direct 不允许 fallback 到旧 /chat/send');
    expect(fake.streamIds, isEmpty);
    final st = c.read(chatProvider).asData?.value;
    expect(st?.isSending, isFalse);
    expect(st?.errorMessage, contains('实时消息连接'));
  });

  test('failed → 失败态,不调旧 /chat/send、不订阅', () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    notifier.debugAgentDirectSendOverride =
        (agentUuid, blocks, summary) async =>
            AgentDirectSendOutcome.failed('发送失败');

    await notifier.send('你好');

    expect(fake.sendMessageCalls, 0, reason: 'failed → 不回退(避免双跑)');
    expect(fake.streamIds, isEmpty);
    final st = c.read(chatProvider).asData?.value;
    expect(st?.isSending, isFalse);
    expect(st?.messages.last.isError, isTrue);
    expect(st?.messages.last.content, '发送失败');

    await notifier.reloadActiveMessages();
    final refreshed = c.read(chatProvider).asData?.value;
    expect(refreshed?.messages.last.isError, isTrue,
        reason: '服务端失败消息到达前，历史刷新不得清掉本地失败气泡');
    expect(refreshed?.messages.last.content, '发送失败');

    fake.history = [
      ChatMessage(
        messageId: 'server-failed-1',
        role: ChatRole.answer,
        content: '数字员工暂时无法回复，请稍后再试。',
        status: BubbleStatus.error,
      ),
    ];
    await notifier.reloadActiveMessages();
    final reconciled = c.read(chatProvider).asData?.value;
    expect(reconciled?.messages, hasLength(1),
        reason: '正式失败消息到达后应替换本地兜底，不能重复显示');
    expect(reconciled?.messages.single.messageId, 'server-failed-1');
  });

  test('pending files bypass dual channel and use old /chat/send(files)',
      () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    var dualChannelCalled = false;
    notifier.debugAgentDirectSendOverride = (agentUuid, blocks, summary) async {
      dualChannelCalled = true;
      return AgentDirectSendOutcome.streamReady(
        streamId: 'new-stream',
        agentMessageUuid: 'new-am',
        conversationUuid: 'new-conv',
      );
    };

    await notifier.send(
      '先看文件',
      blocks: const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: '先看文件'),
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          url: '/chat/media/ref/download',
          fileUuid: 'drive-1',
          refUuid: 'file-1',
          name: '计划.xlsx',
          size: 2048,
        ),
      ],
    );

    expect(dualChannelCalled, isFalse);
    expect(fake.sendMessageCalls, 1);
    expect(fake.lastPrompt, '先看文件');
    expect(fake.lastFiles, hasLength(1));
    expect(fake.lastFiles.single.fileName, '计划.xlsx');
    expect(fake.streamIds, contains('old-stream'));
  });

  test('room-backed pending files use rooms API instead of old /chat/send',
      () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    var dualChannelCalled = false;
    notifier.debugAgentDirectSendOverride = (agentUuid, blocks, summary) async {
      dualChannelCalled = true;
      return AgentDirectSendOutcome.streamReady(
        streamId: 'new-stream',
        agentMessageUuid: 'new-am',
        conversationUuid: 'new-conv',
      );
    };

    await notifier.send(
      '看下图片',
      blocks: const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: '看下图片'),
        ImMessageBlock(
          kind: ImMessageBlockKind.image,
          url: '/chat/media/ref/download',
          fileUuid: 'drive-1',
          refUuid: 'ref-1',
          name: '方案.png',
          size: 1024,
        ),
      ],
    );

    expect(dualChannelCalled, isFalse);
    expect(fake.sendMessageCalls, 0,
        reason: 'room-backed agent_direct 附件不得落到 /chat/send');
    expect(fake.sendRoomMessageCalls, 1);
    expect(fake.lastRoomUuid, 'room-1');
    expect(fake.lastPrompt, '看下图片');
    expect(fake.lastFiles, hasLength(1));
    expect(fake.lastFiles.single.fileName, '方案.png');
    expect(fake.streamIds, contains('room-stream'));
  });

  test('rich media blocks count as attachments and use rooms API', () async {
    final fake = _SendFakeSvc();
    final c = await _bootExistingRoomBackedAgentDirect(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    var dualChannelCalled = false;
    notifier.debugAgentDirectSendOverride = (agentUuid, blocks, summary) async {
      dualChannelCalled = true;
      return AgentDirectSendOutcome.streamReady(
        streamId: 'new-stream',
        agentMessageUuid: 'new-am',
        conversationUuid: 'new-conv',
      );
    };

    await notifier.send(
      '这是什么文件',
      blocks: const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是什么文件'),
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          url: '/message-files/drive-rich/download',
          fileUuid: 'drive-rich',
          refUuid: 'drive-rich',
          name: '3月cursor.pdf',
          size: 309179,
          mime: 'application/pdf',
        ),
      ],
    );

    expect(dualChannelCalled, isFalse);
    expect(fake.sendMessageCalls, 0);
    expect(fake.sendRoomMessageCalls, 1);
    expect(fake.lastFiles, hasLength(1));
    expect(fake.lastFiles.single.driveFileUuid, 'drive-rich');
    expect(fake.lastFiles.single.fileName, '3月cursor.pdf');
    expect(fake.streamIds, contains('room-stream'));
  });

  test('skill chip becomes structured mixed block and does not call old send',
      () async {
    final fake = _SendFakeSvc();
    final c = await _bootSendable(fake);
    addTearDown(c.dispose);
    final notifier = c.read(chatProvider.notifier);
    List<ImMessageBlock> seenBlocks = const [];
    var seenSummary = '';
    notifier.debugAgentDirectSendOverride = (agentUuid, blocks, summary) async {
      seenBlocks = blocks;
      seenSummary = summary;
      return AgentDirectSendOutcome.streamReady(
        streamId: 'new-stream',
        agentMessageUuid: 'new-am',
        conversationUuid: 'new-conv',
      );
    };

    await notifier.send(
      '请检查合同',
      skillSlugs: const ['contract-risk']
    );

    expect(fake.sendMessageCalls, 0);
    expect(seenBlocks.map((b) => b.kind), [
      ImMessageBlockKind.skill,
      ImMessageBlockKind.text,
    ]);
    expect(seenBlocks.first.skillSlug, 'contract-risk');
    expect(seenSummary, '请检查合同');
  });
}
