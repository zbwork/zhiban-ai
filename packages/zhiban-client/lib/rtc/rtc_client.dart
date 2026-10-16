// F16 RTC client 抽象 (FE-01 · Phase 1 · MVP-Runnable)。
//
// 把"加入/离开 RTC 频道 + 麦克风 + 远端成员事件"与具体 native SDK 解耦, 让来电浮窗 /
// in-call UI (FE-03) 与单测只依赖接口, 不依赖 native。
//
// 真实 native 实现是 DingRTC SDK 桥接 [DingRtcClient]（macOS/Android/iOS/Windows 均已实现同一
// `easyo/rtc/methods` + `easyo/rtc/events` contract；Windows 需本地 DingRTC SDK 路径，
// 视频用 HWND overlay 渲染）;
// [FakeRtcClient] 只用于单测 / UI 解耦, **不可生产**。
// 某平台 native bridge 未实现时调用会抛 MissingPluginException —— 这是「未完成」状态, **不是目标行为**;
// 跨平台目标是各平台实现同一 contract, 不应据此把「禁用入口」固化为该平台终态。
//
// 安全: joinChannel 所需的 [RtcJoinConfig] 必须来自 POST /api/agent-bus/v1/calls 响应的
// `rtc` 段 (后端签发), 客户端**不**自造 token。后端未开启 DingRTC token 时 rtc=null,
// 客户端拿不到可用 config → 不入会。

import 'dart:async';

/// 通话媒体类型 (F16 Phase B)。
///
/// - [audio]：1v1 人↔人语音（Phase 1 已落，主干）。
/// - [video]：1v1 人↔人视频。信令 / 状态 / 入会 / 文案 + **真实画面渲染均已接线**
///   （macOS FlutterPlatformView `easyo/rtc/video_view` → DingRtcVideoCanvas）。远端视频未到
///   时显示「等待对方加入」真实空状态，**不伪造画面**；**仍未两台带摄像头 Mac 真机活体核验**。
enum RtcMediaKind { audio, video }

/// 设备类型（DingRTC macOS：三类均真实支持）。
/// - [microphone]：录音设备（getAudioCaptures / setCurrentAudioCaptureWithID）。
/// - [speaker]：播放设备（getAudioRenderers / setCurrentAudioRendererWithID）。
/// - [camera]：摄像头（getCameraList / setCurrentCameraWithID）。
enum RtcDeviceKind { microphone, speaker, camera }

/// 设备类型 ↔ native 线名（MethodChannel/EventChannel 传输用）。
extension RtcDeviceKindWire on RtcDeviceKind {
  String get wireName => switch (this) {
        RtcDeviceKind.microphone => 'microphone',
        RtcDeviceKind.speaker => 'speaker',
        RtcDeviceKind.camera => 'camera',
      };

  static RtcDeviceKind? fromWire(String? s) => switch (s) {
        'microphone' => RtcDeviceKind.microphone,
        'speaker' => RtcDeviceKind.speaker,
        'camera' => RtcDeviceKind.camera,
        _ => null,
      };
}

/// 一个可选设备（id + 名称 + 是否当前）。
class RtcDeviceInfo {
  const RtcDeviceInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.isCurrent,
  });

  final String id;
  final String name;
  final RtcDeviceKind kind;
  final bool isCurrent;

  /// 从 native 返回的 `{id, name, kind, is_current}` 解析；id 缺失/空 → null（丢弃）。
  static RtcDeviceInfo? fromMap(dynamic raw, {RtcDeviceKind? fallbackKind}) {
    if (raw is! Map) return null;
    final id = (raw['id'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    final kind = RtcDeviceKindWire.fromWire(raw['kind'] as String?) ??
        fallbackKind ??
        RtcDeviceKind.microphone;
    return RtcDeviceInfo(
      id: id,
      name: (raw['name'] as String?)?.trim().isNotEmpty == true
          ? (raw['name'] as String).trim()
          : id,
      kind: kind,
      isCurrent: (raw['is_current'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.wireName,
        'is_current': isCurrent,
      };
}

/// 会议窗口里用户选中某设备（native 菜单点击 → controller 调 selectDevice）。
class RtcDeviceSelection {
  const RtcDeviceSelection(this.kind, this.deviceId);
  final RtcDeviceKind kind;
  final String deviceId;
}

/// 屏幕共享源类型（DingRTC macOS：`DingRtcScreenShareType` Desktop=0 / Window=1）。
enum RtcScreenShareSourceKind { screen, window, unknown }

extension RtcScreenShareSourceKindWire on RtcScreenShareSourceKind {
  String get wireName => switch (this) {
        RtcScreenShareSourceKind.screen => 'screen',
        RtcScreenShareSourceKind.window => 'window',
        RtcScreenShareSourceKind.unknown => 'unknown',
      };

  static RtcScreenShareSourceKind fromWire(String? s) => switch (s) {
        'screen' => RtcScreenShareSourceKind.screen,
        'window' => RtcScreenShareSourceKind.window,
        _ => RtcScreenShareSourceKind.unknown,
      };
}

/// 一个可共享的屏幕/窗口源。`thumbnail` 缩略图本轮 deferred（DingRtcVideoFrame 不便过通道）。
class RtcScreenShareSource {
  const RtcScreenShareSource({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;
  final String name;
  final RtcScreenShareSourceKind kind;

  static RtcScreenShareSource? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    return RtcScreenShareSource(
      id: id,
      name: (raw['name'] as String?)?.trim().isNotEmpty == true
          ? (raw['name'] as String).trim()
          : id,
      kind: RtcScreenShareSourceKindWire.fromWire(raw['kind'] as String?),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.wireName,
      };
}

/// 会议窗口里用户请求开始/停止屏幕共享（native 菜单 → controller）。
class RtcScreenShareRequest {
  const RtcScreenShareRequest({required this.start, this.sourceId});
  final bool start;

  /// 指定源 id；null = 共享整个屏幕（native 取首个桌面）。
  final String? sourceId;
}

/// DingRTC joinChannel 默认 gslbServer (官方 Mac SDK 文档 2640103)。
/// 优先用后端下发的 `gslb_server`; 缺省才回退到此值, 不在客户端固化业务路由。
const String kDefaultGslbServer = 'https://gslb.dingrtc.com';

/// 入会凭证 —— 镜像后端 `rtcConfigDTO`(app_id/channel_id/user_id/token/expires_at/gslb_server)。
/// 对应 DingRTC `DingRtcAuthInfo`(appId/channelId/userId/token/gslbServer)。
class RtcJoinConfig {
  const RtcJoinConfig({
    required this.appId,
    required this.channelId,
    required this.userId,
    required this.token,
    this.expiresAt,
    this.gslbServer = kDefaultGslbServer,
  });

  final String appId;
  final String channelId;
  final String userId;
  final String token;
  final DateTime? expiresAt;

  /// DingRTC joinChannel 的 gslbServer (服务端下发, 缺省回退 [kDefaultGslbServer])。
  final String gslbServer;

  /// 从 /calls 响应的 `rtc` 对象解析。
  ///
  /// 返回 null 的情况(均表示"当前不可入会", 由调用方据此不进会):
  ///   - json 为 null (rtc=null, Phase 1 Noop token);
  ///   - token / app_id / channel_id / user_id 任一缺失或空。
  ///
  /// `gslb_server` 优先用后端返回; 缺失/空则回退 [kDefaultGslbServer]。
  static RtcJoinConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final appId = json['app_id'] as String?;
    final channelId = json['channel_id'] as String?;
    final userId = json['user_id'] as String?;
    final token = json['token'] as String?;
    if (appId == null ||
        channelId == null ||
        userId == null ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    final exp = json['expires_at'] as String?;
    final gslb = json['gslb_server'] as String?;
    return RtcJoinConfig(
      appId: appId,
      channelId: channelId,
      userId: userId,
      token: token,
      expiresAt: (exp == null || exp.isEmpty) ? null : DateTime.tryParse(exp),
      gslbServer: (gslb == null || gslb.isEmpty) ? kDefaultGslbServer : gslb,
    );
  }
}

/// RTC 频道事件 (sealed: joined / left / error / remoteUserJoined / remoteUserLeft)。
sealed class RtcEvent {
  const RtcEvent();
}

/// 本端成功加入频道。
class RtcJoined extends RtcEvent {
  const RtcJoined(this.channelId);
  final String channelId;
}

/// 本端离开频道。
class RtcLeft extends RtcEvent {
  const RtcLeft(this.channelId);
  final String channelId;
}

/// 底层错误 (入会失败 / 媒体异常等)。
class RtcError extends RtcEvent {
  const RtcError(this.message);
  final String message;
}

/// 远端成员加入。
class RtcRemoteUserJoined extends RtcEvent {
  const RtcRemoteUserJoined(this.userId);
  final String userId;
}

/// 远端成员离开。
class RtcRemoteUserLeft extends RtcEvent {
  const RtcRemoteUserLeft(this.userId);
  final String userId;
}

/// 远端摄像头开/关（DingRTC `onUserVideoEnabled` / `onRemoteTrackAvailableNotify` 的视频轨道）。
///
/// 语音通话中对方中途开摄像头时，UI 据此挂载远端视频画面——不再把远端画面死 gate 在
/// 初始通话类型（`isVideo`）上。[enabled] = 远端是否正在推摄像头视频。
class RtcRemoteVideoStateChanged extends RtcEvent {
  const RtcRemoteVideoStateChanged({
    required this.userId,
    required this.enabled,
  });
  final String userId;
  final bool enabled;
}

/// 本端网络质量变化（DingRTC `onNetworkQualityChanged`，仅 self）。
/// [level]：0=良好 / 1=较差 / 2=中断 / 3=未知（对齐 `DingRtcNetworkQuality`）。
/// 收到前 UI 显示中性「已连接」，**不伪造「网络良好」**。
class RtcNetworkQuality extends RtcEvent {
  const RtcNetworkQuality(this.level);
  final int level;
}

/// 屏幕共享发布/订阅状态变化（DingRTC `onScreenSharePublishStateChanged` 本端 /
/// `onScreenShareSubscribeStateChanged` 远端）。[local] 区分本端/远端，[active] 是否在共享。
class RtcScreenShareStateChanged extends RtcEvent {
  const RtcScreenShareStateChanged({
    required this.local,
    required this.active,
    this.userId,
  });
  final bool local;
  final bool active;
  final String? userId; // 远端共享者 uid（local=false 时）
}

/// DingRTC AI Agent 状态（RTM `onAgentStateChanged`）。
enum RtcAgentState {
  unknown,
  listening,
  thinking,
  responding
}

extension RtcAgentStateWire on RtcAgentState {
  static RtcAgentState fromWire(int raw) => switch (raw) {
        1 => RtcAgentState.listening,
        2 => RtcAgentState.thinking,
        3 => RtcAgentState.responding,
        _ => RtcAgentState.unknown,
      };
}

/// F16 A2/A3 · Agent 状态变化。客户端用它驱动状态 UI 与“用户插话打断”判断。
class RtcAgentStateChanged extends RtcEvent {
  const RtcAgentStateChanged({
    required this.state,
    required this.rawState
  });

  final RtcAgentState state;
  final int rawState;
}

/// F16 A1 · Agent 通话实时转写（DingRTC RTM `onTranscriptionMessage`）。
///
/// 同一 `(roundId, isUser)` 的事件是 ASR/TTS partial 的**累计替换**：[text] 为该轮
/// 当前完整文本，[end]=true 表示该轮定稿（碎片在 end 前不单独成泡，原地更新）。
/// [beginTimeMs] 为轮次开始时间（epoch ms）；native 取不到时为 0，消费方退化为
/// 首见本地时刻排序（设计 §3.2 fallback，需打日志）。
class RtcAgentTranscription extends RtcEvent {
  const RtcAgentTranscription({
    required this.isUser,
    required this.roundId,
    required this.end,
    required this.text,
    this.reasoning = '',
    this.beginTimeMs = 0,
  });

  /// true=用户语音转写（speaker=user），false=数字员工回答（speaker=agent）。
  final bool isUser;
  final int roundId;
  final bool end;
  final String text;

  /// 智能体思考内容（仅 agent 侧可能有；折叠展示，不进正文）。
  final String reasoning;
  final int beginTimeMs;
}

/// RTC 入会能力抽象。
///
/// 真实实现 = DingRTC native 桥接; 测试 / UI 解耦实现 = [FakeRtcClient]。
abstract class RtcClient {
  /// 初始化底层 SDK (应幂等)。
  Future<void> initialize();

  /// 用后端签发的 [config] 加入频道; 成功后发出 [RtcJoined]。
  ///
  /// [mediaKind] = video 时入会即视频通话（Phase B）：**单一责任**——native joinChannel(video)
  /// 负责开本地摄像头 + 发布本地视频 + 订阅远端视频（Dart 不再重复 enable），画面由
  /// PlatformView 绑定后真实渲染。视频建立期 native rc 非 0 同步抛出 → 上层走 join-fail 清理。
  Future<void> joinChannel(RtcJoinConfig config,
      {RtcMediaKind mediaKind = RtcMediaKind.audio});

  /// 离开当前频道 (应幂等); 在会则发出 [RtcLeft]。
  Future<void> leaveChannel();

  /// 麦克风静音开关。
  Future<void> setMicrophoneMuted(bool muted);

  /// 通话中开/关本地摄像头（视频通话控制条按钮）。
  ///
  /// 对应 DingRTC `enableLocalVideo` + `publishLocalVideoStream`（native 返回 int rc，
  /// rc != 0 抛出 → 上层回滚 `cameraOn`）。关闭后本地 PiP 显示「摄像头已关」预留态。
  Future<void> setCameraEnabled(bool enabled);

  /// 列出某类设备（麦克风/扬声器/摄像头）。会议中拉取供设备 picker。
  /// 桌面（macOS/Windows）为真实设备枚举；移动端（Android/iOS）通常是系统音频路由模型，
  /// 已实现 bridge 返回**空列表或路由/能力结果**，UI 按「无设备枚举 / 系统音频路由」处理。
  /// 仅在该平台 native bridge **尚未实现**时抛 MissingPluginException（未完成态，**非目标行为**；
  /// 上层 catch 后置空，不得当作「该平台正常无设备」固化）。
  Future<List<RtcDeviceInfo>> listDevices(RtcDeviceKind kind);

  /// 选择某类设备的具体设备。native 切换后**回读校验**当前设备：
  /// 不匹配 → 视为失败（rc != 0）抛 [RtcNativeException]，上层据此回滚/提示，**不假成功**。
  Future<void> selectDevice(RtcDeviceKind kind, String deviceId);

  /// 列出可共享的屏幕/窗口源（macOS）。无屏幕录制权限 → 返回空列表（不弹权限）。
  Future<List<RtcScreenShareSource>> listScreenShareSources();

  /// 开始屏幕共享（[sourceId] null = 整个屏幕/首个桌面）。**同一端单路共享**。
  /// 权限缺失 → 抛 PlatformException(code: 'screen_permission_denied')（native 同时触发系统授权弹窗）；
  /// rc != 0 → 抛 [RtcNativeException]。上层据此回滚 UI + 明确提示，**不假成功**。
  Future<void> startScreenShare({String? sourceId});

  /// 停止屏幕共享（幂等）；rc != 0 → 抛 [RtcNativeException]。
  Future<void> stopScreenShare();

  /// 频道事件流 (joined / left / error / remoteUser* / networkQuality / screenShare)。
  Stream<RtcEvent> get events;

  /// 释放资源 (关闭 [events])。
  Future<void> dispose();
}
