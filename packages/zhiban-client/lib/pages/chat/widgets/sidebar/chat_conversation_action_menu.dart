import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';

/// F09 P2 「会话列表操作菜单 v2」 · 飞书风右键 / 长按菜单。
///
/// 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」。
///
/// 视觉:白底 / 8px 圆角内 / 轻阴影 / 14px 文字 / 图标 + 文字 / hover 浅灰 / 危险项红;
/// 6 个动作按 item state 切 toggle 文案,无能力的隐藏(目前所有 6 个 toggle 项普适),
/// 「修改群名」仅 group。**不**显示 disabled 占位。
enum ConversationMenuActionKind {
  togglePin,
  toggleMute,
  markRead,
  markUnread,
  hide,
  renameGroup,
}

class ConversationMenuAction {
  const ConversationMenuAction(
    this.kind, {
    required this.label,
    required this.icon,
    this.danger = false,
  });
  final ConversationMenuActionKind kind;
  final String label;
  final IconData icon;
  final bool danger;
}

/// 纯函数:某会话项基于自身 state **理论可执行**的菜单项 (顺序即菜单顺序)。
/// **不包含** callbacks 过滤;真正展示给用户的菜单走 `resolveConversationMenuActions`,
/// 它在本函数结果上按 `ConversationMenuCallbacks` 中非空回调过滤,避免出现可点击却 no-op
/// 的菜单项 (CR5)。
///
/// 顺序参照飞书:置顶 / 免打扰 / 已读 / 未读 / 修改群名 / 删除会话。
List<ConversationMenuAction> availableConversationActions(
    ConversationItem item) {
  final actions = <ConversationMenuAction>[
    ConversationMenuAction(
      ConversationMenuActionKind.togglePin,
      label: item.pinned ? '取消置顶' : '置顶',
      icon: Icons.push_pin_outlined,
    ),
    ConversationMenuAction(
      ConversationMenuActionKind.toggleMute,
      label: item.muted ? '取消免打扰' : '消息免打扰',
      icon: item.muted ? CupertinoIcons.bell : CupertinoIcons.bell_slash,
    ),
  ];
  // 「标为已读」仅在有红点(unread > 0 或 marked_unread)时才显示。
  if (item.hasUnreadDot) {
    actions.add(const ConversationMenuAction(
      ConversationMenuActionKind.markRead,
      label: '标为已读',
      icon: Icons.done_all_rounded,
    ));
  }
  // 「标为未读」仅在无红点时显示(已经未读就没必要再标)。
  if (!item.hasUnreadDot) {
    actions.add(const ConversationMenuAction(
      ConversationMenuActionKind.markUnread,
      label: '标为未读',
      icon: CupertinoIcons.circle,
    ));
  }
  if (item.isGroup && item.canRenameGroup) {
    actions.add(const ConversationMenuAction(
      ConversationMenuActionKind.renameGroup,
      label: '修改群名',
      icon: CupertinoIcons.pencil,
    ));
  }
  actions.add(const ConversationMenuAction(
    ConversationMenuActionKind.hide,
    label: '删除会话',
    icon: CupertinoIcons.eye_slash,
    danger: true,
  ));
  return actions;
}

/// 飞书风菜单回调集合。所有回调可选(空则该项不弹)。
class ConversationMenuCallbacks {
  const ConversationMenuCallbacks({
    this.onTogglePin,
    this.onToggleMute,
    this.onMarkRead,
    this.onMarkUnread,
    this.onHide,
    this.onRenameGroup,
  });
  final ValueChanged<ConversationItem>? onTogglePin;
  final ValueChanged<ConversationItem>? onToggleMute;
  final ValueChanged<ConversationItem>? onMarkRead;
  final ValueChanged<ConversationItem>? onMarkUnread;
  final ValueChanged<ConversationItem>? onHide;
  final ValueChanged<ConversationItem>? onRenameGroup;

  bool get isEmpty =>
      onTogglePin == null &&
      onToggleMute == null &&
      onMarkRead == null &&
      onMarkUnread == null &&
      onHide == null &&
      onRenameGroup == null;

  /// CR5: 某动作 kind 对应的回调是否已注入 (非空)。
  /// `showConversationActionMenu` / `ConversationActionRegion` 据此过滤菜单,
  /// 避免无回调却可点击产生 no-op。
  bool hasCallbackFor(ConversationMenuActionKind kind) {
    switch (kind) {
      case ConversationMenuActionKind.togglePin:
        return onTogglePin != null;
      case ConversationMenuActionKind.toggleMute:
        return onToggleMute != null;
      case ConversationMenuActionKind.markRead:
        return onMarkRead != null;
      case ConversationMenuActionKind.markUnread:
        return onMarkUnread != null;
      case ConversationMenuActionKind.hide:
        return onHide != null;
      case ConversationMenuActionKind.renameGroup:
        return onRenameGroup != null;
    }
  }
}

/// CR5: 在 `availableConversationActions(item)` 基础上, 进一步按 `callbacks` 过滤,
/// 只保留**回调真实注入**的动作。这是菜单实际展示用的列表。
/// 调用方:`showConversationActionMenu` 决定是否弹、`ConversationActionRegion` 决定是否拦截。
List<ConversationMenuAction> resolveConversationMenuActions(
  ConversationItem item,
  ConversationMenuCallbacks callbacks,
) {
  if (callbacks.isEmpty) return const <ConversationMenuAction>[];
  return [
    for (final a in availableConversationActions(item))
      if (callbacks.hasCallbackFor(a.kind)) a,
  ];
}

/// 在 [globalPosition] 弹出飞书风菜单。返回用户选中的动作 kind,或 null(用户点空白关闭)。
Future<void> showConversationActionMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ConversationItem item,
  required ConversationMenuCallbacks callbacks,
}) async {
  // CR5: 按 callbacks 过滤后再决定是否弹菜单, 杜绝无回调菜单项。
  final actions = resolveConversationMenuActions(item, callbacks);
  if (actions.isEmpty) return;
  final selected = await _showFeishuStyleMenu(
    context: context,
    globalPosition: globalPosition,
    actions: actions,
  );
  if (selected == null) return;
  switch (selected) {
    case ConversationMenuActionKind.togglePin:
      callbacks.onTogglePin?.call(item);
      break;
    case ConversationMenuActionKind.toggleMute:
      callbacks.onToggleMute?.call(item);
      break;
    case ConversationMenuActionKind.markRead:
      callbacks.onMarkRead?.call(item);
      break;
    case ConversationMenuActionKind.markUnread:
      callbacks.onMarkUnread?.call(item);
      break;
    case ConversationMenuActionKind.hide:
      callbacks.onHide?.call(item);
      break;
    case ConversationMenuActionKind.renameGroup:
      callbacks.onRenameGroup?.call(item);
      break;
  }
}

/// 飞书风菜单 overlay (避免 Material `showMenu` 的浪费 padding / 大圆角)。
///
/// 视觉:
///   - 容器 6px 圆角 / 白底 / 1px 极浅描边 / 轻阴影
///   - 单项高 32px / 横向 12px / 左 16x16 icon + 8px gap + 14px label
///   - hover #F5F5F7 / pressed #EBEBEF
///   - 危险项 label + icon 红 #E53935; hover #FEF2F2
Future<ConversationMenuActionKind?> _showFeishuStyleMenu({
  required BuildContext context,
  required Offset globalPosition,
  required List<ConversationMenuAction> actions,
}) async {
  final overlayState = Overlay.maybeOf(context);
  final overlay = overlayState?.context.findRenderObject() as RenderBox?;
  if (overlayState == null || overlay == null) return null;
  final size = overlay.size;
  // 估算: 单项 32, 顶 / 底各 4px padding.
  const itemH = 32.0;
  const padV = 4.0;
  const menuW = 168.0;
  final menuH = actions.length * itemH + padV * 2;
  final anchor = overlay.globalToLocal(globalPosition);
  double x = anchor.dx + 2;
  double y = anchor.dy + 2;
  if (x + menuW > size.width - 6) x = size.width - menuW - 6;
  if (y + menuH > size.height - 6) y = size.height - menuH - 6;
  if (x < 6) x = 6;
  if (y < 6) y = 6;

  final completer = Completer<ConversationMenuActionKind?>();
  late final OverlayEntry entry;
  late final Rect globalMenuRect;
  late final void Function(PointerEvent event) handlePointer;
  void close(ConversationMenuActionKind? action) {
    if (completer.isCompleted) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(handlePointer);
    if (entry.mounted) entry.remove();
    completer.complete(action);
  }

  handlePointer = (PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (globalMenuRect.contains(event.position)) return;
    close(null);
  };

  final menuTopLeft = overlay.localToGlobal(Offset(x, y));
  globalMenuRect = Rect.fromLTWH(menuTopLeft.dx, menuTopLeft.dy, menuW, menuH);
  GestureBinding.instance.pointerRouter.addGlobalRoute(handlePointer);

  entry = OverlayEntry(
    builder: (ctx) {
      return Stack(
        children: [
          Positioned(
            left: x,
            top: y,
            width: menuW,
            child: _MenuCard(actions: actions, onSelected: close),
          ),
        ],
      );
    },
  );
  overlayState.insert(entry);
  return completer.future;
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.actions, required this.onSelected});
  final List<ConversationMenuAction> actions;
  final ValueChanged<ConversationMenuActionKind> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFEAEAEA)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in actions)
              _MenuItem(action: a, onSelected: onSelected),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({required this.action, required this.onSelected});
  final ConversationMenuAction action;
  final ValueChanged<ConversationMenuActionKind> onSelected;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hover = false;
  bool _pressed = false;

  Color get _bg {
    if (_pressed) {
      return widget.action.danger
          ? const Color(0xFFFEE4E2)
          : const Color(0xFFEBEBEF);
    }
    if (_hover) {
      return widget.action.danger
          ? const Color(0xFFFEF2F2)
          : const Color(0xFFF5F5F7);
    }
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final dangerColor = const Color(0xFFE53935);
    final fg = widget.action.danger ? dangerColor : const Color(0xFF1D2129);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () => widget.onSelected(widget.action.kind),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: _bg,
          child: Row(
            children: [
              Icon(widget.action.icon, size: 15, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.action.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: fg,
                    height: 1.2
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 包裹桌面端会话列表项:右键(secondary tap)弹菜单。
/// **不**拦截左键(primary tap 仍由 [child] 处理进入会话)。
///
/// callbacks.isEmpty 或 actions 为空 → 透明返回 [child]。
class ConversationActionRegion extends StatelessWidget {
  const ConversationActionRegion({
    super.key,
    required this.child,
    required this.item,
    required this.callbacks,
    this.onMenuOpenChanged,
  });

  final Widget child;
  final ConversationItem item;
  final ConversationMenuCallbacks callbacks;
  final ValueChanged<bool>? onMenuOpenChanged;

  @override
  Widget build(BuildContext context) {
    // CR5: 按 callbacks 过滤后无动作 → region 透明返回 child, 不拦截右键。
    if (resolveConversationMenuActions(item, callbacks).isEmpty) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onSecondaryTapDown: (d) => _open(context, d.globalPosition),
      child: child,
    );
  }

  Future<void> _open(BuildContext context, Offset pos) async {
    onMenuOpenChanged?.call(true);
    await showConversationActionMenu(
      context: context,
      globalPosition: pos,
      item: item,
      callbacks: callbacks,
    );
    onMenuOpenChanged?.call(false);
  }
}

/// 移动端会话行左滑操作区。
///
/// 只承载「标为未读」和「删除」：完整的置顶 / 免打扰 / 标为已读 / 群改名
/// 菜单继续仅由桌面端 [ConversationActionRegion] 的右键入口提供。
class ConversationSwipeActionRegion extends StatefulWidget {
  const ConversationSwipeActionRegion({
    super.key,
    required this.child,
    required this.item,
    required this.callbacks,
  });

  final Widget child;
  final ConversationItem item;
  final ConversationMenuCallbacks callbacks;

  @override
  State<ConversationSwipeActionRegion> createState() =>
      _ConversationSwipeActionRegionState();
}

class _ConversationSwipeActionRegionState
    extends State<ConversationSwipeActionRegion> {
  static const double _actionWidth = 76;
  static const double _openVelocity = 300;
  static const Duration _settleDuration = Duration(milliseconds: 180);

  double _offset = 0;
  bool _dragging = false;

  bool get _canMarkUnread =>
      !widget.item.hasUnreadDot && widget.callbacks.onMarkUnread != null;
  bool get _canHide => widget.callbacks.onHide != null;
  int get _actionCount => (_canMarkUnread ? 1 : 0) + (_canHide ? 1 : 0);
  double get _maxReveal => _actionCount * _actionWidth;
  bool get _isOpen => _offset < -0.5;

  @override
  void didUpdateWidget(covariant ConversationSwipeActionRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    final conversationChanged =
        oldWidget.item.conversationId != widget.item.conversationId;
    final actionCountChanged =
        _actionCountFor(oldWidget) != _actionCountFor(widget);
    if (conversationChanged || actionCountChanged) _offset = 0;
  }

  int _actionCountFor(ConversationSwipeActionRegion target) {
    final canMarkUnread =
        !target.item.hasUnreadDot && target.callbacks.onMarkUnread != null;
    final canHide = target.callbacks.onHide != null;
    return (canMarkUnread ? 1 : 0) + (canHide ? 1 : 0);
  }

  void _handleDragStart(DragStartDetails _) {
    if (_actionCount == 0) return;
    setState(() => _dragging = true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_actionCount == 0) return;
    final delta = details.primaryDelta ?? 0;
    if (delta == 0) return;
    setState(() {
      _offset = (_offset + delta).clamp(-_maxReveal, 0).toDouble();
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (_actionCount == 0) return;
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen = velocity < -_openVelocity ||
        (velocity <= _openVelocity && _offset.abs() >= _maxReveal / 2);
    setState(() {
      _dragging = false;
      _offset = shouldOpen ? -_maxReveal : 0;
    });
  }

  void _close() {
    if (!_isOpen && !_dragging) return;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  void _run(ValueChanged<ConversationItem>? callback) {
    _close();
    callback?.call(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    if (_actionCount == 0) return widget.child;
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slideFraction =
            width.isFinite && width > 0 ? _offset / width : 0.0;
        return TapRegion(
          onTapOutside: (_) => _close(),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: _maxReveal,
                      child: Row(
                        children: [
                          if (_canMarkUnread)
                            _ConversationSwipeActionButton(
                              key: ValueKey(
                                'conversation-swipe-unread-'
                                '${widget.item.conversationId}',
                              ),
                              backgroundColor: Color.lerp(
                                scheme.primary,
                                scheme.surface,
                                0.12,
                              )!,
                              foregroundColor: scheme.onPrimary,
                              icon: Icons.mark_email_unread_outlined,
                              label: '标为未读',
                              onPressed: () =>
                                  _run(widget.callbacks.onMarkUnread),
                            ),
                          if (_canHide)
                            _ConversationSwipeActionButton(
                              key: ValueKey(
                                'conversation-swipe-delete-'
                                '${widget.item.conversationId}',
                              ),
                              backgroundColor: const Color(0xFFE40014),
                              foregroundColor: Colors.white,
                              icon: CupertinoIcons.delete,
                              label: '删除',
                              onPressed: () => _run(widget.callbacks.onHide),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                AnimatedSlide(
                  offset: Offset(slideFraction, 0),
                  duration: _dragging ? Duration.zero : _settleDuration,
                  curve: Curves.easeOutCubic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _isOpen ? _close : null,
                    // 抢占子会话项的 tap 手势，但移动端长按不执行任何动作。
                    onLongPress: () {},
                    onHorizontalDragStart: _handleDragStart,
                    onHorizontalDragUpdate: _handleDragUpdate,
                    onHorizontalDragEnd: _handleDragEnd,
                    onHorizontalDragCancel: _close,
                    child: AbsorbPointer(
                      absorbing: _isOpen,
                      child: widget.child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ConversationSwipeActionButton extends StatelessWidget {
  const _ConversationSwipeActionButton({
    super.key,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Color backgroundColor;
  final Color foregroundColor;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ConversationSwipeActionRegionState._actionWidth,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          shape: const RoundedRectangleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
