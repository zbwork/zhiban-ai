import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zhiban_client/network/network.dart';

/// ADR-0026: 客户端历史同步走 agent-bus 代理 `POST /im/wukong/messagesync`,
/// **不直连 WuKong :5001**。返回纯 Dart DTO(payload 已 base64 解码为 JSON map),
/// 由 WukongImClient 映射成 SDK 的 WKSyncChannelMsg。
class WukongSyncMsg {
  WukongSyncMsg({
    required this.messageId,
    required this.messageSeq,
    required this.clientMsgNo,
    required this.fromUid,
    required this.channelId,
    required this.channelType,
    required this.timestamp,
    this.payload,
  });

  final String messageId;
  final int messageSeq;
  final String clientMsgNo;
  final String fromUid;
  final String channelId;
  final int channelType;
  final int timestamp;
  final Map<String, dynamic>? payload;
}

class WukongSyncResult {
  WukongSyncResult({
    required this.startMessageSeq,
    required this.endMessageSeq,
    required this.more,
    required this.messages,
  });

  final int startMessageSeq;
  final int endMessageSeq;
  final int more;
  final List<WukongSyncMsg> messages;
}

class WukongMessageSyncApi {
  WukongMessageSyncApi({Dio? dio}) : _dio = dio ?? request;

  final Dio _dio;

  Future<WukongSyncResult> sync({
    required String channelId,
    required int channelType,
    required int startMessageSeq,
    required int endMessageSeq,
    required int limit,
    required int pullMode,
    String? conversationUuid,
  }) async {
    final resp =
        await _dio.post('/im/wukong/messagesync', data: <String, dynamic>{
      'channel_id': channelId,
      'channel_type': channelType,
      'start_message_seq': startMessageSeq,
      'end_message_seq': endMessageSeq,
      'limit': limit,
      'pull_mode': pullMode,
      if (conversationUuid != null && conversationUuid.isNotEmpty)
        'conversation_uuid': conversationUuid,
    });
    final raw = resp.data;
    if (raw is! Map<String, dynamic>) {
      return WukongSyncResult(
          startMessageSeq: 0, endMessageSeq: 0, more: 0, messages: const []);
    }
    final list = (raw['messages'] as List?) ?? const [];
    final msgs = <WukongSyncMsg>[];
    for (final e in list) {
      if (e is! Map) continue;
      msgs.add(WukongSyncMsg(
        messageId: (e['message_idstr'] ?? e['message_id'] ?? '').toString(),
        messageSeq: _asInt(e['message_seq']),
        clientMsgNo: (e['client_msg_no'] ?? '').toString(),
        fromUid: (e['from_uid'] ?? '').toString(),
        channelId: (e['channel_id'] ?? '').toString(),
        channelType: _asInt(e['channel_type']),
        timestamp: _asInt(e['timestamp']),
        payload: _decodePayload(e['payload']),
      ));
    }
    return WukongSyncResult(
      startMessageSeq: _asInt(raw['start_message_seq']),
      endMessageSeq: _asInt(raw['end_message_seq']),
      more: _asInt(raw['more']),
      messages: msgs,
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  /// WuKong payload 是 base64(原始消息体);解码为 JSON map 供 WKSyncMsg 用。
  static Map<String, dynamic>? _decodePayload(dynamic p) {
    if (p is! String || p.isEmpty) return null;
    try {
      final bytes = base64.decode(p);
      final obj = jsonDecode(utf8.decode(bytes));
      return obj is Map<String, dynamic> ? obj : null;
    } catch (_) {
      return null;
    }
  }
}
