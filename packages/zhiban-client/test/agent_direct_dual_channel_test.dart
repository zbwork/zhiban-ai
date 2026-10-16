import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_dual_channel.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

// ── fakes ─────────────────────────────────────────────────────────────────

class _FakeChatService extends OpenClawChatService {
  AgentDirectPrepareResult? prepareResult;
  Object? prepareError;
  final List<AgentDirectAttachResult> attachQueue = [];
  Object? attachError;
  int prepareCalls = 0;
  int attachCalls = 0;
  int sendMessageCalls = 0;

  @override
  Future<AgentDirectPrepareResult> prepareAgentDirectWuKong(
      String agentUuid) async {
    prepareCalls++;
    if (prepareError != null) throw prepareError!;
    return prepareResult!;
  }

  @override
  Future<AgentDirectAttachResult> attachAgentDirectStream({
    required String conversationUuid,
    required String wukongChannelId,
    required String wukongMessageId,
    String? clientMsgNo,
  }) async {
    attachCalls++;
    if (attachError != null) throw attachError!;
    // 多元素逐个出队;单元素则恒定返回(模拟"一直 pending")。
    if (attachQueue.length > 1) return attachQueue.removeAt(0);
    return attachQueue.last;
  }

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
    return const SendMessageResponse(
      messageId: '',
      streamId: '',
      conversationId: '',
      status: '',
      agentId: '',
    );
  }
}

AgentDirectPrepareResult _prep() => const AgentDirectPrepareResult(
      conversationUuid: 'conv-1',
      roomUuid: 'room-1',
      wukongChannelId: 't_7_d_hash',
      wukongChannelType: 2,
      agentUuid: 'a1',
    );

AgentDirectAttachResult _attach(String status,
        {String streamId = '', int retry = 0, String amu = ''}) =>
    AgentDirectAttachResult(
      status: status,
      streamId: streamId,
      agentMessageUuid: amu,
      conversationUuid: 'conv-1',
      retryAfterMs: retry,
    );

AgentDirectDualChannelSender _sender(
  _FakeChatService svc, {
  bool connected = true,
  WukongMessageSender? send,
  List<Duration>? slept,
  int maxAttachAttempts = 10,
}) {
  return AgentDirectDualChannelSender(
    service: svc,
    wukongSend: send ?? (c, t, blocks, summary) async => 'srv-msg-1',
    isWukongConnected: () => connected,
    sleep: (d) async {
      slept?.add(d);
    },
    maxAttachAttempts: maxAttachAttempts,
  );
}

// ── orchestrator tests ──────────────────────────────────────────────────────

void main() {
  group('AgentDirectDualChannelSender', () {
    test('disabled (prepare 404) → fallback(disabled), 不发 WuKong / 不 attach',
        () async {
      final svc = _FakeChatService()
        ..prepareError = const AgentDirectDisabledException();
      var wukongSends = 0;
      final out = await _sender(svc, send: (c, t, blocks, summary) async {
        wukongSends++;
        return 'x';
      }).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );

      expect(out.kind, AgentDirectSendKind.fallback);
      expect(out.disabled, isTrue);
      expect(wukongSends, 0);
      expect(svc.attachCalls, 0);
    });

    test('WuKong 未连 → fallback,且不 prepare', () async {
      final svc = _FakeChatService();
      final out = await _sender(svc, connected: false).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );
      expect(out.kind, AgentDirectSendKind.fallback);
      expect(out.disabled, isFalse);
      expect(svc.prepareCalls, 0);
    });

    test(
        '成功:prepare + WuKong 发 + attach started → streamReady(不调旧 sendMessage)',
        () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('started', streamId: 's1', amu: 'am1'));
      final out = await _sender(svc).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );

      expect(out.kind, AgentDirectSendKind.streamReady);
      expect(out.streamId, 's1');
      expect(out.agentMessageUuid, 'am1');
      expect(out.conversationUuid, 'conv-1');
      expect(out.roomUuid, 'room-1');
      expect(out.wukongChannelId, 't_7_d_hash');
      expect(out.wukongChannelType, 2);
      expect(svc.attachCalls, 1);
      expect(svc.sendMessageCalls, 0); // 关键:不走旧 /chat/send
    });

    test('pending → 按 retry_after_ms 等待重试 → attached', () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('pending', retry: 300))
        ..attachQueue.add(_attach('attached', streamId: 's2'));
      final slept = <Duration>[];
      final out = await _sender(svc, slept: slept).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );

      expect(out.kind, AgentDirectSendKind.streamReady);
      expect(out.streamId, 's2');
      expect(svc.attachCalls, 2);
      expect(slept,
          [const Duration(milliseconds: 300)]); // 一次等待,用服务端 retry_after_ms
    });

    test('pending 超时 → failed(有限轮询,不无限)', () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('pending', retry: 500)); // 单元素 → 恒 pending
      final slept = <Duration>[];
      final out = await _sender(svc, slept: slept, maxAttachAttempts: 5).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );

      expect(out.kind, AgentDirectSendKind.failed);
      expect(out.errorMessage, isNotEmpty);
      // 有限轮询(不无限):attach 与 sleep 次数都受 maxAttachAttempts(5)约束。
      expect(svc.attachCalls, 5);
      expect(slept.length, lessThanOrEqualTo(5));
    });

    test('attach failed → failed(不 fake success)', () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('failed'));
      final out = await _sender(svc).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );
      expect(out.kind, AgentDirectSendKind.failed);
    });

    test('WuKong 发送抛错 → failed(不回退,避免双发)', () async {
      final svc = _FakeChatService()..prepareResult = _prep();
      final out = await _sender(svc, send: (c, t, blocks, summary) async {
        throw StateError('wukong send failed');
      }).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );

      expect(out.kind, AgentDirectSendKind.failed);
      expect(svc.attachCalls, 0); // 没发成功就不 attach
    });

    test('clamp:retry_after_ms 过大被收到 2s 上限', () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('pending', retry: 99999))
        ..attachQueue.add(_attach('started', streamId: 's3'));
      final slept = <Duration>[];
      await _sender(svc, slept: slept).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi')
        ],
        summary: 'hi',
      );
      expect(slept.single, const Duration(milliseconds: 2000));
    });

    test('mixed blocks 原样交给 WuKong sender,summary 单独传递', () async {
      final svc = _FakeChatService()
        ..prepareResult = _prep()
        ..attachQueue.add(_attach('started', streamId: 's1', amu: 'am1'));
      List<ImMessageBlock> sentBlocks = const [];
      var sentSummary = '';
      final out = await _sender(svc, send: (c, t, blocks, summary) async {
        sentBlocks = blocks;
        sentSummary = summary;
        return 'srv-msg-1';
      }).send(
        agentUuid: 'a1',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '先看图'),
          ImMessageBlock(
              kind: ImMessageBlockKind.image,
              name: 'a.png',
              url: '/chat/media/ref/preview'),
          ImMessageBlock(
              kind: ImMessageBlockKind.file,
              name: '计划.xlsx',
              url: '/chat/media/ref/download'),
        ],
        summary: '先看图 [图片] 计划.xlsx',
      );

      expect(out.kind, AgentDirectSendKind.streamReady);
      expect(sentBlocks.map((b) => b.kind), [
        ImMessageBlockKind.text,
        ImMessageBlockKind.image,
        ImMessageBlockKind.file,
      ]);
      expect(sentSummary, '先看图 [图片] 计划.xlsx');
    });
  });

  // ── ack-correlation helper tests ──────────────────────────────────────────

  group('sendAgentDirectTextAwaitingServerId', () {
    test('insert 给 clientMsgNo → refresh 填服务端 message_id → 返回该 id', () async {
      final im = _StreamImClient();
      final future = sendAgentDirectTextAwaitingServerId(im, 'ch', 2, 'hi',
          ackTimeout: const Duration(seconds: 2));
      await Future<void>(() {}); // 让 sendTextMessage 解析 + 订阅就绪
      im.emit(_imMsg('ch', 'me', clientMsgNo: 'c1', messageId: '')); // insert
      im.emit(_imMsg('ch', 'me',
          clientMsgNo: 'c1', messageId: 'srv-1', isRefresh: true)); // ack
      expect(await future, 'srv-1');
      expect(im.sends, 1);
    });

    test('refresh 标记 failed → 抛错(调用方据此失败提示)', () async {
      final im = _StreamImClient();
      final future = sendAgentDirectTextAwaitingServerId(im, 'ch', 2, 'hi',
          ackTimeout: const Duration(seconds: 2));
      await Future<void>(() {});
      im.emit(_imMsg('ch', 'me', clientMsgNo: 'c1', messageId: ''));
      im.emit(_imMsg('ch', 'me',
          clientMsgNo: 'c1',
          messageId: '',
          isRefresh: true,
          sendStatus: ImSendStatus.failed));
      expect(future, throwsA(isA<StateError>()));
    });

    test('无 ack → 超时抛 TimeoutException', () async {
      final im = _StreamImClient();
      final future = sendAgentDirectTextAwaitingServerId(im, 'ch', 2, 'hi',
          ackTimeout: const Duration(milliseconds: 80));
      expect(future, throwsA(isA<TimeoutException>()));
    });

    test('忽略其它 channel / 其它发送者', () async {
      final im = _StreamImClient();
      final future = sendAgentDirectTextAwaitingServerId(im, 'ch', 2, 'hi',
          ackTimeout: const Duration(milliseconds: 120));
      await Future<void>(() {});
      im.emit(_imMsg('OTHER', 'me', clientMsgNo: 'x', messageId: 'nope'));
      im.emit(
          _imMsg('ch', 'someone-else', clientMsgNo: 'y', messageId: 'nope2'));
      expect(future, throwsA(isA<TimeoutException>()));
    });
  });
}

// ── stream-emitting fake ImClient (for the helper) ──────────────────────────

ImMessage _imMsg(
  String channelId,
  String fromUid, {
  required String clientMsgNo,
  required String messageId,
  bool isRefresh = false,
  ImSendStatus sendStatus = ImSendStatus.sent,
}) {
  return ImMessage(
    messageId: messageId,
    clientMsgNo: clientMsgNo,
    fromUid: fromUid,
    channelId: channelId,
    channelType: 2,
    timestamp: 0,
    text: 'hi',
    isRefresh: isRefresh,
    sendStatus: sendStatus,
  );
}

class _StreamImClient implements ImClient {
  final StreamController<ImMessage> _ctrl =
      StreamController<ImMessage>.broadcast();
  int sends = 0;

  void emit(ImMessage m) => _ctrl.add(m);

  @override
  String? get connectedUid => 'me';
  @override
  bool get isRealtimeConnected => true;
  @override
  ImConnectionStatus get connectionStatus => ImConnectionStatus.connected;
  @override
  Stream<ImMessage> listenMessages() => _ctrl.stream;
  @override
  Future<void> sendTextMessage(String channelId, int channelType, String text,
      {List<Map<String, dynamic>>? mentions}) async {
    sends++;
  }

  // 其余接口未用。
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
  Stream<ImConversationEvent> listenConversationEvents() =>
      const Stream.empty();
  @override
  Future<int> unreadCount() async => 0;
  @override
  Future<void> markRead(String channelId, int channelType) async {}
  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}
