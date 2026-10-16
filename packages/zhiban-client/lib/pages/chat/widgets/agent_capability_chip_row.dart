import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'chat_theme.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'compact_capability_icon.dart';

const int _maxInlineCapabilities = 3;
const double _popoverMinWidth = 236;
const double _popoverMaxWidth = 420;
const double _popoverHorizontalMargin = 16;
const TextStyle _popoverItemTextStyle = TextStyle(
  fontSize: 14,
  height: 1.2,
  color: Color(0xFF101828),
  fontWeight: FontWeight.w500,
);

class AgentCapabilityChipRow extends StatelessWidget {
  const AgentCapabilityChipRow({
    super.key,
    required this.skills,
    required this.apps,
    this.supportsSkillBindings = true,
    this.leading,
    this.onAddSkill,
    this.onSelectSkill,
    this.onSelectApp,
    this.launchingAppId,
    this.appLaunchLocked = false,
  });

  /// Optional first action, sharing the existing horizontal scroll area.
  final Widget? leading;
  final List<AgentSkillItem> skills;
  final List<AgentAppItem> apps;
  final bool supportsSkillBindings;
  final VoidCallback? onAddSkill;
  final ValueChanged<AgentSkillItem>? onSelectSkill;
  final ValueChanged<AgentAppItem>? onSelectApp;
  final String? launchingAppId;
  final bool appLaunchLocked;

  @override
  Widget build(BuildContext context) {
    final skillItems = skills
        .map((s) {
          final label =
              s.skillName.trim().isEmpty ? s.slug : s.skillName.trim();
          return _CapabilityItem(
            label: label,
            iconUrl: s.iconUrl,
            fallbackIcon: CupertinoIcons.sparkles,
            onTap: onSelectSkill == null ? null : () => onSelectSkill!(s),
          );
        })
        .where((item) => item.label.isNotEmpty)
        .toList(growable: false);
    final appItems = apps
        .map((a) {
          final label = a.name.trim().isEmpty ? a.slug : a.name.trim();
          final isLaunching = launchingAppId == a.id;
          return _CapabilityItem(
            label: label,
            iconUrl: a.iconUrl,
            fallbackIcon: CupertinoIcons.square_grid_2x2,
            isLoading: isLaunching,
            onTap: onSelectApp == null || appLaunchLocked
                ? null
                : () => onSelectApp!(a),
          );
        })
        .where((item) => item.label.isNotEmpty)
        .toList(growable: false);

    if (leading == null &&
        skillItems.isEmpty &&
        appItems.isEmpty &&
        !supportsSkillBindings) {
      return const SizedBox.shrink();
    }

    final hPad = PlatformUtils.isMobile ? 12.0 : 24.0;
    return Container(
      color: ChatTheme.pageBg,
      padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 4),
      child: SizedBox(
        height: 28,
        child: ListView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          children: [
            if (leading != null) ...[
              Center(child: leading!),
              const SizedBox(width: 8),
            ],
            _CapabilitySegment(
              moreLabel: '更多技能',
              items: skillItems,
              moreEnabled: supportsSkillBindings,
              alwaysShowMore: supportsSkillBindings,
              popoverItems: skillItems,
              openOnHover: true,
              onAdd: onAddSkill,
            ),
            if ((skillItems.isNotEmpty || supportsSkillBindings) &&
                appItems.isNotEmpty)
              const _CapabilityDivider(),
            _CapabilitySegment(
              moreLabel: '更多应用',
              items: appItems
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilitySegment extends StatelessWidget {
  const _CapabilitySegment({
    required this.moreLabel,
    required this.items,
    this.moreEnabled = true,
    this.alwaysShowMore = false,
    this.popoverItems,
    this.openOnHover = false,
    this.onAdd,
  });

  final String moreLabel;
  final List<_CapabilityItem> items;
  final bool moreEnabled;
  final bool alwaysShowMore;
  final List<_CapabilityItem>? popoverItems;
  final bool openOnHover;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final visibleItems =
        moreEnabled ? items.take(_maxInlineCapabilities).toList() : items;
    final hiddenItems = moreEnabled
        ? items.skip(_maxInlineCapabilities).toList()
        : const <_CapabilityItem>[];
    final hasMore = moreEnabled && (alwaysShowMore || hiddenItems.isNotEmpty);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < visibleItems.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _CapabilityChip(
            item: visibleItems[i],
            onTap: visibleItems[i].onTap
          ),
        ],
        if (hasMore) ...[
          if (visibleItems.isNotEmpty) const SizedBox(width: 8),
          _MoreCapabilityChip(
            label: moreLabel,
            items: popoverItems ?? hiddenItems,
            openOnHover: openOnHover,
            onAdd: onAdd,
          ),
        ],
      ],
    );
  }
}

class _CapabilityDivider extends StatelessWidget {
  const _CapabilityDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10),
      child: SizedBox(
        width: 1,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Color(0xFFE2E8F0)),
        ),
      ),
    );
  }
}

class _MoreCapabilityChip extends StatefulWidget {
  const _MoreCapabilityChip({
    required this.label,
    required this.items,
    required this.openOnHover,
    this.onAdd,
  });

  final String label;
  final List<_CapabilityItem> items;
  final bool openOnHover;
  final VoidCallback? onAdd;

  @override
  State<_MoreCapabilityChip> createState() => _MoreCapabilityChipState();
}

class _MoreCapabilityChipState extends State<_MoreCapabilityChip> {
  OverlayEntry? _entry;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hide();
    super.dispose();
  }

  void _hide() {
    _hideTimer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 140), _hide);
  }

  void _cancelHide() => _hideTimer?.cancel();

  void _toggle() {
    if (_entry != null) {
      _hide();
      return;
    }

    _show();
  }

  void _show() {
    if (_entry != null) return;
    _hideTimer?.cancel();
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final anchorBox = context.findRenderObject() as RenderBox?;
    if (overlayBox == null || anchorBox == null || !anchorBox.hasSize) return;

    final anchorOffset =
        anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorRect = anchorOffset & anchorBox.size;
    final overlaySize = overlayBox.size;
    final popupWidth = _measurePopoverWidth(
      context,
      widget.items,
      overlaySize.width,
    );
    final itemHeight = widget.items.isEmpty ? 40 : widget.items.length * 40;
    final footerHeight = widget.onAdd == null ? 0 : 45;
    final popupHeight =
        (itemHeight + footerHeight + 16).clamp(56, 300).toDouble();
    final left = anchorRect.left.clamp(16.0,
        (overlaySize.width - popupWidth - 16).clamp(16.0, overlaySize.width));
    final top =
        (anchorRect.top - popupHeight - 8).clamp(12.0, overlaySize.height);

    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _hide,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: _CapabilityPopover(
              items: widget.items,
              onEnter: _cancelHide,
              onExit: _scheduleHide,
              onSelect: (item) {
                item.onTap?.call();
                _hide();
              },
              onAdd: widget.onAdd == null
                  ? null
                  : () {
                      final callback = widget.onAdd!;
                      _hide();
                      callback();
                    },
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
  }

  double _measurePopoverWidth(
    BuildContext context,
    List<_CapabilityItem> items,
    double overlayWidth,
  ) {
    var longest = 0.0;
    final scaler = MediaQuery.textScalerOf(context);
    for (final item in items) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: _popoverItemTextStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > longest) longest = painter.width;
    }
    const iconSlot = 24.0;
    const iconGap = 12.0;
    const horizontalPadding = 16.0;
    final desired = longest + iconSlot + iconGap + horizontalPadding;
    final maxByScreen =
        (overlayWidth - _popoverHorizontalMargin * 2).clamp(0.0, overlayWidth);
    if (maxByScreen <= _popoverMinWidth) return maxByScreen.toDouble();
    final maxWidth = maxByScreen < _popoverMaxWidth
        ? maxByScreen.toDouble()
        : _popoverMaxWidth;
    return desired.clamp(_popoverMinWidth, maxWidth).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: widget.openOnHover ? (_) => _show() : null,
      onExit: widget.openOnHover ? (_) => _scheduleHide() : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: _CapabilityChip(
          item: _CapabilityItem(
            label: widget.label,
            iconUrl: '',
            fallbackIcon: CupertinoIcons.chevron_up,
          ),
          onTap: null,
        ),
      ),
    );
  }
}

class _CapabilityPopover extends StatelessWidget {
  const _CapabilityPopover({
    required this.items,
    required this.onSelect,
    required this.onEnter,
    required this.onExit,
    this.onAdd,
  });

  final List<_CapabilityItem> items;
  final ValueChanged<_CapabilityItem> onSelect;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: const ValueKey('agent_capability_popover'),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD8E0EA)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.16),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: items.isEmpty
                      ? const SizedBox(
                          height: 28,
                          child: Center(
                            child: Text(
                              '暂无关联技能',
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFF98A2B3),
                              ),
                            ),
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final item in items)
                              _CapabilityMenuItem(
                                item: item,
                                onTap: () => onSelect(item),
                              ),
                          ],
                        ),
                ),
              ),
              if (onAdd != null) ...[
                const Divider(height: 1, color: Color(0xFFE4E7EC)),
                _AddSkillMenuItem(onTap: onAdd!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AddSkillMenuItem extends StatelessWidget {
  const _AddSkillMenuItem({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const SizedBox(
          height: 44,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(CupertinoIcons.add, size: 18, color: Color(0xFF475467)),
                SizedBox(width: 12),
                Text(
                  '添加技能',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF101828),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CapabilityMenuItem extends StatelessWidget {
  const _CapabilityMenuItem({required this.item, required this.onTap});

  final _CapabilityItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              _MenuIconSlot(item: item),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _popoverItemTextStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuIconSlot extends StatelessWidget {
  const _MenuIconSlot({required this.item});

  final _CapabilityItem item;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: _CapabilityIcon(
          item: item,
          size: 20,
          borderRadius: 5,
          fallback: _MenuFallbackIcon(item: item),
        ),
      ),
    );
  }
}

class _MenuFallbackIcon extends StatelessWidget {
  const _MenuFallbackIcon({required this.item});

  final _CapabilityItem item;

  @override
  Widget build(BuildContext context) {
    return Icon(
      item.fallbackIcon,
      size: 18,
      color: const Color(0xFF2F7DFF)
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.item, required this.onTap});

  final _CapabilityItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.label,
      child: MouseRegion(
        cursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 24,
            constraints: const BoxConstraints(maxWidth: 148),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.84),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFD8E0EA)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CapabilityIcon(
                  item: item,
                  size: 16,
                  borderRadius: 4,
                  fallback: _FallbackIcon(item: item),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: Color(0xFF344054),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CapabilityIcon extends StatelessWidget {
  const _CapabilityIcon({
    required this.item,
    required this.size,
    required this.borderRadius,
    required this.fallback,
  });

  final _CapabilityItem item;
  final double size;
  final double borderRadius;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    if (item.isLoading) {
      return SizedBox(
        key: ValueKey('capability_loading_${item.label}'),
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return CompactCapabilityIcon(
      iconUrl: item.iconUrl,
      size: size,
      borderRadius: borderRadius,
      fallback: fallback,
    );
  }
}

class _FallbackIcon extends StatelessWidget {
  const _FallbackIcon({required this.item});

  final _CapabilityItem item;

  @override
  Widget build(BuildContext context) {
    return Icon(
      item.fallbackIcon,
      size: 13,
      color: const Color(0xFF2F7DFF)
    );
  }
}

class _CapabilityItem {
  const _CapabilityItem({
    required this.label,
    required this.iconUrl,
    required this.fallbackIcon,
    this.onTap,
    this.isLoading = false,
  });

  final String label;
  final String iconUrl;
  final IconData fallbackIcon;
  final VoidCallback? onTap;
  final bool isLoading;
}
