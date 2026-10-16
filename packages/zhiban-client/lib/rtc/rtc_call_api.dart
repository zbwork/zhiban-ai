import 'package:dio/dio.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/utils/url_utils.dart';

import 'rtc_client.dart';

/// F16 Phase 1 客户端通话 API。
///
/// 只走 Bus `/api/agent-bus/v1/calls/*`，不碰 admin / WuKong 特权接口。
class RtcCallApi {
  RtcCallApi({Dio? dio}) : _dio = dio ?? request;

  final Dio _dio;

  /// 发起一通通话。[kind] = 'audio' | 'video'（Phase B 起支持 video）。
  /// direct room 需传 [calleeAccountUuid]；group room 可不传，后端会邀请群内 active human 成员。
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async {
    final data = <String, dynamic>{
      'room_uuid': roomUuid,
      'kind': kind
    };
    if (calleeAccountUuid != null && calleeAccountUuid.isNotEmpty) {
      data['callee_account_uuid'] = calleeAccountUuid;
    }
    if (agentUuid != null && agentUuid.isNotEmpty) {
      data['agent_uuid'] = agentUuid;
    }
    if (conversationUuid != null && conversationUuid.isNotEmpty) {
      data['conversation_uuid'] = conversationUuid;
    }
    final resp = await _dio.post(
      '/calls',
      data: data
    );
    return RtcCallSession.fromJson(_responseMap(resp.data));
  }

  /// 1v1 audio 便捷封装（保留向后兼容；新代码用 [createCall]）。
  Future<RtcCallSession> createAudioCall({
    required String roomUuid,
    required String calleeAccountUuid,
  }) =>
      createCall(roomUuid: roomUuid, calleeAccountUuid: calleeAccountUuid);

  Future<RtcCallSession> answer(String callUuid) async {
    final resp =
        await _dio.post('/calls/${Uri.encodeComponent(callUuid)}/answer');
    return RtcCallSession.fromJson(_responseMap(resp.data));
  }

  Future<void> reject(String callUuid) async {
    await _dio.post('/calls/${Uri.encodeComponent(callUuid)}/reject');
  }

  Future<void> cancel(String callUuid) async {
    await _dio.post('/calls/${Uri.encodeComponent(callUuid)}/cancel');
  }

  Future<void> leave(String callUuid) async {
    await _dio.post('/calls/${Uri.encodeComponent(callUuid)}/leave');
  }

  /// 查询通话当前详情（含**全量**参与者、已在会+呼叫中）。
  /// 用于会中收到"别人邀请了新参会人"的 invite 信令后刷新本地参会人列表——
  /// 群通话里 A 邀请 C 时，invite 信令走的是房间群 channel（所有已在会的人都能
  /// 收到），但信令 payload 里只有"谁发起了这次邀请"的身份，没有被邀请人 C 的
  /// 身份；已在会的人 (非 A、非 C) 拿到这条信令后必须主动查一次详情才能同步补上
  /// C 的"呼叫中"状态，不能只靠信令本身。
  Future<RtcCallSession> get(String callUuid) async {
    final resp = await _dio.get('/calls/${Uri.encodeComponent(callUuid)}');
    return RtcCallSession.fromJson(_responseMap(resp.data));
  }

  /// 返回邀请后该通话的**全量**参与者(含已在会的人)，供调用方刷新参会人展示。
  Future<List<RtcCallParticipant>> inviteParticipants({
    required String callUuid,
    required List<String> accountUuids,
  }) async {
    final resp = await _dio.post(
      '/calls/${Uri.encodeComponent(callUuid)}/invite',
      data: <String, dynamic>{'account_uuids': accountUuids},
    );
    final map = _responseMap(resp.data);
    return ((map['participants'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((e) => RtcCallParticipant.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Map<String, dynamic> _responseMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return const <String, dynamic>{};
  }
}

class RtcCallSession {
  const RtcCallSession({
    required this.callUuid,
    required this.state,
    required this.aliyunChannelId,
    required this.rtc,
    this.kind = 'audio',
    this.participants = const <RtcCallParticipant>[],
  });

  final String callUuid;
  final String state;
  final String aliyunChannelId;
  final RtcJoinConfig? rtc;
  final String kind; // 'audio' | 'video'
  final List<RtcCallParticipant> participants;

  bool get canJoin => rtc != null;

  factory RtcCallSession.fromJson(Map<String, dynamic> json) {
    return RtcCallSession(
      callUuid: (json['call_uuid'] ?? '').toString(),
      state: (json['state'] ?? '').toString(),
      aliyunChannelId: (json['aliyun_channel_id'] ?? '').toString(),
      rtc: RtcJoinConfig.fromJson(
          (json['rtc'] as Map?)?.cast<String, dynamic>()),
      kind: (json['kind'] ?? 'audio').toString(),
      participants: ((json['participants'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => RtcCallParticipant.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class RtcCallParticipant {
  const RtcCallParticipant({
    required this.kind,
    required this.role,
    required this.accountId,
    required this.agentId,
    this.accountUuid = '',
    this.displayName = '',
    this.avatarUrl = '',
  });

  final String kind;
  final String role;
  final int accountId;
  final int agentId;
  final String accountUuid;
  final String displayName;
  final String avatarUrl;

  bool get isHuman => kind == 'human' && accountId > 0;
  bool get isCaller => role == 'caller';

  factory RtcCallParticipant.fromJson(Map<String, dynamic> json) {
    int intValue(Object? value) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? 0;
    }

    return RtcCallParticipant(
      kind: (json['kind'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      accountId: intValue(json['account_id']),
      agentId: intValue(json['agent_id']),
      accountUuid: (json['account_uuid'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      avatarUrl: resolveAgentAvatarUrl((json['avatar_url'] ?? '').toString()),
    );
  }
}
