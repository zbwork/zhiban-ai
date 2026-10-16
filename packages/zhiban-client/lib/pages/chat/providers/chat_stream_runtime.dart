import 'package:zhiban_client/pages/chat/providers/chat_answer_reveal.dart';

/// F09 §5.7.2 / 契约 §3.0f C5：单条 `/chat/stream` 订阅的运行时对象。
///
/// 可变对象，**不进入** immutable UI state；由 [ChatStreamRuntimeRegistry]
/// 以 streamId 为主键持有。闭包捕获的 runtime 是事件归属的第一防线：
/// SSE 回调只携带创建时绑定的本对象，绝不读「届时 active 会话」。
class ChatStreamRuntime {
  ChatStreamRuntime({
    required this.streamId,
    required this.conversationId,
    required this.localPlaceholderId,
    this.agentMessageUuid,
  });

  final String streamId;

  /// 目标会话 key。pending→real rekey 时由注册表原子改写为 canonical key。
  String conversationId;

  /// 目标 assistant placeholder 的 [ChatMessage.localId]（C4）。
  final String localPlaceholderId;

  /// 服务端 agent_message_uuid；send/respond 响应或 message_uuid 事件字段绑定。
  String? agentMessageUuid;

  /// 用户主动停止（stop / awaiting_user / done 收口后置 true，吞掉迟到事件）。
  bool stopped = false;

  /// 流已终态收口（done/error/stopped/awaiting_user）。
  bool done = false;

  /// 底层 SSE 订阅的真取消回调（契约 C12）；由 ChatService 订阅时注入。
  void Function()? cancelSubscription;

  /// F09 §5.11：本 stream 独立的正文待显示队列。
  final ChatAnswerRevealBuffer answerReveal = ChatAnswerRevealBuffer();

  /// 当前唯一待执行的 Flutter frame callback id。
  int? answerRevealFrameCallbackId;

  /// 由 Notifier 注入：取消 frame callback 并清空 [answerReveal]。
  void Function()? cancelAnswerReveal;

  /// 真正断开底层连接。幂等。
  void cancel() {
    stopped = true;
    done = true;
    final cancelReveal = cancelAnswerReveal;
    cancelAnswerReveal = null;
    cancelReveal?.call();
    final c = cancelSubscription;
    cancelSubscription = null;
    c?.call();
  }
}

/// 契约 C5/C10：runtime 注册表。streamId 为主键；conversation 维度仅是
/// 辅助查询（stop / 单 run 闸口 / resume 去重），事件归属仍以 runtime 为准。
class ChatStreamRuntimeRegistry {
  final Map<String, ChatStreamRuntime> _byStreamId = {};

  ChatStreamRuntime? byStreamId(String streamId) => _byStreamId[streamId];

  bool contains(String streamId) => _byStreamId.containsKey(streamId);

  Iterable<ChatStreamRuntime> get all => _byStreamId.values;

  void register(ChatStreamRuntime runtime) {
    _byStreamId[runtime.streamId] = runtime;
  }

  void remove(String streamId) {
    _byStreamId.remove(streamId);
  }

  /// 该会话（canonical key）当前活跃的 runtime；一个会话同时最多一条（C2）。
  ChatStreamRuntime? forConversation(String canonicalKey) {
    for (final rt in _byStreamId.values) {
      if (!rt.done && rt.conversationId == canonicalKey) return rt;
    }
    return null;
  }

  /// pending→real rekey：把归属 [from] 的 runtime 原子改绑到 [to]（契约 C6）。
  void rekeyConversation(String from, String to) {
    for (final rt in _byStreamId.values) {
      if (rt.conversationId == from) rt.conversationId = to;
    }
  }

  /// 删除会话：真取消该会话全部 runtime 并移出注册表（契约 C12）。
  void cancelForConversation(String canonicalKey) {
    final ids = <String>[
      for (final rt in _byStreamId.values)
        if (rt.conversationId == canonicalKey) rt.streamId,
    ];
    for (final id in ids) {
      _byStreamId.remove(id)?.cancel();
    }
  }

  /// logout / 切租户 / provider dispose：全量真取消（契约 C12/V14）。
  void cancelAll() {
    final runtimes = _byStreamId.values.toList(growable: false);
    _byStreamId.clear();
    for (final rt in runtimes) {
      rt.cancel();
    }
  }
}
