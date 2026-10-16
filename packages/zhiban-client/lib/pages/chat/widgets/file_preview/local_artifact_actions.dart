import 'package:zhiban_ui/utils/platform_utils.dart';
import 'dart:typed_data';
import 'chat_file_row.dart';
import 'package:dio/dio.dart';
import '../file_attachment_icon.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import '../attachment_preview_dialog.dart';
import 'local_artifact_source.dart';

class LocalArtifactEntry {
  const LocalArtifactEntry(
      {required this.source,
      required this.name,
      required this.mime,
      this.sizeText = ''});
  final LocalArtifactSource source;
  final String name, mime, sizeText;
}

class LocalArtifactActions extends StatefulWidget {
  const LocalArtifactActions(
      {super.key,
      required this.source,
      required this.name,
      required this.mime,
      this.sizeText = '',
      this.additional = const []});
  final LocalArtifactSource source;
  final String name, mime, sizeText;
  final List<LocalArtifactEntry> additional;
  @override
  State<LocalArtifactActions> createState() => _LocalArtifactActionsState();
}

class _LocalArtifactActionsState extends State<LocalArtifactActions> {
  String error = '';
  List<LocalArtifactEntry> get entries => [
        LocalArtifactEntry(
            source: widget.source,
            name: widget.name,
            mime: widget.mime,
            sizeText: widget.sizeText),
        ...widget.additional
      ];
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            _LocalArtifactRow(
                key: ValueKey(entries[index].source.url),
                entry: entries[index],
                onError: (value) {
                  if (mounted) setState(() => error = value);
                }),
          ],
          if (error.isNotEmpty)
            Text(error, style: TextStyle(fontSize: 11, color: scheme.error)),
        ]);
  }
}

class _LocalArtifactRow extends StatefulWidget {
  const _LocalArtifactRow(
      {super.key, required this.entry, required this.onError});
  final LocalArtifactEntry entry;
  final ValueChanged<String> onError;
  @override
  State<_LocalArtifactRow> createState() => _LocalArtifactRowState();
}

class _LocalArtifactRowState extends State<_LocalArtifactRow> {
  final cancel = CancelToken();
  Future<Uint8List>? thumbnail;
  @override
  void initState() {
    super.initState();
    if (widget.entry.mime.startsWith('image/') &&
        LocalAgentService.instance.online) {
      thumbnail = LocalAgentService.instance
          .readArtifact(widget.entry.source, 12 * 1024 * 1024, cancel);
    }
  }

  @override
  void dispose() {
    cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final scheme = Theme.of(context).colorScheme;
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(7));
    Widget actions() => Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(
              style: TextButton.styleFrom(shape: buttonShape),
              onPressed: () => showAttachmentPreviewDialog(context,
                  rawUrl: entry.source.url,
                  displayName: entry.name,
                  mime: entry.mime),
              child: const Text('打开')),
          if (PlatformUtils.isDesktop &&
              LocalAgentService.instance.deviceId == entry.source.deviceId) ...[
            const SizedBox(width: 10),
            TextButton(
                style: TextButton.styleFrom(shape: buttonShape),
                onPressed: () async {
                  try {
                    await LocalAgentService.instance
                        .revealArtifact(entry.source);
                  } catch (_) {
                    widget.onError('原文件已移动、变化或不在这台电脑。请从预览中另存。');
                  }
                },
                child: const Text('在文件夹中显示')),
          ],
        ]);
    final fallback =
        FileAttachmentIcon(fileName: entry.name, customDimension: 36);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: scheme.surface,
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .65)),
          borderRadius: BorderRadius.circular(8)),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 460;
        final row = ChatFileRow(
          name: entry.name,
          meta: [
            if (entry.sizeText.isNotEmpty) entry.sizeText,
            '本机文件',
            if (entry.source.archiveStatus == 'synced') '已归档云盘',
            if (entry.source.archiveStatus == 'failed') '云盘归档未完成'
          ].join(' · '),
          actions: compact ? const SizedBox.shrink() : actions(),
          onOpen: () => showAttachmentPreviewDialog(context,
              rawUrl: entry.source.url,
              displayName: entry.name,
              mime: entry.mime),
          leading: SizedBox(
              width: 36,
              height: 36,
              child: thumbnail == null
                  ? fallback
                  : FutureBuilder<Uint8List>(
                      future: thumbnail,
                      builder: (context, snapshot) => snapshot.hasData
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.memory(snapshot.data!,
                                  fit: BoxFit.cover,
                                  cacheWidth: 108,
                                  errorBuilder: (_, __, ___) => fallback))
                          : fallback)),
        );
        return compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [row, const SizedBox(height: 4), actions()])
            : row;
      }),
    );
  }
}
