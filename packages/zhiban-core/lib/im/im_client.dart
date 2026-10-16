// ImClient: IM substrate 的客户端抽象(ADR-0026)。
//
// 目的:对话页等业务 UI 只依赖本接口与中立 DTO,**不直接 import WuKong SDK**。
// 便于隔离底层 IM 数据面与业务 UI。
//
// 安全(ADR-0026):ImConnInfo 只含 uid/token/长连接地址,**绝不含 WuKong 特权 :5001**。
library;

/// 客户端连接信息,由 agent-bus `POST /api/agent-bus/v1/im/credentials` 下发。
class ImConnInfo {
  final String substrate; // "wukong"
  final String uid;
  final String token;
  final String tcpAddr; // host:port(WuKong 长连接 TCP)
  final String wsAddr; // ws://host:port

  /// 与业务登录设备一致的稳定标识；新版 Bus 回显，供 WuKong CONNECT 精确关联。
  /// 老 Bus 未下发时为空，由 SDK 继续使用历史本地 DeviceID。
  final String deviceID;

  /// WuKong 设备类别：0=App, 1=Web, 2=Desktop。
  /// 必须使用 Bus 注册 token 时返回的同一个值；老 Bus 未下发时兼容回退 0。
  final int deviceFlag;

  /// 连接凭证建议刷新时刻(UTC,后端 = 签发时刻 + TTL)。null = 未知(不强制刷新)。
  /// 客户端据此提前刷新 token、统一连接状态机(P1)。
  final DateTime? expiresAt;

  const ImConnInfo({
    required this.substrate,
    required this.uid,
    required this.token,
    required this.tcpAddr,
    required this.wsAddr,
    this.deviceID = '',
    this.deviceFlag = 0,
    this.expiresAt,
  });

  /// 是否快过期(提前 5min 视为快过期);[expiresAt] 为空(未知)时返回 false(不强制刷新)。
  bool get isExpiringSoon {
    final e = expiresAt;
    if (e == null) return false;
    return DateTime.now()
        .toUtc()
        .isAfter(e.toUtc().subtract(const Duration(minutes: 5)));
  }

  /// 从 /im/credentials 响应解析 WuKong 段(#18 新增的 `wukong` 字段)。
  /// 返回 null 表示响应未含 wukong(未启用 WuKong)。
  static ImConnInfo? fromCredentialsJson(Map<String, dynamic> json) {
    final wk = json['wukong'];
    if (wk is! Map) return null;
    final m = wk.cast<String, dynamic>();
    final uid = (m['uid'] ?? '').toString();
    final token = (m['token'] ?? '').toString();
    if (uid.isEmpty || token.isEmpty) return null;
    return ImConnInfo(
      substrate: (m['substrate'] ?? 'wukong').toString(),
      uid: uid,
      token: token,
      tcpAddr: (m['tcp_addr'] ?? '').toString(),
      wsAddr: (m['ws_addr'] ?? '').toString(),
      deviceID: (m['device_id'] ?? '').toString(),
      deviceFlag: _parseDeviceFlag(m['device_flag']),
      // P1: 连接凭证 TTL,后端可能未下发(老版本)→ null = 未知不强制刷新。
      expiresAt: DateTime.tryParse((m['expires_at'] ?? '').toString())?.toUtc(),
    );
  }

  static int _parseDeviceFlag(dynamic raw) {
    final parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (parsed == 0 || parsed == 1 || parsed == 2) return parsed!;
    return 0;
  }
}

/// 中立会话 DTO(不暴露任何 SDK 类型)。
class ImConversation {
  final String channelId;
  final int channelType; // 1=person, 2=group
  final int unreadCount;
  final int lastMsgTimestamp;

  const ImConversation({
    required this.channelId,
    required this.channelType,
    required this.unreadCount,
    required this.lastMsgTimestamp,
  });
}

/// 消息媒体类型（P2 WuKong 文件消息）。
enum ImMediaKind { none, image, file }

/// 富内容消息块类型(P1 mixed message):一个 IM message 内按顺序承载文本 / 图片 / 文件 / 技能。
/// markdown 用于 agent-direct 最终回复的结构化 content,客户端可按 EMP/Markdown 渲染。
enum ImMessageBlockKind {
  text,
  markdown,
  image,
  file,
  skill,
  callEvent,
  forwardRecord,
}

/// 富内容消息块(P1 mixed message)。媒体 URL 仍然只放 Bus chat_media_ref 地址,
/// 不放 OSS 签名 URL / base64 / 本地路径。
class ImMessageBlock {
  final ImMessageBlockKind kind;
  final String text;
  final String url;
  final String fileUuid;
  final String refUuid;
  final String skillSlug;
  final String name;
  final int size;
  final String mime;
  final int width;
  final int height;

  /// F16 通话卡片 (kind=callEvent) 的结束原因 (normal/timeout/caller_cancel/callee_reject/...)。
  final String callEndReason;

  const ImMessageBlock({
    required this.kind,
    this.text = '',
    this.url = '',
    this.fileUuid = '',
    this.refUuid = '',
    this.skillSlug = '',
    this.name = '',
    this.size = 0,
    this.mime = '',
    this.width = 0,
    this.height = 0,
    this.callEndReason = '',
  });

  bool get isText => kind == ImMessageBlockKind.text;
  bool get isMarkdown => kind == ImMessageBlockKind.markdown;
  bool get isImage => kind == ImMessageBlockKind.image;
  bool get isFile => kind == ImMessageBlockKind.file;
  bool get isSkill => kind == ImMessageBlockKind.skill;
  bool get isCallEvent => kind == ImMessageBlockKind.callEvent;
  bool get isForwardRecord => kind == ImMessageBlockKind.forwardRecord;

  Map<String, dynamic> toJson() {
    final type = switch (kind) {
      ImMessageBlockKind.text => 'text',
      ImMessageBlockKind.markdown => 'markdown',
      ImMessageBlockKind.image => 'image',
      ImMessageBlockKind.file => 'file',
      ImMessageBlockKind.skill => 'skill',
      ImMessageBlockKind.callEvent => 'call_event',
      ImMessageBlockKind.forwardRecord => 'forward_record',
    };
    return {
      'type': type,
      if (text.isNotEmpty) 'text': text,
      if (url.isNotEmpty) 'url': url,
      if (fileUuid.isNotEmpty) 'file_uuid': fileUuid,
      if (refUuid.isNotEmpty) 'ref_uuid': refUuid,
      if (skillSlug.isNotEmpty) 'slug': skillSlug,
      if (name.isNotEmpty) 'name': name,
      if (size > 0) 'size': size,
      if (mime.isNotEmpty) 'mime': mime,
      if (width > 0) 'width': width,
      if (height > 0) 'height': height,
      if (callEndReason.isNotEmpty) 'end_reason': callEndReason,
    };
  }

  static ImMessageBlock? fromJson(Map<String, dynamic> json) {
    final type = (json['type'] ?? '').toString();
    final kind = switch (type) {
      'text' => ImMessageBlockKind.text,
      'markdown' => ImMessageBlockKind.markdown,
      'image' => ImMessageBlockKind.image,
      'file' => ImMessageBlockKind.file,
      'skill' => ImMessageBlockKind.skill,
      'call_event' => ImMessageBlockKind.callEvent,
      'forward_record' => ImMessageBlockKind.forwardRecord,
      _ => null,
    };
    if (kind == null) return null;
    return ImMessageBlock(
      kind: kind,
      text: (json['text'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      fileUuid: (json['file_uuid'] ?? '').toString(),
      refUuid: (json['ref_uuid'] ?? '').toString(),
      skillSlug: (json['slug'] ?? json['skill_slug'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      size: _readInt(json['size']),
      mime: (json['mime'] ?? '').toString(),
      width: _readInt(json['width']),
      height: _readInt(json['height']),
      callEndReason: (json['end_reason'] ?? '').toString(),
    );
  }

  static int _readInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }
}

/// 发送状态(WuKong 为权威):
/// - [pending] 本端已发出、WuKong 尚未 ack(SDK loading 回显);
/// - [sent] WuKong ack 成功 / 收到的他人消息;
/// - [failed] 发送明确失败(SDK fail,或发送前长连接 ensure 失败)。
enum ImSendStatus { pending, sent, failed }

/// 中立消息 DTO。文本 + 图片/文件（媒体引用 message-files，渲染时按需取签名 URL）。
class ImMessage {
  final String messageId;
  final String clientMsgNo;
  final String fromUid;
  final String channelId;
  final int channelType;
  final int timestamp;
  final String text; // 文本内容(非文本消息为可读回退文案,如 [图片]/文件名)
  final String notificationTitle; // 外部通知标题；为空时用会话标题兜底。
  final String notificationBody; // 外部通知描述；为空时用 text 兜底。

  /// WuKong 服务端消息序号(per-channel 单调;未 ack 的本端消息为 0)。用于排序。
  final int messageSeq;

  /// 发送状态(WuKong 权威)。收到的他人消息默认 [ImSendStatus.sent]。
  final ImSendStatus sendStatus;

  /// 发送失败时的错误信息(仅 [ImSendStatus.failed] 有意义)。
  final String errorMessage;

  /// 该次投递是否为「状态/序号刷新」而非新到达(WuKong `refresh`:ack/已读回执/反应等)。
  /// 控制器对 new 与 refresh 一视同仁走 `_upsert`;但左侧列表 bridge **跳过** refresh,
  /// 避免已读回执/反应等刷新被误当新消息加未读/置顶。
  final bool isRefresh;

  /// 媒体（P2.2c WuKong 文件消息）。none = 纯文本。
  final ImMediaKind mediaKind;
  final String
      mediaUrl; // chat media ref 预览/下载引用(/chat/media/{ref}/...;需 Bearer)
  final String mediaName;
  final int mediaSize;
  final String mediaMime;

  /// 底层 drive_files.uuid(溯源/import/去重);**非** URL 用途。
  final String mediaFileUuid;

  /// chat media ref uuid(授权单元;URL 用它)。
  final String mediaRefUuid;
  final int mediaWidth;
  final int mediaHeight;

  /// 本地文件路径(仅自己侧**媒体 failed/uploading 预留态**用于重发本地图片/文件;默认空)。
  /// 已 sent / 对端 / 文本消息均为空;媒体重发/上传预留态最小字段。
  final String mediaLocalPath;

  /// 本地媒体**上传进度**(0-100;`-1` = 非上传 / 未知,默认)。仅自己侧 uploading 预留态有意义。
  /// `sendStatus==pending && mediaLocalPath 非空 && uploadProgress>=0` = 正在上传(可显示进度/取消)。
  final int uploadProgress;

  /// 富内容 mixed blocks(type=110)。为空表示旧文本/图片/文件消息。
  final List<ImMessageBlock> blocks;

  /// 自定义 Agent 最终回复(type=111)的原始 EMP blocks。
  ///
  /// 这里不能复用 [blocks]，因为 mixed IM 只支持 text/markdown/image/file/skill
  /// 等少量聊天块，而 EMP 还包含 code/table/chart/form/source 等富组件。
  final List<Map<String, dynamic>> empBlocks;

  /// type=111 agent final 元数据。群 HITL 需要用 status/message uuid 判定 EMP 是否可提交。
  final String agentStreamId;
  final String agentMessageUuid;
  final String agentMessageStatus;

  /// 结构化 mention 元数据。当前 type=111 群 Agent 回复用它标记本次触发者；
  /// `id` 是 account_uuid 权威值，`name` 仅作旧成员快照回退。
  final List<Map<String, dynamic>> mentions;

  /// F09 P1: 该消息已被撤回 (tombstone 视图)。撤回信号来自 type=98 通知,
  /// controller `_upsert` 时把原消息的 `isRevoked` 置 true,并同时把
  /// `text` / `mediaUrl` / `blocks` 清空,避免渲染原文。
  final bool isRevoked;

  /// F09 P1: 这条消息**自身**是一条撤回通知 (WuKong type=98),
  /// 用于 controller 识别后**吞掉**它(不上屏)。运行时字段, 不参与列表渲染。
  final bool isRevokeNotify;

  /// F09 P1: 撤回通知 payload 中的目标 message_id。仅 isRevokeNotify=true 时有效。
  final String revokedMessageId;

  /// F09 P1: 撤回通知 payload 中的目标 client_msg_no (兜底匹配)。仅 isRevokeNotify=true 时有效。
  final String revokedClientMsgNo;

  /// F09 引用回复 v1: 解码自 mixed payload 顶层 `reply` 字段; null = 普通消息.
  /// 渲染时若非 null, 气泡顶部加引用块 (浅灰底 + 发送人 + 摘要).
  /// 类型为 `Map<String,dynamic>` (snake_case wire); 上层用 `ChatReplyReference.fromJson` 转 model.
  final Map<String, dynamic>? replyRefJson;

  const ImMessage({
    required this.messageId,
    required this.clientMsgNo,
    required this.fromUid,
    required this.channelId,
    required this.channelType,
    required this.timestamp,
    required this.text,
    this.notificationTitle = '',
    this.notificationBody = '',
    this.messageSeq = 0,
    this.sendStatus = ImSendStatus.sent,
    this.errorMessage = '',
    this.isRefresh = false,
    this.mediaKind = ImMediaKind.none,
    this.mediaUrl = '',
    this.mediaName = '',
    this.mediaSize = 0,
    this.mediaMime = '',
    this.mediaFileUuid = '',
    this.mediaRefUuid = '',
    this.mediaWidth = 0,
    this.mediaHeight = 0,
    this.mediaLocalPath = '',
    this.uploadProgress = -1,
    this.blocks = const [],
    this.empBlocks = const <Map<String, dynamic>>[],
    this.agentStreamId = '',
    this.agentMessageUuid = '',
    this.agentMessageStatus = '',
    this.mentions = const <Map<String, dynamic>>[],
    this.isRevoked = false,
    this.isRevokeNotify = false,
    this.revokedMessageId = '',
    this.revokedClientMsgNo = '',
    this.replyRefJson,
  });

  bool get isMedia => mediaKind != ImMediaKind.none;
  bool get isMixed => blocks.isNotEmpty;
  bool get isPending => sendStatus == ImSendStatus.pending;
  bool get isFailed => sendStatus == ImSendStatus.failed;

  /// 本地媒体正在上传(自己侧 pending + 有本地路径 + 已知进度)。可显示进度/取消。
  bool get isUploading =>
      isPending && mediaLocalPath.isNotEmpty && uploadProgress >= 0;

  /// F09 P1: 把当前消息替成 tombstone 视图(保留 messageId/clientMsgNo/timestamp,
  /// 但清掉所有正文 / 媒体引用 / blocks, 置 `isRevoked=true`)。
  ImMessage withRevoked() {
    return ImMessage(
      messageId: messageId,
      clientMsgNo: clientMsgNo,
      fromUid: fromUid,
      channelId: channelId,
      channelType: channelType,
      timestamp: timestamp,
      text: '',
      notificationTitle: '',
      notificationBody: '',
      messageSeq: messageSeq,
      sendStatus: sendStatus,
      errorMessage: '',
      isRefresh: false,
      mediaKind: ImMediaKind.none,
      mediaUrl: '',
      mediaName: '',
      mediaSize: 0,
      mediaMime: '',
      mediaFileUuid: '',
      mediaRefUuid: '',
      mediaWidth: 0,
      mediaHeight: 0,
      mediaLocalPath: '',
      uploadProgress: -1,
      blocks: const <ImMessageBlock>[],
      empBlocks: const <Map<String, dynamic>>[],
      agentStreamId: '',
      agentMessageUuid: '',
      agentMessageStatus: '',
      mentions: const <Map<String, dynamic>>[],
      isRevoked: true,
    );
  }
}

enum ImConnectionStatus {
  /// No connection attempt has started yet; not a transport failure.
  idle,
  disconnected,
  connecting,
  connected,
  noNetwork,
  kicked,
}

extension ImConnectionStatusX on ImConnectionStatus {
  bool get isConnected => this == ImConnectionStatus.connected;
  bool get isConnecting => this == ImConnectionStatus.connecting;
}

/// 会话级事件类型(P1,仅作为左侧列表 refresh **触发器**,不携带业务真相)。
/// - [deleted] 会话被删除(本端/多端);
/// - [unreadChanged] 红点/未读发生变化(如清空所有红点)。
///
/// 故意**不**包含 per-message 的 "conversation refresh"(那会等价每条消息 refresh,由 message stream 覆盖),
/// 也不含 "syncCompleted"(离线同步完成由连接状态 connected/syncCompleted 触发)。
enum ImConversationEventKind { deleted, unreadChanged }

/// 中立会话事件(P1)。`channelId` 为空表示全局事件(如清空所有红点),按全局 refresh 处理。
/// **不**携带 SDK 本地 unread/redDot 值作为业务真相;只用于触发 `/chat/conversations` 权威快照刷新。
class ImConversationEvent {
  final ImConversationEventKind kind;
  final String channelId;
  final int channelType;
  final int timestamp;

  const ImConversationEvent({
    required this.kind,
    this.channelId = '',
    this.channelType = 0,
    this.timestamp = 0,
  });
}

/// WuKong no_persist 已读水位信号。
///
/// 这不是普通聊天消息,也不进入 [ImClient.listenMessages]。支持该能力的底层
/// client 可额外实现 [ImReadReceiptSignalClient]。
class ImReadReceiptSignal {
  const ImReadReceiptSignal({
    required this.conversationUuid,
    required this.lastReadMessageSeq,
    this.readerUid = '',
    this.channelId = '',
    this.channelType = 0,
    this.timestamp = 0,
  });

  final String conversationUuid;
  final int lastReadMessageSeq;
  final String readerUid;
  final String channelId;
  final int channelType;
  final int timestamp;
}

abstract class ImReadReceiptSignalClient {
  Stream<ImReadReceiptSignal> listenReadReceiptSignals();
}

/// 可显式绕过本地历史完整性推断、向服务端对账最新一页的 IM client。
///
/// 普通 [ImClient.getHistoryMessages] 保持 local-first；会话首屏已有缓存时，
/// controller 再通过本接口后台补齐账号离线期间新增的尾部消息。
abstract class ImLatestHistorySyncClient {
  Future<List<ImMessage>> syncLatestHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    String? conversationUuid,
    String? clearedAt,
  });
}

/// Disk-only recovery, independent of IM credentials or connection state.
typedef ImLocalHistory = ({String uid, List<ImMessage> messages});

abstract class ImLocalHistoryClient {
  Future<ImLocalHistory?> readLocalHistory(
      String channelId, int channelType, {int limit = 40});
}

/// IM substrate 客户端抽象。Phase 1 只做文本闭环。
abstract class ImClient {
  /// 一次性初始化(如桌面 sqflite_ffi)。
  Future<void> init();

  /// 已 setup/login 的 uid;为空表示尚未 login。注意:这不是长连接成功信号。
  /// 真正实时连接状态必须看 [connectionStatus] / [listenConnectionStatus]。
  String? get connectedUid;

  /// WuKong 长连接真实状态。connectedUid 非空但这里不是 connected 时,仍需触发 connect/retry。
  ImConnectionStatus get connectionStatus;

  /// 长连接是否已真实连通。
  bool get isRealtimeConnected;

  /// 监听长连接状态变化。
  Stream<ImConnectionStatus> listenConnectionStatus();

  /// 用连接信息登录(设置 uid/token/地址)。幂等:同 uid 重复调跳过 setup。
  Future<void> login(ImConnInfo info);

  Future<void> logout();

  /// 建立 / 断开长连接。
  Future<void> connect();
  Future<void> disconnect();

  /// 会话列表。
  Future<List<ImConversation>> getConversationList();

  /// 拉取某 channel 历史消息(Phase 1 文本)。
  ///
  /// [beforeMessageSeq] 历史分页锚点(P1):0 = 最新一页(默认,兼容现有调用);
  /// `>0` = 拉取 `messageSeq` 严格更早的一页(向上翻页)。
  Future<List<ImMessage>> getHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    int beforeMessageSeq = 0,
    String? conversationUuid,
    String? clearedAt,
  });

  /// 发送文本消息。mentions 为结构化 @ 元数据(payload.mentions, ADR-0026 / F09 P3-3),
  /// 形如 [{type:all|human|agent, id, name}];为空则发普通文本。
  Future<void> sendTextMessage(
    String channelId,
    int channelType,
    String text, {
    List<Map<String, dynamic>>? mentions,
  });

  /// 发送图片消息。url = `/chat/media/{ref}/preview`;refUuid = 同一个 ref。
  Future<void> sendImageMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    String refUuid = '',
    String name = '',
    int width = 0,
    int height = 0,
  });

  /// 发送文件消息（WuKong type=8，自定义内容）。url = `/chat/media/{ref}/download`。
  /// fileUuid = 底层 drive_files.uuid(溯源);refUuid = chat media ref(URL 用)。
  Future<void> sendFileMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    required String refUuid,
    required String name,
    int size = 0,
    String mime = '',
  });

  /// 发送富内容 mixed 消息(WuKong 自定义 type=110)。blocks 为最终发送顺序。
  /// F09 引用回复 v1: 可选 `reply` payload (mixed 顶层字段, 不进 blocks; 不进可见正文)。
  Future<void> sendMixedMessage(
    String channelId,
    int channelType, {
    required List<ImMessageBlock> blocks,
    String summary = '',
    List<Map<String, dynamic>>? mentions,
    Map<String, dynamic>? reply,
  });

  /// 实时消息流(收到新消息时推送)。
  Stream<ImMessage> listenMessages();

  /// 会话级事件流(P1):会话删除 / 清空红点等**非每条消息**的会话变化。
  /// 仅作为左侧列表 refresh 触发器;不携带 SDK 本地 unread/redDot 作为业务真相。
  /// SDK 无对应事件的实现可返回空流。
  Stream<ImConversationEvent> listenConversationEvents();

  /// 总未读数。
  Future<int> unreadCount();

  /// 标记某 channel 已读。
  Future<void> markRead(String channelId, int channelType);

  /// 释放资源。
  Future<void> dispose();
}
