import 'package:flutter/material.dart';
import '../file_attachment_icon.dart';

/// Shared compact file presentation for cloud and local chat artifacts.
class ChatFileRow extends StatelessWidget {
  const ChatFileRow(
      {super.key,
      required this.name,
      required this.meta,
      required this.actions,
      required this.onOpen,
      this.leading,
      this.selected = false});
  final String name, meta;
  final bool selected;
  final Widget actions;
  final Widget? leading;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onOpen,
      child: Row(children: [
        leading ??
            FileAttachmentIcon(
                fileName: name,
                customDimension: 30,
                fallbackIconColor:
                    Theme.of(context).colorScheme.onSurfaceVariant),
        SizedBox(width: leading == null ? 10 : 0),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
              Tooltip(
                  message: name,
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurface))),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ])),
        const SizedBox(width: 8),
        actions,
      ]));
}
