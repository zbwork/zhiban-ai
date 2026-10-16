import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

class SidebarNavItem extends ConsumerStatefulWidget {
  const SidebarNavItem({
    super.key,
    required this.iconAsset,
    required this.iconAssetSelected,
    required this.label,
    required this.path,
    this.badgeCount = 0,
    this.collapsed = false,
  });

  final String iconAsset;
  final String iconAssetSelected;
  final String label;
  final String path;
  final int badgeCount;
  final bool collapsed;

  @override
  ConsumerState<SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends ConsumerState<SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final isActive = location == widget.path;

    const activeBg = Color(0xFFEAF2FF);
    const activeFg = Color(0xFF165DFF);
    const idleFg = Color(0xFF344054);
    const hoverBg = Color(0x0F165DFF);

    final Color textColor = isActive ? activeFg : idleFg;
    final Color bgColor =
        isActive ? activeBg : (_hovered ? hoverBg : Colors.transparent);

    final content = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => context.go(widget.path),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: EdgeInsets.symmetric(
              horizontal: widget.collapsed ? 8 : 14, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: widget.collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              NavIconWithBadge(
                iconAsset:
                    isActive ? widget.iconAssetSelected : widget.iconAsset,
                count: widget.badgeCount,
              ),
              if (!widget.collapsed) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: isActive,
      label: widget.collapsed ? widget.label : null,
      child: widget.collapsed
          ? Tooltip(message: widget.label, child: content)
          : content,
    );
  }
}

class NavIconWithBadge extends StatelessWidget {
  const NavIconWithBadge({
    required this.iconAsset,
    required this.count,
    this.iconSize = 21,
    this.iconWidth,
    this.iconHeight,
    this.boxSize,
    this.usePackageAsset = true,
    super.key,
  });

  final String iconAsset;
  final int count;
  final double iconSize;
  final double? iconWidth;
  final double? iconHeight;
  final double? boxSize;
  final bool usePackageAsset;

  @override
  Widget build(BuildContext context) {
    final resolvedIconWidth = iconWidth ?? iconSize;
    final resolvedIconHeight = iconHeight ?? iconSize;
    final longestIconSide = resolvedIconWidth > resolvedIconHeight
        ? resolvedIconWidth
        : resolvedIconHeight;
    // 外层留 3px 余量给右上角徽标，跟原来桌面端 24/21 的比例保持一致。
    final resolvedBoxSize = boxSize ?? longestIconSide + 3;
    return SizedBox(
      width: resolvedBoxSize,
      height: resolvedBoxSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: SvgPicture.asset(
              package: usePackageAsset ? ClientAssets.packageName : null,
              iconAsset,
              width: resolvedIconWidth,
              height: resolvedIconHeight,
            ),
          ),
          if (count > 0)
            Positioned(
              top: -5,
              right: -8,
              child: NavUnreadBadge(count: count)
            ),
        ],
      ),
    );
  }
}

class NavUnreadBadge extends StatelessWidget {
  const NavUnreadBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
      padding: EdgeInsets.symmetric(horizontal: count >= 10 ? 4 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 1.2),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
