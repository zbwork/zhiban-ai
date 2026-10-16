// F16 FE-01 · FakeRtcClient —— **仅供单测 / UI 解耦, 不可生产**。
//
// 用纯内存状态模拟一次 RTC 通话的事件序列 (joined / remoteUserJoined / left ...), 让来电浮窗 /
// in-call UI 在没有 DingRTC native SDK (blocked-on-SDK) 时也能开发与测试。
//
// ⚠️ 它**绝不**代表真实音视频能力: 不连网、不传媒体、不签 token、不入任何真实频道。
// 生产装配**禁止**使用本类; 真实桥接落地前, 通话功能保持 blocked。

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;

import 'dingrtc_client.dart' show RtcNativeException;
import 'rtc_client.dart';

class FakeRtcClient implements RtcClient {
  FakeRtcClient();

  final StreamController<RtcEvent> _controller =
      StreamController<RtcEvent>.broadcast();
  bool _initialized = false;
  bool _disposed = false;
  String? _joinedChannelId;
  bool _micMuted = false;
  RtcMediaKind _lastJoinMediaKind = RtcMediaKind.audio;
  bool _cameraEnabled = false;

  /// 是否已 initialize。
  bool get isInitialized => _initialized;

  /// 是否在会中 (joinChannel 成功且未 leave)。
  bool get isInCall => _joinedChannelId != null;

  /// 当前麦克风是否静音。
  bool get isMicMuted => _micMuted;

  /// 最近一次 joinChannel 的媒体类型 (B 阶段视频测试断言)。
  RtcMediaKind get lastJoinMediaKind => _lastJoinMediaKind;

  /// 摄像头 enable 骨架状态 (setCameraEnabled 测试断言)。
  bool get isCameraEnabled => _cameraEnabled;

  @override
  Stream<RtcEvent> get events => _controller.stream;

  @override
  Future<void> initialize() async {
    _ensureAlive();
    _initialized = true;
  }

  @override
  Future<void> joinChannel(RtcJoinConfig config,
      {RtcMediaKind mediaKind = RtcMediaKind.audio}) async {
    _ensureAlive();
    if (!_initialized) {
      throw StateError('FakeRtcClient.joinChannel called before initialize()');
    }
    _joinedChannelId = config.channelId;
    _lastJoinMediaKind = mediaKind;
    _emit(RtcJoined(config.channelId));
  }

  @override
  Future<void> leaveChannel() async {
    _ensureAlive();
    final ch = _joinedChannelId;
    if (ch == null) return; // 幂等: 不在会则无事件
    _joinedChannelId = null;
    _emit(RtcLeft(ch));
  }

  @override
  Future<void> setMicrophoneMuted(bool muted) async {
    _ensureAlive();
    _micMuted = muted;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _ensureAlive();
    _cameraEnabled = enabled;
  }

  // ── 设备 picker (内存模拟) ──
  final Map<RtcDeviceKind, List<String>> _deviceIds = {
    RtcDeviceKind.microphone: ['mic-a', 'mic-b'],
    RtcDeviceKind.speaker: ['spk-a', 'spk-b'],
    RtcDeviceKind.camera: ['cam-a', 'cam-b'],
  };
  final Map<RtcDeviceKind, String> _currentDevice = {
    RtcDeviceKind.microphone: 'mic-a',
    RtcDeviceKind.speaker: 'spk-a',
    RtcDeviceKind.camera: 'cam-a',
  };

  /// 测试钩子：下一次 selectDevice 抛 RtcNativeException（模拟 rc != 0）。
  bool failNextSelect = false;
  int listDeviceCalls = 0;
  int selectDeviceCalls = 0;

  /// 当前设备 id（测试断言用）。
  String? currentDevice(RtcDeviceKind kind) => _currentDevice[kind];

  @override
  Future<List<RtcDeviceInfo>> listDevices(RtcDeviceKind kind) async {
    _ensureAlive();
    listDeviceCalls++;
    final ids = _deviceIds[kind] ?? const <String>[];
    return ids
        .map((id) => RtcDeviceInfo(
              id: id,
              name: '$id name',
              kind: kind,
              isCurrent: id == _currentDevice[kind],
            ))
        .toList();
  }

  @override
  Future<void> selectDevice(RtcDeviceKind kind, String deviceId) async {
    _ensureAlive();
    selectDeviceCalls++;
    if (failNextSelect) {
      failNextSelect = false;
      throw RtcNativeException('selectDevice', -1); // 模拟回读校验失败
    }
    _currentDevice[kind] = deviceId;
  }

  /// 模拟 native 网络质量回调。
  void simulateNetworkQuality(int level) => _emit(RtcNetworkQuality(level));

  // ── 屏幕共享 (内存模拟) ──
  bool _screenSharing = false;
  int startScreenShareCalls = 0;
  int stopScreenShareCalls = 0;
  int listScreenSourceCalls = 0;

  /// 测试钩子：下一次 startScreenShare 抛 RtcNativeException（模拟 rc != 0）。
  bool failNextScreenShare = false;

  /// 测试钩子：下一次 startScreenShare 抛 PlatformException(screen_permission_denied)（模拟无权限）。
  bool failNextScreenSharePermission = false;

  bool get isScreenSharing => _screenSharing;

  @override
  Future<List<RtcScreenShareSource>> listScreenShareSources() async {
    _ensureAlive();
    listScreenSourceCalls++;
    return const <RtcScreenShareSource>[
      RtcScreenShareSource(
          id: 'screen-1', name: '整个屏幕', kind: RtcScreenShareSourceKind.screen),
      RtcScreenShareSource(
          id: 'window-1', name: '窗口 A', kind: RtcScreenShareSourceKind.window),
    ];
  }

  @override
  Future<void> startScreenShare({String? sourceId}) async {
    _ensureAlive();
    startScreenShareCalls++;
    if (failNextScreenSharePermission) {
      failNextScreenSharePermission = false;
      throw PlatformException(
          code: 'screen_permission_denied', message: '需要屏幕录制权限');
    }
    if (failNextScreenShare) {
      failNextScreenShare = false;
      throw RtcNativeException('startScreenShare', -1);
    }
    _screenSharing = true;
  }

  @override
  Future<void> stopScreenShare() async {
    _ensureAlive();
    stopScreenShareCalls++;
    _screenSharing = false;
  }

  /// 模拟远端共享开始/停止回调。
  void simulateRemoteScreenShare(bool active, String userId) => _emit(
      RtcScreenShareStateChanged(local: false, active: active, userId: userId));

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _joinedChannelId = null;
    await _controller.close();
  }

  // ── 测试钩子: 手工注入"远端/底层"事件 (真实 SDK 由 native 回调触发) ──

  /// 模拟远端成员入会。
  void simulateRemoteUserJoined(String userId) =>
      _emit(RtcRemoteUserJoined(userId));

  /// 模拟远端成员离会。
  void simulateRemoteUserLeft(String userId) =>
      _emit(RtcRemoteUserLeft(userId));

  /// 模拟底层错误。
  void simulateError(String message) => _emit(RtcError(message));

  /// F16 A1 · 模拟 RTM 实时转写事件（controller live 气泡状态机测试用）。
  void simulateAgentTranscription(RtcAgentTranscription e) => _emit(e);

  /// F16 A2/A3 · 模拟 Agent 状态变化。
  void simulateAgentState(RtcAgentState state, {int? rawState}) => _emit(
        RtcAgentStateChanged(
          state: state,
          rawState: rawState ??
              switch (state) {
                RtcAgentState.listening => 1,
                RtcAgentState.thinking => 2,
                RtcAgentState.responding => 3,
                RtcAgentState.unknown => 0,
              },
        ),
      );

  void _emit(RtcEvent e) {
    if (_disposed || _controller.isClosed) return; // dispose 后静默丢弃
    _controller.add(e);
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('FakeRtcClient used after dispose()');
  }
}
