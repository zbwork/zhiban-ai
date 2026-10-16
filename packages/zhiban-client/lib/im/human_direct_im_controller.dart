import 'dart:async';
import 'dart:convert';

import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/foundation.dart';
import 'package:zhiban_client/im/chat_media_api.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/services/message_files_api.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 普通员工 1v1 控制器(WuKong substrate,ADR-0026)。
///
/// UI 只依赖 [ImMessage]/[ImClient],不直接 import wukongimfluttersdk。
class HumanDirectImController extends ChangeNotifier {
  HumanDirectImController({
    this.peerAccountUuid,
    this.presetChannelId,
    this.presetChannelType,
    this.presetConversationUuid,
    this.presetClearedAt,
    ImClient? client,
    IMCredentialsClient? credentials,
    RoomsService? roomsService,
    ChatMediaApi? chatMedia,
    MessageFilesService? filesService,
  })  : _clearedAtRaw = presetClearedAt,
        _clearedAt = _parseClearedAt(presetClearedAt),
        client = client ?? WukongImClient.shared,
        _credentials = credentials ?? IMCredentialsClient(),
        roomsService = roomsService ?? RoomsService(),
        _chatMedia = chatMedia ?? ChatMediaApi(),
        _filesSvc = filesService ?? MessageFilesService(),
        assert(peerAccountUuid != null || presetChannelId != null,
            'need peerAccountUuid (create) or presetChannelId (open existing)') {
    _identity = ChatCacheScope.resolved;
    _myUid = this.client.connectedUid;
    _channelId = presetChannelId;
    _channelType = presetChannelType ?? 2;
    _conversationUuid = presetConversationUuid;
    final cached = _warmWindows[_windowKey];
    if (!isConnectionKicked && cached != null) {
      _resetMessages(cached);
      debugPrint('[chat-first-frame] IM memory hit messages=${cached.length}');
    }
  }

  ChatCacheScope? _identity;
  bool _historyLoaded = false;
  bool _opening = false;
  bool _cacheDenied = false;
  static final Map<String, List<ImMessage>> _warmWindows = {};
  static void clearMemoryCache() => _warmWindows.clear();
  String? get _windowKey {
    final scope = _identity;
    if (scope == null || _channelId == null || _myUid == null) return null;
    return jsonEncode([
      scope.key,
      scope.generation,
      identityHashCode(client),
      _myUid,
      _channelId,
      _channelType,
      _conversationUuid,
      _clearedAtRaw
    ]);
  }

  bool get historyAccessDenied => _cacheDenied;

  void discardWarmHistory() {
    _cacheDenied = true;
    _warmWindows.remove(_windowKey);
  }

  void _rememberWindow() {
    final key = _windowKey;
    if (key == null ||
        !_historyLoaded ||
        _cacheDenied ||
        isConnectionKicked ||
        (ChatCacheScope.resolved?.key != _identity?.key ||
            ChatCacheScope.resolved?.generation != _identity?.generation)) {
      return;
    }
    final saved = messages.where((m) => !m.isPending).toList();
    _warmWindows.remove(key);
    _warmWindows[key] =
        saved.skip(saved.length > 40 ? saved.length - 40 : 0).toList();
    while (_warmWindows.length > 200) {
      _warmWindows.remove(_warmWindows.keys.first);
    }
  }

  /// 通讯录新开:用 peer uuid 走 /direct-rooms 建/取房。
  final String? peerAccountUuid;

  /// 会话列表点开:已知 wukong channel,直接打开,**不重调 /direct-rooms**(P2.1 点 10)。
  final String? presetChannelId;
  final int? presetChannelType;

  /// 会话 uuid(列表点开时已知;通讯录新开时由 createDirectRoom 返回)。
  /// 发文件消息时建 chat media ref 必须带它。
  final String? presetConversationUuid;
  final String? presetClearedAt;

  final ImClient client;
  final IMCredentialsClient _credentials;
  final RoomsService roomsService;
  final ChatMediaApi _chatMedia;

  String? _myUid;
  String? get myUid => _myUid;

  String? _channelId;
  int _channelType = 1;
  String? _conversationUuid;
  String? _roomUuid;
  String? _clearedAtRaw;
  DateTime? _clearedAt;

  String? get channelId => _channelId;
  int get channelType => _channelType;
  String? get conversationUuid => _conversationUuid;
  String? get roomUuid => _roomUuid;

  /// 消息表(WuKong 为权威的物化视图)。用 [_upsert] 统一去重 + 按 messageSeq 排序;
  /// 本端仍有未 ack 消息时按本地到达序保持用户发送顺序,避免后发且先 ack 的云盘/文件插队。
  /// 历史/实时/自回显/失败预留态都过同一个 [_upsert]。
  final List<_ImMsgEntry> _entries = <_ImMsgEntry>[];
  final Set<String> _locallyDeletedMessageKeys = <String>{};
  int _arrivalCounter = 0;
  List<ImMessage> get messages =>
      List.unmodifiable(_entries.map((e) => e.message));

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  /// 历史分页(P1):是否正在加载更早历史 / 是否可能还有更早历史。
  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;
  bool get hasPendingUploads => _uploads.isNotEmpty;
  bool _hasMoreHistory = true;
  bool get hasMoreHistory => _hasMoreHistory;

  /// 连接是否已被踢下线(P3):pane 据此展示「重新登录」提示条;读 client 实时状态。
  /// 订阅连接状态在 kicked 翻转时 notifyListeners(让 pane 重建);不落本地存储、不引入全局状态。
  bool get isConnectionKicked =>
      client.connectionStatus == ImConnectionStatus.kicked;

  StreamSubscription<ImMessage>? _sub;
  StreamSubscription<ImConnectionStatus>? _connSub;
  bool _lastKicked = false;
  bool _disposed = false;

  /// 进行中的本地媒体上传(localId → 上传句柄),用于进度更新与取消。
  final Map<String, _PendingUpload> _uploads = <String, _PendingUpload>{};

  static const Duration _sendConnectTimeout = Duration(seconds: 3);
  static const int _historyPageSize = 40;

  /// 进入页面:取凭证 → init/login/connect → /direct-rooms 拿 channel → 历史 + 实时监听。
  Future<void> open({String? title}) async {
    if (_opening || _disposed) return;
    _opening = true;
    _setLoading(messages.isEmpty);
    try {
      _identity ??= await ChatCacheScope.current();
      if (_disposed) return;
      // kicked(被踢下线/多端互踢)与普通断线不同(P1 契约):**不**自动重连。
      // 打开 pane 时若已 kicked,则不 connect / 不 fetch 凭证 / 不 init/login /
      // 不 createDirectRoom / 不拉历史,直接给出可读错误等待用户重新登录。
      if (client.connectionStatus == ImConnectionStatus.kicked) {
        _error = 'IM 连接已被踢下线(账号在其他设备登录),请重新登录';
        return; // finally 会结束 loading 并 notify
      }
      final localClient = client;
      final knownChannel = presetChannelId;
      if (knownChannel != null && knownChannel.isNotEmpty) {
        if (messages.isEmpty && client.connectedUid == null &&
            localClient is ImLocalHistoryClient) {
          try {
            final local = await (localClient as ImLocalHistoryClient)
                .readLocalHistory(knownChannel, _channelType);
            if (_disposed) return;
            if (local != null && local.messages.isNotEmpty) {
              _myUid = local.uid;
              await _loadLocalDeletedMessageKeys();
              if (_disposed) return;
              _historyLoaded = true;
              _resetMessages(_filterAfterCleared(local.messages));
              _setLoading(false);
            }
          } catch (error) {
            debugPrint('[chat-cold-cache] read failed (${error.runtimeType})');
          }
        }
        _ensureSubscriptions();
      }
      // 连接是 app 级、跨会话复用:已有 uid 只跳过取凭证 / setup;
      // 真实长连接仍看 connectionStatus,不能把 connectedUid 当成已连通。
      final existingUid = client.connectedUid;
      if (existingUid != null && existingUid.isNotEmpty) {
        _myUid = existingUid;
        if (!client.isRealtimeConnected &&
            !client.connectionStatus.isConnecting) {
          await client.connect();
        }
      } else {
        final info = await _credentials.fetchWukongConnInfo();
        _myUid = info.uid;
        await client.init();
        await client.login(info);
        await client.connect();
      }

      // 会话列表点开:已知 channel,直接用,不重调 /direct-rooms(P2.1 点 10)。
      String? ch = presetChannelId;
      int chType = presetChannelType ?? 2;
      _conversationUuid = presetConversationUuid;
      if (ch == null || ch.isEmpty) {
        // 通讯录新开:走 /direct-rooms 建/取房拿 channel + conversation uuid。
        final room = await roomsService.createDirectRoom(
          peerAccountUuid: peerAccountUuid!,
          title: title,
        );
        _roomUuid = room.roomUuid;
        ch = room.wukongChannelId;
        chType = room.wukongChannelType ?? 2;
        _conversationUuid = room.conversationUuid;
        _setClearedAt(room.clearedAt);
      }
      if (ch == null || ch.isEmpty) {
        _error = 'direct room 未返回 wukong_channel_id(后端 wukong 未启用?)';
        return;
      }
      _channelId = ch;
      _channelType = chType;
      await _loadLocalDeletedMessageKeys();

      final hist = await client.getHistoryMessages(
        ch,
        _channelType,
        limit: _historyPageSize,
        conversationUuid: _conversationUuid,
        clearedAt: _clearedAtRaw,
      );
      if (_disposed) return;
      final visibleHist = _filterAfterCleared(hist);
      _historyLoaded = true;
      _resetMessages(visibleHist);
      // 第一页不足一页 → 没有更早历史可加载。
      _hasMoreHistory = hist.length >= _historyPageSize &&
          visibleHist.length >= _historyPageSize;
      _ensureSubscriptions();
      // ignore: discarded_futures
      client.markRead(ch, _channelType);
      // local-first：已有缓存先结束 open/render，再后台按本地尾游标补齐离线新增。
      // 本地 seq 从 1 连续不代表离线期间服务端尾部没有新增消息。
      if (hist.isNotEmpty && client is ImLatestHistorySyncClient) {
        unawaited(syncLatestMessages());
      }
    } catch (e, st) {
      if ((e is DioException && [401, 403].contains(e.response?.statusCode)) ||
          (e is IMCredentialsException && e.needsReLogin)) {
        discardWarmHistory();
        _entries.clear();
      }
      _error = isTransientNetworkError(e) || e is TimeoutException
          ? null
          : e.toString();
      debugPrint('[HumanDirectIm] open failed: $e\n$st');
    } finally {
      _opening = false;
      _setLoading(false);
    }
  }

  void _ensureSubscriptions() {
    if (_disposed) return;
    _sub ??= client.listenMessages().listen(_onStreamMessage);
    _lastKicked = isConnectionKicked;
    _connSub ??= client.listenConnectionStatus().listen((status) {
      final kicked = status == ImConnectionStatus.kicked;
      if (kicked != _lastKicked) {
        _lastKicked = kicked;
        notifyListeners();
      }
      if (status.isConnected && !_opening && !_cacheDenied) {
        _myUid = client.connectedUid;
        unawaited(syncLatestMessages());
      }
    });
  }

  /// 实时/回显消息入口(他人新消息、自己的 pending 回显、ack/失败刷新都走这里)。
  /// **不再**按 fromUid 丢弃自己的回显 —— 自回显经 [_upsert] 用 clientMsgNo 对账回 pending。
  void _onStreamMessage(ImMessage m) {
    if (m.channelId != _channelId) return;
    if (!_isAfterCleared(m)) return;
    if (_upsert(m)) notifyListeners();
  }

  /// 统一去重 + 排序入表。返回是否实际改变了消息表(用于决定是否 notify)。
  ///
  /// 去重键优先级:`clientMsgNo`(非空) > 服务端 `messageId`(非空、非本地临时)。
  /// 同 clientMsgNo 的回显(pending→sent/failed)**替换**原条目(保留到达序),不新插一条。
  /// `isRefresh` 的消息**只更新已有条目**,不插入陌生旧消息(避免已读回执/反应把旧消息拉进视图)。
  ///
  /// **F09 P1 撤回**: 若 `m.isRevokeNotify==true`, 通知本身不入表; 转去用
  /// `revokedMessageId` / `revokedClientMsgNo` 找原消息替成 tombstone。
  bool _upsert(ImMessage m) {
    if (m.isRevokeNotify) {
      return _applyRevokeNotify(m);
    }
    if (!_isAfterCleared(m)) return false;
    if (_isLocallyDeleted(m)) return false;
    var idx = -1;
    if (m.clientMsgNo.isNotEmpty) {
      idx = _entries.indexWhere((e) =>
          e.message.clientMsgNo.isNotEmpty &&
          e.message.clientMsgNo == m.clientMsgNo);
    }
    if (idx < 0 && _isServerId(m.messageId)) {
      idx = _entries.indexWhere((e) =>
          _isServerId(e.message.messageId) &&
          e.message.messageId == m.messageId);
    }
    if (idx >= 0) {
      _entries[idx] = _ImMsgEntry(m, _entries[idx].arrival);
    } else {
      if (m.isRefresh) return false;
      _entries.add(_ImMsgEntry(m, _arrivalCounter++));
    }
    _sortEntries();
    return true;
  }

  /// F09 P1: 本地乐观撤回 (UI 立刻显示 tombstone)。
  /// 返回原消息快照(成功时用于回滚)。找不到目标返 null。
  ImMessage? markLocallyRevoked(
      {String messageId = '', String clientMsgNo = ''}) {
    final idx = _indexOfMessage(messageId: messageId, clientMsgNo: clientMsgNo);
    if (idx < 0) return null;
    final snapshot = _entries[idx].message;
    if (snapshot.isRevoked) return null;
    _entries[idx] = _ImMsgEntry(snapshot.withRevoked(), _entries[idx].arrival);
    notifyListeners();
    return snapshot;
  }

  /// F09 P1: 撤回失败回滚 — 把 snapshot 重新放回(按 clientMsgNo/messageId 匹配并替换)。
  /// 调用方在 ChatService.revokeMessage 抛错时调。
  void revertRevoke(ImMessage snapshot) {
    final idx = _indexOfMessage(
        messageId: snapshot.messageId, clientMsgNo: snapshot.clientMsgNo);
    if (idx < 0) return;
    _entries[idx] = _ImMsgEntry(snapshot, _entries[idx].arrival);
    notifyListeners();
  }

  int _indexOfMessage(
      {required String messageId, required String clientMsgNo}) {
    if (messageId.isNotEmpty) {
      final i = _entries.indexWhere((e) =>
          _isServerId(e.message.messageId) && e.message.messageId == messageId);
      if (i >= 0) return i;
    }
    if (clientMsgNo.isNotEmpty) {
      return _entries.indexWhere((e) =>
          e.message.clientMsgNo.isNotEmpty &&
          e.message.clientMsgNo == clientMsgNo);
    }
    return -1;
  }

  /// F09 P1 撤回通知处理: 找到原消息 (优先 messageId, 兜底 clientMsgNo) 替成 tombstone;
  /// 通知本身不入表。返回是否实际改变了消息表 (找不到目标也返 false, 让 controller 不 notify)。
  bool _applyRevokeNotify(ImMessage notify) {
    final targetId = notify.revokedMessageId;
    final targetClientNo = notify.revokedClientMsgNo;
    if (targetId.isEmpty && targetClientNo.isEmpty) return false;
    var idx = -1;
    if (targetId.isNotEmpty) {
      idx = _entries.indexWhere((e) =>
          _isServerId(e.message.messageId) && e.message.messageId == targetId);
    }
    if (idx < 0 && targetClientNo.isNotEmpty) {
      idx = _entries.indexWhere((e) =>
          e.message.clientMsgNo.isNotEmpty &&
          e.message.clientMsgNo == targetClientNo);
    }
    if (idx < 0) return false;
    final cur = _entries[idx].message;
    if (cur.isRevoked) return false; // 幂等
    _entries[idx] = _ImMsgEntry(cur.withRevoked(), _entries[idx].arrival);
    return true;
  }

  /// 服务端 messageId(非空、非本地临时 `local-`、非预留态 `0`)。
  static bool _isServerId(String id) =>
      id.isNotEmpty && id != '0' && !id.startsWith('local-');

  static DateTime? _parseClearedAt(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || raw == 'null') return null;
    return DateTime.tryParse(raw);
  }

  void _setClearedAt(String? value) {
    _clearedAtRaw = value;
    _clearedAt = _parseClearedAt(value);
  }

  List<ImMessage> _filterAfterCleared(List<ImMessage> input) {
    final cleared = _clearedAt;
    if (cleared == null) return input;
    return input.where(_isAfterCleared).toList(growable: false);
  }

  bool _isAfterCleared(ImMessage m) {
    final cleared = _clearedAt;
    if (cleared == null) return true;
    final msgAt = _imTimestampToDate(m.timestamp);
    if (msgAt == null) return m.messageSeq <= 0;
    return msgAt.isAfter(cleared);
  }

  static DateTime? _imTimestampToDate(int timestamp) {
    if (timestamp <= 0) return null;
    if (timestamp >= 1000000000000000) {
      return DateTime.fromMicrosecondsSinceEpoch(timestamp);
    }
    if (timestamp >= 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }

  // 未 ack 消息 messageSeq=0 → 用此哨兵排在已 ack(seq>0)之后。
  static const int _pendingSortKey = 1 << 62;

  void _sortEntries() {
    _entries.sort((a, b) {
      if (_shouldKeepLocalOutgoingOrder(a, b)) {
        return a.arrival.compareTo(b.arrival);
      }
      final ka =
          a.message.messageSeq > 0 ? a.message.messageSeq : _pendingSortKey;
      final kb =
          b.message.messageSeq > 0 ? b.message.messageSeq : _pendingSortKey;
      if (ka != kb) return ka.compareTo(kb);
      return a.arrival.compareTo(b.arrival); // 稳定:同序号按到达序
    });
  }

  bool _shouldKeepLocalOutgoingOrder(_ImMsgEntry a, _ImMsgEntry b) {
    final me = _myUid;
    if (me == null || me.isEmpty) return false;
    if (a.message.fromUid != me || b.message.fromUid != me) return false;
    return a.message.messageSeq <= 0 || b.message.messageSeq <= 0;
  }

  void _resetMessages(List<ImMessage> history) {
    _entries.clear();
    _arrivalCounter = 0;
    for (final m in history) {
      _upsert(m);
    }
  }

  /// 当前已加载消息里最早的有效服务端序号(messageSeq>0);无则 0(只有 pending/本地失败预留态)。
  int _earliestMessageSeq() {
    var min = 0;
    for (final e in _entries) {
      final s = e.message.messageSeq;
      if (s > 0 && (min == 0 || s < min)) min = s;
    }
    return min;
  }

  /// F09 引用回复 v1 (2026-06 跨页 best-effort 定位): 当前已加载窗口里最早的服务端 seq。
  /// 用于判断 reply 引用的 messageSeq 是否在已加载窗口**更早**侧 (需要上拉补加载)。
  /// 0 = 当前窗口没有任何已 ack 消息 (只有 pending/local-failed 预留态)。
  int get earliestMessageSeq => _earliestMessageSeq();

  /// 上拉加载更早历史(P1,人↔人 + 群聊共用)。以当前最早 messageSeq 为锚点向更早翻页,
  /// 新页统一过 [_upsert](去重 + 按 messageSeq 排序);返回空、不足一页或去重后无进展
  /// → [hasMoreHistory]=false。
  Future<void> loadMoreHistory({bool reportErrors = false}) async {
    if (_loadingMore || !_hasMoreHistory) return;
    final ch = _channelId;
    if (ch == null) return;
    final anchor = _earliestMessageSeq();
    if (anchor <= 1) {
      // 没有可锚定的已 ack 消息,或已到第一条 → 没有更早历史。
      _hasMoreHistory = false;
      notifyListeners();
      return;
    }
    final beforeEarliest = anchor;
    final beforeCount = _entries.length;
    _loadingMore = true;
    notifyListeners();
    try {
      final older = await client.getHistoryMessages(
        ch,
        _channelType,
        limit: _historyPageSize,
        beforeMessageSeq: anchor,
        conversationUuid: _conversationUuid,
        clearedAt: _clearedAtRaw,
      );
      final visibleOlder = _filterAfterCleared(older);
      if (visibleOlder.isEmpty) {
        _hasMoreHistory = false;
      } else {
        for (final m in visibleOlder) {
          _upsert(m);
        }
        final afterEarliest = _earliestMessageSeq();
        final madeProgress = _entries.length > beforeCount ||
            (afterEarliest > 0 && afterEarliest < beforeEarliest);
        if (older.length < _historyPageSize || !madeProgress) {
          _hasMoreHistory = false;
        }
      }
    } catch (e, st) {
      // 失败不改 hasMore；刷新控件可接收异常显示重试，不覆盖会话主错误。
      debugPrint('[HumanDirectIm] loadMoreHistory failed: $e\n$st');
      if (reportErrors) rethrow;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 补拉最新一页并合入当前窗口。
  ///
  /// 用于会话列表预览已更新、但当前 pane 没收到 SDK 实时消息的 gap 对账
  /// (例如服务端 outbox 代发通话结束卡片)。走 [_upsert] 去重, 不清空已有窗口。
  Future<void> syncLatestMessages() async {
    final ch = _channelId;
    if (ch == null || ch.isEmpty || _disposed) return;
    try {
      final latestClient = client;
      final latestSyncClient = latestClient is ImLatestHistorySyncClient
          ? latestClient as ImLatestHistorySyncClient
          : null;
      final latest = latestSyncClient != null
          ? await latestSyncClient.syncLatestHistoryMessages(
              ch,
              _channelType,
              limit: _historyPageSize,
              conversationUuid: _conversationUuid,
              clearedAt: _clearedAtRaw,
            )
          : await latestClient.getHistoryMessages(
              ch,
              _channelType,
              limit: _historyPageSize,
              conversationUuid: _conversationUuid,
              clearedAt: _clearedAtRaw,
            );
      var changed = false;
      for (final m in _filterAfterCleared(latest)) {
        changed = _upsert(m) || changed;
      }
      if (changed && !_disposed) {
        notifyListeners();
        // ignore: discarded_futures
        client.markRead(ch, _channelType);
      }
    } catch (e, st) {
      debugPrint('[HumanDirectIm] syncLatestMessages failed: $e\n$st');
    }
  }

  /// 文本 failed 重发(P1,仅文本):复用 [sendText] 走完整 WuKong 生命周期。
  /// 最小实现保留旧 failed 预留态(新发一条 pending,旧条不动);媒体重发留后续。
  ///
  /// 仅允许重发**自己**发出的 failed 纯文本:`_myUid` 非空且 `fromUid==_myUid`,
  /// 非文本/空文本/对端消息一律 no-op(controller 是公共方法,不能只靠 UI 不传 onRetry 兜底)。
  Future<void> retryTextMessage(ImMessage failed) async {
    final me = _myUid;
    if (me == null ||
        me.isEmpty ||
        failed.fromUid != me ||
        !failed.isFailed ||
        failed.mediaKind != ImMediaKind.none ||
        failed.text.isEmpty) {
      return;
    }
    await sendText(failed.text);
  }

  /// 发送明确失败(SDK 抛错 / 长连接 ensure 失败)时插入一条本地 failed 预留态:
  /// 不假装 sent;因消息从未进 WuKong,不会有回显与之重复。
  /// 媒体失败时带上重发所需信息(`mediaKind`/`mediaName`/`mediaLocalPath`/`mediaFileUuid`)。
  void _upsertLocalFailed({
    required String channelId,
    required String text,
    required String error,
    ImMediaKind mediaKind = ImMediaKind.none,
    String mediaName = '',
    String mediaLocalPath = '',
    String mediaFileUuid = '',
  }) {
    _upsert(ImMessage(
      messageId: 'local-${DateTime.now().microsecondsSinceEpoch}',
      clientMsgNo: '',
      fromUid: _myUid ?? '',
      channelId: channelId,
      channelType: _channelType,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      text: text,
      sendStatus: ImSendStatus.failed,
      errorMessage: error,
      mediaKind: mediaKind,
      mediaName: mediaName,
      mediaLocalPath: mediaLocalPath,
      mediaFileUuid: mediaFileUuid,
    ));
  }

  /// 媒体发送失败 → 生成自己侧 failed 预留态(保留重发信息)。频道未就绪则跳过(罕见)。
  void _onMediaSendFailed(
    ImMediaKind kind,
    String name,
    Object error, {
    String localPath = '',
    String driveFileUuid = '',
  }) {
    final ch = _channelId;
    if (ch == null) return;
    // 媒体 failed 预留态无 URL,气泡按文本回退渲染,text 给可读标签。
    final label =
        kind == ImMediaKind.image ? '[图片]' : (name.isNotEmpty ? name : '[文件]');
    _upsertLocalFailed(
      channelId: ch,
      text: label,
      error: error.toString(),
      mediaKind: kind,
      mediaName: name,
      mediaLocalPath: localPath,
      mediaFileUuid: driveFileUuid,
    );
    notifyListeners();
  }

  /// 媒体 failed 重发(P1,图片/文件/云盘):口径同 [retryTextMessage] —— 仅自己 failed 媒体,
  /// 复用发送路径走完整 WuKong 生命周期(新 pending,旧 failed 保留)。信息不足则 no-op。
  Future<void> retryMediaMessage(ImMessage failed) async {
    final me = _myUid;
    if (me == null ||
        me.isEmpty ||
        failed.fromUid != me ||
        !failed.isFailed ||
        failed.mediaKind == ImMediaKind.none) {
      return;
    }
    final name = failed.mediaName.isNotEmpty ? failed.mediaName : '文件';
    if (failed.mediaLocalPath.isNotEmpty) {
      await _sendLocalByPath(failed.mediaLocalPath, name, failed.mediaKind);
    } else if (failed.mediaFileUuid.isNotEmpty) {
      await _sendDriveFileByUuid(failed.mediaFileUuid, name, failed.mediaKind);
    } else {
      debugPrint(
          '[HumanDirectIm] retryMediaMessage: 信息不足(无 localPath/driveFileUuid),跳过');
    }
  }

  /// 本地删除一条消息(P2,仅客户端):从 `messages` 物化视图(`_entries`)移除,
  /// 并持久化删除键,重进会话/历史同步/实时回显时继续过滤。
  /// **不**调后端 / SDK / WuKong / Bus、**不**影响对端、**不**改 unread / 已读权威。
  /// 匹配优先级与 `_upsert` 去重键一致:`clientMsgNo`(非空)> 服务端 `messageId`
  /// (`_isServerId`)> 精确 `messageId`(本地预留态 `local-` / 预留态 `0`)。命中即移除 +
  /// `notifyListeners`;未命中 no-op(不 crash、不 notify)。
  void removeLocalMessage(ImMessage msg) {
    var idx = -1;
    if (msg.clientMsgNo.isNotEmpty) {
      idx = _entries.indexWhere((e) =>
          e.message.clientMsgNo.isNotEmpty &&
          e.message.clientMsgNo == msg.clientMsgNo);
    }
    if (idx < 0 && _isServerId(msg.messageId)) {
      idx = _entries.indexWhere((e) =>
          _isServerId(e.message.messageId) &&
          e.message.messageId == msg.messageId);
    }
    if (idx < 0 && msg.messageId.isNotEmpty) {
      idx = _entries.indexWhere((e) => e.message.messageId == msg.messageId);
    }
    if (idx < 0) return;
    final removed = _entries.removeAt(idx).message;
    final keys = _localDeleteKeysFor(removed);
    if (keys.isNotEmpty) {
      _locallyDeletedMessageKeys.addAll(keys);
      unawaited(_persistLocalDeletedMessageKeys());
    }
    notifyListeners();
  }

  String? _localDeletedPrefsKey() {
    final uid = _myUid;
    final ch = _channelId;
    if (uid == null || uid.isEmpty || ch == null || ch.isEmpty) return null;
    return 'zhiban.im.local_deleted_messages.v1.$uid.$_channelType.$ch';
  }

  Future<void> _loadLocalDeletedMessageKeys() async {
    _locallyDeletedMessageKeys.clear();
    final key = _localDeletedPrefsKey();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    _locallyDeletedMessageKeys.addAll(
      prefs.getStringList(key) ?? const <String>[],
    );
  }

  Future<void> _persistLocalDeletedMessageKeys() async {
    final key = _localDeletedPrefsKey();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final keys = _locallyDeletedMessageKeys.toList()..sort();
    await prefs.setStringList(key, keys);
  }

  Set<String> _localDeleteKeysFor(ImMessage msg) {
    final keys = <String>{};
    if (msg.clientMsgNo.isNotEmpty) keys.add('cmn:${msg.clientMsgNo}');
    if (_isServerId(msg.messageId)) keys.add('mid:${msg.messageId}');
    if (msg.messageId.isNotEmpty) keys.add('local:${msg.messageId}');
    return keys;
  }

  bool _isLocallyDeleted(ImMessage msg) {
    if (_locallyDeletedMessageKeys.isEmpty) return false;
    final keys = _localDeleteKeysFor(msg);
    return keys.any(_locallyDeletedMessageKeys.contains);
  }

  /// F09 引用回复 v1: `replyRef` 非空时发送路径**晋升为 mixed**, 顶层带 reply payload;
  /// 否则走 WuKong 文本路径(保持现状, 不影响既有 mentions 路径)。
  Future<void> sendText(String text,
      {List<Map<String, dynamic>>? mentions,
      Map<String, dynamic>? replyRef}) async {
    final ch = _channelId;
    if (ch == null) throw StateError('human direct chat not ready');
    try {
      await _ensureRealtimeReadyForSend();
      if (replyRef != null && replyRef.isNotEmpty) {
        // 引用 + 纯文本 → mixed 包 1 个 text block + 顶层 reply.
        await client.sendMixedMessage(
          ch,
          _channelType,
          blocks: [ImMessageBlock(kind: ImMessageBlockKind.text, text: text)],
          summary: text,
          mentions: mentions,
          reply: replyRef,
        );
      } else {
        // 发送成功后:WuKong SDK 经 msgInserted 立即回送 pending、ack 后再 refresh 成 sent,
        // 都经 listenMessages → _onStreamMessage → _upsert 上屏对账。这里**不**手工乐观插入。
        await client.sendTextMessage(ch, _channelType, text,
            mentions: mentions);
      }
    } catch (e) {
      _upsertLocalFailed(channelId: ch, text: text, error: e.toString());
      notifyListeners();
      rethrow;
    }
  }

  /// mixed 消息发送:blocks 已在 composer 阶段上传/建 ref 完成,这里只负责一次性发出。
  /// F09 引用回复 v1: 接受 `replyRef` 顶层 payload (与 mentions 并列)。
  Future<void> sendMixedMessage(
    List<ImMessageBlock> blocks, {
    String summary = '',
    List<Map<String, dynamic>>? mentions,
    Map<String, dynamic>? replyRef,
  }) async {
    final ch = _channelId;
    if (ch == null) throw StateError('human direct chat not ready');
    try {
      await _ensureRealtimeReadyForSend();
      await client.sendMixedMessage(
        ch,
        _channelType,
        blocks: blocks,
        summary: summary,
        mentions: mentions,
        reply: replyRef,
      );
    } catch (e) {
      _upsertLocalFailed(
        channelId: ch,
        text: summary.trim().isNotEmpty ? summary.trim() : '[非文本消息]',
        error: e.toString(),
        mediaKind: blocks.any((b) => b.isImage)
            ? ImMediaKind.image
            : blocks.any((b) => b.isFile)
                ? ImMediaKind.file
                : ImMediaKind.none,
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _ensureRealtimeReadyForSend() async {
    // kicked(被踢下线/多端互踢)与普通断线不同:不重连、直接发送失败,
    // 调用方 sendText 会据此把该条标记 failed(WuKong 权威:此设备已不该再发)。
    if (client.connectionStatus == ImConnectionStatus.kicked) {
      throw StateError('IM 连接已被踢下线(账号在其他设备登录),请重新登录');
    }
    if (client.isRealtimeConnected) return;
    final connected = client
        .listenConnectionStatus()
        .where((s) => s.isConnected)
        .first
        .timeout(_sendConnectTimeout);
    if (!client.connectionStatus.isConnecting) {
      await client.connect();
    }
    if (client.isRealtimeConnected) return;
    try {
      await connected;
    } on TimeoutException {
      throw StateError('IM 长连接未就绪，请稍后重试');
    }
    if (!client.isRealtimeConnected) {
      throw StateError('IM 长连接未就绪，请稍后重试');
    }
  }

  final MessageFilesService _filesSvc;

  /// 本地图片 → message-files 上传(产出 chat-scoped drive_file)→ chat media ref → 发。
  Future<void> sendLocalImage(String filePath, String fileName) =>
      _sendLocalByPath(filePath, fileName, ImMediaKind.image);

  /// 本地文件 → message-files 上传 → chat media ref → 发。
  Future<void> sendLocalFile(String filePath, String fileName) =>
      _sendLocalByPath(filePath, fileName, ImMediaKind.file);

  /// mixed composer 专用:本地媒体在**输入阶段**上传 + 建 chat media ref,返回可入 blocks 的媒体块。
  /// 不插入聊天气泡、不发 WuKong;失败由 composer 标注在输入框里。
  Future<ImMessageBlock> prepareLocalMediaBlock(
    String filePath,
    String fileName,
    ImMediaKind kind, {
    void Function(int progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (kind == ImMediaKind.none) {
      throw ArgumentError('prepareLocalMediaBlock requires image/file kind');
    }
    await _ensureRealtimeReadyForSend();
    final driveFileUUID = await _filesSvc.uploadFile(
      filePath: filePath,
      fileName: fileName,
      mimeType: _guessMime(fileName),
      conversationUuid: _conversationUuid,
      cancelToken: cancelToken,
      onSendProgress: (sent, total) {
        final pct =
            total > 0 ? ((sent / total) * 100).clamp(0, 100).round() : 0;
        onProgress?.call(pct);
      },
    );
    return _mediaBlockFromDriveFileUuid(driveFileUUID);
  }

  /// 本地图片/文件发送(P2/P3):**先 ensure 长连接可发送,再上传**(P2 修复:kicked/不可用时
  /// 不浪费 OSS 上传、不产生 staged 文件,直接 failed)。ensure 通过后插自己侧 **uploading 预留态**
  /// (进度可见、可取消),上传走 Dio `onSendProgress`/`CancelToken`;成功→移除预留态由 SDK 回显上屏;
  /// 取消→预留态 failed('已取消上传')不发 WuKong;失败→**同一预留态**更新为 failed(不重复)。
  /// 重发复用本路径(新 uploading 预留态,旧条保留)。
  Future<void> _sendLocalByPath(
      String filePath, String fileName, ImMediaKind kind) async {
    final ch = _channelId;
    if (ch == null) throw StateError('human direct chat not ready');

    // P2 修复:上传 OSS 之前先确认 IM 可发送。kicked / 长连接不就绪 → 直接 failed 预留态
    // (**不**先 uploading 闪一下、**不**上传、**不**建 ref、**不**发 WuKong);保留信息可重发,rethrow 给 pane。
    try {
      await _ensureRealtimeReadyForSend();
    } catch (e) {
      _onMediaSendFailed(kind, fileName, e, localPath: filePath);
      rethrow;
    }

    final localId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final up = _PendingUpload(
      localId: localId,
      filePath: filePath,
      fileName: fileName,
      kind: kind,
      channelId: ch,
      cancelToken: CancelToken(),
    );
    _uploads[localId] = up;
    _putByLocalId(
        _uploadMessage(up, status: ImSendStatus.pending, progress: 0));
    notifyListeners();

    String driveFileUUID;
    try {
      driveFileUUID = await _filesSvc.uploadFile(
        filePath: filePath,
        fileName: fileName,
        mimeType: _guessMime(fileName),
        conversationUuid: _conversationUuid,
        cancelToken: up.cancelToken,
        onSendProgress: (sent, total) {
          if (_disposed || up.cancelled) return;
          final pct =
              total > 0 ? ((sent / total) * 100).clamp(0, 100).round() : 0;
          _putByLocalId(
              _uploadMessage(up, status: ImSendStatus.pending, progress: pct));
          notifyListeners();
        },
      );
    } catch (e) {
      _uploads.remove(localId);
      if (_disposed) return;
      if (up.cancelled || _isCancel(e)) {
        // 取消:预留态 → failed('已取消上传');不建 ref、不发 WuKong;不抛(不弹 snackbar)。
        _putByLocalId(
            _uploadMessage(up, status: ImSendStatus.failed, error: '已取消上传'));
        notifyListeners();
        return;
      }
      // 上传失败:**同一预留态**更新为 failed(保留 mediaLocalPath),不再生成第二条;抛给 pane toast。
      _putByLocalId(
          _uploadMessage(up, status: ImSendStatus.failed, error: e.toString()));
      notifyListeners();
      rethrow;
    }

    _uploads.remove(localId);
    if (_disposed) return;
    if (up.cancelled) {
      // 上传刚完成时的竞态取消:仍不发 WuKong。
      _putByLocalId(
          _uploadMessage(up, status: ImSendStatus.failed, error: '已取消上传'));
      notifyListeners();
      return;
    }
    // 上传成功:移除上传预留态,由 SDK msgInserted 产出真正 pending/sent(策略 1,避免重复)。
    _removeByLocalId(localId);
    notifyListeners();
    try {
      await _sendViaMediaRef(driveFileUUID);
    } catch (e) {
      if (_disposed) return;
      // 建 ref / WuKong send 失败 → 一条 failed 预留态(保留 mediaLocalPath 可重发)。
      _onMediaSendFailed(kind, fileName, e, localPath: filePath);
      rethrow;
    }
  }

  static bool _isCancel(Object e) =>
      e is DioException && e.type == DioExceptionType.cancel;

  /// 上传预留态/状态消息(本地 id,无 clientMsgNo)。`pending` 时带 `uploadProgress`,其余 -1。
  ImMessage _uploadMessage(_PendingUpload u,
      {required ImSendStatus status, int progress = -1, String error = ''}) {
    return ImMessage(
      messageId: u.localId,
      clientMsgNo: '',
      fromUid: _myUid ?? '',
      channelId: u.channelId,
      channelType: _channelType,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      text: u.kind == ImMediaKind.image
          ? '[图片]'
          : (u.fileName.isNotEmpty ? u.fileName : '[文件]'),
      sendStatus: status,
      errorMessage: error,
      mediaKind: u.kind,
      mediaName: u.fileName,
      mediaLocalPath: u.filePath,
      uploadProgress: status == ImSendStatus.pending ? progress : -1,
    );
  }

  /// 按本地 messageId 插入/替换条目(保留到达序);上传预留态/进度更新用,不走 `_upsert` 的去重键。
  void _putByLocalId(ImMessage m) {
    final idx = _entries.indexWhere((e) => e.message.messageId == m.messageId);
    if (idx >= 0) {
      _entries[idx] = _ImMsgEntry(m, _entries[idx].arrival);
    } else {
      _entries.add(_ImMsgEntry(m, _arrivalCounter++));
    }
    _sortEntries();
  }

  void _removeByLocalId(String localId) {
    _entries.removeWhere((e) => e.message.messageId == localId);
  }

  /// 取消正在上传的本地媒体(P2/P3):**真 cancel** Dio 上传,预留态转 failed('已取消上传'),不发 WuKong。
  /// 仅自己的、`pending`、`mediaLocalPath` 非空、仍在上传中的预留态可取消;其余 no-op。
  void cancelMediaUpload(ImMessage uploading) {
    final me = _myUid;
    if (me == null || me.isEmpty || uploading.fromUid != me) return;
    if (uploading.sendStatus != ImSendStatus.pending) return;
    if (uploading.mediaLocalPath.isEmpty) return;
    final up = _uploads[uploading.messageId];
    if (up == null) return; // 已不在上传中(上传完成 / 已取消)
    up.cancelled = true;
    if (!up.cancelToken.isCancelled) {
      up.cancelToken.cancel('user cancelled upload');
    }
    // 立即给 UI 反馈;上传 future 的 catch 也会幂等更新同一预留态。
    _putByLocalId(
        _uploadMessage(up, status: ImSendStatus.failed, error: '已取消上传'));
    notifyListeners();
  }

  /// 云盘已有文件 → chat media ref(后端校验 viewer+;不下发原始 drive URL)→ 发。
  Future<void> sendDriveFile(DriveFile f) {
    final kind =
        f.mimeType.startsWith('image/') ? ImMediaKind.image : ImMediaKind.file;
    return _sendDriveFileByUuid(f.uuid, f.name, kind);
  }

  /// mixed composer 专用:云盘已有文件只建 chat media ref,返回可入 blocks 的媒体块。
  Future<ImMessageBlock> prepareDriveMediaBlock(DriveFile f) async {
    await _ensureRealtimeReadyForSend();
    return _mediaBlockFromDriveFileUuid(f.uuid);
  }

  /// 云盘文件发送(失败 → 自己侧 failed 预留态 + 重发信息 `mediaFileUuid`)。重发复用本路径。
  Future<void> _sendDriveFileByUuid(
      String driveFileUuid, String name, ImMediaKind kind) async {
    try {
      await _sendViaMediaRef(driveFileUuid);
    } catch (e) {
      _onMediaSendFailed(kind, name, e, driveFileUuid: driveFileUuid);
      rethrow;
    }
  }

  /// 统一:为 drive_file 建 chat media ref → 用稳定 Bus URL `/chat/media/{ref}/...` 发 WuKong 消息。
  /// 安全:WuKong payload 只放 Bus ref URL,不含 S3 signed / :5001 / 原始私有 drive URL。
  Future<void> _sendViaMediaRef(String driveFileUUID) async {
    final ch = _channelId;
    if (ch == null) throw StateError('human direct chat not ready');
    await _ensureRealtimeReadyForSend();
    final convUUID = _conversationUuid;
    if (convUUID == null || convUUID.isEmpty) {
      throw StateError('conversation uuid unknown; cannot bind chat media');
    }
    final ref = await _chatMedia.createRef(
      conversationUuid: convUUID,
      driveFileUuid: driveFileUUID,
    );
    if (ref.isImage) {
      final url = _chatMediaPath(ref.refUuid, 'preview');
      await client.sendImageMessage(ch, _channelType,
          url: url,
          fileUuid: ref.driveFileUuid,
          refUuid: ref.refUuid,
          name: ref.fileName);
    } else {
      final url = _chatMediaPath(ref.refUuid, 'download');
      await client.sendFileMessage(ch, _channelType,
          url: url,
          fileUuid: ref.driveFileUuid,
          refUuid: ref.refUuid,
          name: ref.fileName,
          size: ref.sizeBytes,
          mime: ref.mimeType);
    }
    // 媒体 pending/sent 经 SDK msgInserted/refresh → listenMessages → _upsert 上屏(不手工乐观插入);
    // 失败由外层 catch(_sendLocalByPath / _sendDriveFileByUuid)生成 failed 预留态并 rethrow 给宿主 pane toast。
  }

  Future<ImMessageBlock> _mediaBlockFromDriveFileUuid(
      String driveFileUUID) async {
    final convUUID = _conversationUuid;
    if (convUUID == null || convUUID.isEmpty) {
      throw StateError('conversation uuid unknown; cannot bind chat media');
    }
    final ref = await _chatMedia.createRef(
      conversationUuid: convUUID,
      driveFileUuid: driveFileUUID,
    );
    if (ref.isImage) {
      return ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: _chatMediaPath(ref.refUuid, 'preview'),
        fileUuid: ref.driveFileUuid,
        refUuid: ref.refUuid,
        name: ref.fileName,
        size: ref.sizeBytes,
        mime: ref.mimeType,
      );
    }
    return ImMessageBlock(
      kind: ImMessageBlockKind.file,
      url: _chatMediaPath(ref.refUuid, 'download'),
      fileUuid: ref.driveFileUuid,
      refUuid: ref.refUuid,
      name: ref.fileName,
      size: ref.sizeBytes,
      mime: ref.mimeType,
    );
  }

  static String _chatMediaPath(String refUuid, String action) =>
      '/chat/media/${Uri.encodeComponent(refUuid)}/$action';

  static String _guessMime(String n) {
    final ext = n.contains('.') ? n.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'zip':
        return 'application/zip';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  void _setLoading(bool v) {
    _loading = v;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _rememberWindow();
    super.notifyListeners();
  }

  @override
  void dispose() {
    // 只取消本会话的订阅;**不** dispose 共享 client(其长连接/消息流是 app 级,
    // 跨会话复用;dispose 会关掉广播流导致其它/后续会话收不到消息)。
    _rememberWindow();
    _disposed = true;
    _sub?.cancel();
    _connSub?.cancel();
    // 取消进行中的上传(pane 关闭即放弃),避免上传回调在 dispose 后 notify。
    for (final u in _uploads.values) {
      u.cancelled = true;
      if (!u.cancelToken.isCancelled) {
        u.cancelToken.cancel('controller disposed');
      }
    }
    _uploads.clear();
    super.dispose();
  }
}

/// 消息表条目:消息本体 + 到达序(用于同 messageSeq / pending 之间的稳定排序)。
class _ImMsgEntry {
  _ImMsgEntry(this.message, this.arrival);
  final ImMessage message;
  final int arrival;
}

/// 进行中的本地媒体上传句柄(进度/取消)。
class _PendingUpload {
  _PendingUpload({
    required this.localId,
    required this.filePath,
    required this.fileName,
    required this.kind,
    required this.channelId,
    required this.cancelToken,
  });
  final String localId;
  final String filePath;
  final String fileName;
  final ImMediaKind kind;
  final String channelId;
  final CancelToken cancelToken;
  bool cancelled = false;
}
