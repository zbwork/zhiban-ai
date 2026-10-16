import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/fake_rtc_client.dart';
import 'package:zhiban_client/rtc/rtc_client.dart';

void main() {
  group('RtcJoinConfig.fromJson', () {
    test('null json (rtc=null, Phase 1 noop token) → null', () {
      expect(RtcJoinConfig.fromJson(null), isNull);
    });

    test('missing/empty token → null (不可入会)', () {
      expect(
        RtcJoinConfig.fromJson(
            {'app_id': 'a', 'channel_id': 'c', 'user_id': 'u'}),
        isNull,
      );
      expect(
        RtcJoinConfig.fromJson(
            {'app_id': 'a', 'channel_id': 'c', 'user_id': 'u', 'token': ''}),
        isNull,
      );
    });

    test('full payload → parsed (incl gslb_server)', () {
      final c = RtcJoinConfig.fromJson({
        'app_id': 'app',
        'channel_id': 'rtc_8f3a6c6d2c934fa29a2fb45a8d7e91aa',
        'user_id': 'u',
        'token': 'TKN',
        'expires_at': '2030-01-01T00:00:00Z',
        'gslb_server': 'https://gslb.example.com',
      });
      expect(c, isNotNull);
      expect(c!.appId, 'app');
      expect(c.channelId, 'rtc_8f3a6c6d2c934fa29a2fb45a8d7e91aa');
      expect(c.userId, 'u');
      expect(c.token, 'TKN');
      expect(c.expiresAt, DateTime.utc(2030, 1, 1));
      expect(c.gslbServer, 'https://gslb.example.com');
    });

    test('missing gslb_server → falls back to default', () {
      final c = RtcJoinConfig.fromJson({
        'app_id': 'app',
        'channel_id': 'rtc_x',
        'user_id': 'u',
        'token': 'TKN',
      });
      expect(c, isNotNull);
      expect(c!.gslbServer, kDefaultGslbServer);
    });
  });

  group('FakeRtcClient', () {
    const cfg =
        RtcJoinConfig(appId: 'a', channelId: 'ch', userId: 'u', token: 't');

    test('join emits RtcJoined; leave emits RtcLeft', () async {
      final c = FakeRtcClient();
      await c.initialize();
      final events = <RtcEvent>[];
      final sub = c.events.listen(events.add);

      await c.joinChannel(cfg);
      expect(c.isInCall, isTrue);
      await c.leaveChannel();
      expect(c.isInCall, isFalse);

      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<RtcJoined>().single.channelId, 'ch');
      expect(events.whereType<RtcLeft>().single.channelId, 'ch');
      await sub.cancel();
      await c.dispose();
    });

    test('joinChannel before initialize throws', () async {
      final c = FakeRtcClient();
      await expectLater(c.joinChannel(cfg), throwsStateError);
      await c.dispose();
    });

    test('B: joinChannel records mediaKind (audio default / video)', () async {
      final c = FakeRtcClient();
      await c.initialize();
      await c.joinChannel(cfg);
      expect(c.lastJoinMediaKind, RtcMediaKind.audio);
      await c.joinChannel(cfg, mediaKind: RtcMediaKind.video);
      expect(c.lastJoinMediaKind, RtcMediaKind.video);
      await c.dispose();
    });

    test('B: setCameraEnabled toggles camera skeleton flag', () async {
      final c = FakeRtcClient();
      await c.initialize();
      expect(c.isCameraEnabled, isFalse);
      await c.setCameraEnabled(true);
      expect(c.isCameraEnabled, isTrue);
      await c.setCameraEnabled(false);
      expect(c.isCameraEnabled, isFalse);
      await c.dispose();
    });

    test('leaveChannel is idempotent (no event when not in call)', () async {
      final c = FakeRtcClient();
      await c.initialize();
      final events = <RtcEvent>[];
      final sub = c.events.listen(events.add);
      await c.leaveChannel();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
      await c.dispose();
    });

    test('simulate remote user join/leave + error', () async {
      final c = FakeRtcClient();
      await c.initialize();
      final events = <RtcEvent>[];
      final sub = c.events.listen(events.add);
      c.simulateRemoteUserJoined('peer');
      c.simulateRemoteUserLeft('peer');
      c.simulateError('boom');
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<RtcRemoteUserJoined>().single.userId, 'peer');
      expect(events.whereType<RtcRemoteUserLeft>().single.userId, 'peer');
      expect(events.whereType<RtcError>().single.message, 'boom');
      await sub.cancel();
      await c.dispose();
    });

    test('mic mute toggle', () async {
      final c = FakeRtcClient();
      await c.initialize();
      expect(c.isMicMuted, isFalse);
      await c.setMicrophoneMuted(true);
      expect(c.isMicMuted, isTrue);
      await c.dispose();
    });

    test('use after dispose: initialize throws; stray emit swallowed',
        () async {
      final c = FakeRtcClient();
      await c.initialize();
      await c.dispose();
      // dispose 后注入事件应被静默丢弃, 不抛。
      c.simulateError('late');
      // 但显式 API 调用 (initialize) 在 dispose 后必须报错。
      await expectLater(c.initialize(), throwsStateError);
    });
  });
}
