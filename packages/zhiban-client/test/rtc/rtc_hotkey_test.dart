import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/widgets/rtc_call_overlay.dart';

void main() {
  group('rtcHotkeyFor (FE-03 窗口内热键)', () {
    test('incoming: Enter=accept, Esc=reject', () {
      expect(rtcHotkeyFor(RtcCallPhase.incomingRinging, LogicalKeyboardKey.enter),
          RtcHotkeyAction.accept);
      expect(
          rtcHotkeyFor(
              RtcCallPhase.incomingRinging, LogicalKeyboardKey.numpadEnter),
          RtcHotkeyAction.accept);
      expect(rtcHotkeyFor(RtcCallPhase.incomingRinging, LogicalKeyboardKey.escape),
          RtcHotkeyAction.reject);
    });

    test('outgoingRinging: Esc=cancel, Enter=none', () {
      expect(rtcHotkeyFor(RtcCallPhase.outgoingRinging, LogicalKeyboardKey.escape),
          RtcHotkeyAction.cancelOutgoing);
      expect(rtcHotkeyFor(RtcCallPhase.outgoingRinging, LogicalKeyboardKey.enter),
          RtcHotkeyAction.none);
    });

    test('connecting/active: Esc=hangUp, Enter=none（留给输入框发送）', () {
      expect(rtcHotkeyFor(RtcCallPhase.connecting, LogicalKeyboardKey.escape),
          RtcHotkeyAction.hangUp);
      expect(rtcHotkeyFor(RtcCallPhase.active, LogicalKeyboardKey.escape),
          RtcHotkeyAction.hangUp);
      expect(rtcHotkeyFor(RtcCallPhase.active, LogicalKeyboardKey.enter),
          RtcHotkeyAction.none);
    });

    test('idle/ending/error: 任意键 none（不抢输入框回车）', () {
      for (final p in [
        RtcCallPhase.idle,
        RtcCallPhase.ending,
        RtcCallPhase.error,
      ]) {
        expect(rtcHotkeyFor(p, LogicalKeyboardKey.enter), RtcHotkeyAction.none);
        expect(rtcHotkeyFor(p, LogicalKeyboardKey.escape), RtcHotkeyAction.none);
      }
    });
  });
}
