import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/contents/wk_rtc_call_signal_content.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_session_identity.dart';
import 'package:zhiban_client/network/interceptor/response_interceptor.dart';
import 'package:zhiban_client/rtc/dingrtc_client.dart' show RtcNativeException;
import 'package:zhiban_client/rtc/fake_rtc_client.dart';
import 'package:zhiban_client/rtc/rtc_call_api.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/rtc_client.dart';
import 'package:zhiban_client/rtc/rtc_native_incoming_window.dart';
import 'package:zhiban_client/rtc/rtc_native_meeting_window.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_incoming_window.dart';
import 'fake_meeting_window.dart';
import 'fake_tone_player.dart';

/// 记录调用、返回可控 session 的 RtcCallApi fake（覆写全部方法，_dio 永不使用）。
class _FakeApi extends RtcCallApi {
  _FakeApi() : super(dio: Dio());
  final List<String> calls = <String>[];
  String? lastCreateKind; // B 阶段：断言 startOutgoing 透传的 kind
  String? lastAgentUuid;
  String? lastConversationUuid;
  String nextCreateState = 'ringing';
  List<RtcCallParticipant> nextParticipants = const <RtcCallParticipant>[
    RtcCallParticipant(kind: 'human', role: 'caller', accountId: 1, agentId: 0),
    RtcCallParticipant(kind: 'human', role: 'callee', accountId: 2, agentId: 0),
  ];

  RtcCallSession _session(String callUuid) => RtcCallSession(
        callUuid: callUuid,
        state: nextCreateState,
        aliyunChannelId: 'rtc_test',
        rtc: const RtcJoinConfig(
            appId: 'a', channelId: 'rtc_test', userId: 'u', token: 'TKN'),
        participants: nextParticipants,
      );

  @override
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async {
    calls.add('create');
    lastCreateKind = kind;
    lastAgentUuid = agentUuid;
    lastConversationUuid = conversationUuid;
    return _session('call-out');
  }

  @override
  Future<RtcCallSession> answer(String callUuid) async {
    calls.add('answer:$callUuid');
    return _session(callUuid);
  }

  @override
  Future<void> reject(String callUuid) async => calls.add('reject:$callUuid');
  @override
  Future<void> cancel(String callUuid) async => calls.add('cancel:$callUuid');
  @override
  Future<void> leave(String callUuid) async => calls.add('leave:$callUuid');
}

class _CreateErrorApi extends _FakeApi {
  _CreateErrorApi(this.error);
  final Object error;

  @override
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async {
    calls.add('create');
    throw error;
  }
}

class _RoomBusyThenSuccessApi extends _FakeApi {
  bool failedOnce = false;

  @override
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async {
    calls.add('create');
    lastCreateKind = kind;
    if (!failedOnce) {
      failedOnce = true;
      throw DioException(
        requestOptions: RequestOptions(path: '/calls'),
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/calls'),
          statusCode: 409,
          data: <String, dynamic>{'code': 'call.room_busy'},
        ),
      );
    }
    return _session('call-out-retry');
  }
}

class _AccountBusyThenSuccessApi extends _RoomBusyThenSuccessApi {
  @override
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async {
    calls.add('create');
    lastCreateKind = kind;
    lastAgentUuid = agentUuid;
    lastConversationUuid = conversationUuid;
    if (!failedOnce) {
      failedOnce = true;
      throw DioException(
        requestOptions: RequestOptions(path: '/calls'),
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/calls'),
          statusCode: 409,
          data: <String, dynamic>{'code': 'call.account_busy'},
        ),
      );
    }
    return _session('call-out-retry');
  }
}

class _LeaveFailsCancelSucceedsApi extends _FakeApi {
  @override
  Future<void> leave(String callUuid) async {
    calls.add('leave:$callUuid');
    throw DioException(requestOptions: RequestOptions(path: '/leave'));
  }
}

class _EndFailsApi extends _FakeApi {
  @override
  Future<void> leave(String callUuid) async {
    calls.add('leave:$callUuid');
    throw DioException(requestOptions: RequestOptions(path: '/leave'));
  }

  @override
  Future<void> cancel(String callUuid) async {
    calls.add('cancel:$callUuid');
    throw DioException(requestOptions: RequestOptions(path: '/cancel'));
  }
}

class _FakeRecoveryStore implements RtcCallRecoveryStore {
  _FakeRecoveryStore(this.record);

  RtcLastCallRecord? record;
  final writes = <RtcLastCallRecord>[];
  final clears = <String?>[];

  @override
  Future<RtcLastCallRecord?> readLastCall() async => record;

  @override
  Future<void> writeLastCall(RtcLastCallRecord record) async {
    this.record = record;
    writes.add(record);
  }

  @override
  Future<void> clearLastCall({String? callUuid}) async {
    if (callUuid == null || record?.callUuid == callUuid) {
      record = null;
    }
    clears.add(callUuid);
  }
}

class _BusyApi extends _CreateErrorApi {
  _BusyApi(String code, {this.cleanupFails = false})
      : super(DioException(
          requestOptions: RequestOptions(path: '/calls'),
          response: Response(
            requestOptions: RequestOptions(path: '/calls'),
            statusCode: 409,
            data: {'success': false, 'code': 4090, 'message': code},
          ),
        ));
  final bool cleanupFails;

  @override
  Future<void> leave(String id) async {
    calls.add('leave:$id');
    if (cleanupFails) throw StateError('offline');
  }

  @override
  Future<void> cancel(String id) async {
    calls.add('cancel:$id');
    if (cleanupFails) throw StateError('offline');
  }
}

class _BusyHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    options.extra['silent'] = true;
    return ResponseBody.fromString(
        jsonEncode({
          'success': false,
          'code': 4090,
          'message': 'call.account_busy',
        }),
        409,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

/// joinChannel 抛错（模拟入会失败）。
class _FailingJoinClient extends FakeRtcClient {
  @override
  Future<void> joinChannel(RtcJoinConfig config,
      {RtcMediaKind mediaKind = RtcMediaKind.audio}) async {
    throw StateError('join boom');
  }
}

/// leaveChannel 抛错（模拟离会失败 → 必须强制 dispose + 重建）。
class _FailingLeaveClient extends FakeRtcClient {
  @override
  Future<void> leaveChannel() async {
    throw StateError('leave boom');
  }
}

/// joinChannel 抛 RtcNativeException（模拟 native 视频建立 rc != 0，P2-1）。
class _RcFailingJoinClient extends FakeRtcClient {
  @override
  Future<void> joinChannel(RtcJoinConfig config,
      {RtcMediaKind mediaKind = RtcMediaKind.audio}) async {
    throw RtcNativeException('joinChannel', -1);
  }
}

/// setCameraEnabled 抛 RtcNativeException（模拟摄像头 native rc != 0，P2-1）。
class _FailingCameraClient extends FakeRtcClient {
  @override
  Future<void> setCameraEnabled(bool enabled) async {
    throw RtcNativeException('setCameraEnabled', -1);
  }
}

RtcCallSignalIncoming _signal(
  RtcCallSignalEvent event, {
  String callUuid = 'call-in',
  String fromUid = 'peer',
  Map<String, dynamic>? extra,
}) {
  return RtcCallSignalIncoming(
    messageId: 'm1',
    fromUid: fromUid,
    channelId: 't_7_d_room',
    channelType: 2,
    timestamp: 0,
    event: event,
    data: <String, dynamic>{'call_uuid': callUuid, ...?extra},
  );
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

String _fakeJwt({required int tenantId, required String accountUuid}) {
  String seg(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json)));
  final header = seg(<String, dynamic>{'alg': 'none'});
  final payload =
      seg(<String, dynamic>{'act_tid': tenantId, 'sub': accountUuid});
  return '$header.$payload.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<RtcCallSignalIncoming> signals;
  late _FakeApi api;
  late FakeRtcClient client;
  late FakeTonePlayer tone;
  late RtcCallController c;
  final toasts = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signals = StreamController<RtcCallSignalIncoming>.broadcast();
    api = _FakeApi();
    client = FakeRtcClient();
    tone = FakeTonePlayer();
    toasts.clear();
    c = RtcCallController(
      api: api,
      clientFactory: () => client,
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: tone,
    );
  });

  tearDown(() async {
    c.dispose();
    await signals.close();
  });

  // ───── 既有：基本状态流 ─────

  test('self-sent invite ignored; peer invite → incomingRinging (idempotent)',
      () async {
    signals.add(_signal(RtcCallSignalEvent.invite, fromUid: 'me'));
    await tick();
    expect(c.phase, RtcCallPhase.idle);

    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    expect(c.phase, RtcCallPhase.incomingRinging);
    expect(c.direction, RtcCallDirection.incoming);
    expect(c.callUuid, 'call-in');

    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    expect(c.phase, RtcCallPhase.incomingRinging);
  });

  test('incoming invite uses caller identity instead of group fallback',
      () async {
    signals.add(_signal(
      RtcCallSignalEvent.invite,
      callUuid: 'call-in',
      extra: {
        'caller_display_name': '李娜',
        'caller_avatar_url': '/avatars/lina.png',
      },
    ));
    await tick();
    expect(c.peerName, '李娜');
    expect(c.displayName, '李娜');
    expect(c.peerAvatarUrl, resolveAgentAvatarUrl('/avatars/lina.png'));
  });

  test('accept → connecting → active on remote join', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    await c.acceptIncoming();
    expect(api.calls, contains('answer:call-in'));
    expect(c.phase, RtcCallPhase.connecting);
    expect(client.isInCall, isTrue);

    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(c.phase, RtcCallPhase.active);
    expect(c.connectedAt, isNotNull);
  });

  test('reject → idle + api.reject', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    await c.rejectIncoming();
    expect(api.calls, contains('reject:call-in'));
    expect(c.phase, RtcCallPhase.idle);
  });

  test('outgoing → outgoingRinging → active on remote join', () async {
    await c.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', peerName: 'Alice');
    expect(api.calls, contains('create'));
    expect(c.phase, RtcCallPhase.outgoingRinging);
    expect(c.direction, RtcCallDirection.outgoing);
    expect(c.peerName, 'Alice');
    expect(client.isInCall, isTrue);

    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(c.phase, RtcCallPhase.active);
  });

  test('agent outgoing passes agent conversation fields and starts active',
      () async {
    api.nextCreateState = 'active';
    await c.startOutgoing(
      roomUuid: 'r',
      agentUuid: 'agent-1',
      conversationUuid: 'conv-1',
      peerName: '小宜',
      mediaKind: RtcMediaKind.video,
    );
    expect(api.calls, contains('create'));
    expect(api.lastAgentUuid, 'agent-1');
    expect(api.lastConversationUuid, 'conv-1');
    expect(api.lastCreateKind, 'video');
    expect(c.phase, RtcCallPhase.active);
    expect(c.connectedAt, isNotNull);
    expect(client.isInCall, isTrue);
    expect(c.canInviteParticipants, isFalse);
  });

  // F16 A1 · live 转写状态机：partial 原地更新 / end 定稿锁定 / 排序 / 挂断清空+结束信号。
  test('A1: live transcripts upsert, finalize lock, clear + tick on hangup',
      () async {
    api.nextCreateState = 'active';
    await c.startOutgoing(
      roomUuid: 'r',
      agentUuid: 'agent-1',
      conversationUuid: 'conv-1',
      peerName: '小宜',
    );
    expect(c.activeAgentConversationUuid, 'conv-1');

    client.simulateAgentTranscription(const RtcAgentTranscription(
        isUser: true, roundId: 1, end: false, text: '今天', beginTimeMs: 100));
    await tick();
    // partial 累计替换：同 (round, speaker) 原地更新，不另建泡。
    client.simulateAgentTranscription(const RtcAgentTranscription(
        isUser: true, roundId: 1, end: true, text: '今天几号', beginTimeMs: 100));
    client.simulateAgentTranscription(const RtcAgentTranscription(
        isUser: false, roundId: 1, end: false, text: '今天是', beginTimeMs: 200));
    await tick();
    var live = c.liveTranscripts;
    expect(live.length, 2);
    expect(live[0].isUser, isTrue); // 同轮 user 先于 agent
    expect(live[0].text, '今天几号');
    expect(live[0].end, isTrue);
    expect(live[1].isUser, isFalse);
    expect(live[1].text, '今天是');

    // 定稿后迟到 partial 丢弃（不回退文本）。
    client.simulateAgentTranscription(const RtcAgentTranscription(
        isUser: true, roundId: 1, end: false, text: '今', beginTimeMs: 100));
    await tick();
    expect(c.liveTranscripts.first.text, '今天几号');

    // 挂断 → live 全清 + 结束信号递增（聊天侧据此 reload canonical 历史）。
    final tickBefore = c.agentCallEndedTick;
    await c.hangUp();
    expect(c.liveTranscripts, isEmpty);
    expect(c.activeAgentConversationUuid, isNull);
    expect(c.agentCallEndedTick, tickBefore + 1);
    expect(c.lastEndedAgentConversationUuid, 'conv-1');
  });

  test(
      'A3: user speech interrupts open agent live bubble and drops late agent chunks',
      () async {
    api.nextCreateState = 'active';
    await c.startOutgoing(
      roomUuid: 'r',
      agentUuid: 'agent-1',
      conversationUuid: 'conv-1',
      peerName: '小宜',
    );

    client.simulateAgentState(RtcAgentState.responding);
    client.simulateAgentTranscription(const RtcAgentTranscription(
      isUser: false,
      roundId: 9,
      end: false,
      text: '好的，我可以先帮你',
      beginTimeMs: 200,
    ));
    await tick();

    client.simulateAgentTranscription(const RtcAgentTranscription(
      isUser: true,
      roundId: 10,
      end: false,
      text: '等一下',
      beginTimeMs: 300,
    ));
    await tick();

    var live = c.liveTranscripts;
    expect(live.length, 2);
    final agent = live.firstWhere((t) => !t.isUser);
    expect(agent.text, '好的，我可以先帮你');
    expect(agent.end, isTrue);
    expect(agent.interrupted, isTrue);
    expect(live.firstWhere((t) => t.isUser).text, '等一下');

    // 阿里侧同一 round 迟到的 agent final/partial 不应继续拼到已打断半截气泡。
    client.simulateAgentTranscription(const RtcAgentTranscription(
      isUser: false,
      roundId: 9,
      end: true,
      text: '好的，我可以先帮你查询并安排会议室。',
      beginTimeMs: 200,
    ));
    await tick();
    live = c.liveTranscripts;
    expect(live.firstWhere((t) => !t.isUser).text, '好的，我可以先帮你');
    expect(live.firstWhere((t) => !t.isUser).interrupted, isTrue);
  });

  test('agent outgoing join failure leaves active backend call', () async {
    api.nextCreateState = 'active';
    final ctrl = RtcCallController(
      api: api,
      clientFactory: () => _FailingJoinClient(),
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: tone,
    );
    await ctrl.startOutgoing(
      roomUuid: 'r',
      agentUuid: 'agent-1',
      conversationUuid: 'conv-1',
    );
    expect(api.calls, contains('create'));
    expect(api.calls, contains('leave:call-out'));
    expect(api.calls, isNot(contains('cancel:call-out')));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
  });

  test('outgoing busy guard: second start ignored + toast', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    api.calls.clear();
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(api.calls, isEmpty);
    expect(toasts, contains('当前已有通话'));
  });

  test('call api error code is mapped to user-friendly toast', () async {
    final api2 = _CreateErrorApi(DioException(
      requestOptions: RequestOptions(path: '/calls'),
      response: Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/calls'),
        statusCode: 409,
        data: <String, dynamic>{'code': 'call.invalid_state'},
      ),
    ));
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final toasts2 = <String>[];
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => FakeRtcClient(),
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: toasts2.add,
      tonePlayer: FakeTonePlayer(),
    );

    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');

    expect(toasts2, contains('通话状态已变化，请刷新后重试'));
    expect(toasts2.join('\n'), isNot(contains('call.invalid_state')));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
    await sig2.close();
  });

  test(
      'room_busy after hot reload clears persisted stale call and retries once',
      () async {
    final api2 = _RoomBusyThenSuccessApi();
    final store = _FakeRecoveryStore(
      const RtcLastCallRecord(callUuid: 'stale-call', roomUuid: 'r'),
    );
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final toasts2 = <String>[];
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => FakeRtcClient(),
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: toasts2.add,
      tonePlayer: FakeTonePlayer(),
      recoveryStore: store,
    );

    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');

    expect(api2.calls, <String>[
      'create',
      'leave:stale-call',
      'cancel:stale-call',
      'create',
    ]);
    expect(ctrl.callUuid, 'call-out-retry');
    expect(ctrl.phase, RtcCallPhase.outgoingRinging);
    expect(toasts2, contains('已清理上一次未正常结束的通话，请稍候'));
    expect(store.clears, contains('stale-call'));
    expect(store.writes.last.callUuid, 'call-out-retry');
    ctrl.dispose();
    await sig2.close();
  });

  test(
      'account_busy clears persisted stale call from another room and retries once',
      () async {
    final api = _AccountBusyThenSuccessApi();
    final store = _FakeRecoveryStore(
      const RtcLastCallRecord(callUuid: 'stale-call', roomUuid: 'old-room'),
    );
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: api,
      clientFactory: () => FakeRtcClient(),
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
      recoveryStore: store,
    );

    await ctrl.startOutgoing(
      roomUuid: 'new-room',
      agentUuid: 'agent-1',
      conversationUuid: 'conv-1',
      peerName: 'Agent',
      peerAvatarUrl: '/avatars/agent.png',
      mediaKind: RtcMediaKind.video,
    );

    expect(api.calls, <String>[
      'create',
      'leave:stale-call',
      'cancel:stale-call',
      'create',
    ]);
    expect(ctrl.callUuid, 'call-out-retry');
    expect(store.clears, contains('stale-call'));
    expect(api.lastCreateKind, 'video');
    expect(api.lastAgentUuid, 'agent-1');
    expect(api.lastConversationUuid, 'conv-1');
    expect(ctrl.peerAvatarUrl, resolveAgentAvatarUrl('/avatars/agent.png'));
    ctrl.dispose();
    await sig.close();
  });

  for (final scenario in [
    (
      name: 'failed cleanup preserves record',
      code: 'call.account_busy',
      room: 'old-room',
      fails: true,
      hasRecord: true,
      creates: 1,
      cleanups: 2
    ),
    (
      name: 'persistent busy retries only once',
      code: 'call.account_busy',
      room: 'old-room',
      fails: false,
      hasRecord: true,
      creates: 2,
      cleanups: 2
    ),
    (
      name: 'no local record never ends an unknown call',
      code: 'call.account_busy',
      room: 'old-room',
      fails: false,
      hasRecord: false,
      creates: 1,
      cleanups: 0
    ),
    (
      name: 'room busy never cleans another room',
      code: 'call.room_busy',
      room: 'old-room',
      fails: false,
      hasRecord: true,
      creates: 1,
      cleanups: 0
    ),
  ]) {
    test(scenario.name, () async {
      final api = _BusyApi(scenario.code, cleanupFails: scenario.fails);
      final store = _FakeRecoveryStore(scenario.hasRecord
          ? RtcLastCallRecord(callUuid: 'stale-call', roomUuid: scenario.room)
          : null);
      final sig = StreamController<RtcCallSignalIncoming>.broadcast();
      final messages = <String>[];
      final ctrl = RtcCallController(
        api: api,
        clientFactory: () => FakeRtcClient(),
        signalStream: sig.stream,
        selfUid: () => 'me',
        showToast: messages.add,
        tonePlayer: FakeTonePlayer(),
        recoveryStore: store,
      );
      try {
        await ctrl.startOutgoing(
            roomUuid: 'new-room', calleeAccountUuid: 'cee');
        expect(api.calls.where((c) => c == 'create').length, scenario.creates);
        expect(api.calls.where((c) => c != 'create').length, scenario.cleanups);
        expect(ctrl.phase, RtcCallPhase.idle);
        if (scenario.fails || scenario.cleanups == 0) {
          expect(store.clears, isEmpty);
          if (scenario.hasRecord) expect(store.record?.callUuid, 'stale-call');
        }
        if (scenario.code == 'call.account_busy') {
          expect(messages.last, '你或对方正在通话中，请结束后再试');
        }
      } finally {
        ctrl.dispose();
        await sig.close();
      }
    });
  }

  test('real HTTP interceptor preserves busy code for controller feedback',
      () async {
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 500))
      ..httpClientAdapter = _BusyHttpAdapter()
      ..interceptors.add(ResponseInterceptor());
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final messages = <String>[];
    final ctrl = RtcCallController(
      api: RtcCallApi(dio: dio),
      clientFactory: () => FakeRtcClient(),
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: messages.add,
      tonePlayer: FakeTonePlayer(),
      recoveryStore: _FakeRecoveryStore(null),
    );
    try {
      await ctrl.startOutgoing(roomUuid: 'room', calleeAccountUuid: 'peer');
      expect(messages, ['你或对方正在通话中，请结束后再试']);
      expect(ctrl.phase, RtcCallPhase.idle);
    } finally {
      ctrl.dispose();
      dio.close();
      await sig.close();
    }
  });

  test('remote end signal closes the call', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    signals.add(_signal(RtcCallSignalEvent.end, callUuid: c.callUuid!));
    await tick();
    expect(c.phase, RtcCallPhase.idle);
  });

  test('busy invite while active → ignored + toast, stays active', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    final myCall = c.callUuid;
    toasts.clear();
    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'other-call'));
    await tick();
    expect(c.phase, RtcCallPhase.active);
    expect(c.callUuid, myCall);
    expect(toasts, contains('当前已有通话'));
  });

  test('toggleMute toggles native mute in active', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(c.muted, isFalse);
    await c.toggleMute();
    expect(c.muted, isTrue);
    expect(client.isMicMuted, isTrue);
  });

  test('remote user leaves active call → closes', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    client.simulateRemoteUserLeft('peer');
    await tick();
    expect(c.phase, RtcCallPhase.idle);
  });

  // ───── P1-2: connecting 走 /leave，outgoingRinging 才走 /cancel ─────

  test('P1-2 outgoingRinging cancel → /cancel (canCancelOutgoing)', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(c.canCancelOutgoing, isTrue);
    expect(c.canHangUp, isFalse);
    await c.cancelOutgoing();
    expect(api.calls.any((s) => s.startsWith('cancel:')), isTrue);
    expect(c.phase, RtcCallPhase.idle);
  });

  test('outgoingRinging hangUp fallback path uses /cancel first', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    api.calls.clear();
    await c.hangUp();
    expect(api.calls, contains('cancel:call-out'));
    expect(api.calls.any((s) => s.startsWith('leave:')), isFalse);
    expect(c.phase, RtcCallPhase.idle);
  });

  test('P1-2 caller accept → connecting: cancel is no-op, end → /leave',
      () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    signals.add(_signal(RtcCallSignalEvent.accept, callUuid: c.callUuid!));
    await tick();
    expect(c.phase, RtcCallPhase.connecting);
    expect(c.canCancelOutgoing, isFalse);
    expect(c.canHangUp, isTrue);

    api.calls.clear();
    await c.cancelOutgoing(); // 应被 phase 守卫挡住
    expect(api.calls.any((s) => s.startsWith('cancel:')), isFalse);

    await c.hangUp();
    expect(api.calls.any((s) => s.startsWith('leave:')), isTrue);
    expect(c.phase, RtcCallPhase.idle);
  });

  test('P1-2 callee accept → connecting → end → /leave not /cancel', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    await c.acceptIncoming();
    expect(c.phase, RtcCallPhase.connecting);
    api.calls.clear();
    await c.hangUp();
    expect(api.calls, contains('leave:call-in'));
    expect(api.calls.any((s) => s.startsWith('cancel:')), isFalse);
    expect(c.phase, RtcCallPhase.idle);
  });

  test('active hangUp → /leave + leaveChannel + idle', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    await c.hangUp();
    expect(api.calls.any((s) => s.startsWith('leave:')), isTrue);
    expect(c.phase, RtcCallPhase.idle);
    expect(client.isInCall, isFalse);
  });

  test('active hangUp falls back to /cancel when /leave fails', () async {
    final api2 = _LeaveFailsCancelSucceedsApi();
    final store = _FakeRecoveryStore(null);
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => client,
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: tone,
      recoveryStore: store,
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();

    await ctrl.hangUp();
    await tick();

    expect(
        api2.calls,
        containsAllInOrder(<String>[
          'leave:call-out',
          'cancel:call-out'
        ]));
    expect(store.clears, contains('call-out'));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
  });

  test('failed hangUp backend cleanup preserves recovery record', () async {
    final api2 = _EndFailsApi();
    final store = _FakeRecoveryStore(null);
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => client,
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: tone,
      recoveryStore: store,
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();

    await ctrl.hangUp();
    await tick();

    expect(
        api2.calls,
        containsAllInOrder(<String>[
          'leave:call-out',
          'cancel:call-out'
        ]));
    expect(store.record?.callUuid, 'call-out');
    expect(store.clears, isNot(contains('call-out')));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
  });

  test('active remote left last participant → best-effort /leave + idle',
      () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(c.phase, RtcCallPhase.active);

    api.calls.clear();
    client.simulateRemoteUserLeft('peer');
    await tick();
    await tick();

    expect(api.calls, contains('leave:call-out'));
    expect(c.phase, RtcCallPhase.idle);
    expect(client.isInCall, isFalse);
  });

  test('active rtc error → best-effort /leave + idle', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(c.phase, RtcCallPhase.active);

    api.calls.clear();
    client.simulateError('boom');
    await tick();
    await tick();

    expect(api.calls, contains('leave:call-out'));
    expect(c.phase, RtcCallPhase.idle);
    expect(client.isInCall, isFalse);
  });

  // ───── P1-1: join 失败必须清后端 ─────

  test('P1-1 outgoing create ok + join fail → best-effort /cancel + idle',
      () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => _FailingJoinClient(),
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(api2.calls, containsAll(<String>['create', 'cancel:call-out']));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
    await sig2.close();
  });

  // P2（Codex）：join 失败 toast 必须随媒介切换，不再写死「语音」。
  // P2-1: native 视频建立 rc != 0（RtcNativeException）→ join-fail 清理（/cancel）+ 视频文案 toast。
  test('P2 video join native rc!=0 → /cancel 清理 + toast「发起视频通话失败」(非语音)',
      () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final toasts2 = <String>[];
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => _RcFailingJoinClient(), // rc!=0 → RtcNativeException
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: toasts2.add,
      tonePlayer: FakeTonePlayer(),
    );
    await ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    expect(api2.calls.any((s) => s.startsWith('cancel:')),
        isTrue); // 走 join-fail 清理
    expect(toasts2.any((t) => t.contains('发起视频通话失败')), isTrue);
    expect(toasts2.any((t) => t.contains('语音')), isFalse);
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
    await sig2.close();
  });

  // P2-1: 摄像头 native rc != 0（setCameraEnabled 抛）→ cameraOn 回滚，不留错误 UI 态。
  test('P2 toggleCamera native rc!=0 → cameraOn 回滚', () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final client2 = _FailingCameraClient();
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => client2,
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
    );
    await ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    client2.simulateRemoteUserJoined('peerX');
    await tick();
    expect(ctrl.phase, RtcCallPhase.active);
    expect(ctrl.cameraOn, isTrue);
    await ctrl.toggleCamera(); // setCameraEnabled 抛 → 回滚
    expect(ctrl.cameraOn, isTrue); // 仍 true（未真正关掉）
    ctrl.dispose();
    await sig2.close();
  });

  test('P2 audio join fail → toast「发起语音通话失败」(不回归)', () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final toasts2 = <String>[];
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => _FailingJoinClient(),
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: toasts2.add,
      tonePlayer: FakeTonePlayer(),
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(toasts2.any((t) => t.contains('发起语音通话失败')), isTrue);
    ctrl.dispose();
    await sig2.close();
  });

  test('P1-1 incoming answer ok + join fail → best-effort /leave + idle',
      () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: api2,
      clientFactory: () => _FailingJoinClient(),
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
    );
    sig2.add(_signal(RtcCallSignalEvent.invite, callUuid: 'call-in'));
    await tick();
    await ctrl.acceptIncoming();
    expect(
        api2.calls, containsAll(<String>['answer:call-in', 'leave:call-in']));
    expect(ctrl.phase, RtcCallPhase.idle);
    ctrl.dispose();
    await sig2.close();
  });

  // ───── P1-3: leaveChannel 失败强制 dispose + 重建 client ─────

  test('P1-3 leave fail → dispose + recreate; next start uses new client',
      () async {
    final api2 = _FakeApi();
    final sig2 = StreamController<RtcCallSignalIncoming>.broadcast();
    final clients = <FakeRtcClient>[];
    RtcClient factory() {
      final cl = clients.isEmpty ? _FailingLeaveClient() : FakeRtcClient();
      clients.add(cl);
      return cl;
    }

    final ctrl = RtcCallController(
      api: api2,
      clientFactory: factory,
      signalStream: sig2.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    clients.first.simulateRemoteUserJoined('peer');
    await tick();
    expect(ctrl.phase, RtcCallPhase.active);

    await ctrl.hangUp(); // leaveChannel 抛错 → 强制 dispose + 重建
    expect(ctrl.phase, RtcCallPhase.idle);
    expect(clients.length, 2); // 已重建一个新 client

    // 再次发起 → 用新的（第 2 个）client，不再重建
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(ctrl.phase, RtcCallPhase.outgoingRinging);
    expect(clients.length, 2);
    expect(clients[1].isInCall, isTrue); // 新 client 已入会

    ctrl.dispose();
    await sig2.close();
  });

  // ───── B 阶段：1v1 video（kind 透传 / 来电媒介 / join mediaKind / 复位）─────

  test('B: outgoing video → kind=video, isVideo, join mediaKind=video',
      () async {
    await c.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    expect(api.lastCreateKind, 'video');
    expect(c.isVideo, isTrue);
    expect(c.mediaKind, RtcMediaKind.video);
    expect(client.lastJoinMediaKind, RtcMediaKind.video);
    expect(c.statusText, '正在发起视频通话');
  });

  test('B: outgoing default → kind=audio, not video', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(api.lastCreateKind, 'audio');
    expect(c.isVideo, isFalse);
    expect(client.lastJoinMediaKind, RtcMediaKind.audio);
  });

  test('B: incoming video invite → isVideo + 文案; end 复用链路复位 audio', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, extra: {'kind': 'video'}));
    await tick();
    expect(c.phase, RtcCallPhase.incomingRinging);
    expect(c.isVideo, isTrue);
    expect(c.statusText, '邀请你进行视频通话');
    // 结束链路（end/cancel/reject/leave）audio/video 共用。
    signals.add(_signal(RtcCallSignalEvent.end));
    await tick();
    expect(c.phase, RtcCallPhase.idle);
    expect(c.isVideo, isFalse); // 复位回 audio
  });

  test('B: incoming audio invite (无 kind) → not video', () async {
    signals.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    expect(c.isVideo, isFalse);
    expect(c.statusText, '邀请你进行语音通话');
  });

  test('B: accept video invite → join mediaKind=video', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, extra: {'kind': 'video'}));
    await tick();
    await c.acceptIncoming();
    expect(api.calls, contains('answer:call-in'));
    expect(client.lastJoinMediaKind, RtcMediaKind.video);
    expect(c.isVideo, isTrue);
  });

  // ───── B 阶段真实画面：remoteUserId + 摄像头开关 ─────

  test('B: video remote joined → remoteUserId saved; hangUp 清空', () async {
    await c.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    expect(c.remoteUserId, isNull); // 远端未到 → 等待对方加入
    client.simulateRemoteUserJoined('peerX');
    await tick();
    expect(c.phase, RtcCallPhase.active);
    expect(c.remoteUserId, 'peerX');
    await c.hangUp();
    expect(c.remoteUserId, isNull);
    expect(c.cameraOn, isFalse);
  });

  test('B: video cameraOn 默认 true；toggleCamera 翻转 + setCameraEnabled',
      () async {
    await c.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    client.simulateRemoteUserJoined('peerX');
    await tick();
    expect(c.cameraOn, isTrue); // native join(video) 已开摄像头
    await c.toggleCamera();
    expect(c.cameraOn, isFalse);
    expect(client.isCameraEnabled, isFalse);
    await c.toggleCamera();
    expect(c.cameraOn, isTrue);
    expect(client.isCameraEnabled, isTrue);
  });

  test('统一模型: audio call cameraOn 默认 false；toggleCamera = 升级到视频（真实开摄像头）',
      () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peerX');
    await tick();
    expect(c.isVideo, isFalse); // 媒介初始仍 audio（不重建 call_session）
    expect(c.cameraOn, isFalse); // audio = cameraOff 的会议
    await c.toggleCamera(); // 升级：真实 setCameraEnabled(true)，不假成功
    expect(c.cameraOn, isTrue);
    expect(client.isCameraEnabled, isTrue);
    await c.toggleCamera(); // 再次关闭
    expect(c.cameraOn, isFalse);
    expect(client.isCameraEnabled, isFalse);
  });

  test('B: hangUp video → 释放 camera (cameraOn false + native leave ran)',
      () async {
    await c.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    client.simulateRemoteUserJoined('peerX');
    await tick();
    expect(client.isInCall, isTrue);
    await c.hangUp();
    expect(c.cameraOn, isFalse);
    expect(client.isInCall, isFalse); // native leaveChannel→releaseVideoCapture
  });

  // ───── 提示音：拨号回铃 / 来电铃声（状态切换自动停止，不残留）─────

  test('Tone: outgoing start → playOutgoingRingback', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    expect(tone.outgoing, 1);
  });

  test('Tone: outgoing cancel → stop', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    await c.cancelOutgoing();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: outgoing 收到对端 accept 信令 → stop', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    signals.add(_signal(RtcCallSignalEvent.accept, callUuid: 'call-out'));
    await tick();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: remote joined（接通）→ stop', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    client.simulateRemoteUserJoined('peer');
    await tick();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: incoming invite → playIncomingRingtone', () async {
    signals.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    expect(tone.incoming, 1);
  });

  test('Tone: incoming accept → stop', () async {
    signals.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await c.acceptIncoming();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: incoming reject → stop', () async {
    signals.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await c.rejectIncoming();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: incoming 对端 cancel/end → stop', () async {
    signals.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    signals.add(_signal(RtcCallSignalEvent.cancel));
    await tick();
    expect(tone.stops, greaterThan(0));
  });

  test('Tone: busy invite ignored → 不播放新 ringtone', () async {
    await c.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee'); // 占线
    signals.add(_signal(RtcCallSignalEvent.invite, callUuid: 'other'));
    await tick();
    expect(tone.incoming, 0);
  });

  test('Tone: self signal ignored → 不播放', () async {
    signals.add(_signal(RtcCallSignalEvent.invite, fromUid: 'me'));
    await tick();
    expect(tone.incoming, 0);
  });

  test('Tone: join fail cleanup → stop', () async {
    final t = FakeTonePlayer();
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: _FakeApi(),
      clientFactory: () => _RcFailingJoinClient(),
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: t,
    );
    await ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    expect(t.stops, greaterThan(0)); // join fail → _endLocally → _reset → stop
    ctrl.dispose();
    await sig.close();
  });

  test('Tone: dispose → stop + dispose', () async {
    final t = FakeTonePlayer();
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: _FakeApi(),
      clientFactory: () => FakeRtcClient(),
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: t,
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    ctrl.dispose();
    expect(t.stops, greaterThan(0));
    expect(t.disposes, 1);
    await sig.close();
  });

  // ───── macOS 被叫来电原生独立浮窗（UI 唤醒；状态仍走 HTTP /calls）─────

  ({
    RtcCallController ctrl,
    FakeIncomingWindow ni,
    StreamController<RtcCallSignalIncoming> sig
  }) nativeH({bool shown = true}) {
    final ni = FakeIncomingWindow(shown: shown);
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: _FakeApi(),
      clientFactory: () => FakeRtcClient(),
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
      nativeIncomingWindow: ni,
    );
    return (ctrl: ctrl, ni: ni, sig: sig);
  }

  test('Native: incoming invite → showIncoming + 隐藏 app 内来电卡', () async {
    final h = nativeH();
    h.sig.add(_signal(
      RtcCallSignalEvent.invite,
      extra: {
        'caller_display_name': '李娜',
        'caller_avatar_url': '/avatars/lina.png',
      },
    ));
    await tick();
    await tick();
    expect(h.ni.shows, 1);
    expect(h.ni.lastPeerName, '李娜');
    expect(h.ni.lastPeerAvatarUrl, resolveAgentAvatarUrl('/avatars/lina.png'));
    expect(h.ctrl.inAppIncomingVisible, isFalse); // 原生窗接管
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: showIncoming 返回 false → 仍显示 app 内来电卡', () async {
    final h = nativeH(shown: false);
    h.sig.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await tick();
    expect(h.ni.shows, 1);
    expect(h.ctrl.inAppIncomingVisible, isTrue); // fallback app 内卡
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: accept 事件 → acceptIncoming', () async {
    final h = nativeH();
    h.sig.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await tick();
    h.ni.emit(RtcNativeIncomingAction.accept);
    await tick();
    await tick();
    expect(h.ctrl.phase, anyOf(RtcCallPhase.connecting, RtcCallPhase.active));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: reject 事件 → rejectIncoming（idle）', () async {
    final h = nativeH();
    h.sig.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await tick();
    h.ni.emit(RtcNativeIncomingAction.reject);
    await tick();
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.idle);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: 对端 end → 关原生浮窗（hide）', () async {
    final h = nativeH();
    h.sig.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await tick();
    h.sig.add(_signal(RtcCallSignalEvent.end));
    await tick();
    await tick();
    expect(h.ni.hides, greaterThan(0));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: busy invite → 不弹原生窗', () async {
    final h = nativeH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee'); // 占线
    h.sig.add(_signal(RtcCallSignalEvent.invite, callUuid: 'other'));
    await tick();
    await tick();
    expect(h.ni.shows, 0);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: self invite → 不弹原生窗', () async {
    final h = nativeH();
    h.sig.add(_signal(RtcCallSignalEvent.invite, fromUid: 'me'));
    await tick();
    await tick();
    expect(h.ni.shows, 0);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Native: dispose → hide + dispose', () async {
    final h = nativeH();
    h.sig.add(_signal(RtcCallSignalEvent.invite));
    await tick();
    await tick();
    h.ctrl.dispose();
    expect(h.ni.hides, greaterThan(0));
    expect(h.ni.disposes, 1);
    await h.sig.close();
  });

  // ───── 统一会议模型 · macOS 独立会议窗口（NSWindow；状态仍走 HTTP /calls，1001 只同步 UI）─────

  ({
    RtcCallController ctrl,
    FakeMeetingWindow mw,
    FakeRtcClient cl,
    _FakeApi api,
    StreamController<RtcCallSignalIncoming> sig
  }) meetingH({bool shown = true}) {
    final mw = FakeMeetingWindow(shown: shown);
    final cl = FakeRtcClient();
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final api = _FakeApi();
    final ctrl = RtcCallController(
      api: api,
      clientFactory: () => cl,
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
      nativeMeetingWindow: mw,
    );
    return (ctrl: ctrl, mw: mw, cl: cl, api: api, sig: sig);
  }

  test('Meeting: 接通(active) → showMeeting + nativeMeetingVisible=true',
      () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.active);
    expect(h.mw.shows, 1);
    expect(h.ctrl.nativeMeetingVisible, isTrue); // app 内只显示状态条
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: group keeps multiple remote users; one leaving does not end',
      () async {
    final h = meetingH();
    h.api.nextParticipants = const <RtcCallParticipant>[
      RtcCallParticipant(
          kind: 'human', role: 'caller', accountId: 1, agentId: 0),
      RtcCallParticipant(
          kind: 'human', role: 'invitee', accountId: 2, agentId: 0),
      RtcCallParticipant(
          kind: 'human', role: 'invitee', accountId: 3, agentId: 0),
    ];
    await h.ctrl.startOutgoing(roomUuid: 'r', peerName: '群通话');
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.outgoingRinging);
    expect(h.ctrl.meetingActive, isTrue);
    expect(h.mw.shows, 1);
    expect(h.ctrl.canInviteParticipants, isFalse);
    expect(h.ctrl.callingParticipantNames, <String>['成员 1', '成员 2']);
    expect(h.mw.lastState?.callingParticipantNames, <String>['成员 1', '成员 2']);

    h.cl.simulateRemoteUserJoined('peerA');
    await tick();
    await tick();
    h.cl.simulateRemoteUserJoined('peerB');
    await tick();
    await tick();

    expect(h.ctrl.phase, RtcCallPhase.active);
    expect(h.ctrl.canInviteParticipants, isTrue);
    expect(h.ctrl.remoteUserId, 'peerA');
    expect(h.ctrl.remoteUserIds, <String>['peerA', 'peerB']);
    expect(h.mw.lastState?.remoteUserIds, <String>['peerA', 'peerB']);

    h.cl.simulateRemoteUserLeft('peerA');
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.active);
    expect(h.ctrl.remoteUserId, 'peerB');
    expect(h.ctrl.remoteUserIds, <String>['peerB']);

    h.cl.simulateRemoteUserLeft('peerB');
    await tick();
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.active);
    expect(h.ctrl.meetingActive, isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 群通话入会顺序与邀请顺序相反时，"呼叫中"列表不重复显示已入会的人', () async {
    const tenantId = 7;
    const selfUuid = 'self-uuid';
    const invitee2Uuid = 'u2';
    const invitee1Uuid = 'u1';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'token': _fakeJwt(tenantId: tenantId, accountUuid: selfUuid),
    });
    final h = meetingH();
    h.api.nextParticipants = const <RtcCallParticipant>[
      RtcCallParticipant(
          kind: 'human',
          role: 'caller',
          accountId: 1,
          agentId: 0,
          accountUuid: selfUuid),
      RtcCallParticipant(
          kind: 'human',
          role: 'invitee',
          accountId: 2,
          agentId: 0,
          accountUuid: invitee1Uuid,
          displayName: '用户2'),
      RtcCallParticipant(
          kind: 'human',
          role: 'invitee',
          accountId: 3,
          agentId: 0,
          accountUuid: invitee2Uuid,
          displayName: '刘先生'),
    ];
    await h.ctrl.startOutgoing(roomUuid: 'r', peerName: '群通话');
    await tick();
    expect(h.ctrl.callingParticipantNames, <String>['用户2', '刘先生']);

    // 复现 bug 的关键：后邀请的"刘先生"先入会（入会顺序与邀请顺序相反）。
    final uidInvitee2 = const WukongSessionIdentity(
            tenantId: tenantId, accountUuid: invitee2Uuid)
        .uid;
    h.cl.simulateRemoteUserJoined(uidInvitee2);
    await tick();
    await tick();

    // 已入会的"刘先生"不能再出现在"呼叫中"列表里；只有还没入会的"用户2"在呼叫中。
    expect(h.ctrl.callingParticipantNames, <String>['用户2']);
    expect(h.ctrl.joinedParticipants.map((p) => p.name), <String>['刘先生']);

    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: showMeeting 返回 false → fallback（nativeMeetingVisible=false）',
      () async {
    final h = meetingH(shown: false);
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.mw.shows, 1);
    expect(h.ctrl.nativeMeetingVisible, isFalse); // app 内会议壳 fallback
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: audio 接通也进会议窗口；mediaKind=audio + cameraOff', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.mw.shows, 1);
    expect(h.mw.lastState?.mediaKind, 'audio');
    expect(h.mw.lastState?.cameraOn, isFalse); // audio = cameraOff 的会议
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: video 接通 → mediaKind=video + cameraOn default true', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.mw.lastState?.mediaKind, 'video');
    expect(h.mw.lastState?.cameraOn, isTrue); // video = cameraOn 的会议
    expect(h.mw.lastState?.remoteUserId, 'peerX');
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 原生 hangUp/close 事件 → 挂断（idle）', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    h.mw.emit(RtcMeetingWindowAction.close); // 窗口关闭 = 挂断
    await tick();
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.idle);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 原生 toggleMute/toggleCamera 事件 → 驱动 controller', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    h.mw.emit(RtcMeetingWindowAction.toggleMute);
    await tick();
    expect(h.ctrl.muted, isTrue);
    expect(h.cl.isMicMuted, isTrue);
    h.mw.emit(RtcMeetingWindowAction.toggleCamera); // audio→video 升级
    await tick();
    expect(h.ctrl.cameraOn, isTrue);
    expect(h.cl.isCameraEnabled, isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 原生 switchLayout 事件 → gallery↔speaker + updateMeeting 回推',
      () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: RtcMediaKind.video);
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.ctrl.meetingLayout, RtcMeetingLayout.gallery);
    h.mw.emit(RtcMeetingWindowAction.switchLayout);
    await tick();
    expect(h.ctrl.meetingLayout, RtcMeetingLayout.speaker);
    expect(h.mw.lastState?.layout, RtcMeetingLayout.speaker); // 状态回推原生窗
    h.mw.emit(RtcMeetingWindowAction.switchLayout);
    await tick();
    expect(h.ctrl.meetingLayout, RtcMeetingLayout.gallery);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 原生 toggleParticipants 事件 → 开/关侧栏 + updateMeeting 回推',
      () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.ctrl.participantsPanelOpen, isFalse);
    h.mw.emit(RtcMeetingWindowAction.toggleParticipants);
    await tick();
    expect(h.ctrl.participantsPanelOpen, isTrue);
    expect(h.mw.lastState?.participantsPanelOpen, isTrue); // 状态回推原生窗
    h.mw.emit(RtcMeetingWindowAction.toggleParticipants);
    await tick();
    expect(h.ctrl.participantsPanelOpen, isFalse);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 状态变化（mute/layout/participants）→ updateMeeting 同步', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    final before = h.mw.updates;
    await h.ctrl.toggleMute();
    h.ctrl.switchLayout();
    h.ctrl.toggleParticipants();
    expect(h.mw.updates, greaterThan(before));
    expect(h.mw.lastState?.layout, RtcMeetingLayout.speaker);
    expect(h.mw.lastState?.participantsPanelOpen, isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: 挂断 → hideMeeting + nativeMeetingVisible=false', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    expect(h.ctrl.nativeMeetingVisible, isTrue);
    await h.ctrl.hangUp();
    expect(h.mw.hides, greaterThan(0));
    expect(h.ctrl.nativeMeetingVisible, isFalse);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Meeting: dispose → hide + dispose', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    h.ctrl.dispose();
    expect(h.mw.hides, greaterThan(0));
    expect(h.mw.disposes, 1);
    await h.sig.close();
  });

  test('Meeting: 呼叫态(outgoingRinging) 不进会议窗口（仅 active 才进）', () async {
    final h = meetingH();
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    await tick();
    expect(h.ctrl.phase, RtcCallPhase.outgoingRinging);
    expect(h.mw.shows, 0); // 来电/呼叫阶段是小窗，不进会议窗口
    h.ctrl.dispose();
    await h.sig.close();
  });

  // ───── 设备 picker + 网络状态 + 生命周期 ─────

  Future<void> reachActive(
      ({
        RtcCallController ctrl,
        FakeMeetingWindow mw,
        FakeRtcClient cl,
        _FakeApi api,
        StreamController<RtcCallSignalIncoming> sig
      }) h,
      {RtcMediaKind kind = RtcMediaKind.audio}) async {
    await h.ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: kind);
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    await tick(); // _refreshDevices(listDevices x3) 落地
  }

  test('Device: 接通后拉设备列表 → listDevices 调用 + meetingState 含设备', () async {
    final h = meetingH();
    await reachActive(h);
    expect(h.cl.listDeviceCalls, greaterThanOrEqualTo(3)); // mic+speaker+camera
    expect(h.mw.lastState?.microphoneDevices, isNotEmpty);
    expect(h.mw.lastState?.speakerDevices, isNotEmpty);
    expect(h.mw.lastState?.cameraDevices, isNotEmpty);
    // speakerSupported = PlatformUtils.isMacOS（与 host 相关，不强断言具体值）。
    expect(h.mw.lastState?.speakerSupported, isA<bool>());
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Device: 原生菜单选麦克风成功 → selectDevice + 回读刷新 current', () async {
    final h = meetingH();
    await reachActive(h);
    expect(h.cl.currentDevice(RtcDeviceKind.microphone), 'mic-a');
    final before = h.mw.updates;
    h.mw.emitDeviceSelection(
        const RtcDeviceSelection(RtcDeviceKind.microphone, 'mic-b'));
    await tick();
    await tick();
    expect(h.cl.selectDeviceCalls, 1);
    expect(h.cl.currentDevice(RtcDeviceKind.microphone), 'mic-b'); // 真切换
    expect(h.mw.updates, greaterThan(before)); // 刷新回推原生窗
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Device: 原生菜单选摄像头成功 → selectDevice(camera)', () async {
    final h = meetingH();
    await reachActive(h, kind: RtcMediaKind.video);
    h.mw.emitDeviceSelection(
        const RtcDeviceSelection(RtcDeviceKind.camera, 'cam-b'));
    await tick();
    await tick();
    expect(h.cl.currentDevice(RtcDeviceKind.camera), 'cam-b');
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Device: selectDevice 失败 → toast「切换设备失败」+ current 不变（不假成功）', () async {
    final toasts = <String>[];
    final mw = FakeMeetingWindow(shown: true);
    final cl = FakeRtcClient();
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: _FakeApi(),
      clientFactory: () => cl,
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: FakeTonePlayer(),
      nativeMeetingWindow: mw,
    );
    await ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    await tick();
    cl.failNextSelect = true; // 下次 selectDevice 抛 rc!=0
    mw.emitDeviceSelection(
        const RtcDeviceSelection(RtcDeviceKind.microphone, 'mic-b'));
    await tick();
    await tick();
    expect(toasts, contains('切换设备失败'));
    expect(cl.currentDevice(RtcDeviceKind.microphone), 'mic-a'); // 未改
    ctrl.dispose();
    await sig.close();
  });

  test('Network: 未收到 callback → 不显示假「网络良好」（中性已连接）；收到后真实文案', () async {
    final h = meetingH();
    await reachActive(h);
    expect(h.mw.lastState?.networkText, '已连接'); // 未收到 → 不伪造
    h.cl.simulateNetworkQuality(0); // 良好
    await tick();
    expect(h.mw.lastState?.networkText, '网络良好');
    h.cl.simulateNetworkQuality(2); // 中断
    await tick();
    expect(h.mw.lastState?.networkText, '网络中断');
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Lifecycle: returnToMeeting（原生窗已显示）→ bringToFront', () async {
    final h = meetingH();
    await reachActive(h);
    expect(h.ctrl.nativeMeetingVisible, isTrue);
    h.mw.emit(RtcMeetingWindowAction.restore); // 状态条「回到会议窗口」
    await tick();
    expect(h.mw.bringToFronts, greaterThan(0)); // 恢复/前置，不重复 show
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Lifecycle: 挂断 → hideMeeting + 设备/网络复位', () async {
    final h = meetingH();
    await reachActive(h);
    h.cl.simulateNetworkQuality(1);
    await tick();
    await h.ctrl.hangUp();
    expect(h.mw.hides, greaterThan(0));
    expect(h.ctrl.nativeMeetingVisible, isFalse);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Device: audio 通话也拉到 cameraDevices（摄像头菜单可用）+ toggleCamera 升级', () async {
    final h = meetingH();
    await reachActive(h); // audio
    expect(h.ctrl.isVideo, isFalse);
    expect(h.mw.lastState?.cameraDevices, isNotEmpty); // audio 也有摄像头菜单
    h.mw.emit(RtcMeetingWindowAction.toggleCamera); // 升级到视频
    await tick();
    expect(h.ctrl.cameraOn, isTrue);
    expect(h.cl.isCameraEnabled, isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  // ───── 屏幕共享 ─────

  ({
    RtcCallController ctrl,
    FakeMeetingWindow mw,
    FakeRtcClient cl,
    StreamController<RtcCallSignalIncoming> sig,
    List<String> toasts
  }) shareH() {
    final toasts = <String>[];
    final mw = FakeMeetingWindow(shown: true);
    final cl = FakeRtcClient();
    final sig = StreamController<RtcCallSignalIncoming>.broadcast();
    final ctrl = RtcCallController(
      api: _FakeApi(),
      clientFactory: () => cl,
      signalStream: sig.stream,
      selfUid: () => 'me',
      showToast: toasts.add,
      tonePlayer: FakeTonePlayer(),
      nativeMeetingWindow: mw,
    );
    return (ctrl: ctrl, mw: mw, cl: cl, sig: sig, toasts: toasts);
  }

  Future<void> shareActive(
      ({
        RtcCallController ctrl,
        FakeMeetingWindow mw,
        FakeRtcClient cl,
        StreamController<RtcCallSignalIncoming> sig,
        List<String> toasts
      }) h,
      {RtcMediaKind kind = RtcMediaKind.audio}) async {
    await h.ctrl.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'cee', mediaKind: kind);
    h.cl.simulateRemoteUserJoined('peerX');
    await tick();
    await tick();
    await tick();
  }

  test('Screen: 接通后拉源列表；start 成功 → screenSharing=true + updateMeeting',
      () async {
    final h = shareH();
    await shareActive(h);
    expect(h.cl.listScreenSourceCalls, greaterThanOrEqualTo(1)); // active 自动拉一次
    expect(h.mw.lastState?.screenShareSources, isNotEmpty);
    final before = h.mw.updates;
    await h.ctrl.startScreenShare();
    expect(h.ctrl.screenSharing, isTrue);
    expect(h.cl.isScreenSharing, isTrue);
    expect(h.cl.startScreenShareCalls, 1);
    expect(h.mw.updates, greaterThan(before));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: start 失败(rc) → screenSharing=false + toast「屏幕共享失败」', () async {
    final h = shareH();
    await shareActive(h);
    h.cl.failNextScreenShare = true;
    await h.ctrl.startScreenShare();
    expect(h.ctrl.screenSharing, isFalse); // 回滚，不假成功
    expect(h.toasts, contains('屏幕共享失败'));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: 权限缺失 → toast 提示授权（不假成功）', () async {
    final h = shareH();
    await shareActive(h);
    h.cl.failNextScreenSharePermission = true;
    await h.ctrl.startScreenShare();
    expect(h.ctrl.screenSharing, isFalse);
    expect(h.toasts.any((t) => t.contains('屏幕录制权限')), isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: stop → screenSharing=false + updateMeeting', () async {
    final h = shareH();
    await shareActive(h);
    await h.ctrl.startScreenShare();
    expect(h.ctrl.screenSharing, isTrue);
    await h.ctrl.stopScreenShare();
    expect(h.ctrl.screenSharing, isFalse);
    expect(h.cl.stopScreenShareCalls, greaterThan(0));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: 已共享时重复 start → 不重复 native 调用 + toast「正在共享屏幕」', () async {
    final h = shareH();
    await shareActive(h);
    await h.ctrl.startScreenShare();
    expect(h.cl.startScreenShareCalls, 1);
    await h.ctrl.startScreenShare(); // 重复
    expect(h.cl.startScreenShareCalls, 1); // 未重复 native
    expect(h.toasts, contains('正在共享屏幕'));
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: 原生请求流 start/stop → 驱动 controller', () async {
    final h = shareH();
    await shareActive(h);
    h.mw.emitScreenShareRequest(
        const RtcScreenShareRequest(start: true, sourceId: 'win-1'));
    await tick();
    expect(h.ctrl.screenSharing, isTrue);
    h.mw.emitScreenShareRequest(const RtcScreenShareRequest(start: false));
    await tick();
    expect(h.ctrl.screenSharing, isFalse);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: audio 会议下也能共享', () async {
    final h = shareH();
    await shareActive(h); // audio
    expect(h.ctrl.isVideo, isFalse);
    await h.ctrl.startScreenShare();
    expect(h.ctrl.screenSharing, isTrue);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: hangUp → best-effort stopScreenShare（无残留）', () async {
    final h = shareH();
    await shareActive(h);
    await h.ctrl.startScreenShare();
    expect(h.cl.isScreenSharing, isTrue);
    await h.ctrl.hangUp();
    expect(h.cl.stopScreenShareCalls, greaterThan(0)); // 结束前停了共享
    expect(h.ctrl.screenSharing, isFalse);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: 远端共享事件 → remoteScreenSharing + meetingState', () async {
    final h = shareH();
    await shareActive(h);
    h.cl.simulateRemoteScreenShare(true, 'peerX');
    await tick();
    expect(h.ctrl.remoteScreenSharing, isTrue);
    expect(h.mw.lastState?.remoteScreenSharing, isTrue);
    expect(h.mw.lastState?.remoteScreenUserId, 'peerX');
    h.cl.simulateRemoteScreenShare(false, 'peerX');
    await tick();
    expect(h.ctrl.remoteScreenSharing, isFalse);
    expect(h.mw.lastState?.remoteScreenUserId, isNull);
    h.ctrl.dispose();
    await h.sig.close();
  });

  test('Screen: 非会议（idle/outgoing）start 被守卫忽略', () async {
    final h = shareH();
    await h.ctrl.startScreenShare(); // idle
    expect(h.cl.startScreenShareCalls, 0);
    await h.ctrl.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'cee');
    await h.ctrl.startScreenShare(); // outgoingRinging（非 active/connecting）
    expect(h.cl.startScreenShareCalls, 0);
    h.ctrl.dispose();
    await h.sig.close();
  });
}
