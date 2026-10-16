// F09 §5.7 / 契约 §3.0f：数字员工单聊多会话并行与状态隔离。
//
// 覆盖验收矩阵（docs/contracts/agent-bus-client-contract.md §3.0f）：
//   V1/V2/V5  A、B 并行流 delta 交错互不串
//   V3        stop 只停当前显示会话
//   V4        后台完成后切回内容完整
//   V6/V18    上传迟到回调只回写发起会话
//   V7/V8/V19 pending→real 合并（含已存在 real session 的冲突合并与消息保序）
//   V10       切回运行中会话不产生第二条 subscription
//   V12       HITL respond 后切会话仍写回原会话
//   V13       placeholder 不存在时 fail closed
//   V15       同会话重复发送被阻止、跨会话并行
//   V20       starting-run 仅占用发起会话，残留发送态首帧清理
//
// fake 按 streamId 独立控制事件时序（standard R8）：`emit(streamId, json)` 手动
// 交错两条流的 delta/done/error，绝不同步立即 onDone。

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameCallback;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_dual_channel.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart'
    show wukongImClientProvider;
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';

// ---------------- 按 streamId 独立控制的 stream fake ----------------

class _StreamCtl {
  Future<void> Function(Map<String, dynamic> json)? onEvent;
  Future<void> Function()? onDone;
  final Completer<void> closed = Completer<void>();
  bool cancelled = false;
}

class _MultiStreamFakeSvc extends OpenClawChatService {
  final Map<String, _StreamCtl> streams = {};
  final List<String> subscribed = [];
  final List<String> stopCalls = [];
  final List<String> deleteCalls = [];
  int sendCalls = 0;
  Object? sendError;
  int respondCalls = 0;
  int a2aDecisionCalls = 0;
  final List<SendMessageResponse> sendQueue = [];
  final Map<String, List<ChatMessage>> historyByConv = {};
  final Map<String, Completer<List<ChatMessage>>> historyHoldByConv = {};
  Completer<SendMessageResponse>? sendHold;
  Completer<void>? stopHold;
  Completer<({String url, String? uuid, String? driveFileUuid})>? uploadHold;
  Completer<RespondToAgentMessageResponse>? respondHold;
  Future<void> Function()? onA2ADecide;
  Completer<ChatHistoryAroundData>? aroundHold;
  RespondToAgentMessageResponse respondResult =
      const RespondToAgentMessageResponse(
    streamId: 'stream-respond',
    conversationUuid: 'conv-a',
    newAgentMessageUuid: 'am-respond',
  );

  _StreamCtl ctl(String streamId) =>
      streams.putIfAbsent(streamId, () => _StreamCtl());

  @override
  Future<List<AgentItem>> listAgents() async => const [];

  @override
  Future<AgentItem> getAgent(String agentId) async =>
      AgentItem.fromJson({'uuid': agentId, 'name': agentId});

  /// 手动向某条流注入一帧事件（等 handler 应用完成后返回）。
  Future<void> emit(String streamId, Map<String, dynamic> json) async {
    final c = ctl(streamId);
    await c.onEvent!.call(json);
  }

  /// 自然结束某条流（onDone + 关闭订阅 future）。
  Future<void> completeStream(String streamId) async {
    final c = ctl(streamId);
    await c.onDone!.call();
    if (!c.closed.isCompleted) c.closed.complete();
  }

  /// 模拟底层 SSE 已断开，但没有送达 terminal event / onDone 回调。
  /// 真实网络断线、解析异常或订阅 future 提前返回都可能形成这类“失效运行态”。
  Future<void> disconnectWithoutTerminal(String streamId) async {
    final c = ctl(streamId);
    if (!c.closed.isCompleted) c.closed.complete();
  }

  @override
  Future<List<ConversationItem>> listAllConversations(
          {int page = 1,
          int pageSize = 40,
          bool includeHidden = false}) async =>
      const [
        ConversationItem(
            conversationId: 'conv-a',
            title: '甲',
            agentId: 'agent-a',
            agentName: '甲'),
        ConversationItem(
            conversationId: 'conv-b',
            title: '乙',
            agentId: 'agent-b',
            agentName: '乙'),
      ];

  @override
  Future<List<ChatMessage>> getHistory(
      {required String conversationId,
      int page = 1,
      int pageSize = 50,
      String? before}) async {
    final hold = historyHoldByConv[conversationId];
    if (hold != null) return hold.future;
    return historyByConv[conversationId] ?? const [];
  }

  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}

  @override
  Future<SendMessageResponse> sendMessage(
      {String? modelHint,
      String? localDeviceId,
      String? localContextId,
      String? conversationId,
      String? agentUuid,
      required String prompt,
      List<ChatFileItem> files = const [],
      List<String> skillSlugs = const [],
      List<ImMessageBlock> blocks = const []}) async {
    sendCalls += 1;
    if (sendError != null) throw sendError!;
    if (sendHold != null) return sendHold!.future;
    return sendQueue.removeAt(0);
  }

  Object? stopError;

  @override
  Future<void> stopMessage({required String messageId}) async {
    stopCalls.add(messageId);
    if (stopError != null) throw stopError!;
    if (stopHold != null) await stopHold!.future;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    deleteCalls.add(conversationId);
  }

  @override
  Future<ChatHistoryAroundData> getHistoryAround({
    required String conversationId,
    required String messageUuid,
    int windowSize = 20,
  }) async {
    if (aroundHold != null) return aroundHold!.future;
    return ChatHistoryAroundData(
      items: historyByConv[conversationId] ?? const [],
      hasMoreUp: false,
      hasMoreDown: false,
      anchorIndex: 0,
    );
  }

  @override
  Future<({String url, String? uuid, String? driveFileUuid})> uploadFile(
      ChatFileItem item) async {
    if (uploadHold != null) return uploadHold!.future;
    return (url: '/u', uuid: 'u1', driveFileUuid: 'd1');
  }

  @override
  Future<RespondToAgentMessageResponse> respondToAgentMessage(
      {required String conversationUuid,
      required String agentMessageUuid,
      required String responseKind,
      required Map<String, dynamic> responsePayload}) async {
    respondCalls += 1;
    if (respondHold != null) return respondHold!.future;
    return respondResult;
  }

  @override
  Future<void> decideA2AApproval({
    required String approvalRequestId,
    required String decision,
    String? reason,
    Map<String, dynamic>? formResult,
  }) async {
    a2aDecisionCalls += 1;
    if (onA2ADecide != null) await onA2ADecide!.call();
  }

  /// 订阅即抛错的流（死流 404/断网/网关错误），模拟真实 HTTP 失败。
  final Set<String> throwOnSubscribe = {};

  @override
  Future<void> streamMessage({
    required String streamId,
    required Future<void> Function(Map<String, dynamic> json) onEvent,
    required Future<void> Function() onDone,
    ChatStreamCancelHandle? cancelHandle,
  }) async {
    subscribed.add(streamId);
    if (throwOnSubscribe.contains(streamId)) {
      throw Exception('subscribe failed: $streamId');
    }
    final c = ctl(streamId);
    c.onEvent = onEvent;
    c.onDone = onDone;
    cancelHandle?.attach(() {
      c.cancelled = true;
      if (!c.closed.isCompleted) c.closed.complete();
    });
    await c.closed.future;
  }
}

class _OfflineImClient implements ImClient {
  // WuKong 未连 → agent-direct 双通道直接 fallback 旧 /chat/send，测试聚焦流路由。
  @override
  String? get connectedUid => null;
  @override
  ImConnectionStatus get connectionStatus => ImConnectionStatus.disconnected;
  @override
  bool get isRealtimeConnected => false;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() async =>
      const DigitalEmployeeCatalog(personal: [], enterprise: []);
}

class _MicrotaskFrameScheduler {
  int _nextId = 0;
  final Map<int, FrameCallback> _pending = {};

  int schedule(FrameCallback callback) {
    final id = ++_nextId;
    _pending[id] = callback;
    scheduleMicrotask(() {
      _pending.remove(id)?.call(Duration.zero);
    });
    return id;
  }

  void cancel(int id) {
    _pending.remove(id);
  }
}

Future<(ProviderContainer, ChatNotifier, _MultiStreamFakeSvc)> _boot({
  bool useRealFrames = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final fake = _MultiStreamFakeSvc();
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => fake),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
    wukongImClientProvider.overrideWithValue(_OfflineImClient()),
  ]);
  await c.read(chatProvider.future);
  // 让 AsyncNotifier 框架对 build 返回值的 state 赋值先落地，
  // 否则紧随其后的 debugSeedSession 会被这次迟到赋值覆盖。
  await Future<void>.delayed(Duration.zero);
  final notifier = c.read(chatProvider.notifier);
  if (!useRealFrames) {
    final scheduler = _MicrotaskFrameScheduler();
    notifier.debugScheduleAnswerFrameCallback = scheduler.schedule;
    notifier.debugCancelAnswerFrameCallback = scheduler.cancel;
  }
  addTearDown(() async {
    // 先放掉所有挂起流再 dispose，避免 disposed Ref 写入。
    for (final ctl in fake.streams.values) {
      if (!ctl.closed.isCompleted) ctl.closed.complete();
    }
    await Future<void>.delayed(Duration.zero);
    c.dispose();
  });
  return (c, notifier, fake);
}

Future<void> _pump([int times = 3]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _mockRtcEventChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const incomingEvents = MethodChannel('easyo/rtc/incoming_panel/events');
  const meetingEvents = MethodChannel('easyo/rtc/meeting/events');
  messenger.setMockMethodCallHandler(incomingEvents, (_) async => null);
  messenger.setMockMethodCallHandler(meetingEvents, (_) async => null);
  addTearDown(() {
    messenger.setMockMethodCallHandler(incomingEvents, null);
    messenger.setMockMethodCallHandler(meetingEvents, null);
  });
}

/// 发起一条 send 并推进到「已订阅流」状态（send 本身 await 到流结束，故 unawaited）。
Future<void> _sendOn(
  ChatNotifier notifier,
  _MultiStreamFakeSvc fake, {
  required String conv,
  required String text,
  required String streamId,
  required String messageId,
  String? adoptTo,
}) async {
  await notifier.selectConversation(conv);
  fake.sendQueue.add(SendMessageResponse(
    messageId: messageId,
    streamId: streamId,
    conversationId: adoptTo ?? conv,
    status: '',
    agentId: '',
  ));
  unawaited(notifier.send(text));
  await _pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'three sequential file streams retain only their own artifacts and reject late identities',
      () async {
    final (_, notifier, fake) = await _boot();
    final names = ['report.pptx', 'report.docx', 'stars.svg'];
    for (var i = 0; i < names.length; i++) {
      await _sendOn(notifier, fake,
          conv: 'conv-a', text: names[i], streamId: 's$i', messageId: 'm$i');
      if (i > 0) {
        await fake.emit('s${i - 1}', {
          'eventType': 'message',
          'content': 'LATE OLD TEXT',
        });
        await fake.emit('s${i - 1}', {
          'eventType': 'tool_result',
          'toolCallId': 'late',
          'toolResult': 'OLD',
        });
        await fake.emit('s$i', {
          'eventType': 'tool_result',
          'stream_id': 's${i - 1}',
          'toolCallId': 'late',
          'toolResult': 'OLD'
        });
        await fake.emit('s$i', {
          'eventType': 'message',
          'message_uuid': 'm${i - 1}',
          'finished': true,
          'blocks': [
            {'type': 'file', 'name': 'OLD'}
          ]
        });
      }
      await fake.emit('s$i', {
        'eventType': 'message',
        'finished': true,
        'content': names[i],
        'blocks': [
          {'type': 'file', 'name': names[i]}
        ]
      });
      await fake.completeStream('s$i');
      await _pump();
      final answers = notifier
          .debugSession('conv-a')!
          .messages
          .where((m) => m.isAnswer)
          .toList();
      expect(answers.last.empBlocks.single['name'], names[i]);
      expect(answers.last.timelineEntries.any((e) => e.key == 'tool:late'),
          isFalse);
      fake.historyByConv['conv-a'] = notifier.debugSession('conv-a')!.messages;
      await notifier.reloadActiveMessages();
    }
    final answers = notifier
        .debugSession('conv-a')!
        .messages
        .where((m) => m.isAnswer)
        .toList();
    expect(answers.map((m) => m.empBlocks.single['name']), names);
  });

  for (final kind in ['message', 'error']) {
    test('$kind explicit empty terminal blocks replace temporary blocks',
        () async {
      final (_, notifier, fake) = await _boot();
      await _sendOn(notifier, fake,
          conv: 'conv-a', text: 'test', streamId: 's', messageId: 'm');
      final session = notifier.debugSession('conv-a')!;
      notifier.debugSeedSession('conv-a', isSending: true, messages: [
        ...session.messages.take(session.messages.length - 1),
        session.messages.last.copyWith(empBlocks: [
          {'type': 'file', 'name': 'temporary'}
        ]),
      ]);
      await fake.emit('s', {
        'eventType': kind,
        'finished': true,
        'blocks': <dynamic>[],
        'error_code': 'zap.local_model_unavailable'
      });
      await _pump();
      expect(notifier.debugSession('conv-a')!.messages.last.empBlocks, isEmpty);
    });
  }

  for (final delivery in ['complete', 'partial', 'none']) {
    test('model failure delivery $delivery is preserved on stream and history',
        () async {
      final (_, notifier, fake) = await _boot();
      await _sendOn(notifier, fake,
          conv: 'conv-a', text: 'files', streamId: 's', messageId: 'm');
      final blocks = <Map<String, dynamic>>[
        if (delivery != 'none') ...[
          {
            'type': 'file',
            'name': 'report.pptx',
            'local_artifact': {
              'artifact_id': 'a',
              'device_id': 'd',
              'sha256': 'a' * 64
            }
          },
          {
            'type': 'local_delivery',
            'status': delivery,
            'verified_count': 1,
            'required_count': 1
          },
        ],
      ];
      await fake.emit('s', {
        'eventType': 'error',
        'error_code': 'zap.local_model_unavailable',
        'error_message': 'private upstream detail',
        'blocks': blocks
      });
      await _pump();
      final notice = delivery == 'complete'
          ? '文件已生成，后续模型处理失败'
          : delivery == 'partial'
              ? '部分文件已生成，任务未完成'
              : null;
      final current = notifier.debugSession('conv-a')!.messages.last;
      expect(current.deliveryNotice, notice);
      expect(current.failureCode, 'zap.local_model_unavailable');
      expect(current.isError, isTrue);
      fake.historyByConv['conv-a'] = [
        ChatMessage.fromAgentBusJson({
          'uuid': 'm',
          'role': 'agent',
          'status': 'failed',
          'error_code': 'zap.local_model_unavailable',
          'blocks': blocks
        })
      ];
      await notifier.reloadActiveMessages();
      expect(notifier.debugSession('conv-a')!.messages.last.deliveryNotice,
          notice);
    });
  }

  test(
      'account reconciliation discovers a remote send and closes its cancelled stream',
      () async {
    final (container, notifier, fake) = await _boot();
    await notifier.selectConversation('conv-a');
    fake.historyByConv['conv-a'] = [
      ChatMessage(
          role: ChatRole.question,
          content: 'Beijing',
          messageId: 'remote-user'),
      ChatMessage(
          role: ChatRole.answer,
          content: '',
          messageId: 'remote-answer',
          streamId: 'remote-stream',
          status: BubbleStatus.loading,
          agentMessageStatus: 'streaming'),
    ];
    await notifier.reconcileAccountConversation('conv-a');
    await _pump();
    expect(fake.subscribed, ['remote-stream']);
    expect(container.read(chatProvider).requireValue.messages.first.content,
        'Beijing');
    await _sendOn(notifier, fake,
        conv: 'conv-b',
        text: 'B stays running',
        streamId: 'stream-b',
        messageId: 'answer-b');
    fake.historyByConv['conv-a'] = [
      fake.historyByConv['conv-a']!.first,
      ChatMessage(
          role: ChatRole.answer,
          content: '',
          messageId: 'remote-answer',
          streamId: 'remote-stream',
          status: BubbleStatus.success,
          agentMessageStatus: 'cancelled'),
    ];
    await notifier.reconcileAccountConversation('conv-a');
    await _pump();
    final workspace = container.read(chatProvider).requireValue;
    expect(workspace.sessions['conv-a']!.messages.last.agentMessageStatus,
        'cancelled');
    expect(workspace.sessions['conv-a']!.isSending, isFalse);
    expect(fake.ctl('remote-stream').cancelled, isTrue);
    expect(workspace.activeConversationId, 'conv-b');
    expect(workspace.sessions['conv-b']!.isSending, isTrue);
    expect(fake.ctl('stream-b').cancelled, isFalse);
    expect(fake.stopCalls, isEmpty);
  });

  test(
      'account reconciliation cannot cancel a live stream without its matching terminal',
      () async {
    final (container, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: 'A', streamId: 'stream-a', messageId: 'answer-a');
    fake.historyByConv['conv-a'] = [
      ChatMessage(
          role: ChatRole.answer,
          content: 'old stopped',
          messageId: 'older-answer',
          agentMessageStatus: 'cancelled'),
    ];
    await notifier.reconcileAccountConversation('conv-a');
    expect(container.read(chatProvider).requireValue.isSending, isTrue);
    expect(fake.ctl('stream-a').cancelled, isFalse);
  });

  test('late account snapshot does not overwrite a newer locally started run',
      () async {
    final (container, notifier, fake) = await _boot();
    await notifier.selectConversation('conv-a');
    final delayed = Completer<List<ChatMessage>>();
    fake.historyHoldByConv['conv-a'] = delayed;
    final refreshing = notifier.reconcileAccountConversation('conv-a');
    await _pump();
    fake.historyHoldByConv.remove('conv-a');
    fake.sendQueue.add(const SendMessageResponse(
        messageId: 'new-answer',
        streamId: 'new-stream',
        conversationId: 'conv-a',
        status: '',
        agentId: ''));
    unawaited(notifier.send('new question'));
    await _pump();
    delayed.complete([]);
    await refreshing;
    expect(container.read(chatProvider).requireValue.messages.first.content,
        'new question');
    expect(container.read(chatProvider).requireValue.isSending, isTrue);
    expect(fake.ctl('new-stream').cancelled, isFalse);
  });

  test(
      'failed sends keep their own question and error despite older server failures',
      () async {
    final (container, notifier, fake) = await _boot();
    fake.historyByConv['conv-a'] = [
      ChatMessage(
          role: ChatRole.answer,
          content: '旧错误',
          messageId: 'old-server-failure',
          status: BubbleStatus.error)
    ];
    await notifier.selectConversation('conv-a');
    fake.sendError = Exception('chat.model_unavailable');
    await notifier.send('同一条测试消息');
    await _pump();
    await notifier.reloadActiveMessages();
    await notifier.send('同一条测试消息');
    await _pump();
    await notifier.reloadActiveMessages();
    await notifier.selectConversation('conv-b');
    await notifier.selectConversation('conv-a');
    await notifier.reloadActiveMessages();
    final messages = container.read(chatProvider).requireValue.messages;
    expect(messages.where((m) => m.content == '同一条测试消息'), hasLength(2));
    expect(
        messages.where((m) => m.isError && m.messageId == null), hasLength(2));
    expect(messages.where((m) => m.messageId == 'old-server-failure'),
        hasLength(1));
    expect(fake.sendCalls, 2);
  });
  test('old local credit failures stay before newer server messages', () async {
    final (container, notifier, fake) = await _boot();
    final old = ChatMessage(
      role: ChatRole.answer,
      content: '旧回复',
      messageId: 'old-answer',
      createdAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    fake.historyByConv['conv-a'] = [old];
    await notifier.selectConversation('conv-a');
    fake.sendError = Exception('billing.insufficient_credits');
    await notifier.send('几点了');
    await _pump();

    final newer = DateTime.now().add(const Duration(minutes: 1));
    fake.historyByConv['conv-a'] = [
      old,
      ChatMessage(
        role: ChatRole.question,
        content: '几点了',
        messageId: 'new-question',
        createdAt: newer,
      ),
      ChatMessage(
        role: ChatRole.answer,
        content: '模型暂不可用',
        messageId: 'new-answer',
        status: BubbleStatus.error,
        createdAt: newer,
      ),
    ];
    for (var refresh = 0; refresh < 2; refresh++) {
      await notifier.reloadActiveMessages();
      final messages = container.read(chatProvider).requireValue.messages;
      expect(messages, hasLength(5));
      expect(messages.first.messageId, 'old-answer');
      expect(messages[1].content, '几点了');
      expect(messages[1].messageId, isNull);
      expect(messages[2].isError, isTrue);
      expect(messages[2].content, contains('积分不足'));
      expect(messages[3].messageId, 'new-question');
      expect(messages.last.messageId, 'new-answer');
      await notifier.selectConversation('conv-b');
      await notifier.selectConversation('conv-a');
    }
    expect(fake.sendCalls, 1);
  });

  testWidgets('UI 回归: active 会话从 A 切到 B 后不保留 A 的消息子树', (tester) async {
    final a = ChatSessionState(
      conversationId: 'conv-a',
      messages: [
        ChatMessage(
          messageId: 'um-a-ui',
          role: ChatRole.question,
          content: '仅属于 A 的问题',
        ),
      ],
    );
    final b = ChatSessionState(
      conversationId: 'conv-b',
      messages: [
        ChatMessage(
          messageId: 'um-b-ui',
          role: ChatRole.question,
          content: '仅属于 B 的问题',
        ),
      ],
    );

    Widget buildView(String active) {
      return MaterialApp(
        home: Scaffold(
          body: ChatSessionView(
            state: ChatWorkspaceState(
              activeConversationId: active,
              sessions: {'conv-a': a, 'conv-b': b},
            ),
            onPickFiles: () {},
            onPickImages: () {},
            onPickFromDrive: () {},
            onRemoveFile: (_) {},
            onSend: (_, __) {},
            onStop: () {},
            onLoadMoreHistory: () {},
          ),
        ),
      );
    }

    await tester.pumpWidget(buildView('conv-a'));
    await tester.pumpAndSettle();
    expect(find.text('仅属于 A 的问题'), findsOneWidget);

    await tester.pumpWidget(buildView('conv-b'));
    await tester.pumpAndSettle();
    expect(find.text('仅属于 B 的问题'), findsOneWidget);
    expect(find.text('仅属于 A 的问题'), findsNothing);
  });

  testWidgets('UI 回归: A 生成中切到空闲 B，输入区必须立即恢复发送按钮', (tester) async {
    final a = ChatSessionState(
      conversationId: 'conv-a',
      isSending: true,
      activeStreamId: 'stream-a',
      messages: [
        ChatMessage(
          messageId: 'am-a-button',
          role: ChatRole.answer,
          content: 'A 生成中',
          status: BubbleStatus.loading,
        ),
      ],
    );
    final b = ChatSessionState(
      conversationId: 'conv-b',
      messages: [
        ChatMessage(
          messageId: 'am-b-button',
          role: ChatRole.answer,
          content: 'B 已完成',
          status: BubbleStatus.success,
        ),
      ],
    );

    Widget buildView(String active) {
      return MaterialApp(
        home: Scaffold(
          body: ChatSessionView(
            state: ChatWorkspaceState(
              activeConversationId: active,
              sessions: {'conv-a': a, 'conv-b': b},
            ),
            onPickFiles: () {},
            onPickImages: () {},
            onPickFromDrive: () {},
            onRemoveFile: (_) {},
            onSend: (_, __) {},
            onStop: () {},
            onLoadMoreHistory: () {},
          ),
        ),
      );
    }

    await tester.pumpWidget(buildView('conv-a'));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.stop_fill), findsWidgets);

    await tester.pumpWidget(buildView('conv-b'));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.stop_fill), findsNothing);
    expect(find.byIcon(CupertinoIcons.paperplane_fill), findsWidgets);
  });

  test('回归: 切到无真实 runtime 的残留发送态，会在历史返回前恢复发送按钮', () async {
    final (c, notifier, fake) = await _boot();
    final done = ChatMessage(
      messageId: 'am-b-done',
      role: ChatRole.answer,
      content: 'B 已完成',
      status: BubbleStatus.success,
    );
    notifier.debugSeedSession(
      'conv-b',
      messages: [done],
      isSending: true,
      makeActive: false,
    );
    fake.historyHoldByConv['conv-b'] = Completer<List<ChatMessage>>();

    final selecting = notifier.selectConversation('conv-b');
    await _pump();

    final duringHistory = c.read(chatProvider).asData!.value;
    expect(duringHistory.activeConversationId, 'conv-b');
    expect(duringHistory.messages.single.content, 'B 已完成');
    expect(duringHistory.isSending, isFalse,
        reason: '无 starting-run/runtime 时不能等待历史请求才清红色停止按钮');

    fake.historyHoldByConv['conv-b']!.complete([done]);
    await selecting;
  });

  test('回归: agent-direct POST 未返回时只占用发起会话，切到 B 仍可发送', () async {
    final (c, notifier, fake) = await _boot();
    final directHold = Completer<AgentDirectSendOutcome>();
    notifier.debugAgentDirectSendOverride = (_, __, ___) => directHold.future;

    await notifier.selectConversation('conv-a');
    unawaited(notifier.send('A 的慢请求'));
    await _pump();
    expect(notifier.debugSession('conv-a')!.isSending, isTrue);

    await notifier.selectConversation('conv-b');
    var ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-b');
    expect(ws.isSending, isFalse, reason: 'A 的 starting-run 不得让 B 显示停止按钮');

    await notifier.selectConversation('conv-a');
    ws = c.read(chatProvider).asData!.value;
    expect(ws.isSending, isTrue, reason: '切回 A 时真实未返回的 starting-run 仍应显示停止按钮');

    directHold.complete(AgentDirectSendOutcome.streamReady(
      streamId: 'stream-agent-direct-a',
      agentMessageUuid: 'am-agent-direct-a',
      conversationUuid: 'conv-a',
    ));
    await _pump();
    expect(fake.subscribed, contains('stream-agent-direct-a'));

    await notifier.selectConversation('conv-b');
    expect(c.read(chatProvider).asData!.value.isSending, isFalse);
  });

  testWidgets('正文 delta 每帧最多提交一次，A/B 队列互不串', (tester) async {
    _mockRtcEventChannels();
    late ProviderContainer container;
    late ChatNotifier notifier;
    await tester.runAsync(() async {
      final boot = await _boot(useRealFrames: true);
      container = boot.$1;
      notifier = boot.$2;
      final fake = boot.$3;

      await _sendOn(notifier, fake,
          conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
      await _sendOn(notifier, fake,
          conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');

      await fake.emit('stream-a', {'eventType': 'message', 'content': 'A1'});
      await fake.emit('stream-a', {'eventType': 'message', 'content': 'A2'});
      await fake.emit('stream-b', {'eventType': 'message', 'content': 'B1'});
    });

    expect(notifier.debugSession('conv-a')!.messages.last.content, isEmpty);
    expect(notifier.debugSession('conv-b')!.messages.last.content, isEmpty);

    var chatStateUpdates = 0;
    final subscription = container.listen(
      chatProvider,
      (_, __) => chatStateUpdates += 1,
    );
    addTearDown(subscription.close);

    await tester.pump(const Duration(milliseconds: 16));
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1',
        reason: '同一帧只从 A 的队列提交一次细粒度正文');
    expect(notifier.debugSession('conv-b')!.messages.last.content, 'B1',
        reason: 'B 使用自己的 runtime 队列');
    expect(chatStateUpdates, 2,
        reason: 'A/B 每条 stream 在同一 frame 各提交一次，不为 timeline 二次重建');

    await tester.pump(const Duration(milliseconds: 16));
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1A2');
    expect(chatStateUpdates, 3);
  });

  test('V1/V2/V5: A、B 并行流 delta 交错，各归各会话互不串', () async {
    final (c, notifier, fake) = await _boot();

    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');
    expect(fake.subscribed, containsAll(['stream-a', 'stream-b']));

    // B 是当前显示会话；交错注入 A/B 的 delta。
    await fake.emit('stream-a', {'eventType': 'message', 'content': 'A1'});
    await fake.emit('stream-b', {'eventType': 'message', 'content': 'B1'});
    await fake.emit('stream-a', {'eventType': 'message', 'content': 'A2'});
    await _pump();

    final a = notifier.debugSession('conv-a')!;
    final b = notifier.debugSession('conv-b')!;
    expect(a.messages.last.content, 'A1A2', reason: 'A 的增量只进 A（V1/V5）');
    expect(b.messages.last.content, 'B1', reason: 'B 的增量只进 B（V2）');
    expect(a.messages.last.isLoading, isTrue);
    expect(b.messages.last.isLoading, isTrue);

    // A 后台完成：active 仍是 B，B 不受影响（V1/V6 语义）。
    await fake.emit('stream-a',
        {'eventType': 'message', 'content': 'A1A2A3', 'finished': true});
    await fake.completeStream('stream-a');
    await _pump();
    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-b');
    expect(notifier.debugSession('conv-a')!.isSending, isFalse);
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1A2A3');
    expect(notifier.debugSession('conv-b')!.isSending, isTrue,
        reason: 'A 的 done 不得收口 B（V2）');
  });

  testWidgets('长回复突发先细粒度起步，预算耗尽后已到内容一次铺出', (tester) async {
    _mockRtcEventChannels();
    late ChatNotifier notifier;
    final longAnswer = List.filled(4096, '长').join();
    await tester.runAsync(() async {
      final boot = await _boot(useRealFrames: true);
      notifier = boot.$2;
      final fake = boot.$3;
      await _sendOn(notifier, fake,
          conv: 'conv-a',
          text: '生成长回复',
          streamId: 'stream-long',
          messageId: 'am-long');

      await fake
          .emit('stream-long', {'eventType': 'message', 'content': longAnswer});
    });

    expect(notifier.debugSession('conv-a')!.messages.last.content, isEmpty);
    // 开头维持细粒度：首帧只揭示一部分，不整段砸出。
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      notifier.debugSession('conv-a')!.messages.last.content.length,
      inExclusiveRange(0, longAnswer.length),
    );

    // 预算耗尽后已到积压一次性铺出：显著早于旧的 16 帧追赶周期，
    // 也不得持有等终态（会看起来直接卡住）。
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(notifier.debugSession('conv-a')!.messages.last.content, longAnswer,
        reason: '预算耗尽后剩余积压必须立即整批上屏');
  });

  testWidgets('completed 立即覆盖权威正文并取消待显示尾段', (tester) async {
    _mockRtcEventChannels();
    late ChatNotifier notifier;
    late _MultiStreamFakeSvc fake;
    await tester.runAsync(() async {
      final boot = await _boot(useRealFrames: true);
      notifier = boot.$2;
      fake = boot.$3;
      await _sendOn(notifier, fake,
          conv: 'conv-a',
          text: '完成覆盖',
          streamId: 'stream-final',
          messageId: 'am-final');

      await fake
          .emit('stream-final', {'eventType': 'message', 'content': '待显示旧正文'});
    });
    expect(notifier.debugSession('conv-a')!.messages.last.content, isEmpty);

    await tester.runAsync(() async {
      await fake.emit('stream-final', {
        'eventType': 'message',
        'content': '服务端完整终态',
        'finished': true,
      });
    });
    expect(
      notifier.debugSession('conv-a')!.messages.last.content,
      '服务端完整终态'
    );

    await tester.pump(const Duration(milliseconds: 32));
    expect(
      notifier.debugSession('conv-a')!.messages.last.content,
      '服务端完整终态',
      reason: '完成后不得继续把旧队列追加到权威终态',
    );
  });

  testWidgets('completed 未重复正文时立即 flush 已到达的最后片段', (tester) async {
    _mockRtcEventChannels();
    late ChatNotifier notifier;
    await tester.runAsync(() async {
      final boot = await _boot(useRealFrames: true);
      notifier = boot.$2;
      final fake = boot.$3;
      await _sendOn(notifier, fake,
          conv: 'conv-a',
          text: '空终态正文',
          streamId: 'stream-empty-final',
          messageId: 'am-empty-final');

      await fake.emit('stream-empty-final', {
        'eventType': 'message',
        'content': '最后一个流式片段',
      });
      await fake.emit('stream-empty-final', {
        'eventType': 'message',
        'content': '',
        'finished': true,
      });
    });

    expect(
      notifier.debugSession('conv-a')!.messages.last.content,
      '最后一个流式片段'
    );
    await tester.pump(const Duration(milliseconds: 32));
    expect(
      notifier.debugSession('conv-a')!.messages.last.content,
      '最后一个流式片段'
    );
  });

  testWidgets('stop 会取消待执行 frame，旧正文不会在停止后出现', (tester) async {
    _mockRtcEventChannels();
    late ChatNotifier notifier;
    await tester.runAsync(() async {
      final boot = await _boot(useRealFrames: true);
      notifier = boot.$2;
      final fake = boot.$3;
      await _sendOn(notifier, fake,
          conv: 'conv-a',
          text: '停止测试',
          streamId: 'stream-stop-reveal',
          messageId: 'am-stop-reveal');

      await fake.emit('stream-stop-reveal', {
        'eventType': 'message',
        'content': '停止后不应补出的正文',
      });
      await notifier.stop();
    });

    expect(notifier.debugSession('conv-a')!.messages.last.content, isEmpty);
    await tester.pump(const Duration(milliseconds: 32));
    expect(notifier.debugSession('conv-a')!.messages.last.content, isEmpty);
    expect(notifier.debugSession('conv-a')!.isSending, isFalse);
  });

  test('Hermes tool_call 终态会实时显示完成或失败', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a',
        text: '生成官网',
        streamId: 'stream-tools',
        messageId: 'am-tools');

    await fake.emit('stream-tools', {
      'eventType': 'tool_call',
      'toolCallId': 'call-ok',
      'toolName': 'terminal',
      'toolStatus': 'running',
    });
    await fake.emit('stream-tools', {
      'eventType': 'tool_call',
      'toolCallId': 'call-ok',
      'toolName': 'terminal',
      'toolStatus': 'completed',
    });
    await fake.emit('stream-tools', {
      'eventType': 'tool_call',
      'toolCallId': 'call-failed',
      'toolName': 'execute_code',
      'toolStatus': 'failed',
    });

    final entries = notifier
        .debugSession('conv-a')!
        .messages
        .last
        .timelineEntries
        .where((entry) => entry.kind == ChatTimelineKind.tool)
        .toList();
    final completed =
        entries.singleWhere((entry) => entry.key == 'tool:call-ok');
    final failed =
        entries.singleWhere((entry) => entry.key == 'tool:call-failed');
    expect(completed.status, ChatTimelineStatus.done);
    expect(completed.title, contains('完成'));
    expect(failed.status, ChatTimelineStatus.error);
    expect(failed.title, contains('失败'));
  });

  test('V3: stop 只停当前显示会话（B），A 继续', () async {
    final (c, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');

    await fake.emit('stream-b', {'eventType': 'phase', 'phase': 'in_progress'});
    await _pump();
    expect(
      notifier
          .debugSession('conv-b')!
          .messages
          .last
          .timelineEntries
          .any((entry) => entry.isRunning),
      isTrue,
      reason: '先复现用户点停止前的“思考中”时间线',
    );

    await notifier.stop(); // 当前显示 conv-b
    await _pump();

    expect(fake.stopCalls, ['am-b']);
    expect(fake.ctl('stream-b').cancelled, isTrue, reason: '真取消 B 的订阅');
    expect(fake.ctl('stream-a').cancelled, isFalse, reason: 'A 的流不受影响');
    expect(notifier.debugSession('conv-b')!.isSending, isFalse);
    expect(notifier.debugSession('conv-a')!.isSending, isTrue);
    final stoppedTimeline =
        notifier.debugSession('conv-b')!.messages.last.timelineEntries;
    expect(stoppedTimeline.any((entry) => entry.isRunning), isFalse,
        reason: '停止后不能继续显示“思考中”');
    expect(
      stoppedTimeline.any(
        (entry) =>
            entry.kind == ChatTimelineKind.stopped &&
            entry.status == ChatTimelineStatus.stopped,
      ),
      isTrue,
      reason: '应立即显示已停止终态',
    );

    // A 仍能继续收增量。
    await fake.emit('stream-a', {'eventType': 'message', 'content': 'A1'});
    await _pump();
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1');
  });

  test('V3: stop awaits confirmation, failures remain retryable', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');
    fake.stopError = StateError('offline');
    await notifier.stop();
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    expect(notifier.debugSession('conv-b')!.errorMessage, contains('停止请求未确认'));
    fake.stopError = null;
    fake.stopHold = Completer<void>();
    final stopping = notifier.stop();
    await _pump();
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    await notifier.stop(); // duplicate suppressed while request is pending
    expect(fake.stopCalls, ['am-b', 'am-b']);
    fake.stopHold!.complete();
    await stopping;
    expect(notifier.debugSession('conv-b')!.isSending, isFalse);
  });

  test('V4: A 后台完成后切回，内容完整不重拉覆盖', () async {
    final (c, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await notifier.selectConversation('conv-b');

    await fake.emit('stream-a',
        {'eventType': 'message', 'content': '完整回答', 'finished': true});
    await fake.completeStream('stream-a');
    await _pump();

    // 服务端历史（切回时后台刷新用），与本地终态一致。
    fake.historyByConv['conv-a'] = [
      ChatMessage(messageId: 'um-a', role: ChatRole.question, content: '问A'),
      ChatMessage(
          messageId: 'am-a',
          role: ChatRole.answer,
          content: '完整回答',
          status: BubbleStatus.success),
    ];
    await notifier.selectConversation('conv-a');
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-a');
    expect(ws.messages.last.content, '完整回答');
    expect(ws.isSending, isFalse);
    expect(fake.subscribed.where((s) => s == 'stream-a').length, 1,
        reason: '完成的流不得被重新订阅');
  });

  test('回归: A 生成中切到 B，右侧立即只展示 B 的历史', () async {
    final (c, notifier, fake) = await _boot();
    fake.historyByConv['conv-b'] = [
      ChatMessage(
        messageId: 'um-b-old',
        role: ChatRole.question,
        content: 'B 的旧问题',
      ),
      ChatMessage(
        messageId: 'am-b-old',
        role: ChatRole.answer,
        content: 'B 的旧回答',
        status: BubbleStatus.success,
      ),
    ];
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: 'A 的问题', streamId: 'stream-a', messageId: 'am-a');

    await notifier.selectConversation('conv-b');
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-b');
    expect(ws.messages.map((m) => m.content), ['B 的旧问题', 'B 的旧回答']);
    expect(ws.messages.any((m) => m.content == 'A 的问题'), isFalse,
        reason: 'active 投影不得残留上一个会话的 optimistic 消息');
    expect(ws.isSending, isFalse, reason: 'B 空闲时输入区不得继承 A 的停止按钮');
    expect(notifier.debugSession('conv-a')!.isSending, isTrue,
        reason: '切换只换展示，不停止 A 的后台流');
  });

  test('回归: SSE 无 terminal 提前结束后，切回会话应拉历史清除思考中', () async {
    final (c, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: 'A 的问题', streamId: 'stream-a', messageId: 'am-a');

    await fake.disconnectWithoutTerminal('stream-a');
    await _pump();
    expect(notifier.debugSession('conv-a')!.isSending, isTrue,
        reason: '先证明已形成 runtime 消失但 session 仍生成中的失效运行态');

    fake.historyByConv['conv-a'] = [
      ChatMessage(
        messageId: 'um-a',
        role: ChatRole.question,
        content: 'A 的问题'
      ),
      ChatMessage(
        messageId: 'am-a',
        role: ChatRole.answer,
        content: '服务端最终回答',
        status: BubbleStatus.success,
      ),
    ];
    await notifier.selectConversation('conv-b');
    await notifier.selectConversation('conv-a');
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-a');
    expect(ws.messages.last.content, '服务端最终回答');
    expect(ws.messages.last.isLoading, isFalse);
    expect(ws.isSending, isFalse,
        reason: '不存在 runtime 的陈旧 activeStreamId 不得永久阻止历史对账');
  });

  test('本机产物在终态前显示、重复不增卡、切会话保留、归档失败更新', () async {
    final (_, notifier, fake) = await _boot();
    fake.historyByConv['conv-b'] = [
      ChatMessage.fromAgentBusJson({
        'uuid': 'am-b',
        'role': 'agent',
        'status': 'streaming',
        'stream_id': 'artifact-stream',
        'blocks': <dynamic>[],
      })
    ];
    await notifier.selectConversation('conv-b');
    await _pump(6);
    final card = <String, dynamic>{
      'type': 'image',
      'name': 'poster.png',
      'mime': 'image/png',
      'size': 100,
      'local_artifact': {'artifact_id': 'a', 'device_id': 'd', 'sha256': 'hash'}
    };
    for (var i = 0; i < 2; i++) {
      await fake.emit('artifact-stream', {
        'eventType': 'local_artifacts',
        'blocks': [card]
      });
    }
    await fake
        .emit('artifact-stream', {'eventType': 'message', 'content': '继续生成手册'});
    await _pump();
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    expect(notifier.debugSession('conv-b')!.messages.last.empBlocks, [card]);
    await notifier.selectConversation('conv-a');
    expect(
        notifier
            .debugSession('conv-a')!
            .messages
            .any((m) => m.empBlocks.contains(card)),
        isFalse);
    await notifier.selectConversation('conv-b');
    expect(notifier.debugSession('conv-b')!.messages.last.empBlocks, [card]);
    // A verified empty snapshot can remove an invalidated local file.
    await fake.emit('artifact-stream',
        {'eventType': 'local_artifacts', 'blocks': <dynamic>[]});
    expect(notifier.debugSession('conv-b')!.messages.last.empBlocks, isEmpty);
    await fake.emit('artifact-stream', {
      'eventType': 'local_artifacts',
      'blocks': [card]
    });
    await fake.emit('artifact-stream', {
      'eventType': 'stage',
      'stageId': 'local-archive',
      'stageText': '正在保存到云盘（已处理 0/1）',
    });
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    expect(
        notifier
            .debugSession('conv-b')!
            .messages
            .last
            .timelineEntries
            .where((e) => e.key == 'stage:local-archive')
            .single
            .isRunning,
        isTrue);
    final archived = {...card, 'archive_status': 'failed'};
    await fake.emit('artifact-stream', {
      'eventType': 'message',
      'finished': true,
      'content': 'done',
      'blocks': [archived]
    });
    await fake.completeStream('artifact-stream');
    await _pump();
    expect(
        notifier.debugSession('conv-b')!.messages.last.empBlocks, [archived]);
    expect(notifier.debugSession('conv-b')!.isSending, isFalse);
  });

  test('已完成的归档阶段不被模型失败改成红色', () async {
    final (_, notifier, fake) = await _boot();
    fake.historyByConv['conv-b'] = [
      ChatMessage.fromAgentBusJson({
        'uuid': 'archive-error',
        'role': 'agent',
        'status': 'streaming',
        'stream_id': 'archive-error-stream',
        'blocks': <dynamic>[],
      })
    ];
    await notifier.selectConversation('conv-b');
    await _pump(6);
    await fake.emit('archive-error-stream', {
      'eventType': 'stage',
      'stageId': 'local-archive',
      'stageText': '正在保存到云盘（已处理 2/2）',
    });
    await fake.emit('archive-error-stream', {
      'eventType': 'stage',
      'stageId': 'local-archive',
      'stageText': '云盘保存完成',
    });
    await fake.emit('archive-error-stream', {'eventType': 'stage_done'});
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    await fake.emit(
        'archive-error-stream', {'eventType': 'error', 'error': '执行引擎收尾异常'});
    await fake.completeStream('archive-error-stream');
    await _pump();
    final state = notifier.debugSession('conv-b')!;
    final archive = state.messages.last.timelineEntries
        .where((e) => e.key == 'stage:local-archive')
        .single;
    expect(archive.title, '云盘保存完成');
    expect(archive.status, ChatTimelineStatus.done);
    expect(state.isSending, isFalse);
  });

  test('运行中历史 DTO 恢复工具进度且切回不重复订阅', () async {
    final (_, notifier, fake) = await _boot();
    fake.historyByConv['conv-b'] = [
      ChatMessage.fromAgentBusJson({
        'uuid': 'am-b',
        'role': 'agent',
        'status': 'streaming',
        'stream_id': 'live-history',
        'blocks': <dynamic>[],
        'final': false,
      }),
    ];
    await notifier.selectConversation('conv-b');
    await _pump(6);
    expect(fake.subscribed.where((id) => id == 'live-history').length, 1);
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
    await fake.emit('live-history', {
      'eventType': 'tool_call',
      'toolCallId': 'read-pdf',
      'toolName': 'render_local_media',
      'toolArgs': '{}',
    });
    await fake.emit('live-history', {
      'eventType': 'tool_result',
      'toolCallId': 'read-pdf',
      'toolName': 'render_local_media',
      'toolResult': '21 pages',
      'toolStatus': 'succeeded',
    });
    await _pump();
    expect(
        notifier
            .debugSession('conv-b')!
            .messages
            .last
            .timelineEntries
            .any((entry) => entry.key == 'tool:read-pdf'),
        isTrue);
    await notifier.selectConversation('conv-a');
    await notifier.selectConversation('conv-b');
    await _pump();
    expect(fake.subscribed.where((id) => id == 'live-history').length, 1);
    await fake.emit('live-history',
        {'eventType': 'message', 'finished': true, 'content': 'done'});
    await fake.completeStream('live-history');
    await _pump();
    expect(notifier.debugSession('conv-b')!.isSending, isFalse);
  });

  test('回归: 订阅死流直接抛错时目标化收口，不得卡「思考中+停止按钮」', () async {
    final (_, notifier, fake) = await _boot();
    // conv-b 服务端历史遗留一条未终态的 streaming 消息（早期后端/联调事故），
    // 进入会话会 resume 该流；订阅直接失败（流已消亡 → HTTP 错误）。
    fake.throwOnSubscribe.add('dead-stream');
    fake.historyByConv['conv-b'] = [
      ChatMessage(
        messageId: 'um-b',
        role: ChatRole.question,
        content: '几点了'
      ),
      ChatMessage(
        messageId: 'am-b',
        role: ChatRole.answer,
        content: '',
        status: BubbleStatus.loading,
        streamId: 'dead-stream',
      ),
    ];

    await notifier.selectConversation('conv-b');
    await _pump(6);

    final b = notifier.debugSession('conv-b')!;
    expect(b.isSending, isFalse, reason: '订阅抛错后必须收口发送态，不能留红色停止按钮');
    expect(b.activeStreamId, isNull);
    expect(b.messages.last.isLoading, isFalse, reason: '思考中 placeholder 必须收口');

    // 再次进出会话：死流不再自动 resume（避免 失败→收口→再订阅 抖动循环）。
    final before = fake.subscribed.where((s) => s == 'dead-stream').length;
    await notifier.selectConversation('conv-a');
    await notifier.selectConversation('conv-b');
    await _pump(6);
    expect(fake.subscribed.where((s) => s == 'dead-stream').length, before);
    expect(notifier.debugSession('conv-b')!.isSending, isFalse);

    // 其他会话不受影响：A 仍可正常发送并行流。
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await fake.emit('stream-a', {'eventType': 'message', 'content': 'A1'});
    await _pump();
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1');
  });

  test('回归: send 后订阅立即抛错，发起会话收口且不影响其他会话', () async {
    final (_, notifier, fake) = await _boot();
    fake.throwOnSubscribe.add('stream-a');
    // send 返回时服务端已落库这两条消息；订阅失败后的对账以此为真相。
    fake.historyByConv['conv-a'] = [
      ChatMessage(
        messageId: 'um-a',
        role: ChatRole.question,
        content: '问A'
      ),
      ChatMessage(
        messageId: 'am-a',
        role: ChatRole.answer,
        content: '',
        status: BubbleStatus.error,
      ),
    ];
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await _pump(6);

    final a = notifier.debugSession('conv-a')!;
    expect(a.isSending, isFalse, reason: '订阅失败必须收口，不能卡停止按钮');
    expect(a.messages, isNotEmpty);
    expect(a.messages.last.isLoading, isFalse);

    // B 完全不受影响。
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');
    await fake.emit('stream-b', {'eventType': 'message', 'content': 'B1'});
    await _pump();
    expect(notifier.debugSession('conv-b')!.messages.last.content, 'B1');
    expect(notifier.debugSession('conv-b')!.isSending, isTrue);
  });

  test('V10: 切回运行中会话不产生第二条 subscription', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await notifier.selectConversation('conv-b');
    await notifier.selectConversation('conv-a'); // 切回运行中的 A
    await _pump();
    expect(fake.subscribed.where((s) => s == 'stream-a').length, 1);
    // 切回后继续收增量。
    await fake.emit('stream-a', {'eventType': 'message', 'content': 'A1'});
    await _pump();
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'A1');
  });

  test('V15: 同会话重复发送被阻止，另一会话可并行发送', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    expect(fake.sendCalls, 1);

    // 同会话生成中再次发送 → 被 C2 闸口拒绝，不产生第二次 POST。
    await notifier.send('再来一条');
    expect(fake.sendCalls, 1);

    // 另一会话并行发送成功。
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');
    expect(fake.sendCalls, 2);
  });

  test('V7/V19: pending→real 无冲突迁移，optimistic 保序、active 保护', () async {
    final (c, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-x';
    notifier.debugSeedSession(pendingKey);

    fake.sendQueue.add(const SendMessageResponse(
      messageId: 'am-p',
      streamId: 'stream-p',
      conversationId: 'conv-real',
      status: '',
      agentId: '',
    ));
    unawaited(notifier.send('第一条'));
    // send 响应回来前用户切到 B（V7 active 保护）。
    await notifier.selectConversation('conv-b');
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-b', reason: 'adopt 不得抢回 active');
    expect(ws.sessions.containsKey(pendingKey), isFalse);
    expect(ws.aliases[pendingKey], 'conv-real');
    final real = notifier.debugSession('conv-real')!;
    expect(real.messages.map((m) => m.content).toList(), ['第一条', '']);
    expect(real.messages.last.messageId, 'am-p');

    // 旧 pending key 经 alias 解析仍能命中 canonical session（C6）。
    expect(notifier.debugSession(pendingKey)!.conversationId, 'conv-real');

    // rekey 后的流事件写入 canonical session。
    await fake.emit('stream-p', {'eventType': 'message', 'content': 'R1'});
    await _pump();
    expect(notifier.debugSession('conv-real')!.messages.last.content, 'R1');
    expect(notifier.debugSession('conv-b')!.messages, isEmpty,
        reason: 'B 不受 adopt/流事件影响');
  });

  test('V8/V17/V18/V19: pending→real 与已存在 real session 合并而非覆盖', () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-x';

    // real session 已因用户点击列表而存在：有服务端历史 + 上传中附件 + 空草稿。
    final histMsg = ChatMessage(
        messageId: 'h1',
        role: ChatRole.answer,
        content: '旧历史',
        status: BubbleStatus.success);
    final realFile = ChatFileItem(
        fileName: 'real.png', fileType: ChatFileType.image, uploading: true);
    notifier.debugSeedSession('conv-real',
        messages: [histMsg], pendingFiles: [realFile], makeActive: false);

    // 草稿留在 real 侧（send 会清发起会话的草稿——正在发送的内容不是草稿；
    // 仲裁 a 档：real 非空、pending 空 → real 胜出）。
    notifier.debugSeedSession('conv-real',
        draft: const ChatComposerDraft(
            revision: 7, text: '海报文案', hasContent: true),
        makeActive: false);
    notifier.debugSeedSession(pendingKey);

    fake.sendQueue.add(const SendMessageResponse(
      messageId: 'am-p',
      streamId: 'stream-p',
      conversationId: 'conv-real',
      status: '',
      agentId: '',
    ));
    unawaited(notifier.send('第一条'));
    // send 响应回来前用户又往 pending 会话加了上传中的附件（迟到附件场景）。
    final pendingFile = ChatFileItem(
        fileName: 'pending.pdf', fileType: ChatFileType.file, uploading: true);
    notifier.debugSeedSession(pendingKey, pendingFiles: [pendingFile]);
    await _pump();

    final merged = notifier.debugSession('conv-real')!;
    // V19: real 服务端历史在前、optimistic 置后、placeholder 原位绑定。
    expect(merged.messages.map((m) => m.content).toList(), ['旧历史', '第一条', '']);
    expect(merged.messages.last.messageId, 'am-p');
    // V17: 非空草稿优先（a 档：pending 已被发送清空、real 非空 → real 胜出）。
    expect(merged.draft.text, '海报文案');
    // V18: 双侧附件按 localUploadId 全保留，real 侧在前。
    expect(merged.pendingFiles.map((f) => f.fileName).toList(),
        ['real.png', 'pending.pdf']);
    expect(merged.isSending, isTrue, reason: '保留 pending 侧运行中 run');
  });

  test('V12: HITL respond 期间切会话，新 placeholder 仍写回原会话', () async {
    final (_, notifier, fake) = await _boot();
    notifier.debugSeedSession('conv-a', messages: [
      ChatMessage(
          messageId: 'am-old',
          role: ChatRole.answer,
          content: '',
          status: BubbleStatus.success,
          agentMessageStatus: 'awaiting_user'),
    ]);
    fake.respondHold = Completer<RespondToAgentMessageResponse>();

    final pending = notifier.respondToAgentMessage(
      agentMessageUuid: 'am-old',
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );
    // 响应回来前切到 B。
    await notifier.selectConversation('conv-b');
    fake.respondHold!.complete(const RespondToAgentMessageResponse(
      streamId: 'stream-r',
      conversationUuid: 'conv-a',
      newAgentMessageUuid: 'am-new',
    ));
    expect(await pending, isTrue);
    await _pump();

    final a = notifier.debugSession('conv-a')!;
    expect(a.messages.last.messageId, 'am-new');
    expect(a.messages.last.isLoading, isTrue);
    expect(a.messages.first.agentMessageStatus, 'final');
    expect(a.isSending, isTrue);
    expect(notifier.debugSession('conv-b')!.messages, isEmpty,
        reason: 'respond 的 placeholder 不得长到 B（V12）');
    // 新流事件仍写回 conv-a。
    await fake.emit('stream-r', {'eventType': 'message', 'content': 'R'});
    await _pump();
    expect(notifier.debugSession('conv-a')!.messages.last.content, 'R');
  });

  test(
      'model HTTP 400 reason survives SSE, history refresh and conversation switch',
      () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '几点了', streamId: 'stream-a', messageId: 'am-a');
    await fake.emit('stream-a', {
      'eventType': 'error',
      'error_code': 'model.request_invalid',
      'error_message': '模型请求格式错误（HTTP 400）。'
    });
    await _pump();
    void check() {
      final answer = notifier.debugSession('conv-a')!.messages.last;
      expect(answer.status, BubbleStatus.error);
      expect(answer.failureCode, 'model.request_invalid');
      expect(answer.failureMessage, '模型请求格式错误（HTTP 400）。');
    }

    check();
    fake.historyByConv['conv-a'] = [
      ChatMessage.fromAgentBusJson({
        'uuid': 'am-a',
        'role': 'agent',
        'status': 'failed',
        'error_code': 'model.request_invalid',
        'error_message': '模型请求格式错误（HTTP 400）。'
      })
    ];
    await notifier.reloadActiveMessages();
    check();
    await notifier.selectConversation('conv-b');
    await notifier.selectConversation('conv-a');
    check();
  });

  test(
      'delivery failure preserves answer, files and safe reason through history reload',
      () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a',
        text: '生成 PPT',
        streamId: 'stream-a',
        messageId: 'am-a');
    final blocks = [
      {'type': 'markdown', 'text': '已生成 PPT'},
      {
        'type': 'file',
        'name': 'report.pptx',
        'mime':
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'size': 1234,
        'local_artifact': {
          'artifact_id': '11111111-1111-4111-8111-111111111111',
          'device_id': '22222222-2222-4222-8222-222222222222',
          'sha256': 'a' * 64
        }
      },
    ];
    await fake.emit('stream-a', {
      'eventType': 'error',
      'error_code': 'chat.deliverable_content_mismatch',
      'error_message': 'secret-provider-body',
      'blocks': blocks,
    });
    await _pump();
    void check() {
      final answer = notifier.debugSession('conv-a')!.messages.last;
      expect(answer.status, BubbleStatus.error);
      expect(answer.content, '已生成 PPT');
      expect(answer.failureMessage, contains('内容或大小未满足交付要求'));
      expect(answer.failureMessage, isNot(contains('secret')));
      expect(answer.empBlocks.single['name'], 'report.pptx');
    }

    check();
    fake.historyByConv['conv-a'] = [
      ChatMessage.fromAgentBusJson({
        'uuid': 'am-a',
        'role': 'agent',
        'status': 'failed',
        'blocks': blocks,
        'error_code': 'chat.deliverable_content_mismatch',
        'error_message': 'secret-provider-body',
      })
    ];
    await notifier.reloadActiveMessages();
    check();
    await notifier.selectConversation('conv-b');
    await notifier.selectConversation('conv-a');
    check();
  });

  for (final kind in ['error', 'stopped']) {
    test('D-01: $kind retains partial local files without turning successful',
        () async {
      final (_, notifier, fake) = await _boot();
      await _sendOn(notifier, fake,
          conv: 'conv-a',
          text: '文件任务',
          streamId: 'stream-a',
          messageId: 'am-a');
      await fake.emit('stream-a', {
        'eventType': kind,
        'error_code': 'zap.upstream_failure',
        'error_message': '任务未完成',
        'blocks': [
          {
            'type': 'file',
            'name': 'partial.txt',
            'mime': 'text/plain',
            'size': 12,
            'archive_status': 'failed',
            'local_artifact': {
              'artifact_id': '11111111-1111-4111-8111-111111111111',
              'device_id': '22222222-2222-4222-8222-222222222222',
              'sha256': 'a' * 64
            }
          }
        ],
      });
      await _pump();
      final state = notifier.debugSession('conv-a')!;
      expect(state.isSending, isFalse);
      expect(
          state.messages.last.empBlocks
              .any((block) => block['name'] == 'partial.txt'),
          isTrue);
      if (kind == 'error') {
        expect(state.messages.last.status, BubbleStatus.error);
      }
    });
  }

  test('V13: 目标 placeholder 不存在时 fail closed，不改写已完成消息', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');

    // 模拟 placeholder 丢失：只留一条已完成消息。
    final done = ChatMessage(
        messageId: 'old-done',
        role: ChatRole.answer,
        content: '已完成的旧回答',
        status: BubbleStatus.success);
    notifier.debugSeedSession('conv-a', messages: [done], isSending: true);

    await fake.emit('stream-a', {'eventType': 'message', 'content': '幽灵增量'});
    await fake.emit('stream-a', {
      'eventType': 'error',
      'error_message': 'boom',
      'error_code': 'x',
    });
    await _pump();

    final a = notifier.debugSession('conv-a')!;
    expect(a.messages.single.content, '已完成的旧回答',
        reason: 'fail closed：不得回退改写最后一条已完成消息（V13）');
    expect(a.messages.single.status, BubbleStatus.success);
    expect(a.isSending, isFalse, reason: '发送态仍要收口');
    expect(a.errorMessage, isNotNull);
  });

  test('V11: 运行中会话的 history reload/append 不覆盖 placeholder 与已积累内容', () async {
    final (_, notifier, fake) = await _boot();
    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await fake.emit('stream-a', {'eventType': 'message', 'content': '已积累'});
    await _pump();

    // 服务端历史此刻还没有这轮消息（只有旧消息）。
    fake.historyByConv['conv-a'] = [
      ChatMessage(
          messageId: 'old-1',
          role: ChatRole.answer,
          content: '很久以前的回答',
          status: BubbleStatus.success),
    ];
    await notifier.reloadActiveMessages();
    await notifier.jumpToLatest();
    await _pump();

    final a = notifier.debugSession('conv-a')!;
    expect(a.messages.last.content, '已积累', reason: '运行中不得被 history 重拉覆盖（V11）');
    expect(a.messages.last.isLoading, isTrue);
    expect(a.isSending, isTrue);
  });

  test('V14: 删除会话 / provider dispose 真正断开底层流并清理', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _MultiStreamFakeSvc();
    final c = ProviderContainer(overrides: [
      chatServiceProvider.overrideWith((ref) => fake),
      digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
      wukongImClientProvider.overrideWithValue(_OfflineImClient()),
    ]);
    await c.read(chatProvider.future);
    await Future<void>.delayed(Duration.zero);
    final notifier = c.read(chatProvider.notifier);

    await _sendOn(notifier, fake,
        conv: 'conv-a', text: '问A', streamId: 'stream-a', messageId: 'am-a');
    await _sendOn(notifier, fake,
        conv: 'conv-b', text: '问B', streamId: 'stream-b', messageId: 'am-b');

    // 删除 A：只断 A 的流（V15 反向：B 不受影响），session/alias 清理。
    await notifier.deleteConversation('conv-a');
    await _pump();
    expect(fake.ctl('stream-a').cancelled, isTrue);
    expect(fake.ctl('stream-b').cancelled, isFalse);
    expect(notifier.debugSession('conv-a'), isNull);

    // dispose（logout/切租户走 ProviderScope 重建触发）：全量真断流。
    c.dispose();
    await _pump();
    expect(fake.ctl('stream-b').cancelled, isTrue,
        reason: 'dispose 必须真取消全部订阅（V14）');
  });

  test('V17: 双侧非空草稿按严格顺序仲裁——active(pending) 侧优先于更高 revision', () async {
    final (c, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-x';
    notifier.debugSeedSession('conv-real',
        draft: const ChatComposerDraft(
            revision: 99, text: '海报文案', hasContent: true),
        makeActive: false);
    notifier.debugSeedSession(pendingKey);

    fake.sendQueue.add(const SendMessageResponse(
      messageId: 'am-p',
      streamId: 'stream-p',
      conversationId: 'conv-real',
      status: '',
      agentId: '',
    ));
    unawaited(notifier.send('第一条'));
    // send 响应回来前用户又在 pending 会话输入了新草稿（revision 更低但 active）。
    notifier.debugSeedSession(pendingKey,
        draft: const ChatComposerDraft(
            revision: 1, text: '偏 UI 设计', hasContent: true));
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.activeConversationId, 'conv-real', reason: 'active 随 adopt 迁移');
    expect(notifier.debugSession('conv-real')!.draft.text, '偏 UI 设计',
        reason: 'b 档：双非空且一侧 active → active 侧优先，不看 revision（V17）');
  });

  test('V6/V18: 上传完成的迟到回调只回写发起会话（经 alias 解析）', () async {
    final (_, notifier, fake) = await _boot();
    await notifier.selectConversation('conv-a');
    fake.uploadHold =
        Completer<({String url, String? uuid, String? driveFileUuid})>();

    unawaited(notifier.addFiles([XFile('/tmp/late.png')]));
    await _pump();
    expect(
        notifier.debugSession('conv-a')!.pendingFiles.single.uploading, isTrue);

    // 上传完成前切到 B。
    await notifier.selectConversation('conv-b');
    fake.uploadHold!.complete((url: '/late', uuid: 'u9', driveFileUuid: 'd9'));
    await _pump();

    final a = notifier.debugSession('conv-a')!;
    expect(a.pendingFiles.single.uploading, isFalse);
    expect(a.pendingFiles.single.fileLink, '/late');
    expect(notifier.debugSession('conv-b')!.pendingFiles, isEmpty,
        reason: '迟到回调不得写入届时 active 的 B（V6）');
  });

  test('P1-1: send 响应前 stop，迟到响应只 canonicalize + stop，不订阅复活', () async {
    final (c, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-x';
    notifier.debugSeedSession(pendingKey);
    fake.sendHold = Completer<SendMessageResponse>();

    final sending = notifier.send('立即停止');
    await _pump();
    expect(fake.sendCalls, 1);
    expect(notifier.debugSession(pendingKey)!.isSending, isTrue);

    await notifier.stop();
    expect(notifier.debugSession(pendingKey)!.isSending, isTrue,
        reason: '等待服务端任务 ID，不能提前宣称停止');

    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-stopped-before-response',
      streamId: 'stream-must-not-subscribe',
      conversationId: 'conv-real-after-stop',
      status: '',
      agentId: '',
    ));
    await sending;
    await _pump();

    final ws = c.read(chatProvider).asData!.value;
    expect(ws.sessions.containsKey(pendingKey), isFalse,
        reason: '停止不应阻止 pending→real canonicalize');
    expect(ws.aliases[pendingKey], 'conv-real-after-stop');
    final real = notifier.debugSession('conv-real-after-stop')!;
    expect(real.isSending, isFalse);
    expect(real.messages.last.messageId, 'am-stopped-before-response');
    expect(fake.stopCalls, contains('am-stopped-before-response'));
    expect(fake.subscribed, isNot(contains('stream-must-not-subscribe')),
        reason: '迟到响应不得重新订阅并复活生成');

    fake.historyByConv['conv-real-after-stop'] = [
      ChatMessage(
        messageId: 'am-stopped-before-response',
        role: ChatRole.answer,
        content: '这段完整结果不应在停止后重新出现',
        empBlocks: const [
          {
            'type': 'file',
            'name': 'partial.txt',
            'local_artifact': {'artifact_id': 'partial'}
          }
        ],
        status: BubbleStatus.success,
        agentMessageStatus: 'final',
      ),
    ];
    await notifier.reloadActiveMessages();
    final afterHistory = notifier.debugSession('conv-real-after-stop')!;
    expect(afterHistory.messages.last.empBlocks.single['name'], 'partial.txt');
    expect(
        afterHistory.messages.last.content, isNot(contains('这段完整结果不应在停止后重新出现')),
        reason: '迟到的 final 历史不得覆盖本地停止投影');
    expect(afterHistory.messages.last.agentMessageStatus, 'cancelled');
  });

  test('P1-2: HITL POST in-flight 占用同会话闸口，阻止 send 与另一条 HITL', () async {
    final (_, notifier, fake) = await _boot();
    notifier.debugSeedSession('conv-a', messages: [
      ChatMessage(
        messageId: 'am-awaiting-1',
        role: ChatRole.answer,
        content: '',
        status: BubbleStatus.success,
        agentMessageStatus: 'awaiting_user',
      ),
      ChatMessage(
        messageId: 'am-awaiting-2',
        role: ChatRole.answer,
        content: '',
        status: BubbleStatus.success,
        agentMessageStatus: 'awaiting_user',
      ),
    ]);
    fake.respondHold = Completer<RespondToAgentMessageResponse>();

    final first = notifier.respondToAgentMessage(
      agentMessageUuid: 'am-awaiting-1',
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );
    await _pump();
    expect(fake.respondCalls, 1);
    expect(notifier.debugSession('conv-a')!.isSending, isFalse,
        reason: 'POST 未返回前还没有可停止的 server run，不伪装 isSending');

    await notifier.send('同会话普通发送应被挡住');
    final second = await notifier.respondToAgentMessage(
      agentMessageUuid: 'am-awaiting-2',
      responseKind: 'approval',
      responsePayload: const {'decision': 'reject'},
    );
    expect(fake.sendCalls, 0);
    expect(second, isFalse);
    expect(fake.respondCalls, 1);

    fake.respondHold!.complete(const RespondToAgentMessageResponse(
      streamId: 'stream-hitl-claim',
      conversationUuid: 'conv-a',
      newAgentMessageUuid: 'am-hitl-claim',
    ));
    expect(await first, isTrue);
    await _pump();
    expect(fake.subscribed, contains('stream-hitl-claim'));
  });

  testWidgets('P1-3: A2A 审批等待期间切到 B，完成状态只回写原会话 A', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const incomingEvents = MethodChannel('easyo/rtc/incoming_panel/events');
    const meetingEvents = MethodChannel('easyo/rtc/meeting/events');
    messenger.setMockMethodCallHandler(incomingEvents, (_) async => null);
    messenger.setMockMethodCallHandler(meetingEvents, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(incomingEvents, null);
      messenger.setMockMethodCallHandler(meetingEvents, null);
    });
    await tester.pumpWidget(MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
      home: const SizedBox(),
    ));
    await tester.pump();
    late ChatNotifier notifier;
    late _MultiStreamFakeSvc fake;
    late bool decided;
    await tester.runAsync(() async {
      final boot = await _boot();
      notifier = boot.$2;
      fake = boot.$3;
      notifier.debugSeedSession('conv-a', messages: [
        ChatMessage(
          messageId: 'am-a2a',
          role: ChatRole.answer,
          content: '',
          status: BubbleStatus.success,
          empBlocks: const [
            {
              'type': 'approval',
              'x_source': 'a2a_approval',
              'approval_request_id': 'approval-1',
            }
          ],
        ),
      ]);
      fake.onA2ADecide = () => notifier.selectConversation('conv-b');
      decided = await notifier.decideA2AApproval(
        approvalRequestId: 'approval-1',
        approved: true,
      );
      await _pump();
    });
    expect(decided, isTrue);

    final aBlock =
        notifier.debugSession('conv-a')!.messages.single.empBlocks.single;
    expect(aBlock['a2a_approval_status'], 'approved');
    expect(notifier.debugSession('conv-b')!.messages, isEmpty,
        reason: '审批完成不得读取届时 active 并污染 B');
    expect(fake.a2aDecisionCalls, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  test('P1-4: around 失败后切到 B，fallback 只更新 A 且不抢回 active', () async {
    final (c, notifier, fake) = await _boot();
    fake.aroundHold = Completer<ChatHistoryAroundData>();
    fake.historyByConv['conv-a'] = [
      ChatMessage(
        messageId: 'fallback-a',
        role: ChatRole.answer,
        content: 'A fallback history',
        status: BubbleStatus.success,
      ),
    ];

    final opening = notifier.selectConversationAtMessage(
      conversationId: 'conv-a',
      messageUuid: 'missing-anchor',
    );
    await _pump();
    await notifier.selectConversation('conv-b');
    fake.aroundHold!.completeError(StateError('around unavailable'));
    await opening;
    await _pump();

    expect(c.read(chatProvider).asData!.value.activeConversationId, 'conv-b');
    expect(notifier.debugSession('conv-a')!.messages.single.messageId,
        'fallback-a');
    expect(notifier.debugSession('conv-b')!.highlightMessageUuid, isNull);
  });

  test('一并项: send 响应时 placeholder 已丢失，停止服务端 run 且不订阅', () async {
    final (_, notifier, fake) = await _boot();
    fake.sendHold = Completer<SendMessageResponse>();
    final sending = notifier.send('目标稍后丢失');
    await _pump();

    final old = ChatMessage(
      messageId: 'old-done',
      role: ChatRole.answer,
      content: '旧回答',
      status: BubbleStatus.success,
    );
    notifier.debugSeedSession('conv-a', messages: [old], isSending: true);
    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-orphan',
      streamId: 'stream-orphan',
      conversationId: 'conv-a',
      status: '',
      agentId: '',
    ));
    await sending;
    await _pump();

    expect(notifier.debugSession('conv-a')!.messages.single.content, '旧回答');
    expect(fake.stopCalls, contains('am-orphan'));
    expect(fake.subscribed, isNot(contains('stream-orphan')));
  });

  test('一并项: 旧 pending alias 删除统一使用 canonical real key', () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-delete';
    notifier.debugSeedSession(pendingKey);
    fake.sendQueue.add(const SendMessageResponse(
      messageId: 'am-delete',
      streamId: 'stream-delete',
      conversationId: 'conv-delete-real',
      status: '',
      agentId: '',
    ));
    unawaited(notifier.send('创建后删除'));
    await _pump();
    expect(notifier.debugSession('conv-delete-real'), isNotNull);

    await notifier.deleteConversation(pendingKey);
    await _pump();
    expect(fake.deleteCalls, ['conv-delete-real']);
    expect(notifier.debugSession('conv-delete-real'), isNull);
  });

  test('V17-c: 双侧非空且均非 active，workspace revision 较大者胜出', () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-v17c';
    notifier.debugSeedSession('conv-v17c-real',
        draft: const ChatComposerDraft(
            revision: 10, text: 'real-old', hasContent: true),
        makeActive: false);
    notifier.debugSeedSession(pendingKey);
    fake.sendHold = Completer<SendMessageResponse>();
    unawaited(notifier.send('触发合并'));
    await _pump();
    notifier.debugSeedSession(pendingKey,
        draft: const ChatComposerDraft(
            revision: 20, text: 'pending-new', hasContent: true),
        makeActive: false);
    await notifier.selectConversation('conv-b');
    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-v17c',
      streamId: 'stream-v17c',
      conversationId: 'conv-v17c-real',
      status: '',
      agentId: '',
    ));
    await _pump();
    expect(notifier.debugSession('conv-v17c-real')!.draft.text, 'pending-new');
  });

  test('V17-d: 双侧非空且 revision 相同，固定选择 canonical real', () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-v17d';
    notifier.debugSeedSession('conv-v17d-real',
        draft: const ChatComposerDraft(
            revision: 7, text: 'real-wins', hasContent: true),
        makeActive: false);
    notifier.debugSeedSession(pendingKey);
    fake.sendHold = Completer<SendMessageResponse>();
    unawaited(notifier.send('触发合并'));
    await _pump();
    notifier.debugSeedSession(pendingKey,
        draft: const ChatComposerDraft(
            revision: 7, text: 'pending-loses', hasContent: true),
        makeActive: false);
    await notifier.selectConversation('conv-b');
    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-v17d',
      streamId: 'stream-v17d',
      conversationId: 'conv-v17d-real',
      status: '',
      agentId: '',
    ));
    await _pump();
    expect(notifier.debugSession('conv-v17d-real')!.draft.text, 'real-wins');
  });

  test('V17-e: 双侧都为空时固定选择 canonical real draft', () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-v17e';
    notifier.debugSeedSession('conv-v17e-real',
        draft: const ChatComposerDraft(revision: 3), makeActive: false);
    notifier.debugSeedSession(pendingKey);
    fake.sendHold = Completer<SendMessageResponse>();
    unawaited(notifier.send('触发合并'));
    await _pump();
    notifier.debugSeedSession(pendingKey,
        draft: const ChatComposerDraft(revision: 9), makeActive: false);
    await notifier.selectConversation('conv-b');
    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-v17e',
      streamId: 'stream-v17e',
      conversationId: 'conv-v17e-real',
      status: '',
      agentId: '',
    ));
    await _pump();
    expect(notifier.debugSession('conv-v17e-real')!.draft.revision, 3);
  });

  test('V18: 相同 localUploadId 冲突按 ready > uploading > failed 合并且顺序稳定',
      () async {
    final (_, notifier, fake) = await _boot();
    const pendingKey = 'pending:agent-v18';
    notifier.debugSeedSession('conv-v18-real',
        pendingFiles: [
          ChatFileItem(
            localUploadId: 'file-ready',
            fileName: 'ready-real.png',
            fileType: ChatFileType.image,
            fileLink: '/ready',
          ),
          ChatFileItem(
            localUploadId: 'file-uploading',
            fileName: 'failed-real.pdf',
            fileType: ChatFileType.file,
          ),
        ],
        makeActive: false);
    notifier.debugSeedSession(pendingKey);
    fake.sendHold = Completer<SendMessageResponse>();
    unawaited(notifier.send('触发附件合并'));
    await _pump();
    notifier.debugSeedSession(pendingKey, pendingFiles: [
      ChatFileItem(
        localUploadId: 'file-ready',
        fileName: 'uploading-pending.png',
        fileType: ChatFileType.image,
        uploading: true,
      ),
      ChatFileItem(
        localUploadId: 'file-uploading',
        fileName: 'uploading-pending.pdf',
        fileType: ChatFileType.file,
        uploading: true,
      ),
      ChatFileItem(
        localUploadId: 'file-new',
        fileName: 'new-pending.txt',
        fileType: ChatFileType.file,
      ),
    ]);
    fake.sendHold!.complete(const SendMessageResponse(
      messageId: 'am-v18',
      streamId: 'stream-v18',
      conversationId: 'conv-v18-real',
      status: '',
      agentId: '',
    ));
    await _pump();

    final files = notifier.debugSession('conv-v18-real')!.pendingFiles;
    expect(files.map((f) => f.localUploadId).toList(),
        ['file-ready', 'file-uploading', 'file-new']);
    expect(files[0].fileName, 'ready-real.png', reason: 'ready 胜过 uploading');
    expect(files[1].fileName, 'uploading-pending.pdf',
        reason: 'uploading 胜过 failed/未就绪');
    expect(files[1].uploading, isTrue);
  });
}
