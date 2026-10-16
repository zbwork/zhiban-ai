// F16 · 测试用提示音播放器（记录调用，绝不真播放）。
import 'package:zhiban_client/rtc/rtc_call_tone_player.dart';

class FakeTonePlayer implements RtcCallTonePlayer {
  final List<String> calls = <String>[];
  int outgoing = 0;
  int incoming = 0;
  int stops = 0;
  int disposes = 0;

  @override
  Future<void> playOutgoingRingback() async {
    outgoing++;
    calls.add('outgoing');
  }

  @override
  Future<void> playIncomingRingtone() async {
    incoming++;
    calls.add('incoming');
  }

  @override
  Future<void> stop() async {
    stops++;
    calls.add('stop');
  }

  @override
  Future<void> dispose() async {
    disposes++;
    calls.add('dispose');
  }
}
