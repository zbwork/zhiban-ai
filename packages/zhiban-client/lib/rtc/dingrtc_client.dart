// F16 FE-01 · 真实 DingRTC native bridge 客户端 (实现 [RtcClient])。
//
// 通过两个统一平台通道驱动各平台 native → DingRTC SDK（协议与具体平台/SDK 解耦）:
//   - MethodChannel "easyo/rtc/methods": initialize/joinChannel/leaveChannel/setMicrophoneMuted/
//       setCameraEnabled/listDevices/selectDevice/listScreenShareSources/startScreenShare/
//       stopScreenShare/dispose
//   - EventChannel  "easyo/rtc/events" : joined/left/error/remoteUserJoined/remoteUserLeft/
//       networkQuality/screenShare/agentState/agentTranscription
//
// 跨平台现状: macOS（macos/Runner/DingRtcBridge.swift）、Android（android/.../DingRtcBridge.kt）、
// iOS（ios/Runner/DingRtcBridge.swift）与 Windows（windows/runner/dingrtc_bridge.cpp）均已实现
// 同一 contract（Windows 需本地 DingRTC SDK 路径，视频用 HWND overlay 渲染），
// 详见 docs/architecture/zhiban-app-rtc-cross-platform.md。
// **某平台 bridge 未实现时 invokeMethod 抛 MissingPluginException —— 这只是「未完成」状态, 不是目标行为**;
// 已实现平台不得靠 MissingPlugin 正常返回（无能力的方法应返回明确 unsupported error 或空结果）。
// 生产装配用本类; [FakeRtcClient] 只用于单测 / UI 解耦, 不入生产。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rtc_client.dart';

/// native joinChannel / leaveChannel 返回非 0 返回码时抛出。
///
/// 让 [RtcCallController] 的 join-fail 分支触发后端 `/cancel` 或 `/leave`、leave-fail 分支触发
/// dispose + recreate（释放麦克风）。**不要**吞掉非 0 rc，否则后端状态 / 麦克风会残留。
class RtcNativeException implements Exception {
  RtcNativeException(this.operation, this.code);

  /// 失败的 native 操作（joinChannel / leaveChannel）。
  final String operation;

  /// native 返回码（rc != 0；null 表示 native 未回返回码，同样视为失败）。
  final int? code;

  @override
  String toString() => 'RtcNativeException($operation rc=$code)';
}

class DingRtcClient implements RtcClient {
  DingRtcClient({
    MethodChannel? methodChannel,
    EventChannel? eventChannel
  })  : _methods = methodChannel ?? const MethodChannel('easyo/rtc/methods'),
        _events = eventChannel ?? const EventChannel('easyo/rtc/events');

  final MethodChannel _methods;
  final EventChannel _events;

  final StreamController<RtcEvent> _controller =
      StreamController<RtcEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeSub;
  bool _disposed = false;
  String? _channelId;

  @override
  Stream<RtcEvent> get events => _controller.stream;

  @override
  Future<void> initialize() async {
    _ensureAlive();
    _nativeSub ??= _events.receiveBroadcastStream().listen(
          _onNativeEvent,
          onError: (Object e) =>
              _emit(RtcError('native event stream error: $e')),
        );
    await _methods.invokeMethod<void>('initialize');
  }

  @override
  Future<void> joinChannel(RtcJoinConfig config,
      {RtcMediaKind mediaKind = RtcMediaKind.audio}) async {
    _ensureAlive();
    _channelId = config.channelId;
    final video = mediaKind == RtcMediaKind.video;
    // 读 native 同步返回码：rc==0 才算成功。rc!=0 抛 [RtcNativeException]，让上层走 join-fail 清理。
    // PlatformException（含 MissingPluginException）在 invokeMethod 处自然抛出，不在此吞掉。
    // video=true 时 native 在 join 内开摄像头 + 发布本地视频 + 订阅远端视频；视频建立期 rc 非 0
    // 会聚合进同步返回码 → 这里一并按 rc!=0 失败处理（走 join-fail 清理）。
    final rc =
        await _methods.invokeMethod<int>('joinChannel', <String, dynamic>{
      'appId': config.appId,
      'channelId': config.channelId,
      'userId': config.userId,
      'token': config.token,
      'gslbServer': config.gslbServer,
      'video': video,
    });
    // 只打 channelId / rc / video，不打 token。
    debugPrint(
        '[F16 RTC] joinChannel rc=$rc channel=${config.channelId} video=$video');
    _ensureRcOk('joinChannel', rc);
  }

  @override
  Future<void> leaveChannel() async {
    if (_disposed) return;
    // 读 native 同步返回码：rc!=0 抛错，让上层 _releaseNativeRtc 触发 dispose + recreate（释放麦克风）。
    final rc = await _methods.invokeMethod<int>('leaveChannel');
    debugPrint('[F16 RTC] leaveChannel rc=$rc');
    _ensureRcOk('leaveChannel', rc);
  }

  /// rc==0 才算同步调用成功；非 0（含 null）抛 [RtcNativeException]。
  void _ensureRcOk(String operation, int? rc) {
    if (rc != 0) {
      throw RtcNativeException(operation, rc);
    }
  }

  @override
  Future<void> setMicrophoneMuted(bool muted) async {
    _ensureAlive();
    await _methods.invokeMethod<void>(
        'setMicrophoneMuted', <String, dynamic>{'muted': muted});
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _ensureAlive();
    // native enableLocalVideo+publishLocalVideoStream 返回 int rc：rc==0 才算成功，
    // 非 0（含 null）抛 [RtcNativeException]，与 join/leave 同口径（让上层据此回滚 UI/清理）。
    final rc = await _methods.invokeMethod<int>(
        'setCameraEnabled', <String, dynamic>{'enabled': enabled});
    debugPrint('[F16 RTC] setCameraEnabled rc=$rc enabled=$enabled');
    _ensureRcOk('setCameraEnabled', rc);
  }

  @override
  Future<List<RtcDeviceInfo>> listDevices(RtcDeviceKind kind) async {
    _ensureAlive();
    final raw = await _methods.invokeMethod<List<dynamic>>(
        'listDevices', <String, dynamic>{'kind': kind.wireName});
    if (raw == null) return const <RtcDeviceInfo>[];
    return raw
        .map((e) => RtcDeviceInfo.fromMap(e, fallbackKind: kind))
        .whereType<RtcDeviceInfo>()
        .toList();
  }

  @override
  Future<void> selectDevice(RtcDeviceKind kind, String deviceId) async {
    _ensureAlive();
    // native 切换后回读校验当前设备：匹配 → rc=0，否则 rc!=0（setter 无返回码，回读判定）。
    // rc != 0 → 抛 [RtcNativeException]，上层 toast + 不改 selected（**不假成功**）。不打印 token。
    final rc = await _methods.invokeMethod<int>('selectDevice',
        <String, dynamic>{'kind': kind.wireName, 'deviceId': deviceId});
    debugPrint('[F16 RTC] selectDevice rc=$rc kind=${kind.wireName}');
    _ensureRcOk('selectDevice', rc);
  }

  @override
  Future<List<RtcScreenShareSource>> listScreenShareSources() async {
    _ensureAlive();
    final raw =
        await _methods.invokeMethod<List<dynamic>>('listScreenShareSources');
    if (raw == null) return const <RtcScreenShareSource>[];
    return raw
        .map(RtcScreenShareSource.fromMap)
        .whereType<RtcScreenShareSource>()
        .toList();
  }

  @override
  Future<void> startScreenShare({String? sourceId}) async {
    _ensureAlive();
    // 权限缺失 → native 返回 FlutterError(screen_permission_denied) → 这里抛 PlatformException（上层提示授权）。
    // rc != 0 → RtcNativeException（上层回滚 UI + 提示）。不打印 token。
    final rc = await _methods.invokeMethod<int>('startScreenShare',
        <String, dynamic>{if (sourceId != null) 'sourceId': sourceId});
    debugPrint(
        '[F16 RTC] startScreenShare rc=$rc source=${sourceId ?? "(default)"}');
    _ensureRcOk('startScreenShare', rc);
  }

  @override
  Future<void> stopScreenShare() async {
    if (_disposed) return;
    final rc = await _methods.invokeMethod<int>('stopScreenShare');
    debugPrint('[F16 RTC] stopScreenShare rc=$rc');
    _ensureRcOk('stopScreenShare', rc);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _methods.invokeMethod<void>('dispose');
    } catch (_) {
      // best-effort; 释放原生引擎失败不应抛出。
    }
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _controller.close();
  }

  void _onNativeEvent(dynamic raw) {
    final e = eventFromNative(raw, fallbackChannelId: _channelId);
    if (e != null) _emit(e);
  }

  /// 把 native EventChannel 的 Map 映射成 [RtcEvent]。提取为静态便于单测。
  /// 未知/非法 payload → null (忽略)。
  static RtcEvent? eventFromNative(dynamic raw, {String? fallbackChannelId}) {
    if (raw is! Map) {
      debugPrint('[F16 RTC] native event not a Map: $raw');
      return null;
    }
    switch (raw['type'] as String?) {
      case 'joined':
        return RtcJoined(
            (raw['channelId'] as String?) ?? fallbackChannelId ?? '');
      case 'left':
        return RtcLeft(
            (raw['channelId'] as String?) ?? fallbackChannelId ?? '');
      case 'remoteUserJoined':
        return RtcRemoteUserJoined((raw['userId'] as String?) ?? '');
      case 'remoteUserLeft':
        return RtcRemoteUserLeft((raw['userId'] as String?) ?? '');
      case 'remoteVideo':
        final uid = (raw['userId'] as String?) ?? '';
        if (uid.isEmpty) return null;
        return RtcRemoteVideoStateChanged(
          userId: uid,
          enabled: (raw['enabled'] as bool?) ?? false,
        );
      case 'networkQuality':
        final level = raw['level'];
        return RtcNetworkQuality(level is int ? level : 3);
      case 'screenShare':
        return RtcScreenShareStateChanged(
          local: (raw['scope'] as String?) == 'local',
          active: (raw['active'] as bool?) ?? false,
          userId: raw['userId'] as String?,
        );
      case 'agentState':
        final state = raw['state'];
        final rawState = state is int ? state : 0;
        return RtcAgentStateChanged(
          state: RtcAgentStateWire.fromWire(rawState),
          rawState: rawState,
        );
      case 'error':
        final code = raw['code'];
        final msg = (raw['message'] as String?) ?? 'unknown';
        return RtcError(code == null ? msg : '[$code] $msg');
      // F16 A1 · RTM 实时转写 → live 气泡（此前 default→null 直接丢弃，聊天窗永远收不到）。
      case 'agentTranscription':
        final roundId = raw['roundId'];
        final beginTime = raw['beginTime'];
        final speaker = raw['speaker'] as String?;
        if (speaker != 'user' && speaker != 'agent') {
          debugPrint(
              '[F16 RTC] ignored agentTranscription with unknown speaker=$speaker round=$roundId');
          return null;
        }
        final text = (raw['text'] as String?) ?? '';
        final reasoning = (raw['reasoning'] as String?) ?? '';
        debugPrint(
            '[F16 RTC] native agentTranscription speaker=$speaker round=$roundId end=${raw['end']} text=${text.length} reasoning=${reasoning.length}');
        return RtcAgentTranscription(
          isUser: speaker == 'user',
          roundId: roundId is int ? roundId : 0,
          end: (raw['end'] as bool?) ?? false,
          text: text,
          reasoning: reasoning,
          beginTimeMs: beginTime is int ? beginTime : 0,
        );
      default:
        debugPrint('[F16 RTC] unrecognized native event: $raw');
        return null;
    }
  }

  void _emit(RtcEvent e) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(e);
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('DingRtcClient used after dispose()');
  }
}
