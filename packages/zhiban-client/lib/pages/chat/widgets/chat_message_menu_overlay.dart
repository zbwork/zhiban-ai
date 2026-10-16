import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

/// 飞书风轻量菜单的**纯视觉** overlay,与具体业务 action 解耦。
///
/// IM 人↔人 / 群聊消息菜单 (`ChatMessageAction` / `ImMessage` 规则) 与人↔agent
/// 本地菜单 (`ChatLocalMessageActionRegion`) 共用同一视觉:白底 / 6px 圆角 / 1px
/// 极浅描边 / 轻阴影 / 单项 32px / 13.5px 文字 / hover 浅灰 / 危险红。
///
/// 见 `docs/contracts/agent-bus-client-contract.md` §「消息操作菜单」。
class ChatMenuOverlayItem {
  const ChatMenuOverlayItem({
    required this.icon,
    required this.label,
    this.danger = false,
    this.separatedBefore = false,
  });

  final IconData icon;
  final String label;

  /// 危险操作 (如删除) 用红色文字 / 图标。
  final bool danger;

  /// 该项前展示一条轻分隔线,用于企微式菜单分组。
  final bool separatedBefore;
}

// 全局同一时刻只允许一个该菜单打开:再次打开自动关旧 (IM + agent 共用),
// 避免在另一条消息上右键时旧菜单残留。
Object? _activeMenuToken;
VoidCallback? _dismissOpenMenu;

/// 在 [globalPosition] 弹出飞书风菜单,返回被选中项的索引;点击外部取消返回 null。
///
/// `items` 为空时不弹 (返回 null)。
///
/// 直接往 `Overlay.of(context, rootOverlay: true)` 塞 `OverlayEntry`,不走
/// `showGeneralDialog`/`Navigator.push`——后者会插入一个新 Route,Route 激活时
/// Flutter 会把下面 Route 里的 `SelectableRegion` 焦点收走,连带触发它内部
/// `_handleFocusChanged` → `clearSelection()`,导致刚选中的文字被清空。
/// `OverlayEntry` 不经过 Navigator/Route 机制,不会抢焦点。
///
/// [groupId] 传气泡自己 `TapRegion` 用的同一个 id(见
/// `ChatSelectionGestureMixin`)。[safeZone] 传气泡的全局矩形(已外扩):
/// 选区手柄画在 Overlay 里,不是气泡子树的一部分,手柄本身的可点区域可能落在
/// 气泡视觉边界外几十像素——只靠 groupId 分组覆盖不到"气泡范围外、菜单范围外
/// 的这一小圈",摸手柄第一下会被判成点击外部,菜单和选区一起被清掉。这里额外
/// 插一块跟菜单同 groupId、但不可见、范围是 safeZone 的 `TapRegion`,把这圈
/// 也划进"区域内"。
///
/// [visible] 由调用方(见 `ChatSelectionGestureMixin`)控制:拖手柄期间切成
/// `false` 暂时隐藏菜单卡片(不可见也不可点),松手后再切回 `true`——只是
/// UI 层面的显隐,不影响这个 Future 什么时候 resolve,不清选区、不重新弹菜单,
/// 全程是同一个 OverlayEntry。
Future<int?> showChatFeishuMenu({
  required BuildContext context,
  required Offset globalPosition,
  required List<ChatMenuOverlayItem> items,
  Object? groupId,
  Rect? safeZone,
  ValueListenable<bool>? visible,
}) async {
  if (items.isEmpty) return null;

  _dismissOpenMenu?.call();
  final token = Object();
  _activeMenuToken = token;
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<int?>();
  late final OverlayEntry entry;

  void close(int? result) {
    if (!identical(_activeMenuToken, token)) return;
    _activeMenuToken = null;
    _dismissOpenMenu = null;
    entry.remove();
    if (!completer.isCompleted) completer.complete(result);
  }

  _dismissOpenMenu = () => close(null);

  entry = OverlayEntry(
    builder: (overlayContext) {
      // 用 TapRegion(而不是全屏 opaque GestureDetector)判定"点击外部关闭":
      // 后者会整块吞掉指针事件,挡在选区手柄(也画在同一个 Overlay 里)上面,
      // 导致手柄收不到拖拽手势。TapRegion 只被动登记"完整的一次点击落在
      // 菜单区域外",不拦截 / 不消费指针事件,不会挡手柄——注意 TapRegion
      // 要直接包菜单卡片本身,不能包这层占满全屏的 Positioned.fill,否则
      // "区域内"会变成整个屏幕,onTapOutside 永远不触发。
      return Stack(
        children: [
          if (safeZone != null)
            Positioned.fromRect(
              rect: safeZone,
              // TapRegion 默认 HitTestBehavior.deferToChild——只有子树自己
              // "被命中"才算数,SizedBox.expand() 没有任何可绘制内容,本身不会
              // 响应命中测试,导致这块区域形同虚设(实测:手柄落点明明在
              // safeZone 矩形内,onTapOutside 还是照样触发)。必须显式传
              // behavior 让它自己的几何范围参与命中测试——但**不能传 opaque**:
              // opaque 会连带吞掉它背后(paint 顺序更早,即手柄所在的那个
              // Overlay 层)的指针事件,重新引入"手柄拖不动"那个已经修过的坑。
              // translucent 既会被记入命中路径(TapRegion 分组逻辑能生效),
              // 又不阻断事件继续派发给它背后的手柄。
              child: TapRegion(
                groupId: groupId,
                behavior: HitTestBehavior.translucent,
                child: const SizedBox.expand(),
              ),
            ),
          Positioned.fill(
            child: _ChatFeishuMenuRoute(
              anchor: globalPosition,
              items: items,
              onSelected: close,
              onTapOutside: () => close(null),
              groupId: groupId,
              visible: visible,
            ),
          ),
        ],
      );
    },
  );
  overlay.insert(entry);

  return completer.future;
}

/// 主动关闭当前打开的自研菜单(若有),按"点击外部"处理(resolve null)。
void dismissActiveChatFeishuMenu() => _dismissOpenMenu?.call();

class _ChatFeishuMenuRoute extends StatelessWidget {
  const _ChatFeishuMenuRoute({
    required this.anchor,
    required this.items,
    required this.onSelected,
    required this.onTapOutside,
    this.groupId,
    this.visible,
  });

  final Offset anchor;
  final List<ChatMenuOverlayItem> items;
  final ValueChanged<int> onSelected;
  final VoidCallback onTapOutside;
  final Object? groupId;
  final ValueListenable<bool>? visible;

  static const double _itemH = 44.0;
  static const double _padV = 6.0;
  static const double _menuW = 184.0;
  static const double _separatorH = 1.0;

  @override
  Widget build(BuildContext context) {
    final separatorCount = items.skip(1).where((i) => i.separatedBefore).length;
    final menuH =
        items.length * _itemH + _padV * 2 + separatorCount * _separatorH;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        double x;
        double y;
        if (PlatformUtils.isMobile) {
          // 移动端长按一般是选中一整段/整条消息,贴着长按点往右下偏一点很容易
          // 正好盖住刚选中的那行字。优先出现在长按点上方(留 12px 间隙,
          // iOS/微信式选区工具条的惯例),上方放不下(长按点靠近顶部)才落到下方。
          x = anchor.dx - _menuW / 2;
          y = anchor.dy - menuH - 12;
          if (y < 8) y = anchor.dy + 20;
        } else {
          // 桌面右键:菜单贴着鼠标点右下方弹出,符合系统右键菜单的习惯。
          x = anchor.dx + 6;
          y = anchor.dy + 6;
        }
        if (x + _menuW > maxW - 8) x = maxW - _menuW - 8;
        if (y + menuH > maxH - 8) y = maxH - menuH - 8;
        if (x < 8) x = 8;
        if (y < 8) y = 8;
        final menuCard = TapRegion(
          groupId: groupId,
          onTapOutside: (event) => onTapOutside(),
          child: _MenuCard(
            items: items,
            onSelected: onSelected
          ),
        );
        return Stack(
          children: [
            Positioned(
              left: x,
              top: y,
              width: _menuW,
              child: visible == null
                  ? menuCard
                  : ValueListenableBuilder<bool>(
                      valueListenable: visible!,
                      builder: (context, isVisible, child) {
                        return IgnorePointer(
                          ignoring: !isVisible,
                          child: AnimatedOpacity(
                            opacity: isVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: child,
                          ),
                        );
                      },
                      child: menuCard,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.items, required this.onSelected});
  final List<ChatMenuOverlayItem> items;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          // border: Border.all(color: const Color(0xFFDADDE3)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        // padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0xFFE8E8E8),
                ),
              _MenuItem(
                item: items[i],
                onTap: () => onSelected(i)
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({required this.item, required this.onTap});
  final ChatMenuOverlayItem item;
  final VoidCallback onTap;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hover = false;
  bool _pressed = false;

  Color get _bg {
    final danger = widget.item.danger;
    if (_pressed) {
      return danger ? const Color(0xFFFEE4E2) : const Color(0xFFEDEFF2);
    }
    if (_hover) {
      return danger ? const Color(0xFFFFF1F0) : const Color(0xFFF4F5F7);
    }
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final fg = item.danger ? const Color(0xFFE5484D) : const Color(0xFF111827);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          color: _bg,
          child: Row(
            children: [
              Icon(item.icon, size: 21, color: fg),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: fg,
                    height: 1.2,
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
