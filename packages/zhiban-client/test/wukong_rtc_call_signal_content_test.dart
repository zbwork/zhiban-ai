import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/contents/wk_rtc_call_signal_content.dart';

void main() {
  group('WkRtcCallSignalContent', () {
    test('contentType is 1001 (F16 spec v0.6.4 §6.2.6 D14)', () {
      final c = WkRtcCallSignalContent();
      expect(c.contentType, kRtcCallSignalContentType);
      expect(kRtcCallSignalContentType, 1001);
    });

    test('encode/decode round-trip: invite', () {
      final original = WkRtcCallSignalContent()
        ..event = RtcCallSignalEvent.invite
        ..data = {
          'call_uuid': 'call-abc',
          'kind': 'audio',
          'host_account_uuid': 'u-1',
        };

      final json = original.encodeJson();
      expect(json['type'], 1001);
      expect(json['event'], 'invite');
      expect(json['data']['call_uuid'], 'call-abc');
      expect(json['data']['kind'], 'audio');

      final decoded =
          WkRtcCallSignalContent().decodeJson(json) as WkRtcCallSignalContent;
      expect(decoded.contentType, 1001);
      expect(decoded.event, RtcCallSignalEvent.invite);
      expect(decoded.data['call_uuid'], 'call-abc');
      expect(decoded.data['kind'], 'audio');
    });

    test('encode/decode round-trip: cancel/accept/reject/end/ringing', () {
      for (final e in [
        RtcCallSignalEvent.cancel,
        RtcCallSignalEvent.accept,
        RtcCallSignalEvent.reject,
        RtcCallSignalEvent.end,
        RtcCallSignalEvent.ringing,
      ]) {
        final c = WkRtcCallSignalContent()
          ..event = e
          ..data = {'call_uuid': 'call-x'};
        final json = c.encodeJson();
        expect(json['type'], 1001);
        expect(json['event'], rtcCallSignalEventName(e));

        final decoded =
            WkRtcCallSignalContent().decodeJson(json) as WkRtcCallSignalContent;
        expect(decoded.event, e);
      }
    });

    test('decode tolerates unknown event verb (falls back to unknown)', () {
      final decoded = WkRtcCallSignalContent().decodeJson({
        'type': 1001,
        'event': 'bogus_verb',
        'data': const {'call_uuid': 'call-1'},
      }) as WkRtcCallSignalContent;
      expect(decoded.event, RtcCallSignalEvent.unknown);
      expect(decoded.data['call_uuid'], 'call-1');
    });

    test('decode tolerates missing data field', () {
      final decoded = WkRtcCallSignalContent().decodeJson({
        'type': 1001,
        'event': 'invite'
      }) as WkRtcCallSignalContent;
      expect(decoded.event, RtcCallSignalEvent.invite);
      expect(decoded.data, isEmpty);
    });

    test('displayText is empty so RTC signal does not render as chat message',
        () {
      final c = WkRtcCallSignalContent()
        ..event = RtcCallSignalEvent.invite
        ..data = {'call_uuid': 'call-1'};
      // F16 spec §6.2.6 安全闸门 + 体验: 1001 是控制信令, 不应在聊天时间线显示文本气泡。
      expect(c.displayText(), isEmpty);
      expect(c.searchableWord(), isEmpty);
    });

    test('raw WuKong field fallback decodes type 1001 content', () {
      final decoded = rtcSignalContentFromWukongFields(
        contentType: 1001,
        content:
            '{"type":1001,"event":"invite","data":{"call_uuid":"call-raw","kind":"audio"}}',
      );

      expect(decoded, isNotNull);
      expect(decoded!.event, RtcCallSignalEvent.invite);
      expect(decoded.data['call_uuid'], 'call-raw');
      expect(decoded.data['kind'], 'audio');
    });

    test('raw WuKong field fallback ignores non-1001 and malformed content',
        () {
      expect(
        rtcSignalContentFromWukongFields(contentType: 1, content: '{}'),
        isNull,
      );
      expect(
        rtcSignalContentFromWukongFields(
          contentType: 1001,
          content: 'not json',
        ),
        isNull,
      );
    });

    test('rtcCallSignalEventFromName parses every known verb', () {
      expect(rtcCallSignalEventFromName('invite'), RtcCallSignalEvent.invite);
      expect(rtcCallSignalEventFromName('cancel'), RtcCallSignalEvent.cancel);
      expect(rtcCallSignalEventFromName('accept'), RtcCallSignalEvent.accept);
      expect(rtcCallSignalEventFromName('reject'), RtcCallSignalEvent.reject);
      expect(rtcCallSignalEventFromName('end'), RtcCallSignalEvent.end);
      expect(rtcCallSignalEventFromName('ringing'), RtcCallSignalEvent.ringing);
      expect(rtcCallSignalEventFromName('INVITE'), RtcCallSignalEvent.invite);
      expect(rtcCallSignalEventFromName('  ringing  '),
          RtcCallSignalEvent.ringing);
      expect(rtcCallSignalEventFromName(''), RtcCallSignalEvent.unknown);
      expect(rtcCallSignalEventFromName('garbage'), RtcCallSignalEvent.unknown);
    });
  });
}
