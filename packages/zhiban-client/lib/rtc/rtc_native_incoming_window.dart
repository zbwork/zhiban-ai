// F16 · 被叫来电「屏幕级」原生浮窗（macOS NSPanel）。
//
// 只负责 UI 唤醒：在屏幕右下角弹一个独立小窗（不局限于 app 窗口内），可拖动，有拒接/接听。
// 真正的状态推进仍走 HTTP /calls/*（RtcCallController），1001 信令不改 call_session.state。
//
// macOS 生产实现 = MethodChannel + EventChannel 驱动 RtcIncomingPanelBridge（见 DingRtcBridge.swift）。
// 其它平台 / 测试用 [NoopIncomingWindow]（永不显示）→ 退回 app 内来电卡。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_client/utils/url_utils.dart';

/// 原生来电浮窗回传的动作。
enum RtcNativeIncomingAction { accept, reject, close }

/// 原生来电浮窗抽象（便于注入测试）。
abstract class RtcNativeIncomingWindow {
  /// 显示原生来电浮窗。返回 true 表示**已显示原生窗口**（此时 app 内来电卡应隐藏，避免双卡）。
  Future<bool> showIncoming({
    required String callUuid,
    required String peerName,
    String? peerAvatarUrl,
    required String mediaKind,
  });

  /// 关闭原生来电浮窗（幂等）。
  Future<void> hide();

  /// 用户在原生浮窗上的动作流（accept / reject / close）。
  Stream<RtcNativeIncomingAction> get actions;

  /// 释放资源。
  Future<void> dispose();
}

/// 降级实现：永不显示原生窗口（非 macOS / 测试默认）→ 退回 app 内来电卡。
class NoopIncomingWindow implements RtcNativeIncomingWindow {
  const NoopIncomingWindow();

  @override
  Future<bool> showIncoming({
    required String callUuid,
    required String peerName,
    String? peerAvatarUrl,
    required String mediaKind,
  }) async =>
      false;

  @override
  Future<void> hide() async {}

  @override
  Stream<RtcNativeIncomingAction> get actions =>
      const Stream<RtcNativeIncomingAction>.empty();

  @override
  Future<void> dispose() async {}
}

/// 生产实现：MethodChannel 驱动 macOS `RtcIncomingPanelBridge`（NSPanel）。
class MethodChannelIncomingWindow implements RtcNativeIncomingWindow {
  MethodChannelIncomingWindow({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods =
            methodChannel ?? const MethodChannel('easyo/rtc/incoming_panel'),
        _events = eventChannel ??
            const EventChannel('easyo/rtc/incoming_panel/events');

  final MethodChannel _methods;
  final EventChannel _events;
  StreamController<RtcNativeIncomingAction>? _ctrl;
  StreamSubscription<dynamic>? _sub;

  @override
  Future<bool> showIncoming({
    required String callUuid,
    required String peerName,
    String? peerAvatarUrl,
    required String mediaKind,
  }) async {
    try {
      // **不传 token**；仅 UI 唤醒所需字段。
      final r = await _methods.invokeMethod<bool>('show', <String, dynamic>{
        'callUuid': callUuid,
        'peerName': peerName,
        if ((peerAvatarUrl ?? '').trim().isNotEmpty)
          'peerAvatarUrl': resolveAgentAvatarUrl(peerAvatarUrl ?? ''),
        'mediaKind': mediaKind,
      });
      return r ?? false;
    } catch (e) {
      debugPrint('[F16 RTC] native incoming show failed (fallback in-app): $e');
      return false;
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _methods.invokeMethod<void>('hide');
    } catch (e) {
      debugPrint('[F16 RTC] native incoming hide failed (ignored): $e');
    }
  }

  @override
  Stream<RtcNativeIncomingAction> get actions {
    final ctrl = _ctrl ??=
        StreamController<RtcNativeIncomingAction>.broadcast(onListen: _start);
    return ctrl.stream;
  }

  void _start() {
    _sub ??= _events.receiveBroadcastStream().listen(
      (raw) {
        final a = actionFromNative(raw);
        if (a != null) _ctrl?.add(a);
      },
      onError: (Object e) =>
          debugPrint('[F16 RTC] native incoming events error: $e'),
    );
  }

  /// 把 native EventChannel payload 映射成动作。提取为静态便于单测。
  static RtcNativeIncomingAction? actionFromNative(dynamic raw) {
    final s = (raw is Map ? raw['action'] : raw)?.toString();
    switch (s) {
      case 'accept':
        return RtcNativeIncomingAction.accept;
      case 'reject':
        return RtcNativeIncomingAction.reject;
      case 'close':
        return RtcNativeIncomingAction.close;
      default:
        return null;
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _ctrl?.close();
    _ctrl = null;
  }
}
