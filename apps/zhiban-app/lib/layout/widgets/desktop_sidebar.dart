import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/widgets/ui_sidebar_toggle_style.dart';

import 'package:zhiban_client/layout/models/main_nav_item.dart';
import 'sidebar_bottom_dock.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'sidebar_user_top.dart';

/// Only the desktop navigation owns collapse state; the workspace stays mounted.
class DesktopSidebar extends StatefulWidget {
  const DesktopSidebar({
    super.key,
    required this.navItems,
    this.chatUnreadCount = 0,
  });

  final List<MainNavItem> navItems;
  final int chatUnreadCount;

  @override
  State<DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends State<DesktopSidebar> {
  static const _sidebarAnimationDuration = Duration(milliseconds: 220);

  bool _collapsed = false;
  bool _contentCollapsed = false;
  int _transitionGeneration = 0;

  void _toggleSidebar() {
    final nextCollapsed = !_collapsed;
    final generation = ++_transitionGeneration;
    setState(() {
      _collapsed = nextCollapsed;
      if (nextCollapsed) _contentCollapsed = true;
    });
    if (nextCollapsed) return;

    Future<void>.delayed(_sidebarAnimationDuration, () {
      if (!mounted || generation != _transitionGeneration || _collapsed) {
        return;
      }
      setState(() => _contentCollapsed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sidebarWidth = _collapsed ? 64.0 : 180.0;
    final edgeSpace = _collapsed ? 12.0 : 0.0;
    return AnimatedContainer(
      width: sidebarWidth + edgeSpace,
      height: double.infinity,
      duration: _sidebarAnimationDuration,
      curve: Curves.easeOutCubic,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _buildNavigation(),
            ),
            Positioned(
              right: 0,
              top: constraints.maxHeight * 0.44 - 26,
              child: SidebarToggleButton(
                collapsed: _collapsed,
                onTap: _toggleSidebar,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    return AnimatedContainer(
      key: const ValueKey('desktop-sidebar'),
      width: _collapsed ? 64 : 180,
      height: double.infinity,
      duration: _sidebarAnimationDuration,
      curve: Curves.easeOutCubic,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7FBFF), Color(0xFFE8F2FF)],
        ),
        border: Border(
          right: BorderSide(color: Color(0xFFE6EEF8)),
        ),
      ),
      padding: const EdgeInsets.only(top: 34, bottom: 12),
      child: Column(
        children: [
          SidebarUserTop(collapsed: _contentCollapsed),
          const SizedBox(height: 18),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final item in widget.navItems)
                    SidebarNavItem(
                      key: ValueKey(item.path),
                      iconAsset: item.mobileIconAsset,
                      iconAssetSelected: item.mobileIconAssetSelected,
                      label: item.label,
                      path: item.path,
                      collapsed: _contentCollapsed,
                      badgeCount: item.path == RoutePaths.chat
                          ? widget.chatUnreadCount
                          : 0,
                    ),
                ],
              ),
            ),
          ),
          SidebarBottomDock(collapsed: _contentCollapsed),
        ],
      ),
    );
  }
}

/// Thin edge surface with a larger hit region and keyboard activation.
class SidebarToggleButton extends StatefulWidget {
  const SidebarToggleButton({
    super.key,
    required this.collapsed,
    required this.onTap,
  });

  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<SidebarToggleButton> createState() => _SidebarToggleButtonState();
}

class _SidebarToggleButtonState extends State<SidebarToggleButton> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.collapsed ? '展开菜单' : '收起菜单';
    final highlighted = _hovered || _focused || _pressed;
    return Semantics(
      button: true,
      label: label,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onTap: widget.onTap,
              child: SizedBox(
                width: 20,
                height: 52,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedScale(
                    key: const ValueKey('sidebar-toggle-press-scale'),
                    scale: _pressed ? 0.96 : 1,
                    duration: const Duration(milliseconds: 80),
                    curve: Curves.easeOut,
                    child: Container(
                      key: const ValueKey('sidebar-toggle-surface'),
                      width: 12,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: UiSidebarToggleStyle.fill(scheme,
                            highlighted: highlighted),
                        borderRadius: widget.collapsed
                            ? const BorderRadius.horizontal(
                                right: Radius.circular(6))
                            : const BorderRadius.horizontal(
                                left: Radius.circular(6)),
                      ),
                      child: AnimatedSlide(
                        offset: highlighted
                            ? Offset(widget.collapsed ? 0.125 : -0.125, 0)
                            : Offset.zero,
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          child: SvgPicture.asset(
                            package: ClientAssets.packageName,
                            widget.collapsed
                                ? 'assets/images/main_layout/sidebar_expand.svg'
                                : 'assets/images/main_layout/sidebar_collapse.svg',
                            key: ValueKey(widget.collapsed),
                            width: 8,
                            height: 12,
                            colorFilter: ColorFilter.mode(
                              UiSidebarToggleStyle.foreground(scheme,
                                  highlighted: highlighted),
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
