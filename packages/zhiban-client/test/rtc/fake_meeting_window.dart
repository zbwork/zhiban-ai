// F16 · 测试用独立会议窗口（记录调用 + 可控动作流，绝不弹真 NSWindow）。
import 'dart:async';

import 'package:zhiban_client/rtc/rtc_client.dart';
import 'package:zhiban_client/rtc/rtc_native_meeting_window.dart';

class FakeMeetingWindow implements RtcNativeMeetingWindow {
  FakeMeetingWindow({this.shown = true});

  /// showMeeting 返回值（true = 视为已弹原生会议窗 → app 内只显示状态条）。
  bool shown;
  int shows = 0;
  int updates = 0;
  int hides = 0;
  int disposes = 0;
  int bringToFronts = 0;
  RtcMeetingWindowState? lastState;

  final StreamController<RtcMeetingWindowAction> _actions =
      StreamController<RtcMeetingWindowAction>.broadcast();
  final StreamController<RtcDeviceSelection> _deviceSelections =
      StreamController<RtcDeviceSelection>.broadcast();
  final StreamController<RtcScreenShareRequest> _screenShareRequests =
      StreamController<RtcScreenShareRequest>.broadcast();

  /// 模拟用户在原生会议窗点击。
  void emit(RtcMeetingWindowAction a) => _actions.add(a);

  /// 模拟用户在原生会议窗设备菜单点选。
  void emitDeviceSelection(RtcDeviceSelection sel) => _deviceSelections.add(sel);

  /// 模拟用户在原生会议窗共享按钮/菜单操作。
  void emitScreenShareRequest(RtcScreenShareRequest req) =>
      _screenShareRequests.add(req);

  @override
  Future<bool> showMeeting(RtcMeetingWindowState state) async {
    shows++;
    lastState = state;
    return shown;
  }

  @override
  Future<void> updateMeeting(RtcMeetingWindowState state) async {
    updates++;
    lastState = state;
  }

  @override
  Future<void> hideMeeting() async {
    hides++;
  }

  @override
  Future<void> bringToFront() async {
    bringToFronts++;
  }

  @override
  Stream<RtcMeetingWindowAction> get actions => _actions.stream;

  @override
  Stream<RtcDeviceSelection> get deviceSelections => _deviceSelections.stream;

  @override
  Stream<RtcScreenShareRequest> get screenShareRequests =>
      _screenShareRequests.stream;

  @override
  Future<void> dispose() async {
    disposes++;
    await _actions.close();
    await _deviceSelections.close();
    await _screenShareRequests.close();
  }
}
