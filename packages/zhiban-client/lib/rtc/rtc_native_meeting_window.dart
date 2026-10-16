// F16 · macOS 独立会议窗口（NSWindow）Dart 桥。
//
// 统一 audio/video meeting model：接通(active)后进入会议窗口（audio = cameraOff 的会议，
// video = cameraOn 的会议）。macOS 用同一 app 内的独立 NSWindow（可拖/可缩放/可最小化），
// 复用现有 DingRtcEngine（不新建第二套 RTC engine）；视频块绑定窗口内 NSView。
// 只做 UI：按钮经 EventChannel 回传，状态推进仍走 RtcCallController + HTTP /calls/*，1001 不改 state。
// 非 macOS / show 失败 → [NoopMeetingWindow] 返回 false → 退回 app 内会议壳 fallback。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rtc_client.dart'
    show
        RtcDeviceInfo,
        RtcDeviceKindWire,
        RtcDeviceSelection,
        RtcScreenShareRequest,
        RtcScreenShareSource;

/// 会议画面布局。
enum RtcMeetingLayout { gallery, speaker }

/// 会议窗口回传的用户动作。
enum RtcMeetingWindowAction {
  hangUp,
  toggleMute,
  toggleCamera,
  switchLayout,
  toggleParticipants,
  invite,
  restore, // 回到/聚焦会议窗口
  close, // 窗口关闭按钮（MVP：等同挂断）
}

/// 会议窗口渲染所需状态（无 token）。
@immutable
class RtcMeetingWindowState {
  const RtcMeetingWindowState({
    required this.callUuid,
    required this.peerName,
    this.peerAvatarUrl = '',
    required this.selfDisplayName,
    this.selfAvatarUrl = '',
    required this.mediaKind, // 'audio' | 'video'（初始媒介；通话中摄像头可升级）
    required this.phase, // 'active' 等
    required this.elapsedSeconds,
    required this.muted,
    required this.cameraOn,
    required this.remoteUserId,
    this.remoteUserIds = const <String>[],
    this.remoteCameraOnUserIds = const <String>[],
    this.joinedParticipantNames = const <String>[],
    this.joinedParticipantAvatars = const <String>[],
    this.callingParticipantNames = const <String>[],
    this.callingParticipantAvatars = const <String>[],
    required this.layout,
    required this.participantsPanelOpen,
    this.microphoneDevices = const <RtcDeviceInfo>[],
    this.speakerDevices = const <RtcDeviceInfo>[],
    this.cameraDevices = const <RtcDeviceInfo>[],
    this.speakerSupported = true,
    this.networkText = '已连接',
    this.screenSharing = false,
    this.screenShareBusy = false,
    this.remoteScreenSharing = false,
    this.remoteScreenUserId,
    this.screenShareSources = const <RtcScreenShareSource>[],
    this.canInviteParticipants = false,
  });

  final String callUuid;
  final String peerName;
  final String peerAvatarUrl;
  final String selfDisplayName;
  final String selfAvatarUrl;
  final String mediaKind;
  final String phase;
  final int elapsedSeconds;
  final bool muted;
  final bool cameraOn;
  final String? remoteUserId;
  final List<String> remoteUserIds;

  /// 当前在推摄像头视频的远端成员（语音通话中对方中途开摄像头时非空）。
  /// 原生会议窗口据此决定挂载远端视频画面，而非死 gate 在 [mediaKind]。
  final List<String> remoteCameraOnUserIds;
  final List<String> joinedParticipantNames;
  final List<String> joinedParticipantAvatars;
  final List<String> callingParticipantNames;
  final List<String> callingParticipantAvatars;
  final RtcMeetingLayout layout;
  final bool participantsPanelOpen;

  /// 设备 picker 列表（会议中拉取）。每项含 id/name/is_current。
  final List<RtcDeviceInfo> microphoneDevices;
  final List<RtcDeviceInfo> speakerDevices;
  final List<RtcDeviceInfo> cameraDevices;

  /// 扬声器选择是否支持（DingRTC macOS 支持 → true；不支持平台 → false，UI 灰显）。
  final bool speakerSupported;

  /// 顶部网络状态文案（真实 callback 驱动；未收到 → 中性「已连接」，不伪造）。
  final String networkText;

  /// 屏幕共享：本端是否在共享 / 切换中 / 远端是否在共享 / 远端共享者 / 可共享源列表。
  final bool screenSharing;
  final bool screenShareBusy;
  final bool remoteScreenSharing;
  final String? remoteScreenUserId;
  final List<RtcScreenShareSource> screenShareSources;
  final bool canInviteParticipants;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'callUuid': callUuid,
        'peerName': peerName,
        'peerAvatarUrl': peerAvatarUrl,
        'selfDisplayName': selfDisplayName,
        'selfAvatarUrl': selfAvatarUrl,
        'mediaKind': mediaKind,
        'phase': phase,
        'elapsedSeconds': elapsedSeconds,
        'muted': muted,
        'cameraOn': cameraOn,
        if (remoteUserId != null) 'remoteUserId': remoteUserId,
        'remoteUserIds': remoteUserIds,
        'remoteCameraOnUserIds': remoteCameraOnUserIds,
        'joinedParticipantNames': joinedParticipantNames,
        'joinedParticipantAvatars': joinedParticipantAvatars,
        'callingParticipantNames': callingParticipantNames,
        'callingParticipantAvatars': callingParticipantAvatars,
        'layout': layout == RtcMeetingLayout.gallery ? 'gallery' : 'speaker',
        'participantsPanelOpen': participantsPanelOpen,
        'microphoneDevices': microphoneDevices.map((d) => d.toMap()).toList(),
        'speakerDevices': speakerDevices.map((d) => d.toMap()).toList(),
        'cameraDevices': cameraDevices.map((d) => d.toMap()).toList(),
        'speakerSupported': speakerSupported,
        'networkText': networkText,
        'screenSharing': screenSharing,
        'screenShareBusy': screenShareBusy,
        'remoteScreenSharing': remoteScreenSharing,
        if (remoteScreenUserId != null)
          'remoteScreenUserId': remoteScreenUserId,
        'screenShareSources': screenShareSources.map((s) => s.toMap()).toList(),
        'canInviteParticipants': canInviteParticipants,
      };
}

/// 会议窗口抽象（便于注入测试）。
abstract class RtcNativeMeetingWindow {
  /// 显示独立会议窗口。返回 true = 已显示原生窗口（此时 app 内只显示轻量状态条）。
  Future<bool> showMeeting(RtcMeetingWindowState state);

  /// 更新会议窗口状态（静音/摄像头/布局/参会人/远端 等变化）。
  Future<void> updateMeeting(RtcMeetingWindowState state);

  /// 关闭会议窗口（幂等）。
  Future<void> hideMeeting();

  /// 把已存在的会议窗口恢复（取消最小化）并前置聚焦（「回到会议窗口」）。
  Future<void> bringToFront();

  /// 会议窗口动作流（hangUp / toggleMute / toggleCamera / switchLayout / toggleParticipants / invite / restore / close）。
  Stream<RtcMeetingWindowAction> get actions;

  /// 设备选择流（会议窗口设备菜单点击 → 上层调 RtcClient.selectDevice）。
  Stream<RtcDeviceSelection> get deviceSelections;

  /// 屏幕共享请求流（会议窗口共享按钮/菜单 → 上层调 RtcClient.start/stopScreenShare）。
  Stream<RtcScreenShareRequest> get screenShareRequests;

  /// 释放资源。
  Future<void> dispose();
}

/// 降级实现：永不显示独立窗口（非 macOS / 测试默认）→ app 内会议壳 fallback。
class NoopMeetingWindow implements RtcNativeMeetingWindow {
  const NoopMeetingWindow();
  @override
  Future<bool> showMeeting(RtcMeetingWindowState state) async => false;
  @override
  Future<void> updateMeeting(RtcMeetingWindowState state) async {}
  @override
  Future<void> hideMeeting() async {}
  @override
  Future<void> bringToFront() async {}
  @override
  Stream<RtcMeetingWindowAction> get actions =>
      const Stream<RtcMeetingWindowAction>.empty();
  @override
  Stream<RtcDeviceSelection> get deviceSelections =>
      const Stream<RtcDeviceSelection>.empty();
  @override
  Stream<RtcScreenShareRequest> get screenShareRequests =>
      const Stream<RtcScreenShareRequest>.empty();
  @override
  Future<void> dispose() async {}
}

/// 生产实现：MethodChannel 驱动 macOS `RtcMeetingWindowBridge`（NSWindow）。
class MethodChannelMeetingWindow implements RtcNativeMeetingWindow {
  MethodChannelMeetingWindow({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ?? const MethodChannel('easyo/rtc/meeting'),
        _events =
            eventChannel ?? const EventChannel('easyo/rtc/meeting/events');

  final MethodChannel _methods;
  final EventChannel _events;
  StreamController<RtcMeetingWindowAction>? _ctrl;
  StreamController<RtcDeviceSelection>? _deviceCtrl;
  StreamController<RtcScreenShareRequest>? _screenCtrl;
  StreamSubscription<dynamic>? _sub;

  @override
  Future<bool> showMeeting(RtcMeetingWindowState state) async {
    try {
      final r = await _methods.invokeMethod<bool>('show', state.toMap());
      return r ?? false;
    } catch (e) {
      debugPrint('[F16 RTC] native meeting show failed (fallback in-app): $e');
      return false;
    }
  }

  @override
  Future<void> updateMeeting(RtcMeetingWindowState state) async {
    try {
      await _methods.invokeMethod<void>('update', state.toMap());
    } catch (e) {
      debugPrint('[F16 RTC] native meeting update failed (ignored): $e');
    }
  }

  @override
  Future<void> hideMeeting() async {
    try {
      await _methods.invokeMethod<void>('hide');
    } catch (e) {
      debugPrint('[F16 RTC] native meeting hide failed (ignored): $e');
    }
  }

  @override
  Future<void> bringToFront() async {
    try {
      await _methods.invokeMethod<void>('bringToFront');
    } catch (e) {
      debugPrint('[F16 RTC] native meeting bringToFront failed (ignored): $e');
    }
  }

  @override
  Stream<RtcMeetingWindowAction> get actions {
    final ctrl = _ctrl ??=
        StreamController<RtcMeetingWindowAction>.broadcast(onListen: _start);
    return ctrl.stream;
  }

  @override
  Stream<RtcDeviceSelection> get deviceSelections {
    final ctrl = _deviceCtrl ??=
        StreamController<RtcDeviceSelection>.broadcast(onListen: _start);
    return ctrl.stream;
  }

  @override
  Stream<RtcScreenShareRequest> get screenShareRequests {
    final ctrl = _screenCtrl ??=
        StreamController<RtcScreenShareRequest>.broadcast(onListen: _start);
    return ctrl.stream;
  }

  void _start() {
    _sub ??= _events.receiveBroadcastStream().listen(
      (raw) {
        // selectDevice → 设备流；screenShareRequest → 共享流；其余 → 动作流。
        final sel = deviceSelectionFromNative(raw);
        if (sel != null) {
          _deviceCtrl?.add(sel);
          return;
        }
        final share = screenShareRequestFromNative(raw);
        if (share != null) {
          _screenCtrl?.add(share);
          return;
        }
        final a = actionFromNative(raw);
        if (a != null) _ctrl?.add(a);
      },
      onError: (Object e) =>
          debugPrint('[F16 RTC] native meeting events error: $e'),
    );
  }

  /// native `{action:'screenShareRequest', start: bool, sourceId?}` → [RtcScreenShareRequest]。
  static RtcScreenShareRequest? screenShareRequestFromNative(dynamic raw) {
    if (raw is! Map || raw['action'] != 'screenShareRequest') return null;
    final sourceId = (raw['sourceId'] as String?)?.trim();
    return RtcScreenShareRequest(
      start: (raw['start'] as bool?) ?? false,
      sourceId: (sourceId != null && sourceId.isNotEmpty) ? sourceId : null,
    );
  }

  /// native `{action:'selectDevice', deviceKind, deviceId}` → [RtcDeviceSelection]。静态便于单测。
  static RtcDeviceSelection? deviceSelectionFromNative(dynamic raw) {
    if (raw is! Map || raw['action'] != 'selectDevice') return null;
    final kind = RtcDeviceKindWire.fromWire(raw['deviceKind'] as String?);
    final id = (raw['deviceId'] as String?)?.trim();
    if (kind == null || id == null || id.isEmpty) return null;
    return RtcDeviceSelection(kind, id);
  }

  /// native EventChannel payload → 动作。静态便于单测。
  static RtcMeetingWindowAction? actionFromNative(dynamic raw) {
    final s = (raw is Map ? raw['action'] : raw)?.toString();
    switch (s) {
      case 'hangUp':
        return RtcMeetingWindowAction.hangUp;
      case 'toggleMute':
        return RtcMeetingWindowAction.toggleMute;
      case 'toggleCamera':
        return RtcMeetingWindowAction.toggleCamera;
      case 'switchLayout':
        return RtcMeetingWindowAction.switchLayout;
      case 'toggleParticipants':
        return RtcMeetingWindowAction.toggleParticipants;
      case 'invite':
        return RtcMeetingWindowAction.invite;
      case 'restore':
        return RtcMeetingWindowAction.restore;
      case 'close':
        return RtcMeetingWindowAction.close;
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
    await _deviceCtrl?.close();
    _deviceCtrl = null;
    await _screenCtrl?.close();
    _screenCtrl = null;
  }
}
