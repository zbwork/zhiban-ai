import 'dart:typed_data';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import '../attachment_preview_dialog.dart';
import 'attachment_preview_loader.dart';
import 'attachment_preview_target.dart';
import 'chat_file_row.dart';
import 'chat_artifact_download.dart';
import 'local_artifact_source.dart';

/// One result card for every runtime. Only the source and available actions vary.
class ChatArtifactCard extends StatefulWidget {
  const ChatArtifactCard(
      {super.key,
      required this.target,
      this.sizeText = '',
      this.loaderFactory,
      this.source,
      this.summary = '',
      this.kind = '',
      this.embedded = false,
      this.compact = false,
      this.showArchiveStatus = true});
  final AttachmentPreviewTarget target;
  final AttachmentPreviewLoader Function()? loaderFactory;
  final LocalArtifactSource? source;
  final String sizeText, summary, kind;
  final bool embedded, showArchiveStatus, compact;
  String get format => kind == 'image' || kind == 'video'
      ? kind
      : attachmentPreviewFormat(target.name, target.url, target.mime);

  ChatArtifactCard inGroup({required bool showArchiveStatus, bool? compact}) =>
      ChatArtifactCard(
          key: key,
          target: target,
          loaderFactory: loaderFactory,
          source: source,
          sizeText: sizeText,
          summary: summary,
          kind: kind,
          embedded: true,
          compact: compact ?? this.compact,
          showArchiveStatus: showArchiveStatus);
  @override
  State<ChatArtifactCard> createState() => _ChatArtifactCardState();
}

class _ChatArtifactCardState extends State<ChatArtifactCard> {
  AttachmentPreviewLoader? _loader;
  Future<Uint8List>? _thumbnail;
  String? _error;
  bool _downloading = false;
  String get format => widget.format;
  @override
  void initState() {
    super.initState();
    AttachmentPreviewRefresh.instance.addListener(_previewRead);
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(ChatArtifactCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.url != widget.target.url ||
        oldWidget.target.mime != widget.target.mime ||
        oldWidget.target.name != widget.target.name ||
        oldWidget.kind != widget.kind ||
        oldWidget.compact != widget.compact) {
      _error = null;
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    _loader?.dispose();
    _loader = null;
    _thumbnail = null;
    if (!widget.compact && format == 'image' && widget.target.url.isNotEmpty) {
      _loader = widget.loaderFactory?.call() ?? AttachmentPreviewLoader();
      _thumbnail = _loader!.read(widget.target, 'image');
    }
  }

  void _previewRead() {
    if (mounted &&
        format == 'image' &&
        AttachmentPreviewRefresh.instance.url == widget.target.url) {
      setState(_loadThumbnail);
    }
  }

  @override
  void dispose() {
    AttachmentPreviewRefresh.instance.removeListener(_previewRead);
    _loader?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await showAttachmentPreviewDialog(context,
        rawUrl: widget.target.url,
        displayName: widget.target.name,
        mime: widget.target.mime.isNotEmpty
            ? widget.target.mime
            : format == 'video'
                ? 'video/mp4'
                : format == 'image'
                    ? 'image/*'
                    : '',
        downloadUrl: widget.target.downloadUrl);
    // Preview can succeed after the initial thumbnail read raced artifact
    // materialization (especially on Windows). Refresh on every platform so a
    // successful preview also repairs the inline card instead of leaving the
    // stale "unavailable" placeholder visible.
    if (mounted && format == 'image') {
      setState(_loadThumbnail);
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      await downloadChatArtifact(context, widget.target);
    } catch (_) {
      if (mounted) setState(() => _error = '文件下载失败或当前设备无法访问，请重试。');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _reveal() async {
    try {
      await LocalAgentService.instance.revealArtifact(widget.source!);
    } catch (_) {
      if (mounted) setState(() => _error = '原文件已移动、变化或不在这台电脑。可从预览下载副本。');
    }
  }

  Widget _placeholder({bool failed = false}) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
        color: scheme.surfaceContainerLow,
        child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
              format == 'video'
                  ? CupertinoIcons.play_circle
                  : CupertinoIcons.photo,
              size: 42,
              color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
              failed
                  ? '缩略图加载失败，点击预览查看'
                  : format == 'video'
                      ? '播放视频'
                      : '暂无图片预览',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final source = widget.source;
    final available = widget.target.url.isNotEmpty;
    final name = widget.target.name.isEmpty ? '未命名附件' : widget.target.name;
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
    final selected =
        AttachmentPreviewScope.of(context)?.selectedUrl == widget.target.url;
    final meta = [
      if (widget.compact) '可编辑源文件',
      if (ext.isNotEmpty) ext,
      if (widget.sizeText.isNotEmpty) widget.sizeText,
      if (source != null && PlatformUtils.isDesktop) '本机文件',
      if (widget.showArchiveStatus && source?.archiveStatus == 'synced')
        '已归档云盘',
      if (source?.archiveStatus == 'failed') '云盘归档未完成',
    ].join(' · ');
    final media = !widget.compact && (format == 'image' || format == 'video');
    final buttonSize = PlatformUtils.isDesktop ? 32.0 : 44.0;
    Widget action(String tooltip, IconData icon, VoidCallback? onPressed,
            {bool loading = false, bool emphasized = false}) =>
        IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints:
                BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
            style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            color: emphasized ? scheme.primary : scheme.onSurfaceVariant,
            icon: loading
                ? const CupertinoActivityIndicator()
                : Icon(icon, size: 19));
    final body = Container(
        key: const ValueKey('chat-artifact-card'),
        constraints: const BoxConstraints(minHeight: 64),
        color:
            selected ? scheme.primary.withValues(alpha: .06) : scheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (media) ...[
                Semantics(
                    button: true,
                    label: format == 'video' ? '播放 $name' : '预览 $name',
                    child: GestureDetector(
                        onTap: available ? _open : null,
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                                height: 180,
                                child: format == 'video'
                                    ? _placeholder()
                                    : _thumbnail == null
                                        ? _placeholder()
                                        : FutureBuilder<Uint8List>(
                                            future: _thumbnail,
                                            builder: (context, snapshot) {
                                              if (snapshot.hasError) {
                                                return _placeholder(
                                                    failed: true);
                                              }
                                              if (!snapshot.hasData) {
                                                return ColoredBox(
                                                    color: scheme
                                                        .surfaceContainerLow,
                                                    child: const Center(
                                                        child:
                                                            CupertinoActivityIndicator()));
                                              }
                                              if (widget.target.mime ==
                                                      'image/svg+xml' ||
                                                  widget.target.name
                                                      .toLowerCase()
                                                      .endsWith('.svg')) {
                                                return SvgPicture.memory(
                                                    snapshot.data!,
                                                    fit: BoxFit.contain,
                                                    errorBuilder:
                                                        (_, __, ___) =>
                                                            _placeholder(
                                                                failed: true));
                                              }
                                              return Image.memory(
                                                  snapshot.data!,
                                                  fit: BoxFit.contain,
                                                  errorBuilder: (_, __, ___) =>
                                                      _placeholder(
                                                          failed: true));
                                            }))))),
                const SizedBox(height: 8),
              ],
              ChatFileRow(
                  name: name,
                  meta: meta,
                  selected: selected,
                  leading: media ? const SizedBox.shrink() : null,
                  onOpen: available ? _open : null,
                  actions: Row(mainAxisSize: MainAxisSize.min, children: [
                    action(
                        format == 'video' ? '播放' : '预览',
                        format == 'video'
                            ? CupertinoIcons.play
                            : CupertinoIcons.eye,
                        available ? _open : null,
                        emphasized: !PlatformUtils.isDesktop),
                    if (PlatformUtils.isDesktop)
                      action('下载', CupertinoIcons.arrow_down_to_line,
                          available && !_downloading ? _download : null,
                          loading: _downloading),
                    if (!PlatformUtils.isDesktop)
                      SizedBox.square(
                          dimension: 44,
                          child: PopupMenuButton<String>(
                            tooltip: '更多文件操作',
                            enabled: available && !_downloading,
                            icon: _downloading
                                ? const CupertinoActivityIndicator()
                                : Icon(CupertinoIcons.ellipsis,
                                    size: 20, color: scheme.onSurfaceVariant),
                            onSelected: (_) => _download(),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'save', child: Text('保存到文件')),
                              PopupMenuItem(value: 'share', child: Text('分享')),
                            ],
                          )),
                    if (source != null &&
                        PlatformUtils.isDesktop &&
                        LocalAgentService.instance.deviceId == source.deviceId)
                      action('在文件夹中显示', CupertinoIcons.folder, _reveal),
                  ])),
              if (!available)
                Text('暂无可下载地址',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12)),
              if (widget.summary.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(widget.summary,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant))),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_error!,
                        style: TextStyle(fontSize: 12, color: scheme.error))),
            ]));
    if (widget.embedded) return body;
    return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: media ? 340 : 560),
            child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: .65)),
                    borderRadius: BorderRadius.circular(10)),
                child: body)));
  }
}

/// Consecutive files share one frame; mixed archive states remain per-file.
class ChatArtifactGroup extends StatelessWidget {
  const ChatArtifactGroup(
      {super.key, required this.cards, this.maxWidth = 560});
  final double maxWidth;
  final List<ChatArtifactCard> cards;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allArchived = cards.isNotEmpty &&
        cards.every((card) => card.source?.archiveStatus == 'synced');
    return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: .65)),
                    borderRadius: BorderRadius.circular(10)),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < cards.length; i++) ...[
                        if (i > 0)
                          Divider(
                              height: 1,
                              thickness: 1,
                              color:
                                  scheme.outlineVariant.withValues(alpha: .45)),
                        cards[i].inGroup(showArchiveStatus: !allArchived),
                      ],
                      if (allArchived) ...[
                        Divider(
                            height: 1,
                            thickness: 1,
                            color:
                                scheme.outlineVariant.withValues(alpha: .45)),
                        Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            child: Row(children: [
                              Icon(CupertinoIcons.checkmark_seal,
                                  size: 16, color: scheme.primary),
                              const SizedBox(width: 6),
                              Text('已归档云盘',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant)),
                            ])),
                      ],
                    ]))));
  }
}
