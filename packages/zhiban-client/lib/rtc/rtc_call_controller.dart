// F16 FE-03b · 全局 RTC 通话协调器 (飞书质感 1v1 audio MVP)。
//
// 把"来电接收 + 呼叫态 + 通话态"从单个聊天 Pane 提到**全局**: 挂在 MainLayout，跨所有已登录路由存活，
// 订阅 WuKong 1001 信令，驱动全局浮层 (lib/rtc/widgets/rtc_call_overlay.dart)。
//
// 边界 (与后端一致):
//   - 状态推进仍走 HTTP /api/agent-bus/v1/calls/*；本控制器只做客户端 UI 状态 + DingRTC 入会/离会。
//   - 1001 信令仅用于唤醒/同步 UI，**不**改后端 call_session 状态。
//   - 自己发出的信令按 connectedUid 过滤，不弹自己。

import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../im/wukong/contents/wk_rtc_call_signal_content.dart';
import '../im/wukong/wukong_im_client.dart';
import '../im/wukong/wukong_session_identity.dart';
import '../services/account_info_api.dart';
import '../utils/haptic_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import '../utils/url_utils.dart';
import 'dingrtc_client.dart';
import 'rtc_call_api.dart';
import 'rtc_call_tone_player.dart';
import 'rtc_client.dart';
import 'rtc_native_incoming_window.dart';
import 'rtc_native_meeting_window.dart';

/// 客户端通话阶段。
enum RtcCallPhase {
  idle, // 无通话
  outgoingRinging, // 我发起，呼叫中（等待对方接听/入会）
  incomingRinging, // 收到来电，等待我接听/拒接
  connecting, // 已接听/已接通，入会建立中（双方已答应，结束须走 /leave 不是 /cancel）
  active, // 通话中（对方已在频道）
  ending, // 正在结束（API/leave 进行中）
  error, // 出错（短暂，随后回 idle）
}

/// 当前通话方向：决定 connecting 阶段的语义来源，仅供 UI / 日志，不影响后端。
enum RtcCallDirection { none, outgoing, incoming }

const String _kRtcLastCallStorageKey = 'rtc.last_active_call.v1';

class RtcLastCallRecord {
  const RtcLastCallRecord({
    required this.callUuid,
    required this.roomUuid
  });

  final String callUuid;
  final String roomUuid;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'call_uuid': callUuid,
        'room_uuid': roomUuid,
      };

  static RtcLastCallRecord? fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final callUuid = (data['call_uuid'] ?? '').toString();
      final roomUuid = (data['room_uuid'] ?? '').toString();
      if (callUuid.isEmpty || roomUuid.isEmpty) return null;
      return RtcLastCallRecord(callUuid: callUuid, roomUuid: roomUuid);
    } catch (_) {
      return null;
    }
  }
}

abstract class RtcCallRecoveryStore {
  Future<RtcLastCallRecord?> readLastCall();
  Future<void> writeLastCall(RtcLastCallRecord record);
  Future<void> clearLastCall({String? callUuid});
}

class SharedPreferencesRtcCallRecoveryStore implements RtcCallRecoveryStore {
  const SharedPreferencesRtcCallRecoveryStore();

  @override
  Future<RtcLastCallRecord?> readLastCall() async {
    final prefs = await SharedPreferences.getInstance();
    return RtcLastCallRecord.fromJsonString(
      prefs.getString(_kRtcLastCallStorageKey),
    );
  }

  @override
  Future<void> writeLastCall(RtcLastCallRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRtcLastCallStorageKey, jsonEncode(record.toJson()));
  }

  @override
  Future<void> clearLastCall({String? callUuid}) async {
    final prefs = await SharedPreferences.getInstance();
    if (callUuid != null && callUuid.isNotEmpty) {
      final current = RtcLastCallRecord.fromJsonString(
        prefs.getString(_kRtcLastCallStorageKey),
      );
      if (current != null && current.callUuid != callUuid) return;
    }
    await prefs.remove(_kRtcLastCallStorageKey);
  }
}

/// F16 A1 · 通话中的一条 live 转写气泡（`(roundId, isUser)` 唯一，partial 原地累计替换）。
///
/// 只存在于通话期间的内存里（**不可信层**，不持久化）；通话结束由聊天侧 reload 服务端
/// canonical 历史替换（设计 §3.4 方案 C）。
class RtcLiveTranscript {
  const RtcLiveTranscript({
    required this.roundId,
    required this.isUser,
    required this.text,
    required this.reasoning,
    required this.end,
    required this.beginTimeMs,
    required this.firstSeenAt,
    this.interrupted = false,
  });

  final int roundId;
  final bool isUser;
  final String text;
  final String reasoning;

  /// true=该轮转写已定稿（之后的迟到 partial 不再回退文本）。
  final bool end;

  /// true=该 Agent 气泡因用户插话被打断，保留半截文本并停止追加。
  final bool interrupted;

  /// 阿里轮次开始时间（epoch ms）；0=native 未取到 → 排序退化用 [firstSeenAt]。
  final int beginTimeMs;

  /// 客户端首次见到该 `(roundId, speaker)` 的本地时刻（排序 fallback + 时间分割线）。
  final DateTime firstSeenAt;

  /// 设计 §3.2 排序键：`(roundId, beginTime|firstSeenAt, user 先于 agent)`。
  static int compare(RtcLiveTranscript a, RtcLiveTranscript b) {
    if (a.roundId != b.roundId) return a.roundId.compareTo(b.roundId);
    final at = a.beginTimeMs > 0
        ? a.beginTimeMs
        : a.firstSeenAt.millisecondsSinceEpoch;
    final bt = b.beginTimeMs > 0
        ? b.beginTimeMs
        : b.firstSeenAt.millisecondsSinceEpoch;
    if (at != bt) return at.compareTo(bt);
    if (a.isUser != b.isUser) return a.isUser ? -1 : 1;
    return 0;
  }
}

/// 会议参与者面板展示用（姓名 + 头像）；查不到真实身份时 avatarUrl 为空，
/// UI 侧退回默认头像。
class RtcParticipantDisplay {
  const RtcParticipantDisplay(
      {required this.name, this.avatarUrl = '', this.uid});
  final String name;
  final String avatarUrl;
  final String? uid;
}

/// 全局通话控制器。挂在 app shell，进程内单实例（随 ProviderScope 生命周期，登出即销毁）。
class RtcCallController extends ChangeNotifier {
  RtcCallController({
    RtcCallApi? api,
    RtcClient Function()? clientFactory,
    Stream<RtcCallSignalIncoming>? signalStream,
    String? Function()? selfUid,
    void Function(String message)? showToast,
    RtcCallTonePlayer? tonePlayer,
    RtcNativeIncomingWindow? nativeIncomingWindow,
    RtcNativeMeetingWindow? nativeMeetingWindow,
    RtcCallRecoveryStore? recoveryStore,
  })  : _api = api ?? RtcCallApi(),
        _clientFactory = clientFactory ?? DingRtcClient.new,
        _selfUid = selfUid ?? (() => WukongImClient.shared.connectedUid),
        _showToast = showToast ?? ((m) => BotToast.showText(text: m)),
        _tone = tonePlayer ?? AudioPlayersTonePlayer(),
        _nativeIncoming = nativeIncomingWindow ?? const NoopIncomingWindow(),
        _meeting = nativeMeetingWindow ?? const NoopMeetingWindow(),
        _recoveryStore =
            recoveryStore ?? const SharedPreferencesRtcCallRecoveryStore() {
    _client = _clientFactory();
    _eventSub = _client.events.listen(_onRtcEvent);
    _signalSub = (signalStream ?? WukongImClient.shared.listenRtcCallSignals())
        .listen(_onSignal);
    _nativeActionSub = _nativeIncoming.actions.listen(_onNativeIncomingAction);
    _meetingActionSub = _meeting.actions.listen(_onMeetingAction);
    _deviceSelSub = _meeting.deviceSelections.listen(_onDeviceSelection);
    _screenShareSub =
        _meeting.screenShareRequests.listen(_onScreenShareRequest);
  }

  final RtcCallApi _api;
  // P1-3: client 可替换 —— leaveChannel 失败时强制 dispose + 用 factory 重建，避免麦克风残留。
  final RtcClient Function() _clientFactory;
  late RtcClient _client;
  final String? Function() _selfUid;
  final void Function(String message) _showToast;
  final RtcCallTonePlayer _tone; // 拨号回铃 / 来电铃声
  final RtcNativeIncomingWindow _nativeIncoming; // macOS 被叫来电独立浮窗
  bool _nativeIncomingActive = false; // 原生来电浮窗是否正在显示
  final RtcNativeMeetingWindow _meeting; // macOS 独立会议窗口
  bool _nativeMeetingActive = false; // 独立会议窗口是否显示成功
  RtcMeetingLayout _layout =
      RtcMeetingLayout.gallery; // 会议布局（native + app shell 共享）
  bool _participantsPanelOpen = false; // 参会人侧栏开关
  // 设备 picker（会议中拉取，传给原生会议窗口菜单）。
  List<RtcDeviceInfo> _micDevices = const <RtcDeviceInfo>[];
  List<RtcDeviceInfo> _speakerDevices = const <RtcDeviceInfo>[];
  List<RtcDeviceInfo> _cameraDevices = const <RtcDeviceInfo>[];
  final bool _speakerSupported = PlatformUtils.isMacOS ||
      PlatformUtils.isAndroid; // macOS=设备枚举；Android=系统音频路由。
  int? _networkLevel; // 0 良好/1 较差/2 中断/3 未知；null=未收到 callback
  // 屏幕共享（仅 macOS 会议窗口；同一端单路；状态走本控制器，不发 1001、不改后端）。
  bool _screenSharing = false;
  bool _screenShareBusy = false;
  bool _remoteScreenSharing = false;
  String? _remoteScreenUserId;
  List<RtcScreenShareSource> _screenShareSources =
      const <RtcScreenShareSource>[];
  String? _selectedScreenShareSourceId;
  final RtcCallRecoveryStore _recoveryStore;
  bool _preserveRecoveryRecordOnReset = false;
  StreamSubscription<RtcCallSignalIncoming>? _signalSub;
  StreamSubscription<RtcEvent>? _eventSub;
  StreamSubscription<RtcNativeIncomingAction>? _nativeActionSub;
  StreamSubscription<RtcMeetingWindowAction>? _meetingActionSub;
  StreamSubscription<RtcDeviceSelection>? _deviceSelSub;
  StreamSubscription<RtcScreenShareRequest>? _screenShareSub;
  final StreamController<void> _inviteRequests =
      StreamController<void>.broadcast();

  RtcCallPhase _phase = RtcCallPhase.idle;
  RtcCallDirection _direction = RtcCallDirection.none;
  String? _callUuid;
  String? _roomUuid;
  String? _peerName;
  String? _peerAvatarUrl;
  String _selfAvatarUrl = '';
  bool _meetingStarted = false;
  bool _outgoingGroupMeetingOpened = false;
  int _expectedRemoteParticipants = 0;
  List<RtcParticipantDisplay> _pendingParticipants =
      const <RtcParticipantDisplay>[];
  // rtc uid(t_{tenant}_u_{account_uuid}) → 参与者身份；RtcRemoteUserJoined 用它
  // 把 DingRTC uid 映射回真实姓名/头像，而不是"成员 N"占位。
  Map<String, RtcCallParticipant> _remoteParticipantsByUid =
      const <String, RtcCallParticipant>{};
  bool _muted = false;
  bool _busy = false; // 防止按钮重入
  bool _disposed = false; // dispose 后异步回调不再 notify
  DateTime? _connectedAt;
  RtcMediaKind _mediaKind = RtcMediaKind.audio; // B 阶段：当前通话媒体类型
  String? _remoteUserId; // 远端已入会的 DingRTC userId → 驱动 remote video view
  final Set<String> _remoteUserIds = <String>{}; // 群会议远端成员集合（保留加入顺序）
  final Set<String> _remoteVideoOnUserIds =
      <String>{}; // 远端开了摄像头的成员（语音通话中途开摄像头时驱动远端视频画面挂载）
  bool _cameraOn = false; // 视频通话本地摄像头是否开启（video join 时 native 已开 → 默认 true）
  // ── F16 A1 · agent 通话实时转写（live 层，内存态） ──
  String? _agentConversationUuid; // 仅 agent 外呼通话有值；live 气泡归属的会话
  final Map<String, RtcLiveTranscript> _liveTranscripts =
      <String, RtcLiveTranscript>{}; // key='$roundId:u|a'
  bool _loggedBeginTimeMissing =
      false; // beginTime 缺失只告警一次（设计 §3.2 fallback 记录）
  RtcAgentState _agentState = RtcAgentState.unknown;
  final Set<int> _interruptedAgentRounds = <int>{};
  int _agentCallEndedTick = 0; // agent 通话结束信号（聊天侧据此 reload canonical 历史）
  String? _lastEndedAgentConversationUuid;

  // ── getters (供 overlay / pane 读) ──
  RtcCallPhase get phase => _phase;
  RtcCallDirection get direction => _direction;
  String? get callUuid => _callUuid;
  String? get roomUuid => _roomUuid;
  String? get peerName => _peerName;
  String? get peerAvatarUrl => _peerAvatarUrl;

  /// 会议画廊里「我」这块 tile 的头像；查不到本地缓存资料时为空，UI 侧退回默认头像。
  String get selfAvatarUrl => _selfAvatarUrl;
  bool get muted => _muted;
  bool get busy => _busy;
  DateTime? get connectedAt => _connectedAt;

  /// 当前通话媒体类型（audio / video）。
  RtcMediaKind get mediaKind => _mediaKind;

  /// 是否视频通话（overlay 据此切「视频」文案 + 居中会议面板）。
  bool get isVideo => _mediaKind == RtcMediaKind.video;

  /// 远端已入会的 DingRTC userId（null = 远端视频尚未到达 → 显示「等待对方加入」）。
  String? get remoteUserId => _remoteUserId;

  /// 群会议远端已入会 DingRTC userId 列表（1v1 时长度最多 1）。
  List<String> get remoteUserIds => List<String>.unmodifiable(_remoteUserIds);

  /// 视频通话本地摄像头是否开启（控制条摄像头按钮 + 本地 PiP 据此渲染）。
  bool get cameraOn => _cameraOn;

  /// 指定远端成员当前是否在推摄像头视频（语音通话中对方中途开摄像头时为 true）。
  /// overlay 据此决定挂载远端视频画面，而非死 gate 在 [isVideo]。
  bool isRemoteCameraOn(String userId) =>
      _remoteVideoOnUserIds.contains(userId);

  /// F16 A1 · 当前 agent 通话归属的会话 uuid（非 agent 通话 / idle 时 null）。
  /// 聊天侧据此判断 live 转写气泡该不该拼进当前会话的消息流。
  String? get activeAgentConversationUuid => _agentConversationUuid;

  /// F16 A1 · live 转写气泡，按设计 §3.2 排序键（roundId → beginTime|firstSeenAt → user 先）。
  List<RtcLiveTranscript> get liveTranscripts {
    if (_liveTranscripts.isEmpty) return const <RtcLiveTranscript>[];
    return _liveTranscripts.values.toList()..sort(RtcLiveTranscript.compare);
  }

  /// 最近一次收到的 DingRTC AI Agent 状态。
  RtcAgentState get agentState => _agentState;

  /// F16 A1 · agent 通话结束信号（单调递增）。聊天侧监听到变化即 reload canonical
  /// 历史替换 live 气泡（设计 §3.4 方案 C）；结束的会话 uuid 见
  /// [lastEndedAgentConversationUuid]。
  int get agentCallEndedTick => _agentCallEndedTick;
  String? get lastEndedAgentConversationUuid => _lastEndedAgentConversationUuid;

  /// 通话媒介中文名（「视频」/「语音」），用于文案拼接。
  String get _mediaWord => isVideo ? '视频' : '语音';

  /// 任意非 idle = 有通话占用（pane 据此置 voiceCallActive）。
  bool get hasActiveCall => _phase != RtcCallPhase.idle;
  bool get isInCall => _phase == RtcCallPhase.active || _meetingStarted;
  bool get isIncoming => _phase == RtcCallPhase.incomingRinging;

  /// 群会议和两人通话都能拉新人；数字员工单聊(human-agent direct)不行——那是
  /// 1v1 智能体会话，后端 room.add_participants 也明确拒绝这种 room。
  bool get canInviteParticipants =>
      _phase == RtcCallPhase.active &&
      _agentConversationUuid == null &&
      (_callUuid?.isNotEmpty ?? false) &&
      (_roomUuid?.isNotEmpty ?? false);
  Stream<void> get inviteRequests => _inviteRequests.stream;

  /// app 内来电卡是否应渲染：来电中 **且** 未由 macOS 原生独立浮窗接管（避免双卡）。
  bool get inAppIncomingVisible =>
      _phase == RtcCallPhase.incomingRinging && !_nativeIncomingActive;

  // ── 统一会议模型（audio/video 同一 meeting；接通=active 进会议）──

  /// 接通中（active）= 进入会议（audio 也是会议，只是 cameraOff）。
  bool get meetingActive => _phase == RtcCallPhase.active || _meetingStarted;

  /// macOS 独立会议窗口是否显示成功（true → app 内只显示轻量状态条，不渲染大会议壳）。
  bool get nativeMeetingVisible => _nativeMeetingActive;

  /// 当前会议布局（gallery / speaker）。
  RtcMeetingLayout get meetingLayout => _layout;

  /// 参会人侧栏是否展开。
  bool get participantsPanelOpen => _participantsPanelOpen;

  /// 已在会议中的远端展示名（原生会议窗口 platform channel 只吃 `List<String>`）。
  List<String> get joinedParticipantNames =>
      joinedParticipants.map((p) => p.name).toList();

  /// 已在会议中的远端参与者（姓名+头像）；按 [_remoteParticipantsByUid] 用
  /// RtcRemoteUserJoined 的 uid 反查真实身份，查不到才用"成员 N"兜底。
  List<RtcParticipantDisplay> get joinedParticipants {
    if (_remoteUserIds.isEmpty) return const <RtcParticipantDisplay>[];
    if (_pendingParticipants.isEmpty && _remoteUserIds.length == 1) {
      return <RtcParticipantDisplay>[RtcParticipantDisplay(name: displayName)];
    }
    final uids = _remoteUserIds.toList();
    return List<RtcParticipantDisplay>.generate(uids.length,
        (i) => participantDisplayFor(uids[i], fallbackName: '成员 ${i + 1}'));
  }

  /// 按 RtcRemoteUserJoined 的 uid 反查会议画面块用的展示身份（姓名+头像）；
  /// 查不到时 name 用 fallbackName（调用方传"成员 N"之类兜底）。
  RtcParticipantDisplay participantDisplayFor(String uid,
      {String fallbackName = ''}) {
    final p = _remoteParticipantsByUid[uid];
    if (p != null && p.displayName.isNotEmpty) {
      return RtcParticipantDisplay(name: p.displayName, avatarUrl: p.avatarUrl);
    }
    for (final entry in _pendingParticipants) {
      if (entry.uid == uid && entry.name.isNotEmpty) return entry;
    }
    final idx = _remoteUserIds.toList().indexOf(uid);
    if (idx >= 0 && idx < _pendingParticipants.length) {
      final fallback = _pendingParticipants[idx];
      if (fallback.uid == null && fallback.name.isNotEmpty) return fallback;
    }
    return RtcParticipantDisplay(name: fallbackName);
  }

  /// 已发起邀请、但尚未收到 RTC remote joined 的远端展示名。
  List<String> get callingParticipantNames =>
      callingParticipants.map((p) => p.name).toList();

  /// 已发起邀请、但尚未收到 RTC remote joined 的远端参与者（姓名+头像）。
  List<RtcParticipantDisplay> get callingParticipants {
    final pending = _expectedRemoteParticipants - _remoteUserIds.length;
    if (pending <= 0) return const <RtcParticipantDisplay>[];
    final stillCalling = _pendingParticipants
        .where((p) => p.uid == null || !_remoteUserIds.contains(p.uid))
        .toList();
    if (stillCalling.length > pending) {
      return stillCalling.sublist(0, pending);
    }
    return stillCalling;
  }

  /// 仅 outgoingRinging（对方还没答应）才允许 /cancel。
  bool get canCancelOutgoing =>
      _phase == RtcCallPhase.outgoingRinging && !_busy;

  /// connecting / active（已答应）结束必须走 /leave，不是 /cancel。
  bool get canHangUp =>
      (_phase == RtcCallPhase.connecting || _phase == RtcCallPhase.active) &&
      !_busy;

  /// 会议壳（含状态条/最小化胶囊）统一挂断键用这个，而不是 [canHangUp]：群/多人
  /// 呼叫时 startOutgoing 的 isGroupOutgoing 分支会在还是 outgoingRinging 阶段就
  /// 提前显示会议壳（让呼叫中的人也出现在画面里），这时 [canHangUp] 仍是 false，
  /// 会导致会议壳的挂断键被禁用点不动。hangUp() 内部本来就会按 phase 正确路由到
  /// /cancel 还是 /leave，这里只是放开 UI 层面的门禁。
  bool get canEndMeeting =>
      !_busy &&
      (_phase == RtcCallPhase.outgoingRinging ||
          _phase == RtcCallPhase.connecting ||
          _phase == RtcCallPhase.active);

  /// 浮层主标题：对端名（拿不到兜底）。来电卡标题固定「语音来电」，副标题用此。
  String get displayName => _peerName ?? '同事';

  /// 浮层状态副文案（overlay 少判断 phase）。
  String get statusText {
    switch (_phase) {
      case RtcCallPhase.incomingRinging:
        return '邀请你进行$_mediaWord通话';
      case RtcCallPhase.outgoingRinging:
        return isVideo ? '正在发起视频通话' : '正在呼叫';
      case RtcCallPhase.connecting:
        return '接通中';
      case RtcCallPhase.active:
        return '通话中';
      case RtcCallPhase.ending:
        return '结束中';
      case RtcCallPhase.error:
      case RtcCallPhase.idle:
        return '';
    }
  }

  // ── 发起方 ──

  /// 点击通话按钮发起 1v1 通话（[mediaKind] = audio / video）。已有通话 → toast 提示不重复发起。
  Future<void> startOutgoing({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String? peerName,
    String? peerAvatarUrl,
    RtcMediaKind mediaKind = RtcMediaKind.audio,
  }) =>
      _startOutgoing(
        roomUuid: roomUuid,
        calleeAccountUuid: calleeAccountUuid,
        agentUuid: agentUuid,
        conversationUuid: conversationUuid,
        peerName: peerName,
        peerAvatarUrl: peerAvatarUrl,
        mediaKind: mediaKind,
        allowBusyRecovery: true,
      );

  Future<void> _startOutgoing({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String? peerName,
    String? peerAvatarUrl,
    RtcMediaKind mediaKind = RtcMediaKind.audio,
    required bool allowBusyRecovery,
  }) async {
    if (_phase != RtcCallPhase.idle) {
      _showToast('当前已有通话');
      debugPrint('[F16 RTC] startOutgoing ignored: busy phase=$_phase');
      return;
    }
    if (roomUuid.isEmpty) {
      _showToast('缺少通话所需的 room 信息');
      return;
    }
    _busy = true;
    _phase = RtcCallPhase.outgoingRinging;
    _direction = RtcCallDirection.outgoing;
    _roomUuid = roomUuid;
    // A1: agent 外呼才有实时转写；记下归属会话，live 气泡只拼进这个会话。
    _agentConversationUuid =
        (agentUuid != null && agentUuid.trim().isNotEmpty) &&
                (conversationUuid != null && conversationUuid.trim().isNotEmpty)
            ? conversationUuid.trim()
            : null;
    _mediaKind = mediaKind;
    _cameraOn = mediaKind == RtcMediaKind.video; // video join 由 native 开摄像头
    _peerName = (peerName != null && peerName.trim().isNotEmpty)
        ? peerName.trim()
        : null;
    // agent 1v1 通话的参与者身份走 Phase 1 only-human 的 /calls 参与者列表拿不到
    // (数字员工不进 accounts 表)，只能靠调用方传入的已知头像做兜底。
    _peerAvatarUrl = (peerAvatarUrl != null && peerAvatarUrl.trim().isNotEmpty)
        ? resolveAgentAvatarUrl(peerAvatarUrl.trim())
        : null;
    notifyListeners();
    unawaited(_tone.playOutgoingRingback()); // 拨号回铃，直到接通/取消/失败

    // 1) 创建后端通话。失败 → 后端无成功状态可清，直接释放本地。
    final RtcCallSession session;
    final bool isGroupOutgoing =
        (calleeAccountUuid == null || calleeAccountUuid.trim().isEmpty) &&
            (agentUuid == null || agentUuid.trim().isEmpty);
    try {
      session = await _api.createCall(
        roomUuid: roomUuid,
        calleeAccountUuid: calleeAccountUuid,
        agentUuid: agentUuid,
        conversationUuid: conversationUuid,
        kind: mediaKind == RtcMediaKind.video ? 'video' : 'audio',
      );
    } catch (e) {
      debugPrint('[F16 RTC] create failed: $e');
      final createErrorCode = _extractCallErrorCode(e);
      final recoverAnyRoom = createErrorCode == 'call.account_busy';
      if (allowBusyRecovery &&
          (createErrorCode == 'call.room_busy' || recoverAnyRoom) &&
          await _recoverPersistedBusyCall(
            roomUuid,
            allowDifferentRoom: recoverAnyRoom,
          )) {
        await _endLocally();
        await _startOutgoing(
          roomUuid: roomUuid,
          calleeAccountUuid: calleeAccountUuid,
          agentUuid: agentUuid,
          conversationUuid: conversationUuid,
          peerName: peerName,
          peerAvatarUrl: peerAvatarUrl,
          mediaKind: mediaKind,
          allowBusyRecovery: false,
        );
        return;
      }
      await _endLocally(
          toast: _callErrorText(e, fallback: '发起$_mediaWord通话失败，请稍后重试'));
      return;
    }
    _callUuid = session.callUuid;
    await _captureRemoteParticipants(session.participants, peerName: peerName);
    await _rememberActiveCall(roomUuid: roomUuid, callUuid: session.callUuid);
    debugPrint('[F16 RTC] outgoing created call=$_callUuid');

    // 2) 入会。ringing 失败走 /cancel；Agent StartAgent 成功后后端可能已 active，失败须 /leave。
    final backendActive = session.state == 'active';
    try {
      await _joinRtc(session);
    } catch (e) {
      debugPrint('[F16 RTC] outgoing join failed; cleaning backend: $e');
      if (backendActive) {
        await _leaveBackendBestEffort(_callUuid);
      } else {
        await _cancelBackendBestEffort(_callUuid);
      }
      await _endLocally(
          toast: _callErrorText(e, fallback: '发起$_mediaWord通话失败，请稍后重试'));
      return;
    }
    if (backendActive) {
      _phase = RtcCallPhase.active;
      _connectedAt ??= DateTime.now();
      unawaited(_tone.stop());
      unawaited(_showMeeting());
      unawaited(_refreshDevices());
      unawaited(loadScreenShareSources());
    } else if (isGroupOutgoing) {
      _meetingStarted = true;
      _outgoingGroupMeetingOpened = true;
      _connectedAt ??= DateTime.now();
      unawaited(_tone.stop());
      unawaited(_showMeeting());
      unawaited(_refreshDevices());
      unawaited(loadScreenShareSources());
    }
    // 人↔人/群通话维持 outgoingRinging，等对方入会(RtcRemoteUserJoined) → active。
    _busy = false;
    notifyListeners();
  }

  /// 取消呼叫（**仅** outgoingRinging：对方还没答应，走 /cancel）。
  Future<void> cancelOutgoing() async {
    if (_phase != RtcCallPhase.outgoingRinging) return;
    final id = _callUuid;
    _busy = true;
    _phase = RtcCallPhase.ending;
    notifyListeners();
    await _cancelBackendBestEffort(id);
    await _endLocally();
  }

  // ── 被叫方 ──

  /// 接听来电：answer + 入会。
  Future<void> acceptIncoming() async {
    if (_phase != RtcCallPhase.incomingRinging) return;
    final id = _callUuid;
    if (id == null || id.isEmpty) return;
    debugPrint('[F16 RTC] acceptIncoming begin call=$id');
    _busy = true;
    _phase = RtcCallPhase.connecting;
    notifyListeners();
    unawaited(_tone.stop()); // 接听即停来电铃声（call 进入 connecting，不 reset）
    _hideNativeIncoming(); // 关原生来电浮窗

    // 1) answer 后端。失败 → 后端仍 ringing，本端只释放本地（caller 端会自行 cancel/超时）。
    final RtcCallSession session;
    try {
      session = await _api.answer(id);
    } catch (e) {
      debugPrint('[F16 RTC] answer failed: $e');
      await _endLocally(toast: _callErrorText(e, fallback: '接听失败，请稍后重试'));
      return;
    }
    debugPrint(
        '[F16 RTC] answer ok call=$id channel=${session.aliyunChannelId} '
        'state=${session.state} participants=${session.participants.length} hasRtc=${session.rtc != null}');
    await _captureRemoteParticipants(session.participants, peerName: _peerName);
    // 2) 入会。失败 → 后端已 answer(active)，必须 best-effort /leave 释放，再释放本地。
    try {
      await _joinRtc(session);
    } catch (e) {
      debugPrint('[F16 RTC] accept join failed; leaving backend: $e');
      await _leaveBackendBestEffort(id);
      await _endLocally(toast: _callErrorText(e, fallback: '接听失败，请稍后重试'));
      return;
    }
    debugPrint(
        '[F16 RTC] acceptIncoming joined native ok call=$id, waiting for remote (connecting)');
    // 维持 connecting，等对方在频道(RtcRemoteUserJoined) → active。
    _busy = false;
    notifyListeners();
  }

  /// 拒接来电。
  Future<void> rejectIncoming() async {
    if (_phase != RtcCallPhase.incomingRinging) return;
    final id = _callUuid;
    _busy = true;
    notifyListeners();
    try {
      if (id != null && id.isNotEmpty) await _api.reject(id);
    } catch (e) {
      debugPrint('[F16 RTC] reject api failed: $e');
    }
    await _endLocally();
  }

  /// 点推送通知(`call_invite`)进来时调用：App 可能刚从后台/被杀死状态恢复，实时信令
  /// (WuKong invite)可能已经错过，本地没有任何来电状态。按 [callUuid] 主动查一次后端
  /// 当前状态——仍是 ringing 才弹出接听 UI；已经结束/取消/被其它设备接听就不弹，只让
  /// 调用方跳转到会话页。返回是否成功弹出了接听 UI。
  Future<bool> attachRingingCall(String callUuid, {String? roomUuid}) async {
    if (callUuid.isEmpty || _phase != RtcCallPhase.idle) return false;
    final RtcCallSession session;
    try {
      session = await _api.get(callUuid);
    } catch (e) {
      debugPrint('[F16 RTC] attachRingingCall get failed: $e');
      return false;
    }
    if (session.state != 'ringing' || _phase != RtcCallPhase.idle) {
      return false;
    }
    RtcCallParticipant? caller;
    for (final p in session.participants) {
      if (p.isCaller) {
        caller = p;
        break;
      }
    }
    _phase = RtcCallPhase.incomingRinging;
    _direction = RtcCallDirection.incoming;
    _mediaKind = session.kind.trim().toLowerCase() == 'video'
        ? RtcMediaKind.video
        : RtcMediaKind.audio;
    _cameraOn = _mediaKind == RtcMediaKind.video;
    _callUuid = callUuid;
    if (roomUuid != null && roomUuid.isNotEmpty) {
      _roomUuid = roomUuid;
      unawaited(_rememberActiveCall(roomUuid: roomUuid, callUuid: callUuid));
    }
    _peerName =
        (caller?.displayName.isNotEmpty ?? false) ? caller!.displayName : null;
    _peerAvatarUrl =
        (caller?.avatarUrl.isNotEmpty ?? false) ? caller!.avatarUrl : null;
    notifyListeners();
    unawaited(_tone.playIncomingRingtone());
    unawaited(_showNativeIncoming());
    return true;
  }

  // ── 通话中 ──

  /// 挂断（connecting / active —— 双方已答应，走 /leave）。
  Future<void> hangUp() async {
    if (_phase == RtcCallPhase.idle) return;
    unawaited(HapticUtils.mediumImpact());
    final id = _callUuid;
    final phaseBeforeEnding = _phase;
    _busy = true;
    _phase = RtcCallPhase.ending;
    notifyListeners();
    final backendEnded = await _endBackendBestEffort(
      id,
      preferLeave: phaseBeforeEnding != RtcCallPhase.outgoingRinging,
    );
    if (!backendEnded && id != null && id.isNotEmpty) {
      _preserveRecoveryRecordOnReset = true;
    }
    await _endLocally();
  }

  /// 麦克风静音切换。
  Future<void> toggleMute() async {
    if (!meetingActive) return;
    _muted = !_muted;
    notifyListeners();
    _updateMeeting();
    try {
      await _client.setMicrophoneMuted(_muted);
    } catch (e) {
      debugPrint('[F16 RTC] setMicrophoneMuted failed: $e');
    }
  }

  /// 摄像头开关（统一会议模型：**audio 通话也可开**摄像头 = 升级到视频能力，
  /// 不重建 call_session；走真实 native setCameraEnabled（enableLocalVideo+publishLocalVideoStream），
  /// rc!=0 或异常回滚 UI——**不假成功**；动态 publish 是否可靠未两台 Mac 真机核验）。
  Future<void> toggleCamera() async {
    if (!meetingActive && _phase != RtcCallPhase.connecting) {
      return;
    }
    final next = !_cameraOn;
    _cameraOn = next;
    notifyListeners();
    _updateMeeting();
    try {
      await _client.setCameraEnabled(next);
    } catch (e) {
      debugPrint('[F16 RTC] setCameraEnabled failed; rollback: $e');
      _cameraOn = !next; // rc!=0 或异常 → 回滚 UI
      notifyListeners();
      _updateMeeting();
    }
  }

  /// 切换布局（gallery/speaker），同步会议窗口。
  void switchLayout() {
    if (!meetingActive) return;
    _layout = _layout == RtcMeetingLayout.gallery
        ? RtcMeetingLayout.speaker
        : RtcMeetingLayout.gallery;
    notifyListeners();
    _updateMeeting();
  }

  /// 开关参会人侧栏，同步会议窗口。
  void toggleParticipants() {
    _participantsPanelOpen = !_participantsPanelOpen;
    notifyListeners();
    _updateMeeting();
  }

  void requestInviteParticipants() {
    if (!canInviteParticipants) {
      return;
    }
    _inviteRequests.add(null);
  }

  Future<void> inviteParticipants(
    List<String> accountUuids, {
    bool showErrorToast = true,
  }) async {
    final id = _callUuid;
    final picked = accountUuids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (id == null || id.isEmpty || picked.isEmpty) return;
    try {
      final updated =
          await _api.inviteParticipants(callUuid: id, accountUuids: picked);
      // 用邀请后返回的全量参与者刷新"呼叫中"列表——被邀请人此时还没入会
      // (RtcRemoteUserJoined 未触发)，但已经能拿到真实姓名/头像展示为"呼叫中"。
      await _captureRemoteParticipants(updated);
      notifyListeners();
      _updateMeeting();
      _showToast('已发送会议邀请');
    } catch (e) {
      debugPrint('[F16 RTC] invite participants failed: $e');
      if (showErrorToast) {
        _showToast(_callErrorText(e, fallback: '邀请参会人失败'));
        return;
      }
      rethrow;
    }
  }

  /// 回到/聚焦独立会议窗口（轻量状态条「回到会议窗口」按钮）。
  /// 原生窗已显示 → 恢复（取消最小化）+ 前置 + 同步状态；否则重试 show（fallback 路径）。
  void returnToMeeting() {
    if (_nativeMeetingActive) {
      unawaited(_meeting.bringToFront());
      _updateMeeting();
    } else {
      unawaited(_showMeeting());
    }
  }

  // ── 会议窗口编排（仅 active；native 优先，失败回退 app 内会议壳）──

  RtcMeetingWindowState _meetingState() => RtcMeetingWindowState(
        callUuid: _callUuid ?? '',
        peerName: displayName,
        peerAvatarUrl: _peerAvatarUrl ?? '',
        selfDisplayName: '我',
        selfAvatarUrl: _selfAvatarUrl,
        mediaKind: _mediaKind == RtcMediaKind.video ? 'video' : 'audio',
        phase: _phase.name,
        elapsedSeconds: _connectedAt == null
            ? 0
            : DateTime.now().difference(_connectedAt!).inSeconds,
        muted: _muted,
        cameraOn: _cameraOn,
        remoteUserId: _remoteUserId,
        remoteUserIds: remoteUserIds,
        remoteCameraOnUserIds: _remoteVideoOnUserIds.toList(),
        joinedParticipantNames: joinedParticipantNames,
        joinedParticipantAvatars:
            joinedParticipants.map((p) => p.avatarUrl).toList(),
        callingParticipantNames: callingParticipantNames,
        callingParticipantAvatars:
            callingParticipants.map((p) => p.avatarUrl).toList(),
        layout: _layout,
        participantsPanelOpen: _participantsPanelOpen,
        microphoneDevices: _micDevices,
        speakerDevices: _speakerDevices,
        cameraDevices: _cameraDevices,
        speakerSupported: _speakerSupported,
        networkText: _networkText,
        screenSharing: _screenSharing,
        screenShareBusy: _screenShareBusy,
        remoteScreenSharing: _remoteScreenSharing,
        remoteScreenUserId: _remoteScreenUserId,
        screenShareSources: _screenShareSources,
        canInviteParticipants: canInviteParticipants,
      );

  /// 顶部网络状态文案。**未收到真实 callback（null）→ 中性「已连接」，不伪造「网络良好」。**
  String get _networkText {
    switch (_networkLevel) {
      case 0:
        return '网络良好';
      case 1:
        return '网络较差';
      case 2:
        return '网络中断';
      default:
        return '已连接'; // 3 未知 / null 未收到
    }
  }

  /// 会议中拉取三类设备列表（mic/speaker/camera），刷新会议窗口/壳菜单。
  /// macOS 返回桌面设备枚举；Android 返回系统音频路由 + 摄像头能力；未实现 bridge 的平台
  /// 可能抛 MissingPlugin，catch 后置空（菜单显示「未检测到设备」）。
  Future<void> _refreshDevices() async {
    try {
      final mic = await _client.listDevices(RtcDeviceKind.microphone);
      final spk = await _client.listDevices(RtcDeviceKind.speaker);
      final cam = await _client.listDevices(RtcDeviceKind.camera);
      _micDevices = mic;
      _speakerDevices = spk;
      _cameraDevices = cam;
    } catch (e) {
      debugPrint('[F16 RTC] listDevices failed (ignored, empty menus): $e');
      _micDevices = const <RtcDeviceInfo>[];
      _speakerDevices = const <RtcDeviceInfo>[];
      _cameraDevices = const <RtcDeviceInfo>[];
    }
    if (_disposed) return;
    notifyListeners();
    _updateMeeting();
  }

  /// 原生会议窗口设备菜单点选 → 真实切换设备；**失败 toast + 不改 selected（回读列表反映真实当前）**。
  Future<void> _onDeviceSelection(RtcDeviceSelection sel) async {
    if (!meetingActive) return;
    try {
      await _client.selectDevice(sel.kind, sel.deviceId);
    } catch (e) {
      debugPrint('[F16 RTC] selectDevice failed: $e');
      _showToast('切换设备失败');
    }
    // 无论成败都回读：成功→当前变更；失败→当前不变（不假成功）。
    await _refreshDevices();
  }

  // ── 屏幕共享（仅 macOS 会议窗口；同一端单路；不发 1001、不改后端）──

  bool get screenSharing => _screenSharing;
  bool get screenShareBusy => _screenShareBusy;
  bool get remoteScreenSharing => _remoteScreenSharing;
  String? get remoteScreenUserId => _remoteScreenUserId;
  List<RtcDeviceInfo> get microphoneDevices => _micDevices;
  List<RtcDeviceInfo> get speakerDevices => _speakerDevices;
  List<RtcDeviceInfo> get cameraDevices => _cameraDevices;
  bool get speakerSupported => _speakerSupported;
  List<RtcScreenShareSource> get screenShareSources => _screenShareSources;
  String? get selectedScreenShareSourceId => _selectedScreenShareSourceId;

  /// App 内会议壳设备菜单选择；复用原生会议窗同一条 select + 回读刷新路径。
  Future<void> selectDevice(RtcDeviceKind kind, String deviceId) =>
      _onDeviceSelection(RtcDeviceSelection(kind, deviceId));

  /// 拉取可共享的屏幕/窗口源（无权限 → 空列表，菜单只剩「共享整个屏幕」）。
  Future<void> loadScreenShareSources() async {
    try {
      _screenShareSources = await _client.listScreenShareSources();
    } catch (e) {
      debugPrint('[F16 RTC] listScreenShareSources failed (ignored): $e');
      _screenShareSources = const <RtcScreenShareSource>[];
    }
    if (_disposed) return; // 通话已结束/销毁 → 不再 notify
    notifyListeners();
    _updateMeeting();
  }

  /// 开始屏幕共享（[sourceId] null = 整个屏幕）。仅 connecting/active；同一端已共享则提示不重复。
  /// 权限缺失 / rc!=0 → 回滚 UI + 明确提示，**不假成功**。
  Future<void> startScreenShare([String? sourceId]) async {
    if (!meetingActive && _phase != RtcCallPhase.connecting) {
      return;
    }
    if (_screenShareBusy) return;
    if (_screenSharing) {
      _showToast('正在共享屏幕');
      return;
    }
    _screenShareBusy = true;
    _selectedScreenShareSourceId = sourceId;
    notifyListeners();
    _updateMeeting();
    try {
      await _client.startScreenShare(sourceId: sourceId);
      _screenSharing = true;
    } on PlatformException catch (e) {
      _screenSharing = false;
      _showToast(e.code == 'screen_permission_denied'
          ? '需要屏幕录制权限，请在系统设置中授权后重试'
          : '屏幕共享失败');
    } catch (e) {
      debugPrint('[F16 RTC] startScreenShare failed: $e');
      _screenSharing = false;
      _showToast('屏幕共享失败');
    } finally {
      _screenShareBusy = false;
      notifyListeners();
      _updateMeeting();
    }
    if (_screenSharing) {
      unawaited(loadScreenShareSources()); // 授权后刷新真实源列表
    }
  }

  /// 停止屏幕共享。stop 失败也回到未共享态（不让 UI 卡住）；native 已强制 stopScreenShare。
  Future<void> stopScreenShare() async {
    if (!_screenSharing && !_screenShareBusy) return;
    _screenShareBusy = true;
    notifyListeners();
    _updateMeeting();
    try {
      await _client.stopScreenShare();
    } catch (e) {
      debugPrint('[F16 RTC] stopScreenShare failed (forcing UI off): $e');
    } finally {
      _screenSharing = false;
      _screenShareBusy = false;
      notifyListeners();
      _updateMeeting();
    }
  }

  /// 共享按钮 toggle：共享中→停止；否则→开始（整个屏幕）。
  Future<void> toggleScreenShare() async {
    if (_screenSharing) {
      await stopScreenShare();
    } else {
      await startScreenShare();
    }
  }

  void _onScreenShareRequest(RtcScreenShareRequest r) {
    if (r.start) {
      unawaited(startScreenShare(r.sourceId));
    } else {
      unawaited(stopScreenShare());
    }
  }

  Future<void> _showMeeting() async {
    final shown = await _meeting.showMeeting(_meetingState());
    if (meetingActive) {
      _nativeMeetingActive = shown; // 成功 → app 内只显示状态条；失败 → app 会议壳 fallback
      notifyListeners();
    }
  }

  void _updateMeeting() {
    if (_nativeMeetingActive) {
      unawaited(_meeting.updateMeeting(_meetingState()));
    }
  }

  void _hideMeeting() {
    if (_nativeMeetingActive) _nativeMeetingActive = false;
    unawaited(_meeting.hideMeeting());
  }

  void _onMeetingAction(RtcMeetingWindowAction action) {
    switch (action) {
      case RtcMeetingWindowAction.hangUp:
      case RtcMeetingWindowAction.close: // 窗口关闭 = 挂断（MVP）
        unawaited(hangUp());
        break;
      case RtcMeetingWindowAction.toggleMute:
        unawaited(toggleMute());
        break;
      case RtcMeetingWindowAction.toggleCamera:
        unawaited(toggleCamera());
        break;
      case RtcMeetingWindowAction.switchLayout:
        switchLayout();
        break;
      case RtcMeetingWindowAction.toggleParticipants:
        toggleParticipants();
        break;
      case RtcMeetingWindowAction.invite:
        requestInviteParticipants();
        break;
      case RtcMeetingWindowAction.restore:
        returnToMeeting();
        break;
    }
  }

  // ── 内部 ──

  Future<void> _joinRtc(RtcCallSession session) async {
    final config = session.rtc;
    if (config == null) {
      throw StateError('后端未返回 RTC 入会凭证 (rtc=null)');
    }
    debugPrint(
        '[F16 RTC] joinRtc begin call=${session.callUuid} channel=${config.channelId} '
        'userId=${config.userId} mediaKind=$_mediaKind expectedRemote=$_expectedRemoteParticipants '
        'participants=${session.participants.length}');
    await _client.initialize();
    // 单一责任：video 通话由 native joinChannel(video:true) 负责开摄像头 + 发布本地视频 +
    // 订阅远端视频；Dart **不**在 join 后重复调 setCameraEnabled（仅摄像头开关按钮调）。
    await _client.joinChannel(config, mediaKind: _mediaKind);
  }

  /// 会中收到"别人邀请了新参会人"的 invite 信令后同步刷新参会人列表（含新人的
  /// "呼叫中"状态）。查询通话**当前**详情、交给 [_captureRemoteParticipants] 按
  /// 查回来的真实参与者列表重算 _expectedRemoteParticipants/_pendingParticipants，
  /// 保证已在会的人也能看到新邀请的人出现在"呼叫中"，跟发起邀请那一端一致。
  Future<void> _syncParticipantsForOngoingCall() async {
    final id = _callUuid;
    if (id == null || id.isEmpty) return;
    try {
      final session = await _api.get(id);
      if (session.callUuid != _callUuid) return; // 通话已切换，丢弃过期结果
      await _captureRemoteParticipants(session.participants);
      notifyListeners();
      _updateMeeting();
    } catch (e) {
      debugPrint('[F16 RTC] sync participants for ongoing invite failed: $e');
    }
  }

  Future<void> _captureRemoteParticipants(
    List<RtcCallParticipant> participants, {
    String? peerName,
  }) async {
    if (_selfAvatarUrl.isEmpty) {
      final me = await AccountInfoService().getCachedAccountInfo();
      _selfAvatarUrl = resolveAgentAvatarUrl(me?.avatar.trim() ?? '');
    }
    final identity = await WukongSessionIdentity.current();
    // 排除"自己"必须按 accountUuid 比对，不能用 !isCaller——接听方自己的 role 也不是
    // 'caller'，用 role 判据会把接听方自己误当成"远端参与者"塞进 pendingParticipants/
    // 头像映射，导致接听方会议窗口里对方的头像显示成了自己的。identity 拿不到时
    // (理论上不会发生) 才退回旧的 role 判据兜底。
    final remoteHumans = participants
        .where((p) =>
            p.isHuman &&
            (identity != null
                ? p.accountUuid != identity.accountUuid
                : !p.isCaller))
        .toList();
    final fallbackCount =
        _peerName != null && _peerName!.trim().isNotEmpty ? 1 : 0;
    _expectedRemoteParticipants = remoteHumans.isNotEmpty
        ? remoteHumans.length
        : (fallbackCount > 0 ? fallbackCount : _expectedRemoteParticipants);
    final count = _expectedRemoteParticipants;
    final directName =
        (peerName != null && peerName.trim().isNotEmpty) ? peerName.trim() : '';
    String? uidFor(RtcCallParticipant p) {
      if (identity == null || p.accountUuid.isEmpty) return null;
      return WukongSessionIdentity(
        tenantId: identity.tenantId,
        accountUuid: p.accountUuid,
      ).uid;
    }

    _pendingParticipants = List<RtcParticipantDisplay>.generate(count, (i) {
      if (i < remoteHumans.length && remoteHumans[i].displayName.isNotEmpty) {
        final p = remoteHumans[i];
        return RtcParticipantDisplay(
          name: p.displayName,
          avatarUrl: p.avatarUrl,
          uid: uidFor(p),
        );
      }
      if (count == 1 && directName.isNotEmpty) {
        return RtcParticipantDisplay(name: directName);
      }
      return RtcParticipantDisplay(name: '成员 ${i + 1}');
    });

    final byUid = <String, RtcCallParticipant>{};
    if (identity != null) {
      for (final p in remoteHumans) {
        if (p.accountUuid.isEmpty) continue;
        final uid = WukongSessionIdentity(
          tenantId: identity.tenantId,
          accountUuid: p.accountUuid,
        ).uid;
        byUid[uid] = p;
      }
    }
    _remoteParticipantsByUid = byUid;
  }

  /// best-effort 同步后端：/cancel（呼叫中放弃）。失败只 log，不阻断本地释放。
  Future<bool> _cancelBackendBestEffort(String? id) async {
    if (id == null || id.isEmpty) return true;
    try {
      await _api.cancel(id);
      return true;
    } catch (e) {
      debugPrint('[F16 RTC] best-effort cancel failed (ignored): $e');
      return false;
    }
  }

  /// best-effort 同步后端：/leave（已接通后结束）。失败只 log，不阻断本地释放。
  Future<bool> _leaveBackendBestEffort(String? id) async {
    if (id == null || id.isEmpty) return true;
    try {
      await _api.leave(id);
      return true;
    } catch (e) {
      debugPrint('[F16 RTC] best-effort leave failed (ignored): $e');
      return false;
    }
  }

  /// 挂断收尾首选状态机语义对应的接口；若后端 state 与本地 phase 分叉，
  /// 再 best-effort 尝试另一个结束接口，避免留下 ringing/active lock。
  Future<bool> _endBackendBestEffort(
    String? id, {
    required bool preferLeave,
  }) async {
    if (id == null || id.isEmpty) return true;
    if (preferLeave) {
      if (await _leaveBackendBestEffort(id)) return true;
      return _cancelBackendBestEffort(id);
    }
    if (await _cancelBackendBestEffort(id)) return true;
    return _leaveBackendBestEffort(id);
  }

  /// 远端先离会 / RTC 底层异常也必须同步后端 `/leave`，否则 active
  /// call_session 和 active_call_participant_lock 会残留，下一次拨号被 room/account busy 拦住。
  Future<void> _leaveBackendThenEndLocally({String? toast}) async {
    final id = _callUuid;
    await _leaveBackendBestEffort(id);
    await _endLocally(toast: toast);
  }

  Future<void> _rememberActiveCall({
    required String roomUuid,
    required String callUuid,
  }) async {
    if (roomUuid.isEmpty || callUuid.isEmpty) return;
    try {
      await _recoveryStore.writeLastCall(
        RtcLastCallRecord(callUuid: callUuid, roomUuid: roomUuid),
      );
    } catch (e) {
      debugPrint('[F16 RTC] remember active call failed (ignored): $e');
    }
  }

  Future<void> _forgetActiveCall(String? callUuid) async {
    if (callUuid == null || callUuid.isEmpty) return;
    try {
      await _recoveryStore.clearLastCall(callUuid: callUuid);
    } catch (e) {
      debugPrint('[F16 RTC] forget active call failed (ignored): $e');
    }
  }

  /// 热重载 / native 进程状态切换可能让客户端本地 UI 回 idle，但后端仍保留上一通
  /// `call_session` / lock；下一次 create 会返回 busy。room_busy 只清理同 room，
  /// account_busy 允许清理本机记得的另一 room 通话，因为账号锁是跨 room 的。
  Future<bool> _recoverPersistedBusyCall(
    String roomUuid, {
    bool allowDifferentRoom = false,
  }) async {
    try {
      final last = await _recoveryStore.readLastCall();
      if (last == null ||
          (!allowDifferentRoom && last.roomUuid != roomUuid) ||
          last.callUuid.isEmpty) {
        return false;
      }
      debugPrint('[F16 RTC] busy; recovering persisted call=${last.callUuid}');
      final left = await _leaveBackendBestEffort(last.callUuid);
      final cancelled = await _cancelBackendBestEffort(last.callUuid);
      if (!left && !cancelled) return false;
      await _recoveryStore.clearLastCall(callUuid: last.callUuid);
      _showToast('已清理上一次未正常结束的通话，请稍候');
      return true;
    } catch (e) {
      debugPrint('[F16 RTC] recover persisted busy call failed: $e');
      return false;
    }
  }

  /// 结束本通话：**先保证本地 RTC 释放**（避免麦克风残留），再复位 UI。
  Future<void> _endLocally({String? toast}) async {
    await _stopScreenShareBestEffort(); // 结束前先停共享，避免残留（native 离会也会兜底停）
    await _releaseNativeRtc();
    _reset();
    if (toast != null) _showToast(toast);
  }

  /// 结束/挂断前 best-effort 停止屏幕共享（仅在共享/切换中时触发，失败只 log）。
  Future<void> _stopScreenShareBestEffort() async {
    if (!_screenSharing && !_screenShareBusy) return;
    try {
      await _client.stopScreenShare();
    } catch (e) {
      debugPrint('[F16 RTC] stopScreenShare on end failed (ignored): $e');
    }
  }

  /// P1-3：保证本地 RTC 释放。leaveChannel 成功即可；抛错则强制 dispose 当前 client
  /// 并用 factory 重建一个可用实例（否则 macOS 上 UI 关了但 DingRTC 仍占麦克风）。
  Future<void> _releaseNativeRtc() async {
    try {
      await _client.leaveChannel();
    } catch (e) {
      debugPrint('[F16 RTC] leaveChannel failed; forcing dispose+recreate: $e');
      await _recreateClient();
    }
  }

  /// 强制 dispose 当前 client（释放麦克风/引擎）并重建，事件订阅切到新 client。
  Future<void> _recreateClient() async {
    final old = _client;
    await _eventSub?.cancel();
    try {
      await old.dispose();
    } catch (e) {
      debugPrint('[F16 RTC] client dispose failed (ignored): $e');
    }
    _client = _clientFactory();
    _eventSub = _client.events.listen(_onRtcEvent);
    _muted = false;
    debugPrint('[F16 RTC] rtc client recreated after failed leave');
  }

  void _reset() {
    // 任何结束/清理路径（reject/cancel/hangUp/end/error/create·join·answer fail）都经此复位 →
    // 统一停声 + 关原生来电浮窗 + 关独立会议窗口，保证 idle 不残留声音/浮窗/会议窗口。
    unawaited(_tone.stop());
    _hideNativeIncoming();
    _hideMeeting();
    final endedCallUuid = _callUuid;
    _phase = RtcCallPhase.idle;
    _direction = RtcCallDirection.none;
    _callUuid = null;
    _roomUuid = null;
    _peerName = null;
    _peerAvatarUrl = null;
    _meetingStarted = false;
    _outgoingGroupMeetingOpened = false;
    _expectedRemoteParticipants = 0;
    _pendingParticipants = const <RtcParticipantDisplay>[];
    _remoteParticipantsByUid = const <String, RtcCallParticipant>{};
    _muted = false;
    _busy = false;
    _connectedAt = null;
    _mediaKind = RtcMediaKind.audio;
    _remoteUserId = null;
    _remoteUserIds.clear();
    _remoteVideoOnUserIds.clear();
    _cameraOn = false;
    _layout = RtcMeetingLayout.gallery;
    _participantsPanelOpen = false;
    _micDevices = const <RtcDeviceInfo>[];
    _speakerDevices = const <RtcDeviceInfo>[];
    _cameraDevices = const <RtcDeviceInfo>[];
    _networkLevel = null;
    // 屏幕共享复位（native releaseVideoCapture 已 best-effort stopScreenShare）。
    _screenSharing = false;
    _screenShareBusy = false;
    _remoteScreenSharing = false;
    _remoteScreenUserId = null;
    _screenShareSources = const <RtcScreenShareSource>[];
    _selectedScreenShareSourceId = null;
    // A1 方案 C: agent 通话结束 → 发结束信号（tick 递增），聊天侧 reload canonical
    // 历史替换 live 气泡；live 层内存态全清。信号必须在 notifyListeners() 之前置好。
    if (_agentConversationUuid != null) {
      _lastEndedAgentConversationUuid = _agentConversationUuid;
      _agentCallEndedTick++;
    }
    _agentConversationUuid = null;
    _liveTranscripts.clear();
    _loggedBeginTimeMissing = false;
    _agentState = RtcAgentState.unknown;
    _interruptedAgentRounds.clear();
    if (_preserveRecoveryRecordOnReset) {
      _preserveRecoveryRecordOnReset = false;
    } else {
      unawaited(_forgetActiveCall(endedCallUuid));
    }
    notifyListeners();
  }

  /// 从 1001 invite payload 的 `data.kind` 解析媒体类型（'video' → video，其余 audio）。
  RtcMediaKind _mediaKindFromData(Map<String, dynamic> data) {
    final k = (data['kind'] ?? '').toString().trim().toLowerCase();
    return k == 'video' ? RtcMediaKind.video : RtcMediaKind.audio;
  }

  /// 显示 macOS 原生来电浮窗；成功显示则隐藏 app 内来电卡（避免双卡）。
  /// 仅在仍处于 incomingRinging 时生效（避免 await 期间通话已结束的竞态）。
  Future<void> _showNativeIncoming() async {
    final shown = await _nativeIncoming.showIncoming(
      callUuid: _callUuid ?? '',
      peerName: displayName,
      peerAvatarUrl: _peerAvatarUrl,
      mediaKind: _mediaKind == RtcMediaKind.video ? 'video' : 'audio',
    );
    if (_phase == RtcCallPhase.incomingRinging && shown) {
      _nativeIncomingActive = true;
      notifyListeners();
    }
  }

  /// 关闭原生来电浮窗并复位标记（幂等）。
  void _hideNativeIncoming() {
    if (_nativeIncomingActive) {
      _nativeIncomingActive = false;
    }
    unawaited(_nativeIncoming.hide());
  }

  /// 原生浮窗上的 accept/reject/close → 走既有 HTTP 状态机（不直接改 state）。
  void _onNativeIncomingAction(RtcNativeIncomingAction action) {
    if (_phase != RtcCallPhase.incomingRinging) return;
    switch (action) {
      case RtcNativeIncomingAction.accept:
        unawaited(acceptIncoming());
        break;
      case RtcNativeIncomingAction.reject:
      case RtcNativeIncomingAction.close: // 关闭浮窗等同拒接
        unawaited(rejectIncoming());
        break;
    }
  }

  void _onSignal(RtcCallSignalIncoming signal) {
    final self = _selfUid();
    final callUuid = (signal.data['call_uuid'] ?? '').toString();
    debugPrint(
      '[F16 RTC] controller signal event=${rtcCallSignalEventName(signal.event)} '
      'call=$callUuid from=${signal.fromUid} phase=$_phase',
    );
    if (self != null && self.isNotEmpty && signal.fromUid == self) {
      debugPrint('[F16 RTC] controller ignored self signal call=$callUuid');
      return;
    }
    if (callUuid.isEmpty) {
      debugPrint('[F16 RTC] controller ignored signal without call_uuid');
      return;
    }
    switch (signal.event) {
      case RtcCallSignalEvent.invite:
        if (_phase != RtcCallPhase.idle) {
          if (callUuid == _callUuid) {
            // 会中收到同一通话的 invite 信令：这不是给自己的来电，是群通话里
            // "别人邀请了新参会人"——invite 信令走的是房间群 channel，所有已在会
            // 的人都会收到，但信令 payload 里只有发起邀请那个人的身份，没有被
            // 邀请人的身份，无法直接从信令拼出"呼叫中"条目；主动拉一次通话详情
            // 才能让已在会的人同步看到新参会人的"呼叫中"状态。
            unawaited(_syncParticipantsForOngoingCall());
            return;
          }
          _showToast('当前已有通话');
          debugPrint('[F16 RTC] invite ignored: busy phase=$_phase');
          return;
        }
        _phase = RtcCallPhase.incomingRinging;
        _direction = RtcCallDirection.incoming;
        _mediaKind = _mediaKindFromData(
            signal.data); // B 阶段：invite data.kind=video → 视频来电
        _cameraOn = _mediaKind == RtcMediaKind.video; // 接听后 native 开摄像头
        _callUuid = callUuid;
        final roomUuid = (signal.data['room_uuid'] ?? '').toString();
        if (roomUuid.isNotEmpty) {
          _roomUuid = roomUuid;
          unawaited(_rememberActiveCall(
            roomUuid: roomUuid,
            callUuid: callUuid),
          );
        }
        _peerName = _extractCallerName(signal);
        _peerAvatarUrl = _extractCallerAvatarUrl(signal);
        notifyListeners();
        unawaited(_tone.playIncomingRingtone()); // 来电铃声，直到接听/拒接/取消/超时
        unawaited(_showNativeIncoming()); // macOS：屏幕右下角原生来电浮窗（其它平台 no-op）
        break;
      case RtcCallSignalEvent.accept:
        // 对端接听 → 呼叫中切到"接通建立中"，真正 active 等 RtcRemoteUserJoined。
        if (callUuid == _callUuid && _phase == RtcCallPhase.outgoingRinging) {
          _phase = RtcCallPhase.connecting;
          notifyListeners();
          unawaited(_tone.stop()); // 对端已接 → 停拨号回铃
        }
        break;
      case RtcCallSignalEvent.cancel:
      case RtcCallSignalEvent.end:
        if (callUuid == _callUuid && _phase != RtcCallPhase.idle) {
          unawaited(_endLocally(toast: _endToastFor(signal.event)));
        }
        break;
      case RtcCallSignalEvent.reject:
        if (callUuid == _callUuid && _phase != RtcCallPhase.idle) {
          // 群/多人呼叫：拒接的只是其中一个被邀请人 (后端 Reject() 对
          // role=invitee 只广播信令、不结束会话)，不能一个人拒接就把整通
          // 通话挂了；只有 1v1，或者群呼叫里最后一个还没应答/未加入的人也
          // 拒了，才真的结束本地通话。
          final remaining = _expectedRemoteParticipants - _remoteUserIds.length;
          if (remaining <= 1) {
            unawaited(_endLocally(toast: _endToastFor(signal.event)));
          } else {
            _expectedRemoteParticipants -= 1;
            notifyListeners();
          }
        }
        break;
      case RtcCallSignalEvent.ringing:
      case RtcCallSignalEvent.unknown:
        break;
    }
  }

  void _onRtcEvent(RtcEvent event) {
    switch (event) {
      case RtcRemoteUserJoined(:final userId):
        debugPrint(
            '[F16 RTC] remote joined user=$userId phase=$_phase call=$_callUuid');
        // 保存远端 userId → remote video view 可绑定该 uid 的画面；群会议保留多个远端。
        if (userId.isNotEmpty) {
          _remoteUserIds.add(userId);
          _remoteUserId ??= userId;
        }
        if (_phase == RtcCallPhase.outgoingRinging ||
            _phase == RtcCallPhase.connecting) {
          final wasMeetingStarted = _meetingStarted;
          _meetingStarted = true;
          _phase = RtcCallPhase.active;
          _connectedAt ??= DateTime.now();
          _busy = false;
          unawaited(_tone.stop()); // 已接通 → 停一切提示音
          if (wasMeetingStarted) {
            _updateMeeting();
          } else {
            unawaited(
                _showMeeting()); // 接通即进会议窗口（audio/video 统一；native 优先，失败回退 app 壳）
            unawaited(_refreshDevices()); // 进会议后拉一次设备列表，刷新设备菜单
            unawaited(loadScreenShareSources()); // 拉一次可共享源（无权限则空，仅「整个屏幕」）
          }
        } else if (_phase == RtcCallPhase.active) {
          _updateMeeting();
        }
        notifyListeners();
        break;
      case RtcRemoteUserLeft(:final userId):
        debugPrint(
            '[F16 RTC] remote left user=$userId phase=$_phase call=$_callUuid');
        if (userId.isNotEmpty) {
          _remoteUserIds.remove(userId);
          _remoteVideoOnUserIds.remove(userId);
          if (_remoteUserId == userId) {
            _remoteUserId =
                _remoteUserIds.isEmpty ? null : _remoteUserIds.first;
          }
        }
        if (_phase == RtcCallPhase.active &&
            _remoteUserIds.isEmpty &&
            !_outgoingGroupMeetingOpened) {
          unawaited(_leaveBackendThenEndLocally(toast: '对方已离开通话'));
        } else if (meetingActive) {
          notifyListeners();
          _updateMeeting();
        }
        break;
      case RtcRemoteVideoStateChanged(:final userId, :final enabled):
        if (userId.isEmpty) break;
        final changed = enabled
            ? _remoteVideoOnUserIds.add(userId)
            : _remoteVideoOnUserIds.remove(userId);
        debugPrint(
            '[F16 RTC] remote video user=$userId enabled=$enabled changed=$changed');
        if (changed && meetingActive) {
          notifyListeners();
          _updateMeeting();
        }
        break;
      case RtcLeft():
        if (_phase != RtcCallPhase.idle) _reset();
        break;
      case RtcError(:final message):
        debugPrint('[F16 RTC] rtc error: $message');
        if (_phase != RtcCallPhase.idle) {
          unawaited(_leaveBackendThenEndLocally(toast: '通话出错: $message'));
        }
        break;
      case RtcJoined(:final channelId):
        // 本端入会成功；caller 维持 ringing、callee 维持 connecting，等对端入会。
        debugPrint(
            '[F16 RTC] joined channel=$channelId phase=$_phase call=$_callUuid');
        break;
      case RtcNetworkQuality(:final level):
        // 真实网络质量 callback → 顶部状态文案（不再永远假写「网络良好」）。
        _networkLevel = level;
        if (meetingActive) {
          notifyListeners();
          _updateMeeting();
        }
        break;
      case RtcScreenShareStateChanged(
          :final local,
          :final active,
          :final userId
        ):
        if (local) {
          // busy 期间以显式 rc 为准（避免 Publishing 中间态闪烁）；非 busy 时同步异步停止/失败。
          if (!_screenShareBusy) _screenSharing = active;
        } else {
          _remoteScreenSharing = active;
          _remoteScreenUserId = active ? userId : null;
        }
        if (_phase == RtcCallPhase.active) {
          notifyListeners();
          _updateMeeting();
        }
        break;
      case RtcAgentStateChanged(:final state, :final rawState):
        _agentState = state;
        debugPrint('[F16 RTC] agent state=$state raw=$rawState');
        if (_phase == RtcCallPhase.active) notifyListeners();
        break;
      case RtcAgentTranscription():
        _onAgentTranscription(event);
        break;
    }
  }

  /// F16 A1 · RTM 转写 → live 气泡 map 上插。
  /// partial 为同 `(roundId, speaker)` 的**累计替换**（原地更新，不另建泡）；
  /// end=true 定稿后迟到的 partial 丢弃（不回退文本）。
  void _onAgentTranscription(RtcAgentTranscription e) {
    // 非 agent 通话 / 已复位 → 丢弃（人↔人通话不存在 RTM 转写，此处只是防御）。
    if (_callUuid == null || _agentConversationUuid == null) {
      debugPrint(
          '[F16 RTC] drop transcription without active agent call call=$_callUuid conv=$_agentConversationUuid round=${e.roundId} user=${e.isUser}');
      return;
    }
    // 全空 partial 不建泡（空文本+空思考没有可渲染内容）。
    if (e.text.trim().isEmpty && e.reasoning.trim().isEmpty) {
      debugPrint(
          '[F16 RTC] drop empty transcription round=${e.roundId} user=${e.isUser} end=${e.end}');
      return;
    }
    if (e.beginTimeMs <= 0 && !_loggedBeginTimeMissing) {
      _loggedBeginTimeMissing = true;
      debugPrint(
          '[F16 RTC] transcription beginTime missing → fallback firstSeenAt (round=${e.roundId})');
    }
    if (e.isUser &&
        (_agentState == RtcAgentState.responding ||
            _hasOpenAgentLiveTranscript)) {
      _interruptOpenAgentLiveTranscripts(reason: 'user_speech');
    }
    if (!e.isUser && _interruptedAgentRounds.contains(e.roundId)) {
      debugPrint(
          '[F16 RTC] drop interrupted agent transcription round=${e.roundId} end=${e.end} text=${e.text.length}');
      return;
    }
    final key = '${e.roundId}:${e.isUser ? 'u' : 'a'}';
    final prev = _liveTranscripts[key];
    if (prev != null && prev.interrupted) {
      debugPrint(
          '[F16 RTC] drop transcription for frozen interrupted bubble round=${e.roundId} user=${e.isUser}');
      return;
    }
    if (prev != null && prev.end && !e.end) return;
    _liveTranscripts[key] = RtcLiveTranscript(
      roundId: e.roundId,
      isUser: e.isUser,
      text: e.text,
      reasoning: e.reasoning.isNotEmpty ? e.reasoning : (prev?.reasoning ?? ''),
      end: e.end,
      beginTimeMs: e.beginTimeMs > 0 ? e.beginTimeMs : (prev?.beginTimeMs ?? 0),
      firstSeenAt: prev?.firstSeenAt ?? DateTime.now(),
      interrupted: prev?.interrupted ?? false,
    );
    debugPrint(
        '[F16 RTC] live transcription upsert conv=$_agentConversationUuid round=${e.roundId} user=${e.isUser} end=${e.end} text=${e.text.length} reasoning=${e.reasoning.length}');
    notifyListeners();
  }

  bool get _hasOpenAgentLiveTranscript => _liveTranscripts.values.any(
        (t) =>
            !t.isUser &&
            !t.end &&
            !t.interrupted &&
            (t.text.trim().isNotEmpty || t.reasoning.trim().isNotEmpty),
      );

  void _interruptOpenAgentLiveTranscripts({required String reason}) {
    var changed = false;
    for (final entry in _liveTranscripts.entries.toList()) {
      final t = entry.value;
      if (t.isUser || t.end || t.interrupted) continue;
      _interruptedAgentRounds.add(t.roundId);
      _liveTranscripts[entry.key] = RtcLiveTranscript(
        roundId: t.roundId,
        isUser: t.isUser,
        text: t.text,
        reasoning: t.reasoning,
        end: true,
        beginTimeMs: t.beginTimeMs,
        firstSeenAt: t.firstSeenAt,
        interrupted: true,
      );
      changed = true;
      debugPrint(
          '[F16 RTC] freeze interrupted agent bubble reason=$reason round=${t.roundId} text=${t.text.length}');
    }
    // Agent 正在 responding 但 RTM 文本尚未到达时，至少清状态；后续真正新轮由状态/roundId 驱动。
    if (!changed && _agentState == RtcAgentState.responding) {
      debugPrint(
          '[F16 RTC] user speech during agent responding without open bubble');
    }
    if (changed) notifyListeners();
  }

  /// 把后端错误码 / Dio 文本收敛成用户能读懂的通话提示，避免裸露 `call.invalid_state`。
  String _callErrorText(Object e, {required String fallback}) {
    final code = _extractCallErrorCode(e);
    switch (code) {
      case 'call.invalid_state':
        return '通话状态已变化，请刷新后重试';
      case 'call.not_found':
        return '通话不存在或已结束';
      case 'call.account_busy':
        return '你或对方正在通话中，请结束后再试';
      case 'call.room_busy':
        return '当前会话已有通话';
      case 'call.not_room_member':
        return '你不在当前会话中';
      case 'call.invitee_not_member':
        return '对方不在当前会话中';
      case 'call.caller_required':
      case 'call.invalid_participant':
      case 'call.invalid_request':
        return '通话参数不完整，请重新打开会话后再试';
      default:
        return fallback;
    }
  }

  String? _extractCallErrorCode(Object e) {
    dynamic data;
    if (e is DioException) {
      data = e.response?.data;
    }
    final fromData = _extractCodeFromData(data);
    if (fromData != null) return fromData;
    final text = e.toString();
    for (final code in const [
      'call.invalid_state',
      'call.not_found',
      'call.account_busy',
      'call.room_busy',
      'call.not_room_member',
      'call.invitee_not_member',
      'call.caller_required',
      'call.invalid_participant',
      'call.invalid_request',
    ]) {
      if (text.contains(code)) return code;
    }
    return null;
  }

  String? _extractCodeFromData(dynamic data) {
    if (data is Map) {
      for (final key in const ['code', 'error_code', 'err_code']) {
        final v = data[key];
        if (v != null && v.toString().startsWith('call.')) {
          return v.toString();
        }
      }
      final nested = data['error'];
      if (nested is Map) {
        return _extractCodeFromData(nested);
      }
      final message = data['message']?.toString();
      if (message != null) {
        for (final code in const [
          'call.invalid_state',
          'call.not_found',
          'call.account_busy',
          'call.room_busy',
          'call.not_room_member',
          'call.invitee_not_member',
          'call.caller_required',
          'call.invalid_participant',
          'call.invalid_request',
        ]) {
          if (message.contains(code)) return code;
        }
      }
    }
    return null;
  }

  String? _extractCallerName(RtcCallSignalIncoming signal) {
    for (final k in const [
      'caller_display_name',
      'caller_name',
      'host_name',
      'from_name',
    ]) {
      final v = signal.data[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    if (signal.channelType == 2) return '群通话';
    return null;
  }

  String? _extractCallerAvatarUrl(RtcCallSignalIncoming signal) {
    for (final k in const [
      'caller_avatar_url',
      'caller_avatar',
      'from_avatar'
    ]) {
      final v = signal.data[k];
      if (v is String && v.trim().isNotEmpty) {
        final resolved = resolveAgentAvatarUrl(v.trim());
        if (resolved.isNotEmpty) return resolved;
      }
    }
    return null;
  }

  String _endToastFor(RtcCallSignalEvent event) {
    switch (event) {
      case RtcCallSignalEvent.reject:
        return '对方已拒接';
      case RtcCallSignalEvent.cancel:
        return '对方已取消';
      default:
        return '通话已结束';
    }
  }

  @override
  void dispose() {
    _disposed = true; // async 回调（设备/共享源拉取）落地后不再 notify 已销毁的 controller
    _signalSub?.cancel();
    _eventSub?.cancel();
    _nativeActionSub?.cancel();
    _meetingActionSub?.cancel();
    _deviceSelSub?.cancel();
    _screenShareSub?.cancel();
    _inviteRequests.close();
    // 关原生来电浮窗 + 关会议窗口 + 停声并释放播放器/原生窗口（避免登出/销毁后泄漏）。
    _hideNativeIncoming();
    unawaited(_nativeIncoming.dispose());
    _hideMeeting();
    unawaited(_meeting.dispose());
    unawaited(_tone.stop());
    unawaited(_tone.dispose());
    // best-effort 释放 native client（释放麦克风/引擎）。
    unawaited(_client.dispose().catchError((Object e) {
      debugPrint('[F16 RTC] dispose client failed (ignored): $e');
    }));
    super.dispose();
  }
}

/// 全局单例 provider。挂在 MainLayout 的 overlay host 会 watch 它 → 一登录即订阅 1001 信令。
/// 随 ProviderScope 生命周期；登出（sessionScopeKey 自增重建 scope）即 dispose → 自动挂断。
final rtcCallControllerProvider = Provider<RtcCallController>((ref) {
  final controller = RtcCallController(
    // macOS 被叫来电用屏幕级原生独立浮窗；其它平台退回 app 内来电卡（Noop）。
    nativeIncomingWindow:
        PlatformUtils.isMacOS ? MethodChannelIncomingWindow() : null,
    // macOS 接通后用独立会议窗口（NSWindow）；其它平台/失败退回 app 内会议壳（Noop）。
    nativeMeetingWindow:
        PlatformUtils.isMacOS ? MethodChannelMeetingWindow() : null,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
