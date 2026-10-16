import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';

import 'sidebar_update_state.dart';
export 'sidebar_update_state.dart';

/// 左下角「新版本发布了」更新卡片。仅在检测到有新版本时展示，不显示具体版本号；
/// 点击触发原生 updater（macOS Sparkle / Windows WinSparkle）下载安装并重启。
class SidebarUpdateIndicator extends StatefulWidget {
  const SidebarUpdateIndicator({
    super.key,
    required this.state,
    required this.onTap,
    this.collapsed = false,
    this.progress,
  });

  final bool collapsed;
  final SidebarUpdateState state;

  /// 点击回调；为 null 时卡片不可点。
  final VoidCallback? onTap;
  final double? progress;

  @override
  State<SidebarUpdateIndicator> createState() => _SidebarUpdateIndicatorState();
}

class _SidebarUpdateIndicatorState extends State<SidebarUpdateIndicator> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final downloading = widget.state == SidebarUpdateState.downloading ||
        widget.state == SidebarUpdateState.downloadingFull;
    final scheme = Theme.of(context).colorScheme;
    if (widget.collapsed) {
      return widget.state.isBusy
          ? Tooltip(
              message: widget.state.title,
              child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: widget.progress == null
                        ? const CupertinoActivityIndicator(radius: 9)
                        : Text(
                            '${(widget.progress! * 100).round()}%',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  )),
            )
          : UiIconButton(
              icon: CupertinoIcons.arrow_2_circlepath,
              size: 44,
              iconSize: 20,
              color: Theme.of(context).colorScheme.primary,
              tooltip:
                  '${widget.state.title} · ${widget.state.description ?? ''}',
              onTap: widget.onTap,
            );
    }
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          decoration: BoxDecoration(
            color: downloading
                ? scheme.surface.withValues(alpha: 0.8)
                : _hovered
                    ? Colors.white.withValues(alpha: 0.98)
                    : Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(downloading ? 10 : 12),
            border: Border.all(
              color: downloading
                  ? scheme.primary.withValues(alpha: 0.12)
                  : _hovered
                      ? const Color(0xFFC7DCFF)
                      : const Color(0xFFDDEBFF),
            ),
            boxShadow: downloading
                ? []
                : [
                    BoxShadow(
                      color: const Color(0xFF165DFF).withValues(alpha: 0.09),
                      blurRadius: 16,
                      offset: const Offset(0, 7),
                    ),
                  ],
          ),
          child: downloading
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.state.title,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (widget.progress != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${(widget.progress! * 100).round()}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: widget.progress,
                        minHeight: 3,
                        backgroundColor: scheme.primary.withValues(alpha: 0.1),
                        color: scheme.primary,
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFEAF3FF),
                            border: Border.all(color: const Color(0xFFCFE2FF)),
                          ),
                          child: const Icon(
                            CupertinoIcons.arrow_2_circlepath,
                            size: 12,
                            color: Color(0xFF165DFF),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.state.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF172033),
                                ),
                              ),
                              if (widget.state.isBusy &&
                                  widget.progress != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '${(widget.progress! * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF165DFF),
                                  ),
                                ),
                              ],
                              if (widget.state.description
                                  case final description?) ...[
                                const SizedBox(height: 4),
                                Text(
                                  description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.1,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF5D6B82),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (!widget.state.isBusy ||
                            widget.progress == null) ...[
                          const SizedBox(width: 4),
                          widget.state.isBusy
                              ? const CupertinoActivityIndicator(radius: 7)
                              : const Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 16,
                                  color: Color(0xFF6B86B8),
                                ),
                        ],
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
