import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/dingrtc_client.dart';
import 'package:zhiban_client/rtc/rtc_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DingRtcClient.eventFromNative', () {
    test('joined / left / remote / error mapping', () {
      expect(
        DingRtcClient.eventFromNative({'type': 'joined', 'channelId': 'rtc_x'}),
        isA<RtcJoined>().having((e) => e.channelId, 'channelId', 'rtc_x'),
      );
      expect(
        DingRtcClient.eventFromNative({'type': 'left'},
            fallbackChannelId: 'rtc_fallback'),
        isA<RtcLeft>().having((e) => e.channelId, 'channelId', 'rtc_fallback'),
      );
      expect(
        DingRtcClient.eventFromNative(
            {'type': 'remoteUserJoined', 'userId': 'peer'}),
        isA<RtcRemoteUserJoined>().having((e) => e.userId, 'userId', 'peer'),
      );
      expect(
        DingRtcClient.eventFromNative(
            {'type': 'remoteUserLeft', 'userId': 'peer'}),
        isA<RtcRemoteUserLeft>().having((e) => e.userId, 'userId', 'peer'),
      );
      expect(
        DingRtcClient.eventFromNative(
            {'type': 'error', 'code': 33, 'message': 'boom'}),
        isA<RtcError>().having((e) => e.message, 'message', '[33] boom'),
      );
      expect(
        DingRtcClient.eventFromNative({'type': 'networkQuality', 'level': 1}),
        isA<RtcNetworkQuality>().having((e) => e.level, 'level', 1),
      );
      // level 缺失 → 视为未知(3)。
      expect(
        DingRtcClient.eventFromNative({'type': 'networkQuality'}),
        isA<RtcNetworkQuality>().having((e) => e.level, 'level', 3),
      );
      expect(
        DingRtcClient.eventFromNative(
            {'type': 'screenShare', 'scope': 'local', 'active': true}),
        isA<RtcScreenShareStateChanged>()
            .having((e) => e.local, 'local', true)
            .having((e) => e.active, 'active', true),
      );
      expect(
        DingRtcClient.eventFromNative({
          'type': 'screenShare',
          'scope': 'remote',
          'active': true,
          'userId': 'peer'
        }),
        isA<RtcScreenShareStateChanged>()
            .having((e) => e.local, 'local', false)
            .having((e) => e.userId, 'userId', 'peer'),
      );
      expect(
        DingRtcClient.eventFromNative({'type': 'agentState', 'state': 3}),
        isA<RtcAgentStateChanged>()
            .having((e) => e.state, 'state', RtcAgentState.responding)
            .having((e) => e.rawState, 'rawState', 3),
      );
    });

    test('unknown/invalid payload → null', () {
      expect(DingRtcClient.eventFromNative({'type': 'wat'}), isNull);
      expect(DingRtcClient.eventFromNative('not a map'), isNull);
      expect(DingRtcClient.eventFromNative(null), isNull);
    });

    // F16 A1 · RTM 实时转写事件（此前 default→null 丢弃，A1 起必须可达 Dart 层）。
    test('agentTranscription mapping (user/agent + beginTime fallback)', () {
      expect(
        DingRtcClient.eventFromNative({
          'type': 'agentTranscription',
          'speaker': 'user',
          'roundId': 3,
          'end': false,
          'text': '今天几号',
          'reasoning': '',
          'beginTime': 1781118230000,
        }),
        isA<RtcAgentTranscription>()
            .having((e) => e.isUser, 'isUser', true)
            .having((e) => e.roundId, 'roundId', 3)
            .having((e) => e.end, 'end', false)
            .having((e) => e.text, 'text', '今天几号')
            .having((e) => e.beginTimeMs, 'beginTimeMs', 1781118230000),
      );
      expect(
        DingRtcClient.eventFromNative({
          'type': 'agentTranscription',
          'speaker': 'agent',
          'roundId': 3,
          'end': true,
          'text': '今天是 6 月 11 日。',
          'reasoning': '查询会话时间',
        }),
        isA<RtcAgentTranscription>()
            .having((e) => e.isUser, 'isUser', false)
            .having((e) => e.end, 'end', true)
            .having((e) => e.reasoning, 'reasoning', '查询会话时间')
            // beginTime 缺失 → 0（消费方退化为 firstSeenAt 排序）。
            .having((e) => e.beginTimeMs, 'beginTimeMs', 0),
      );
      expect(
        DingRtcClient.eventFromNative({
          'type': 'agentTranscription',
          'speaker': 'unknown',
          'roundId': 4,
          'text': '不能归到用户侧',
        }),
        isNull,
      );
      expect(
        DingRtcClient.eventFromNative({
          'type': 'agentTranscription',
          'roundId': 4,
          'text': '缺 speaker 也不能归到用户侧',
        }),
        isNull,
      );
    });
  });

  group('DingRtcClient method channel', () {
    const methods = MethodChannel('easyo/rtc/methods');
    final calls = <MethodCall>[];
    // 可被各测试覆写的 native 处理器；默认 join/leave 返回 rc=0（成功），其它返回 null。
    late Future<dynamic> Function(MethodCall call) handler;

    DingRtcClient newClient() => DingRtcClient(
          methodChannel: methods,
          eventChannel: const EventChannel('easyo/rtc/events_unused_in_test'),
        );

    setUp(() {
      calls.clear();
      handler = (call) async =>
          (call.method == 'joinChannel' || call.method == 'leaveChannel')
              ? 0
              : null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return handler(call);
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, null);
    });

    test(
        'initialize / join / mute / leave / dispose invoke right methods + args',
        () async {
      // 用真实 method channel(被 mock) + 一个不订阅的 event channel。
      final c = newClient();

      await c.initialize();
      await c.joinChannel(const RtcJoinConfig(
        appId: 'app',
        channelId: 'rtc_abc',
        userId: 'u',
        token: 'TKN',
        gslbServer: 'https://gslb.dingrtc.com',
      ));
      await c.setMicrophoneMuted(true);
      await c.leaveChannel();
      await c.dispose();

      expect(calls.map((c) => c.method).toList(), [
        'initialize',
        'joinChannel',
        'setMicrophoneMuted',
        'leaveChannel',
        'dispose'
      ]);

      final join = calls.firstWhere((c) => c.method == 'joinChannel');
      final args = (join.arguments as Map).cast<String, dynamic>();
      expect(args['appId'], 'app');
      expect(args['channelId'], 'rtc_abc');
      expect(args['userId'], 'u');
      expect(args['token'], 'TKN');
      expect(args['gslbServer'], 'https://gslb.dingrtc.com');
      expect(args['video'], false); // 默认 audio → video=false

      final mute = calls.firstWhere((c) => c.method == 'setMicrophoneMuted');
      expect((mute.arguments as Map)['muted'], true);
    });

    test('B: joinChannel video → args.video=true; setCameraEnabled rc=0 ok',
        () async {
      // join/leave/setCameraEnabled 均返回 rc=0（成功）。
      handler = (call) async => const {
            'joinChannel': 0,
            'leaveChannel': 0,
            'setCameraEnabled': 0,
          }[call.method];
      final c = newClient();
      await c.initialize();
      await c.joinChannel(
        const RtcJoinConfig(
            appId: 'app', channelId: 'rtc_v', userId: 'u', token: 'TKN'),
        mediaKind: RtcMediaKind.video,
      );
      await c.setCameraEnabled(true); // rc=0 → 不抛
      await c.dispose();

      final join = calls.firstWhere((c) => c.method == 'joinChannel');
      expect((join.arguments as Map)['video'], true);
      final cam = calls.firstWhere((c) => c.method == 'setCameraEnabled');
      expect((cam.arguments as Map)['enabled'], true);
    });

    test('B: setCameraEnabled native rc=-1 → throws RtcNativeException',
        () async {
      handler = (call) async => call.method == 'setCameraEnabled' ? -1 : 0;
      final c = newClient();
      await c.initialize();
      await expectLater(
        c.setCameraEnabled(true),
        throwsA(isA<RtcNativeException>()
            .having((e) => e.operation, 'operation', 'setCameraEnabled')),
      );
      await c.dispose();
    });

    test('use after dispose throws on initialize', () async {
      final c = newClient();
      await c.initialize();
      await c.dispose();
      expect(() => c.initialize(), throwsStateError);
    });

    // ───── native return-code hardening ─────

    const cfg = RtcJoinConfig(
        appId: 'app', channelId: 'rtc_abc', userId: 'u', token: 'TKN');

    test('joinChannel native rc=0 → success', () async {
      handler = (call) async => call.method == 'joinChannel' ? 0 : null;
      await newClient().joinChannel(cfg); // 不抛
    });

    test('joinChannel native rc=-1 → throws RtcNativeException', () async {
      handler = (call) async => call.method == 'joinChannel' ? -1 : null;
      await expectLater(
        newClient().joinChannel(cfg),
        throwsA(isA<RtcNativeException>()
            .having((e) => e.operation, 'operation', 'joinChannel')
            .having((e) => e.code, 'code', -1)),
      );
    });

    test('joinChannel native rc=null → throws (treated as failure)', () async {
      handler = (call) async => null; // 未回返回码
      await expectLater(
          newClient().joinChannel(cfg), throwsA(isA<RtcNativeException>()));
    });

    test('leaveChannel native rc=0 → success', () async {
      handler = (call) async => call.method == 'leaveChannel' ? 0 : null;
      await newClient().leaveChannel(); // 不抛
    });

    test('leaveChannel native rc=-1 → throws RtcNativeException', () async {
      handler = (call) async => call.method == 'leaveChannel' ? -1 : null;
      await expectLater(
        newClient().leaveChannel(),
        throwsA(isA<RtcNativeException>()
            .having((e) => e.operation, 'operation', 'leaveChannel')
            .having((e) => e.code, 'code', -1)),
      );
    });

    test('joinChannel PlatformException propagates (not swallowed)', () async {
      handler = (call) async {
        throw PlatformException(code: 'native_boom', message: 'boom');
      };
      await expectLater(
          newClient().joinChannel(cfg), throwsA(isA<PlatformException>()));
    });

    test('leaveChannel PlatformException propagates (not swallowed)', () async {
      handler = (call) async {
        throw PlatformException(code: 'native_boom', message: 'boom');
      };
      await expectLater(
          newClient().leaveChannel(), throwsA(isA<PlatformException>()));
    });

    // ───── 设备 picker（list / select） ─────

    test('listDevices 解析 native 列表 → RtcDeviceInfo（含 is_current）', () async {
      handler = (call) async {
        if (call.method != 'listDevices') return null;
        expect((call.arguments as Map)['kind'], 'microphone');
        return <Map<String, dynamic>>[
          {
            'id': 'mic-a',
            'name': 'MacBook 麦克风',
            'kind': 'microphone',
            'is_current': true
          },
          {
            'id': 'mic-b',
            'name': 'USB 麦克风',
            'kind': 'microphone',
            'is_current': false
          },
          {'id': '', 'name': '空 id 丢弃', 'kind': 'microphone'}, // id 空 → 丢弃
        ];
      };
      final devices = await newClient().listDevices(RtcDeviceKind.microphone);
      expect(devices.length, 2); // 空 id 被过滤
      expect(devices[0].id, 'mic-a');
      expect(devices[0].name, 'MacBook 麦克风');
      expect(devices[0].isCurrent, isTrue);
      expect(devices[1].isCurrent, isFalse);
    });

    test('selectDevice rc=0 → 成功（回读校验通过）', () async {
      handler = (call) async => call.method == 'selectDevice' ? 0 : null;
      await newClient().selectDevice(RtcDeviceKind.camera, 'cam-b'); // 不抛
      final sel = calls.firstWhere((c) => c.method == 'selectDevice');
      expect((sel.arguments as Map)['kind'], 'camera');
      expect((sel.arguments as Map)['deviceId'], 'cam-b');
    });

    test('selectDevice rc=-1（回读不匹配）→ throws RtcNativeException', () async {
      handler = (call) async => call.method == 'selectDevice' ? -1 : null;
      await expectLater(
        newClient().selectDevice(RtcDeviceKind.speaker, 'spk-x'),
        throwsA(isA<RtcNativeException>()
            .having((e) => e.operation, 'operation', 'selectDevice')),
      );
    });

    // ───── 屏幕共享（list / start / stop） ─────

    test('listScreenShareSources 解析 → RtcScreenShareSource（screen/window）',
        () async {
      handler = (call) async {
        if (call.method != 'listScreenShareSources') return null;
        return <Map<String, dynamic>>[
          {'id': 'desk-1', 'name': '内建显示器', 'kind': 'screen'},
          {'id': 'win-1', 'name': 'Safari', 'kind': 'window'},
          {'id': '', 'name': '空 id 丢弃', 'kind': 'window'},
        ];
      };
      final sources = await newClient().listScreenShareSources();
      expect(sources.length, 2);
      expect(sources[0].id, 'desk-1');
      expect(sources[0].kind, RtcScreenShareSourceKind.screen);
      expect(sources[1].kind, RtcScreenShareSourceKind.window);
    });

    test('startScreenShare rc=0 → 成功（透传 sourceId）', () async {
      handler = (call) async => call.method == 'startScreenShare' ? 0 : null;
      await newClient().startScreenShare(sourceId: 'win-1'); // 不抛
      final s = calls.firstWhere((c) => c.method == 'startScreenShare');
      expect((s.arguments as Map)['sourceId'], 'win-1');
    });

    test('startScreenShare rc=-1 → throws RtcNativeException', () async {
      handler = (call) async => call.method == 'startScreenShare' ? -1 : null;
      await expectLater(
        newClient().startScreenShare(),
        throwsA(isA<RtcNativeException>()
            .having((e) => e.operation, 'operation', 'startScreenShare')),
      );
    });

    test('startScreenShare 权限缺失 → PlatformException(screen_permission_denied)',
        () async {
      handler = (call) async {
        if (call.method == 'startScreenShare') {
          throw PlatformException(code: 'screen_permission_denied');
        }
        return null;
      };
      await expectLater(
        newClient().startScreenShare(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'screen_permission_denied')),
      );
    });

    test('stopScreenShare rc=0 → 成功', () async {
      handler = (call) async => call.method == 'stopScreenShare' ? 0 : null;
      await newClient().stopScreenShare(); // 不抛
      expect(calls.any((c) => c.method == 'stopScreenShare'), isTrue);
    });
  });
}
