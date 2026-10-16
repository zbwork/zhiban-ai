import 'wukong_cache_cleanup.dart';
import 'package:wukongimfluttersdk/db/const.dart';
import 'package:wukongimfluttersdk/db/message.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'wukong_session_identity.dart';
import 'package:crypto/crypto.dart';
import 'wukong_incremental_history.dart';
// WukongImClient: ImClient 的 WuKongIM 实现(ADR-0026)。
//
// **唯一**直接 import wukongimfluttersdk 的文件;业务 UI 只用 ../im_client.dart 抽象。
// 安全:连接信息来自 agent-bus /im/credentials(注入的 fetchConnInfo);不接触 WuKong :5001。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wukongimfluttersdk/common/mode.dart';
import 'package:wukongimfluttersdk/common/options.dart';
import 'package:wukongimfluttersdk/entity/channel.dart';
import 'package:wukongimfluttersdk/entity/msg.dart';
import 'package:wukongimfluttersdk/model/wk_image_content.dart';
import 'package:wukongimfluttersdk/model/wk_media_message_content.dart';
import 'package:wukongimfluttersdk/model/wk_message_content.dart';
import 'package:wukongimfluttersdk/model/wk_text_content.dart';
import 'package:wukongimfluttersdk/type/const.dart';
import 'package:wukongimfluttersdk/wkim.dart';

import 'package:zhiban_core/im/im_client.dart';
import 'contents/wk_rtc_call_signal_content.dart';
import 'wukong_history_completion.dart';
import 'wukong_message_sync_api.dart';
import 'wukong_local_schema.dart';

/// macOS uses the native sqflite Darwin plugin. FFI is required on desktop
/// platforms without that plugin only.
@visibleForTesting
bool usesWukongFfiDatabaseFactory({
  required bool isWindows,
  required bool isLinux,
}) =>
    isWindows || isLinux;

@visibleForTesting
Future<bool> migrateLegacyMacWukongDatabase({
  required Directory legacyDirectory,
  required Directory nativeDirectory,
  required String uid,
}) async {
  final databaseName = 'wk_$uid.db';
  final legacyDatabase =
      File('${legacyDirectory.path}${Platform.pathSeparator}$databaseName');
  final nativeDatabase =
      File('${nativeDirectory.path}${Platform.pathSeparator}$databaseName');
  if (!await legacyDatabase.exists() || await nativeDatabase.exists()) {
    return false;
  }

  await nativeDirectory.create(recursive: true);
  // SQLite's WAL files must travel with the main database when they exist.
  // Copy them first: without a main file they cannot be opened, so a failed
  // migration can safely retry on the next login without replacing a database.
  for (final suffix in <String>['-wal', '-shm', '']) {
    final source = File('${legacyDatabase.path}$suffix');
    if (await source.exists()) {
      await source.copy('${nativeDatabase.path}$suffix');
    }
  }
  return true;
}

class WukongImClient
    implements ImClient, ImLocalHistoryClient, ImLatestHistorySyncClient, ImReadReceiptSignalClient {
  WukongImClient({WukongMessageSyncApi? syncApi})
      : _syncApi = syncApi ?? WukongMessageSyncApi();

  /// 进程级共享实例:WuKong 长连接是 app 级、与具体会话无关。
  /// 所有 human_direct 会话复用同一连接 + 同一消息流,切换会话时**不**重取凭证/重连。
  static final WukongImClient shared = WukongImClient();

  final WukongMessageSyncApi _syncApi;

  static const String _listenerKey = 'zhiban_wukong_im';
  static const String _refreshListenerKey = 'zhiban_wukong_im_refresh';
  static const String _connectionListenerKey = 'zhiban_wukong_connection';
  static const String _convEventListenerKey = 'zhiban_wukong_conv_event';
  final StreamController<ImMessage> _msgController =
      StreamController<ImMessage>.broadcast();
  final StreamController<ImConnectionStatus> _connectionController =
      StreamController<ImConnectionStatus>.broadcast();
  final StreamController<ImConversationEvent> _convEventController =
      StreamController<ImConversationEvent>.broadcast();
  final StreamController<ImReadReceiptSignal> _readReceiptSignalController =
      StreamController<ImReadReceiptSignal>.broadcast();
  final Map<String, String> _historyConversationByChannel = <String, String>{};

  /// F16 RTC 控制信令旁路 stream(WuKong content type=1001)。
  /// 与 [_msgController] 隔离, 让聊天 UI 不会把信令当作普通消息渲染。
  /// 消费者: apps/zhiban-app/lib/rtc/signaling_listener.dart。
  /// 安全: 信令仅供 UI 唤醒, 真正的状态推进仍走 /api/agent-bus/v1/calls/* HTTP + 权限闸口。
  final StreamController<RtcCallSignalIncoming> _rtcSignalController =
      StreamController<RtcCallSignalIncoming>.broadcast();
  bool _inited = false;
  bool _listening = false;
  bool _connectionListening = false;
  String? _loggedInUid;
  int _identityGeneration = 0;
  String? _cachePartition;
  String? _loggedInToken; // 跟踪当前 setup 的 token;token 变化需重新 setup(P1 凭证刷新)。
  String? _loggedInDeviceID;
  int? _loggedInDeviceFlag;
  ImConnectionStatus _connectionStatus = ImConnectionStatus.idle;

  static const int _mixedContentType = 110;
  static const int agentFinalContentType = 111;

  /// F09 P1 撤回通知: server 在 sender 校验后用 caller 的 WuKong UID 广播一条
  /// `type=98` 自定义内容; 客户端 SDK 解码后, controller 用它把原消息替成 tombstone,
  /// notify 本身**不上屏**。
  static const int revokeNotifyContentType = 98;

  /// F09 消息级已读回执实时刷新信号。
  ///
  /// 服务端以 WuKong no_persist 自定义消息广播,客户端必须旁路消费,不得渲染到聊天列表。
  static const int readReceiptSignalContentType = 1002;

  static String _channelKey(String channelId, int channelType) =>
      '$channelType:$channelId';

  @override
  String? get connectedUid => _loggedInUid;

  @override
  ImConnectionStatus get connectionStatus => _connectionStatus;

  @override
  bool get isRealtimeConnected => _connectionStatus.isConnected;

  @override
  Stream<ImConnectionStatus> listenConnectionStatus() =>
      _connectionController.stream;

  @override
  Future<void> init() async {
    if (_inited) return;
    // Windows/Linux 没有 sqflite 的 Darwin 原生插件，才使用 FFI。macOS
    // 保留其原生工厂，避免替换进程级 databaseFactory 影响其他库。
    if (usesWukongFfiDatabaseFactory(
      isWindows: Platform.isWindows,
      isLinux: Platform.isLinux,
    )) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // FFI 默认目录不适合桌面包；显式使用应用沙盒内可写的目录。
      final appSupportDir = await getApplicationSupportDirectory();
      databaseFactoryFfi.setDatabasesPath(appSupportDir.path);
    }
    WKIM.shared.runMode = Model.app;
    // Local disk decoding is also needed before SDK setup/login.
    WKIM.shared.messageManager.registerMsgContent(WkMessageContentType.text,
        (dynamic data) => MentionTextContent('')
            .decodeJson((data as Map).cast<String, dynamic>()));
    WKIM.shared.messageManager.registerMsgContent(WkMessageContentType.image,
        (dynamic data) => WKImageContent(0, 0)
            .decodeJson((data as Map).cast<String, dynamic>()));
    // 注册自定义「文件」消息内容（type=8；SDK 无内置 WKFileContent）。
    // 图片(type=2)用 SDK 内置 WKImageContent，无需注册。
    WKIM.shared.messageManager.registerMsgContent(
      WkMessageContentType.file,
      (dynamic data) =>
          WkFileContent().decodeJson((data as Map).cast<String, dynamic>()),
    );
    // EasyO 富内容 mixed 消息(type=110):一个消息内按顺序承载 text/image/file blocks。
    WKIM.shared.messageManager.registerMsgContent(
      _mixedContentType,
      (dynamic data) =>
          WkMixedContent().decodeJson((data as Map).cast<String, dynamic>()),
    );
    // EasyO agent-direct 最终回复(type=111):WuKong 存结构化 markdown final,
    // SSE 仍只承载执行过程。
    WKIM.shared.messageManager.registerMsgContent(
      agentFinalContentType,
      (dynamic data) => WkAgentFinalContent()
          .decodeJson((data as Map).cast<String, dynamic>()),
    );
    // F16 RTC 通话控制信令(type=1001, spec v0.6.4 §6.2.6 D14):
    // 1001 是 WuKong content type, **不是** channel type;
    // 服务端 wukongwh.MuxSink 把它路由到 CallSignalSink, **不**触发 @Agent 链路。
    WKIM.shared.messageManager.registerMsgContent(
      kRtcCallSignalContentType,
      (dynamic data) => WkRtcCallSignalContent()
          .decodeJson((data as Map).cast<String, dynamic>()),
    );
    // F09 P1 撤回通知(type=98): controller 收到后把原消息替成 tombstone,本身不上屏。
    WKIM.shared.messageManager.registerMsgContent(
      revokeNotifyContentType,
      (dynamic data) => WkRevokeNotifyContent()
          .decodeJson((data as Map).cast<String, dynamic>()),
    );
    // F09 已读回执刷新信号(type=1002):WuKong no_persist 临时消息。
    // 它只触发本地 receipt controller 刷新,不进入普通消息流/历史列表。
    WKIM.shared.messageManager.registerMsgContent(
      readReceiptSignalContentType,
      (dynamic data) => WkReadReceiptSignalContent()
          .decodeJson((data as Map).cast<String, dynamic>()),
    );
    // EasyO 的聊天媒体在调用 SDK 前已经通过 message-files / chat_media_ref 上传完成,
    // payload 内放的是受保护的 Bus URL。WuKong SDK 对 WKMediaMessageContent 会等待
    // app 层 uploadAttachment 回调;这里直接放行已有 URL,否则图片只会插入本地 pending,
    // 不会真正发包,气泡会一直显示发送中。
    WKIM.shared.messageManager.addOnUploadAttachmentListener((m, back) {
      final c = m.messageContent;
      if (c is WKMediaMessageContent && c.url.trim().isNotEmpty) {
        back(true, m);
      } else {
        back(false, m);
      }
    });
    _inited = true;
  }

  @override
  Future<void> login(ImConnInfo info) async {
    final beforeInit = _identityGeneration;
    await init();
    if (beforeInit != _identityGeneration) return;
    final partition = _databasePartition;
    // 幂等:同 uid **且同 token** 已 setup 过则跳过(避免每次切会话重 setup → 重连)。
    // token 变化(P1 凭证刷新:同 uid 新 token)必须重新 setup,否则新 token 不生效。
    if (_loggedInUid == info.uid &&
        _cachePartition == partition &&
        _loggedInToken == info.token &&
        _loggedInDeviceID == info.deviceID &&
        _loggedInDeviceFlag == info.deviceFlag) {
      await _ensureLocalSchemaReady();
      _ensureListener();
      return;
    }
    final generation = ++_identityGeneration;
    // setup 会替换 SDK 的全局 options。若旧账号/旧 token 仍有活跃 socket，必须
    // 先让旧 connection generation 失效再 setup；否则新凭证可能被幂等 connect
    // 判为“已连接”而没有真正发出新的 CONNECT 包。
    if (_loggedInUid != null) {
      await WKIM.shared.connectionManager.disconnect(false);
      if (generation != _identityGeneration) return;
    }
    // PaaS/企业网络优先走 WS/WSS:它能复用 HTTP(S) 网关、Nginx 与标准端口。
    // 本地开发或未下发 ws_addr 时回退到原 TCP host:port;两者都不能是 :5001 特权口。
    final connectAddr = _selectConnectAddr(info);
    final options = Options.newDefault(
      info.uid,
      info.token,
      addr: connectAddr,
      dbSuffix: '_$partition',
      deviceID: info.deviceID.trim().isEmpty ? null : info.deviceID.trim(),
    )..deviceFlag = info.deviceFlag;
    if (Platform.isMacOS) {
      await _migrateLegacyMacDatabaseIfNeeded(info.uid);
      if (generation != _identityGeneration) return;
    }
    final setupOk = await WKIM.shared.setup(options);
    if (generation != _identityGeneration) return;
    if (!setupOk) {
      throw StateError('WuKong setup failed');
    }
    WKIM.shared.messageManager.registerMsgContent(
      WkMessageContentType.text,
      (dynamic data) => MentionTextContent('')
          .decodeJson((data as Map).cast<String, dynamic>()),
    );
    await _ensureLocalSchemaReady();
    if (generation != _identityGeneration) return;
    _cachePartition = partition;
    _loggedInUid = info.uid;
    _loggedInToken = info.token;
    _loggedInDeviceID = info.deviceID;
    _loggedInDeviceFlag = info.deviceFlag;
    _ensureListener();
  }

  String _selectConnectAddr(ImConnInfo info) {
    final wsAddr = info.wsAddr.trim();
    if (wsAddr.startsWith('ws://') || wsAddr.startsWith('wss://')) {
      return wsAddr;
    }
    final tcpAddr = info.tcpAddr.trim();
    if (tcpAddr.isNotEmpty) return tcpAddr;
    throw StateError('WuKong connection address missing');
  }

  Future<void> _migrateLegacyMacDatabaseIfNeeded(String uid) async {
    try {
      final migrated = await migrateLegacyMacWukongDatabase(
        legacyDirectory: await getApplicationSupportDirectory(),
        nativeDirectory: Directory(await getDatabasesPath()),
        uid: uid,
      );
      if (migrated) {
        debugPrint('[WuKongIM] macOS local database migration completed');
      }
    } catch (error) {
      // Local cache migration is best effort: the server remains the message
      // timeline authority. Do not expose paths, uid, or database contents.
      debugPrint(
        '[WuKongIM] macOS local database migration failed '
        'type=${error.runtimeType}',
      );
    }
  }

  Future<void> _ensureLocalSchemaReady() {
    return ensureWukongLocalSchema();
  }

  Future<void> _sendWithOption(
    WKMessageContent content,
    String channelId,
    int channelType,
  ) async {
    await _ensureLocalSchemaReady();
    await WKIM.shared.messageManager.sendWithOption(
      content,
      WKChannel(channelId, channelType),
      WKSendOptions(),
    );
  }

  void _ensureListener() {
    if (_listening) return;
    WKIM.shared.messageManager.addOnNewMsgListener(_listenerKey,
        (List<WKMsg> msgs) {
      if (_msgController.isClosed) return;
      for (final m in msgs) {
        if (_dispatchIfReadReceiptSignal(m)) continue;
        if (_dispatchIfRtcSignal(m)) continue;
        _msgController.add(_toImMessage(m));
      }
    });
    // 本端发送时 SDK 立即插入一条 loading 回显(pending,已带真实 clientMsgNo)。
    // 经同一条消息流到 controller(右侧 upsert 上屏)与 bridge(左侧预览/置顶,fromSelf 不加未读)。
    WKIM.shared.messageManager.addOnMsgInsertedListener((WKMsg m) {
      if (_msgController.isClosed) return;
      if (_dispatchIfReadReceiptSignal(m)) return;
      if (_dispatchIfRtcSignal(m)) return;
      _msgController.add(_toImMessage(m));
    });
    // ack / 失败等状态刷新(同一 clientMsgNo,填上真实 messageId/messageSeq、status→success/fail;
    // 也包含已读回执/反应等)。标记 isRefresh:true:controller 仍走 _upsert 对账 pending→sent/failed,
    // 但 bridge 跳过(不把刷新当新消息加未读/置顶)。
    WKIM.shared.messageManager.addOnRefreshMsgListener(_refreshListenerKey,
        (WKMsg m) {
      if (_msgController.isClosed) return;
      if (_dispatchIfReadReceiptSignal(m)) return;
      if (_dispatchIfRtcSignal(m)) return;
      _msgController.add(_toImMessage(m, isRefresh: true));
    });
    // ADR-0026: 历史/离线同步 provider。SDK 需要拉服务端历史时回调此处,
    // 经 agent-bus 代理(不直连 :5001),拿到后转成 WKSyncChannelMsg 交还 SDK。
    WKIM.shared.messageManager.addOnSyncChannelMsgListener((channelID,
        channelType,
        startMessageSeq,
        endMessageSeq,
        limit,
        pullMode,
        back) async {
      try {
        final generation = _identityGeneration;
        final res = await _syncApi.sync(
          channelId: channelID,
          channelType: channelType,
          startMessageSeq: startMessageSeq,
          endMessageSeq: endMessageSeq,
          limit: limit,
          pullMode: pullMode,
          conversationUuid: _historyConversationByChannel[
              _channelKey(channelID, channelType)],
        );
        if (generation != _identityGeneration) {
          back(null);
          return;
        }
        back(_toSyncChannelMsg(res));
      } catch (_) {
        back(null);
      }
    });
    // P1 会话级事件:只接**非每条消息**的会话变化作为左侧列表 refresh 触发器。
    // 会话删除(本端/多端)→ deleted;清空所有红点 → unreadChanged(无 channelID = 全局)。
    // **不**接 addOnRefreshMsgList*(每条消息保存都会触发,等价"每条 refresh");
    // **不**把 SDK 本地 unread/redDot 当业务真相,事件只用于触发 /chat/conversations 权威刷新。
    WKIM.shared.conversationManager.addOnDeleteMsgListener(
      _convEventListenerKey,
      (String channelID, int channelType) {
        if (_convEventController.isClosed) return;
        _convEventController.add(ImConversationEvent(
          kind: ImConversationEventKind.deleted,
          channelId: channelID,
          channelType: channelType,
        ));
      },
    );
    WKIM.shared.conversationManager.addOnClearAllRedDotListener(
      _convEventListenerKey,
      () {
        if (_convEventController.isClosed) return;
        _convEventController.add(const ImConversationEvent(
          kind: ImConversationEventKind.unreadChanged,
        ));
      },
    );
    _listening = true;
    _ensureConnectionListener();
  }

  void _ensureConnectionListener() {
    if (_connectionListening) return;
    WKIM.shared.connectionManager.addOnConnectionStatus(
      _connectionListenerKey,
      (int status, int? reasonCode, dynamic info) {
        if (_loggedInUid == null) return;
        final mapped = _mapConnectionStatus(status);
        debugPrint(
            '[WukongImClient] connection status raw=$status mapped=$mapped reason=$reasonCode info=${_safeConnectionInfo(info)}');
        _setConnectionStatus(mapped);
      }
    );
    _connectionListening = true;
  }

  String _safeConnectionInfo(dynamic info) {
    if (info == null) return '';
    final text = info.toString();
    if (text.length <= 160) return text;
    return '${text.substring(0, 160)}...';
  }

  ImConnectionStatus _mapConnectionStatus(int status) {
    switch (status) {
      case WKConnectStatus.success:
      case WKConnectStatus.syncMsg:
      case WKConnectStatus.syncCompleted:
        return ImConnectionStatus.connected;
      case WKConnectStatus.connecting:
        return ImConnectionStatus.connecting;
      case WKConnectStatus.noNetwork:
        return ImConnectionStatus.noNetwork;
      case WKConnectStatus.kicked:
        return ImConnectionStatus.kicked;
      case WKConnectStatus.fail:
      default:
        return ImConnectionStatus.disconnected;
    }
  }

  void _setConnectionStatus(ImConnectionStatus status) {
    if (_connectionStatus == status) return;
    _connectionStatus = status;
    if (!_connectionController.isClosed) {
      _connectionController.add(status);
    }
  }

  WKSyncChannelMsg _toSyncChannelMsg(WukongSyncResult res) {
    final out = WKSyncChannelMsg();
    out.startMessageSeq = res.startMessageSeq;
    out.endMessageSeq = res.endMessageSeq;
    out.more = res.more;
    out.messages = res.messages.map((m) {
      final s = WKSyncMsg();
      s.messageID = m.messageId;
      s.messageSeq = m.messageSeq;
      s.clientMsgNO = m.clientMsgNo;
      s.fromUID = m.fromUid;
      s.channelID = m.channelId;
      s.channelType = m.channelType;
      s.timestamp = m.timestamp;
      s.payload = m.payload;
      return s;
    }).toList();
    return out;
  }

  @override
  Future<void> connect() async {
    if (_loggedInUid == null) return;
    _ensureConnectionListener();
    WKIM.shared.connectionManager.connect();
  }

  @override
  Future<void> disconnect() async {
    await WKIM.shared.connectionManager.disconnect(false);
    _setConnectionStatus(ImConnectionStatus.disconnected);
  }

  @override
  Future<void> logout() async {
    _identityGeneration++;
    _cachePartition = null;
    _loggedInUid = null;
    _loggedInToken = null;
    _loggedInDeviceID = null;
    _loggedInDeviceFlag = null;
    _setConnectionStatus(ImConnectionStatus.idle);
    await WKIM.shared.connectionManager.disconnect(true);
  }

  /// Evict only the current business identity's SDK cache, including offline use.
  Future<void> clearCurrentHistoryCache() async {
    final identity = await WukongSessionIdentity.current();
    if (identity == null ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(identity.uid)) {
      return;
    }
    final partition = _databasePartition;
    await init();
    // Invalidate old sync callbacks and stop incoming writes before eviction.
    await logout();
    final factory = databaseFactory;
    final directory = await factory.getDatabasesPath();
    final path = '$directory${Platform.pathSeparator}wk_${identity.uid}_$partition.db';
    if (!await factory.databaseExists(path)) return;
    final db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await clearWukongCachedRows(db);
    } finally {
      await db.close();
    }
  }

  @override
  Future<List<ImConversation>> getConversationList() async {
    final list = await WKIM.shared.conversationManager.getAll();
    return list
        .map((c) => ImConversation(
              channelId: c.channelID,
              channelType: c.channelType,
              unreadCount: c.unreadCount,
              lastMsgTimestamp: c.lastMsgTimestamp,
            ))
        .toList();
  }

  static String get _databasePartition =>
      '${AppConfig.env.name}_${sha256.convert(utf8.encode(AppConfig.apiUrl())).toString().substring(0, 16)}';

  @override
  Future<ImLocalHistory?> readLocalHistory(
      String channelId, int channelType, {int limit = 40}) async {
    final scope = await ChatCacheScope.current();
    final identity = await WukongSessionIdentity.current();
    if (scope == null || identity == null ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(identity.uid)) {
      return null;
    }
    final partition = _databasePartition;
    await init();
    final factory = databaseFactory;
    final directory = await factory.getDatabasesPath();
    final path = '$directory${Platform.pathSeparator}wk_${identity.uid}_$partition.db';
    if (!await factory.databaseExists(path)) return null;
    // A separate read-only handle cannot replace or close the live SDK handle.
    final db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    List<Map<String, Object?>> rows;
    try {
      final message = WKDBConst.tableMessage;
      final extra = WKDBConst.tableMessageExtra;
      rows = await db.rawQuery(
          'SELECT ${MessageDB.shared.messageCols},${MessageDB.shared.extraCols} '
          'FROM $message LEFT JOIN $extra ON $message.message_id=$extra.message_id '
          'WHERE $message.channel_id=? AND $message.channel_type=? '
          'AND $message.type NOT IN (0,99,1001,1002) '
          'AND $message.is_deleted=0 AND IFNULL($extra.is_mutual_deleted,0)=0 '
          'ORDER BY $message.order_seq DESC LIMIT ?',
          [channelId, channelType, limit]);
    } finally {
      await db.close();
    }
    if (!await scope.isCurrent() || partition != _databasePartition ||
        (await WukongSessionIdentity.current())?.uid != identity.uid) {
      return null;
    }
    final messages = rows.reversed.map((row) {
      final message = WKDBConst.serializeWKMsg(row);
      final decoded = _toImMessage(message, localUid: identity.uid);
      return message.wkMsgExtra?.revoke == 1 ? decoded.withRevoked() : decoded;
    }).toList();
    debugPrint('[chat-cold-cache] disk hit messages=${messages.length}');
    return (uid: identity.uid, messages: messages);
  }

  @override
  Future<List<ImMessage>> getHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    int beforeMessageSeq = 0,
    String? conversationUuid,
    String? clearedAt,
  }) =>
      _getHistoryMessages(
        channelId,
        channelType,
        limit: limit,
        beforeMessageSeq: beforeMessageSeq,
        conversationUuid: conversationUuid,
        forceRemoteLatest: false,
      );

  @override
  Future<List<ImMessage>> syncLatestHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    String? conversationUuid,
    String? clearedAt,
  }) async {
    final generation = _identityGeneration;
    if (conversationUuid != null && conversationUuid.isNotEmpty) {
      _historyConversationByChannel[_channelKey(channelId, channelType)] =
          conversationUuid;
    }
    final cursor = await WKIM.shared.messageManager
        .getMaxMessageSeq(channelId, channelType);
    if (cursor <= 0) {
      return _getHistoryMessages(channelId, channelType,
          limit: limit,
          conversationUuid: conversationUuid,
          forceRemoteLatest: true);
    }
    return loadIncrementalHistory<ImMessage>(
        afterSeq: cursor,
        fetch: (after) async {
          if (generation != _identityGeneration) throw StateError('聊天账号已切换');
          final completed = Completer<WKSyncChannelMsg>();
          // This SDK entry point saves the returned page in its existing SQLite
          // timeline before completing. No second copy of the IM timeline is made.
          WKIM.shared.messageManager.setSyncChannelMsgListener(
              channelId, channelType, after, 0, 100, 1, (page) {
            if (page == null) {
              completed.completeError(StateError('聊天增量同步失败'));
            } else {
              completed.complete(page);
            }
          });
          final page =
              await completed.future.timeout(const Duration(seconds: 20));
          if (generation != _identityGeneration) throw StateError('聊天账号已切换');
          final raw = page.messages ?? <WKSyncMsg>[];
          var last = after;
          final result = <ImMessage>[];
          for (final item in raw) {
            if (item.messageSeq > last) last = item.messageSeq;
            final message = item.getWKMsg();
            if (message.contentType == readReceiptSignalContentType ||
                message.messageContent is WkRtcCallSignalContent ||
                message.messageContent is WkReadReceiptSignalContent) {
              continue;
            }
            if (item.messageSeq > after) result.add(_toImMessage(message));
          }
          return HistoryDeltaPage(
              result, last, page.more == 1 || raw.length >= 100);
        });
  }

  Future<List<ImMessage>> _getHistoryMessages(
    String channelId,
    int channelType, {
    required int limit,
    int beforeMessageSeq = 0,
    String? conversationUuid,
    required bool forceRemoteLatest,
  }) async {
    final conv = conversationUuid?.trim() ?? '';
    if (conv.isNotEmpty) {
      _historyConversationByChannel[_channelKey(channelId, channelType)] = conv;
    }
    // 分页(P1):beforeMessageSeq=0 → oldestOrderSeq=0 拉最新一页(现状);
    // >0 → oldestOrderSeq=messageSeq×factor、contain=false、pullMode=0(向更早方向,
    // order_seq < 锚点,必要时经 agent-bus 同步代理补;到第一条 messageSeq=1 时返回空)。
    final factor = WKIM.shared.messageManager.wkOrderSeqFactor;
    final oldestOrderSeq = beforeMessageSeq > 0 ? beforeMessageSeq * factor : 0;
    final contain = beforeMessageSeq <= 0; // 最新页含锚点;更早页排除锚点本身

    return waitForWukongHistory<ImMessage>(
      start: (completeWithMessages, onRemoteSyncStarted) {
        WKIM.shared.messageManager.getOrSyncHistoryMessages(
          channelId,
          channelType,
          oldestOrderSeq,
          contain,
          0, // pullMode=0:向更早方向
          limit,
          0, // aroundMsgOrderSeq
          (List<WKMsg> msgs) {
            // F16: 历史同步里也可能夹带 1001 信令(理论上不会落历史, 但 SDK 不保证), 跳过避免空气泡。
            final latest = msgs
                .where((m) =>
                    m.contentType != readReceiptSignalContentType &&
                    m.messageContent is! WkRtcCallSignalContent &&
                    m.messageContent is! WkReadReceiptSignalContent)
                .map(_toImMessage)
                .toList();
            // 拿到结果即完成; 不能在 syncBack 完成,它只是"远端同步已开始"。
            completeWithMessages(latest);
          },
          onRemoteSyncStarted,
          forceRemoteLatest,
        );
      },
    );
  }

  @override
  Future<void> sendTextMessage(
    String channelId,
    int channelType,
    String text, {
    List<Map<String, dynamic>>? mentions,
  }) async {
    // 有结构化 @ 时发 MentionTextContent(payload 多带 mentions, type 仍=1 文本),
    // 后端 metadata 优先触发;否则发普通 WKTextContent。
    final content = (mentions != null && mentions.isNotEmpty)
        ? MentionTextContent(text, mentions)
        : WKTextContent(text);
    await _sendWithOption(content, channelId, channelType);
  }

  @override
  Future<void> sendImageMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    String refUuid = '',
    String name = '',
    int width = 0,
    int height = 0,
  }) async {
    final content = WkMixedContent()
      ..blocks = [
        ImMessageBlock(
          kind: ImMessageBlockKind.image,
          url: url,
          fileUuid: fileUuid,
          refUuid: refUuid,
          name: name,
          width: width,
          height: height,
        ),
      ]
      ..summary = name.trim().isNotEmpty ? name.trim() : '[图片]';
    await _sendWithOption(content, channelId, channelType);
  }

  @override
  Future<void> sendFileMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    required String refUuid,
    required String name,
    int size = 0,
    String mime = '',
  }) async {
    final content = WkFileContent()
      ..url = url
      ..name = name
      ..size = size
      ..mime = mime
      ..fileUuid = fileUuid
      ..refUuid = refUuid;
    await _sendWithOption(content, channelId, channelType);
  }

  @override
  Future<void> sendMixedMessage(
    String channelId,
    int channelType, {
    required List<ImMessageBlock> blocks,
    String summary = '',
    List<Map<String, dynamic>>? mentions,
    Map<String, dynamic>? reply,
  }) async {
    final content = WkMixedContent()
      ..blocks = blocks
      ..summary = summary.trim().isNotEmpty
          ? summary.trim()
          : WkMixedContent.summaryOf(blocks)
      ..mentions = mentions ?? const <Map<String, dynamic>>[]
      ..replyMeta = (reply != null && reply.isNotEmpty) ? reply : null;
    await _sendWithOption(content, channelId, channelType);
  }

  @override
  Stream<ImMessage> listenMessages() => _msgController.stream;

  @override
  Stream<ImConversationEvent> listenConversationEvents() =>
      _convEventController.stream;

  @override
  Stream<ImReadReceiptSignal> listenReadReceiptSignals() =>
      _readReceiptSignalController.stream;

  @override
  Future<int> unreadCount() async {
    return WKIM.shared.conversationManager.getAllUnreadCount();
  }

  @override
  Future<void> markRead(String channelId, int channelType) async {
    await WKIM.shared.conversationManager
        .updateRedDot(channelId, channelType, 0);
  }

  @override
  Future<void> dispose() async {
    WKIM.shared.connectionManager
        .removeOnConnectionStatus(_connectionListenerKey);
    WKIM.shared.messageManager.removeNewMsgListener(_listenerKey);
    WKIM.shared.messageManager.removeOnRefreshMsgListener(_refreshListenerKey);
    WKIM.shared.conversationManager
        .removeDeleteMsgListener(_convEventListenerKey);
    WKIM.shared.conversationManager
        .removeClearAllRedDotListener(_convEventListenerKey);
    _connectionListening = false;
    _listening = false;
    if (!_msgController.isClosed) {
      await _msgController.close();
    }
    if (!_connectionController.isClosed) {
      await _connectionController.close();
    }
    if (!_convEventController.isClosed) {
      await _convEventController.close();
    }
    if (!_rtcSignalController.isClosed) {
      await _rtcSignalController.close();
    }
    if (!_readReceiptSignalController.isClosed) {
      await _readReceiptSignalController.close();
    }
  }

  /// 把 WKMsg.status 映射成中立发送状态(WuKong 为权威)。
  /// 他人消息(fromUID != 自己)在我们视角恒为「已送达」= sent;
  /// 自己的消息:loading(0)→pending、success(1)→sent、其余(fail/noRelation/blackList/...)→failed。
  ImSendStatus _toSendStatus(WKMsg m, {String? localUid}) {
    final uid = localUid ?? _loggedInUid;
    final isOwn = uid != null && m.fromUID == uid;
    if (!isOwn) return ImSendStatus.sent;
    switch (m.status) {
      case WKSendMsgResult.sendSuccess:
        return ImSendStatus.sent;
      case WKSendMsgResult.sendLoading:
        return localUid == null ? ImSendStatus.pending : ImSendStatus.failed;
      default:
        return ImSendStatus.failed;
    }
  }

  String _sendErrorMessage(WKMsg m, {String? localUid}) {
    if (_toSendStatus(m, localUid: localUid) != ImSendStatus.failed) return '';
    switch (m.status) {
      case WKSendMsgResult.noRelation:
        return '你们还未建立会话';
      case WKSendMsgResult.blackList:
        return '已被对方拉黑';
      case WKSendMsgResult.notOnWhiteList:
        return '不在对方白名单';
      default:
        return '发送失败';
    }
  }

  /// F16 RTC 控制信令(type=1001)旁路 stream, 给 lib/rtc/signaling_listener.dart 订阅。
  Stream<RtcCallSignalIncoming> listenRtcCallSignals() =>
      _rtcSignalController.stream;

  /// F16 spec v0.6.4 §6.2.6 D14:
  /// 截获 type=1001 信令, 路由到旁路 stream, 不让它进 _msgController(聊天 UI 不渲染)。
  /// 返回 true 表示**已**被信令旁路处理, 调用方应跳过常规消息派发。
  bool _dispatchIfRtcSignal(WKMsg m) {
    final c = rtcSignalContentFromWukongFields(
      contentType: m.contentType,
      content: m.content,
      messageContent: m.messageContent,
    );
    if (c == null) return false;
    debugPrint(
      '[F16 RTC] dispatch signal event=${rtcCallSignalEventName(c.event)} '
      'messageId=${m.messageID} from=${m.fromUID} channel=${m.channelID} '
      'channelType=${m.channelType} data=${c.data}',
    );
    if (_rtcSignalController.isClosed) return true;
    _rtcSignalController.add(RtcCallSignalIncoming(
      messageId: m.messageID,
      fromUid: m.fromUID,
      channelId: m.channelID,
      channelType: m.channelType,
      timestamp: m.timestamp,
      event: c.event,
      data: c.data,
    ));
    return true;
  }

  bool _dispatchIfReadReceiptSignal(WKMsg m) {
    final c = _readReceiptSignalContentFrom(m);
    if (c == null) return m.contentType == readReceiptSignalContentType;
    if (_readReceiptSignalController.isClosed) return true;
    if (c.conversationUuid.isEmpty || c.lastReadMessageSeq <= 0) return true;
    _readReceiptSignalController.add(ImReadReceiptSignal(
      conversationUuid: c.conversationUuid,
      lastReadMessageSeq: c.lastReadMessageSeq,
      readerUid: c.readerUid,
      channelId: m.channelID,
      channelType: m.channelType,
      timestamp: m.timestamp,
    ));
    return true;
  }

  WkReadReceiptSignalContent? _readReceiptSignalContentFrom(WKMsg m) {
    final decoded = m.messageContent;
    if (decoded is WkReadReceiptSignalContent) return decoded;
    if (m.contentType != readReceiptSignalContentType) return null;
    final raw = m.content.trim();
    if (raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is Map) {
        return WkReadReceiptSignalContent()
                .decodeJson(v.cast<String, dynamic>())
            as WkReadReceiptSignalContent;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  ImMessage _toImMessage(WKMsg m, {bool isRefresh = false, String? localUid}) {
    var text = '';
    var mediaKind = ImMediaKind.none;
    var mediaUrl = '';
    var mediaName = '';
    var mediaSize = 0;
    var mediaMime = '';
    var mediaFileUuid = '';
    var mediaRefUuid = '';
    var mediaWidth = 0;
    var mediaHeight = 0;
    var blocks = const <ImMessageBlock>[];
    var empBlocks = const <Map<String, dynamic>>[];
    var agentStreamId = '';
    var agentMessageUuid = '';
    var agentMessageStatus = '';
    var mentions = const <Map<String, dynamic>>[];
    var notificationTitle = '';
    var notificationBody = '';
    Map<String, dynamic>? replyRefJson;

    final c = m.messageContent;
    if (c is WKTextContent) {
      text = c.content;
      if (c is MentionTextContent) mentions = c.mentions;
      final notificationMeta = _textNotificationMeta(m);
      notificationTitle = notificationMeta.title;
      notificationBody = notificationMeta.body;
    } else if (c is WKImageContent) {
      mediaKind = ImMediaKind.image;
      mediaUrl = c.url;
      mediaWidth = c.width;
      mediaHeight = c.height;
      text = '[图片]';
    } else if (c is WkFileContent) {
      mediaKind = ImMediaKind.file;
      mediaUrl = c.url;
      mediaName = c.name;
      mediaSize = c.size;
      mediaMime = c.mime;
      mediaFileUuid = c.fileUuid; // 底层 drive_files.uuid
      mediaRefUuid = c.refUuid; // chat media ref(URL 用)
      text = c.name.isNotEmpty ? c.name : '[文件]';
    } else if (c is WkMixedContent) {
      blocks = c.blocks;
      mentions = c.mentions;
      text =
          c.summary.isNotEmpty ? c.summary : WkMixedContent.summaryOf(c.blocks);
      // F09 引用回复 v1: mixed 顶层 reply payload 透传到 ImMessage 供气泡渲染.
      replyRefJson = c.replyMeta;
      // 若 mixed 内**仅含**单一图片/文件 block, 把媒体字段也填到 ImMessage 顶层,
      // 让既有 image / file 气泡渲染逻辑可处理"带引用的图片/文件";不影响纯文本 mixed.
      if (blocks.length == 1) {
        final b = blocks.first;
        if (b.isImage) {
          mediaKind = ImMediaKind.image;
          mediaUrl = b.url;
          mediaName = b.name;
          mediaFileUuid = b.fileUuid;
          mediaRefUuid = b.refUuid;
          mediaWidth = b.width;
          mediaHeight = b.height;
        } else if (b.isFile) {
          mediaKind = ImMediaKind.file;
          mediaUrl = b.url;
          mediaName = b.name;
          mediaSize = b.size;
          mediaMime = b.mime;
          mediaFileUuid = b.fileUuid;
          mediaRefUuid = b.refUuid;
        }
      }
    } else if (c is WkAgentFinalContent) {
      blocks = c.blocks;
      empBlocks = c.empBlocks;
      agentStreamId = c.streamId;
      agentMessageUuid = c.agentMessageUuid;
      agentMessageStatus = c.agentMessageStatus;
      mentions = c.mentions;
      text = c.displayText();
    } else if (c is WkRevokeNotifyContent) {
      // F09 P1: type=98 撤回通知, 不上屏, 由 controller 用 revokedMessageId/ClientMsgNo
      // 找原消息替成 tombstone。
      return ImMessage(
        messageId: m.messageID,
        clientMsgNo: m.clientMsgNO,
        fromUid: m.fromUID,
        channelId: m.channelID,
        channelType: m.channelType,
        timestamp: m.timestamp,
        text: '',
        messageSeq: m.messageSeq,
        sendStatus: _toSendStatus(m, localUid: localUid),
        errorMessage: '',
        isRefresh: isRefresh,
        isRevokeNotify: true,
        revokedMessageId: c.revokedMessageId,
        revokedClientMsgNo: c.revokedClientMsgNo,
      );
    }
    return ImMessage(
      messageId: m.messageID,
      clientMsgNo: m.clientMsgNO,
      fromUid: m.fromUID,
      channelId: m.channelID,
      channelType: m.channelType,
      timestamp: m.timestamp,
      text: text,
      notificationTitle: notificationTitle,
      notificationBody: notificationBody,
      messageSeq: m.messageSeq,
      sendStatus: _toSendStatus(m, localUid: localUid),
      errorMessage: _sendErrorMessage(m, localUid: localUid),
      isRefresh: isRefresh,
      mediaKind: mediaKind,
      mediaUrl: mediaUrl,
      mediaName: mediaName,
      mediaSize: mediaSize,
      mediaMime: mediaMime,
      mediaFileUuid: mediaFileUuid,
      mediaRefUuid: mediaRefUuid,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      blocks: blocks,
      empBlocks: empBlocks,
      agentStreamId: agentStreamId,
      agentMessageUuid: agentMessageUuid,
      agentMessageStatus: agentMessageStatus,
      mentions: mentions,
      replyRefJson: replyRefJson,
    );
  }

  ({String title, String body}) _textNotificationMeta(WKMsg m) {
    final raw = m.content.trim();
    if (raw.isEmpty) return (title: '', body: '');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return (title: '', body: '');
      final payload = decoded.cast<String, dynamic>();
      return (
        title: (payload['notification_title'] ?? '').toString().trim(),
        body: (payload['notification_body'] ?? '').toString().trim(),
      );
    } catch (_) {
      return (title: '', body: '');
    }
  }
}

class MentionTextContent extends WKTextContent {
  MentionTextContent(super.content, [this.mentions = const []]);
  List<Map<String, dynamic>> mentions;

  @override
  Map<String, dynamic> encodeJson() {
    final j = super.encodeJson();
    if (mentions.isNotEmpty) j['mentions'] = mentions;
    return j;
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    super.decodeJson(json);
    final raw = json['mentions'];
    if (raw is List) {
      mentions = raw
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);
    }
    return this;
  }
}

/// 自定义「文件」消息内容（WuKong type=8）。SDK 无内置 WKFileContent，
/// 在 [WukongImClient.init] 通过 `registerMsgContent` 注册解码器。
/// payload：`{url, name, size, mime, file_uuid, ref_uuid}`。
///   - `url`       = `/chat/media/{ref_uuid}/download`(读取走它,Bus 成员鉴权);
///   - `file_uuid` = 底层 drive_files.uuid(溯源/import/去重,**非** URL 用途);
///   - `ref_uuid`  = chat media ref(授权单元;= url 里的那个 uuid)。
/// F09 P1 撤回通知(WuKong type=98)。
///
/// payload: `{type:98, version, revoked_message_id, revoked_client_msg_no?, revoker_uid}`。
/// 服务端在 caller 身份与 sender 校验后用 caller 的 WuKong UID 发出这条消息;
/// 客户端 SDK 解码后, controller 用 (revokedMessageId | revokedClientMsgNo) 找到原消息
/// 替成 `isRevoked=true`,通知本身**不上屏**(由 controller 吞掉)。
///
/// **不**承载消息正文/媒体引用,故撤回后原消息不再泄露内容。
class WkRevokeNotifyContent extends WKMessageContent {
  int version = 1;
  String revokedMessageId = '';
  String revokedClientMsgNo = '';
  String revokerUid = '';

  WkRevokeNotifyContent() {
    contentType = WukongImClient.revokeNotifyContentType;
  }

  @override
  Map<String, dynamic> encodeJson() {
    return {
      'type': WukongImClient.revokeNotifyContentType,
      'version': version,
      'revoked_message_id': revokedMessageId,
      if (revokedClientMsgNo.isNotEmpty)
        'revoked_client_msg_no': revokedClientMsgNo,
      'revoker_uid': revokerUid,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    final v = readInt(json, 'version');
    version = v <= 0 ? 1 : v;
    revokedMessageId = readString(json, 'revoked_message_id');
    revokedClientMsgNo = readString(json, 'revoked_client_msg_no');
    revokerUid = readString(json, 'revoker_uid');
    return this;
  }

  @override
  String displayText() => ''; // 通知不上屏

  @override
  String searchableWord() => '';
}

/// F09 已读回执刷新信号(WuKong type=1002)。
///
/// 服务端通过 no_persist 消息发送;客户端只用它触发 receipt controller 刷新,
/// 不展示、不搜索、不进入普通消息流。
class WkReadReceiptSignalContent extends WKMessageContent {
  int version = 1;
  String kind = 'read_receipt.changed';
  String conversationUuid = '';
  int lastReadMessageSeq = 0;
  String readerUid = '';
  String ts = '';

  WkReadReceiptSignalContent() {
    contentType = WukongImClient.readReceiptSignalContentType;
  }

  @override
  Map<String, dynamic> encodeJson() {
    return {
      'type': WukongImClient.readReceiptSignalContentType,
      'version': version,
      'kind': kind,
      'conversation_uuid': conversationUuid,
      'last_read_message_seq': lastReadMessageSeq,
      'reader_uid': readerUid,
      if (ts.isNotEmpty) 'ts': ts,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    final v = readInt(json, 'version');
    version = v <= 0 ? 1 : v;
    kind = readString(json, 'kind');
    if (kind.isEmpty) kind = 'read_receipt.changed';
    conversationUuid = readString(json, 'conversation_uuid');
    lastReadMessageSeq = readInt(json, 'last_read_message_seq');
    readerUid = readString(json, 'reader_uid');
    ts = readString(json, 'ts');
    return this;
  }

  @override
  String displayText() => '';

  @override
  String searchableWord() => '';
}

class WkFileContent extends WKMessageContent {
  String url = '';
  String name = '';
  int size = 0;
  String mime = '';
  String fileUuid = '';
  String refUuid = '';

  WkFileContent() {
    contentType = WkMessageContentType.file;
  }

  @override
  Map<String, dynamic> encodeJson() {
    return {
      'url': url,
      'name': name,
      'size': size,
      'mime': mime,
      'file_uuid': fileUuid,
      'ref_uuid': refUuid,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    url = readString(json, 'url');
    name = readString(json, 'name');
    size = readInt(json, 'size');
    mime = readString(json, 'mime');
    fileUuid = readString(json, 'file_uuid');
    refUuid = readString(json, 'ref_uuid');
    return this;
  }

  @override
  String displayText() => name.isNotEmpty ? name : '[文件]';

  @override
  String searchableWord() => name.isNotEmpty ? name : '[文件]';
}

/// 自定义「富内容 mixed」消息内容（WuKong type=110）。
/// payload：`{version, summary, blocks:[{type:text|image|file,...}], mentions?}`。
/// 图片/文件 URL 均为 Bus chat_media_ref URL,不含 OSS signed URL / base64。
class WkMixedContent extends WKMessageContent {
  int version = 1;
  String summary = '';
  List<ImMessageBlock> blocks = const <ImMessageBlock>[];
  List<Map<String, dynamic>> mentions = const <Map<String, dynamic>>[];

  /// F09 引用回复 v1: 顶层 `reply` 字段 (与 blocks 并列). 不写入可见正文/Markdown.
  /// null = 普通 mixed 消息; 非空 = 引用了某条原消息.
  ///
  /// 字段名用 `replyMeta` 避开 [WKMessageContent.reply] (SDK 自带 WKReply 强类型字段);
  /// 我们直接走 JSON map, 不引入 SDK reply 类型.
  Map<String, dynamic>? replyMeta;

  WkMixedContent() {
    contentType = WukongImClient._mixedContentType;
  }

  static String summaryOf(List<ImMessageBlock> blocks) {
    final parts = <String>[];
    for (final b in blocks) {
      if (b.isText) {
        final t = b.text.trim();
        if (t.isNotEmpty) parts.add(t);
      } else if (b.isMarkdown) {
        final t = b.text.trim();
        if (t.isNotEmpty) parts.add(t);
      } else if (b.isImage) {
        parts.add('[图片]');
      } else if (b.isFile) {
        parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[文件]');
      } else if (b.isCallEvent) {
        // F16 通话卡片：摘要纳入卡片文案，避免无 summary 的 mixed 卡片显示 [非文本消息]。
        parts.add(b.text.trim().isNotEmpty ? b.text.trim() : '语音通话');
      } else if (b.isForwardRecord) {
        parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[聊天记录]');
      }
    }
    final s = parts.join(' ').trim();
    return s.isNotEmpty ? s : '[非文本消息]';
  }

  @override
  Map<String, dynamic> encodeJson() {
    return {
      'type': WukongImClient._mixedContentType,
      'version': version,
      'summary': summary.isNotEmpty ? summary : summaryOf(blocks),
      'blocks': blocks.map((b) => b.toJson()).toList(growable: false),
      if (mentions.isNotEmpty) 'mentions': mentions,
      if (replyMeta != null && replyMeta!.isNotEmpty) 'reply': replyMeta,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    version = readInt(json, 'version');
    if (version <= 0) version = 1;
    summary = readString(json, 'summary');
    final rawBlocks = json['blocks'];
    if (rawBlocks is List) {
      blocks = rawBlocks
          .whereType<Map>()
          .map((m) => ImMessageBlock.fromJson(m.cast<String, dynamic>()))
          .whereType<ImMessageBlock>()
          .toList(growable: false);
    } else {
      blocks = const <ImMessageBlock>[];
    }
    final rawMentions = json['mentions'];
    if (rawMentions is List) {
      mentions = rawMentions
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList(growable: false);
    } else {
      mentions = const <Map<String, dynamic>>[];
    }
    final rawReply = json['reply'];
    if (rawReply is Map) {
      replyMeta = rawReply.cast<String, dynamic>();
    } else {
      replyMeta = null;
    }
    return this;
  }

  @override
  String displayText() => summary.isNotEmpty ? summary : summaryOf(blocks);

  @override
  String searchableWord() => displayText();
}

/// 自定义「Agent 最终回复」消息内容（WuKong type=111）。
/// payload：`{version, format:"markdown", content, summary, blocks, stream_id, agent_message_uuid, agent_message_status}`。
/// WuKong 保存最终结构化时间线;SSE 仅承载执行过程。
class WkAgentFinalContent extends WKMessageContent {
  int version = 1;
  String format = 'markdown';
  String markdownContent = '';
  String summary = '';
  String streamId = '';
  String agentMessageUuid = '';
  String agentMessageStatus = '';
  List<ImMessageBlock> blocks = const <ImMessageBlock>[];
  List<Map<String, dynamic>> empBlocks = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> mentions = const <Map<String, dynamic>>[];

  WkAgentFinalContent() {
    contentType = WukongImClient.agentFinalContentType;
  }

  @override
  Map<String, dynamic> encodeJson() {
    final encodedBlocks = empBlocks.isNotEmpty
        ? empBlocks
        : blocks.isNotEmpty
            ? blocks
            : [
                if (markdownContent.trim().isNotEmpty)
                  ImMessageBlock(
                    kind: ImMessageBlockKind.markdown,
                    text: markdownContent,
                  )
              ];
    return {
      'type': WukongImClient.agentFinalContentType,
      'version': version,
      'format': format.isNotEmpty ? format : 'markdown',
      'content': markdownContent,
      'summary': displayText(),
      'blocks': encodedBlocks
          .map((b) => b is ImMessageBlock ? b.toJson() : b)
          .toList(growable: false),
      if (streamId.isNotEmpty) 'stream_id': streamId,
      if (agentMessageUuid.isNotEmpty) 'agent_message_uuid': agentMessageUuid,
      if (agentMessageStatus.isNotEmpty)
        'agent_message_status': agentMessageStatus,
      if (mentions.isNotEmpty) 'mentions': mentions,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    version = readInt(json, 'version');
    if (version <= 0) version = 1;
    format = readString(json, 'format');
    if (format.isEmpty) format = 'markdown';
    markdownContent = readString(json, 'content');
    summary = readString(json, 'summary');
    streamId = readString(json, 'stream_id');
    agentMessageUuid = readString(json, 'agent_message_uuid');
    agentMessageStatus = readString(json, 'agent_message_status');
    final rawMentions = json['mentions'];
    if (rawMentions is List) {
      mentions = rawMentions
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    } else {
      mentions = const <Map<String, dynamic>>[];
    }

    final rawBlocks = json['blocks'];
    if (rawBlocks is List) {
      empBlocks = _readRawEmpBlocks(rawBlocks);
      blocks = rawBlocks
          .whereType<Map>()
          .map((m) => ImMessageBlock.fromJson(m.cast<String, dynamic>()))
          .whereType<ImMessageBlock>()
          .toList(growable: false);
    } else if (markdownContent.trim().isNotEmpty) {
      empBlocks = const <Map<String, dynamic>>[];
      blocks = [
        ImMessageBlock(
            kind: ImMessageBlockKind.markdown, text: markdownContent),
      ];
    } else {
      empBlocks = const <Map<String, dynamic>>[];
      blocks = const <ImMessageBlock>[];
    }
    return this;
  }

  /// 只把**真正的 EMP 富内容块**(chart/form/table/tool_result 等 typed block)当 empBlocks；
  /// 普通文本类(没 type / markdown / plain / text)绝不能算进去——口径跟
  /// lib/emp/blocks/emp_block_readable_text.dart 的 _renderOneBlock、
  /// lib/emp/blocks/emp_blocks_view.dart:381 一致。此前这里不分类型把整个 blocks
  /// 数组塞进 empBlocks，导致任何一条普通 markdown 回复都被误判成"带 EMP 富内容"，
  /// ChatAssistantMessageView 走 EMP 专用的 ConstrainedBox 分支把气泡撑成近乎整行宽
  /// (而不是普通气泡走 IntrinsicWidth 贴合内容宽度)。
  List<Map<String, dynamic>> _readRawEmpBlocks(List rawBlocks) {
    const plainTypes = {'', 'markdown', 'plain', 'text'};
    final out = <Map<String, dynamic>>[];
    for (final b in rawBlocks) {
      Map<String, dynamic>? block;
      if (b is Map<String, dynamic>) {
        block = b;
      } else if (b is Map) {
        block = b.map((k, v) => MapEntry(k.toString(), v));
      }
      if (block == null) continue;
      final type = (block['type'] ?? '').toString().trim().toLowerCase();
      if (plainTypes.contains(type)) continue;
      out.add(block);
    }
    return out;
  }

  @override
  String displayText() {
    final s = summary.trim();
    if (s.isNotEmpty) return s;
    final c = markdownContent.trim();
    if (c.isNotEmpty) return c;
    final empText = empBlocksToReadableText(empBlocks).trim();
    if (empText.isNotEmpty) return empText;
    return WkMixedContent.summaryOf(blocks);
  }

  @override
  String searchableWord() => displayText();
}

/// F16 RTC 信令旁路事件 (F16 spec v0.6.4 §6.2.6 D14)。
///
/// 由 [WukongImClient.listenRtcCallSignals] 流出, 给 lib/rtc/signaling_listener.dart 消费。
/// 客户端收到后**仅**用于唤起 RTC 专用来电界面与铃声等 UI 副作用;
/// 通话状态推进仍走 POST /api/agent-bus/v1/calls/* HTTP + 权限闸口 (spec §4.1.0)。
class RtcCallSignalIncoming {
  RtcCallSignalIncoming({
    required this.messageId,
    required this.fromUid,
    required this.channelId,
    required this.channelType,
    required this.timestamp,
    required this.event,
    required this.data,
  });

  /// WuKong 消息 id (per-channel 单调)。
  final String messageId;

  /// 发送者 WuKong UID (形如 `t_{tenant}_u_{account}` 或 `t_{tenant}_a_{agent}`)。
  final String fromUid;

  /// WuKong channel id, 与发起通话所在的 channel 一致。
  final String channelId;

  /// WuKong channel type (1=person, 2=group)。**不**是 content type 1001。
  final int channelType;

  /// WuKong 上报时间 (unix 秒)。
  final int timestamp;

  /// 信令动词 (invite / cancel / accept / reject / end / ringing / unknown)。
  final RtcCallSignalEvent event;

  /// 业务字段 (建议至少含 call_uuid; invite 含 host / kind / room_uuid 等)。
  final Map<String, dynamic> data;
}
