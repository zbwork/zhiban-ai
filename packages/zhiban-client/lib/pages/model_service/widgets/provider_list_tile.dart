import 'package:flutter/material.dart';

import 'add_provider_dialog.dart' show ProviderIcon;

class ProviderListTile extends StatefulWidget {
  const ProviderListTile({
    super.key,
    required this.name,
    required this.iconAssetPath,
    required this.enabled,
    required this.selected,
    required this.onTap,
    this.pressedFeedback = false,
    this.dragHandle,
  });

  final String name;
  final String? iconAssetPath;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;
  final bool pressedFeedback;

  /// 拖动排序手柄，只在列表处于"可拖动"状态（未搜索/未筛选）时由外层传入；
  /// 只有 hover 到这一行才显示，避免列表平时看起来很乱
  /// (2026-08-27 反馈：默认已启用放前面，用户可拖动改)。
  final Widget? dragHandle;

  @override
  State<ProviderListTile> createState() => _ProviderListTileState();
}

class _ProviderListTileState extends State<ProviderListTile> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    if (widget.pressedFeedback) _setPressed(true);
    widget.onTap();
    if (widget.pressedFeedback) {
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        _setPressed(false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = widget.selected
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.72)
        : widget.pressedFeedback && _pressed
            ? const Color(0xFFEFF4FF)
            : _hovered
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                : Colors.transparent;
    // 拖动手柄必须是 onTap 那个 GestureDetector 的兄弟节点、不能嵌在它内部
    // ——嵌在里面时手柄区域的指针事件要跟外层 TapGestureRecognizer 一起进
    // 手势竞技场，桌面端鼠标拖动偶发会被 tap 识别器抢先/搅局，表现为"拖起来
    // 跟手，松手却弹回原位"（2026-09-02 反馈：拖动排序有问题，隔离单测验证
    // 过 sortProviderRows/onReorder 的排序逻辑本身没问题，问题在手势层）。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Container(
          key: ValueKey('provider-list-tile-surface-${widget.name}'),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown:
                    widget.pressedFeedback ? (_) => _setPressed(true) : null,
                onTapCancel:
                    widget.pressedFeedback ? () => _setPressed(false) : null,
                onTap: _handleTap,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      widget.dragHandle != null ? 18 : 4, 5, 10, 5),
                  child: Row(
                    children: [
                      ProviderIcon(
                        iconAssetPath: widget.iconAssetPath,
                        name: widget.name,
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (widget.enabled)
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Color(0xFF12B76A),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.dragHandle != null)
                Positioned(
                  left: 4,
                  top: 0,
                  bottom: 0,
                  width: 12,
                  child: Center(
                    child: MouseRegion(
                      opaque: true,
                      hitTestBehavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: 12,
                        height: 16,
                        child: Opacity(
                          opacity: _hovered ? 1 : 0,
                          child: widget.dragHandle,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
