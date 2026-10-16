import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_session_identity.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/app_notification_service.dart';
import 'package:zhiban_client/services/desktop_network_connectivity.dart';

import 'package:zhiban_ui/utils/platform_utils.dart';
import 'conversation_connection_state.dart';
export 'conversation_connection_state.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import '../widgets/agent_mention.dart';
import 'chat_read_receipt_events.dart';
import 'chat_providers.dart';

final conversationConnectionStateProvider =
    StreamProvider<ConversationConnectionSnapshot>((ref) {
  return ref.watch(conversationRealtimeBridgeProvider).connectionChanges;
});

typedef DesktopNotificationSender = Future<void> Function(
    String title, String body, String payload);
typedef DesktopNotificationFlash = Future<void> Function();
typedef DesktopBadgeUpdater = Future<void> Function(int count);

/// 左侧会话列表实时桥接 (docs/contracts/agent-bus-client-contract.md §P2.1b 客户端会话列表实时更新
/// + 连接凭证 TTL / kicked / reconnect gap 对账)。
///
/// 背景: 右侧人↔人 / 群聊 pane 经 WuKong 长连接实时收消息, 左侧 `conversationsProvider` 若只靠
/// `/chat/conversations` REST 快照会滞后。本桥接:
///   1. **app 级建立 WuKong 连接** —— 用户刚进应用、只停在会话列表、还没打开任何人聊/群聊时,
///      也先 ensure 连接, 左侧列表才能实时收消息 (不再依赖先打开某个 pane)。首次失败**有限退避自动重试**。
///   2. 订阅 `listenMessages()`, 把 human_direct / group 实时消息**本地物化**到 `conversationsProvider`。
///   3. **P1 连接可靠性**: 连接凭证 token 快过期前主动刷新; connect 失败疑似 token 失效时本失败轮兜底刷新一次;
///      `kicked` 停止自动重连; reconnect / syncCompleted / app resume 后 **debounce** 拉一次权威快照补 gap。
///
/// 收口边界:
///   - **只**同步左侧会话列表, **不**替代右侧 pane 的消息显示 (pane 各自仍 listenMessages 渲染气泡)。
///   - 数字员工单聊**不**走这里 (仍 `/chat/send` + `/chat/stream`; 左侧预览由 ChatNotifier 本地 patch)。
///   - REST `/chat/conversations` 仍是权威快照; refresh 后 unread 仍以 WuKong 为准, **不**用本地状态覆盖。
///   - 已知 channel 先本地 patch preview/unread，再 debounce refresh 权威快照，
///     让联系人昵称/头像/participants 等资料变更随下一条消息收敛；连续消息合并请求。
///   - 退避重试本身**不**调 refresh。
class ConversationRealtimeBridge {
  ConversationRealtimeBridge(
    this._ref, {
    ImClient? client,
    Stream<List<ConnectivityResult>>? networkChanges,
    Future<List<ConnectivityResult>> Function()? checkNetwork,
    IMCredentialsClient? credentials,
    Duration Function(int attempt)? retryDelay,
    Duration? refreshDebounce,
    Duration? connectingWatchdog,
    Duration offlineConfirmation = const Duration(seconds: 1),
    Duration? resumeRefreshMinInterval,
    DesktopNotificationSender? notifyDesktop,
    DesktopNotificationFlash? flashDesktop,
    DesktopBadgeUpdater? updateDesktopBadge,
  })  : _networkChanges = networkChanges ?? const Stream.empty(),
        _checkNetwork = checkNetwork,
        _offlineConfirmation = offlineConfirmation,
        _client = client ?? WukongImClient.shared,
        _credentials = credentials ?? IMCredentialsClient(),
        _retryDelay = retryDelay ?? _defaultRetryDelay,
        _refreshDebounce = refreshDebounce ?? const Duration(milliseconds: 800),
        _connectingWatchdog = connectingWatchdog ?? const Duration(seconds: 8),
        _resumeRefreshMinInterval =
            resumeRefreshMinInterval ?? const Duration(seconds: 30),
        _notifyDesktop = notifyDesktop ??
            ((title, body, payload) => AppNotificationService.notify(
                  title: title,
                  body: body,
                  payload: payload,
                )),
        _flashDesktop = flashDesktop ?? AppNotificationService.flash,
        _updateDesktopBadge =
            updateDesktopBadge ?? AppNotificationService.setBadgeCount;

  final Stream<List<ConnectivityResult>> _networkChanges;
  final Future<List<ConnectivityResult>> Function()? _checkNetwork;
  final Duration _offlineConfirmation;
  final _connectionChanges =
      StreamController<ConversationConnectionSnapshot>.broadcast();
  ConversationConnectionState _connectionState =
      ConversationConnectionState.idle;
  ConversationNetworkState _networkState = ConversationNetworkState.unknown;
  int _networkObservation = 0;
  int _networkCheck = 0;
  Timer? _offlineTimer;
  bool _sessionEnded = false;

  ConversationConnectionSnapshot get connectionSnapshot =>
      ConversationConnectionSnapshot(_connectionState, _networkState);

  Stream<ConversationConnectionSnapshot> get connectionChanges =>
      Stream.multi((controller) {
        final sub = _connectionChanges.stream.listen(controller.add);
        controller.add(connectionSnapshot);
        controller.onCancel = sub.cancel;
      });

  void _publishConnectionState([ConversationConnectionState? state]) {
    if (_disposed) return;
    if (state != null) _connectionState = state;
    debugPrint('[RealtimeBridge] connection=${_connectionState.name} '
        'network=${_networkState.name} banner=${connectionSnapshot.isOffline}');
    _connectionChanges.add(connectionSnapshot);
  }

  StreamSubscription<List<ConnectivityResult>>? _networkSub;
  String? _lastNetworkTypes;
  bool _networkRecoveryPending = false;
  bool _backgrounded = false;
  bool _awaitingResumeObservation = false;
  final Ref _ref;
  final ImClient _client;
  final IMCredentialsClient _credentials;

  /// 第 N 次失败 (0-based) 后的重试间隔。默认 capped backoff (2s/5s/10s/后续 30s)。测试可注入更短间隔。
  final Duration Function(int attempt) _retryDelay;

  /// reconnect/syncCompleted/app resume 后 refresh 会话快照的 debounce 间隔。测试可注入极短值。
  final Duration _refreshDebounce;

  /// SDK 进入 connecting 后若长期没有 success/fail/kicked, 主动断开并重建连接。
  /// 这是对 WuKong SDK 卡在 connecting 的保护,避免聊天区一直显示「正在重连…」。
  final Duration _connectingWatchdog;

  /// 短时间内桌面 App 可能因截图/剪切板/窗口焦点切换反复 inactive→resumed。
  /// 这些不代表真正离线 gap,无需每次都刷新左侧会话列表。
  final Duration _resumeRefreshMinInterval;
  final DesktopNotificationSender _notifyDesktop;
  final DesktopNotificationFlash _flashDesktop;
  final DesktopBadgeUpdater _updateDesktopBadge;

  StreamSubscription<ImMessage>? _sub;
  StreamSubscription<ImConnectionStatus>? _connectionSub;
  StreamSubscription<ImConversationEvent>? _convEventSub;
  StreamSubscription<Map<String, dynamic>>? _accountEventSub;
  StreamSubscription<ImReadReceiptSignal>? _readReceiptSignalSub;
  Timer? _retryTimer;
  Timer? _accountEventRetryTimer;
  Timer? _convRefreshTimer;
  final Map<String, Timer> _accountHistoryTimers = {};
  Timer? _connectingWatchdogTimer;
  bool _connecting = false; // 同一时刻只允许一个 connect attempt
  bool _disposed = false;
  bool _started = false; // start() 幂等: 只订阅一次 / 只启动一条连接链
  bool _kicked = false; // 被踢下线: 停止自动重连
  bool _credsRefreshAttempted = false; // 本失败轮是否已兜底刷新过一次凭证 (避免无限快刷)
  bool _lastConnectAttemptFailed =
      false; // 上一次 connect 尝试是否失败 (区分服务端正常掉线 vs 连接失败)
  ImConnectionStatus? _lastConnectionStatus;
  bool _didScheduleConnectedGapRefresh = false;
  DateTime? _lastResumeRefreshAt;
  int _retryAttempt = 0; // 已失败次数, 决定下次退避间隔
  int _accountEventRetryAttempt = 0; // 账号级 SSE 失败次数, 决定下次退避间隔
  ImConnInfo? _lastConnInfo; // 最近一次连接凭证 (判 token 是否快过期)
  Future<void>? _firstAttempt; // 首次 attempt future (测试 hook; 成功或失败都 resolve)
  String? _selfAccountUuid;
  bool _didScanUnreadMentions = false;

  /// 首次连接 attempt 的 future (start 后非空)。测试可 await 以确定性等待第一轮 ensure 完成。
  Future<void>? get connected => _firstAttempt;

  /// 当前是否有待触发的重试 timer (测试 hook)。
  bool get hasPendingRetry => _retryTimer != null;

  /// 当前是否有待触发的会话快照 refresh (测试 hook)。
  bool get hasPendingConvRefresh => _convRefreshTimer != null;

  /// 是否已被踢下线 (kicked): UI/日志可据此提示重新登录; 桥接已停止自动重连。
  bool get isKicked => _kicked;

  static Duration _defaultRetryDelay(int attempt) {
    switch (attempt) {
      case 0:
        return const Duration(seconds: 2);
      case 1:
        return const Duration(seconds: 5);
      case 2:
        return const Duration(seconds: 10);
      default:
        return const Duration(seconds: 30); // capped, 持续重试
    }
  }

  /// 启动: 订阅消息流 (幂等, 只订阅一次) + app 级 ensure WuKong 连接 (失败自动退避重试)。
  void start() {
    if (_started) return;
    _started = true;
    _networkSub =
        _networkChanges.listen(_onNetworkChanged, onError: (Object error) {
      debugPrint('[RealtimeBridge] network monitor failed: $error');
    });
    _lastConnectionStatus = _client.connectionStatus;
    _publishConnectionState(_client.isRealtimeConnected
        ? ConversationConnectionState.connected
        : ConversationConnectionState.connecting);
    unawaited(_refreshNetworkState());
    unawaited(WukongSessionIdentity.current().then((identity) {
      if (_disposed) return;
      _selfAccountUuid = identity?.accountUuid;
    }));
    // 点击通知跳转到对应会话——桌面/移动共用: 桌面走系统通知, 移动端走
    // AppNotificationService._notifyMobileBanner 应用内横幅, 两边点击都要能
    // 跳转(2026-08-26 反馈: 移动端点击横幅没反应, 根因是这里只在桌面端注册了
    // 回调, 移动端 onNotificationTapped 一直是 null)。
    AppNotificationService.onNotificationTapped = _onNotificationTapped;
    _sub = _client.listenMessages().listen(_onMessage);
    _connectionSub =
        _client.listenConnectionStatus().listen(_onConnectionStatus);
    // P1: 会话级事件(删除/清红点等非每条消息变化)只触发 debounce refresh 权威快照。
    _convEventSub =
        _client.listenConversationEvents().listen(_onConversationEvent);
    _startAccountEventStream();
    final receiptClient = _client;
    if (receiptClient is ImReadReceiptSignalClient) {
      _readReceiptSignalSub = (receiptClient as ImReadReceiptSignalClient)
          .listenReadReceiptSignals()
          .listen(_onReadReceiptSignal);
    }
    _firstAttempt = _tryConnect();
  }

  void _onNetworkChanged(List<ConnectivityResult> results) {
    if (_disposed || _kicked || _sessionEnded) return;
    _networkObservation++;
    if (results.isEmpty) {
      return; // No observation is not proof of being offline.
    }
    final types = results.map((e) => e.name).toSet().toList()..sort();
    final signature = types.join(',');
    final hadNetworkObservation = _lastNetworkTypes != null;
    if (_lastNetworkTypes == signature &&
        _networkState != ConversationNetworkState.confirmingOffline) {
      return;
    }
    _lastNetworkTypes = signature;
    if (!results.any((e) => e != ConnectivityResult.none)) {
      if (_networkState == ConversationNetworkState.offline) return;
      _networkState = ConversationNetworkState.confirmingOffline;
      _publishConnectionState();
      if (_backgrounded || _offlineTimer != null) return;
      _offlineTimer = Timer(_offlineConfirmation, () {
        _offlineTimer = null;
        if (_disposed || _sessionEnded || _backgrounded) return;
        _networkState = ConversationNetworkState.offline;
        _publishConnectionState();
      });
      return;
    }
    final recoveringNetwork =
        _networkState == ConversationNetworkState.offline ||
            _networkState == ConversationNetworkState.confirmingOffline;
    _offlineTimer?.cancel();
    _offlineTimer = null;
    _networkState = ConversationNetworkState.available;
    _publishConnectionState();
    if (!hadNetworkObservation) return;
    // Bus list availability is independent of IM credentials/reconnect backoff.
    unawaited(_refreshConversations(showLoading: recoveringNetwork));
    if (_client.isRealtimeConnected) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    debugPrint('[RealtimeBridge] network available: reconnect without backoff');
    if (_connecting) {
      _networkRecoveryPending = true;
      return;
    }
    unawaited(_tryConnect());
  }

  Future<void> _refreshNetworkState() async {
    final check = _checkNetwork;
    if (check == null || _disposed || _sessionEnded || _kicked) return;
    final observation = _networkObservation;
    final attempt = ++_networkCheck;
    try {
      final results = await check();
      if (_disposed ||
          _sessionEnded ||
          _kicked ||
          _backgrounded ||
          observation != _networkObservation ||
          attempt != _networkCheck) {
        return;
      }
      _onNetworkChanged(results);
    } catch (error) {
      if (!_disposed) {
        debugPrint(
            '[RealtimeBridge] network check failed: ${error.runtimeType}');
      }
    }
  }

  bool get _connectionAttemptObsolete =>
      _disposed ||
      _sessionEnded ||
      _kicked ||
      _client.connectionStatus == ImConnectionStatus.kicked ||
      _client.isRealtimeConnected;

  /// 单次连接尝试。connectedUid 只代表已 setup/login, 真实连接以 connectionStatus 为准。
  ///   - kicked → 不连接 (停止自动重连)。
  ///   - 已 connected → 停止重试。
  ///   - 取凭证条件: 无 uid (首登) | token 快过期 (主动刷新) | 上一轮失败后的一次性兜底 (被动, 疑似 token 失效)。
  ///   - 失败/未连通 → 退避重试。
  Future<void> _tryConnect() async {
    if (_disposed || _sessionEnded || _kicked) return;
    if (_client.connectionStatus == ImConnectionStatus.kicked) {
      _onKicked();
      return;
    }
    if (_client.isRealtimeConnected) {
      _onConnectSuccess(refreshGap: !_didScheduleConnectedGapRefresh);
      return;
    }
    if (_client.connectionStatus.isConnecting) {
      _armConnectingWatchdog();
      return;
    }
    if (_connecting) return; // 防止并发 attempt
    _connecting = true;
    _publishConnectionState(_didScheduleConnectedGapRefresh
        ? ConversationConnectionState.recovering
        : ConversationConnectionState.connecting);
    try {
      final existing = _client.connectedUid;
      final noUid = existing == null || existing.isEmpty;
      final expiring = _tokenExpiringSoon();
      // 被动兜底: 已有 uid、token 未明显快过期, 但上一次 connect **尝试失败**(非服务端正常掉线)
      // → 疑似 token 失效, 本失败轮刷新一次凭证再试。普通断线重连不刷新(token 仍有效)。
      final reactive = !noUid &&
          !expiring &&
          !_credsRefreshAttempted &&
          _lastConnectAttemptFailed;
      final needCreds = noUid || expiring || reactive;
      if (needCreds) {
        if (reactive) _credsRefreshAttempted = true;
        final info = await _credentials.fetchWukongConnInfo();
        if (_connectionAttemptObsolete) return;
        await _client.init();
        if (_connectionAttemptObsolete) return;
        _lastConnInfo = info;
        // 同 uid 新 token 时 WukongImClient 会重新 setup, 使新 token 生效。
        await _client.login(info);
        if (_connectionAttemptObsolete) return;
      }
      await _client.connect();
      if (_disposed || _sessionEnded || _kicked) return;
      if (_client.isRealtimeConnected) {
        _onConnectSuccess(
          refreshGap: _lastConnectionStatus?.isConnected != true,
        );
      } else {
        if (_client.connectionStatus.isConnecting) {
          // SDK 已接受本次连接尝试。此时只保留 watchdog，不能同时安排普通
          // backoff；否则 timer 到点会成为第二条连接种子。
          _armConnectingWatchdog();
        } else {
          _lastConnectAttemptFailed = true;
          _publishConnectionState(ConversationConnectionState.unavailable);
          _scheduleRetry();
        }
      }
    } catch (error) {
      if (_connectionAttemptObsolete) return;
      final failure = ConversationConnectionState.fromError(error);
      _publishConnectionState(failure);
      debugPrint('[RealtimeBridge] connection attempt failed: '
          '${error.runtimeType} state=${failure.name}');
      _lastConnectAttemptFailed = true;
      _scheduleRetry();
    } finally {
      _connecting = false;
      if (_networkRecoveryPending && !_disposed && !_kicked && !_sessionEnded) {
        _networkRecoveryPending = false;
        _retryTimer?.cancel();
        _retryTimer = null;
        if (!_client.isRealtimeConnected) unawaited(_tryConnect());
      }
    }
  }

  void _onConnectionStatus(ImConnectionStatus status) {
    if (_disposed || _sessionEnded || _kicked) return;
    final wasConnected = _lastConnectionStatus?.isConnected == true;
    final resumeObservation = _awaitingResumeObservation;
    _awaitingResumeObservation = false;
    _lastConnectionStatus = status;
    if (status == ImConnectionStatus.kicked) {
      _onKicked();
      return;
    }
    if (status.isConnected) {
      _onConnectSuccess(
        refreshGap: !wasConnected || !_didScheduleConnectedGapRefresh,
      );
      return;
    }
    if (status == ImConnectionStatus.idle) {
      _sessionEnded = true;
      _retryTimer?.cancel();
      _retryTimer = null;
      _offlineTimer?.cancel();
      _offlineTimer = null;
      _networkState = ConversationNetworkState.unknown;
      _cancelConnectingWatchdog();
      _publishConnectionState(ConversationConnectionState.idle);
      return;
    }
    if (status.isConnecting) {
      _publishConnectionState(_didScheduleConnectedGapRefresh
          ? ConversationConnectionState.recovering
          : ConversationConnectionState.connecting);
      _armConnectingWatchdog();
      return;
    } else {
      _publishConnectionState(_backgrounded
          ? ConversationConnectionState.recovering
          : ConversationConnectionState.unavailable);
      _cancelConnectingWatchdog();
    }
    if (!_backgrounded && resumeObservation && !_connecting) {
      _retryTimer?.cancel();
      _retryTimer = null;
      unawaited(_tryConnect());
      return;
    }
    // 普通掉线 (disconnected/noNetwork): 退避重连。kicked 已在上面 return, 不会到这。
    if (_started && !_connecting && !_kicked) {
      _scheduleRetry();
    }
  }

  /// 被踢下线: 与普通断线不同 —— 停止自动重连, 暴露 isKicked。重新上线需用户重新登录 (out of scope)。
  void _onKicked() {
    _backgrounded = false;
    _offlineTimer?.cancel();
    _offlineTimer = null;
    _networkState = ConversationNetworkState.unknown;
    _publishConnectionState(ConversationConnectionState.kicked);
    _kicked = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelConnectingWatchdog();
    debugPrint('[RealtimeBridge] WuKong kicked: 账号已在其他设备登录, 停止自动重连 (需重新登录)');
  }

  void _onConnectSuccess({required bool refreshGap}) {
    _publishConnectionState(ConversationConnectionState.connected);
    _retryAttempt = 0;
    _credsRefreshAttempted = false;
    _lastConnectAttemptFailed = false;
    _kicked = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelConnectingWatchdog();
    if (!refreshGap) return;
    _didScheduleConnectedGapRefresh = true;
    // 非 connected → connected (含 syncCompleted): debounce 拉权威快照补 gap (离线期堆积的消息/已读)。
    _scheduleConversationsRefresh();
  }

  void _armConnectingWatchdog() {
    if (_disposed || _kicked || _sessionEnded) return;
    if (_connectingWatchdogTimer != null) return;
    _connectingWatchdogTimer = Timer(_connectingWatchdog, () {
      _connectingWatchdogTimer = null;
      // ignore: discarded_futures
      _recoverStuckConnecting();
    });
  }

  void _cancelConnectingWatchdog() {
    _connectingWatchdogTimer?.cancel();
    _connectingWatchdogTimer = null;
  }

  Future<void> _recoverStuckConnecting() async {
    if (_disposed || _kicked || _sessionEnded) return;
    if (!_client.connectionStatus.isConnecting) return;
    if (_connecting) {
      _armConnectingWatchdog();
      return;
    }
    debugPrint(
        '[RealtimeBridge] WuKong connecting watchdog fired: reset attempt and schedule capped backoff');
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastConnectAttemptFailed = true;
    final shouldInvalidateCredentials = !_credsRefreshAttempted;
    // disconnect 会同步广播 disconnected；用 _connecting 抑制该回调另起一条
    // retry timer，最终只由本方法安排一次 capped backoff。
    _connecting = true;
    try {
      await _client.disconnect();
      if (_disposed || _kicked || _sessionEnded) return;
      if (shouldInvalidateCredentials) {
        await _credentials.invalidateCache();
      }
    } catch (e) {
      debugPrint(
          '[RealtimeBridge] WuKong connecting watchdog reset failed (ignored): $e');
    } finally {
      _connecting = false;
    }
    if (_disposed || _kicked || _sessionEnded) return;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _kicked || _sessionEnded) return;
    if (_retryTimer != null) return; // 已有 pending retry, 不重复创建
    final delay = _retryDelay(_retryAttempt);
    _retryAttempt++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      // ignore: discarded_futures
      _tryConnect();
    });
  }

  void _startAccountEventStream() {
    if (_disposed || _accountEventSub != null) return;
    _accountEventSub =
        _ref.read(chatServiceProvider).streamAccountEvents().listen(
      (event) {
        _accountEventRetryAttempt = 0;
        // ignore: discarded_futures
        _onAccountEvent(event);
      },
      onError: (Object e) {
        debugPrint('[RealtimeBridge] account SSE failed, retry scheduled: $e');
        // ignore: discarded_futures
        _accountEventSub?.cancel();
        _accountEventSub = null;
        _scheduleAccountEventRetry();
      },
      onDone: () {
        if (_disposed) return;
        debugPrint('[RealtimeBridge] account SSE closed, retry scheduled');
        _accountEventSub = null;
        _scheduleAccountEventRetry();
      },
    );
  }

  void _scheduleAccountEventRetry() {
    if (_disposed || _accountEventSub != null) return;
    if (_accountEventRetryTimer != null) return;
    final delay = _retryDelay(_accountEventRetryAttempt);
    _accountEventRetryAttempt++;
    _accountEventRetryTimer = Timer(delay, () {
      _accountEventRetryTimer = null;
      _startAccountEventStream();
    });
  }

  bool _tokenExpiringSoon() {
    final info = _lastConnInfo ?? _credentials.cachedCredentials?.wukong;
    return info?.isExpiringSoon ?? false;
  }

  void onAppBackgrounded() {
    if (_disposed || _backgrounded || _kicked || _sessionEnded) return;
    _backgrounded = true;
    _networkCheck++;
    _offlineTimer?.cancel();
    _offlineTimer = null;
  }

  /// app 从后台恢复: ensure 连接 (非 kicked) + debounce 拉权威快照补 gap。由 MainLayout 生命周期回调。
  void onAppResumed() {
    if (_disposed || _kicked || _sessionEnded) return;
    if (_backgrounded) {
      _backgrounded = false;
      _awaitingResumeObservation = _client.isRealtimeConnected;
      _cancelConnectingWatchdog();
      if (_client.connectionStatus.isConnecting) _armConnectingWatchdog();
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    unawaited(_refreshNetworkState());
    // 回前台按会话补查服务端历史，包括仍显示运行中的消息；只有同一
    // message 的权威终态才能收口订阅，不因旧 UI 标记跳过停止状态同步。
    _reconcileLoadedAgentConversations();
    final realtimeConnected = _client.isRealtimeConnected;
    if (!realtimeConnected && !_connecting) {
      // ignore: discarded_futures
      _tryConnect();
    }
    if (realtimeConnected && !_shouldRefreshForResume()) return;
    _scheduleConversationsRefresh();
  }

  bool _shouldRefreshForResume() {
    final now = DateTime.now();
    final last = _lastResumeRefreshAt;
    if (last != null && now.difference(last) < _resumeRefreshMinInterval) {
      return false;
    }
    _lastResumeRefreshAt = now;
    return true;
  }

  /// debounce 刷新 `/chat/conversations` 权威快照。多次触发 (success+syncCompleted) 合并为一次。
  void _scheduleConversationsRefresh() {
    if (_disposed) return;
    _convRefreshTimer?.cancel();
    _convRefreshTimer = Timer(_refreshDebounce, () {
      _convRefreshTimer = null;
      if (_disposed) return;
      // ignore: discarded_futures
      _refreshConversations();
    });
  }

  Future<void> _refreshConversations({bool showLoading = false}) async {
    try {
      // refresh 以 WuKong unread 快照为准 (服务端权威); 不用本地状态覆盖。
      await _ref
          .read(conversationsProvider.notifier)
          .refresh(showLoading: showLoading);
      unawaited(_scanUnreadMentionsOnce());
    } catch (e) {
      // 吞掉并记录, 不阻塞聊天 (gap refresh 失败下次重连/resume 再补)。
      debugPrint('[RealtimeBridge] conversations refresh failed (ignored): $e');
    }
  }

  Future<void> _scanUnreadMentionsOnce() async {
    if (_didScanUnreadMentions || _disposed) return;
    final selfAccountUuid = _selfAccountUuid;
    if (selfAccountUuid == null) return;
    _didScanUnreadMentions = true;
    final items = _ref.read(conversationsProvider).asData?.value;
    if (items == null) return;
    final targets = items
        .where((c) =>
            c.isGroup &&
            c.unreadCount > 0 &&
            (c.wukongChannelId ?? '').isNotEmpty)
        .take(30);
    for (final c in targets) {
      if (_disposed) return;
      try {
        final msgs = await _client.getHistoryMessages(
          c.wukongChannelId!,
          c.wukongChannelType ?? 2,
          limit: c.unreadCount.clamp(1, 30),
          conversationUuid: c.conversationId,
        );
        if (_disposed) return;
        if (msgs.any((m) => messageMentionsMe(m.mentions, selfAccountUuid))) {
          final mentioned = _ref.read(mentionedConversationIdsProvider);
          if (!mentioned.contains(c.conversationId)) {
            _ref.read(mentionedConversationIdsProvider.notifier).state = {
              ...mentioned,
              c.conversationId,
            };
          }
        }
      } catch (_) {}
    }
  }

  /// 会话级事件(P1):删除会话 / 清空红点等无法从 message stream 推导的变化。
  /// **只**触发 debounce refresh `/chat/conversations` 权威快照,**不**直接改 preview/unread,
  /// **不**信任 SDK 本地 unread/redDot 值;多事件经 debounce 合并为一次 refresh。
  void _onConversationEvent(ImConversationEvent e) {
    if (_disposed) return;
    debugPrint(
        '[RealtimeBridge] conversation event ${e.kind} (channel=${e.channelId}) → debounce refresh');
    _scheduleConversationsRefresh();
  }

  void _onReadReceiptSignal(ImReadReceiptSignal event) {
    if (_disposed) return;
    if (event.conversationUuid.isEmpty || event.lastReadMessageSeq <= 0) {
      return;
    }
    _ref.read(chatReadReceiptEventBusProvider).emit(
          ChatReadReceiptChangedEvent(
            conversationUuid: event.conversationUuid,
            lastReadMessageSeq: event.lastReadMessageSeq,
          ),
        );
  }

  Future<void> _onAccountEvent(Map<String, dynamic> event) async {
    if (_disposed) return;
    final kind = (event['kind'] ?? '').toString();
    // The connected control frame has no kind; each connection starts without
    // a replay cursor, so reconcile snapshots even when gap is false.
    if (event.containsKey('conn_id') && event.containsKey('gap')) {
      _reconcileLoadedAgentConversations();
      _scheduleConversationsRefresh();
      return;
    }
    if (const {
          'message.created',
          'message.completed',
          'message.failed',
          'message.cancelled',
          'message.awaiting_user',
        }.contains(kind) &&
        '${event['room_uuid'] ?? ''}'.isEmpty) {
      final conversation = '${event['conversation_uuid'] ?? ''}'.trim();
      if (conversation.isNotEmpty) _scheduleAccountHistory(conversation);
      _scheduleConversationsRefresh();
      return;
    }
    if (kind != 'external_notification.created' &&
        kind != 'notification.created') {
      return;
    }
    final data = _accountEventData(event);
    final route = data['route'] is Map
        ? Map<String, dynamic>.from(data['route'] as Map)
        : const <String, dynamic>{};
    final conversationId = (data['conversation_uuid'] ??
            route['conversation_uuid'] ??
            event['conversation_uuid'] ??
            '')
        .toString()
        .trim();
    final title = (data['title'] ?? '').toString().trim();
    final body = (data['description'] ?? data['body'] ?? '').toString().trim();
    if (title.isEmpty || body.isEmpty) return;

    try {
      await _ref.read(conversationsProvider.notifier).refresh();
    } catch (e) {
      debugPrint(
          '[RealtimeBridge] external notification conversation refresh failed (ignored): $e');
    }
    if (_disposed) return;
    // chat_message / cron_result 的通用通知已由 WuKong 消息处理；桌面端
    // call_invite 则由 RTC type=1001 驱动专用来电浮窗和铃声，不叠加普通
    // 系统通知或任务栏闪烁。移动端 call_invite 仍使用现有提醒路径。
    // external_notification.created 没有 WuKong 直推兜底，继续保留。
    final notificationKind = (data['notification_kind'] ?? '').toString();
    if (kind == 'notification.created' &&
        (notificationKind != 'call_invite' || PlatformUtils.isDesktop)) {
      _updateBadge();
      return;
    }
    final isCurrent = conversationId.isNotEmpty &&
        _currentConversationIds().contains(conversationId);
    if (!isCurrent) {
      await _notifyDesktop(title, body, conversationId);
      await _flashDesktop();
    }
    _updateBadge();
  }

  void _scheduleAccountHistory(String conversation) {
    _accountHistoryTimers.remove(conversation)?.cancel();
    _accountHistoryTimers[conversation] =
        Timer(const Duration(milliseconds: 150), () {
      _accountHistoryTimers.remove(conversation);
      if (_disposed) return;
      unawaited(_ref
          .read(chatProvider.notifier)
          .reconcileAccountConversation(conversation));
    });
  }

  void _reconcileLoadedAgentConversations() {
    final workspace = _ref.read(chatProvider).asData?.value;
    if (workspace == null) return;
    for (final key in workspace.sessions.keys) {
      _scheduleAccountHistory(key);
    }
  }

  Map<String, dynamic> _accountEventData(Map<String, dynamic> event) {
    final blocks = event['blocks'];
    if (blocks is List && blocks.isNotEmpty) {
      final first = blocks.first;
      if (first is Map) {
        final data = first['data'];
        if (data is Map) {
          return data.map((key, value) => MapEntry(key.toString(), value));
        }
      }
    }
    return event;
  }

  void _onMessage(ImMessage m) {
    if (m.channelId.isEmpty) return;
    if (m.isRefresh) return;
    final selfUid = _client.connectedUid;
    final fromSelf =
        selfUid != null && selfUid.isNotEmpty && m.fromUid == selfUid;

    final beforePatch = _ref.read(conversationsProvider).asData?.value;
    ConversationItem? matchedConversation;
    if (beforePatch != null) {
      for (final conversation in beforePatch) {
        if (conversation.wukongChannelId == m.channelId &&
            conversation.wukongChannelType == m.channelType) {
          matchedConversation = conversation;
          break;
        }
      }
    }

    final currentIds = _currentConversationIds();

    final matched =
        _ref.read(conversationsProvider.notifier).applyRealtimeMessage(
              channelId: m.channelId,
              channelType: m.channelType,
              previewText: m.text,
              fromSelf: fromSelf,
              currentConversationIds: currentIds,
              messageTimestamp: m.timestamp,
              dedupId: m.messageId.isNotEmpty ? m.messageId : m.clientMsgNo,
            );
    if (!matched) {
      debugPrint(
          '[RealtimeBridge] message for unknown conversation channel=${m.channelId}/${m.channelType} → debounce refresh');
    }
    // human/group 的本地 realtime patch 只更新 preview/time/unread，不能证明
    // title/avatar/participants 仍是最新。即使 channel 已命中也要 debounce
    // 拉 Bus 权威快照，否则对端修改昵称后既有会话会永久保留旧标题。
    // 数字员工单聊资料有独立 enrich 链路，不在这里扩大刷新范围。
    if (!matched ||
        matchedConversation?.isHumanDirect == true ||
        matchedConversation?.isGroup == true) {
      _scheduleConversationsRefresh();
    }

    if (!fromSelf && !m.isRevokeNotify) {
      _handleNotification(m, currentIds);
    }

    final selfAccountUuid = _selfAccountUuid;
    if (!fromSelf &&
        matchedConversation != null &&
        selfAccountUuid != null &&
        !currentIds.contains(matchedConversation.conversationId) &&
        messageMentionsMe(m.mentions, selfAccountUuid)) {
      final mentioned = _ref.read(mentionedConversationIdsProvider);
      if (!mentioned.contains(matchedConversation.conversationId)) {
        _ref.read(mentionedConversationIdsProvider.notifier).state = {
          ...mentioned,
          matchedConversation.conversationId,
        };
      }
    }
  }

  /// 当前正在查看的会话 id(群聊 / 人聊 / 数字员工单聊三选一,按此优先级)。
  /// 用于抑制"正在看这个会话"时还弹一次桌面通知。
  Set<String> _currentConversationIds() {
    // 对话 tab 不是当前可见路由时，不管 chatProvider/selected*Provider 里还
    // 残留着上次选中的是哪个会话，都不能算"正在看"——否则切到其它 tab 后台
    // 收到消息，会因为命中了"上次打开过的会话"而被误判成"正在看"，从而既不
    // 弹系统通知也不闪 dock/任务栏图标（跟 markConversationRead 同一类问题，
    // 2026-08-25 实测：停在自动任务页收不到系统通知，就是这里判成了 isCurrent）。
    if (!_ref.read(isChatRouteActiveProvider)) return const <String>{};
    final currentIds = <String>{};
    final g = _ref.read(selectedGroupProvider)?.conversationId;
    if (g != null && g.isNotEmpty) currentIds.add(g);
    final h = _ref.read(selectedHumanDirectProvider)?.conversationId;
    if (h != null && h.isNotEmpty) currentIds.add(h);
    if (currentIds.isEmpty) {
      final activeAgentConversation =
          _ref.read(chatProvider).asData?.value.activeConversationId;
      if (activeAgentConversation != null &&
          activeAgentConversation.isNotEmpty) {
        currentIds.add(activeAgentConversation);
      }
    }
    return currentIds;
  }

  void _handleNotification(ImMessage m, Set<String> currentConversationIds) {
    final conversations = _ref.read(conversationsProvider).asData?.value;
    if (conversations == null) return;
    final conv = conversations
        .where((c) =>
            c.wukongChannelId == m.channelId &&
            c.wukongChannelType == m.channelType)
        .firstOrNull;
    if (conv == null) return;
    if (conv.muted) return;

    final isCurrent = currentConversationIds.contains(conv.conversationId);

    if (!isCurrent) {
      final title = m.notificationTitle.isNotEmpty
          ? m.notificationTitle
          : (conv.title.isNotEmpty ? conv.title : '知办AI');
      final body = m.notificationBody.isNotEmpty
          ? m.notificationBody
          : (m.text.isNotEmpty ? m.text : '[消息]');
      _notifyDesktop(title, body, conv.conversationId);
      _flashDesktop();
    } else {
      // 正在看这个会话时收到新消息：applyRealtimeMessage 只把本地 unreadCount
      // 乐观清成 0，服务端并不知道这条新消息已经被看到——line 597 附近
      // human/group 命中后会 debounce refresh 权威快照，届时服务端仍报未读，
      // 会把本地清好的 0 又覆盖回去，退出会话回列表就看到"未读"了。这里跟着
      // 这条新消息重新上报一次已读水位，让服务端状态跟本地保持一致
      // (2026-08-28 反馈)。
      _markCurrentConversationRead(conv, m);
    }

    _updateBadge();
  }

  void _markCurrentConversationRead(ConversationItem conv, ImMessage m) {
    markConversationReadEverywhere(
      ref: _ref,
      wukongClient: _client,
      conversationId: conv.conversationId,
      channelId: conv.wukongChannelId,
      channelType: conv.wukongChannelType ?? m.channelType,
    );
  }

  void _updateBadge() {
    final conversations = _ref.read(conversationsProvider).asData?.value;
    if (conversations == null) return;
    int total = 0;
    for (final c in conversations) {
      if (!c.muted) total += c.unreadCount;
    }
    _updateDesktopBadge(total);
  }

  void _onNotificationTapped(String conversationId) {
    if (_disposed || conversationId.isEmpty) return;
    unawaited(_openNotificationConversation(conversationId));
  }

  Future<void> _openNotificationConversation(String conversationId) async {
    if (_disposed || conversationId.isEmpty) return;
    await _waitUntilAfterWidgetBuild();
    if (_disposed) return;
    final context = rootNavigatorKey.currentContext;
    // 桌面端 /chat 本身就是常驻分栏, go 过去后配合下面的 openConversationByProvider
    // 就能切到对应会话。移动端 /chat 只是列表页——之前一直 go 到这里就没下文了,
    // 用户点横幅完全没跳转(2026-08-26 反馈); 移动端要另外 push 到会话详情路由
    // /chat/conversation 才能真正打开。
    if (context != null && context.mounted && PlatformUtils.isDesktop) {
      final router = GoRouter.maybeOf(context);
      router?.go(RoutePaths.chat);
      await Future<void>.delayed(Duration.zero);
    }
    await _ref.read(conversationsProvider.notifier).refresh();
    if (_disposed) return;
    final conversations =
        _ref.read(conversationsProvider).asData?.value ?? const [];
    final conv = conversations
        .where((c) => c.conversationId == conversationId)
        .firstOrNull;
    if (conv == null) return;
    await _waitUntilAfterWidgetBuild();
    if (_disposed) return;
    openConversationByProvider(_ref, conv);
    _updateBadge();
    if (PlatformUtils.isMobile) {
      final mobileContext = rootNavigatorKey.currentContext;
      if (mobileContext != null && mobileContext.mounted) {
        final router = GoRouter.maybeOf(mobileContext);
        // rootNavigatorKey.currentContext 不一定落在某个 GoRoute.builder 子树
        // 下面(点击横幅时可能在别的 Overlay/context 上), GoRouterState.of(context)
        // 要求必须在子树内, 拿不到会直接抛异常。改用 router.state 读当前路由,
        // 这是 GoRouter 实例自身的状态, 不依赖 context 位置。
        final location = router?.state.matchedLocation;
        if (location != null && location != RoutePaths.chatConversation) {
          router?.push(RoutePaths.chatConversation);
        }
      }
    }
  }

  Future<void> _waitUntilAfterWidgetBuild() async {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  void dispose() {
    _disposed = true;
    _offlineTimer?.cancel();
    _offlineTimer = null;
    unawaited(_connectionChanges.close());
    _networkSub?.cancel();
    _networkSub = null;
    for (final timer in _accountHistoryTimers.values) {
      timer.cancel();
    }
    _accountHistoryTimers.clear();
    if (AppNotificationService.onNotificationTapped == _onNotificationTapped) {
      AppNotificationService.onNotificationTapped = null;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _accountEventRetryTimer?.cancel();
    _accountEventRetryTimer = null;
    _convRefreshTimer?.cancel();
    _convRefreshTimer = null;
    _cancelConnectingWatchdog();
    _sub?.cancel();
    _sub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _convEventSub?.cancel();
    _convEventSub = null;
    _accountEventSub?.cancel();
    _accountEventSub = null;
    _readReceiptSignalSub?.cancel();
    _readReceiptSignalSub = null;
  }
}

/// WuKong 客户端 / 凭证 client / 重试间隔 / refresh debounce 注入点 (生产用默认; 测试可 override)。
final wukongImClientProvider =
    Provider<ImClient>((ref) => WukongImClient.shared);
final imCredentialsClientProvider =
    Provider<IMCredentialsClient>((ref) => IMCredentialsClient());

/// 重试退避间隔覆盖 (null = 用 bridge 默认 capped backoff)。测试注入极短间隔以确定性推进。
final realtimeRetryDelayProvider =
    Provider<Duration Function(int attempt)?>((ref) => null);

/// reconnect/syncCompleted/resume 后 refresh 的 debounce 间隔覆盖 (null = 默认 800ms)。测试注入极短值。
final realtimeRefreshDebounceProvider = Provider<Duration?>((ref) => null);

/// connecting 卡住后的 watchdog 覆盖 (null = 默认 8s)。测试注入极短值。
final realtimeConnectingWatchdogProvider = Provider<Duration?>((ref) => null);

final realtimeOfflineConfirmationProvider =
    Provider<Duration>((ref) => const Duration(seconds: 1));
final conversationNetworkCheckProvider =
    Provider<Future<List<ConnectivityResult>> Function()>((ref) =>
        PlatformUtils.isMacOS || PlatformUtils.isWindows
            ? DesktopNetworkConnectivity().checkConnectivity
            : Connectivity().checkConnectivity);

final realtimeNotificationSenderProvider =
    Provider<DesktopNotificationSender>((ref) {
  return (title, body, payload) => AppNotificationService.notify(
        title: title,
        body: body,
        payload: payload
      );
});

final realtimeNotificationFlashProvider =
    Provider<DesktopNotificationFlash>((ref) => AppNotificationService.flash);

final realtimeBadgeUpdaterProvider = Provider<DesktopBadgeUpdater>(
    (ref) => AppNotificationService.setBadgeCount);

/// 进程级桥接 provider。读取一次即启动订阅 + ensure 连接; sessionScope 重建时 onDispose 取消并随新 scope 重建。
/// 在 chat shell (MainLayout) 读一次确保只订阅一次, 不在每个 pane 重复订阅。
final conversationNetworkChangesProvider =
    Provider<Stream<List<ConnectivityResult>>>(
  (ref) => PlatformUtils.isMacOS || PlatformUtils.isWindows
      ? DesktopNetworkConnectivity().onConnectivityChanged
      : Connectivity().onConnectivityChanged,
);

final conversationRealtimeBridgeProvider =
    Provider<ConversationRealtimeBridge>((ref) {
  final bridge = ConversationRealtimeBridge(
    ref,
    client: ref.read(wukongImClientProvider),
    networkChanges: ref.read(conversationNetworkChangesProvider),
    checkNetwork: ref.read(conversationNetworkCheckProvider),
    offlineConfirmation: ref.read(realtimeOfflineConfirmationProvider),
    credentials: ref.read(imCredentialsClientProvider),
    retryDelay: ref.read(realtimeRetryDelayProvider),
    refreshDebounce: ref.read(realtimeRefreshDebounceProvider),
    connectingWatchdog: ref.read(realtimeConnectingWatchdogProvider),
    notifyDesktop: ref.read(realtimeNotificationSenderProvider),
    flashDesktop: ref.read(realtimeNotificationFlashProvider),
    updateDesktopBadge: ref.read(realtimeBadgeUpdaterProvider),
  );
  ref.onDispose(bridge.dispose);
  bridge.start();
  return bridge;
});
