import 'dart:async';

import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart'
    show EmpBlocksRespondHandler;
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_answer_reveal.dart'
    show ChatAnswerRevealBuffer;
import 'package:zhiban_client/pages/chat/widgets/chat_conversation_layout.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart'
    show isRenderObjectAttached;
import 'package:zhiban_client/pages/chat/widgets/chat_scroll.dart';
import 'chat_conversation_pair_view.dart';
import 'chat_system_message_view.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollDirection, RenderAbstractViewport;
import 'package:flutter/scheduler.dart' show Ticker;

class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.activeConversationId,
    required this.messages,
    required this.hasMoreHistory,
    required this.isLoadingHistory,
    required this.isSending,
    required this.maxBubbleWidth,
    required this.bottomContentInset,
    required this.onLoadMoreHistory,
    this.onLoadNewerHistory,
    this.hasMoreNewer = false,
    this.isLoadingNewer = false,
    this.onScrolledToBottom,
    this.onJumpToLatest,
    this.onMobileBackgroundInteraction,
    this.onOpenAttachment,
    this.onStop,
    this.userAvatarUrl,
    this.agentAvatarUrl,
    this.highlightMessageUuid,
    this.highlightToken = 0,
    this.onHighlightConsumed,
    this.respondHandler,
    this.skillIconUrls = const {},
  });

  final String? activeConversationId;
  final List<ChatMessage> messages;
  final bool hasMoreHistory;
  final bool isLoadingHistory;
  final bool isSending;
  final double maxBubbleWidth;
  final double bottomContentInset;
  final FutureOr<void> Function() onLoadMoreHistory;

  /// 「向下加载更新消息」：仅 around 入中段场景会挂，普通会话此项为 null。
  /// 底部距离 <= 触发阈值时由 NotificationListener 触发一次。
  final VoidCallback? onLoadNewerHistory;

  /// 对应 [ChatState.hasMoreNewer]。true 时底部"向下加载"才会启动。
  final bool hasMoreNewer;

  /// 对应 [ChatState.isLoadingNewer]，用于底部显示转圈 + 防重复触发。
  final bool isLoadingNewer;

  /// 用户主动滚到底部时回调（典型用途：把 active 会话标记为已读，清红点）。
  /// 仅在「点底部箭头」这种用户显式操作时触发，不在被动 jumpToBottom 时触发。
  final VoidCallback? onScrolledToBottom;

  /// 「一键跳到最新」：当 [hasMoreNewer]=true（around 中段模式）时，点底部箭头
  /// 走这条快路径——不要逐页 loadNewerHistory 拖几千条，让上层直接重置到首屏
  /// 最新。回调 resolve 后 messages 会被替换 + hasMoreNewer 清零，本 widget
  /// 的 didUpdateWidget 检测到"从中段模式回到首屏"会自动强制跳底部。
  final VoidCallback? onJumpToLatest;

  final VoidCallback? onMobileBackgroundInteraction;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  /// 透传给 assistant 状态条上的"停止"按钮；通常 == [ChatNotifier.stop]。
  final VoidCallback? onStop;

  /// 用户/智能体头像 URL，进一步透传给 [ChatConversationPairView]。
  final String? userAvatarUrl;
  final String? agentAvatarUrl;

  /// 「在对话中查看 cron 历史」链路要求滚动+高亮的目标消息 uuid。
  /// 配合 [highlightToken] 一起做防抖：同一个 uuid 被点两次也要触发新一轮高亮，
  /// 单看 uuid 是否变化判断不出来；token 严格递增就能触发 didUpdateWidget。
  final String? highlightMessageUuid;
  final int highlightToken;

  /// 高亮动画结束 / 滚动定位完成后回调，让上层 ChatNotifier 清掉 state 上的标记。
  final VoidCallback? onHighlightConsumed;

  /// ADR-0028 §4.9 — HITL 富组件 (approval/form/action) 提交回调集; null 时保持只读。
  /// 由 [ChatSessionView] 透传自 chat_conversation_content (ref.read(chatProvider.notifier))。
  final EmpBlocksRespondHandler? respondHandler;
  final Map<String, String> skillIconUrls;

  @override
  ChatMessageListState createState() => ChatMessageListState();
}

class ChatMessageListState extends State<ChatMessageList>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final BottomAwareScrollController _scrollController =
      BottomAwareScrollController();
  static const double _scrollThreshold = 100;
  static const double _streamFollowBottomThreshold = 4;

  late final Ticker _streamFollowTicker;
  bool _streamAutoFollow = true;

  /// 行级步进跟滚的追平态：false = 静止攒漂移；true = 正在快速追平一小段。
  bool _followCatchingUp = false;

  bool _showScrollToBottomButton = false;
  bool _isListVisible = false;
  final Map<String, String> _rowIdentityByAlias = {};
  double _viewportHeight = 0;
  double _lastLayoutMaxHeight = 0;
  double? _lastMessageMinHeight;
  int _lastRenderedMessageCount = 0;
  String? _lastConversationId;

  /// 当前正在闪烁高亮的消息 uuid（形如 `cron-<runId>`），由「在对话中查看」链路写入。
  /// 用于在 _buildMessageChildren 里给目标行加 box decoration 闪烁，1.5s 后清掉。
  String? _highlightingUuid;
  int _lastConsumedHighlightToken = 0;
  // 记录每条消息当前挂载的 BuildContext，定位时用 Scrollable.ensureVisible 滚到位。
  // 不用长期 GlobalKey，避免历史分页 prepend 时移动整棵消息子树触发 Flutter
  // InheritedNotifier descendant 断言。
  final Map<String, BuildContext> _messageContexts = {};

  /// 本轮 didUpdateWidget 检测到同时发生 `activeConversationId 切换 + highlight
  /// 请求` 时置 true：此时 [_jumpToBottomWhenReady] / [_smartScrollToBottom]
  /// 必须让路，否则它们 PostFrame 拽到底部会盖掉 ensureVisible 的结果，表现
  /// 就是「点历史跳转 → 看到的是目标之后的窗口末尾，而不是目标本身」。
  /// 高亮动画结束后 [_scheduleHighlight] 把它清零。
  bool _suppressNextJumpToBottom = false;

  /// 程序化滚动期间置 true，阻止 [NotificationListener] 误触 [onLoadMoreHistory]
  /// / [onLoadNewerHistory]。覆盖两条路径：
  ///   - `_scheduleHighlight` 做 320ms 的 ensureVisible 跳 cron 历史；
  ///   - `_applyPendingAnchor` 做分页完成后的 anchor 对齐。
  bool _programmaticScrollInProgress = false;
  Object? _olderRequest;
  int _bottomScrollGeneration = 0;

  /// 上一次成功触发 [onLoadMoreHistory] / [onLoadNewerHistory] 的时间。
  /// 配合 [_paginationCooldown] 做 3s 节流：用户"连续滚动"里 isLoading 翻转
  /// 的瞬间可能被下一个 ScrollUpdate 再次命中，这里加硬冷却避免一次滚动
  /// 触发两次分页。null = 从未触发过。
  DateTime? _lastPaginationTriggerAt;
  static const Duration _paginationCooldown = Duration(seconds: 3);

  /// 分页加载完成后的 anchor 对齐计划：
  ///   - 触发底部分页前记录 `uuid = messages.last.id, alignment = 0.0`
  ///     ——加载完新消息 append 进列表，把原末条推到视口顶部，新数据从
  ///     它下方延伸。
  /// `didUpdateWidget` 侦测到 messages 长度增长会调 [_applyPendingAnchor]
  /// 用 `Scrollable.ensureVisible` 把 anchor 放到指定位置，之后清零。
  String? _pendingAnchorUuid;
  double _pendingAnchorAlignment = 1.0;

  bool get isNearBottom {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return true;
    }
    final distance = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    return distance <= 4;
  }

  @override
  void initState() {
    super.initState();
    _streamFollowTicker = createTicker(_onStreamFollowFrame);
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.activeConversationId == null) {
        _isListVisible = true;
        return;
      }
      _lastConversationId = widget.activeConversationId;
      _lastRenderedMessageCount = widget.messages.length;
      // 关键：当「在对话中查看 cron 历史」链路触发 context.go(chat) 后本 widget 是
      // 被 initState 全新创建（而不是 didUpdateWidget 接收变更），此时 widget 第
      // 一次 mount 就已经带着 highlightToken+highlightMessageUuid。didUpdateWidget
      // 里的 highlight 分派分支根本不会跑，结果就只走了 _scheduleJumpToBottom 把
      // 视口拽到最底（表现：跳 #500 落到 #520）。这里先把 highlight 分派起来，
      // 有目标就 suppress 掉默认的 jumpToBottom、交给 _scheduleHighlight 主导；
      // 没目标再走 jumpToBottom 维持原语义。
      if (!_maybeScheduleHighlight()) {
        _scheduleJumpToBottom();
      }
    });
  }

  /// 检查 widget 当前是否携带了未消费的 highlight 请求，有则：
  ///   1. 置 [_suppressNextJumpToBottom] = true，挡住所有 jumpToBottom 链路；
  ///   2. 记 [_lastConsumedHighlightToken] 避免 didUpdateWidget 再消费一次；
  ///   3. 调 [_scheduleHighlight] 走 ensureVisible。
  /// 返回 true 表示已被 highlight 接管、调用方不要再排 jumpToBottom。
  bool _maybeScheduleHighlight() {
    final wantUuid = widget.highlightMessageUuid;
    final wantToken = widget.highlightToken;
    if (wantUuid == null || wantUuid.isEmpty) {
      return false;
    }
    if (wantToken == _lastConsumedHighlightToken) {
      return false;
    }
    _lastConsumedHighlightToken = wantToken;
    _suppressNextJumpToBottom = true;
    _scheduleHighlight(wantUuid);
    return true;
  }

  @override
  void dispose() {
    _streamFollowTicker.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _messageContexts.clear();
    super.dispose();
  }

  void _registerMessageContext(String uuid, BuildContext context) {
    _messageContexts[uuid] = context;
  }

  void _unregisterMessageContext(String uuid, BuildContext context) {
    if (identical(_messageContexts[uuid], context)) {
      _messageContexts.remove(uuid);
    }
  }

  BuildContext? _messageContext(String uuid) {
    final ctx = _messageContexts[uuid];
    if (ctx == null) return null;
    if (!ctx.mounted) {
      _messageContexts.remove(uuid);
      return null;
    }
    return ctx;
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeConversationId != widget.activeConversationId) {
      _rowIdentityByAlias.clear();
      _bottomScrollGeneration++;
      _olderRequest = null;
      _lastPaginationTriggerAt = null;
      _pendingAnchorUuid = null;
      _stopStreamFollow();
      _streamAutoFollow = true;
      _lastConversationId = widget.activeConversationId;
      _lastMessageMinHeight = null;
      _lastRenderedMessageCount = widget.messages.length;
      if (_isListVisible) {
        _isListVisible = false;
      }
      _scheduleJumpToBottom();
    }

    if (oldWidget.bottomContentInset != widget.bottomContentInset &&
        _lastLayoutMaxHeight > 0) {
      _lastMessageMinHeight = null;
      _viewportHeight = (_lastLayoutMaxHeight - widget.bottomContentInset)
          .clamp(0.0, double.infinity);
    }

    // 流式 delta：messages.length 没变但最后一条 content 在追加。
    // 混合停跟（标准规则 8）：细粒度揭示阶段（正文仍在 fineGrainedRuneBudget
    // 内）打字伴随平滑跟滚，保持"生成中"的活感；预算耗尽后 provider 整批
    // 铺出剩余内容，这里同步停跟，视口停在当前阅读位置，只在 layout 后
    // 重估与底部的距离，让“回到最新”按钮及时出现。
    if (oldWidget.messages.length == widget.messages.length &&
        oldWidget.messages.isNotEmpty &&
        widget.messages.isNotEmpty &&
        oldWidget.messages.last.content != widget.messages.last.content) {
      final shouldFollow = _isInStreamFollowPhase(widget.messages.last) &&
          _streamAutoFollow &&
          (_streamFollowTicker.isActive || _isAtBottomNow());
      if (!shouldFollow) _stopStreamFollow();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleScroll();
        if (shouldFollow) _startStreamFollow();
      });
    }

    if (oldWidget.messages.length != widget.messages.length ||
        oldWidget.activeConversationId != widget.activeConversationId) {
      _syncAfterMessageUpdate();
    }

    // around 中段模式 → 首屏最新模式：hasMoreNewer 从 true 降为 false 且会话
    // 未切换，说明是用户点"跳到最新"触发的 jumpToLatest。把 suppress 清掉 +
    // 排一次 jumpToBottom，否则列表 replace 后视口停留在中段顶部，用户再找
    // 新消息就尴尬了。
    if (oldWidget.hasMoreNewer &&
        !widget.hasMoreNewer &&
        !oldWidget.isLoadingNewer &&
        _pendingAnchorUuid == null &&
        oldWidget.activeConversationId == widget.activeConversationId) {
      _suppressNextJumpToBottom = false;
      _scheduleJumpToBottom();
    }

    // 处理来自上层的「滚动 + 高亮 cron 消息」请求。token 严格递增 → 同一 uuid
    // 重复点击也能触发新一轮动画（同 uuid 不变，靠 token 判定）。
    // 同时发生"会话切换"时，上面已经排了 _scheduleJumpToBottom，后面还有
    // _syncAfterMessageUpdate 在 oldCount==0 时也会跳底。_maybeScheduleHighlight
    // 里压 suppress=true 让它们让路。
    _maybeScheduleHighlight();
  }

  void _scheduleHighlight(String uuid) {
    _olderRequest = null;
    _bottomScrollGeneration++;
    _stopStreamFollow(disableAutoFollow: true);
    // selectConversation 后 messages 是异步加载的，先 PostFrame 等列表渲染一次；
    // 找不到定位 context 则再延迟一次（200ms）兜底；都找不到就放弃，避免无限重试。
    Future<void> attempt(int retries) async {
      if (!mounted) return;
      final ctx = _messageContext(uuid);
      if (ctx == null) {
        if (retries > 0) {
          await Future.delayed(const Duration(milliseconds: 200));
          attempt(retries - 1);
        } else {
          // 彻底没找到目标行：放行 jumpToBottom，并让 UI 标记可见、清高亮 token。
          _suppressNextJumpToBottom = false;
          if (mounted && !_isListVisible) {
            setState(() => _isListVisible = true);
          }
          widget.onHighlightConsumed?.call();
        }
        return;
      }
      // 动画过程中 pixels 会从 0 被推向目标，第一帧命中顶部分页阈值会误触
      // loadMoreHistory，prepend 后内容整体偏移，最终视口对应的消息不再是
      // 目标。先压一把 flag 挡掉 NotificationListener 里的分页触发。
      if (!_scrollController.hasClients) return;
      if (!isRenderObjectAttached(ctx)) return;
      _programmaticScrollInProgress = true;
      try {
        await Scrollable.ensureVisible(
          ctx,
          // 定位到消息头部（顶对齐），避免落在视口中部导致用户二次寻找。
          alignment: 0.0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
      } finally {
        _programmaticScrollInProgress = false;
      }
      if (!mounted) return;
      // 滚动已落位，可以放行后续的 jumpToBottom（如果用户之后手动切会话等）。
      _suppressNextJumpToBottom = false;
      // 确保列表可见——走 suppress 分支时我们压了 _jumpToBottomWhenReady，
      // setState(_highlightingUuid) 顺便把 _isListVisible 兜底置回。
      setState(() {
        _highlightingUuid = uuid;
        if (!_isListVisible) _isListVisible = true;
      });
      await Future.delayed(const Duration(milliseconds: 1600));
      if (!mounted) return;
      if (_highlightingUuid == uuid) {
        setState(() => _highlightingUuid = null);
      }
      widget.onHighlightConsumed?.call();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      attempt(6);
    });
  }

  void _syncAfterMessageUpdate() {
    if (_lastConversationId != widget.activeConversationId) return;
    if (_lastRenderedMessageCount == widget.messages.length) return;

    final oldCount = _lastRenderedMessageCount;
    _lastRenderedMessageCount = widget.messages.length;

    if (_olderRequest != null) return;
    if (widget.messages.length > oldCount) {
      // 有 pending anchor 说明是上/下分页加载刚回来：把原边界消息滚到视口
      // 指定端，优先级高于默认的 jumpToBottom / smartScroll（否则 prepend 会
      // 被 retainDistance 顶在原位、append 会被 smartScroll 拉到最底）。
      if (_pendingAnchorUuid != null) {
        _applyPendingAnchor();
        return;
      }
      if (oldCount == 0) {
        _scheduleJumpToBottom();
      } else {
        _smartScrollToBottom();
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_olderRequest != null ||
        widget.isLoadingHistory ||
        !widget.hasMoreHistory ||
        !_scrollController.hasClients) {
      return;
    }
    final conversation = widget.activeConversationId;
    final uuid = _firstRowUuid();
    final anchor = uuid == null ? null : _messageContext(uuid);
    final box = anchor?.findRenderObject();
    final anchorOffset = box is RenderBox && box.attached
        ? RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset
        : null;
    final request = Object();
    _olderRequest = request;
    _bottomScrollGeneration++;
    _stopStreamFollow(disableAutoFollow: true);
    try {
      await widget.onLoadMoreHistory();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          widget.activeConversationId != conversation ||
          !identical(_olderRequest, request) ||
          !_scrollController.hasClients ||
          anchorOffset == null) {
        return;
      }
      final updated =
          uuid == null ? null : _messageContext(uuid)?.findRenderObject();
      if (updated is! RenderBox || !updated.attached) return;
      final delta = RenderAbstractViewport.of(updated)
              .getOffsetToReveal(updated, 0)
              .offset -
          anchorOffset;
      final position = _scrollController.position;
      // 保留同一消息在屏幕上的位置，不能把整行强制搬到视口底部。
      _scrollController.jumpTo((position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    } catch (_) {
      if (!mounted || !identical(_olderRequest, request)) return;
      if (usesChatPullToRefresh(context)) rethrow;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('加载更早消息失败，请重试'))
      );
    } finally {
      if (identical(_olderRequest, request)) _olderRequest = null;
    }
  }

  /// 从 [widget.messages] 首个非系统消息拿 uuid/messageId，给分页 anchor 用。
  String? _firstRowUuid() {
    for (final m in widget.messages) {
      final id = m.uuid ?? m.messageId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  String? _lastRowUuid() {
    for (var i = widget.messages.length - 1; i >= 0; i--) {
      final m = widget.messages[i];
      final id = m.uuid ?? m.messageId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  /// 把 [_pendingAnchorUuid] 对应的行用 `Scrollable.ensureVisible` 滚到视口的
  /// [_pendingAnchorAlignment] 位置：
  ///   - 上加载：alignment=1.0，原首条 → 视口底，老数据从它上方开始显示；
  ///   - 下加载：alignment=0.0，原末条 → 视口顶，新数据从它下方开始显示。
  ///
  /// 执行期间挂 `_programmaticScrollInProgress = true`，避免 NotificationListener
  /// 在动画途中（pixels 抖动）再次误触分页。
  void _applyPendingAnchor() {
    _stopStreamFollow(disableAutoFollow: true);
    final uuid = _pendingAnchorUuid;
    final alignment = _pendingAnchorAlignment;
    _pendingAnchorUuid = null;
    if (uuid == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final ctx = _messageContext(uuid);
      if (ctx == null) {
        return;
      }
      if (!_scrollController.hasClients) {
        return;
      }
      if (!isRenderObjectAttached(ctx)) {
        return;
      }
      _programmaticScrollInProgress = true;
      try {
        // duration=0 直接瞬跳，不做动画：用户手向上滚触发的加载，如果用动画
        // 反方向下滑会有违和感；瞬跳让"转圈 → 数据一到 anchor 就在视口底
        // (上加载) 或顶 (下加载)"的过渡更自然。
        await Scrollable.ensureVisible(
          ctx,
          alignment: alignment,
          duration: Duration.zero,
        );
      } catch (_) {
      } finally {
        _programmaticScrollInProgress = false;
      }
      if (!mounted) return;
    });
  }

  List<ChatConversationItem> get _items => buildChatConversationItems(
        widget.messages,
        includeWelcomeWhenEmpty: false,
      );

  void _handleScroll() {
    if (!mounted) return;
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return;
    }
    final distance = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_scrollController.position.userScrollDirection !=
        ScrollDirection.idle) {
      if (distance <= _streamFollowBottomThreshold) {
        _streamAutoFollow = true;
      } else {
        _stopStreamFollow(disableAutoFollow: true);
      }
    }
    final shouldShow = distance > _scrollThreshold;
    if (shouldShow != _showScrollToBottomButton) {
      setState(() => _showScrollToBottomButton = shouldShow);
    }
  }

  void scrollToBottom({bool animated = false, bool hideDuringJump = false}) {
    if (!mounted) return;
    // suppress 期间完全不触碰滚动位置：highlight 跳转路径已经排了 ensureVisible，
    // 任何 jumpTo(maxScrollExtent) 都会盖住它（表现为跳 #500 却停在 #520）。
    if (_suppressNextJumpToBottom) {
      if (hideDuringJump && !_isListVisible) {
        setState(() => _isListVisible = true);
      }
      return;
    }
    final generation = ++_bottomScrollGeneration;
    _olderRequest = null;
    _stopStreamFollow();
    _streamAutoFollow = true;
    // Any scroll (including keyboard metrics and stream updates) supersedes
    // the initial/rekey jump, so it must also reveal the mounted list.
    if (!_isListVisible) {
      setState(() => _isListVisible = true);
    }
    if (animated) {
      if (!_scrollController.hasClients) return;
      if (!_scrollController.position.hasContentDimensions) return;
      final max = _scrollController.position.maxScrollExtent;
      _scrollController
          .animateTo(
        max,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      )
          .whenComplete(() {
        if (mounted && generation == _bottomScrollGeneration) {
          _correctBottomAlignment(0, generation);
        }
      });
      return;
    }
    if (hideDuringJump && _isListVisible) {
      setState(() => _isListVisible = false);
    }
    if (_scrollController.hasClients &&
        _scrollController.position.hasContentDimensions) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      if (hideDuringJump && !_isListVisible) {
        setState(() => _isListVisible = true);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _correctBottomAlignment(0, generation);
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _bottomScrollGeneration) return;
      _jumpToBottomWhenReady(0, generation);
    });
  }

  void _jumpToBottomWhenReady(int retry, int generation) {
    if (!mounted || generation != _bottomScrollGeneration) return;
    if (_suppressNextJumpToBottom) {
      // 本轮 didUpdateWidget 叠了 highlight 请求，滚动交给 _scheduleHighlight。
      // 只是跳过本次，让 _isListVisible 仍要被置回 true，否则整个列表会一直透明。
      if (!_isListVisible) {
        setState(() => _isListVisible = true);
      }
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.hasContentDimensions) {
      scrollToBottom(hideDuringJump: true);
      return;
    }
    if (retry >= 6) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottomWhenReady(retry + 1, generation);
    });
  }

  void _correctBottomAlignment(int retry, int generation) {
    if (!mounted || generation != _bottomScrollGeneration) return;
    // 「在对话中查看 cron」跳转时，上一轮 scrollToBottom 留下的 _correctBottomAlignment
    // 会递归 4 次跨帧 jumpTo(maxScrollExtent)。如果这期间 messages 从 0 扩到 N，
    // 它会把 ensureVisible 的结果拽回最底部——用户看到的就是目标消息之后的窗口
    // 末尾（如跳 #500 却停在 #520）。这里和 _jumpToBottomWhenReady 保持一致，
    // suppress 期间整条链路让路。
    if (_suppressNextJumpToBottom) return;
    if (!_scrollController.hasClients) return;
    if (!_scrollController.position.hasContentDimensions) {
      if (retry < 4) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _correctBottomAlignment(retry + 1, generation);
        });
      }
      return;
    }
    final distance = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (distance.abs() <= 2) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    if (retry < 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _correctBottomAlignment(retry + 1, generation);
      });
    }
  }

  void _scheduleJumpToBottom() {
    final generation = ++_bottomScrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _bottomScrollGeneration) return;
      _jumpToBottomWhenReady(0, generation);
    });
  }

  /// 平滑跟随只覆盖细粒度揭示阶段：最后一条 answer 仍在流式生成、且已揭示
  /// 正文没超过 [ChatAnswerRevealBuffer.fineGrainedRuneBudget]（与 provider
  /// 的两阶段切换共用同一常量，保证"停止打字机"与"停止跟滚"同帧发生）。
  bool _isInStreamFollowPhase(ChatMessage last) {
    if (last.role != ChatRole.answer) return false;
    if (last.status != BubbleStatus.loading) return false;
    return last.content.runes.length <
        ChatAnswerRevealBuffer.fineGrainedRuneBudget;
  }

  /// 当前视口是否贴底（流式跟随判定用）。
  /// 没有 client / 没有 content dimensions 时按"贴底"处理 —— 列表刚 mount 还
  /// 没 layout 时新增内容应该自动落到底，符合用户直觉。
  bool _isAtBottomNow() {
    if (!_scrollController.hasClients) return true;
    if (!_scrollController.position.hasContentDimensions) return true;
    final distance = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    return distance <= _scrollThreshold;
  }

  void _startStreamFollow() {
    if (!_streamAutoFollow ||
        _suppressNextJumpToBottom ||
        _programmaticScrollInProgress) {
      return;
    }
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return;
    }
    if (!_streamFollowTicker.isActive) {
      _streamFollowTicker.start();
    }
  }

  void _stopStreamFollow({bool disableAutoFollow = false}) {
    if (_streamFollowTicker.isActive) {
      _streamFollowTicker.stop();
    }
    _followCatchingUp = false;
    if (disableAutoFollow) {
      _streamAutoFollow = false;
    }
  }

  void _onStreamFollowFrame(Duration _) {
    if (!mounted ||
        !_streamAutoFollow ||
        _suppressNextJumpToBottom ||
        _programmaticScrollInProgress ||
        !_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      _stopStreamFollow();
      return;
    }

    final position = _scrollController.position;
    final target = position.maxScrollExtent;

    // 行级步进：漂移不足约一行时保持完全静止（连续慢速漂移 = 视觉残留），
    // 攒够一行再用更快的插值追平这一小段，追平后回到静止。
    if (!_followCatchingUp) {
      if (target - position.pixels < streamFollowStepThreshold) {
        _stopStreamFollow();
        return;
      }
      _followCatchingUp = true;
    }

    final next = nextStreamFollowOffset(
      current: position.pixels,
      target: target,
      factor: streamFollowCatchUpFactor,
    ).clamp(position.minScrollExtent, target).toDouble();
    if (next != position.pixels) {
      _scrollController.jumpTo(next);
    }
    if ((target - next).abs() <= streamFollowStopEpsilon) {
      _stopStreamFollow();
    }
  }

  void _smartScrollToBottom() {
    if (_suppressNextJumpToBottom || _olderRequest != null) return;
    if (!_showScrollToBottomButton) {
      final generation = _bottomScrollGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            generation != _bottomScrollGeneration ||
            _olderRequest != null) {
          return;
        }
        scrollToBottom();
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final followBottom = isNearBottom && _olderRequest == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (followBottom) scrollToBottom();
      _handleScroll();
    });
  }

  /// 对应 intellispeak [ChatController.onSendHandler] 里发送前 `_lastMessageMinHeight = null`。
  void resetLastMessageMinHeight() {
    _lastMessageMinHeight = null;
  }

  /// 与 intellispeak [ChatController.getMessageMinHeight] 一致：
  /// 仅当扁平 [messages] 最后一条为 answer 时参与计算（即 main_dialogue 里 `index == chatList.length - 1` 且取 answer 气泡）；
  /// 首次 loading 时锁定视口高度，非 loading 仍返回已记录值直至 [resetLastMessageMinHeight]。
  double? _minHeightForLastAnswerRow() {
    final messages = widget.messages;
    if (messages.isEmpty) return null;
    final last = messages.last;

    if (last.role != ChatRole.answer) return null;
    if (last.status == BubbleStatus.loading) {
      _lastMessageMinHeight ??= _viewportHeight;
      return _lastMessageMinHeight;
    }
    return _lastMessageMinHeight;
  }

  List<Widget> _buildMessageChildren(List<ChatConversationItem> items) {
    final children = <Widget>[];
    final rowKeyOccurrences = <String, int>{};
    if (widget.isLoadingHistory && !usesChatPullToRefresh(context)) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Center(child: CupertinoActivityIndicator(radius: 7)),
        ),
      );
    }
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;
      final minHeight = isLast ? _minHeightForLastAnswerRow() : null;
      final rowUuids = _rowUuids(item);
      Widget row = switch (item.kind) {
        ChatConversationItemKind.systemMessage ||
        ChatConversationItemKind.systemPrompt =>
          ChatSystemMessageView(
            item: item as ChatSystemConversationItem,
          ),
        ChatConversationItemKind.welcome => const SizedBox.shrink(),
        ChatConversationItemKind.pair => ChatConversationPairView(
            item: item as ChatPairConversationItem,
            maxWidth: widget.maxBubbleWidth,
            onOpenAttachment: widget.onOpenAttachment,
            onStop: widget.onStop,
            userAvatarUrl: widget.userAvatarUrl,
            agentAvatarUrl: widget.agentAvatarUrl,
            conversationUuid: widget.activeConversationId,
            respondHandler: widget.respondHandler,
            skillIconUrls: widget.skillIconUrls,
          ),
      };
      // 定位后不再做背景高亮，仅保留滚动到目标消息的行为。

      final rowContainer = Container(
        constraints:
            minHeight != null ? BoxConstraints(minHeight: minHeight) : null,
        child: row,
      );
      final localId = item is ChatPairConversationItem
          ? item.userMessage?.localId ?? item.assistantMessage?.localId
          : null;
      final aliases = [
        if (localId != null) 'local:$localId',
        ...rowUuids.map((id) => 'server:$id'),
      ];
      if (aliases.isNotEmpty) {
        // The optimistic row already owns its identity before server IDs exist.
        // Keep server aliases so history refreshes can reuse the same element.
        final keyId = aliases
                .map((alias) => _rowIdentityByAlias[alias])
                .whereType<String>()
                .firstOrNull ??
            (rowUuids.isNotEmpty ? rowUuids.first : aliases.first);
        for (final alias in aliases) {
          _rowIdentityByAlias[alias] = keyId;
        }
        final occurrence = (rowKeyOccurrences[keyId] ?? 0) + 1;
        rowKeyOccurrences[keyId] = occurrence;
        final rowKey = occurrence == 1
            ? 'chat-message-row:$keyId'
            : 'chat-message-row:$keyId#$occurrence';
        children.add(
          _ChatMessageAnchor(
            key: ValueKey(rowKey),
            uuids: rowUuids,
            onRegister: _registerMessageContext,
            onUnregister: _unregisterMessageContext,
            child: rowContainer,
          ),
        );
        continue;
      }
      children.add(rowContainer);
    }
    return children;
  }

  List<String> _rowUuids(ChatConversationItem item) {
    final ids = <String>[];
    void add(String? value) {
      final id = value?.trim();
      if (id == null || id.isEmpty || ids.contains(id)) return;
      ids.add(id);
    }

    if (item is ChatPairConversationItem) {
      add(item.userMessage?.uuid);
      add(item.userMessage?.messageId);
      add(item.assistantMessage?.uuid);
      add(item.assistantMessage?.messageId);
    } else if (item is ChatSystemConversationItem) {
      add(item.messageId);
    }
    return ids;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final horizontalPadding = ChatConversationLayout.horizontalPadding();

    return LayoutBuilder(
      builder: (context, constraints) {
        _lastLayoutMaxHeight = constraints.maxHeight;
        if (_viewportHeight <= 0) {
          _viewportHeight = (constraints.maxHeight - widget.bottomContentInset)
              .clamp(0.0, double.infinity);
        }
        return Stack(
          children: [
            Opacity(
              opacity: _isListVisible ? 1 : 0,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth != 0 || items.isEmpty) return false;
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _bottomScrollGeneration++;
                    _stopStreamFollow(disableAutoFollow: true);
                    _lastPaginationTriggerAt = null;
                  }
                  if (!_scrollController.hasClients ||
                      !_scrollController.position.hasContentDimensions) {
                    return false;
                  }
                  // around 跳转期间 ensureVisible 动画把 pixels 从 0 推到目标，
                  // 第一帧 pixels=0 会误命中顶部分页阈值，prepend 后内容整体偏
                  // 移，最终用户看到的不是目标消息（表现：跳 #500 落 #480）。
                  // 动画期间 NotificationListener 里的上下分页完全让路。
                  if (_programmaticScrollInProgress) return false;
                  // 只在"用户真正滚动"时触发分页：
                  //   - 手指/鼠标拖动时 userScrollDirection = forward/reverse；
                  //   - fling 惯性期间也保持为非 idle（Flutter 约定）；
                  //   - ensureVisible/animateTo/jumpTo 等程序化滚动期间保持 idle。
                  // 之前用单纯 `pixels<=20 / distanceToBottom<=20` 判定，程序化
                  // 滚动完成后 `_syncAfterMessageUpdate → _smartScrollToBottom`
                  // 等路径又会把 pixels 推到底，引发 loadNewerHistory 被级联
                  // 触发几十次（日志里表现：#521→#780 不停 append）。
                  if (_scrollController.position.userScrollDirection ==
                      ScrollDirection.idle) {
                    return false;
                  }
                  // 只看 ScrollUpdateNotification，start/end/user 三种不重复触发。
                  if (notification is! ScrollUpdateNotification) return false;
                  // 3s 节流：一次"连续滚动"内（手指贴边、释放后 fling 惯性依然
                  // 会发出 ScrollUpdate），避免 isLoading 翻转瞬间又命中阈值再
                  // 次触发分页。
                  final now = DateTime.now();
                  if (_lastPaginationTriggerAt != null &&
                      now.difference(_lastPaginationTriggerAt!) <
                          _paginationCooldown) {
                    return false;
                  }
                  final pixels = _scrollController.position.pixels;
                  final maxScroll = _scrollController.position.maxScrollExtent;
                  if (!usesChatPullToRefresh(context) &&
                      pixels <= 80 &&
                      _scrollController.position.userScrollDirection ==
                          ScrollDirection.forward &&
                      widget.hasMoreHistory &&
                      !widget.isLoadingHistory &&
                      _olderRequest == null) {
                    _lastPaginationTriggerAt = now;
                    unawaited(_loadOlder());
                    return false;
                  }
                  final distanceToBottom = maxScroll - pixels;
                  if (distanceToBottom <= 20 &&
                      widget.hasMoreNewer &&
                      !widget.isLoadingNewer &&
                      widget.onLoadNewerHistory != null) {
                    // append 前记 anchor = 当前末条，alignment=0.0 → 加载完
                    // 成后把原末条"推到视口顶部"，新消息从它下方延伸。
                    final anchor = _lastRowUuid();
                    if (anchor != null) {
                      _pendingAnchorUuid = anchor;
                      _pendingAnchorAlignment = 0.0;
                    }
                    _lastPaginationTriggerAt = now;
                    widget.onLoadNewerHistory!();
                  }
                  return false;
                },
                child: Builder(
                  builder: (context) {
                    final scrollBody = ChatMessageScrollbar(
                      controller: _scrollController,
                      bottomObstruction: widget.bottomContentInset,
                      child: SizedBox.expand(
                        child: ChatHistoryRefresh(
                            key: ValueKey(widget.activeConversationId),
                            scrollController: _scrollController,
                            hasMore: widget.hasMoreHistory,
                            onLoadOlder: _loadOlder,
                            child: CustomScrollView(
                              controller: _scrollController,
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                SliverToBoxAdapter(
                                    child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    horizontalPadding,
                                    16,
                                    horizontalPadding,
                                    widget.bottomContentInset,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: _buildMessageChildren(items),
                                  ),
                                ))
                              ],
                            )),
                      ),
                    );
                    if (widget.onMobileBackgroundInteraction != null) {
                      return ClickScrollDetectorWidget(
                        onClick: widget.onMobileBackgroundInteraction,
                        onScroll: widget.onMobileBackgroundInteraction,
                        child: scrollBody,
                      );
                    }
                    return scrollBody;
                  },
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16 + widget.bottomContentInset,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  reverseDuration: const Duration(milliseconds: 800),
                  switchInCurve: Curves.easeOutBack,
                  switchOutCurve: Curves.easeInBack,
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: FadeTransition(
                        opacity: animation,
                        child: child,
                      ),
                    );
                  },
                  child: _showScrollToBottomButton
                      ? Material(
                          key: const ValueKey('scroll_button_visible'),
                          color: Colors.transparent,
                          elevation: 0,
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            onTap: () {
                              // around 中段模式（下方还有一堆没加载的更新消息）：
                              // 不走 scrollToBottom 让用户一路触发 loadNewerHistory
                              // 分页拉几千条，直接让上层 jumpToLatest 重置到首屏
                              // 最新；didUpdateWidget 侦测到 hasMoreNewer 由 true→false
                              // 会安排一次强制跳底。
                              if (widget.hasMoreNewer &&
                                  widget.onJumpToLatest != null) {
                                widget.onJumpToLatest!();
                              } else {
                                scrollToBottom(animated: true);
                              }
                              widget.onScrolledToBottom?.call();
                            },
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.grey.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                CupertinoIcons.down_arrow,
                                color: Colors.black87,
                                size: 22,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('scroll_button_hidden'),
                          width: 36,
                          height: 36,
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChatMessageAnchor extends StatefulWidget {
  const _ChatMessageAnchor({
    super.key,
    required this.uuids,
    required this.onRegister,
    required this.onUnregister,
    required this.child,
  });

  final List<String> uuids;
  final void Function(String uuid, BuildContext context) onRegister;
  final void Function(String uuid, BuildContext context) onUnregister;
  final Widget child;

  @override
  State<_ChatMessageAnchor> createState() => _ChatMessageAnchorState();
}

class _ChatMessageAnchorState extends State<_ChatMessageAnchor> {
  @override
  void didUpdateWidget(covariant _ChatMessageAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final uuid in oldWidget.uuids) {
      if (!widget.uuids.contains(uuid)) {
        oldWidget.onUnregister(uuid, context);
      }
    }
  }

  @override
  void dispose() {
    for (final uuid in widget.uuids) {
      widget.onUnregister(uuid, context);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final uuid in widget.uuids) {
      widget.onRegister(uuid, context);
    }
    return widget.child;
  }
}
