// F16 RTC 信令客户端订阅入口 (F16 spec v0.6.4 §6.2.6 D14 + §7.3)。
//
// 职责: 订阅 [WukongImClient.listenRtcCallSignals], 把 1001 信令路由到
// onInvite / onCancel / onAccept / onReject / onEnd / onRinging 6 类业务回调。
//
// 当前是**最小骨架**, 只完成事件模型 + 派发, **不**接 UI(来电浮窗 / 通知中心 / Dock 反弹 /
// 全局热键 在 F16-FE-03 落地)。
//
// 安全闸门 (spec §6.2.6):
//   - 收到信令**仅**触发 UI 唤醒;
//   - **绝不**直接修改 call_session.state;
//   - 通话状态推进必须走 POST /api/agent-bus/v1/calls/{answer,reject,cancel,...} HTTP。

import 'dart:async';

import '../im/wukong/contents/wk_rtc_call_signal_content.dart';
import '../im/wukong/wukong_im_client.dart';

/// 6 类业务回调签名 (与 [RtcCallSignalEvent] 1:1, 不含 unknown)。
typedef RtcSignalHandler = void Function(RtcCallSignalIncoming signal);

/// F16 RTC 信令订阅器。
///
/// 用法:
/// ```dart
/// final listener = RtcSignalingListener(WukongImClient.shared);
/// listener.start(
///   onInvite: (s) => showIncomingCallWindow(s),
///   onCancel: (s) => dismissIncomingCallWindow(s),
///   onEnd: (s) => closeInCallWindow(s),
///   ...
/// );
/// // dispose 时:
/// listener.stop();
/// ```
class RtcSignalingListener {
  RtcSignalingListener(this._imClient);

  final WukongImClient _imClient;
  StreamSubscription<RtcCallSignalIncoming>? _sub;

  /// 是否已开始监听; start 是幂等的。
  bool get isRunning => _sub != null;

  /// 订阅 6 类信令; 未提供的回调按 no-op 处理。
  void start({
    RtcSignalHandler? onInvite,
    RtcSignalHandler? onCancel,
    RtcSignalHandler? onAccept,
    RtcSignalHandler? onReject,
    RtcSignalHandler? onEnd,
    RtcSignalHandler? onRinging,
    void Function(RtcCallSignalIncoming signal)? onUnknown,
  }) {
    if (_sub != null) return; // 幂等
    _sub = _imClient.listenRtcCallSignals().listen((s) {
      switch (s.event) {
        case RtcCallSignalEvent.invite:
          onInvite?.call(s);
          break;
        case RtcCallSignalEvent.cancel:
          onCancel?.call(s);
          break;
        case RtcCallSignalEvent.accept:
          onAccept?.call(s);
          break;
        case RtcCallSignalEvent.reject:
          onReject?.call(s);
          break;
        case RtcCallSignalEvent.end:
          onEnd?.call(s);
          break;
        case RtcCallSignalEvent.ringing:
          onRinging?.call(s);
          break;
        case RtcCallSignalEvent.unknown:
          onUnknown?.call(s);
          break;
      }
    });
  }

  /// 关闭订阅 (与 [start] 配对)。再次 [start] 会重新订阅。
  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }
}
