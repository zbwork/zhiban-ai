import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../file_attachment_icon.dart';
import 'attachment_preview_target.dart';

/// File identity and shared actions occupy one row in every preview format.
class AttachmentPreviewHeader extends StatelessWidget {
  const AttachmentPreviewHeader({
    super.key,
    required this.target,
    required this.onReload,
    required this.onDownload,
    required this.onClose,
    this.onExpand,
    this.expanded = false,
    this.byteLength,
    this.trailingInset = 0,
  });

  final AttachmentPreviewTarget target;
  final VoidCallback onReload, onDownload, onClose;
  final VoidCallback? onExpand;
  final bool expanded;
  final int? byteLength;
  final double trailingInset;

  String get _size {
    final bytes = byteLength;
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = target.name.isEmpty ? '未命名附件' : target.name;
    final format = attachmentPreviewFormat(name, target.url, target.mime);
    final fallbackExtension = switch (format) {
      'image' => 'png',
      'video' => 'mp4',
      'markdown' || 'text' => 'txt',
      _ => format,
    };
    final iconName =
        fileAttachmentIconAsset(fileAttachmentExtension(name)) != null
            ? name
            : 'preview.$fallbackExtension';
    Widget action(IconData icon, String label, VoidCallback? callback) =>
        IconButton(
          tooltip: label,
          onPressed: callback,
          icon: Icon(icon, size: 16),
          color: colors.onSurfaceVariant,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            hoverColor: colors.onSurfaceVariant.withValues(alpha: .08),
          ),
        );
    return Container(
      key: const ValueKey('attachment-preview-header'),
      constraints: const BoxConstraints(minHeight: 44),
      padding: EdgeInsets.only(
          left: 12, right: 8 + trailingInset, top: 8, bottom: 7),
      decoration: BoxDecoration(
        border: Border(
            bottom:
                BorderSide(color: colors.outlineVariant.withValues(alpha: .5))),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final compact = box.maxWidth < 340;
        final showSize = _size.isNotEmpty &&
            box.maxWidth >= 310 &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        return Row(children: [
          FileAttachmentIcon(
              fileName: iconName,
              customDimension: 24,
              fallbackIconColor: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
              child: Row(children: [
            Flexible(
                child: Tooltip(
              message: _size.isEmpty ? name : '$name · $_size',
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,),
            ),
                      ),
                    ),
            if (showSize) ...[
              const SizedBox(width: 10),
              Text(_size,
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
            ],
          ])),
          const SizedBox(width: 8),
          if (compact)
            SizedBox.square(
                dimension: 28,
                child: PopupMenuButton<String>(
                  tooltip: '更多文件操作',
                  icon: Icon(CupertinoIcons.ellipsis,
                      size: 16, color: colors.onSurfaceVariant),
                  padding: EdgeInsets.zero,
                  onSelected: (value) =>
                      value == 'reload' ? onReload() : onDownload(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'reload', child: Text('重新加载')),
                    PopupMenuItem(value: 'download', child: Text('下载')),
                  ],
                ))
          else ...[
            action(CupertinoIcons.refresh, '重新加载', onReload),
            action(CupertinoIcons.arrow_down_to_line, '下载', onDownload),
          ],
          if (onExpand != null)
            action(
                expanded
                    ? CupertinoIcons.arrow_down_right_arrow_up_left
                    : CupertinoIcons.arrow_up_left_arrow_down_right,
                expanded ? '还原' : '展开预览',
                onExpand),
          action(CupertinoIcons.xmark, '关闭预览', onClose),
        ]);
      }),
    );
  }
}
