import 'package:zhiban_client/pages/chat/widgets/conversation_connection_banner.dart';
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/im/chat_media_api.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/services/message_files_api.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/chat_read_receipt_events.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/services/app_notification_service.dart';

import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 左侧会话列表实时更新 (docs/contracts §P2.1b 客户端会话列表实时更新)。
// 核心逻辑在 ConversationsNotifier.applyRealtimeMessage / applyAgentConversationPreview;
// 这里直喂这两个方法验证 WuKong human_direct/group 实时 patch + agent 单聊本地预览。

class _FakeChatSvc extends OpenClawChatService {
  _FakeChatSvc(this.items, {List<Stream<Map<String, dynamic>>>? accountStreams})
      : accountStreams = accountStreams ?? [];
  List<ConversationItem> items;
  final List<Stream<Map<String, dynamic>>> accountStreams;
  int listCalls = 0; // listAllConversations 调用次数 (build + 每次 refresh)
  Future<void>? listGate;
  Object? listError;
  int accountStreamListenCalls = 0;
  final Map<String, List<ChatMessage>> histories = {};
  final StreamController<Map<String, dynamic>> accountEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async {
    listCalls++;
    await listGate;
    if (listError != null) throw listError!;
    return items;
  }

  @override
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async =>
      histories[conversationId] ?? const [];

  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}

  @override
  Stream<Map<String, dynamic>> streamAccountEvents() {
    accountStreamListenCalls++;
    if (accountStreams.isNotEmpty) {
      return accountStreams.removeAt(0);
    }
    return accountEvents.stream;
  }

  @override
  Future<List<AgentItem>> listAgents() async => const [];

  @override
  Future<OpenClawInstanceState> bootstrapInstance() async =>
      const OpenClawInstanceState(
          instanceStatus: 'running',
          message: '',
          defaultAgentReady: true,
          gatewayReady: true);

  @override
  Future<OpenClawInstanceState> getInstanceStatus() async =>
      const OpenClawInstanceState(
          instanceStatus: 'running',
          message: '',
          defaultAgentReady: true,
          gatewayReady: true);
}

class _FakeCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() async =>
      const DigitalEmployeeCatalog(personal: [], enterprise: []);
}

class _UnavailableContacts extends ContactsService {
  @override
  Future<ContactAgent> agent(String agentUuid, {bool silent = false}) async {
    throw StateError('No contact detail in this test fixture');
  }
}

ConversationItem _human(String id,
        {required String ch,
        int type = 2,
        int unread = 0,
        String? title,
        String? lastMessageAt}) =>
    ConversationItem(
      conversationId: id,
      title: title ?? id,
      agentId: '',
      agentName: id,
      kind: 'human_direct',
      wukongChannelId: ch,
      wukongChannelType: type,
      unreadCount: unread,
      lastMessageAt: lastMessageAt,
    );

ConversationItem _group(String id,
        {required String ch,
        int type = 2,
        int unread = 0,
        String? lastMessageAt}) =>
    ConversationItem(
      conversationId: id,
      title: id,
      agentId: '',
      agentName: id,
      kind: 'group',
      wukongChannelId: ch,
      wukongChannelType: type,
      unreadCount: unread,
      lastMessageAt: lastMessageAt,
    );

ConversationItem _agent(String id, String agentId,
        {String? ch, int type = 2}) =>
    ConversationItem(
      conversationId: id,
      title: id,
      agentId: agentId,
      agentName: id,
      kind: 'single',
      wukongChannelId: ch,
      wukongChannelType: ch == null ? null : type,
    );

Future<ProviderContainer> _boot(List<ConversationItem> items) async {
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => _FakeChatSvc(items)),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
  ]);
  await c.read(conversationsProvider.future);
  return c;
}

List<ConversationItem> _list(ProviderContainer c) =>
    c.read(conversationsProvider).asData!.value;

ConversationItem _byId(ProviderContainer c, String id) =>
    _list(c).firstWhere((e) => e.conversationId == id);

/// fake ImClient: 记录 init/login/connect 调用 + 用广播流喂消息 + 可设已 login uid / 真实连接状态。
class _FakeImClient implements ImClient, ImReadReceiptSignalClient {
  _FakeImClient({
    this.uid,
    this.status = ImConnectionStatus.disconnected,
    this.connectMarksConnected = false,
    this.sendThrows = false,
  });
  String? uid;
  ImConnectionStatus status;
  final bool connectMarksConnected;

  /// 模拟 WuKong SDK 发送行为:true = sendTextMessage 抛错(发送前失败);
  /// false = 发送即经 msgInserted 回送一条 pending(带自增 clientMsgNo)。
  bool sendThrows;

  /// open() 时返回的历史消息(测试可在 open 前设置)。
  List<ImMessage> history = <ImMessage>[];

  /// 上拉分页(beforeMessageSeq>0)返回的更早历史;记录最近一次锚点供断言。
  List<ImMessage> olderHistory = <ImMessage>[];
  int lastHistoryBeforeSeq = -1;
  String? lastHistoryConversationUuid;
  String? lastHistoryClearedAt;

  final StreamController<ImMessage> _ctrl =
      StreamController<ImMessage>.broadcast();
  final StreamController<ImConnectionStatus> _statusCtrl =
      StreamController<ImConnectionStatus>.broadcast();
  final StreamController<ImConversationEvent> _convEventCtrl =
      StreamController<ImConversationEvent>.broadcast();
  final StreamController<ImReadReceiptSignal> _readReceiptSignalCtrl =
      StreamController<ImReadReceiptSignal>.broadcast();
  int convEventListenCalls = 0;
  int readReceiptSignalListenCalls = 0;
  int initCalls = 0;
  int loginCalls = 0;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int listenCalls = 0;
  int statusListenCalls = 0;
  int sendTextCalls = 0;
  int sendMixedCalls = 0;
  String lastSentText = '';
  int _cmnSeq = 0;

  /// 最近一次自动回送 pending 的 clientMsgNo(测试用它构造匹配的 refresh)。
  String lastClientMsgNo = '';

  void emit(ImMessage m) => _ctrl.add(m);
  void emitConvEvent(ImConversationEvent e) => _convEventCtrl.add(e);
  void emitReadReceiptSignal(ImReadReceiptSignal e) =>
      _readReceiptSignalCtrl.add(e);
  void emitStatus(ImConnectionStatus s) {
    status = s;
    _statusCtrl.add(s);
  }

  @override
  String? get connectedUid => uid;
  @override
  ImConnectionStatus get connectionStatus => status;
  @override
  bool get isRealtimeConnected => status.isConnected;
  @override
  Stream<ImConnectionStatus> listenConnectionStatus() {
    statusListenCalls++;
    return _statusCtrl.stream;
  }

  @override
  Future<void> init() async => initCalls++;
  @override
  Future<void> login(ImConnInfo info) async {
    loginCalls++;
    uid = info.uid;
  }

  @override
  Future<void> connect() async {
    connectCalls++;
    if (connectMarksConnected) {
      emitStatus(ImConnectionStatus.connected);
    } else if (status == ImConnectionStatus.disconnected) {
      emitStatus(ImConnectionStatus.connecting);
    }
  }

  @override
  Stream<ImMessage> listenMessages() {
    listenCalls++;
    return _ctrl.stream;
  }

  @override
  Stream<ImConversationEvent> listenConversationEvents() {
    convEventListenCalls++;
    return _convEventCtrl.stream;
  }

  @override
  Stream<ImReadReceiptSignal> listenReadReceiptSignals() {
    readReceiptSignalListenCalls++;
    return _readReceiptSignalCtrl.stream;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    emitStatus(ImConnectionStatus.disconnected);
  }

  @override
  Future<void> logout() async {}
  @override
  Future<List<ImConversation>> getConversationList() async => const [];
  @override
  Future<List<ImMessage>> getHistoryMessages(String channelId, int channelType,
      {int limit = 30,
      int beforeMessageSeq = 0,
      String? conversationUuid,
      String? clearedAt}) async {
    lastHistoryBeforeSeq = beforeMessageSeq;
    lastHistoryConversationUuid = conversationUuid;
    lastHistoryClearedAt = clearedAt;
    return beforeMessageSeq > 0 ? olderHistory : history;
  }

  @override
  Future<void> sendTextMessage(String channelId, int channelType, String text,
      {List<Map<String, dynamic>>? mentions}) async {
    sendTextCalls++;
    lastSentText = text;
    if (sendThrows) throw StateError('fake send fail');
    // 模拟 WuKong SDK: 发送即经 msgInserted 回送一条 pending(已带真实 clientMsgNo)。
    lastClientMsgNo = 'cmn-${++_cmnSeq}';
    _ctrl.add(ImMessage(
      messageId: '',
      clientMsgNo: lastClientMsgNo,
      fromUid: uid ?? 'me',
      channelId: channelId,
      channelType: channelType,
      timestamp: 1700000000,
      text: text,
      sendStatus: ImSendStatus.pending,
    ));
  }

  int sendMediaCalls = 0;
  // 模拟 WuKong SDK: 媒体发送即经 msgInserted 回送一条 pending(带真实 clientMsgNo)。
  void _emitMediaPending(String channelId, int channelType, ImMediaKind kind,
      String url, String name) {
    lastClientMsgNo = 'cmn-${++_cmnSeq}';
    _ctrl.add(ImMessage(
      messageId: '',
      clientMsgNo: lastClientMsgNo,
      fromUid: uid ?? 'me',
      channelId: channelId,
      channelType: channelType,
      timestamp: 1700000000,
      text: kind == ImMediaKind.image ? '[图片]' : name,
      sendStatus: ImSendStatus.pending,
      mediaKind: kind,
      mediaUrl: url,
      mediaName: name,
    ));
  }

  @override
  Future<void> sendImageMessage(String channelId, int channelType,
      {required String url,
      required String fileUuid,
      String refUuid = '',
      String name = '',
      int width = 0,
      int height = 0}) async {
    sendMediaCalls++;
    _emitMediaPending(channelId, channelType, ImMediaKind.image, url, name);
  }

  @override
  Future<void> sendFileMessage(String channelId, int channelType,
      {required String url,
      required String fileUuid,
      required String refUuid,
      required String name,
      int size = 0,
      String mime = ''}) async {
    sendMediaCalls++;
    _emitMediaPending(channelId, channelType, ImMediaKind.file, url, name);
  }

  @override
  Future<void> sendMixedMessage(String channelId, int channelType,
      {required List<ImMessageBlock> blocks,
      String summary = '',
      List<Map<String, dynamic>>? mentions,
      Map<String, dynamic>? reply}) async {
    sendMixedCalls++;
    lastClientMsgNo = 'cmn-${++_cmnSeq}';
    _ctrl.add(ImMessage(
      messageId: '',
      clientMsgNo: lastClientMsgNo,
      fromUid: uid ?? 'me',
      channelId: channelId,
      channelType: channelType,
      timestamp: 1700000000,
      text: summary.isNotEmpty ? summary : '[非文本消息]',
      sendStatus: ImSendStatus.pending,
      blocks: blocks,
    ));
  }

  @override
  Future<int> unreadCount() async => 0;
  @override
  Future<void> markRead(String channelId, int channelType) async {}
  @override
  Future<void> dispose() async {
    if (!_ctrl.isClosed) await _ctrl.close();
    if (!_statusCtrl.isClosed) await _statusCtrl.close();
    if (!_convEventCtrl.isClosed) await _convEventCtrl.close();
    if (!_readReceiptSignalCtrl.isClosed) {
      await _readReceiptSignalCtrl.close();
    }
  }
}

/// fake 凭证 client: 前 [failTimes] 次 fetch 抛错, 之后返回固定连接信息 + 计数。
class _FakeCreds extends IMCredentialsClient {
  _FakeCreds(this.info, {this.failTimes = 0, this.failure, this.firstGate});
  final Future<void>? firstGate;
  final Object? failure;
  final ImConnInfo info;
  final int failTimes;
  int fetchCalls = 0;
  int invalidateCalls = 0;
  @override
  Future<ImConnInfo> fetchWukongConnInfo() async {
    fetchCalls++;
    if (fetchCalls == 1 && firstGate != null) await firstGate;
    if (fetchCalls <= failTimes) {
      throw failure ?? Exception('fake fetch fail #$fetchCalls');
    }
    return info;
  }

  @override
  Future<void> invalidateCache() async {
    invalidateCalls++;
  }
}

const _connInfo = ImConnInfo(
  substrate: 'wukong',
  uid: 'me',
  token: 't',
  tcpAddr: 'h:1',
  wsAddr: 'ws://h:1',
);

// 连接凭证 TTL helpers (DateTime 非 const → 用函数构造)。
ImConnInfo _freshInfo({String token = 't'}) => ImConnInfo(
      substrate: 'wukong',
      uid: 'me',
      token: token,
      tcpAddr: 'h:1',
      wsAddr: 'ws://h:1',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)), // 远未来
    );
ImConnInfo _expiringInfo({String token = 't'}) => ImConnInfo(
      substrate: 'wukong',
      uid: 'me',
      token: token,
      tcpAddr: 'h:1',
      wsAddr: 'ws://h:1',
      expiresAt:
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)), // 已过期
    );

// 历史消息 helper(已 ack:sendStatus=sent、messageSeq>0)。
ImMessage _histMsg(int seq, {String channelId = 'ch-zw', int? timestamp}) =>
    ImMessage(
      messageId: 'm$seq',
      clientMsgNo: 'c$seq',
      fromUid: 'peer',
      channelId: channelId,
      channelType: 2,
      timestamp: timestamp ?? 1700000000 + seq,
      text: '#$seq',
      messageSeq: seq,
    );

// 生成 messageSeq = [from..to] 的连续历史页。
List<ImMessage> _histRange(int from, int to, {String channelId = 'ch-zw'}) =>
    [for (var s = from; s <= to; s++) _histMsg(s, channelId: channelId)];

// 媒体发送依赖:可注入的上传 / chat media ref fake(用于媒体 failed/重发窄测,不依赖网络)。
class _FakeFilesSvc extends MessageFilesService {
  _FakeFilesSvc({this.throwOnUpload = false, this.autoComplete = true});
  bool throwOnUpload;

  /// false = 上传**挂起**(模拟上传中),直到 completeUpload()/failUpload() 或被 cancelToken 取消。
  bool autoComplete;
  int uploadCalls = 0;
  void Function(int, int)? _progress;
  Completer<String>? _pending;

  void emitProgress(int sent, int total) => _progress?.call(sent, total);
  void completeUpload() {
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.complete('drv-uploaded');
    }
  }

  void failUpload(Object e) {
    if (_pending != null && !_pending!.isCompleted) _pending!.completeError(e);
  }

  @override
  Future<String> uploadFile({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? conversationUuid,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    uploadCalls++;
    _progress = onSendProgress;
    if (throwOnUpload) throw StateError('fake upload fail');
    onSendProgress?.call(0, 100); // 初始进度
    if (!autoComplete) {
      final c = Completer<String>();
      _pending = c;
      // 模拟真实 Dio: cancelToken.cancel() → 抛 DioException(type: cancel)。
      cancelToken?.whenCancel.then((_) {
        if (!c.isCompleted) {
          c.completeError(DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
          ));
        }
      });
      return c.future;
    }
    return 'drv-uploaded'; // 上传成功 → chat-scoped drive_file uuid
  }
}

class _FakeChatMedia extends ChatMediaApi {
  _FakeChatMedia({this.throwOnCreate = false, this.isImage = false});
  bool throwOnCreate;
  bool isImage;
  int createCalls = 0;
  @override
  Future<ChatMediaRef> createRef({
    required String conversationUuid,
    required String driveFileUuid,
  }) async {
    createCalls++;
    if (throwOnCreate) throw StateError('fake createRef fail');
    return ChatMediaRef(
      refUuid: 'ref-$createCalls',
      driveFileUuid: driveFileUuid,
      mediaKind: isImage ? 2 : 8,
      sourceKind: 'chat',
      fileName: 'f.bin',
      mimeType: isImage ? 'image/png' : 'application/octet-stream',
      sizeBytes: 10,
    );
  }
}

DriveFile _driveFile(String uuid, String name,
        {String mime = 'application/pdf'}) =>
    DriveFile(
      uuid: uuid,
      name: name,
      mimeType: mime,
      sizeBytes: 10,
      source: 'personal',
      driveFolderUuid: '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

Future<ProviderContainer> _bootBridge(
  List<ConversationItem> items,
  _FakeImClient client,
  _FakeCreds creds, {
  Duration Function(int attempt)? retryDelay,
  Duration? refreshDebounce,
  Duration? connectingWatchdog,
  DesktopNotificationSender? notifyDesktop,
  DesktopNotificationFlash? flashDesktop,
  DesktopBadgeUpdater? updateDesktopBadge,
  _FakeChatSvc? chatSvc,
  Stream<List<ConnectivityResult>> networkChanges = const Stream.empty(),
  Future<List<ConnectivityResult>> Function()? checkNetwork,
  Duration offlineConfirmation = const Duration(milliseconds: 20),
}) async {
  final svc = chatSvc ?? _FakeChatSvc(items);
  final c = ProviderContainer(overrides: [
    chatServiceProvider.overrideWith((ref) => svc),
    contactsServiceProvider.overrideWith((ref) => _UnavailableContacts()),
    digitalEmployeeCatalogProvider.overrideWith(() => _FakeCatalog()),
    wukongImClientProvider.overrideWithValue(client),
    imCredentialsClientProvider.overrideWithValue(creds),
    conversationNetworkChangesProvider.overrideWithValue(networkChanges),
    conversationNetworkCheckProvider.overrideWithValue(
        checkNetwork ?? () async => [ConnectivityResult.wifi]),
    realtimeOfflineConfirmationProvider.overrideWithValue(offlineConfirmation),
    if (retryDelay != null)
      realtimeRetryDelayProvider.overrideWithValue(retryDelay),
    if (refreshDebounce != null)
      realtimeRefreshDebounceProvider.overrideWithValue(refreshDebounce),
    if (connectingWatchdog != null)
      realtimeConnectingWatchdogProvider.overrideWithValue(connectingWatchdog),
    if (notifyDesktop != null)
      realtimeNotificationSenderProvider.overrideWithValue(notifyDesktop),
    if (flashDesktop != null)
      realtimeNotificationFlashProvider.overrideWithValue(flashDesktop),
    if (updateDesktopBadge != null)
      realtimeBadgeUpdaterProvider.overrideWithValue(updateDesktopBadge),
  ]);
  await c.read(conversationsProvider.future);
  return c;
}

class _DesktopNotifyCall {
  const _DesktopNotifyCall(this.title, this.body, this.payload);
  final String title;
  final String body;
  final String payload;
}

// 极短退避 (测试用): 任意 attempt 都 5ms, 让重试快速触发。
Duration _fastRetry(int attempt) => const Duration(milliseconds: 5);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('applyRealtimeMessage (WuKong human_direct/group 实时)', () {
    test('incoming 非当前会话 → 更新 preview/time, 置顶, unread +1', () async {
      final c = await _boot([
        _human('张伟', ch: 'ch-zw'),
        _human('李四', ch: 'ch-ls'),
      ]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '在吗',
            fromSelf: false,
            currentConversationIds: const {},
            dedupId: 'm1',
          );

      final list = _list(c);
      expect(list.first.conversationId, '张伟'); // 置顶
      expect(list.first.lastMessage, '在吗');
      expect(list.first.unreadCount, 1);
      expect((list.first.lastMessageAt ?? '').isNotEmpty, isTrue);
    });

    test('incoming 当前打开会话 → 更新 preview/time, 置顶, unread 保持 0', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw', unread: 0)]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '对方消息',
            fromSelf: false,
            currentConversationIds: const {'张伟'},
            dedupId: 'm2',
          );

      final zw = _byId(c, '张伟');
      expect(zw.lastMessage, '对方消息');
      expect(zw.unreadCount, 0); // 当前会话不增红点
    });

    test('self echo (自己发的) → 更新 preview/time, 置顶, 不加未读', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw', unread: 3)]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '在吗',
            fromSelf: true,
            currentConversationIds: const {}, // 即便不在当前会话
            dedupId: 'm3',
          );

      final zw = _byId(c, '张伟');
      expect(zw.lastMessage, '在吗');
      expect(zw.unreadCount, 3); // 自己发的不加未读, 保持原值
    });

    test('去重: 同一 messageId 重复投递不重复加未读/置顶', () async {
      final c = await _boot([
        _human('张伟', ch: 'ch-zw'),
        _human('李四', ch: 'ch-ls'),
      ]);
      addTearDown(c.dispose);

      final n = c.read(conversationsProvider.notifier);
      n.applyRealtimeMessage(
          channelId: 'ch-zw',
          channelType: 2,
          previewText: '在吗',
          fromSelf: false,
          currentConversationIds: const {},
          dedupId: 'dup-1');
      n.applyRealtimeMessage(
          channelId: 'ch-zw',
          channelType: 2,
          previewText: '在吗',
          fromSelf: false,
          currentConversationIds: const {},
          dedupId: 'dup-1'); // 同 id 再来一次

      expect(_byId(c, '张伟').unreadCount, 1); // 只 +1, 不是 2
    });

    test('group channel 匹配 → 群聊实时更新 + 置顶 + unread +1', () async {
      final c = await _boot([
        _group('群A', ch: 'ch-g'),
        _human('张伟', ch: 'ch-zw'),
      ]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-g',
            channelType: 2,
            previewText: '群成员消息',
            fromSelf: false,
            currentConversationIds: const {},
            dedupId: 'gm1',
          );

      final list = _list(c);
      expect(list.first.conversationId, '群A');
      expect(list.first.lastMessage, '群成员消息');
      expect(list.first.unreadCount, 1);
    });

    test('不命中任何会话 (未知 channel) → 列表不变', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw')]);
      addTearDown(c.dispose);

      final handled =
          c.read(conversationsProvider.notifier).applyRealtimeMessage(
                channelId: 'ch-unknown',
                channelType: 2,
                previewText: 'x',
                fromSelf: false,
                currentConversationIds: const {},
                dedupId: 'u1',
              );

      expect(handled, isFalse);
      expect(_byId(c, '张伟').unreadCount, 0);
      expect(_byId(c, '张伟').lastMessage, isNull);
    });

    test('channelType 不匹配 → 不命中 (不串号)', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw', type: 2)]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 1, // 不同 type
            previewText: 'x',
            fromSelf: false,
            currentConversationIds: const {},
            dedupId: 't1',
          );

      expect(_byId(c, '张伟').unreadCount, 0);
    });
  });

  group('applyAgentConversationPreview (数字员工单聊本地预览)', () {
    test('patch 预览 + 置顶, 不加未读', () async {
      final c = await _boot([
        _agent('a-conv', 'ag1'),
        _human('张伟', ch: 'ch-zw', unread: 2),
      ]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyAgentConversationPreview(
            'a-conv',
            lastMessage: '这是最终回答'
          );

      final list = _list(c);
      expect(list.first.conversationId, 'a-conv'); // 置顶
      expect(list.first.lastMessage, '这是最终回答');
      expect(list.first.unreadCount, 0); // 不加未读
      // 其它会话未受影响。
      expect(_byId(c, '张伟').unreadCount, 2);
    });

    test('找不到会话 → no-op, 不崩', () async {
      final c = await _boot([_agent('a-conv', 'ag1')]);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).applyAgentConversationPreview(
            'missing',
            lastMessage: 'x'
          );

      expect(_byId(c, 'a-conv').lastMessage, isNull); // 未变
    });

    test('agent 预览 patch 不影响右侧 SSE 执行态 (chatProvider 不变)', () async {
      final c = await _boot([_agent('a-conv', 'ag1')]);
      addTearDown(c.dispose);

      // 建立 chatProvider 初始态。
      final before = await c.read(chatProvider.future);
      final beforeActive = before.activeConversationId;
      final beforeMsgCount = before.messages.length;

      c.read(conversationsProvider.notifier).applyAgentConversationPreview(
            'a-conv',
            lastMessage: '最终回答'
          );

      final after = c.read(chatProvider).asData!.value;
      expect(after.activeConversationId, beforeActive); // SSE 执行态不被列表 patch 影响
      expect(after.messages.length, beforeMsgCount);
      // 左侧仍然更新了。
      expect(_byId(c, 'a-conv').lastMessage, '最终回答');
    });
  });

  group('applyRealtimeMessage 时间戳单位 + 当前会话自发', () {
    test('秒级时间戳 → lastMessageAt 正确落到该秒', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw')]);
      addTearDown(c.dispose);
      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '在吗',
            fromSelf: false,
            currentConversationIds: const {},
            messageTimestamp: 1700000000, // 秒
            dedupId: 's-sec',
          );
      final at = DateTime.parse(_byId(c, '张伟').lastMessageAt!);
      expect(at.millisecondsSinceEpoch, 1700000000 * 1000);
    });

    test('毫秒级时间戳 → lastMessageAt 正确落到该毫秒', () async {
      final c = await _boot([_human('张伟', ch: 'ch-zw')]);
      addTearDown(c.dispose);
      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '在吗',
            fromSelf: false,
            currentConversationIds: const {},
            messageTimestamp: 1700000000000, // 毫秒
            dedupId: 's-ms',
          );
      final at = DateTime.parse(_byId(c, '张伟').lastMessageAt!);
      expect(at.millisecondsSinceEpoch, 1700000000000);
    });

    test('当前会话自己发送 (fromSelf+current) → 更新 preview/time, 置顶, unread 不增 (清 0)',
        () async {
      final c = await _boot([
        _human('张伟', ch: 'ch-zw', unread: 2),
        _human('李四', ch: 'ch-ls'),
      ]);
      addTearDown(c.dispose);
      c.read(conversationsProvider.notifier).applyRealtimeMessage(
            channelId: 'ch-zw',
            channelType: 2,
            previewText: '在吗',
            fromSelf: true,
            currentConversationIds: const {'张伟'},
            messageTimestamp: 1700000000000,
            dedupId: 'local-1',
          );
      final list = _list(c);
      expect(list.first.conversationId, '张伟'); // 置顶
      expect(list.first.lastMessage, '在吗');
      expect(list.first.unreadCount, 0); // 自发不加未读 (当前会话清 0)
    });

    test('本地清零只是乐观 UI; refresh 仍以 WuKong unread 快照为准', () async {
      final server = <ConversationItem>[
        _group('群聊', ch: 'g-1', unread: 2)
      ];
      final c = await _boot(server);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).clearUnreadLocally('群聊');
      expect(_byId(c, '群聊').unreadCount, 0);

      await c.read(conversationsProvider.notifier).refresh();

      expect(_byId(c, '群聊').unreadCount, 2);
    });

    test('WuKong 已读成功后 refresh 返回 0 → 红点保持清除', () async {
      final server = <ConversationItem>[
        _group('群聊', ch: 'g-1', unread: 2)
      ];
      final c = await _boot(server);
      addTearDown(c.dispose);

      c.read(conversationsProvider.notifier).clearUnreadLocally('群聊');
      server[0] = _group('群聊', ch: 'g-1', unread: 0);

      await c.read(conversationsProvider.notifier).refresh();

      expect(_byId(c, '群聊').unreadCount, 0);
    });
  });

  group('ConversationRealtimeBridge (app 级连接 + 消息流)', () {
    test('start 时未连接 → fetch creds + init + login + connect 各一次', () async {
      final client =
          _FakeImClient(connectMarksConnected: true); // connectedUid 为空
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 等 ensureConnected 完成

      expect(creds.fetchCalls, 1);
      expect(client.initCalls, 1);
      expect(client.loginCalls, 1);
      expect(client.connectCalls, 1);
    });

    test('真实 connected 同 uid → 复用, 不重复 fetch/init/login/connect', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      expect(creds.fetchCalls, 0);
      expect(client.initCalls, 0);
      expect(client.loginCalls, 0);
      expect(client.connectCalls, 0);
    });

    test('uid 已 setup 但未真实 connected → 不重取凭证, 会重新 connect', () async {
      final client = _FakeImClient(uid: 'me'); // uid 有了, 但长连接断开
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      expect(creds.fetchCalls, 0); // uid 已 setup, 不重取凭证
      expect(client.initCalls, 0);
      expect(client.loginCalls, 0);
      expect(client.connectCalls, 1); // 但必须重连真实长连接
      // SDK 已进入 connecting，只挂 watchdog，不同时创建普通 backoff timer。
      expect(bridge.hasPendingRetry, isFalse);

      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.hasPendingRetry, isFalse); // connack/sync 成功后停止重试
    });

    test('fake stream 来消息 → patch conversationsProvider (非当前 → unread +1, 置顶)',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge([
        _human('张伟', ch: 'ch-zw'),
        _human('李四', ch: 'ch-ls')
      ], client, creds);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      client.emit(const ImMessage(
        messageId: 'm1',
        clientMsgNo: '',
        fromUid: 'peer', // 非自己
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000000, // 秒
        text: '在吗',
      ));
      await Future<void>.delayed(Duration.zero); // 让广播流投递

      final list = _list(c);
      expect(list.first.conversationId, '张伟'); // 置顶
      expect(list.first.lastMessage, '在吗');
      expect(list.first.unreadCount, 1);
      expect(DateTime.parse(list.first.lastMessageAt!).millisecondsSinceEpoch,
          1700000000 * 1000); // 用消息时间, 非收到时间
    });

    test('既有私聊收到消息 → debounce 权威刷新并同步对端新昵称', () async {
      final svc = _FakeChatSvc([
        _human('conv-peer', ch: 'ch-peer', title: '旧昵称'),
      ]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        const [],
        client,
        _FakeCreds(_connInfo),
        chatSvc: svc,
        refreshDebounce: const Duration(milliseconds: 20),
      );
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      c.read(selectedHumanDirectProvider.notifier).state =
          const HumanDirectSelection(
        conversationId: 'conv-peer',
        roomUuid: 'room-peer',
        peerAccountUuid: 'account-peer',
        channelId: 'ch-peer',
        channelType: 2,
        title: '旧昵称',
      );
      final before = svc.listCalls;
      svc.items = [
        _human('conv-peer', ch: 'ch-peer', title: '新昵称')
      ];

      client.emit(const ImMessage(
        messageId: 'm-after-rename',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'ch-peer',
        channelType: 2,
        timestamp: 1700000000,
        text: '昵称变更后的第一条消息',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.listCalls, before + 1);
      expect(_byId(c, 'conv-peer').title, '新昵称');
      expect(c.read(selectedHumanDirectProvider)?.title, '新昵称');
    });

    testWidgets('当前会话前台的普通消息即使带旧通知字段也不弹桌面通知', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final calls = <_DesktopNotifyCall>[];
      var flashCalls = 0;
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(
        [_human('conv-zw', ch: 'ch-zw')],
        client,
        creds,
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {
          flashCalls++;
        },
        updateDesktopBadge: (_) async {},
      );
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      c.read(isChatRouteActiveProvider.notifier).state = true;
      c.read(selectedHumanDirectProvider.notifier).state =
          const HumanDirectSelection(
        conversationId: 'conv-zw',
        roomUuid: 'room-zw',
        peerAccountUuid: 'acct-zw',
        channelId: 'ch-zw',
        channelType: 2,
        title: '张伟',
      );

      client.emit(const ImMessage(
        messageId: 'm-current',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000000,
        text: '普通当前会话消息',
      ));
      await tester.pump();
      expect(calls, isEmpty);

      client.emit(const ImMessage(
        messageId: 'm-legacy-notification-meta',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000001,
        text: '普通回复正文',
        notificationTitle: '行政专员',
        notificationBody: '普通回复正文',
      ));
      await tester.pump();

      expect(calls, isEmpty);
      expect(flashCalls, 0);

      c.dispose();
      await client.dispose();
    });

    testWidgets('当前数字员工会话前台收到主动聊天消息不弹桌面通知', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final calls = <_DesktopNotifyCall>[];
      var flashCalls = 0;
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        [_agent('conv-agent', 'ag1', ch: 'agent-ch')],
        client,
        _FakeCreds(_connInfo),
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {
          flashCalls++;
        },
        updateDesktopBadge: (_) async {},
      );
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      c.read(isChatRouteActiveProvider.notifier).state = true;
      await c.read(chatProvider.notifier).selectConversation('conv-agent');

      client.emit(const ImMessage(
        messageId: 'm-agent-active-chat',
        clientMsgNo: '',
        fromUid: 'agent',
        channelId: 'agent-ch',
        channelType: 2,
        timestamp: 1700000001,
        text: '聊天记录聚焦复测二',
      ));
      await tester.pump();

      expect(calls, isEmpty);
      expect(flashCalls, 0);
      expect(_byId(c, 'conv-agent').unreadCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      client.emit(const ImMessage(
        messageId: 'm-agent-active-chat-inactive-window',
        clientMsgNo: '',
        fromUid: 'agent',
        channelId: 'agent-ch',
        channelType: 2,
        timestamp: 1700000002,
        text: '窗口非 resumed 但仍是当前会话',
      ));
      await tester.pump();

      expect(calls, isEmpty);
      expect(flashCalls, 0);

      c.dispose();
      await client.dispose();
    });

    testWidgets('切到群聊时数字员工主动聊天消息弹普通通知', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final calls = <_DesktopNotifyCall>[];
      var flashCalls = 0;
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        [
          _agent('conv-agent', 'ag1', ch: 'agent-ch'),
          _group('conv-group', ch: 'group-ch'),
        ],
        client,
        _FakeCreds(_connInfo),
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {
          flashCalls++;
        },
        updateDesktopBadge: (_) async {},
      );
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await c.read(chatProvider.notifier).selectConversation('conv-agent');
      c.read(selectedGroupProvider.notifier).state = const GroupSelection(
        conversationId: 'conv-group',
        roomUuid: 'room-group',
        channelId: 'group-ch',
        channelType: 2,
        title: '群聊',
        participants: [],
      );

      client.emit(const ImMessage(
        messageId: 'm-agent-while-group-current',
        clientMsgNo: '',
        fromUid: 'agent',
        channelId: 'agent-ch',
        channelType: 2,
        timestamp: 1700000003,
        text: '聊天记录切走复测',
      ));
      await tester.pump();

      expect(calls, hasLength(1));
      expect(calls.single.title, 'conv-agent');
      expect(calls.single.body, '聊天记录切走复测');
      expect(calls.single.payload, 'conv-agent');
      expect(flashCalls, 1);
      expect(_byId(c, 'conv-agent').unreadCount, 1);

      c.dispose();
      await client.dispose();
    });

    test(
        'account message events and reconnect reconcile unchanged conversation timestamps',
        () async {
      final svc = _FakeChatSvc([_agent('conv-agent', 'ag1', ch: 'agent-ch')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(svc.items, client, _FakeCreds(_connInfo),
          chatSvc: svc,
          notifyDesktop: (_, __, ___) async {},
          flashDesktop: () async {},
          updateDesktopBadge: (_) async {});
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await c.read(chatProvider.notifier).selectConversation('conv-agent');
      svc.histories['conv-agent'] = [
        ChatMessage(
            role: ChatRole.question,
            content: 'from phone',
            messageId: 'remote-user')
      ];
      svc.accountEvents.add({
        'kind': 'message.created',
        'conversation_uuid': 'conv-agent',
        'message_uuid': 'remote-user'
      });
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(c.read(chatProvider).requireValue.messages.single.content,
          'from phone');
      svc.histories['conv-agent'] = [
        ...svc.histories['conv-agent']!,
        ChatMessage(
            role: ChatRole.answer,
            content: '',
            messageId: 'remote-answer',
            agentMessageStatus: 'cancelled')
      ];
      svc.accountEvents.add({
        'kind': 'message.cancelled',
        'conversation_uuid': 'conv-agent',
        'message_uuid': 'remote-answer'
      });
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(c.read(chatProvider).requireValue.messages.last.agentMessageStatus,
          'cancelled');
      svc.histories['conv-agent'] = [
        ChatMessage(
            role: ChatRole.answer,
            content: 'finished while disconnected',
            messageId: 'new-answer',
            agentMessageStatus: 'final')
      ];
      svc.accountEvents.add({'conn_id': 'new-connection', 'gap': false});
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(c.read(chatProvider).requireValue.messages.last.content,
          'finished while disconnected');
    });

    test('账号级系统通知 SSE → 弹桌面通知但不写聊天消息流', () async {
      final calls = <_DesktopNotifyCall>[];
      final svc = _FakeChatSvc([_human('conv-zw', ch: 'ch-zw')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        [_human('conv-zw', ch: 'ch-zw')],
        client,
        _FakeCreds(_connInfo),
        chatSvc: svc,
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {},
        updateDesktopBadge: (_) async {},
      );
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      final beforeListenMessages = client.listenCalls;

      svc.accountEvents.add({
        'kind': 'external_notification.created',
        'conversation_uuid': 'conv-zw',
        'blocks': [
          {
            'kind': 'external_notification',
            'data': {
              'notification_uuid': 'notification-1',
              'conversation_uuid': 'conv-zw',
              'room_uuid': 'room-zw',
              'title': '审批待处理',
              'description': '客户工单等待确认',
            },
          }
        ],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(calls.single.title, '审批待处理');
      expect(calls.single.body, '客户工单等待确认');
      expect(calls.single.payload, 'conv-zw');
      expect(client.listenCalls, beforeListenMessages);
      expect(svc.listCalls, greaterThanOrEqualTo(2)); // 初始加载 + 通知到达后刷新
    });

    test('桌面 call_invite 只刷新会话和角标，不弹普通通知或闪烁', () async {
      if (!PlatformUtils.isDesktop) return;
      final calls = <_DesktopNotifyCall>[];
      var flashes = 0;
      var badgeUpdates = 0;
      final svc = _FakeChatSvc([_human('conv-call', ch: 'ch-call')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        [_human('conv-call', ch: 'ch-call')],
        client,
        _FakeCreds(_connInfo),
        chatSvc: svc,
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {
          flashes++;
        },
        updateDesktopBadge: (_) async {
          badgeUpdates++;
        },
      );
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      final beforeBadgeUpdates = badgeUpdates;

      svc.accountEvents.add({
        'kind': 'notification.created',
        'notification_kind': 'call_invite',
        'title': '李娜',
        'body': '邀请你进行语音通话',
        'route': {
          'conversation_uuid': 'conv-call',
          'call_uuid': 'call-1'
        },
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
      expect(flashes, 0);
      expect(badgeUpdates, greaterThan(beforeBadgeUpdates));
      expect(svc.listCalls, greaterThanOrEqualTo(2));
    });

    test('账号级 SSE 异常断开后会自动重连并继续接收系统通知', () async {
      final calls = <_DesktopNotifyCall>[];
      final retryEvents = StreamController<Map<String, dynamic>>.broadcast();
      final svc = _FakeChatSvc(
        [_human('conv-zw', ch: 'ch-zw')],
        accountStreams: [
          Stream<Map<String, dynamic>>.error(Exception('sse down')),
          retryEvents.stream,
        ],
      );
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        [_human('conv-zw', ch: 'ch-zw')],
        client,
        _FakeCreds(_connInfo),
        chatSvc: svc,
        retryDelay: _fastRetry,
        notifyDesktop: (title, body, payload) async {
          calls.add(_DesktopNotifyCall(title, body, payload));
        },
        flashDesktop: () async {},
        updateDesktopBadge: (_) async {},
      );
      addTearDown(() async {
        await retryEvents.close();
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(svc.accountStreamListenCalls, greaterThanOrEqualTo(2));

      retryEvents.add({
        'kind': 'external_notification.created',
        'conversation_uuid': 'conv-zw',
        'blocks': [
          {
            'kind': 'external_notification',
            'data': {
              'notification_uuid': 'notification-retry',
              'conversation_uuid': 'conv-zw',
              'room_uuid': 'room-zw',
              'title': 'SSE 重连通知',
              'description': '账号级 SSE 重连后收到',
            },
          }
        ],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(calls.single.title, 'SSE 重连通知');
      expect(calls.single.body, '账号级 SSE 重连后收到');
      expect(calls.single.payload, 'conv-zw');
    });

    testWidgets('在 widget build 帧点击系统通知 → 帧后选中对应数字员工会话', (tester) async {
      final svc = _FakeChatSvc(const []);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
        const [],
        client,
        _FakeCreds(_connInfo),
        chatSvc: svc,
        updateDesktopBadge: (_) async {},
      );
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      svc.items = [_agent('conv-agent', 'ag1', ch: 'agent-ch')];

      var tapped = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              if (!tapped) {
                tapped = true;
                AppNotificationService.onNotificationTapped?.call('conv-agent');
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(svc.listCalls, greaterThanOrEqualTo(2));
      expect(
        c.read(chatProvider).asData?.value.activeConversationId,
        'conv-agent',
      );
      c.dispose();
      await client.dispose();
    });

    test('陌生 channel 来消息 → debounce refresh, 用权威快照补出新会话', () async {
      final svc = _FakeChatSvc(const []);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(const [], client, creds,
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 20));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      // 首连成功也会 refresh 一次,先 settle 掉,再验证陌生 channel 的补拉。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = svc.listCalls;
      svc.items = [_human('李娜', ch: 'ch-ln', unread: 1)];

      client.emit(const ImMessage(
        messageId: 'm-new-conv',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-ln',
        channelType: 2,
        timestamp: 1700000000,
        text: 'hello',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.listCalls, before + 1);
      expect(_list(c), hasLength(1));
      expect(_list(c).first.conversationId, '李娜');
    });

    test('已有其他会话时, 新人陌生 channel 来消息 → refresh 后出现在列表', () async {
      final svc = _FakeChatSvc([_human('张伟', ch: 'ch-zw')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(const [], client, creds,
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 20));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_list(c).map((e) => e.conversationId), contains('张伟'));
      final before = svc.listCalls;

      svc.items = [
        _human('李娜', ch: 'ch-ln', unread: 1),
        _human('张伟', ch: 'ch-zw'),
      ];
      client.emit(const ImMessage(
        messageId: 'm-new-peer-conv',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-ln',
        channelType: 2,
        timestamp: 1700000000,
        text: 'hello',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.listCalls, before + 1);
      expect(_list(c).map((e) => e.conversationId), containsAll(['李娜', '张伟']));
      expect(_byId(c, '李娜').unreadCount, 1);
    });

    test('自己发的消息经流回显 → 更新预览但不加未读', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(
          [_human('张伟', ch: 'ch-zw', unread: 0)], client, creds);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      client.emit(const ImMessage(
        messageId: 'm-self',
        clientMsgNo: '',
        fromUid: 'me', // 自己 (connectedUid)
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000000000,
        text: '我发的',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(_byId(c, '张伟').lastMessage, '我发的');
      expect(_byId(c, '张伟').unreadCount, 0); // 自回显不加未读
    });

    test('isRefresh 状态刷新经流 → bridge 跳过, 不改预览/不加未读', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(
          [_human('张伟', ch: 'ch-zw', unread: 0)], client, creds);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;

      // 他人消息的 refresh (如已读回执/反应): isRefresh=true, 不应被当新消息加未读/改预览。
      client.emit(const ImMessage(
        messageId: 'm-old',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000000,
        text: '不该成为预览的旧消息刷新',
        messageSeq: 5,
        isRefresh: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(_byId(c, '张伟').lastMessage, isNull); // 预览未变
      expect(_byId(c, '张伟').unreadCount, 0); // 未读未变
    });
  });

  group('ConversationRealtimeBridge 连接失败退避重试', () {
    for (final fails in [true, false]) {
      test('已连接后忽略迟到凭证${fails ? '失败' : '成功'}，不重新展示错误或重新登录', () async {
        final gate = Completer<void>();
        final client = _FakeImClient(connectMarksConnected: true);
        final creds = _FakeCreds(_connInfo,
            firstGate: gate.future,
            failTimes: fails ? 1 : 0,
            failure: DioException(
                requestOptions: RequestOptions(path: '/im/credentials'),
                type: DioExceptionType.connectionError));
        final c = await _bootBridge([], client, creds,
            retryDelay: (_) => const Duration(seconds: 30));
        addTearDown(() async {
          c.dispose();
          await client.dispose();
        });
        final bridge = c.read(conversationRealtimeBridgeProvider);
        await Future<void>.delayed(Duration.zero);
        client.emitStatus(ImConnectionStatus.connected);
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await bridge.connected;
        expect(bridge.connectionSnapshot.connection,
            ConversationConnectionState.connected);
        expect(bridge.hasPendingRetry, false);
        expect(client.loginCalls, 0);
        expect(client.connectCalls, 0);
      });
    }

    for (final fails in [false, true]) {
      test('恢复网络已有会话仍显示加载，重复事件不重复拉取，结束清除 loading failure=$fails', () async {
        final network = StreamController<List<ConnectivityResult>>.broadcast();
        final client =
            _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
        final svc = _FakeChatSvc([_human('cached', ch: 'cached')]);
        final c = await _bootBridge(svc.items, client, _FakeCreds(_connInfo),
            chatSvc: svc, networkChanges: network.stream);
        final gate = Completer<void>();
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          c.dispose();
          await network.close();
          await client.dispose();
        });
        final bridge = c.read(conversationRealtimeBridgeProvider);
        await bridge.connected;
        await Future<void>.delayed(Duration.zero);
        svc.listGate = gate.future;
        if (fails) {
          svc.listError = DioException(
              requestOptions: RequestOptions(path: '/chat/conversations'),
              type: DioExceptionType.connectionError);
        }
        network.add([ConnectivityResult.none]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(bridge.connectionSnapshot.isOffline, true);
        final calls = svc.listCalls;
        network.add([ConnectivityResult.wifi]);
        network.add([ConnectivityResult.wifi]);
        await Future<void>.delayed(Duration.zero);
        expect(bridge.connectionSnapshot.isOffline, false);
        expect(c.read(conversationsRefreshingProvider), true);
        expect(_list(c).single.conversationId, 'cached');
        expect(svc.listCalls, calls + 1);
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(c.read(conversationsRefreshingProvider), false);
        expect(_list(c).single.conversationId, 'cached');
      });
    }

    test('在线接口切换已有会话静默刷新，不闪加载条', () async {
      final network = StreamController<List<ConnectivityResult>>.broadcast();
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final svc = _FakeChatSvc([_human('cached', ch: 'cached')]);
      final c = await _bootBridge(svc.items, client, _FakeCreds(_connInfo),
          chatSvc: svc, networkChanges: network.stream);
      final gate = Completer<void>();
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        c.dispose();
        await network.close();
        await client.dispose();
      });
      await c.read(conversationRealtimeBridgeProvider).connected;
      await Future<void>.delayed(Duration.zero);
      svc.listGate = gate.future;
      final calls = svc.listCalls;
      network.add([ConnectivityResult.ethernet]);
      await Future<void>.delayed(Duration.zero);
      expect(svc.listCalls, calls + 1);
      expect(c.read(conversationsRefreshingProvider), false);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('网络恢复等待旧请求收尾后立即补连，不并发；kicked 后忽略恢复', () async {
      final network = StreamController<List<ConnectivityResult>>.broadcast();
      final gate = Completer<void>();
      final client = _FakeImClient(connectMarksConnected: true);
      final creds = _FakeCreds(_connInfo, failTimes: 1, firstGate: gate.future);
      final c = await _bootBridge([], client, creds,
          retryDelay: (_) => const Duration(seconds: 30),
          networkChanges: network.stream);
      addTearDown(() async {
        c.dispose();
        await network.close();
        await client.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await Future<void>.delayed(Duration.zero);
      network.add([ConnectivityResult.none]);
      network.add([ConnectivityResult.mobile]);
      network.add([ConnectivityResult.mobile]);
      await Future<void>.delayed(Duration.zero);
      expect(creds.fetchCalls, 1);
      expect((c.read(chatServiceProvider) as _FakeChatSvc).listCalls,
          greaterThan(1));
      gate.complete();
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(creds.fetchCalls, 2);
      expect(client.connectCalls, 1);
      expect(bridge.hasPendingRetry, false);
      client.emitStatus(ImConnectionStatus.kicked);
      await Future<void>.delayed(Duration.zero);
      network.add([ConnectivityResult.none]);
      network.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(client.connectCalls, 1);
      expect(creds.fetchCalls, 2);
    });

    test('网络恢复取消 30 秒退避，重复网络事件不重复连接，dispose 释放监听', () async {
      final network = StreamController<List<ConnectivityResult>>.broadcast();
      final client = _FakeImClient(connectMarksConnected: true);
      final creds = _FakeCreds(_connInfo,
          failTimes: 1,
          failure: DioException(
            requestOptions: RequestOptions(path: '/im/credentials'),
            type: DioExceptionType.connectionError,
          ));
      final c = await _bootBridge(
        [],
        client,
        creds,
        retryDelay: (_) => const Duration(seconds: 30),
        networkChanges: network.stream,
      );
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      expect(bridge.hasPendingRetry, true);
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.unavailable);
      network.add([ConnectivityResult.none]);
      await Future<void>.delayed(Duration.zero);
      expect(creds.fetchCalls, 1);
      network.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(client.connectCalls, 1);
      expect(bridge.hasPendingRetry, false);
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.connected);
      network.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(client.connectCalls, 1);
      c.dispose();
      expect(network.hasListener, false);
      await network.close();
      await client.dispose();
    });

    test('首次失败 → 调度重试 → 重试成功后 init/login/connect 被调用', () async {
      final client = _FakeImClient(connectMarksConnected: true); // 未连接
      final creds = _FakeCreds(_connInfo,
          failTimes: 1,
          failure: DioException(
            requestOptions: RequestOptions(path: '/im/credentials'),
            type: DioExceptionType.connectionError,
          )); // 第 1 次网络失败, 之后成功
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 第 1 次 attempt (失败)
      expect(creds.fetchCalls, 1);
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.unavailable);
      expect(client.connectCalls, 0); // 第 1 次没连上
      expect(bridge.hasPendingRetry, isTrue); // 已调度重试

      // 等退避 (5ms) + 第 2 次 attempt 完成。
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(creds.fetchCalls, 2); // 重试又拉了一次凭证
      expect(client.initCalls, 1);
      expect(client.loginCalls, 1);
      expect(client.connectCalls, 1);
      expect(client.connectedUid, 'me'); // 已连上
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.connected);
      expect(bridge.hasPendingRetry, isFalse); // 成功后清空重试
    });

    test('真实 connected 非空 → 不 fetch/init/login/connect, 不调度重试', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(creds.fetchCalls, 0);
      expect(client.initCalls, 0);
      expect(client.loginCalls, 0);
      expect(client.connectCalls, 0);
      expect(bridge.hasPendingRetry, isFalse);
    });

    test('dispose 后不再重试', () async {
      final client = _FakeImClient(); // 未连接
      final creds = _FakeCreds(_connInfo, failTimes: 99); // 一直失败
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 第 1 次失败, 调度重试
      expect(creds.fetchCalls, 1);
      expect(bridge.hasPendingRetry, isTrue);

      bridge.dispose(); // 取消 timer, 不再重试
      expect(bridge.hasPendingRetry, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(creds.fetchCalls, 1); // dispose 后没有再次尝试
      expect(client.connectCalls, 0);
    });

    test('start 多次 → 不重复订阅、不并发多次 connect', () async {
      final client = _FakeImClient(connectMarksConnected: true); // 未连接, 让连接链走起来
      final creds = _FakeCreds(_connInfo); // 首次即成功
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge =
          c.read(conversationRealtimeBridgeProvider); // provider 已 start 一次
      bridge.start(); // 再调一次
      bridge.start(); // 再调一次
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.listenCalls, 1); // 只订阅一次
      expect(creds.fetchCalls, 1); // 只 connect 一次
      expect(client.initCalls, 1);
      expect(client.loginCalls, 1);
      expect(client.connectCalls, 1);
    });

    test('SDK 长时间停在 connecting → watchdog 复位后按 backoff 刷新一次凭证', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.connecting,
        connectMarksConnected: true,
      );
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(
        [_human('张伟', ch: 'ch-zw')],
        client,
        creds,
        retryDelay: (_) => const Duration(milliseconds: 100),
        connectingWatchdog: const Duration(milliseconds: 5),
      );
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 第一轮看到 connecting，只挂 watchdog。
      expect(client.connectCalls, 0);
      expect(bridge.hasPendingRetry, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(client.disconnectCalls, 1);
      expect(creds.invalidateCalls, 1);
      expect(creds.fetchCalls, 0, reason: 'watchdog 不得立即拉凭证');
      expect(client.connectCalls, 0, reason: 'watchdog 不得绕过 capped backoff');
      expect(bridge.hasPendingRetry, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(creds.fetchCalls, 1);
      expect(client.initCalls, 1);
      expect(client.loginCalls, 1);
      expect(client.connectCalls, 1);
      expect(client.connectionStatus, ImConnectionStatus.connected);
      expect(bridge.hasPendingRetry, isFalse);
    });

    test('连续 connecting watchdog → 同一失败轮只刷新一次凭证', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.connecting,
      );
      final creds = _FakeCreds(_connInfo);
      final c = await _bootBridge(
        [_human('张伟', ch: 'ch-zw')],
        client,
        creds,
        retryDelay: (_) => const Duration(milliseconds: 15),
        connectingWatchdog: const Duration(milliseconds: 5),
      );
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(client.disconnectCalls, greaterThanOrEqualTo(2));
      expect(creds.invalidateCalls, 1);
      expect(creds.fetchCalls, 1);
      expect(bridge.isKicked, isFalse);
    });
  });

  group('HumanDirectImController 连接复用', () {
    test('已有 uid 但未真实 connected → 打开右侧 pane 仍会 connect', () async {
      final client = _FakeImClient(uid: 'me');
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.open(title: '张伟');

      expect(controller.error, isNull);
      expect(client.connectCalls, 1);
      expect(client.listenCalls, 1);
    });

    test('kicked 时打开 pane → 不重连/不取凭证/不建房, 给可读错误 (P2 修复)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.kicked);
      final creds = _FakeCreds(_connInfo);
      final controller = HumanDirectImController(
        // 用 peerAccountUuid (无 presetChannel): 若未短路, open 会走到 createDirectRoom。
        peerAccountUuid: 'peer-uuid',
        client: client,
        credentials: creds,
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.open(title: '张伟');

      // kicked 短路: 不 connect / 不 init / 不 login / 不 fetch 凭证 (→ createDirectRoom 也到不了)。
      expect(client.connectCalls, 0);
      expect(client.initCalls, 0);
      expect(client.loginCalls, 0);
      expect(creds.fetchCalls, 0);
      expect(controller.error, isNotNull);
      expect(controller.error, contains('踢下线'));
      expect(controller.loading, isFalse);
      expect(controller.isConnectionKicked, isTrue); // P3: pane 据此展示提示条
    });

    test('isConnectionKicked 反映 client 连接状态;kicked 翻转时通知 pane 重建 (P3)',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      await controller.open(title: '会话');
      expect(controller.isConnectionKicked, isFalse);

      var notifies = 0;
      controller.addListener(() => notifies++);
      client.emitStatus(ImConnectionStatus.kicked);
      await Future<void>.delayed(Duration.zero);

      expect(controller.isConnectionKicked, isTrue);
      expect(notifies, greaterThanOrEqualTo(1)); // kicked 翻转 → notifyListeners
    });

    test('已有 uid 且正在连接 → 打开右侧 pane 不打断重连', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.connecting,
      );
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.open(title: '张伟');

      expect(controller.error, isNull);
      expect(client.connectCalls, 0);
      expect(client.listenCalls, 1);
    });

    test('发送前长连接未就绪 → 不真正发送, 该条标记 failed (不假装 sent/不凭空消失)', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.connecting,
      );
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.open(title: '张伟');

      await expectLater(controller.sendText('hello'), throwsStateError);
      expect(client.sendTextCalls, 0); // 长连接未就绪 → 没真正发到 WuKong
      expect(controller.messages.length, 1);
      expect(controller.messages.single.text, 'hello');
      expect(controller.messages.single.sendStatus, ImSendStatus.failed);
    });

    test('发送前可重连成功 → 发送, pending 经 SDK 回显上屏 (发送中)', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.disconnected,
        connectMarksConnected: true,
      );
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.open(title: '张伟');
      await controller.sendText('hello');
      await Future<void>.delayed(Duration.zero); // 让 SDK pending 回显经广播流投递

      expect(client.connectCalls, 1);
      expect(client.sendTextCalls, 1);
      expect(client.lastSentText, 'hello');
      // pending 由 SDK msgInserted 回送 → _upsert 上屏 (不在 controller 手工乐观插入)。
      expect(controller.messages.map((m) => m.text), ['hello']);
      expect(controller.messages.single.sendStatus, ImSendStatus.pending);
    });
  });

  group('HumanDirectImController 消息可靠性 (P0: pending/对账/排序去重)', () {
    Future<HumanDirectImController> openController(
      _FakeImClient client, {
      int channelType = 2,
      String channelId = 'ch-zw',
    }) async {
      final controller = HumanDirectImController(
        presetChannelId: channelId,
        presetChannelType: channelType,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      await controller.open(title: '张伟');
      return controller;
    }

    test('1) 发送文本 → 先产生 pending (发送中)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendText('hi');
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1);
      expect(controller.messages.single.sendStatus, ImSendStatus.pending);
      expect(controller.messages.single.clientMsgNo, isNotEmpty);
      expect(controller.messages.single.messageSeq, 0); // 未 ack
    });

    test('2) 同 clientMsgNo 回显 → pending 替换为 sent, 补 messageId/messageSeq',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendText('hi');
      await Future<void>.delayed(Duration.zero);
      final cmn = client.lastClientMsgNo;

      // SDK ack: 同 clientMsgNo refresh, 填真实 messageId/messageSeq + status sent。
      client.emit(ImMessage(
        messageId: 'srv-1',
        clientMsgNo: cmn,
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000005,
        text: 'hi',
        messageSeq: 7,
        isRefresh: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1); // 替换, 不新增
      final m = controller.messages.single;
      expect(m.sendStatus, ImSendStatus.sent);
      expect(m.messageId, 'srv-1');
      expect(m.messageSeq, 7);
    });

    test('3) 自己回显不产生重复 (pending + ack 仍是 1 条)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendText('hi');
      await Future<void>.delayed(Duration.zero);
      final cmn = client.lastClientMsgNo;
      // newMsg 形态的自回显 (有真实 messageId, 同 clientMsgNo) 也不应重复。
      client.emit(ImMessage(
        messageId: 'srv-1',
        clientMsgNo: cmn,
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000005,
        text: 'hi',
        messageSeq: 7,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1);
      expect(controller.messages.single.messageId, 'srv-1');
    });

    test('4) sendTextMessage 抛错 → 标记 failed, 不显示 sent', () async {
      final client = _FakeImClient(
        uid: 'me',
        status: ImConnectionStatus.connected,
        sendThrows: true,
      );
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendText('hi'), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1);
      expect(controller.messages.single.sendStatus, ImSendStatus.failed);
      expect(controller.messages.single.text, 'hi');
    });

    test('5) 乱序实时消息 → 按 messageSeq 排序', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      ImMessage incoming(String id, int seq, String text) => ImMessage(
            messageId: id,
            clientMsgNo: '',
            fromUid: 'peer',
            channelId: 'ch-zw',
            channelType: 2,
            timestamp: 1700000000 + seq,
            text: text,
            messageSeq: seq,
          );
      client.emit(incoming('m3', 3, 'c'));
      client.emit(incoming('m1', 1, 'a'));
      client.emit(incoming('m2', 2, 'b'));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.map((m) => m.text).toList(), ['a', 'b', 'c']);
    });

    test('6) 历史 + 实时重叠 → 按 messageId/clientMsgNo 去重', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [
        const ImMessage(
          messageId: 'm9',
          clientMsgNo: 'c9',
          fromUid: 'peer',
          channelId: 'ch-zw',
          channelType: 2,
          timestamp: 1700000009,
          text: '历史',
          messageSeq: 9,
        ),
      ];
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      expect(controller.messages.length, 1); // 历史 1 条

      // 实时再投递同一条 (同 messageId) → 去重, 不新增。
      client.emit(const ImMessage(
        messageId: 'm9',
        clientMsgNo: 'c9',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000009,
        text: '历史',
        messageSeq: 9,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1);
    });

    test('7) 群聊 (channelType=2) 同样走 pending→sent 对账去重', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller =
          await openController(client, channelId: 'ch-g', channelType: 2);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendText('群消息');
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.single.sendStatus, ImSendStatus.pending);
      final cmn = client.lastClientMsgNo;

      client.emit(ImMessage(
        messageId: 'g-1',
        clientMsgNo: cmn,
        fromUid: 'me',
        channelId: 'ch-g',
        channelType: 2,
        timestamp: 1700000005,
        text: '群消息',
        messageSeq: 3,
        isRefresh: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.length, 1);
      expect(controller.messages.single.sendStatus, ImSendStatus.sent);
      expect(controller.messages.single.messageSeq, 3);
    });

    test('8) 打开后被踢下线再发送 → 标记 failed, 不真正 send (P1)', () async {
      // 正常打开 (channel 就绪), 之后被踢下线 → 发送应失败 (kicked 不真正 send)。
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      client.emitStatus(ImConnectionStatus.kicked); // 打开后被踢下线

      await expectLater(controller.sendText('hi'), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(client.sendTextCalls, 0); // kicked → 不真正 send
      expect(controller.messages.length, 1);
      expect(controller.messages.single.sendStatus, ImSendStatus.failed);
      expect(controller.messages.single.errorMessage, contains('踢下线'));
    });
  });

  group('ImConnInfo 连接凭证 TTL 解析 (P1)', () {
    test('解析 wukong.expires_at → expiresAt(UTC); 缺失 → null 不强制刷新', () {
      final withExp = ImConnInfo.fromCredentialsJson({
        'wukong': {
          'uid': 'u',
          'token': 't',
          'tcp_addr': 'h:1',
          'ws_addr': 'ws://h:1',
          'expires_at': '2099-12-31T00:00:00Z',
        }
      });
      expect(withExp, isNotNull);
      expect(withExp!.expiresAt, DateTime.utc(2099, 12, 31));
      expect(withExp.isExpiringSoon, isFalse);

      // 老后端不下发 expires_at → null = 未知, 不强制刷新。
      final noExp = ImConnInfo.fromCredentialsJson({
        'wukong': {
          'uid': 'u',
          'token': 't',
          'tcp_addr': 'h:1',
          'ws_addr': 'ws://h:1',
        }
      });
      expect(noExp!.expiresAt, isNull);
      expect(noExp.isExpiringSoon, isFalse);

      // 已过期 → isExpiringSoon。
      final expired = ImConnInfo.fromCredentialsJson({
        'wukong': {
          'uid': 'u',
          'token': 't',
          'expires_at': '2000-01-01T00:00:00Z',
        }
      });
      expect(expired!.isExpiringSoon, isTrue);
    });
  });

  group('ConversationRealtimeBridge 凭证 TTL / kicked (P1)', () {
    test('token 快过期 → reconnect 时重新 fetch credentials + login', () async {
      final client = _FakeImClient(connectMarksConnected: true); // 无 uid
      final creds = _FakeCreds(_expiringInfo());
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 首连: 无 uid → fetch (1) → login → connect
      expect(creds.fetchCalls, 1);

      // 掉线 → 退避重连; _lastConnInfo 快过期 → 再 fetch 一次。
      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(creds.fetchCalls, greaterThanOrEqualTo(2));
    });

    test('首连后 token 未过期 → reconnect 复用, 不再 fetch', () async {
      final client = _FakeImClient(connectMarksConnected: true); // 无 uid
      final creds = _FakeCreds(_freshInfo());
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // 首连: fetch (1)
      expect(creds.fetchCalls, 1);

      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(creds.fetchCalls, 1); // 未过期 → 复用, 不重复 fetch
    });

    test('kicked → 停止自动重连, isKicked=true, 不再 connect', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_freshInfo());
      final c = await _bootBridge([_human('张伟', ch: 'ch-zw')], client, creds,
          retryDelay: _fastRetry);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      final connectsBefore = client.connectCalls;

      client.emitStatus(ImConnectionStatus.kicked);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isKicked, isTrue);
      expect(bridge.hasPendingRetry, isFalse);

      // 即便随后再掉线, kicked 也不自动重连。
      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.connectCalls, connectsBefore);
      expect(bridge.hasPendingRetry, isFalse);
    });
  });

  group('device offline banner transitions', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 2));
    Future<void> confirm() =>
        Future<void>.delayed(const Duration(milliseconds: 40));

    Future<(ConversationRealtimeBridge, _FakeImClient)> boot({
      Future<List<ConnectivityResult>> Function()? check,
      Stream<List<ConnectivityResult>> changes = const Stream.empty(),
      _FakeCreds? creds,
      ImConnectionStatus status = ImConnectionStatus.connected,
    }) async {
      final client =
          _FakeImClient(uid: creds == null ? 'me' : null, status: status);
      final c = await _bootBridge([], client, creds ?? _FakeCreds(_connInfo),
          checkNetwork: check,
          networkChanges: changes,
          retryDelay: (_) => const Duration(seconds: 30));
      final bridge = c.read(conversationRealtimeBridgeProvider);
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      await settle();
      return (bridge, client);
    }

    for (final status in [
      ImConnectionStatus.idle,
      ImConnectionStatus.disconnected,
      ImConnectionStatus.noNetwork
    ]) {
      test('cold $status with available network never displays banner',
          () async {
        final gate = Completer<void>();
        final (bridge, _) = await boot(
            status: status,
            creds: _FakeCreds(_connInfo, firstGate: gate.future));
        expect(bridge.connectionSnapshot.connection,
            ConversationConnectionState.connecting);
        await confirm();
        expect(bridge.connectionSnapshot.isOffline, isFalse);
        gate.complete();
        await bridge.connected;
      });
    }

    test('cancelled credentials end connecting without offline banner',
        () async {
      final (bridge, _) = await boot(
          status: ImConnectionStatus.disconnected,
          creds: _FakeCreds(_connInfo,
              failTimes: 1,
              failure: DioException(
                  requestOptions: RequestOptions(path: '/im/credentials'),
                  type: DioExceptionType.cancel)));
      await bridge.connected;
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.cancelled);
      expect(bridge.connectionSnapshot.isUnavailable, isTrue);
      expect(bridge.connectionSnapshot.isOffline, isFalse);
    });

    test('cold offline waits for confirmation then displays banner', () async {
      final (bridge, _) =
          await boot(check: () async => [ConnectivityResult.none]);
      expect(bridge.connectionSnapshot.network,
          ConversationNetworkState.confirmingOffline);
      expect(bridge.connectionSnapshot.isOffline, isFalse);
      await confirm();
      expect(bridge.connectionSnapshot.isOffline, isTrue);
    });

    test('short offline and repeated switches never flash', () async {
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);
      final (bridge, _) = await boot(changes: changes.stream);
      final shown = <bool>[];
      final subscription =
          bridge.connectionChanges.listen((s) => shown.add(s.isOffline));
      addTearDown(subscription.cancel);
      for (var i = 0; i < 3; i++) {
        changes.add([ConnectivityResult.none]);
        await settle();
        changes.add([ConnectivityResult.wifi]);
        await settle();
      }
      await confirm();
      expect(shown, isNot(contains(true)));
      expect(bridge.connectionSnapshot.network,
          ConversationNetworkState.available);
    });

    test('network recovery hides immediately even when server fails again',
        () async {
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);
      final (bridge, client) = await boot(
          changes: changes.stream,
          check: () async => [ConnectivityResult.none]);
      await confirm();
      expect(bridge.connectionSnapshot.isOffline, isTrue);
      changes.add([ConnectivityResult.mobile]);
      await settle();
      expect(bridge.connectionSnapshot.isOffline, isFalse);
      client.emitStatus(ImConnectionStatus.disconnected);
      client.emitStatus(ImConnectionStatus.noNetwork);
      await confirm();
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.unavailable);
      expect(bridge.connectionSnapshot.isOffline, isFalse);
    });

    for (final offlineOnResume in [false, true]) {
      test('background none rechecked on resume offline=$offlineOnResume',
          () async {
        final changes = StreamController<List<ConnectivityResult>>();
        addTearDown(changes.close);
        var network = [ConnectivityResult.wifi];
        final (bridge, _) =
            await boot(changes: changes.stream, check: () async => network);
        bridge.onAppBackgrounded();
        changes.add([ConnectivityResult.none]);
        await confirm();
        expect(bridge.connectionSnapshot.isOffline, isFalse);
        network = [
          offlineOnResume ? ConnectivityResult.none : ConnectivityResult.wifi
        ];
        bridge.onAppResumed();
        await settle();
        expect(bridge.connectionSnapshot.isOffline, isFalse);
        await confirm();
        expect(bridge.connectionSnapshot.isOffline, offlineOnResume);
      });
    }

    test('confirmed offline cleared by fresh resume observation', () async {
      var network = [ConnectivityResult.none];
      final (bridge, _) = await boot(check: () async => network);
      await confirm();
      expect(bridge.connectionSnapshot.isOffline, isTrue);
      bridge.onAppBackgrounded();
      network = [ConnectivityResult.wifi];
      bridge.onAppResumed();
      await settle();
      expect(bridge.connectionSnapshot.isOffline, isFalse);
    });

    test('late initial none cannot override newer available event', () async {
      final pending = Completer<List<ConnectivityResult>>();
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);
      final (bridge, _) =
          await boot(changes: changes.stream, check: () => pending.future);
      changes.add([ConnectivityResult.wifi]);
      await settle();
      pending.complete([ConnectivityResult.none]);
      await confirm();
      expect(bridge.connectionSnapshot.network,
          ConversationNetworkState.available);
    });

    test('older check cannot override new foreground check', () async {
      final old = Completer<List<ConnectivityResult>>();
      var calls = 0;
      final (bridge, _) = await boot(
          check: () => ++calls == 1
              ? old.future
              : Future.value([ConnectivityResult.mobile]));
      bridge.onAppBackgrounded();
      bridge.onAppResumed();
      await settle();
      old.complete([ConnectivityResult.none]);
      await confirm();
      expect(bridge.connectionSnapshot.network,
          ConversationNetworkState.available);
    });

    for (final result in ['empty', 'error', 'mixed']) {
      test('network observation $result cannot fabricate offline', () async {
        final (bridge, _) = await boot(check: () async {
          if (result == 'error') throw StateError('platform unavailable');
          return result == 'empty'
              ? []
              : [ConnectivityResult.none, ConnectivityResult.wifi];
        });
        await confirm();
        expect(
            bridge.connectionSnapshot.network,
            result == 'mixed'
                ? ConversationNetworkState.available
                : ConversationNetworkState.unknown);
        expect(bridge.connectionSnapshot.isOffline, isFalse);
      });
    }

    for (final failure in [false, true]) {
      test('logout rejects late credentials failure=$failure and SDK events',
          () async {
        final gate = Completer<void>();
        final (bridge, client) = await boot(
            status: ImConnectionStatus.disconnected,
            check: () async => [ConnectivityResult.none],
            creds: _FakeCreds(_connInfo,
                firstGate: gate.future, failTimes: failure ? 1 : 0));
        client.emitStatus(ImConnectionStatus.idle);
        await settle();
        gate.complete();
        await bridge.connected;
        client.emitStatus(ImConnectionStatus.connected);
        client.emitStatus(ImConnectionStatus.noNetwork);
        bridge.onAppResumed();
        await confirm();
        expect(client.loginCalls, 0);
        expect(client.connectCalls, 0);
        expect(bridge.hasPendingRetry, isFalse);
        expect(bridge.connectionSnapshot.connection,
            ConversationConnectionState.idle);
        expect(bridge.connectionSnapshot.network,
            ConversationNetworkState.unknown);
      });
    }

    test('kicked terminates pending offline confirmation and reconnect',
        () async {
      final (bridge, client) =
          await boot(check: () async => [ConnectivityResult.none]);
      client.emitStatus(ImConnectionStatus.kicked);
      await confirm();
      bridge.onAppResumed();
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.kicked);
      expect(bridge.connectionSnapshot.isOffline, isFalse);
      expect(bridge.hasPendingRetry, isFalse);
    });

    test('dispose rejects pending network check', () async {
      final pending = Completer<List<ConnectivityResult>>();
      final (bridge, _) = await boot(check: () => pending.future);
      bridge.dispose();
      pending.complete([ConnectivityResult.none]);
      await confirm();
      expect(
          bridge.connectionSnapshot.network, ConversationNetworkState.unknown);
    });
  });

  group('foreground recovery presentation', () {
    for (final outcome in ['connected', 'failed', 'noNetwork', 'timeout']) {
      test('background disconnect then $outcome', () async {
        final client =
            _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
        final c = await _bootBridge([], client, _FakeCreds(_connInfo),
            retryDelay: (_) => const Duration(seconds: 30),
            connectingWatchdog: const Duration(milliseconds: 100));
        addTearDown(() async {
          c.dispose();
          await client.dispose();
        });
        final bridge = c.read(conversationRealtimeBridgeProvider);
        await bridge.connected;
        final shown = <bool>[];
        c.listen(conversationConnectionStateProvider, (_, next) {
          if (next.hasValue) shown.add(next.value!.isOffline);
        }, fireImmediately: true);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        bridge.onAppBackgrounded();
        client.emitStatus(ImConnectionStatus.disconnected);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        bridge.onAppResumed();
        await Future<void>.delayed(const Duration(milliseconds: 2));
        expect(client.connectCalls, 1);
        expect(client.connectionStatus, ImConnectionStatus.connecting);
        expect(shown, isNot(contains(true)));
        expect(bridge.connectionSnapshot.connection,
            ConversationConnectionState.recovering);
        if (outcome == 'timeout') {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        } else {
          client.emitStatus(switch (outcome) {
            'connected' => ImConnectionStatus.connected,
            'noNetwork' => ImConnectionStatus.noNetwork,
            _ => ImConnectionStatus.disconnected,
          });
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(
            bridge.connectionSnapshot.connection,
            outcome == 'connected'
                ? ConversationConnectionState.connected
                : ConversationConnectionState.unavailable);
        expect(c.read(conversationConnectionUnavailableProvider).value,
            outcome != 'connected');
        if (outcome == 'connected') {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(shown, isNot(contains(true)));
        }
      });
    }

    test('background watchdog does not expire during a fresh resume window',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge([], client, _FakeCreds(_connInfo),
          retryDelay: (_) => const Duration(seconds: 30),
          connectingWatchdog: const Duration(milliseconds: 200));
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      bridge.onAppBackgrounded();
      client.emitStatus(ImConnectionStatus.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      bridge.onAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(client.disconnectCalls, 0);
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.recovering);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(bridge.connectionSnapshot.connection,
          ConversationConnectionState.connected);
    });

    test('known failure stops loading without an offline banner', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge([], client, _FakeCreds(_connInfo),
          retryDelay: (_) => const Duration(seconds: 30));
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      c.listen(conversationConnectionUnavailableProvider, (_, __) {});
      client.emitStatus(ImConnectionStatus.noNetwork);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(c.read(conversationConnectionUnavailableProvider).value, isTrue);
      bridge.onAppBackgrounded();
      bridge.onAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(bridge.connectionSnapshot.isOffline, false);
      expect(c.read(conversationConnectionUnavailableProvider).value, isTrue);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(c.read(conversationConnectionUnavailableProvider).value, isFalse);
    });

    test('stale connected snapshot on resume waits for actual reconnection',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge([], client, _FakeCreds(_connInfo),
          retryDelay: (_) => const Duration(seconds: 30));
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      final shown = <bool>[];
      c.listen(conversationConnectionStateProvider, (_, next) {
        if (next.hasValue) shown.add(next.value!.isOffline);
      });
      bridge.onAppBackgrounded();
      bridge.onAppResumed();
      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(client.connectCalls, 1);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(shown, isNot(contains(true)));
    });
  });

  group('ConversationRealtimeBridge reconnect/resume gap refresh (P1)', () {
    test('reconnect/syncCompleted → 状态跃迁时 debounce 一次 conversations refresh',
        () async {
      final svc = _FakeChatSvc([_group('群', ch: 'g-1', unread: 2)]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_freshInfo());
      final c = await _bootBridge([], client, creds,
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 50));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected; // _onConnectSuccess → schedule refresh
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final afterBuild = svc.listCalls; // build + 首连 gap refresh 已落定

      // 已经 connected 时，SDK 重复上报 success / syncCompleted 不应继续刷列表。
      client.emitStatus(ImConnectionStatus.connected);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(svc.listCalls, afterBuild);

      // 只有从非 connected 回到 connected，才需要补一次离线 gap 快照。
      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(Duration.zero);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.hasPendingConvRefresh, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(svc.listCalls, afterBuild + 1);
    });

    test('onAppResumed → debounce 一次 conversations refresh', () async {
      final svc = _FakeChatSvc([_group('群', ch: 'g-1')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_freshInfo());
      final c = await _bootBridge([], client, creds,
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 30));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(
          const Duration(milliseconds: 60)); // 首连 refresh 落定
      final before = svc.listCalls;

      bridge.onAppResumed();
      expect(bridge.hasPendingConvRefresh, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(svc.listCalls, before + 1);

      final afterFirstResume = svc.listCalls;
      bridge.onAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        svc.listCalls,
        afterFirstResume,
        reason: '短时间内反复 resumed 不应重复刷新对话列表',
      );
    });

    test('实时 +1 后 refresh → unread 仍以 WuKong 快照为准 (不被本地覆盖)', () async {
      final svc = _FakeChatSvc([_human('张伟', ch: 'ch-zw', unread: 2)]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final creds = _FakeCreds(_freshInfo());
      final c = await _bootBridge([], client, creds,
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 20));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      await Future<void>.delayed(
          const Duration(milliseconds: 40)); // 首连 refresh 落定 (unread=2)

      // 实时来一条他人消息 → 本地乐观 +1。
      client.emit(const ImMessage(
        messageId: 'm1',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000000,
        text: '在吗',
      ));
      await Future<void>.delayed(Duration.zero);
      expect(_byId(c, '张伟').unreadCount, 3); // 本地乐观 +1

      // 触发 refresh (模拟真实 reconnect) → 服务端快照 unread=2 → 回到 WuKong 权威。
      client.emitStatus(ImConnectionStatus.disconnected);
      await Future<void>.delayed(Duration.zero);
      client.emitStatus(ImConnectionStatus.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_byId(c, '张伟').unreadCount, 2); // WuKong 权威, 不被本地 +1 覆盖
    });
  });

  group('ConversationRealtimeBridge 会话级事件 refresh (P1)', () {
    const deleted = ImConversationEvent(
      kind: ImConversationEventKind.deleted,
      channelId: 'g-1',
      channelType: 2,
    );
    const unreadChanged =
        ImConversationEvent(kind: ImConversationEventKind.unreadChanged);

    Future<(ProviderContainer, _FakeImClient, _FakeChatSvc)> bootSettled(
      _FakeChatSvc svc, {
      Duration debounce = const Duration(milliseconds: 30),
    }) async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge([], client, _FakeCreds(_freshInfo()),
          chatSvc: svc, refreshDebounce: debounce);
      final bridge = c.read(conversationRealtimeBridgeProvider);
      await bridge.connected;
      // 首连 _onConnectSuccess 也会 schedule 一次 refresh,先 settle 掉它再测会话事件。
      await Future<void>.delayed(debounce + const Duration(milliseconds: 20));
      return (c, client, svc);
    }

    test('会话事件(删除)→ debounce 一次 conversations refresh', () async {
      final svc = _FakeChatSvc([_group('群', ch: 'g-1', unread: 2)]);
      final (c, client, _) = await bootSettled(svc);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      final before = svc.listCalls;

      client.emitConvEvent(deleted);
      await Future<void>.delayed(Duration.zero); // 广播事件异步投递到 bridge
      expect(bridge.hasPendingConvRefresh, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(svc.listCalls, before + 1); // 事件触发一次 refresh
    });

    test('连续多个会话事件 → debounce 合并为一次 refresh', () async {
      final svc = _FakeChatSvc([_group('群', ch: 'g-1', unread: 2)]);
      final (c, client, _) = await bootSettled(svc);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final before = svc.listCalls;

      client.emitConvEvent(deleted);
      client.emitConvEvent(unreadChanged);
      client.emitConvEvent(deleted);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(svc.listCalls, before + 1); // 合并一次, 不是三次
    });

    test('会话事件 refresh → unread 以 WuKong 服务端快照为准(不被本地乐观覆盖)', () async {
      final svc = _FakeChatSvc([_human('张伟', ch: 'ch-zw', unread: 2)]);
      final (c, client, _) =
          await bootSettled(svc, debounce: const Duration(milliseconds: 20));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      // 本地乐观清零。
      c.read(conversationsProvider.notifier).clearUnreadLocally('张伟');
      expect(_byId(c, '张伟').unreadCount, 0);

      // 会话事件触发 refresh → 服务端 unread=2 覆盖本地乐观 0。
      client.emitConvEvent(unreadChanged);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(_byId(c, '张伟').unreadCount, 2); // WuKong 权威
    });

    test('会话事件本身不直接 patch 列表;只有 debounce refresh 后才变化', () async {
      final svc = _FakeChatSvc([_human('张伟', ch: 'ch-zw', unread: 2)]);
      final (c, client, _) =
          await bootSettled(svc, debounce: const Duration(milliseconds: 60));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });

      // 模拟服务端快照变化(事件本身不携带这个值)。
      svc.items = [_human('张伟', ch: 'ch-zw', unread: 7)];
      client.emitConvEvent(deleted);
      await Future<void>.delayed(Duration.zero);
      expect(_byId(c, '张伟').unreadCount, 2); // 事件本身没 patch(仍是旧快照)

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(_byId(c, '张伟').unreadCount, 7); // refresh 后才用新服务端快照
    });

    test('dispose 后再来会话事件 → 不 refresh', () async {
      final svc = _FakeChatSvc([_group('群', ch: 'g-1', unread: 2)]);
      final (c, client, _) = await bootSettled(svc);
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final bridge = c.read(conversationRealtimeBridgeProvider);
      final before = svc.listCalls;

      bridge.dispose();
      client.emitConvEvent(deleted);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(svc.listCalls, before); // dispose 后不再 refresh
    });
  });

  group('ConversationRealtimeBridge WuKong 回执信号', () {
    test('read_receipt.changed → 转发到本地 ChatReadReceiptEventBus', () async {
      final svc = _FakeChatSvc([_human('李娜', ch: 'ch-ln')]);
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final c = await _bootBridge(
          [_human('李娜', ch: 'ch-ln')], client, _FakeCreds(_freshInfo()),
          chatSvc: svc, refreshDebounce: const Duration(milliseconds: 20));
      addTearDown(() async {
        await client.dispose();
        c.dispose();
      });
      final received = c
          .read(chatReadReceiptEventBusProvider)
          .stream
          .first
          .timeout(const Duration(seconds: 1));

      c.read(conversationRealtimeBridgeProvider);
      expect(client.readReceiptSignalListenCalls, 1);
      expect(svc.accountStreamListenCalls, 1);
      client.emitReadReceiptSignal(const ImReadReceiptSignal(
        conversationUuid: 'conv-ln',
        lastReadMessageSeq: 42,
      ));

      final event = await received;
      expect(event.conversationUuid, 'conv-ln');
      expect(event.lastReadMessageSeq, 42);
    });
  });

  group('HumanDirectImController 历史分页 + 文本重发 (P1)', () {
    Future<HumanDirectImController> openController(_FakeImClient client,
        {String? clearedAt}) async {
      final controller = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        presetClearedAt: clearedAt,
        client: client,
        credentials: _FakeCreds(_connInfo),
      );
      await controller.open(title: '会话');
      return controller;
    }

    test('满页 → hasMoreHistory=true;上拉加载更早页 → 锚点=最早 messageSeq, upsert 去重排序',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = _histRange(11, 50); // 40 条 → 满页
      client.olderHistory = _histRange(1, 11); // 更早 11 条(seq=11 与首页重叠 → 去重)
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      expect(controller.hasMoreHistory, isTrue);
      expect(controller.messages.length, 40);
      expect(controller.messages.first.messageSeq, 11);

      await controller.loadMoreHistory();
      expect(client.lastHistoryBeforeSeq, 11); // 以最早 messageSeq 为锚点
      expect(controller.messages.length, 50); // 40 + 10 新(seq=11 去重)
      expect(controller.messages.first.messageSeq, 1); // 升序:现在最早是 1
      expect(controller.hasMoreHistory, isFalse); // 更早页 11<40 → 没有更多
    });

    test('clearedAt 过滤本地历史缓存,并透传 conversation 给 WuKong 同步代理', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = <ImMessage>[
        _histMsg(1, timestamp: 100),
        _histMsg(2, timestamp: 101),
      ];
      final controller = await openController(client,
          clearedAt: DateTime.fromMillisecondsSinceEpoch(100000)
              .toUtc()
              .toIso8601String());
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      expect(controller.messages.map((m) => m.messageSeq).toList(), [2]);
      expect(client.lastHistoryConversationUuid, 'conv-zw');
      expect(client.lastHistoryClearedAt, isNotEmpty);
    });

    test('第一页不足一页 → hasMoreHistory=false', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = _histRange(1, 5);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      expect(controller.hasMoreHistory, isFalse);
    });

    test('loadMoreHistory 返回空 → hasMoreHistory=false 且不再重复触发', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = _histRange(11, 50);
      client.olderHistory = const [];
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      expect(controller.hasMoreHistory, isTrue);

      await controller.loadMoreHistory();
      expect(controller.hasMoreHistory, isFalse);

      client.lastHistoryBeforeSeq = -99;
      await controller.loadMoreHistory();
      expect(
          client.lastHistoryBeforeSeq, -99); // hasMore=false → 直接返回, 没再 fetch
    });

    test('loadMoreHistory 返回满页但去重后无进展 → hasMoreHistory=false,避免顶部慢滚重复触发',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = _histRange(11, 50);
      client.olderHistory = _histRange(11, 50); // 满页但全是重复消息,最早 seq 不前移
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      expect(controller.hasMoreHistory, isTrue);

      await controller.loadMoreHistory();
      expect(client.lastHistoryBeforeSeq, 11);
      expect(controller.messages.length, 40);
      expect(controller.messages.first.messageSeq, 11);
      expect(controller.hasMoreHistory, isFalse);

      client.lastHistoryBeforeSeq = -99;
      await controller.loadMoreHistory();
      expect(client.lastHistoryBeforeSeq, -99);
    });

    test('failed 文本重发 → 多调一次 sendTextMessage + 新 pending(旧 failed 保留)',
        () async {
      final client = _FakeImClient(
          uid: 'me', status: ImConnectionStatus.connected, sendThrows: true);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendText('hi'), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final failed = controller.messages.firstWhere((m) => m.isFailed);
      final callsBefore = client.sendTextCalls;

      client.sendThrows = false; // 重发成功
      await controller.retryTextMessage(failed);
      await Future<void>.delayed(Duration.zero);

      expect(client.sendTextCalls, callsBefore + 1);
      expect(
          controller.messages
              .where((m) => m.sendStatus == ImSendStatus.pending)
              .length,
          1);
      expect(controller.messages.where((m) => m.isFailed).length,
          1); // 旧 failed 保留
      expect(controller.messages.length, 2);
    });

    test('kicked 状态重发 → 不真正 send, failed 仍在', () async {
      final client = _FakeImClient(
          uid: 'me', status: ImConnectionStatus.connected, sendThrows: true);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendText('hi'), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final failed = controller.messages.firstWhere((m) => m.isFailed);
      final callsBefore = client.sendTextCalls;

      client.sendThrows = false;
      client.emitStatus(ImConnectionStatus.kicked);
      await expectLater(controller.retryTextMessage(failed), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(client.sendTextCalls, callsBefore); // kicked → ensure 抛错, 没真正 send
      expect(controller.messages.any((m) => m.isFailed), isTrue);
    });

    test('媒体 failed 不触发文本重发 (no-op)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      const mediaFailed = ImMessage(
        messageId: 'x',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 0,
        text: '[图片]',
        sendStatus: ImSendStatus.failed,
        mediaKind: ImMediaKind.image,
        mediaUrl: 'u',
      );
      final before = client.sendTextCalls;
      await controller.retryTextMessage(mediaFailed);
      expect(client.sendTextCalls, before); // 媒体 → no-op
    });

    test('对端 failed 文本不可重发 (owner 校验 → no-op)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openController(client); // _myUid='me'
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      const peerFailed = ImMessage(
        messageId: 'p1',
        clientMsgNo: '',
        fromUid: 'peer', // 非自己
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 0,
        text: '别人的失败文本',
        sendStatus: ImSendStatus.failed,
      );
      final before = client.sendTextCalls;
      await controller.retryTextMessage(peerFailed);
      expect(client.sendTextCalls, before); // 非自己 → 不真正 send
      expect(
          controller.messages
              .where((m) => m.sendStatus == ImSendStatus.pending),
          isEmpty); // 不新增 pending
    });
  });

  group('HumanDirectImController 媒体 failed 预留态 + 重发 (P1)', () {
    Future<HumanDirectImController> openMediaController(
      _FakeImClient client, {
      _FakeFilesSvc? files,
      _FakeChatMedia? media,
      String channelId = 'ch-zw',
      int channelType = 2,
    }) async {
      final controller = HumanDirectImController(
        presetChannelId: channelId,
        presetChannelType: channelType,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
        chatMedia: media ?? _FakeChatMedia(),
        filesService: files ?? _FakeFilesSvc(),
      );
      await controller.open(title: '会话');
      return controller;
    }

    test('1) 本地图片发送失败 → failed image 预留态(保留 mediaLocalPath,不显示 sent)',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(throwOnUpload: true);
      final controller = await openMediaController(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendLocalImage('/p/a.png', 'a.png'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      expect(client.sendMediaCalls, 0); // 没真正发到 WuKong
      expect(controller.messages.length, 1);
      final m = controller.messages.single;
      expect(m.sendStatus, ImSendStatus.failed);
      expect(m.mediaKind, ImMediaKind.image);
      expect(m.mediaLocalPath, '/p/a.png');
      expect(m.mediaName, 'a.png');
    });

    test('2) 本地文件发送失败 → failed file 预留态(保留 mediaLocalPath)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(throwOnUpload: true);
      final controller = await openMediaController(client, files: files);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendLocalFile('/p/b.pdf', 'b.pdf'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      final m = controller.messages.single;
      expect(m.sendStatus, ImSendStatus.failed);
      expect(m.mediaKind, ImMediaKind.file);
      expect(m.mediaLocalPath, '/p/b.pdf');
    });

    test('3) 云盘文件发送失败 → failed 预留态(保留 mediaFileUuid,无 localPath)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final media = _FakeChatMedia(throwOnCreate: true);
      final controller = await openMediaController(client, media: media);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(
          controller.sendDriveFile(_driveFile('drv-1', 'doc.pdf')),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      final m = controller.messages.single;
      expect(m.sendStatus, ImSendStatus.failed);
      expect(m.mediaKind, ImMediaKind.file);
      expect(m.mediaFileUuid, 'drv-1');
      expect(m.mediaLocalPath, isEmpty);
    });

    test('4) 本地图片重发成功 → 新 pending,旧 failed 保留', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(throwOnUpload: true);
      final controller = await openMediaController(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendLocalImage('/p/a.png', 'a.png'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      final failed = controller.messages.firstWhere((m) => m.isFailed);
      final before = client.sendMediaCalls;

      files.throwOnUpload = false; // 重发成功
      await controller.retryMediaMessage(failed);
      await Future<void>.delayed(Duration.zero);

      expect(client.sendMediaCalls, before + 1); // 真正发了一次
      expect(
          controller.messages.where((m) => m.isPending).length, 1); // 新 pending
      expect(controller.messages.where((m) => m.isFailed).length,
          1); // 旧 failed 保留
      expect(controller.messages.length, 2);
    });

    test('5) 云盘文件重发成功 → 新 pending,旧 failed 保留', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final media = _FakeChatMedia(throwOnCreate: true);
      final controller = await openMediaController(client, media: media);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(
          controller.sendDriveFile(_driveFile('drv-1', 'doc.pdf')),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      final failed = controller.messages.firstWhere((m) => m.isFailed);
      final before = client.sendMediaCalls;

      media.throwOnCreate = false; // 重发成功
      await controller.retryMediaMessage(failed);
      await Future<void>.delayed(Duration.zero);

      expect(client.sendMediaCalls, before + 1);
      expect(controller.messages.where((m) => m.isPending).length, 1);
      expect(controller.messages.where((m) => m.isFailed).length, 1);
      expect(controller.messages.length, 2);
    });

    test('6) 对端 failed 媒体重发 → no-op(owner 校验)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openMediaController(client); // _myUid='me'
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      const peerFailed = ImMessage(
        messageId: 'p1',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 0,
        text: '[图片]',
        sendStatus: ImSendStatus.failed,
        mediaKind: ImMediaKind.image,
        mediaLocalPath: '/x',
      );
      final before = client.sendMediaCalls;
      await controller.retryMediaMessage(peerFailed);
      expect(client.sendMediaCalls, before); // 非自己 → 不发
      expect(controller.messages.where((m) => m.isPending), isEmpty);
    });

    test('7) pending/sent 媒体重发 → no-op', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openMediaController(client);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });
      const pendingMedia = ImMessage(
        messageId: '',
        clientMsgNo: 'c-p',
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 0,
        text: '[图片]',
        sendStatus: ImSendStatus.pending,
        mediaKind: ImMediaKind.image,
        mediaLocalPath: '/x',
      );
      const sentMedia = ImMessage(
        messageId: 'm-s',
        clientMsgNo: 'c-s',
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 0,
        text: '[图片]',
        sendStatus: ImSendStatus.sent,
        mediaKind: ImMediaKind.image,
        mediaFileUuid: 'drv-x',
      );
      final before = client.sendMediaCalls;
      await controller.retryMediaMessage(pendingMedia);
      await controller.retryMediaMessage(sentMedia);
      expect(client.sendMediaCalls, before); // 非 failed → 不发
    });

    test('8) 群聊(channelType=2)媒体发送失败同样生成 failed 预留态', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final media = _FakeChatMedia(throwOnCreate: true);
      final controller = await openMediaController(client,
          media: media, channelId: 'ch-g', channelType: 2);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendDriveFile(_driveFile('drv-g', 'g.pdf')),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      final m = controller.messages.single;
      expect(m.isFailed, isTrue);
      expect(m.channelId, 'ch-g');
      expect(m.mediaFileUuid, 'drv-g');
    });

    test('9) 本端未 ack 图片后再发云盘文件 → 保持用户发送顺序,不被 ack 文件插队', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(autoComplete: false);
      final controller = await openMediaController(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      final uploadFuture = controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.single.text, '[图片]');
      expect(controller.messages.single.messageSeq, 0);

      // 模拟后选的云盘文件先拿到服务端 seq。旧排序按 seq 会把它插到未 ack 图片前面。
      client.emit(const ImMessage(
        messageId: 'srv-file',
        clientMsgNo: 'cmn-file',
        fromUid: 'me',
        channelId: 'ch-zw',
        channelType: 2,
        timestamp: 1700000005,
        text: '30天学习汉语计划.xlsx',
        messageSeq: 9,
        sendStatus: ImSendStatus.sent,
        mediaKind: ImMediaKind.file,
        mediaUrl: '/chat/media/ref/download',
        mediaName: '30天学习汉语计划.xlsx',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.map((m) => m.text).toList(),
          ['[图片]', '30天学习汉语计划.xlsx']);

      files.completeUpload();
      await uploadFuture;
    });
  });

  group('HumanDirectImController 媒体上传进度 / 取消 (P2/P3)', () {
    Future<HumanDirectImController> openCtrl(
      _FakeImClient client, {
      _FakeFilesSvc? files,
      _FakeChatMedia? media,
      String channelId = 'ch-zw',
      int channelType = 2,
    }) async {
      final controller = HumanDirectImController(
        presetChannelId: channelId,
        presetChannelType: channelType,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
        chatMedia: media ?? _FakeChatMedia(),
        filesService: files ?? _FakeFilesSvc(),
      );
      await controller.open(title: '会话');
      return controller;
    }

    test('1) 本地图片发送 → 立即生成 uploading 预留态(localPath/name/进度,尚未发 WuKong)',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(autoComplete: false); // 挂起在上传中
      final controller = await openCtrl(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      final fut = controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);

      final m = controller.messages.singleWhere((x) => x.isUploading);
      expect(m.sendStatus, ImSendStatus.pending);
      expect(m.mediaKind, ImMediaKind.image);
      expect(m.mediaLocalPath, '/p/a.png');
      expect(m.mediaName, 'a.png');
      expect(m.uploadProgress, greaterThanOrEqualTo(0));
      expect(client.sendMediaCalls, 0); // 还没发 WuKong

      files.completeUpload();
      await fut;
    });

    test('2) 上传 progress 回调更新预留态 uploadProgress', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(autoComplete: false);
      final controller = await openCtrl(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      final fut = controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);
      files.emitProgress(50, 100);
      await Future<void>.delayed(Duration.zero);

      expect(
          controller.messages.singleWhere((x) => x.isUploading).uploadProgress,
          50);

      files.completeUpload();
      await fut;
    });

    test('3) 上传中取消 → 预留态 failed(已取消),不建 ref/不发 WuKong;可重发', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final media = _FakeChatMedia(isImage: true);
      final files = _FakeFilesSvc(autoComplete: false);
      final controller = await openCtrl(client, files: files, media: media);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      final fut = controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);
      final uploading = controller.messages.singleWhere((x) => x.isUploading);

      controller.cancelMediaUpload(uploading);
      await fut; // 上传 future 因 cancel resolve(swallowed,不抛)
      await Future<void>.delayed(Duration.zero);

      final cancelled = controller.messages.singleWhere((x) => x.isFailed);
      expect(cancelled.errorMessage, contains('取消'));
      expect(cancelled.mediaLocalPath, '/p/a.png'); // 保留可重发
      expect(media.createCalls, 0); // 没建 chat media ref
      expect(client.sendMediaCalls, 0); // 没发 WuKong

      // 重发 → 重新走上传(新 uploading 预留态,旧 failed 保留)。
      final retryFut = controller.retryMediaMessage(cancelled);
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.where((x) => x.isUploading).length, 1);
      expect(controller.messages.where((x) => x.isFailed).length, 1);

      files.completeUpload();
      await retryFut;
    });

    test('4) 上传失败 → 只一条 failed(不重复),保留 localPath', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(throwOnUpload: true);
      final controller = await openCtrl(client, files: files);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendLocalImage('/p/a.png', 'a.png'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      final failedList = controller.messages.where((x) => x.isFailed).toList();
      expect(failedList.length, 1); // 不重复
      expect(failedList.single.mediaLocalPath, '/p/a.png');
      expect(failedList.single.mediaKind, ImMediaKind.image);
    });

    test('5) 上传成功 → 上传预留态被移除,由 SDK pending 上屏(不重复)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(autoComplete: true); // 直接成功
      final controller = await openCtrl(client,
          files: files, media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.where((x) => x.isUploading),
          isEmpty); // upload entry removed
      expect(client.sendMediaCalls, 1); // 发了 WuKong
      final pendings = controller.messages.where((x) => x.isPending).toList();
      expect(pendings.length, 1); // 只 SDK pending
      expect(pendings.single.mediaLocalPath, isEmpty); // 是 SDK pending,非上传预留态
    });

    test('5b) 新发图片写入 WuKong 的 URL 是相对 chat media path', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final controller = await openCtrl(client,
          files: _FakeFilesSvc(autoComplete: true),
          media: _FakeChatMedia(isImage: true));
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await controller.sendLocalImage('/p/a.png', 'a.png');
      await Future<void>.delayed(Duration.zero);

      final pending = controller.messages.singleWhere((x) => x.isPending);
      expect(pending.mediaUrl, '/chat/media/ref-1/preview');
      expect(pending.mediaUrl, isNot(contains('127.0.0.1')));
      expect(pending.mediaUrl, isNot(contains('/api/agent-bus/v1')));
    });

    test('6) 群聊 channelType=2 同样有 uploading 预留态 + 取消', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc(autoComplete: false);
      final controller = await openCtrl(client,
          files: files, channelId: 'ch-g', channelType: 2);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      final fut = controller.sendLocalFile('/p/b.pdf', 'b.pdf');
      await Future<void>.delayed(Duration.zero);
      final uploading = controller.messages.singleWhere((x) => x.isUploading);
      expect(uploading.channelId, 'ch-g');
      expect(uploading.mediaKind, ImMediaKind.file);

      controller.cancelMediaUpload(uploading);
      await fut;
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.singleWhere((x) => x.isFailed).errorMessage,
          contains('取消'));
    });

    test(
        '7) kicked 状态 sendLocalImage → 不上传/不建ref/不发,直接 failed(不闪 uploading) (P2 修复)',
        () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      final files = _FakeFilesSvc();
      final media = _FakeChatMedia(isImage: true);
      final controller =
          await openCtrl(client, files: files, media: media); // channel 就绪
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      client.emitStatus(ImConnectionStatus.kicked); // 打开后被踢下线

      await expectLater(controller.sendLocalImage('/p/a.png', 'a.png'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      expect(files.uploadCalls, 0); // 没上传 OSS(不浪费 staged 文件)
      expect(media.createCalls, 0); // 没建 chat media ref
      expect(client.sendMediaCalls, 0); // 没发 WuKong
      expect(controller.messages.where((x) => x.isUploading),
          isEmpty); // 没闪 uploading
      final m = controller.messages.singleWhere((x) => x.isFailed);
      expect(m.mediaKind, ImMediaKind.image);
      expect(m.mediaLocalPath, '/p/a.png');
      expect(m.errorMessage, contains('踢下线'));
    });

    test('8) 长连接未就绪 sendLocalFile → 不上传/不建ref/不发,直接 failed file 预留态 (P2 修复)',
        () async {
      // connecting 且不会变 connected → ensure 超时抛错 → 直接 failed,不上传。
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connecting);
      final files = _FakeFilesSvc();
      final media = _FakeChatMedia();
      final controller = await openCtrl(client, files: files, media: media);
      addTearDown(() async {
        controller.dispose();
        await client.dispose();
      });

      await expectLater(controller.sendLocalFile('/p/b.pdf', 'b.pdf'),
          throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      expect(files.uploadCalls, 0);
      expect(media.createCalls, 0);
      expect(client.sendMediaCalls, 0);
      expect(controller.messages.where((x) => x.isUploading), isEmpty);
      final m = controller.messages.singleWhere((x) => x.isFailed);
      expect(m.mediaKind, ImMediaKind.file);
      expect(m.mediaLocalPath, '/p/b.pdf');
      expect(m.mediaName, 'b.pdf');
    });
  });

  // ── removeLocalMessage(P2 消息操作菜单「删除」,仅客户端本地删除)─────────────
  group('removeLocalMessage (本地删除,仅客户端)', () {
    Future<HumanDirectImController> openC(_FakeImClient client) async {
      final c = HumanDirectImController(
        presetChannelId: 'ch-zw',
        presetChannelType: 2,
        presetConversationUuid: 'conv-zw',
        client: client,
        credentials: _FakeCreds(_connInfo),
        chatMedia: _FakeChatMedia(),
        filesService: _FakeFilesSvc(),
      );
      await c.open(title: '会话');
      return c;
    }

    ImMessage mkMsg({
      String messageId = '',
      String clientMsgNo = '',
      int seq = 0,
      String fromUid = 'me',
      ImSendStatus status = ImSendStatus.sent,
      String text = 'hi',
    }) =>
        ImMessage(
          messageId: messageId,
          clientMsgNo: clientMsgNo,
          fromUid: fromUid,
          channelId: 'ch-zw',
          channelType: 2,
          timestamp: 1700000000,
          text: text,
          messageSeq: seq,
          sendStatus: status,
        );

    test('按本地 failed messageId 删除命中', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [
        mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'),
        mkMsg(messageId: 'local-f1', status: ImSendStatus.failed, text: 'oops'),
      ];
      final c = await openC(client);
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      expect(c.messages.length, 2);
      c.removeLocalMessage(mkMsg(
          messageId: 'local-f1', status: ImSendStatus.failed, text: 'oops'));
      expect(c.messages.map((m) => m.messageId).toList(), ['srv-1']);
    });

    test('按服务端 messageId 删除命中', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [
        mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'),
        mkMsg(messageId: 'srv-2', seq: 2),
      ];
      final c = await openC(client);
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      // 传入仅含 server messageId 的探针(模拟 UI 只持有这条 ImMessage)。
      c.removeLocalMessage(mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'));
      expect(c.messages.map((m) => m.messageId).toList(), ['srv-2']);
    });

    test('按服务端 messageId 删除后重进会话仍隐藏,实时补齐也不复活', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [
        mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'),
        mkMsg(messageId: 'srv-2', seq: 2, fromUid: 'peer'),
      ];
      final c1 = await openC(client);
      c1.removeLocalMessage(mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c1.messages.map((m) => m.messageId).toList(), ['srv-2']);
      c1.dispose();

      final c2 = await openC(client);
      addTearDown(() async {
        c2.dispose();
        await client.dispose();
      });
      expect(c2.messages.map((m) => m.messageId).toList(), ['srv-2']);

      client.emit(mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'));
      await Future<void>.delayed(Duration.zero);
      expect(c2.messages.map((m) => m.messageId).toList(), ['srv-2']);
    });

    test('按 clientMsgNo(pending)删除命中', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [
        mkMsg(messageId: 'srv-1', seq: 1, fromUid: 'peer'),
        mkMsg(clientMsgNo: 'cmn-1', status: ImSendStatus.pending, text: 'x'),
      ];
      final c = await openC(client);
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      expect(c.messages.length, 2);
      c.removeLocalMessage(
          mkMsg(clientMsgNo: 'cmn-1', status: ImSendStatus.pending, text: 'x'));
      expect(c.messages.map((m) => m.clientMsgNo).toList(), ['']);
      expect(c.messages.single.messageId, 'srv-1');
    });

    test('未命中 → no-op(长度不变)', () async {
      final client =
          _FakeImClient(uid: 'me', status: ImConnectionStatus.connected);
      client.history = [mkMsg(messageId: 'srv-1', seq: 1)];
      final c = await openC(client);
      addTearDown(() async {
        c.dispose();
        await client.dispose();
      });
      c.removeLocalMessage(mkMsg(messageId: 'nope', clientMsgNo: 'zzz'));
      expect(c.messages.length, 1);
      expect(c.messages.single.messageId, 'srv-1');
    });
  });
}
