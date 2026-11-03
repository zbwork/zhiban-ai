import 'package:flutter/material.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_panel.dart';

/// The conversation keeps the same constraints while the preview is expanded.
class AttachmentPreviewHost extends StatefulWidget {
  const AttachmentPreviewHost(
      {super.key,
      required this.child,
      required this.sessionKey,
      this.onVisibilityChanged});
  final Widget child;
  final String sessionKey;
  final ValueChanged<bool>? onVisibilityChanged;
  @override
  State<AttachmentPreviewHost> createState() => _AttachmentPreviewHostState();
}

class _AttachmentPreviewHostState extends State<AttachmentPreviewHost> {
  AttachmentPreviewTarget? _target;
  bool _expanded = false;
  double _fraction = .48;
  @override
  void didUpdateWidget(AttachmentPreviewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionKey != widget.sessionKey) {
      _target = null;
      _expanded = false;
      widget.onVisibilityChanged?.call(false);
    }
  }

  void _close() {
    setState(() {
      _target = null;
      _expanded = false;
    });
    widget.onVisibilityChanged?.call(false);
  }

  @override
  void dispose() {
    widget.onVisibilityChanged?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AttachmentPreviewScope(
      selectedUrl: _target?.url,
      open: (target) {
        final wasOpen = _target != null;
        setState(() => _target = target);
        if (!wasOpen) widget.onVisibilityChanged?.call(true);
      },
      child: LayoutBuilder(builder: (context, box) {
        final target = _target;
        final split = box.maxWidth >= 720;
        final width = split
            ? (box.maxWidth * _fraction).clamp(320.0, box.maxWidth - 400)
            : box.maxWidth;
        return Stack(children: [
          Positioned.fill(
            child: Row(children: [
              Expanded(child: widget.child),
              // Keep this reservation underneath the expanded preview.
              if (target != null && split) SizedBox(width: width),
            ]),
          ),
          if (target != null)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: _expanded ? box.maxWidth : width,
              child: AttachmentPreviewPanel(
                target: target,
                expanded: _expanded,
                onClose: _close,
                onExpand: () => setState(() => _expanded = !_expanded),
              ),
            ),
          if (target != null && split && !_expanded)
            Positioned(
              top: 0,
              bottom: 0,
              right: width - 4,
              width: 8,
              child: _PreviewDivider(
                  onDrag: (delta) => setState(() {
                        _fraction =
                            (width - delta).clamp(320.0, box.maxWidth - 400) /
                                box.maxWidth;
                      })),
            ),
        ]);
      }));
}

class _PreviewDivider extends StatefulWidget {
  const _PreviewDivider({required this.onDrag});
  final ValueChanged<double> onDrag;
  @override
  State<_PreviewDivider> createState() => _PreviewDividerState();
}

class _PreviewDividerState extends State<_PreviewDivider> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: const ValueKey('attachment-preview-divider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: Center(
            child: Container(
                width: 1,
                color: _hover
                    ? colors.primary.withValues(alpha: .3)
                    : colors.outlineVariant.withValues(alpha: .3))),
      ),
    );
  }
}
