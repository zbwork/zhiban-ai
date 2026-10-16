// ADR-0026 agent-direct 双通道 prepare / attach 的 DTO + disabled 异常(无依赖,供 service + 编排器复用)。
// 契约见 docs/contracts/agent-bus-client-contract.md §P2.1b。

/// 后端 flag=false / 未接线 → prepare / attach 返回 404 → 抛此异常,调用方据此 fallback 旧路径。
class AgentDirectDisabledException implements Exception {
  const AgentDirectDisabledException();
  @override
  String toString() => 'AgentDirectDisabledException';
}

/// prepare-wukong 返回。
class AgentDirectPrepareResult {
  const AgentDirectPrepareResult({
    required this.conversationUuid,
    required this.roomUuid,
    required this.wukongChannelId,
    required this.wukongChannelType,
    required this.agentUuid,
  });

  final String conversationUuid;
  final String roomUuid;
  final String wukongChannelId;
  final int wukongChannelType;
  final String agentUuid;

  factory AgentDirectPrepareResult.fromJson(Map<String, dynamic> json) {
    return AgentDirectPrepareResult(
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      roomUuid: (json['room_uuid'] ?? '').toString(),
      wukongChannelId: (json['wukong_channel_id'] ?? '').toString(),
      wukongChannelType:
          int.tryParse((json['wukong_channel_type'] ?? '0').toString()) ?? 0,
      agentUuid: (json['agent_uuid'] ?? '').toString(),
    );
  }
}

/// attach-stream 返回。`status ∈ {started, attached, pending, failed}`。
class AgentDirectAttachResult {
  const AgentDirectAttachResult({
    required this.status,
    required this.streamId,
    required this.agentMessageUuid,
    required this.conversationUuid,
    required this.retryAfterMs,
  });

  final String status;
  final String streamId;
  final String agentMessageUuid;
  final String conversationUuid;
  final int retryAfterMs;

  bool get isReady => status == 'started' || status == 'attached';
  bool get isPending => status == 'pending';
  bool get isFailed => status == 'failed';

  factory AgentDirectAttachResult.fromJson(Map<String, dynamic> json) {
    return AgentDirectAttachResult(
      status: (json['status'] ?? '').toString(),
      streamId: (json['stream_id'] ?? '').toString(),
      agentMessageUuid: (json['agent_message_uuid'] ?? '').toString(),
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      retryAfterMs:
          int.tryParse((json['retry_after_ms'] ?? '0').toString()) ?? 0,
    );
  }
}
