import 'package:zhiban_client/network/user_refresh.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

bool usesChatPullToRefresh(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.android;
}

double chatLatestScrollOffset(ScrollPosition position) =>
    position.axisDirection == AxisDirection.up
        ? position.minScrollExtent
        : position.maxScrollExtent;

/// An anchored, chronological timeline: older pages grow toward the visual top and
/// new messages toward the bottom. Neither insertion shifts existing rows.
class ChatHistoryList extends StatefulWidget {
  const ChatHistoryList(
      {super.key,
      required this.scrollController,
      required this.hasMore,
      required this.onLoadOlder,
      required this.itemIds,
      required this.itemBuilder,
      required this.padding});

  final ScrollController scrollController;
  final bool hasMore;
  final FutureOr<void> Function() onLoadOlder;
  final List<String> itemIds;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;

  @override
  State<ChatHistoryList> createState() => _ChatHistoryListState();
}

class _ChatHistoryListState extends State<ChatHistoryList> {
  final _centerKey = UniqueKey();
  String? _centerId;
  final _rowKeys = <String, GlobalKey>{};
  int _anchorRequest = 0;

  @override
  void didUpdateWidget(covariant ChatHistoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final request = ++_anchorRequest;
    if (!usesChatPullToRefresh(context) ||
        oldWidget.itemIds.isEmpty ||
        widget.itemIds.indexOf(oldWidget.itemIds.first) <= 0 ||
        !widget.scrollController.hasClients) {
      return;
    }
    final viewport = context.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) {
      return;
    }
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    for (final id in oldWidget.itemIds) {
      final box =
          _rowKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        continue;
      }
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height <= top || y >= bottom) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            request != _anchorRequest ||
            !widget.scrollController.hasClients) {
          return;
        }
        final current =
            _rowKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
        if (current == null || !current.hasSize) return;
        final position = widget.scrollController.position;
        final delta = current.localToGlobal(Offset.zero).dy - y;
        if (delta.abs() > 0.5) {
          widget.scrollController.jumpTo((position.pixels + delta)
              .clamp(position.minScrollExtent, position.maxScrollExtent));
        }
      });
      break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.itemIds;
    final mobile = usesChatPullToRefresh(context);
    if (!ids.contains(_centerId)) {
      _centerId = ids.firstOrNull;
    }
    final center = _centerId == null ? 0 : ids.indexOf(_centerId!);
    final currentIds = ids.toSet();
    _rowKeys.removeWhere((id, _) => !currentIds.contains(id));
    Widget row(BuildContext context, int index) => KeyedSubtree(
        key: ValueKey(ids[index]),
        child: KeyedSubtree(
            key: _rowKeys.putIfAbsent(ids[index], GlobalKey.new),
            child: widget.itemBuilder(context, index)));
    return ChatHistoryRefresh(
        scrollController: widget.scrollController,
        hasMore: widget.hasMore,
        onLoadOlder: widget.onLoadOlder,
        child: CustomScrollView(
            controller: widget.scrollController,
            center: mobile ? null : _centerKey,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: mobile
                ? [
                    SliverToBoxAdapter(
                        child: Padding(
                            padding: widget.padding,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: List.generate(ids.length,
                                    (index) => row(context, index))))),
                  ]
                : [
                    SliverPadding(
                        padding: EdgeInsets.only(
                            left: widget.padding.left,
                            right: widget.padding.right,
                            top: center > 0 ? widget.padding.top : 0),
                        sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                                (context, i) => row(context, center - i - 1),
                                childCount: center,
                                findChildIndexCallback: (key) {
                          final index =
                              ids.indexOf((key as ValueKey<String>).value);
                          return index < 0 || index >= center
                              ? null
                              : center - index - 1;
                        }))),
                    SliverPadding(
                        key: _centerKey,
                        padding: EdgeInsets.only(
                            left: widget.padding.left,
                            right: widget.padding.right,
                            top: widget.padding.top,
                            bottom: widget.padding.bottom),
                        sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                                (context, i) => row(context, center + i),
                                childCount: ids.length - center,
                                findChildIndexCallback: (key) {
                          final index =
                              ids.indexOf((key as ValueKey<String>).value);
                          return index < center ? null : index - center;
                        }))),
                  ]));
  }
}

/// An explicit entry/send scroll keeps following layout estimates until the
/// lazy list settles. A user gesture cancels the request immediately.
class ChatBottomScrollController extends ScrollController {
  int _request = 0;
  bool _disposed = false;

  void cancelScrollToLatest() => _request++;

  void scrollToLatest({bool animated = false}) {
    if (_disposed) return;
    unawaited(_align(++_request, animated));
  }

  Future<void> _align(int request, bool animated) async {
    var stableFrames = 0;
    for (var frame = 0; frame < 24; frame++) {
      await SchedulerBinding.instance.endOfFrame;
      if (_disposed || request != _request) return;
      if (!hasClients || !position.hasContentDimensions) continue;
      final target = chatLatestScrollOffset(position);
      final distance = target - position.pixels;
      if (distance.abs() <= 0.5) {
        if (++stableFrames == 2) return;
        continue;
      }
      stableFrames = 0;
      if (animated) {
        animated = false;
        await animateTo(target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic);
      } else {
        jumpTo(target);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancelScrollToLatest();
    super.dispose();
  }
}

/// Mobile history pagination uses the same refresh physics as other app lists.
/// Desktop panes retain their wheel/trackpad edge-loading interaction.
class ChatHistoryRefresh extends StatefulWidget {
  const ChatHistoryRefresh({
    super.key,
    required this.scrollController,
    required this.hasMore,
    required this.onLoadOlder,
    required this.child,
  });

  final ScrollController scrollController;
  final bool hasMore;
  final FutureOr<void> Function() onLoadOlder;
  final ScrollView child;

  @override
  State<ChatHistoryRefresh> createState() => _ChatHistoryRefreshState();
}

class _ChatHistoryRefreshState extends State<ChatHistoryRefresh> {
  final _refresh = RefreshController();

  Future<void> _load() async {
    try {
      await widget.onLoadOlder();
      if (mounted) {
        if (widget.child.reverse) {
          _refresh.loadComplete();
        } else {
          _refresh.refreshCompleted();
        }
      }
    } catch (_) {
      if (mounted) {
        if (widget.child.reverse) {
          _refresh.loadFailed();
        } else {
          _refresh.refreshFailed();
        }
      }
    }
  }

  @override
  void dispose() {
    _refresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SmartRefresher rebuilds the scroll view, so handle keyboard dismissal
    // outside it rather than relying on the child's keyboardDismissBehavior.
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0 ||
            notification.metrics.axis != Axis.vertical ||
            notification.direction == ScrollDirection.idle) {
          return false;
        }
        // A drag start alone can also occur on a tap; require actual movement.
        FocusScope.of(context).unfocus();
        return false;
      },
      child: _buildScrollView(context),
    );
  }

  Widget _buildScrollView(BuildContext context) {
    if (!usesChatPullToRefresh(context)) {
      return widget.child;
    }
    return RefreshConfiguration(
      springDescription: const SpringDescription(
          mass: 1, stiffness: 364.718677686, damping: 35.2),
      enableBallisticLoad: false,
      child: SmartRefresher(
        controller: _refresh,
        scrollController: widget.scrollController,
        enablePullDown: !widget.child.reverse && widget.hasMore,
        enablePullUp: widget.child.reverse && widget.hasMore,
        onLoading: _load,
        footer: const ClassicFooter(
          idleText: '下拉加载更早消息',
          canLoadingText: '释放加载更早消息',
          loadingText: '正在加载…',
          noDataText: '没有更早消息了',
          failedText: '加载失败，请重试',
          loadingIcon: CupertinoActivityIndicator(radius: 8),
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        onRefresh: () => UserRefresh.run(_load),
        header: const ClassicHeader(
          idleText: '下拉加载更早消息',
          releaseText: '释放加载更早消息',
          refreshingText: '正在加载…',
          completeText: '加载完成',
          failedText: '加载失败，请重试',
          refreshingIcon: CupertinoActivityIndicator(radius: 8),
        ),
        child: widget.child,
      ),
    );
  }
}

const double streamFollowLerpFactor = 0.15;
const double streamFollowStopEpsilon = 0.5;

/// 行级步进跟滚：漂移小于约一行高度时完全静止（连续慢速漂移会产生
/// 视觉残留感），攒够一行再用更快的插值一小段追平。
const double streamFollowStepThreshold = 24;
const double streamFollowCatchUpFactor = 0.3;

double nextStreamFollowOffset({
  required double current,
  required double target,
  double factor = streamFollowLerpFactor,
  double epsilon = streamFollowStopEpsilon,
}) {
  final difference = target - current;
  if (difference.abs() <= epsilon) return target;
  return current + difference * factor;
}

/// 桌面端聊天消息区滚动条。
///
/// 显式与消息列表共用 [controller]，保证滑块可拖拽、轨道可点击；空闲时
/// 自动淡出。数字员工聊天的输入区覆盖在消息视口上方，因此通过
/// [bottomObstruction] 把滚动条绘制范围收在输入区上方，避免滑块被遮挡。
class ChatMessageScrollbar extends StatelessWidget {
  const ChatMessageScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.bottomObstruction = 0,
  });

  final ScrollController controller;
  final Widget child;
  final double bottomObstruction;

  static const double _edgeInset = 4;
  static const double _minThumbLength = 40;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUtils.isDesktop) return child;

    final theme = Theme.of(context);
    final scrollbarTheme = theme.scrollbarTheme;
    final thumbColor = scrollbarTheme.thumbColor?.resolve(
          const <WidgetState>{}
        ) ??
        theme.colorScheme.onSurface.withValues(alpha: 0.42);
    final thickness = scrollbarTheme.thickness?.resolve(
          const <WidgetState>{}
        ) ??
        6;
    final radius = scrollbarTheme.radius ?? const Radius.circular(999);
    final safeBottom = bottomObstruction.clamp(0.0, double.infinity);

    // Flutter 会在桌面端通过 ScrollBehavior 自动包一层 RawScrollbar。
    // 本组件已经显式提供可交互滚动条，需关闭子树自动装饰以避免双滑块。
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: RawScrollbar(
        controller: controller,
        thumbVisibility: false,
        trackVisibility: false,
        interactive: true,
        thumbColor: thumbColor,
        thickness: thickness,
        radius: radius,
        minThumbLength: _minThumbLength,
        crossAxisMargin: _edgeInset,
        padding: EdgeInsets.only(
          top: _edgeInset,
          bottom: safeBottom + _edgeInset,
        ),
        child: child,
      ),
    );
  }
}

class BottomAwareScrollController extends ScrollController {
  BottomAwareScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return BottomAwareScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }

  void retainDistanceFromBottom() {
    if (!hasClients) return;
    position.retainDistance();
  }

  @override
  BottomAwareScrollPosition get position =>
      super.position as BottomAwareScrollPosition;
}

class BottomAwareScrollPosition extends ScrollPositionWithSingleContext {
  BottomAwareScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels = 0.0,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  double? _oldPixels;
  double? _oldMaxScrollExtent;

  bool get shouldRestore => _oldMaxScrollExtent != null && _oldPixels != null;

  void retainDistance() {
    if (!hasPixels) return;
    _oldPixels = pixels;
    _oldMaxScrollExtent = maxScrollExtent;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (shouldRestore) {
      final oldBottomDist = _oldMaxScrollExtent! - _oldPixels!;
      final newPixels = maxScrollExtent - oldBottomDist;
      if (newPixels >= minScrollExtent && newPixels <= maxScrollExtent) {
        correctPixels(newPixels);
      }
      _oldPixels = null;
      _oldMaxScrollExtent = null;
    }
    return applied;
  }
}

/// 检测点击与滚动，避免把滚动误判成点击。
class ClickScrollDetectorWidget extends StatefulWidget {
  const ClickScrollDetectorWidget({
    super.key,
    required this.child,
    this.onClick,
    this.onScroll,
    this.clickThreshold = 5.0,
    this.clickMaxDuration = 200,
  });

  final Widget child;
  final VoidCallback? onClick;
  final VoidCallback? onScroll;
  final double clickThreshold;
  final int clickMaxDuration;

  @override
  State<ClickScrollDetectorWidget> createState() =>
      _ClickScrollDetectorWidgetState();
}

class _ClickScrollDetectorWidgetState extends State<ClickScrollDetectorWidget> {
  late final ClickScrollDetector _detector;

  @override
  void initState() {
    super.initState();
    _detector = ClickScrollDetector(
      onClick: widget.onClick,
      clickThreshold: widget.clickThreshold,
      clickMaxDuration: widget.clickMaxDuration,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final wasScrolling = _detector.isScrolling;
    _detector.onPointerMove(event);
    if (!wasScrolling && _detector.isScrolling) {
      widget.onScroll?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _detector.onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _detector.onPointerUp,
      onPointerCancel: _detector.onPointerCancel,
      child: widget.child,
    );
  }
}

class ClickScrollDetector {
  ClickScrollDetector({
    this.onClick,
    this.clickThreshold = 5.0,
    this.clickMaxDuration = 200,
  });

  final VoidCallback? onClick;
  final double clickThreshold;
  final int clickMaxDuration;

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;
  bool _isScrolling = false;

  bool get isScrolling => _isScrolling;

  void onPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
    _isScrolling = false;
  }

  void onPointerMove(PointerMoveEvent event) {
    if (_pointerDownPosition == null) return;
    final distance = (_pointerDownPosition! - event.position).distance;
    if (distance > clickThreshold) {
      _isScrolling = true;
    }
  }

  void onPointerUp(PointerUpEvent event) {
    final duration = _pointerDownTime == null
        ? 0
        : DateTime.now().difference(_pointerDownTime!).inMilliseconds;
    final moveDistance = _pointerDownPosition == null
        ? 0.0
        : (_pointerDownPosition! - event.position).distance;

    final isClick = !_isScrolling &&
        _pointerDownPosition != null &&
        _pointerDownTime != null &&
        duration < clickMaxDuration &&
        moveDistance <= clickThreshold;
    if (isClick) {
      onClick?.call();
    }
    _reset();
  }

  void onPointerCancel(PointerCancelEvent event) {
    _reset();
  }

  void _reset() {
    _pointerDownPosition = null;
    _pointerDownTime = null;
    _isScrolling = false;
  }
}
