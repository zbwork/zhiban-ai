// F16 · 测试用原生来电浮窗（记录调用 + 可控动作流，绝不弹真窗）。
import 'dart:async';

import 'package:zhiban_client/rtc/rtc_native_incoming_window.dart';

class FakeIncomingWindow implements RtcNativeIncomingWindow {
  FakeIncomingWindow({this.shown = true});

  /// showIncoming 返回值（true = 视为已弹原生窗 → app 内卡隐藏）。
  bool shown;
  int shows = 0;
  int hides = 0;
  int disposes = 0;
  String? lastCallUuid;
  String? lastPeerName;
  String? lastPeerAvatarUrl;
  String? lastMediaKind;

  final StreamController<RtcNativeIncomingAction> _actions =
      StreamController<RtcNativeIncomingAction>.broadcast();

  /// 模拟用户在原生浮窗点击。
  void emit(RtcNativeIncomingAction a) => _actions.add(a);

  @override
  Future<bool> showIncoming({
    required String callUuid,
    required String peerName,
    String? peerAvatarUrl,
    required String mediaKind,
  }) async {
    shows++;
    lastCallUuid = callUuid;
    lastPeerName = peerName;
    lastPeerAvatarUrl = peerAvatarUrl;
    lastMediaKind = mediaKind;
    return shown;
  }

  @override
  Future<void> hide() async {
    hides++;
  }

  @override
  Stream<RtcNativeIncomingAction> get actions => _actions.stream;

  @override
  Future<void> dispose() async {
    disposes++;
    await _actions.close();
  }
}
