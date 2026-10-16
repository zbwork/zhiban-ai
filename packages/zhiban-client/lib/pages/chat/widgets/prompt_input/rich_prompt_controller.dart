import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';

enum RichAttachmentStatus { uploading, ready, failed }

enum RichPromptDraftBlockKind { text, attachment }

class RichPromptDraftBlock {
  const RichPromptDraftBlock.text({
    required this.id,
    required this.text
  })  : kind = RichPromptDraftBlockKind.text,
        attachment = null;

  const RichPromptDraftBlock.attachment({
    required this.id,
    required this.attachment,
  })  : kind = RichPromptDraftBlockKind.attachment,
        text = '';

  final String id;
  final RichPromptDraftBlockKind kind;
  final String text;
  final RichPromptAttachment? attachment;

  bool get isText => kind == RichPromptDraftBlockKind.text;
  bool get isAttachment => kind == RichPromptDraftBlockKind.attachment;

  RichPromptDraftBlock copyWith({
    String? text,
    RichPromptAttachment? attachment,
  }) {
    if (isText) {
      return RichPromptDraftBlock.text(id: id, text: text ?? this.text);
    }
    return RichPromptDraftBlock.attachment(
      id: id,
      attachment: attachment ?? this.attachment!,
    );
  }
}

class RichPromptAttachment {
  const RichPromptAttachment({
    required this.id,
    required this.fileName,
    required this.fileType,
    this.localPath = '',
    this.status = RichAttachmentStatus.uploading,
    this.progress = 0,
    this.error = '',
    this.block,
    this.onCancel,
  });

  final String id;
  final String fileName;
  final ChatFileType fileType;
  final String localPath;
  final RichAttachmentStatus status;
  final int progress;
  final String error;
  final ImMessageBlock? block;
  final VoidCallback? onCancel;

  bool get isReady => status == RichAttachmentStatus.ready && block != null;
  bool get isUploading => status == RichAttachmentStatus.uploading;
  bool get isFailed => status == RichAttachmentStatus.failed;

  RichPromptAttachment copyWith({
    RichAttachmentStatus? status,
    int? progress,
    String? error,
    ImMessageBlock? block,
    VoidCallback? onCancel,
  }) {
    return RichPromptAttachment(
      id: id,
      fileName: fileName,
      fileType: fileType,
      localPath: localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: error ?? this.error,
      block: block ?? this.block,
      onCancel: onCancel ?? this.onCancel,
    );
  }
}

/// 契约 §3.0f C7：composer 草稿的不透明快照 payload。
/// 由 [RichPromptController.snapshotDraft] 导出、[RichPromptController.restoreDraft]
/// 恢复；存放在 ChatComposerDraft.composer（models 层不感知本类型）。
class RichComposerDraftPayload {
  const RichComposerDraftPayload({
    required this.blocks,
    required this.attachments,
    required this.activeTextBlockIndex,
    required this.selectionBase,
    required this.selectionExtent,
  });

  final List<RichPromptDraftBlock> blocks;
  final Map<String, RichPromptAttachment> attachments;
  final int activeTextBlockIndex;
  final int selectionBase;
  final int selectionExtent;

  bool get hasContent =>
      attachments.isNotEmpty ||
      blocks.any((b) => b.isText && b.text.trim().isNotEmpty);
}

/// 轻量 chat block composer controller。
///
/// 图片/文件不再塞进 [TextField] 的 [WidgetSpan]。控制器维护一个有序
/// draft block 列表,当前正在编辑的 text block 仍复用 TextEditingController
/// 的 value,从而保留输入法/快捷键/群聊 @ 候选的普通文本编辑能力。
class RichPromptController extends TextEditingController {
  RichPromptController({super.text}) {
    _blocks.add(RichPromptDraftBlock.text(
      id: _nextTextId(),
      text: value.text
    ));
    addListener(_syncActiveTextFromValue);
  }

  final Map<String, RichPromptAttachment> _attachments = {};
  final List<RichPromptDraftBlock> _blocks = <RichPromptDraftBlock>[];
  int _activeTextBlockIndex = 0;
  int _textSeq = 0;
  bool _internalUpdate = false;

  List<RichPromptAttachment> get attachments =>
      List.unmodifiable(_attachments.values);
  List<RichPromptDraftBlock> get draftBlocks => List.unmodifiable(_blocks);
  int get activeTextBlockIndex => _activeTextBlockIndex;

  bool get hasAttachments => _attachments.isNotEmpty;
  bool get hasUploading => _attachments.values.any((a) => a.isUploading);
  bool get hasFailed => _attachments.values.any((a) => a.isFailed);
  bool get hasUnready => _attachments.values.any((a) => !a.isReady);

  String get textWithoutAttachmentTokens => _blocks
      .where((b) => b.isText)
      .map((b) => b.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n')
      .trim();

  bool get hasRichContent =>
      textWithoutAttachmentTokens.isNotEmpty || _attachments.isNotEmpty;

  void insertMixedBlocks(List<ImMessageBlock> blocks) {
    if (blocks.isEmpty) return;
    for (final block in blocks) {
      if (block.isText || block.isMarkdown) {
        _insertTextAtCursor(block.text);
      } else if (block.isImage || block.isFile) {
        insertAttachment(_attachmentFromBlock(block));
      }
    }
  }

  void insertAttachment(RichPromptAttachment attachment) {
    _attachments[attachment.id] = attachment;
    _syncActiveTextFromValue();
    _ensureActiveTextBlock();

    final active = _blocks[_activeTextBlockIndex];
    final raw = active.text;
    final sel = value.selection;
    final start = sel.isValid ? sel.start.clamp(0, raw.length) : raw.length;
    final end = sel.isValid ? sel.end.clamp(0, raw.length) : raw.length;
    final before = raw.substring(0, start);
    final after = raw.substring(end);

    _blocks[_activeTextBlockIndex] = active.copyWith(text: before);
    _blocks.insert(
      _activeTextBlockIndex + 1,
      RichPromptDraftBlock.attachment(
        id: attachment.id,
        attachment: attachment,
      ),
    );
    _blocks.insert(
      _activeTextBlockIndex + 2,
      RichPromptDraftBlock.text(id: _nextTextId(), text: after),
    );
    _setActiveTextBlock(_activeTextBlockIndex + 2, selectionOffset: 0);
    notifyListeners();
  }

  void updateAttachment(String id,
      RichPromptAttachment Function(RichPromptAttachment old) update) {
    final old = _attachments[id];
    if (old == null) return;
    final next = update(old);
    _attachments[id] = next;
    final idx = _blocks.indexWhere((b) => b.isAttachment && b.id == id);
    if (idx >= 0) {
      _blocks[idx] = _blocks[idx].copyWith(attachment: next);
    }
    notifyListeners();
  }

  void activateTextBlock(int index) {
    _syncActiveTextFromValue();
    _setActiveTextBlock(index);
    notifyListeners();
  }

  void activateTrailingTextBlock() {
    _syncActiveTextFromValue();
    final idx = _blocks.lastIndexWhere((b) => b.isText);
    if (idx < 0) {
      _ensureActiveTextBlock();
      _setActiveTextBlock(_activeTextBlockIndex);
    } else {
      _setActiveTextBlock(idx);
    }
    notifyListeners();
  }

  bool moveToNextTextBlockFromCaretEnd() {
    _syncActiveTextFromValue();
    if (_activeTextBlockIndex < 0 ||
        _activeTextBlockIndex >= _blocks.length ||
        !_blocks[_activeTextBlockIndex].isText) {
      return false;
    }
    final selection = value.selection;
    final activeText = _blocks[_activeTextBlockIndex].text;
    if (!selection.isValid ||
        !selection.isCollapsed ||
        selection.baseOffset < activeText.length) {
      return false;
    }
    for (var i = _activeTextBlockIndex + 1; i < _blocks.length; i++) {
      if (_blocks[i].isText) {
        _setActiveTextBlock(i, selectionOffset: 0);
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  bool moveToPreviousTextBlockFromCaretStart() {
    _syncActiveTextFromValue();
    if (_activeTextBlockIndex < 0 ||
        _activeTextBlockIndex >= _blocks.length ||
        !_blocks[_activeTextBlockIndex].isText) {
      return false;
    }
    final selection = value.selection;
    if (!selection.isValid ||
        !selection.isCollapsed ||
        selection.baseOffset > 0) {
      return false;
    }
    for (var i = _activeTextBlockIndex - 1; i >= 0; i--) {
      if (_blocks[i].isText) {
        _setActiveTextBlock(i);
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void removeAttachment(String id) {
    final old = _attachments.remove(id);
    old?.onCancel?.call();
    final idx = _blocks.indexWhere((b) => b.isAttachment && b.id == id);
    if (idx < 0) {
      notifyListeners();
      return;
    }
    _blocks.removeAt(idx);
    if (_activeTextBlockIndex > idx) {
      _activeTextBlockIndex -= 1;
    }
    _mergeAdjacentTextBlocksAround((idx - 1).clamp(0, _blocks.length));
    _ensureActiveTextBlock();
    _setActiveTextBlock(_activeTextBlockIndex);
    notifyListeners();
  }

  void clearRich() {
    _attachments.clear();
    _blocks
      ..clear()
      ..add(RichPromptDraftBlock.text(id: _nextTextId(), text: ''));
    _activeTextBlockIndex = 0;
    _internalUpdate = true;
    clear();
    _internalUpdate = false;
  }

  /// F09 §5.7 / 契约 §3.0f C7：导出当前 composer 的完整草稿快照
  /// （有序 blocks + 附件 + 光标），供按会话 snapshot/restore。
  RichComposerDraftPayload snapshotDraft() {
    _syncActiveTextFromValue();
    final sel = value.selection;
    return RichComposerDraftPayload(
      blocks: List.of(_blocks),
      attachments: Map.of(_attachments),
      activeTextBlockIndex: _activeTextBlockIndex,
      selectionBase: sel.isValid ? sel.baseOffset : -1,
      selectionExtent: sel.isValid ? sel.extentOffset : -1,
    );
  }

  /// An asynchronous send must not erase edits made while it was pending.
  bool clearIfUnchanged(RichComposerDraftPayload sentDraft) {
    _syncActiveTextFromValue();
    if (!listEquals(_blocks, sentDraft.blocks)) return false;
    clearRich();
    return true;
  }

  /// 用 [payload] 整体恢复 composer；传 null 恢复为空（新会话无草稿）。
  void restoreDraft(RichComposerDraftPayload? payload) {
    if (payload == null) {
      clearRich();
      return;
    }
    _attachments
      ..clear()
      ..addAll(payload.attachments);
    _blocks
      ..clear()
      ..addAll(payload.blocks);
    _activeTextBlockIndex = payload.activeTextBlockIndex;
    _ensureActiveTextBlock();
    final activeText = _blocks[_activeTextBlockIndex].text;
    final base = payload.selectionBase >= 0
        ? payload.selectionBase.clamp(0, activeText.length)
        : activeText.length;
    final extent = payload.selectionExtent >= 0
        ? payload.selectionExtent.clamp(0, activeText.length)
        : activeText.length;
    _internalUpdate = true;
    value = TextEditingValue(
      text: activeText,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
      composing: TextRange.empty,
    );
    _internalUpdate = false;
    notifyListeners();
  }

  List<ImMessageBlock> toMixedBlocks() {
    final out = <ImMessageBlock>[];
    _syncActiveTextFromValue();
    for (final block in _blocks) {
      if (block.isText) {
        _appendText(out, block.text);
      } else {
        final media = block.attachment?.block;
        if (media != null) out.add(media);
      }
    }
    return out;
  }

  static String summaryOfBlocks(List<ImMessageBlock> blocks) {
    final parts = <String>[];
    for (final b in blocks) {
      if (b.isText) {
        final t = b.text.trim();
        if (t.isNotEmpty) parts.add(t);
      } else if (b.isImage) {
        parts.add('[图片]');
      } else if (b.isFile) {
        parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[文件]');
      }
    }
    return parts.join(' ').trim();
  }

  static void _appendText(List<ImMessageBlock> out, String raw) {
    final t = raw.trim();
    if (t.isEmpty) return;
    if (out.isNotEmpty && out.last.isText) {
      final prev = out.removeLast();
      out.add(ImMessageBlock(
        kind: ImMessageBlockKind.text,
        text: '${prev.text}\n$t'),
      );
    } else {
      out.add(ImMessageBlock(kind: ImMessageBlockKind.text, text: t));
    }
  }

  void _insertTextAtCursor(String snippet) {
    if (snippet.isEmpty) return;
    _syncActiveTextFromValue();
    _ensureActiveTextBlock();
    final active = _blocks[_activeTextBlockIndex];
    final raw = active.text;
    final sel = value.selection;
    final start = sel.isValid ? sel.start.clamp(0, raw.length) : raw.length;
    final end = sel.isValid ? sel.end.clamp(0, raw.length) : raw.length;
    final next = raw.replaceRange(start, end, snippet);
    _blocks[_activeTextBlockIndex] = active.copyWith(text: next);
    _setActiveTextBlock(_activeTextBlockIndex,
        selectionOffset: start + snippet.length);
    notifyListeners();
  }

  RichPromptAttachment _attachmentFromBlock(ImMessageBlock block) {
    final fallbackName = block.isImage ? '图片' : '文件';
    final name =
        block.name.trim().isNotEmpty ? block.name.trim() : fallbackName;
    return RichPromptAttachment(
      id: 'paste-${_nextTextId()}',
      fileName: name,
      fileType: block.isImage ? ChatFileType.image : ChatFileType.file,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: block,
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(style: style, text: text);
  }

  String _nextTextId() {
    _textSeq += 1;
    return 'text-$_textSeq';
  }

  void _syncActiveTextFromValue() {
    if (_internalUpdate || _blocks.isEmpty) return;
    if (_activeTextBlockIndex < 0 ||
        _activeTextBlockIndex >= _blocks.length ||
        !_blocks[_activeTextBlockIndex].isText) {
      _ensureActiveTextBlock();
    }
    final active = _blocks[_activeTextBlockIndex];
    if (active.text != value.text) {
      _blocks[_activeTextBlockIndex] = active.copyWith(text: value.text);
    }
  }

  void _setActiveTextBlock(int index, {int? selectionOffset}) {
    if (index < 0 || index >= _blocks.length || !_blocks[index].isText) return;
    _activeTextBlockIndex = index;
    final nextText = _blocks[index].text;
    final offset =
        (selectionOffset ?? nextText.length).clamp(0, nextText.length);
    _internalUpdate = true;
    value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: offset),
      composing: TextRange.empty,
    );
    _internalUpdate = false;
  }

  void _ensureActiveTextBlock() {
    if (_blocks.isEmpty) {
      _blocks.add(RichPromptDraftBlock.text(id: _nextTextId(), text: ''));
      _activeTextBlockIndex = 0;
      return;
    }
    if (_activeTextBlockIndex >= 0 &&
        _activeTextBlockIndex < _blocks.length &&
        _blocks[_activeTextBlockIndex].isText) {
      return;
    }
    final idx = _blocks.lastIndexWhere((b) => b.isText);
    if (idx >= 0) {
      _activeTextBlockIndex = idx;
      return;
    }
    _blocks.add(RichPromptDraftBlock.text(id: _nextTextId(), text: ''));
    _activeTextBlockIndex = _blocks.length - 1;
  }

  void _mergeAdjacentTextBlocksAround(int start) {
    if (_blocks.length < 2) return;
    var i = start.clamp(0, _blocks.length - 1);
    if (i > 0) i -= 1;
    while (i < _blocks.length - 1) {
      final a = _blocks[i];
      final b = _blocks[i + 1];
      if (a.isText && b.isText) {
        final mergedText = '${a.text}${b.text}';
        _blocks[i] = a.copyWith(text: mergedText);
        _blocks.removeAt(i + 1);
        if (_activeTextBlockIndex == i + 1) {
          _activeTextBlockIndex = i;
        } else if (_activeTextBlockIndex > i + 1) {
          _activeTextBlockIndex -= 1;
        }
        continue;
      }
      i += 1;
    }
  }
}

extension RichPromptFocusX on State {
  void refocusPromptInput(FocusNode focusNode) {
    if (!mounted) return;
    FocusScope.of(context).requestFocus(FocusNode());
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) FocusScope.of(context).requestFocus(focusNode);
    });
  }
}

class RichPromptAttachmentPreview extends StatelessWidget {
  const RichPromptAttachmentPreview({
    super.key,
    required this.attachment,
    required this.onRemove,
    this.maxWidth = 380,
  });

  final RichPromptAttachment attachment;
  final VoidCallback onRemove;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return attachment.fileType == ChatFileType.image
        ? _imagePreview(context)
        : _fileChip(context);
  }

  Widget _imagePreview(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final rawUrl = attachment.block?.url.trim() ?? '';
    final resolvedUrl = rawUrl.isEmpty ? null : apiImageResolveUrl(rawUrl);
    final needsAuth = rawUrl.isNotEmpty && apiImageNeedsAuth(rawUrl);
    return SizedBox(
      width: 168,
      height: 112,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: FutureBuilder<Map<String, String>>(
                future: rawUrl.isEmpty
                    ? Future.value(const <String, String>{})
                    : apiImageLoadHeaders(rawUrl),
                builder: (context, snap) {
                  final filePath = attachment.localPath.isNotEmpty
                      ? attachment.localPath
                      : null;
                  if (needsAuth &&
                      snap.connectionState != ConnectionState.done) {
                    return UiImagePreviewThumb(
                      width: 168,
                      height: 112,
                      borderRadius: 10,
                      filePath: filePath,
                      onPreview: (tag) =>
                          _openPreview(context, filePath, null, null, tag),
                    );
                  }
                  return UiImagePreviewThumb(
                    width: 168,
                    height: 112,
                    borderRadius: 10,
                    filePath: filePath,
                    fileUrl: resolvedUrl,
                    httpHeaders: snap.data,
                    cacheKey: resolvedUrl,
                    onPreview: (tag) => _openPreview(
                        context, filePath, resolvedUrl, snap.data, tag),
                  );
                },
              ),
            ),
          ),
          if (attachment.isUploading) _progressOverlay(radius),
          if (attachment.isFailed) _failedOverlay(radius),
          _removeButton(),
        ],
      ),
    );
  }

  void _openPreview(
    BuildContext context,
    String? filePath,
    String? fileUrl,
    Map<String, String>? httpHeaders,
    Object heroTag,
  ) {
    if (attachment.isUploading || attachment.isFailed) return;
    if (tryOpenChatImagePreview(context,
        rawUrl: filePath != null && filePath.isNotEmpty
            ? Uri.file(filePath).toString()
            : fileUrl ?? '',
        displayName: attachment.fileName)) {
      return;
    }
    showImagePreviewRoute<void>(
      context: context,
      useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
          Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => UiImagePreviewDialog(
        heroTag: heroTag,
        filePath: filePath,
        fileUrl: fileUrl,
        httpHeaders: httpHeaders,
        cacheKey: fileUrl,
      ),
    );
  }

  Widget _fileChip(BuildContext context) {
    final availableWidth = maxWidth.isFinite ? maxWidth : 230.0;
    final width = availableWidth >= 230
        ? 230.0
        : availableWidth.clamp(190.0, 230.0).toDouble();
    final statusText = attachment.isUploading
        ? '上传中 ${attachment.progress.clamp(0, 100)}%'
        : attachment.isFailed
            ? '上传失败'
            : _readyFileMeta();
    final statusColor =
        attachment.isFailed ? const Color(0xFFE5484D) : const Color(0xFF8A94A6);

    return SizedBox(
      width: width,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 34, 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E7EB)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.025),
                    blurRadius: 5,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FileAttachmentIcon(
                    fileName: attachment.fileName,
                    size: FileAttachmentIconSize.lg,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          attachment.fileName.isEmpty
                              ? '文件'
                              : attachment.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827),
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 11,
                            color: statusColor,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: _miniRemoveButton()
          ),
        ],
      ),
    );
  }

  String _readyFileMeta() {
    final ext = fileAttachmentExtension(attachment.fileName);
    return switch (ext) {
      'xls' || 'xlsx' || 'csv' => '电子表格',
      'doc' || 'docx' || 'rtf' => '文档',
      'ppt' || 'pptx' => '演示文稿',
      'pdf' => 'PDF',
      'txt' || 'md' => '文本',
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => '压缩包',
      _ => '文件',
    };
  }

  Widget _progressOverlay(BorderRadius radius) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Colors.black.withValues(alpha: 0.22),
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CupertinoActivityIndicator(radius: 5),
                const SizedBox(width: 5),
                Text(
                  '${attachment.progress.clamp(0, 100)}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF334155),
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _failedOverlay(BorderRadius radius) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Colors.black.withValues(alpha: 0.24),
        ),
        child: const Center(
          child: Icon(
            CupertinoIcons.exclamationmark_circle_fill,
            color: Color(0xFFE5484D),
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _removeButton() {
    return Positioned(
      right: 4,
      top: 4,
      child: _miniRemoveButton()
    );
  }

  Widget _miniRemoveButton({bool light = false}) {
    return GestureDetector(
      onTap: onRemove,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: light
              ? const Color(0xFFE5EAF2)
              : Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1),
        ),
        child: Icon(
          CupertinoIcons.xmark,
          size: 10,
          color: light ? const Color(0xFF64748B) : Colors.white,
        ),
      ),
    );
  }
}

/// PC / 移动端共用的图文排布视图：附件（图片/文件）按插入顺序独占一整行
/// （连续多个附件挤在同一个 [Wrap] 行里），文字按 block 顺序穿插在附件行
/// 之间，当前正在编辑的文本段落用真正的 [TextField]（由
/// [activeTextFieldBuilder] 提供）渲染。
class RichDraftBlocksView extends StatelessWidget {
  const RichDraftBlocksView({
    super.key,
    required this.controller,
    required this.activeTextFieldBuilder,
    required this.onFocusTrailingText,
    this.textTrailingPadding = 0,
  });

  final RichPromptController controller;
  final Widget Function({required bool reserveSendArea}) activeTextFieldBuilder;
  final VoidCallback onFocusTrailingText;

  /// 非当前编辑文本行右侧预留宽度：PC 端要避开右下角悬浮的发送按钮，
  /// 移动端发送按钮不悬浮在文字上，传 0 即可。
  final double textTrailingPadding;

  @override
  Widget build(BuildContext context) {
    final blocks = controller.draftBlocks;
    if (blocks.length == 1 && blocks.single.isText) {
      return activeTextFieldBuilder(reserveSendArea: true);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final children = <Widget>[];
        final pendingAttachments = <RichPromptAttachment>[];

        void flushAttachments() {
          if (pendingAttachments.isEmpty) return;
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  for (final attachment in pendingAttachments)
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: onFocusTrailingText,
                      child: RichPromptAttachmentPreview(
                        key: ValueKey('rich-attachment-${attachment.id}'),
                        attachment: attachment,
                        maxWidth: constraints.maxWidth - 8,
                        onRemove: () {
                          controller.removeAttachment(attachment.id);
                          onFocusTrailingText();
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
          pendingAttachments.clear();
        }

        for (var i = 0; i < blocks.length; i++) {
          final block = blocks[i];
          if (block.isAttachment) {
            final attachment = block.attachment;
            if (attachment != null) pendingAttachments.add(attachment);
            continue;
          }

          flushAttachments();
          if (i == controller.activeTextBlockIndex) {
            children.add(activeTextFieldBuilder(
              reserveSendArea: !_hasRenderableBlockAfter(blocks, i),
            ));
            continue;
          }
          if (block.text.trim().isEmpty) continue;
          children.add(
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onFocusTrailingText,
              child: Padding(
                padding: EdgeInsets.only(right: textTrailingPadding, bottom: 8),
                child: Text(
                  block.text,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
            ),
          );
        }
        flushAttachments();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children.isEmpty
              ? [activeTextFieldBuilder(reserveSendArea: true)]
              : children,
        );
      },
    );
  }

  bool _hasRenderableBlockAfter(List<RichPromptDraftBlock> blocks, int index) {
    for (var i = index + 1; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isAttachment) return true;
      if (block.text.trim().isNotEmpty) return true;
    }
    return false;
  }
}
