// chat_respond_notifier_test.dart — ADR-0028 §4.9 / Plan 16 §J HITL 客户端
//
// ChatNotifier.respondToAgentMessage 接线测试. 用最小 fake OpenClawChatService
// 覆盖 service 层, 让 notifier 在 ProviderContainer 中跑真实状态机:
//   1. 成功路径: 调 service.respondToAgentMessage 透传 4 个字段; 旧 awaiting_user
//      气泡 raw status 改成 'final'; 新 assistant placeholder 追加 (messageId=
//      new_agent_message_uuid, streamId=new stream_id, BubbleStatus.loading); 启
//      动新 stream 订阅; 返 true.
//   2. 失败路径: service 抛错 → 旧气泡不动, 不追加 placeholder, 返 false.
//   3. 防双击: 同一 agent_message_uuid 在 flight 中第二次调用返 false, 不重复 POST.
//   4. service 返回空 stream_id → 视作失败, 不追加 placeholder, 返 false.
//
// 复用 agent_direct_cutover_send_test.dart 的 _FakeImClient / _FakeCatalog 模式
// 避开 ChatNotifier.build() 对 WuKong / 数字员工目录的依赖.

import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';

// ---- fake chat service (respondToAgentMessage 专用最小实现) ----

class _RespondCall {
  _RespondCall({
    required this.conversationUuid,
    required this.agentMessageUuid,
    required this.responseKind,
    required this.responsePayload,
  });
  final String conversationUuid;
  final String agentMessageUuid;
  final String responseKind;
  final Map<String, dynamic> responsePayload;
}

class _RespondFakeSvc extends OpenClawChatService {
  final List<_RespondCall> respondCalls = [];
  final List<String> streamIds = [];
  // streamMessage 默认挂起, 让新 placeholder 保持 BubbleStatus.loading (符合"刚 POST 完
  // 等待 runtime 推流"的生产语义)。测试完成时 ProviderContainer.dispose 会触发 _startStream
  // 的 onCancel/finally 路径。
  final Completer<void> _streamHold = Completer<void>();
  void releaseStream() {
    if (!_streamHold.isCompleted) _streamHold.complete();
  }

  /// 注入控制: 拿到 [respondCompleter.future] 决定 respondToAgentMessage 何时 resolve;
  /// 默认立即返回 [respondResult]。
  Completer<RespondToAgentMessageResponse>? respondCompleter;
  RespondToAgentMessageResponse respondResult =
      const RespondToAgentMessageResponse(
    streamId: 'new-stream',
    conversationUuid: 'conv-1',
    newAgentMessageUuid: 'new-am',
  );
  Object? respondThrowError;

  @override
  Future<List<ConversationItem>> listAllConversations(
          {int page = 1,
          int pageSize = 40,
          bool includeHidden = false}) async =>
      const [];
  @override
  Future<List<AgentItem>> listAgents() async => const [];
  @override
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async =>
      const [];
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
  Future<RespondToAgentMessageResponse> respondToAgentMessage({
    required String conversationUuid,
    required String agentMessageUuid,
    required String responseKind,
    required Map<String, dynamic> responsePayload,
  }) async {
    respondCalls.add(_RespondCall(
      conversationUuid: conversationUuid,
      agentMessageUuid: agentMessageUuid,
      responseKind: responseKind,
      responsePayload: responsePayload,
    ));
    if (respondThrowError != null) {
      throw respondThrowError!;
    }
    if (respondCompleter != null) {
      return respondCompleter!.future;
    }
    return respondResult;
  }

  @override
  Future<void> streamMessage({
    required String streamId,
    required Future<void> Function(Map<String, dynamic> json) onEvent,
    required Future<void> Function() onDone,
    ChatStreamCancelHandle? cancelHandle,
  }) async {
    streamIds.add(streamId);
    // 挂起到 releaseStream() 被调; 我们关心的是 streamId 是否被订阅, 而非 stream 终态。
    // 这样新 placeholder 在 assertion 时仍是 BubbleStatus.loading。
    await _streamHold.future;
    await onDone();
  }
}

// ---- 支撑 ChatNotifier.build() 的最小 fake ----

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

// ---- 测试 fixture ----

const _convUuid = 'conv-1';
const _oldAwaitingMsgUuid = 'old-awaiting-am';

/// 把 active conversation 设到 [_convUuid] 并塞一条 awaiting_user assistant message.
Future<ProviderContainer> _bootWithAwaitingMessage(_RespondFakeSvc fake) async {
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => fake),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
    wukongImClientProvider.overrideWithValue(_FakeImClient()),
  ]);
  await c.read(chatProvider.future);
  // 手工塞一个 ChatState: active conversation + awaiting_user assistant message。
  // 借鉴 agent_direct_cutover_send_test 的"直写 notifier.state" 思路, 避免依赖
  // selectConversation 内部 history fetch / WuKong 联动。
  final notifier = c.read(chatProvider.notifier);
  // workspace/sessions 模型：按会话播种（契约 C1，flat copyWith 写路径已移除）。
  notifier.debugSeedSession(_convUuid, messages: [
    ChatMessage(
      role: ChatRole.question,
      content: 'approval demo',
      status: BubbleStatus.success,
    ),
    ChatMessage(
      role: ChatRole.answer,
      content: '',
      status: BubbleStatus.success,
      messageId: _oldAwaitingMsgUuid,
      streamId: 'old-stream',
      agentMessageStatus: 'awaiting_user',
      empBlocks: const [
        {'type': 'approval', 'title': '请审批'},
      ],
    ),
  ]);
  // 单 tearDown 顺序: 先释放 stream hold + 让 onDone 跑完, 再 dispose container。
  // 反过来 (先 dispose 再 release) 会让 onDone 命中 disposed Ref.state 抛 "Cannot use Ref after disposed"。
  addTearDown(() async {
    fake.releaseStream();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
  });
  return c;
}

void main() {
  // BotToast.showText 依赖 SemanticsBinding (动画 reverse), 失败 / empty 路径会调.
  // 单元测试不渲染真实 UI 也不能让 toast 弹出, 但要避免它 throw "Binding not initialized".
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'success path: service 调用透传 4 字段; 旧 awaiting_user 切 final + 新 placeholder 追加 + 订阅新 stream; 返 true',
      () async {
    final fake = _RespondFakeSvc()
      ..respondResult = const RespondToAgentMessageResponse(
        streamId: 'new-stream-xyz',
        conversationUuid: _convUuid,
        newAgentMessageUuid: 'new-am-abc',
      );
    final c = await _bootWithAwaitingMessage(fake);
    final notifier = c.read(chatProvider.notifier);

    final ok = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );

    expect(ok, isTrue);

    // 1) service 入参对齐
    expect(fake.respondCalls.length, 1);
    final call = fake.respondCalls.single;
    expect(call.conversationUuid, _convUuid);
    expect(call.agentMessageUuid, _oldAwaitingMsgUuid);
    expect(call.responseKind, 'approval');
    expect(call.responsePayload, {'decision': 'approve'});

    // 2) 状态更新: 旧 awaiting_user → 'final'; 新 placeholder 追加
    final st = c.read(chatProvider).asData!.value;
    final old =
        st.messages.firstWhere((m) => m.messageId == _oldAwaitingMsgUuid);
    expect(old.agentMessageStatus, 'final',
        reason:
            '旧气泡 raw status 必须切到 final, 让 EmpBlocksView 4 条件 enable fail-out, 按钮锁死');
    final newPh = st.messages.last;
    expect(newPh.messageId, 'new-am-abc');
    expect(newPh.streamId, 'new-stream-xyz');
    expect(newPh.role, ChatRole.answer);
    expect(newPh.status, BubbleStatus.loading);

    // 3) stream 订阅
    expect(fake.streamIds, contains('new-stream-xyz'));
  });

  test(
      'confirm 路径: 透传 response_kind=confirm + payload={confirmed:bool}, '
      '后端 buildRespondReplyBlock confirm 分支才能拿到 confirmed', () async {
    final fake = _RespondFakeSvc()
      ..respondResult = const RespondToAgentMessageResponse(
        streamId: 'new-stream-c',
        conversationUuid: _convUuid,
        newAgentMessageUuid: 'new-am-c',
      );
    final c = await _bootWithAwaitingMessage(fake);
    final notifier = c.read(chatProvider.notifier);

    final ok = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'confirm',
      responsePayload: const {'confirmed': true},
    );
    expect(ok, isTrue);
    expect(fake.respondCalls.single.responseKind, 'confirm');
    expect(fake.respondCalls.single.responsePayload, {'confirmed': true});
  });

  // 失败路径走 BotToast.showText, BotToast 必须在 widget tree 里挂过 BotToastInit
  // (其 GlobalKey 状态被 botToastManager 引用), 否则 assertion fail。所以这两个
  // 测试用 testWidgets + pump 一个最小 MaterialApp+BotToastInit。
  testWidgets(
      'failure path: service 抛错 → 返 false, 旧 awaiting_user 气泡不动, 不追加 placeholder',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
      home: const SizedBox(),
    ));

    final fake = _RespondFakeSvc()..respondThrowError = StateError('boom');
    final c = await _bootWithAwaitingMessage(fake);
    final notifier = c.read(chatProvider.notifier);

    final stBefore = c.read(chatProvider).asData!.value;
    final lenBefore = stBefore.messages.length;
    final oldBefore =
        stBefore.messages.firstWhere((m) => m.messageId == _oldAwaitingMsgUuid);
    expect(oldBefore.agentMessageStatus, 'awaiting_user');

    final ok = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );

    expect(ok, isFalse);
    expect(fake.respondCalls.length, 1);
    final stAfter = c.read(chatProvider).asData!.value;
    expect(stAfter.messages.length, lenBefore,
        reason: '失败时不能追加 placeholder; 旧气泡保留');
    final oldAfter =
        stAfter.messages.firstWhere((m) => m.messageId == _oldAwaitingMsgUuid);
    expect(oldAfter.agentMessageStatus, 'awaiting_user',
        reason: '失败时旧气泡的 raw status 必须保留 awaiting_user, 让用户能重试');
    expect(fake.streamIds, isEmpty);

    // BotToast 自挂 ~2s 自销毁 Timer; pump 足够时间排掉, 避免 "Timer still pending"。
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('empty stream_id 返回 → 视作失败, 不追加 placeholder, 返 false',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
      home: const SizedBox(),
    ));

    final fake = _RespondFakeSvc()
      ..respondResult = const RespondToAgentMessageResponse(
        streamId: '',
        conversationUuid: _convUuid,
        newAgentMessageUuid: '',
      );
    final c = await _bootWithAwaitingMessage(fake);
    final notifier = c.read(chatProvider.notifier);

    final lenBefore = c.read(chatProvider).asData!.value.messages.length;
    final ok = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );

    expect(ok, isFalse);
    final st = c.read(chatProvider).asData!.value;
    expect(st.messages.length, lenBefore);
    expect(fake.streamIds, isEmpty);

    // BotToast 自挂 ~2s 自销毁 Timer; pump 足够时间排掉。
    await tester.pump(const Duration(seconds: 5));
  });

  test('防双击: 同一 agent_message_uuid 在 flight 中第二次调用立即返 false, 不重复 POST',
      () async {
    final fake = _RespondFakeSvc()
      ..respondCompleter = Completer<RespondToAgentMessageResponse>();
    final c = await _bootWithAwaitingMessage(fake);
    final notifier = c.read(chatProvider.notifier);

    final first = notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );

    // 第二次立刻打: 应返 false, 不进入 service.
    final second = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'reject'},
    );
    expect(second, isFalse);
    expect(fake.respondCalls.length, 1,
        reason: '同 uuid 还在 flight, 第二次不能再 POST');

    // 让第一次 resolve, 它应仍能正确收尾。
    fake.respondCompleter!.complete(const RespondToAgentMessageResponse(
      streamId: 'new-stream-double',
      conversationUuid: _convUuid,
      newAgentMessageUuid: 'new-am-double',
    ));
    final ok1 = await first;
    expect(ok1, isTrue);
    expect(fake.respondCalls.length, 1);

    // 契约 §3.0f C2：同会话单 active run——第一轮的新 stream 仍在推流时,
    // 重试会被单 run 闸口拒绝。先让第一轮流终态收口,再验证 finally 清理后
    // 同 uuid 可重新提交（原断言语义:_respondingMessages 正确清理）。
    fake.releaseStream();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // flight 结束, 同 uuid 可以再提交 (例如重试)。这条断言保证 _respondingMessages
    // 在 finally 里正确清理。
    final third = await notifier.respondToAgentMessage(
      agentMessageUuid: _oldAwaitingMsgUuid,
      responseKind: 'approval',
      responsePayload: const {'decision': 'approve'},
    );
    expect(third, isTrue);
    expect(fake.respondCalls.length, 2);
  });
}
