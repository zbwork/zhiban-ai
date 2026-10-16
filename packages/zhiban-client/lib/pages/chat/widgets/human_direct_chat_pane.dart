import 'messages/chat_messages_shimmer.dart';
import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_client/im/chat_media_api.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_chat_draft_guard.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/chat_read_receipt_events.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/services/clipboard_image_paste.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_connection_notice.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_empty_state.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history_panel.dart';

import 'package:zhiban_core/chat/chat_reply_reference.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart'
    show wukongImClientProvider;
import 'package:zhiban_client/pages/chat/widgets/chat_forward_executor.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_forward_picker.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_preview.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_action_menu.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_reply_locate.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_scroll.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_time_divider.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_mixed_message_bubble.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_multi_select.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_reply_widgets.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_upload_progress_indicator.dart';
import 'package:zhiban_client/pages/chat/widgets/contact_profile_card.dart';
import 'package:zhiban_client/widgets/ui/chat_platform_widgets.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/pages/chat/widgets/send_status_indicator.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_picker.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/rtc_client.dart' show RtcMediaKind;
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/logout_flow.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

/// 普通员工 1v1 direct IM 主区(ADR-0026,WuKong substrate)。
///
/// 嵌在 ChatPage / MobileChatPage 的主对话区,**不是**独立全屏页。
/// 视觉贴近现有对话:白色顶栏 + 头像/在线、灰底消息区 + 左右气泡、底部输入条。
/// 仅依赖 [HumanDirectImController] / [ImMessage]([im_client.dart] 抽象),
/// **不** import wukongimfluttersdk。
class HumanDirectChatPane extends ConsumerStatefulWidget {
  const HumanDirectChatPane({
    super.key,
    this.peerAccountUuid,
    this.roomUuid,
    this.channelId,
    this.channelType,
    this.title,
    this.peerAvatarUrl,
    this.peerDepartmentName = '',
    this.peerEmail = '',
    this.peerCompanyName = '',
    this.selfAvatarUrl,
    this.conversationUuid = '',
    this.clearedAt,
    this.showHeader = true,
    this.headerTrailing,
  }) : assert(peerAccountUuid != null || channelId != null,
            'HumanDirectChatPane needs peerAccountUuid or channelId');

  /// 通讯录新开:peer uuid → /direct-rooms。
  final String? peerAccountUuid;

  /// F09 direct room uuid. F16 `/calls` 创建必须带 room_uuid。
  final String? roomUuid;

  /// 会话列表点开:已知 wukong channel,直接打开(P2.1 点 10)。
  final String? channelId;
  final int? channelType;
  final String? title;

  /// 对端头像 URL(顶栏 + 对端气泡左侧);空时回退默认「用户」头像。
  final String? peerAvatarUrl;

  /// 对端所在部门;顶栏副标题展示,空时副标题隐藏。
  final String peerDepartmentName;
  final String peerEmail;
  final String peerCompanyName;

  /// 当前账号头像 URL(自己气泡右侧);空时回退默认「用户」头像。
  final String? selfAvatarUrl;

  /// 会话 uuid:统一 composer「应用」按钮拉会话可用应用用(空则应用广场空态)。
  final String conversationUuid;
  final String? clearedAt;

  /// 桌面三栏内渲染时显示对话顶栏;移动端全屏页已有 UiPageBar,传 false 避免双标题。
  final bool showHeader;

  /// 顶栏右侧挂载点,由调用方决定放什么(如"加人"按钮);组件本身不感知具体业务。
  final Widget? headerTrailing;

  @override
  ConsumerState<HumanDirectChatPane> createState() =>
      _HumanDirectChatPaneState();
}

class _HumanDirectChatPaneState extends ConsumerState<HumanDirectChatPane> {
  static const double _autoScrollBottomThreshold = 32;

  late final HumanDirectImController controller;
  StateController<HumanDirectImController?>? _activeImControllerNotifier;
  // F09 P1 已读回执 v1: per-pane cache + debounce, conversation_uuid 在 open 后才能拿到。
  // open 后第一次 _onChange 时 lazy 初始化, dispose 时一并释放.
  ChatReceiptsController? _receipts;
  bool _initialReceiptsReady = false;
  bool _receiptPreparationStarted = false;
  StreamSubscription<ImConnectionStatus>? _receiptConnectionSub;
  StreamSubscription<ChatReadReceiptChangedEvent>? _receiptEventSub;
  final RichPromptController _input = RichPromptController();
  final FocusNode _inputFocus = FocusNode();
  final ChatBottomScrollController _scroll = ChatBottomScrollController();
  bool _sending = false;
  bool _cacheClearGuard() =>
      _input.hasRichContent || _sending || controller.hasPendingUploads;
  // F16 FE-03b: 通话状态(来电/呼叫/通话)统一由全局 [RtcCallController] 管理，pane 只发起 + 显示状态。

  // P2 历史定位:主 ListView 每条 message 按 identity 复用 GlobalKey;
  // 点击历史结果 → 关抽屉 + ensureVisible + 高亮 _highlightedKey(~1s 后清除)。
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedKey;
  Timer? _highlightTimer;

  // F09 引用回复 v1: 当前待引用消息. null = 普通输入态.
  // 选中后 composer 上方出现 ChatReplyPreviewBar; 发送成功 / 用户取消 → 清空。
  ChatReplyReference? _replyRef;

  // F09 多选 v1: 进入多选模式后, 顶部出现 [ChatBatchActionBar], 气泡渲染 checkbox。
  // 退出 (取消 / 完成批量操作) → 清空集合 + 退出。
  bool _selectionMode = false;
  final Set<String> _selectedKeys = <String>{};
  // F09 多选 v1 (2026-06 P2 防重入): 批量转发执行中 → 转发/删除/取消按钮全 disabled,
  // 重复点击 「转发」直接 return; 避免同一批消息被发两遍。
  bool _batchForwarding = false;
  String? _lastConversationActivityKey;
  Timer? _latestMessagesSyncTimer;
  bool _latestMessagesSyncing = false;

  @override
  void initState() {
    super.initState();
    HumanChatDraftGuard.register(_cacheClearGuard);
    controller = HumanDirectImController(
      client: ref.read(wukongImClientProvider),
      peerAccountUuid: widget.peerAccountUuid,
      presetChannelId: widget.channelId,
      presetChannelType: widget.channelType,
      presetConversationUuid: widget.conversationUuid,
      presetClearedAt: widget.clearedAt,
    );
    _activeImControllerNotifier = ref.read(activeImControllerProvider.notifier);
    final notifier = _activeImControllerNotifier;
    final createdController = controller;
    Future(() {
      if (mounted) notifier?.state = createdController;
    });
    controller.addListener(_onChange);
    _scroll.addListener(_onScroll);
    // ignore: discarded_futures
    controller.open(title: widget.title);
  }

  // 加载更早历史期间抑制自动跳底，固定消息中心保持原阅读位置。
  bool _loadingOlder = false;
  bool _initialScrollPending = true;

  void _onChange() {
    if (!mounted) return;
    final shouldStickToBottom = _isNearBottom();
    // F09 P1: open 完成后 conversationUuid 就绪, 懒创建 receipts controller。
    final convUuid = controller.conversationUuid;
    if (_receipts == null && convUuid != null && convUuid.isNotEmpty) {
      _receipts = ChatReceiptsController(
        conversationUuid: convUuid,
        service: ref.read(chatServiceProvider),
      );
      _receipts!.addListener(_onReceiptState);
      _receiptEventSub ??= ref
          .read(chatReadReceiptEventBusProvider)
          .stream
          .listen(_onReadReceiptChanged);
    }
    // F09 P1 已读回执 v1: 当前最大 seq → 上报水位 + 让自己 sent 已发消息的 indicator 刷新.
    final receipts = _receipts;
    if (receipts != null && !controller.isConnectionKicked) {
      var maxSeq = 0;
      final selfSeqs = <int>[];
      final myUid = controller.myUid ?? '';
      for (final m in controller.messages) {
        if (m.messageSeq > maxSeq) maxSeq = m.messageSeq;
        if (myUid.isNotEmpty &&
            m.fromUid == myUid &&
            m.messageSeq > 0 &&
            !m.isRevoked &&
            !m.isPending &&
            !m.isFailed) {
          selfSeqs.add(m.messageSeq);
        }
      }
      if (!_receiptPreparationStarted &&
          (!controller.loading || controller.messages.isNotEmpty)) {
        _initialReceiptsReady = receipts.hasSnapshots(selfSeqs);
        debugPrint('[chat-first-frame] messages=${controller.messages.length} '
            'receiptsReady=$_initialReceiptsReady loading=${controller.loading}');
        _receiptPreparationStarted = true;
        unawaited(receipts
            .prepareInitial(selfSeqs, readThrough: maxSeq)
            .whenComplete(() {
          if (!mounted) return;
          _initialReceiptsReady = true;
          _onChange();
        }));
        final im = ref.read(wukongImClientProvider);
        _receiptConnectionSub = im.listenConnectionStatus().listen((_) {
          if (im.isRealtimeConnected) receipts.onReconnect();
        });
      }
      if (_receiptPreparationStarted && !_initialReceiptsReady) {
        unawaited(receipts.prepareInitial(selfSeqs, readThrough: maxSeq));
      }
      if (_initialReceiptsReady) {
        receipts.recordSentSeqs(selfSeqs);
        if (maxSeq > 0) {
          receipts.reportReadWatermark(maxSeq, selfSeqs: selfSeqs);
        }
      }
    }
    setState(() {});
    if (_initialReceiptsReady &&
        _initialScrollPending &&
        controller.messages.isNotEmpty) {
      _initialScrollPending = false;
      _scroll.scrollToLatest();
    }
    if (_loadingOlder || !_initialReceiptsReady) return; // 上拉加载更早历史时不自动跳到底
    if (shouldStickToBottom) {
      _scroll.scrollToLatest();
    }
  }

  bool get _hideHistory =>
      controller.isConnectionKicked ||
      controller.historyAccessDenied ||
      (_receipts?.accessDenied ?? false);

  void _onReceiptState() {
    if (_receipts?.accessDenied ?? false) controller.discardWarmHistory();
    if (mounted) setState(() {});
  }

  void _onReadReceiptChanged(ChatReadReceiptChangedEvent event) {
    final receipts = _receipts;
    if (receipts == null) return;
    if (event.conversationUuid != receipts.conversationUuid) return;
    receipts.refreshReadThrough(event.lastReadMessageSeq);
  }

  void _onConversationSnapshotChanged(
    AsyncValue<List<ConversationItem>>? previous,
    AsyncValue<List<ConversationItem>> next,
  ) {
    final items = next.asData?.value;
    if (items == null || items.isEmpty) return;
    final item = _findCurrentConversationItem(items);
    if (item == null) return;
    final key = [
      item.conversationId,
      item.lastMessageAt ?? '',
      item.lastMessage ?? '',
    ].join('|');
    if (key == _lastConversationActivityKey) return;
    _lastConversationActivityKey = key;
    _scheduleLatestMessagesSync();
  }

  ConversationItem? _findCurrentConversationItem(List<ConversationItem> items) {
    final conversationUuid = widget.conversationUuid.trim();
    final ch = controller.channelId ?? widget.channelId ?? '';
    final chType = controller.channelType;
    for (final item in items) {
      if (conversationUuid.isNotEmpty &&
          item.conversationId == conversationUuid) {
        return item;
      }
      if (ch.isNotEmpty &&
          item.wukongChannelId == ch &&
          item.wukongChannelType == chType) {
        return item;
      }
    }
    return null;
  }

  void _scheduleLatestMessagesSync() {
    _latestMessagesSyncTimer?.cancel();
    _latestMessagesSyncTimer =
        Timer(const Duration(milliseconds: 250), () async {
      if (!mounted || _latestMessagesSyncing) return;
      _latestMessagesSyncing = true;
      try {
        await controller.syncLatestMessages();
      } finally {
        _latestMessagesSyncing = false;
      }
    });
  }

  /// 滚到顶部附近 → 加载更早历史(P1)。加载后保持视口锚点,不自动跳到底、不重画聊天页。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.userScrollDirection != ScrollDirection.idle) {
      _scroll.cancelScrollToLatest();
    }
    // 移动端由下拉刷新控件在释放手势后触发，桌面用顶部滚轮/触控板。
    if (usesChatPullToRefresh(context) || _loadingOlder) return;
    if (_scroll.position.userScrollDirection != ScrollDirection.reverse) return;
    if (_scroll.position.extentAfter > 80) return;
    unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (!_scroll.hasClients ||
        _loadingOlder ||
        controller.loadingMore ||
        !controller.hasMoreHistory) {
      return;
    }
    _loadingOlder = true;
    _scroll.cancelScrollToLatest();
    try {
      await controller.loadMoreHistory(reportErrors: true);
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {
      if (!mounted) return;
      if (usesChatPullToRefresh(context)) rethrow;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载更早消息失败，请重试'))
      );
    } finally {
      _loadingOlder = false;
    }
  }

  // 左侧会话列表的实时预览/置顶/未读由 app 级 ConversationRealtimeBridge 统一处理:
  // 自己发出的 pending 经 WuKong SDK msgInserted 回显流到 bridge(fromSelf 不加未读),
  // 这里不再单独回调 patch 左侧。

  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return true;
    return (chatLatestScrollOffset(position) - position.pixels).abs() <=
        _autoScrollBottomThreshold;
  }

  /// 自己 failed 消息重发(P1):文本走 retryTextMessage、媒体走 retryMediaMessage;
  /// 复用 _runSend 的 catch + snackbar,避免未处理异常。
  void _onRetry(ImMessage m) {
    final action = m.mediaKind == ImMediaKind.none
        ? () => controller.retryTextMessage(m)
        : () => controller.retryMediaMessage(m);
    // ignore: discarded_futures
    _runSend(action, '重发失败');
  }

  /// P2/P3: 取消正在上传的本地媒体(自己侧 uploading 预留态)。
  void _onCancelUpload(ImMessage m) => controller.cancelMediaUpload(m);

  /// F09 C「保存文件」(P2 2026-06 CR 接入 download controller): 任一侧媒体消息可触发;
  /// 改走 `ChatMediaDownloadController.start` 拿到统一进度 / 防重复 / 失败 toast。
  /// 同 url 已在下载中 → controller 自吐 toast「该文件已在下载中」, 不并发。
  /// 成功 / 失败 toast 都由 controller 统一发, pane 不再 BotToast 避免重复提示。
  void _onSaveFile(ImMessage m) {
    if (!m.isMedia || m.mediaUrl.trim().isEmpty) return;
    final name = m.mediaName.trim().isNotEmpty
        ? m.mediaName
        : (m.text.trim().isNotEmpty ? m.text : '文件');
    // ignore: discarded_futures
    ref.read(chatMediaDownloadControllerProvider).start(
          url: m.mediaUrl,
          name: name,
          reveal: true,
          isImage: looksLikeSavableImage(m),
        );
  }

  /// F09 P1 撤回自己消息: 本地乐观替成 tombstone → POST /chat/messages/revoke;
  /// 失败 BotToast「撤回失败」+ controller 回滚 snapshot, 不假成功。
  Future<void> _onRevoke(ImMessage m) async {
    final convUuid = controller.conversationUuid;
    if (convUuid == null || convUuid.isEmpty) {
      BotToast.showText(text: '撤回失败:会话未就绪');
      return;
    }
    if (!_isServerMessageId(m.messageId)) {
      BotToast.showText(text: '撤回失败:消息尚未送达');
      return;
    }
    final snapshot = controller.markLocallyRevoked(
      messageId: m.messageId,
      clientMsgNo: m.clientMsgNo,
    );
    if (snapshot == null) return;
    try {
      await ref.read(chatServiceProvider).revokeMessage(
            conversationUuid: convUuid,
            messageId: m.messageId,
            messageSeq: m.messageSeq,
            clientMsgNo: m.clientMsgNo,
          );
    } catch (e) {
      controller.revertRevoke(snapshot);
      if (mounted) BotToast.showText(text: chatRevokeFailureMessage(e));
    }
  }

  static bool _isServerMessageId(String id) =>
      id.isNotEmpty && id != '0' && !id.startsWith('local-');

  /// P2 历史定位:点击历史结果 → 关抽屉 + 滚到主聊天区对应消息 + 短暂高亮(~1s)。
  /// 仅定位**当前已加载**(最新 `controller.messages`)的消息;已删除 / 不在窗口 → 仅关闭,不 crash。
  void _onSelectHistoryMessage(ImMessage m) {
    // 关抽屉(复用同一 provider 入口)。
    ref.read(chatHistoryPanelOpenProvider.notifier).state = false;
    // 用最新 messages 校验目标仍在;不在 → 仅关闭。
    final index = findImMessageIndex(controller.messages, m);
    if (index < 0) return;
    final idKey = imMessageIdentity(m);
    // 高亮(单一 key,1s 清除);目标暂未上屏时滚动到位 build 后即可见。
    setState(() => _highlightedKey = idKey);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _highlightedKey = null);
    });
    // 关抽屉后下一帧开始定位(离屏先 ± 扩张近似滚动让 item build,再 ensureVisible,最多 kLocateMaxAttempts 次)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, index, attempt: 0);
    });
  }

  /// 消息按时间正序索引；按实际视口方向换算历史定位偏移。
  /// 第 [attempt] 次围绕估算点
  /// 做 ± 扩张搜索(每次跳**不同**偏移,避免重复跳同一点),`jumpTo` 让目标 item 当帧 build。
  void _scrollToMessageByIndex(int index, int attempt) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final estimated = estimateHistoryScrollOffset(
      index: index,
      itemCount: controller.messages.length,
      maxScrollExtent: pos.maxScrollExtent - pos.minScrollExtent,
    );
    _scroll.cancelScrollToLatest();
    final probe = expandingProbeOffset(
      estimated: estimated,
      attempt: attempt,
      viewport: pos.viewportDimension,
      maxScrollExtent: pos.maxScrollExtent - pos.minScrollExtent,
    );
    _scroll.jumpTo(pos.axisDirection == AxisDirection.up
        ? pos.maxScrollExtent - probe
        : pos.minScrollExtent + probe);
  }

  /// 离屏定位 + retry(最多 [kLocateMaxAttempts]):context 在屏 → `ensureVisible`;
  /// 离屏 → ± 扩张近似滚动后下一帧再试;用尽仍无 → 仅高亮(已设),不滚动、不 crash(best-effort)。
  void _ensureMessageVisibleWithRetry(String idKey, int index,
      {int attempt = 0}) {
    if (!mounted) return;
    _scroll.cancelScrollToLatest();
    final resolved = runLocateAttempt(
      attempt: attempt,
      probeContext: () => _messageKeys[idKey]?.currentContext != null,
      onVisible: () {
        final ctx = _messageKeys[idKey]!.currentContext;
        if (!isRenderObjectAttached(ctx)) return;
        unawaited(Scrollable.ensureVisible(ctx!,
                duration: const Duration(milliseconds: 200), alignment: 0.65)
            .catchError((_) {}));
      },
      onApproxScroll: () => _scrollToMessageByIndex(index, attempt),
    );
    if (resolved || attempt >= kLocateMaxAttempts) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, index, attempt: attempt + 1);
    });
  }

  /// F09 P2 媒体体验 (2026-06): 点击图片 → 大图预览 (含当前窗口所有图片, 可左右翻).
  /// 仅收集已加载窗口内的可预览图片 (revoked/pending/failed/uploading 自动跳过)。
  void _onPreviewImage(ImMessage m, {Object? heroTag, String? imageUrl}) {
    final peerLabel = (widget.title?.trim().isNotEmpty ?? false)
        ? widget.title!.trim()
        : '对方';
    final images = collectPreviewableImages(
      controller.messages,
      resolveSenderName: (x) =>
          x.fromUid == (controller.myUid ?? '') ? '我' : peerLabel,
    );
    if (images.isEmpty) return;
    final messageKey = imMessageIdentity(m);
    final selectedIndex = imageUrl == null
        ? -1
        : images.indexWhere(
            (image) => image.messageKey == messageKey && image.url == imageUrl);
    final idx = selectedIndex >= 0
        ? selectedIndex
        : findImagePreviewIndex(images, messageKey);
    // ignore: discarded_futures
    showChatImagePreview(
      context: context,
      images: images,
      initialIndex: idx,
      heroTag: heroTag,
    );
  }

  /// F09 P2 媒体体验 (2026-06): 点击视频文件 → 直接调 download controller 走「下载 + reveal」。
  /// 本轮不引入 video_player 重依赖, 内嵌播放器留后续 (见 docs)。
  void _onOpenVideo(ImMessage m) {
    final url = m.mediaUrl.trim();
    if (url.isEmpty) return;
    final name = m.mediaName.trim().isNotEmpty
        ? m.mediaName
        : (m.text.trim().isNotEmpty ? m.text : '视频');
    _openVideoMedia(url: url, name: name);
  }

  void _onOpenVideoBlock(ImMessage parent, ImMessageBlock block) {
    final url = block.url.trim();
    if (url.isEmpty) return;
    final name = block.name.trim().isNotEmpty ? block.name.trim() : '视频';
    _openVideoMedia(url: url, name: name);
  }

  void _openVideoMedia({required String url, required String name}) {
    // ignore: discarded_futures
    ref.read(chatMediaDownloadControllerProvider).start(
        url: url, name: name.trim().isNotEmpty ? name : '视频', reveal: true);
  }

  /// F09 多选 v1: 进入多选模式. 入口为单条消息菜单「多选」, 进入时默认勾选当前消息.
  /// 同时清掉引用态 (避免输入框上方两条状态)。
  void _onEnterSelection(ImMessage m) {
    if (!canSelectMessage(m)) return;
    setState(() {
      _selectionMode = true;
      _replyRef = null;
      _selectedKeys
        ..clear()
        ..add(messageSelectionKey(m));
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedKeys.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  /// 单条勾选 / 取消. 超过 [kChatMultiSelectMax] 时 toast 提示并拒绝。
  void _toggleSelection(ImMessage m) {
    if (!canSelectMessage(m)) return;
    final key = messageSelectionKey(m);
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        if (_selectedKeys.length >= kChatMultiSelectMax) {
          BotToast.showText(text: '一次最多选 $kChatMultiSelectMax 条');
          return;
        }
        _selectedKeys.add(key);
      }
    });
  }

  /// 当前已勾选消息按时间升序返回 (controller.messages 本身就是升序)。
  List<ImMessage> _collectSelected() {
    if (_selectedKeys.isEmpty) return const <ImMessage>[];
    final out = <ImMessage>[];
    for (final m in controller.messages) {
      if (_selectedKeys.contains(messageSelectionKey(m))) out.add(m);
    }
    return out;
  }

  /// 批量本地删除 (确认 dialog → 逐条复用 controller.removeLocalMessage; 不调 WuKong/Bus 删除)。
  Future<void> _batchDeleteSelected() async {
    final items = _collectSelected();
    if (items.isEmpty) return;
    final ok = await showUiConfirmDialog(
      context,
      title: '删除 ${items.length} 条消息',
      description: '仅在你本地视图中移除, 不影响对方。',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    for (final m in items) {
      controller.removeLocalMessage(m);
    }
    if (mounted) _exitSelection();
  }

  /// 批量转发: 选 1..N 个目标 → 按时间升序逐条 sendTextMessage; 媒体 / 不可转发条目跳过 (fail-closed)。
  /// 不携带 mentions metadata.
  ///
  /// **防重入 (CR-2026-06-P2)**:`_batchForwarding=true` 期间重复触发直接 return;
  /// `forwardMessagesToTargets` 包在 try/finally, finally 里 mounted 时清旗;
  /// 转发期间 [ChatBatchActionBar] 三个按钮回调全部置 null (灰显)。
  Future<void> _batchForwardSelected(ChatForwardMode mode) async {
    if (_batchForwarding) return; // 防重入
    final items = _collectSelected();
    if (items.isEmpty) return;
    final forwardable =
        items.where(canBatchForwardMessage).toList(growable: false);
    final skipped = items.length - forwardable.length;
    if (forwardable.isEmpty) {
      BotToast.showText(text: '所选消息无可转发内容');
      return;
    }
    final picked = await showChatForwardPickerDialog(
      context,
      title: mode == ChatForwardMode.merged
          ? '合并转发到… (${forwardable.length} 条)'
          : '逐条转发到… (${forwardable.length} 条)',
      subtitle: skipped > 0 ? '另有 $skipped 条不可转发, 将自动跳过' : null,
      multi: true,
    );
    // 用户取消 picker → 不进入 forwarding 状态。
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _batchForwarding = true);
    final client = ref.read(wukongImClientProvider);
    try {
      final result = await forwardRichMessagesToTargets(
        messages: forwardable,
        targets: picked,
        mode: mode,
        senderNameOf: _forwardSenderName,
        mergeTitle: '${_peerForwardTitle()}的聊天记录',
        cloneMediaBlock: _cloneForwardMediaBlock,
        send: (ch, ct, payload) => _sendForwardPayload(client, ch, ct, payload),
      );
      if (!mounted) return;
      BotToast.showText(
        text: chatForwardResultToast(result: result, isBatch: true),
      );
      _exitSelection();
    } finally {
      if (mounted) setState(() => _batchForwarding = false);
    }
  }

  Future<void> _sendForwardPayload(ImClient client, String channelId,
      int channelType, ChatForwardPayload payload) {
    if (payload.isPlainText) {
      return client.sendTextMessage(channelId, channelType, payload.plainText);
    }
    return client.sendMixedMessage(
      channelId,
      channelType,
      blocks: payload.blocks,
      summary: payload.summary,
    );
  }

  Future<ImMessageBlock?> _cloneForwardMediaBlock(
      String targetConversationUuid, ImMessageBlock block) async {
    final fileUuid = block.fileUuid.trim();
    if (fileUuid.isEmpty) return null;
    final media = await ChatMediaApi().createRef(
      conversationUuid: targetConversationUuid,
      driveFileUuid: fileUuid,
    );
    final isImage = block.isImage || media.isImage;
    return ImMessageBlock(
      kind: isImage ? ImMessageBlockKind.image : ImMessageBlockKind.file,
      url: _chatMediaPath(media.refUuid, isImage ? 'preview' : 'download'),
      fileUuid: media.driveFileUuid,
      refUuid: media.refUuid,
      name: media.fileName.trim().isNotEmpty ? media.fileName : block.name,
      size: media.sizeBytes > 0 ? media.sizeBytes : block.size,
      mime: media.mimeType.trim().isNotEmpty ? media.mimeType : block.mime,
      width: block.width,
      height: block.height,
    );
  }

  static String _chatMediaPath(String refUuid, String action) =>
      '/chat/media/$refUuid/$action';

  String _forwardSenderName(ImMessage message) {
    if (message.fromUid == (controller.myUid ?? '')) return '我';
    return _peerForwardTitle();
  }

  String _peerForwardTitle() {
    final title = widget.title?.trim() ?? '';
    return title.isNotEmpty ? title : '对方';
  }

  /// F09 转发 v1 (2026-06 多目标增量): 单条文本转发到 1..N 个目标.
  /// **不**复用 controller (controller 绑定当前 channel; 目标可能是别的会话).
  /// **必须不**携带原消息 mentions metadata (避免 @数字员工 在目标群被误触发); 见
  /// docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.
  Future<void> _onForward(ImMessage m) async {
    if (!canForwardRichMessage(m)) return;
    final picked = await showChatForwardPickerDialog(
      context,
      title: '转发到…',
      subtitle: chatForwardSubtitleOf(m),
      multi: true,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final client = ref.read(wukongImClientProvider);
    final result = await forwardRichMessagesToTargets(
      messages: <ImMessage>[m],
      targets: picked,
      mode: ChatForwardMode.separate,
      cloneMediaBlock: _cloneForwardMediaBlock,
      send: (ch, ct, payload) => _sendForwardPayload(client, ch, ct, payload),
    );
    if (!mounted) return;
    BotToast.showText(
      text: chatForwardResultToast(
        result: result,
        isBatch: false,
        singleTargetName: picked.length == 1 ? picked.first.title : null,
      ),
    );
  }

  /// F09 引用回复 v1: 菜单「引用」入口. 取消时设 null; 取消后焦点回输入框.
  void _onReply(ImMessage m) {
    if (!canReplyMessage(m)) return;
    final isPeer = m.fromUid != (controller.myUid ?? '');
    final senderName = isPeer
        ? ((widget.title?.trim().isNotEmpty == true)
            ? widget.title!.trim()
            : '对方')
        : '我';
    setState(() {
      _replyRef = buildReplyRefFromMessage(source: m, senderName: senderName);
    });
    _inputFocus.requestFocus();
  }

  /// F09 引用回复 v1 (2026-06 best-effort 跨页定位): 点击气泡内引用块 → 优先在
  /// 已加载窗口定位; 若不在且 ref.messageSeq>0 且 hasMoreHistory → 最多上拉 5 页;
  /// 仍找不到 → BotToast 提示 (与历史定位策略一致, 不发 SyncOne)。
  Future<void> _onLocateReply(ChatReplyReference ref) async {
    int idx = _findMessageByReplyRef(ref);
    // 触发 best-effort 跨页加载: 仅当当前窗口找不到 且 ref 有 seq 且 hasMore 且 ref 在更早页。
    if (idx < 0) {
      idx = await loadOlderUntilFoundForReplyRef(
        controller: controller,
        ref: ref,
        findIndex: () => _findMessageByReplyRef(ref),
      );
    }
    if (!mounted) return;
    if (idx < 0) {
      BotToast.showText(text: '原消息不在当前会话窗口');
      return;
    }
    final msg = controller.messages[idx];
    final idKey = imMessageIdentity(msg);
    setState(() => _highlightedKey = idKey);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _highlightedKey = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, idx, attempt: 0);
    });
  }

  /// 在当前 controller.messages 中按 reply 元数据找原消息 (复用共享 helper)。
  int _findMessageByReplyRef(ChatReplyReference ref) =>
      findMessageIndexByReplyRef(controller.messages, ref);

  /// 判断 reply 引用的原消息在当前窗口内是否已撤回 / 不可用 (渲染时透传给 ChatBubbleReplyBlock)。
  bool _replyTargetUnavailable(ChatReplyReference ref) {
    final idx = _findMessageByReplyRef(ref);
    if (idx < 0) return false; // 不在窗口不算 unavailable, 仍可点击 (locate 时再 toast)
    return controller.messages[idx].isRevoked;
  }

  /// P3: kicked 恢复入口 —— 复用现有 logout 流程(清 token + resetSessionScope)+ 跳登录,
  /// **不**新造认证架构、不自动 logout。
  Future<void> _onReLogin() async {
    await performLogoutToLogin(context);
  }

  @override
  void dispose() {
    HumanChatDraftGuard.unregister(_cacheClearGuard);
    final notifier = _activeImControllerNotifier;
    final disposedController = controller;
    Future(() {
      // notifier 背后的 provider 可能在这个延迟任务触发前就被整体 dispose 了
      // (比如 resetSessionScope 重建 ProviderScope)；此时 .state 会抛
      // "used after dispose"，此处只是尽力清理，抛了就说明不用清理了。
      try {
        if (notifier?.state == disposedController) {
          notifier?.state = null;
        }
      } catch (_) {}
    });
    _highlightTimer?.cancel();
    _latestMessagesSyncTimer?.cancel();
    controller.removeListener(_onChange);
    _scroll.removeListener(_onScroll);
    _receiptEventSub?.cancel();
    _receiptEventSub = null;
    _receiptConnectionSub?.cancel();
    _receipts?.dispose();
    controller.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_input.hasRichContent || _sending) return;
    if (_input.hasUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件上传中，请稍候'))
      );
      return;
    }
    if (_input.hasFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('有文件上传失败，请移除后重试'))
      );
      return;
    }
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final sentDraft = _input.snapshotDraft();
    final sentReply = _replyRef;
    final replyJson = sentReply?.toJson();
    try {
      final blocks = _input.toMixedBlocks();
      if (blocks.isEmpty) return;
      if (blocks.length == 1 && blocks.single.isText) {
        await controller.sendText(blocks.single.text, replyRef: replyJson);
      } else {
        await controller.sendMixedMessage(
          blocks,
          summary: RichPromptController.summaryOfBlocks(blocks),
          replyRef: replyJson,
        );
      }
      if (!mounted) return;
      _input.clearIfUnchanged(sentDraft);
      if (_replyRef == sentReply) setState(() => _replyRef = null);
      _scroll.scrollToLatest(animated: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _isImageFileName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'}
        .contains(ext);
  }

  void _addPendingImages(List<XFile> files) {
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      final name = f.name.trim().isEmpty ? '图片.png' : f.name.trim();
      _insertLocalAttachment(f.path, name, ChatFileType.image);
    }
    _inputFocus.requestFocus();
    if (files.length > slots) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
    }
  }

  void _addPendingLocalAttachments(List<XFile> files) {
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      final type = _chatFileTypeForName(f.name);
      final fallback = type == ChatFileType.image ? '图片.png' : '文件';
      final name = f.name.trim().isEmpty ? fallback : f.name.trim();
      _insertLocalAttachment(f.path, name, type);
    }
    _inputFocus.requestFocus();
    if (files.length > slots) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
    }
  }

  void _insertLocalAttachment(
    String path,
    String name,
    ChatFileType fileType
  ) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    final cancel = CancelToken();
    final mediaKind =
        fileType == ChatFileType.image ? ImMediaKind.image : ImMediaKind.file;
    _input.activateTrailingTextBlock();
    _input.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: name,
      fileType: fileType,
      localPath: path,
      onCancel: () {
        if (!cancel.isCancelled) cancel.cancel('removed from composer');
      },
    ));
    unawaited(controller
        .prepareLocalMediaBlock(
      path,
      name,
      mediaKind,
      cancelToken: cancel,
      onProgress: (p) => _input.updateAttachment(
        id,
        (old) => old.copyWith(progress: p.clamp(0, 100)),
      ),
    )
        .then((block) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: block,
        ),
      );
      refocusPromptInput(_inputFocus);
    }).catchError((Object e) {
      if (cancel.isCancelled) return null;
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
      return null;
    }));
  }

  ChatFileType _chatFileTypeForName(String name) =>
      _isImageFileName(name) ? ChatFileType.image : ChatFileType.file;

  Future<void> _runSend(Future<void> Function() action, String failHint) async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$failHint: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String get _callRoomUuid =>
      (widget.roomUuid ?? controller.roomUuid ?? '').trim();

  String get _callPeerAccountUuid => (widget.peerAccountUuid ?? '').trim();

  /// 点击电话按钮 → 委托全局 [RtcCallController] 发起 1v1 audio。来电接收/呼叫态/通话态
  /// 全由全局协调器 + overlay 负责，pane 不再持有 RTC 客户端 / 不再弹本地来电 dialog。
  void _onVoiceCallPressed() {
    final controller = ref.read(rtcCallControllerProvider);
    // ignore: discarded_futures
    controller.startOutgoing(
      roomUuid: _callRoomUuid,
      calleeAccountUuid: _callPeerAccountUuid,
      peerName: widget.title,
    );
  }

  /// 点击视频按钮 → 委托全局 [RtcCallController] 发起 1v1 video（Phase B）。
  /// 与语音同走全局浮层；不改 PromptInput 本体，仅多传一个回调。
  void _onVideoCallPressed() {
    final controller = ref.read(rtcCallControllerProvider);
    // ignore: discarded_futures
    controller.startOutgoing(
      roomUuid: _callRoomUuid,
      calleeAccountUuid: _callPeerAccountUuid,
      peerName: widget.title,
      mediaKind: RtcMediaKind.video,
    );
  }

  ChatContactProfile _peerProfile() {
    final peerUuid = _callPeerAccountUuid;
    final selfUuid = _selfAccountUuid();
    return ChatContactProfile(
      kind: 'human',
      accountUuid: peerUuid,
      displayName:
          widget.title?.trim().isNotEmpty == true ? widget.title!.trim() : '同事',
      avatarUrl: widget.peerAvatarUrl?.trim() ?? '',
      departmentName: widget.peerDepartmentName,
      email: widget.peerEmail,
      companyName: widget.peerCompanyName,
      isSelf: selfUuid.isNotEmpty && selfUuid == peerUuid,
    );
  }

  String _selfAccountUuid() {
    final fromUid = _accountUuidFromWukongUid(controller.myUid ?? '');
    if (fromUid.isNotEmpty) return fromUid;
    return ref.read(accountInfoProvider).asData?.value?.accountNo.trim() ?? '';
  }

  String _accountUuidFromWukongUid(String uid) {
    const marker = '_u_';
    final idx = uid.indexOf(marker);
    if (idx < 0) return '';
    return uid.substring(idx + marker.length).trim();
  }

  void _showPeerProfile(Offset anchor) {
    final profile = _peerProfile();
    if (PlatformUtils.isMobile) {
      _openPeerContactDetail(profile);
      return;
    }
    final canAct =
        profile.isHuman && !profile.isSelf && profile.accountUuid.isNotEmpty;
    showChatContactProfileCard(
      context,
      anchor: anchor,
      profile: profile,
      onMessage: canAct
          ? () {
              _inputFocus.requestFocus();
            }
          : null,
      onVoiceCall: canAct ? _onVoiceCallPressed : null,
      onVideoCall: canAct ? _onVideoCallPressed : null,
    );
  }

  void _openPeerContactDetail(ChatContactProfile profile) {
    if (profile.isSelf) {
      context.push(RoutePaths.profileDetails);
      return;
    }
    if (profile.accountUuid.isEmpty) return;
    context.push(
      RoutePaths.contactsPersonDetail,
      extra: profile.accountUuid
    );
  }

  void _onPickAttachment(ChatAttachmentPickKind kind) {
    switch (kind) {
      case ChatAttachmentPickKind.files:
        _pickAndSendFiles();
      case ChatAttachmentPickKind.images:
        _pickAndSendImages();
      case ChatAttachmentPickKind.camera:
        _takeAndSendPhoto();
    }
  }

  Future<void> _pickAndSendImages() async {
    final files = await pickImageFiles();
    if (!mounted) return;
    if (files.isEmpty) return;
    _addPendingImages(files);
  }

  Future<void> _takeAndSendPhoto() async {
    final file = await takePhotoFile();
    if (!mounted) return;
    if (file == null) return;
    _addPendingImages([file]);
  }

  Future<bool> _pasteAndSendImage() async {
    final files = await readClipboardAttachmentsAsXFiles();
    if (files.isEmpty) return false;
    _addPendingLocalAttachments(files);
    return true;
  }

  Future<void> _pickAndSendFiles() async {
    final files = await pickChatFiles();
    if (!mounted) return;
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      _insertLocalAttachment(f.path, f.name, _chatFileTypeForName(f.name));
    }
  }

  Future<void> _pickAndSendFromDrive() async {
    final picked = await showDriveFilePicker(context, ref);
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    for (final f in picked.take(slots)) {
      _insertDriveAttachment(f);
    }
  }

  void _insertDriveAttachment(DriveFile f) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    final type = f.mimeType.startsWith('image/')
        ? ChatFileType.image
        : _chatFileTypeForName(f.name);
    _input.activateTrailingTextBlock();
    _input.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: f.name,
      fileType: type),
    );
    unawaited(controller.prepareDriveMediaBlock(f).then((block) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: block,
        ),
      );
      refocusPromptInput(_inputFocus);
    }).catchError((Object e) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
      return null;
    }));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<ConversationItem>>>(
      conversationsProvider,
      _onConversationSnapshotChanged,
    );
    final title = widget.title ?? '同事对话';
    final peerLabel = (widget.title?.trim().isNotEmpty ?? false)
        ? widget.title!.trim()
        : '对方';
    return ChatImHistoryHost(
      controller: controller,
      resolveSenderName: (_) => peerLabel,
      onSelectMessage: _onSelectHistoryMessage,
      onPreviewImage: _onPreviewImage,
      onOpenVideo: _onOpenVideo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader)
            _Header(
              title: title,
              departmentName: widget.peerDepartmentName,
              onProfileTap: _showPeerProfile,
              trailing: widget.headerTrailing,
            ),
          // P3: kicked/连接断开 → 明确提示 + 重新登录入口(优先于通用加载错误)。
          if (controller.isConnectionKicked)
            ChatConnectionNotice(onReLogin: _onReLogin),
          if (!controller.isConnectionKicked && controller.error != null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFDECEC),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '加载失败: ${controller.error}',
                style: const TextStyle(color: Color(0xFFD92D20), fontSize: 12),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: ChatTheme.pageBg,
                    child: _hideHistory ||
                            (controller.loading &&
                                controller.messages.isEmpty) ||
                            (!_initialReceiptsReady &&
                                controller.messages.isNotEmpty)
                        ? _hideHistory
                            ? const Center(child: Text('当前会话不可访问，请重新登录或检查权限'))
                            : const DeferredChatMessagesShimmer(
                                bottomContentInset: 0)
                        : controller.messages.isEmpty
                            ? const ChatEmptyState()
                            : ChatMessageScrollbar(
                                controller: _scroll,
                                child: ChatHistoryList(
                                  scrollController: _scroll,
                                  hasMore: controller.hasMoreHistory,
                                  onLoadOlder: _loadOlder,
                                  itemIds: controller.messages
                                      .map(imMessageIdentity)
                                      .toList(),
                                  padding: EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    _selectionMode ? 110 : 12,
                                  ),
                                  itemBuilder: (context, i) {
                                    final msgs = controller.messages;
                                    final msg = msgs[i];
                                    // F09 引用回复 v1: 解码气泡上方引用块的 ref + 透传 unavailable 标记.
                                    final replyRefJson = msg.replyRefJson;
                                    ChatReplyReference? replyRef;
                                    if (replyRefJson != null &&
                                        replyRefJson.isNotEmpty) {
                                      final base = ChatReplyReference.fromJson(
                                          replyRefJson);
                                      replyRef = base.copyWith(
                                        isUnavailable:
                                            _replyTargetUnavailable(base),
                                      );
                                    }
                                    final bubble = _Bubble(
                                      msg: msg,
                                      myUid: controller.myUid ?? '',
                                      peerAvatarUrl: widget.peerAvatarUrl,
                                      selfAvatarUrl: widget.selfAvatarUrl,
                                      peerName: title,
                                      onPeerProfileTap: _selectionMode
                                          ? null
                                          : _showPeerProfile,
                                      onRetry: _selectionMode ? null : _onRetry,
                                      onCancelUpload: _selectionMode
                                          ? null
                                          : _onCancelUpload,
                                      onDelete: _selectionMode
                                          ? null
                                          : controller.removeLocalMessage,
                                      onRevoke:
                                          _selectionMode ? null : _onRevoke,
                                      onSaveFile:
                                          _selectionMode ? null : _onSaveFile,
                                      onReply: _selectionMode ? null : _onReply,
                                      onForward:
                                          _selectionMode ? null : _onForward,
                                      onMultiSelect: _selectionMode
                                          ? null
                                          : _onEnterSelection,
                                      replyRef: replyRef,
                                      onLocateReply: _selectionMode
                                          ? null
                                          : _onLocateReply,
                                      onPreviewImage: _selectionMode
                                          ? null
                                          : _onPreviewImage,
                                      onOpenVideo:
                                          _selectionMode ? null : _onOpenVideo,
                                      onOpenVideoBlock: _selectionMode
                                          ? null
                                          : _onOpenVideoBlock,
                                      // F09 P1 已读回执 v1: 自己 sent 非 revoked/pending/failed
                                      // 才会内部渲染入口; 见 _Bubble.build。
                                      receipts:
                                          _selectionMode ? null : _receipts,
                                    );
                                    // F09 多选 v1: selection mode 下气泡左/右出 checkbox + 整行 toggle.
                                    final selectionKey =
                                        messageSelectionKey(msg);
                                    final selectable = canSelectMessage(msg);
                                    final bubbleForList = _selectionMode
                                        ? ChatSelectableBubble(
                                            checked: _selectedKeys
                                                .contains(selectionKey),
                                            enabled: selectable,
                                            isPeer: msg.fromUid !=
                                                (controller.myUid ?? ''),
                                            onToggle: () =>
                                                _toggleSelection(msg),
                                            child: bubble,
                                          )
                                        : bubble;
                                    // P2 历史定位:按 identity 复用 GlobalKey + 高亮包装(无高亮时透明)。
                                    final idKey = imMessageIdentity(msg);
                                    final gk = _messageKeys.putIfAbsent(
                                        idKey, () => GlobalKey());
                                    final located = KeyedSubtree(
                                      key: gk,
                                      child: ChatLocateHighlight(
                                        active: _highlightedKey == idKey,
                                        child: bubbleForList,
                                      ),
                                    );
                                    // P2: 相邻消息时间差 ≥ 5min(或第一条)→ 在该条上方插入时间分隔。
                                    if (!shouldShowTimeDivider(
                                      prevTimestampMs:
                                          i > 0 ? msgs[i - 1].timestamp : null,
                                      timestampMs: msg.timestamp,
                                    )) {
                                      return located;
                                    }
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ChatMessageTimeDivider(
                                            timestampMs: msg.timestamp),
                                        located,
                                      ],
                                    );
                                  },
                                ),
                              ),
                  ),
                ),
                if (_selectionMode)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 18,
                    child: Center(
                      child: ChatBatchActionBar(
                        selectedCount: _selectedKeys.length,
                        forwarding: _batchForwarding,
                        onCancel: _batchForwarding ? null : _exitSelection,
                        onForwardSeparate: _batchForwarding
                            ? null
                            : () =>
                                _batchForwardSelected(ChatForwardMode.separate),
                        onForwardMerged: _batchForwarding
                            ? null
                            : () =>
                                _batchForwardSelected(ChatForwardMode.merged),
                        onDelete:
                            _batchForwarding ? null : _batchDeleteSelected,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // F09 引用回复 v1: 选中后 composer 上方插入 preview bar; 取消 → 清空 + 焦点回输入框。
          if (_replyRef != null)
            ChatReplyPreviewBar(
              reference: _replyRef!,
              onCancel: () {
                setState(() => _replyRef = null);
                _inputFocus.requestFocus();
              },
            ),
          // 统一 composer(human 变体:不展示数字员工技能入口)。
          // 电话按钮的 enabled/active 跟随全局 RtcCallController 状态(来电/呼叫/通话)。
          ListenableBuilder(
            listenable: ref.watch(rtcCallControllerProvider),
            builder: (context, _) {
              final rtc = ref.read(rtcCallControllerProvider);
              if (PlatformUtils.isMobile) {
                return ChatPlatformWidgets.of(context).promptInput(
                  focusNode: _inputFocus,
                  controller: _input,
                  conversationUuid: widget.conversationUuid,
                  showSkillButton: false,
                  onPickAttachment: _onPickAttachment,
                  onPickFromDrive: _pickAndSendFromDrive,
                  onVoiceCall: _onVoiceCallPressed,
                  voiceCallEnabled: !rtc.busy,
                  voiceCallActive: rtc.hasActiveCall && !rtc.isVideo,
                  onVideoCall: _onVideoCallPressed,
                  videoCallEnabled: !rtc.busy,
                  videoCallActive: rtc.hasActiveCall && rtc.isVideo,
                  allowAttachmentOnlySend: true,
                  isSending: _sending,
                  onSend: (_) => _send(),
                );
              }
              return PromptInput(
                focusNode: _inputFocus,
                controller: _input,
                conversationUuid: widget.conversationUuid,
                showSkillChips: false,
                showSkillButton: false,
                showAiDisclaimer: false,
                onPickAttachment: _onPickAttachment,
                onPasteImage: _pasteAndSendImage,
                onPickFromDrive: _pickAndSendFromDrive,
                onVoiceCall: _onVoiceCallPressed,
                voiceCallEnabled: !rtc.busy,
                voiceCallActive: rtc.hasActiveCall && !rtc.isVideo,
                onVideoCall: _onVideoCallPressed,
                videoCallEnabled: !rtc.busy,
                videoCallActive: rtc.hasActiveCall && rtc.isVideo,
                allowAttachmentOnlySend: true,
                isSending: _sending,
                onSend: (_) => _send(),
                onStop: () {},
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 顶栏:白底 64px,「名字 ┊ 部门」紧凑单行(产品要求**不展示**对端头像 icon、**不展示**
/// 「在线」绿点; 视觉对齐 ChatDetailHeader, 但不耦合 chatProvider —— direct IM 用对端而非
/// 数字员工)。
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.departmentName,
    required this.onProfileTap,
    this.trailing,
  });
  final String title;
  final String departmentName;
  final void Function(Offset anchor) onProfileTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final dept = departmentName.trim();
    Offset lastTap = Offset.zero;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => lastTap = details.globalPosition,
                      onTap: () => onProfileTap(lastTap),
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1D2129),
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),
                if (dept.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Container(
                    width: 1,
                    height: 14,
                    color: const Color(0xFFE5E6EB),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      dept,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF86909C),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 单条消息:头像 + 气泡水平排版(对端在左、自己在右),视觉对齐 agent 对话的
/// [MessageBubble]——人↔人两侧都是「用户」头像(无 agent 在线绿点)。
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.msg,
    required this.myUid,
    this.peerAvatarUrl,
    this.selfAvatarUrl,
    required this.peerName,
    this.onRetry,
    this.onCancelUpload,
    this.onDelete,
    this.onRevoke,
    this.onSaveFile,
    this.onPeerProfileTap,
    this.onReply,
    this.onForward,
    this.onMultiSelect,
    this.replyRef,
    this.onLocateReply,
    this.onPreviewImage,
    this.onOpenVideo,
    this.onOpenVideoBlock,
    this.receipts,
  });
  final ImMessage msg;
  final String myUid;
  final String? peerAvatarUrl;
  final String? selfAvatarUrl;
  final String peerName;
  final void Function(Offset anchor)? onPeerProfileTap;

  /// 自己 failed 文本消息的重发回调(P1)。
  final void Function(ImMessage msg)? onRetry;

  /// 自己 uploading 媒体预留态的取消回调(P2/P3)。
  final void Function(ImMessage msg)? onCancelUpload;

  /// 本地删除回调(P2,仅客户端);右键 / 长按菜单用。
  final void Function(ImMessage msg)? onDelete;

  /// F09 P1: 撤回自己发送的 WuKong 时间线消息。仅 sent 自己消息显示该项。
  final void Function(ImMessage msg)? onRevoke;

  /// F09 C: 保存文件到下载目录(桌面端 reveal in Finder)。媒体消息(image/file)可见。
  final void Function(ImMessage msg)? onSaveFile;

  /// F09 引用回复 v1: 菜单「引用」入口. null = 不显示该菜单项。
  final void Function(ImMessage msg)? onReply;

  /// F09 转发 v1: 菜单「转发」入口. null = 不显示该菜单项 (媒体 fail-closed)。
  final void Function(ImMessage msg)? onForward;

  /// F09 多选 v1: 菜单「多选」入口, 进入选择模式. null = 不显示。
  final void Function(ImMessage msg)? onMultiSelect;

  /// F09 引用回复 v1: 本消息引用的原消息快照 (含 unavailable 状态). null = 普通消息.
  final ChatReplyReference? replyRef;

  /// F09 引用回复 v1: 点击气泡内引用块定位回原消息. unavailable 时 ChatBubbleReplyBlock 自吞 tap.
  final void Function(ChatReplyReference ref)? onLocateReply;

  /// F09 P2 媒体体验 (2026-06): 点击图片缩略图 → 大图预览 (含上一张/下一张)。
  final void Function(ImMessage msg, {Object? heroTag, String? imageUrl})?
      onPreviewImage;

  /// F09 P2 媒体体验 (2026-06): 点击视频卡片 → 下载 + 系统打开 (本轮无内嵌播放器)。
  final void Function(ImMessage msg)? onOpenVideo;

  /// F09 P2 媒体体验 (2026-06): mixed 内 file block 视频用 block URL 打开。
  final void Function(ImMessage parent, ImMessageBlock block)? onOpenVideoBlock;

  /// F09 P1 已读回执 v1: 自己 sent 非 revoked/pending/failed/uploading 才渲染入口。
  /// null = controller 尚未就绪 (open 中); 入口不渲染。
  final ChatReceiptsController? receipts;

  @override
  Widget build(BuildContext context) {
    final isPeer = msg.fromUid != myUid;
    final bg = isPeer
        ? ChatTheme.enterprisePeerBubble
        : ChatTheme.enterpriseSelfBubble;

    final Widget bubble;
    // 只有纯文本气泡(撤回提示 / 普通文本)整条包一层 ChatSelectableSurface;
    // 图片/文件/mixed/EMP/通话卡片这些**没有直接文字**或者**自己内部已经按块
    // 单独包了**(mixed)的分支不能再在这里整体包一层——ChatSelectableSurface
    // 永久 IgnorePointer,包住图片/文件会直接挡掉它们的点击。
    var wrapSelectable = false;
    if (msg.isRevoked) {
      // F09 P1 tombstone: 撤回后两侧统一灰色提示, 不渲染原文 / 媒体。
      // 自己侧「你撤回了一条消息」、对端「对方撤回了一条消息」。
      wrapSelectable = true;
      final tombstoneText = isPeer ? '对方撤回了一条消息' : '你撤回了一条消息';
      bubble = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          tombstoneText,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF8A94A6),
            fontStyle: FontStyle.italic,
            height: 1.4,
          ),
        ),
      );
    } else if (isCallEventLikeMessage(msg)) {
      bubble = ChatCallEventCard(
        label: callEventMessageLabel(msg),
        endReason: callEventMessageEndReason(msg),
      );
    } else if (msg.empBlocks.isNotEmpty) {
      bubble = EmpBlocksView(blocks: msg.empBlocks);
    } else if (msg.mediaKind == ImMediaKind.image && msg.mediaUrl.isNotEmpty) {
      // 图片消息:直接出缩略图(无气泡边框,贴近主流 IM)。点击 → P2 大图预览 overlay。
      bubble = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: HumanDirectMediaImage(
          url: msg.mediaUrl,
          onPreviewWithHero: onPreviewImage == null
              ? null
              : (tag) => onPreviewImage!(msg, heroTag: tag),
        ),
      );
    } else if (msg.mediaKind == ImMediaKind.file && msg.mediaUrl.isNotEmpty) {
      // P2 (2026-06): 视频以「视频卡片」呈现 (file wire + 客户端识别);
      // 点击 → 下载 + 系统打开 (本轮无内嵌播放器)。
      final isVideo = isVideoMessage(msg);
      bubble = HumanDirectFileCard(
        url: msg.mediaUrl,
        name: msg.mediaName.isNotEmpty ? msg.mediaName : msg.text,
        size: msg.mediaSize,
        mime: msg.mediaMime,
        isVideoOverride: isVideo,
        onOpen: isVideo && onOpenVideo != null ? () => onOpenVideo!(msg) : null,
      );
    } else if (msg.isMixed) {
      // P2 (2026-06 CR): 把 parentMessage + 媒体回调透传给 mixed bubble, 让 image/video block
      // 走与顶层媒体一致的预览 / 打开链路。
      bubble = ChatMixedMessageBubble(
        blocks: msg.blocks,
        backgroundColor: bg,
        isPeer: isPeer,
        parentMessage: msg,
        onPreviewImage: onPreviewImage,
        onOpenVideo: onOpenVideoBlock,
      );
    } else {
      wrapSelectable = true;
      final text = msg.text.isNotEmpty ? msg.text : '[非文本消息]';
      bubble = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: isPeer ? 8 : 6
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isPeer
                ? ChatTheme.enterprisePeerBubbleBorder
                : ChatTheme.enterpriseSelfBubbleBorder,
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF1D2129),
            height: 1.5,
          ),
        ),
      );
    }

    // F09 引用回复 v1: 气泡内引用块. 撤回视图 (tombstone) 时不画 (无锚点); 其余消息均可带.
    // 气泡正文(不含引用预览块/发送者名字行)——纯文本才包 ChatSelectableSurface,
    // mixed 已经按块单独包了(见 ChatMixedMessageBubble),图片/文件/EMP/通话卡片
    // 不包(没有可选文字,包了反而挡住点击)。
    Widget bubbleWithReply =
        wrapSelectable ? ChatSelectableSurface(child: bubble) : bubble;
    if (replyRef != null && !msg.isRevoked) {
      bubbleWithReply = Column(
        crossAxisAlignment:
            isPeer ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ChatBubbleReplyBlock(
            reference: replyRef!,
            onTap:
                onLocateReply == null ? null : () => onLocateReply!(replyRef!),
          ),
          wrapSelectable ? ChatSelectableSurface(child: bubble) : bubble,
        ],
      );
    }

    // P2 + F09 P1/C/v2: 右键 / 长按 → 复制 / 引用 / 转发 / 多选 / 重发 / 撤回 / 保存文件 / 本地删除 / 取消上传。
    final actionBubble = ChatMessageActionRegion(
      msg: msg,
      isMine: !isPeer,
      onReply: onReply == null ? null : () => onReply!(msg),
      onForward: onForward == null ? null : () => onForward!(msg),
      onMultiSelect: onMultiSelect == null ? null : () => onMultiSelect!(msg),
      onResend: onRetry == null ? null : () => onRetry!(msg),
      onRevoke: onRevoke == null ? null : () => onRevoke!(msg),
      onSaveFile: onSaveFile == null ? null : () => onSaveFile!(msg),
      onDelete: onDelete == null ? null : () => onDelete!(msg),
      onCancelUpload:
          onCancelUpload == null ? null : () => onCancelUpload!(msg),
      child: bubbleWithReply,
    );

    // F09 P1 已读回执 v1: 自己 sent (非 revoked/pending/failed/uploading) 左侧始终保留
    // 一个状态位。receipts controller / snapshot 没就绪时由 ChatReceiptStatusSlot 显示
    // 弱灰占位 (不消失、不假已读);pending/failed/uploading 仍走上面的发送态指示器。
    final bool showSelfReceiptSlot = shouldShowSelfReceiptStatusSlot(
      msg: msg,
      isPeer: isPeer,
    );

    final children = isPeer
        ? <Widget>[
            Flexible(fit: FlexFit.loose, child: actionBubble)
          ]
        : <Widget>[
            Flexible(
              fit: FlexFit.loose,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // uploading(本地媒体上传中)→ 进度+取消;否则 pending 转圈 / failed 红色感叹号(可点重发)。
                  if (msg.isUploading)
                    ChatUploadProgressIndicator(
                      progress: msg.uploadProgress,
                      onCancel: () => onCancelUpload?.call(msg),
                    )
                  else
                    ChatSendStatusIndicator(
                      isPeer: isPeer,
                      status: msg.sendStatus,
                      errorMessage: msg.errorMessage,
                      onRetry: (msg.isFailed &&
                              onRetry != null &&
                              (msg.mediaKind != ImMediaKind.none ||
                                  msg.text.isNotEmpty))
                          ? () => onRetry!(msg)
                          : null,
                    ),
                  // F09 P1 已读回执状态位 (单聊):贴气泡左下角, snapshot 没回来也不消失。
                  if (showSelfReceiptSlot)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, bottom: 3),
                      child: ChatReceiptStatusSlot(
                        controller: receipts,
                        messageSeq: msg.messageSeq,
                        isGroup: false,
                      ),
                    ),
                  Flexible(fit: FlexFit.loose, child: actionBubble),
                ],
              ),
            ),
          ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isPeer ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}
