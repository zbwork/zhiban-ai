// F16 · 原生来电浮窗 Dart 层单测（纯映射 + Noop 行为，不弹真窗）。
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/rtc_native_incoming_window.dart';

void main() {
  group('MethodChannelIncomingWindow.actionFromNative', () {
    test('accept/reject/close 映射；未知 → null', () {
      expect(MethodChannelIncomingWindow.actionFromNative({'action': 'accept'}),
          RtcNativeIncomingAction.accept);
      expect(MethodChannelIncomingWindow.actionFromNative({'action': 'reject'}),
          RtcNativeIncomingAction.reject);
      expect(MethodChannelIncomingWindow.actionFromNative({'action': 'close'}),
          RtcNativeIncomingAction.close);
      expect(MethodChannelIncomingWindow.actionFromNative('accept'),
          RtcNativeIncomingAction.accept);
      expect(
          MethodChannelIncomingWindow.actionFromNative({'action': 'wat'}), isNull);
      expect(MethodChannelIncomingWindow.actionFromNative(null), isNull);
    });
  });

  test('NoopIncomingWindow: showIncoming=false, actions 空流', () async {
    const w = NoopIncomingWindow();
    expect(
        await w.showIncoming(callUuid: 'c', peerName: 'p', mediaKind: 'audio'),
        isFalse);
    final events = <RtcNativeIncomingAction>[];
    final sub = w.actions.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    await sub.cancel();
    await w.hide();
    await w.dispose();
  });
}
