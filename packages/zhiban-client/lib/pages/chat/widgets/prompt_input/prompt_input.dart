import 'dart:async';

import 'package:zhiban_client/pages/apps/widgets/apps_plaza_sheet.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/rich_message_clipboard.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'components/emoji_picker_sheet.dart';
import '../compact_capability_icon.dart';
import 'rich_prompt_controller.dart';

class PromptInputOverlayMetrics {
  const PromptInputOverlayMetrics({
    required this.containerSize,
    required this.textFieldOrigin,
    required this.textFieldWidth,
    required this.overlayOrigin,
    required this.overlaySize,
    required this.textOffsetRect,
  });

  final Size containerSize;
  final Offset textFieldOrigin;
  final double textFieldWidth;
  final Offset overlayOrigin;
  final Size overlaySize;
  final Rect? Function(int textOffset) textOffsetRect;
}

typedef PromptInputOverlayBuilder = Widget Function(
  BuildContext context,
  PromptInputOverlayMetrics metrics
);

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    required this.focusNode,
    required this.controller,
    required this.onPickAttachment,
    required this.onPickFromDrive,
    required this.onSend,
    required this.onStop,
    required this.isSending,
    this.onNotify,
    this.conversationUuid = '',
    this.showSkillChips = true,
    this.showSkillButton = true,
    this.overlayBuilder,
    this.onPasteImage,
    this.onVoiceCall,
    this.voiceCallActive = false,
    this.voiceCallEnabled = false,
    this.onVideoCall,
    this.videoCallActive = false,
    this.videoCallEnabled = false,
    this.allowAttachmentOnlySend = false,
    this.enabled = true,
    this.skillIconUrls = const {},
    this.showAiDisclaimer = true,
    this.runtimeControls,
    this.sendReady = true,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final ValueChanged<ChatAttachmentPickKind> onPickAttachment;
  // 从云盘选择已有文件作为附件,不重新上传。
  final VoidCallback onPickFromDrive;

  /// 发送回调：参数为本次发送携带的已选技能 slug 列表（可为空）。
  /// 技能不会拼接到 text 里，由后端在调 OpenClaw 时单独处理。
  final ValueChanged<List<String>> onSend;
  final VoidCallback onStop;
  final bool isSending;
  final bool enabled;
  final bool sendReady;
  final ValueChanged<String>? onNotify;

  /// 当前会话 uuid：用于「应用」按钮拉取会话可用应用。空时应用广场显示空态。
  final String conversationUuid;

  /// 顶部「常用技能」chips（agent 对话显示；人↔人对话隐藏）。
  final bool showSkillChips;

  /// 兼容人聊/群聊调用方。桌面端独立技能按钮已统一移除，参数仅保留调用契约。
  final bool showSkillButton;

  /// 输入框内部浮层锚点。用于群聊 @ 候选面板按 TextField 真实宽度定位。
  final PromptInputOverlayBuilder? overlayBuilder;

  /// 输入框聚焦时粘贴图片(Ctrl/Cmd+V)的处理入口。
  ///
  /// 返回 false 表示剪贴板没有图片；PromptInput 会保留系统文本粘贴默认行为。
  final Future<bool> Function()? onPasteImage;

  /// 人↔人 direct chat 的语音通话入口。为空时语音按钮保持置灰预留态。
  final VoidCallback? onVoiceCall;

  /// 语音通话进行中时高亮 mic 按钮。
  final bool voiceCallActive;

  /// 是否允许点击语音按钮。false 时点击仍给出「敬请期待」。
  final bool voiceCallEnabled;

  /// 人↔人 direct chat 的视频通话入口（Phase B）。为空时「会议」按钮保持置灰预留态。
  final VoidCallback? onVideoCall;

  /// 视频通话进行中时高亮视频按钮。
  final bool videoCallActive;

  /// 是否允许点击视频按钮。false 时点击仍给出「敬请期待」。
  final bool videoCallEnabled;

  /// 是否允许仅靠待发送附件触发发送。
  ///
  /// Agent 对话当前仍需要文本 prompt；人↔人/群聊 IM composer 允许纯图片/文件发送。
  final bool allowAttachmentOnlySend;

  /// 当前数字员工技能 slug → iconUrl；仅用于已选标签展示，不进入草稿持久化。
  final Map<String, String> skillIconUrls;

  /// 底部"内容由AI生成，请仔细甄别"提示；仅 agent 对话展示，人↔人对话（含群聊）隐藏。
  final bool showAiDisclaimer;
  final Widget? runtimeControls;

  @override
  State<PromptInput> createState() => PromptInputState();
}

class PromptInputState extends State<PromptInput> {
  static const double _topMargin = 2;
  static const double _bottomMargin = 3;
  static const double _inputRadius = 8;
  static const double _mobileInputMinHeight = 183;
  static const double _desktopInputMinHeight = 231;
  static const double _contentHorizontalPadding = 14;
  static final double _iconSize = 16;
  static const double _sendButtonSize = 40;
  final OverlayPortalController _overlayController = OverlayPortalController();
  final GlobalKey _inputCardKey = GlobalKey();
  final GlobalKey _textFieldKey = GlobalKey();
  bool _pasteImageInFlight = false;

  /// 已选择的技能（slug, 展示名）。点击技能 chip 即追加，再次点击同一项忽略。
  /// 不会拼接到文本里——发送时把 slug 列表通过 onSend 透出，后端在调
  /// OpenClaw 时识别并路由到对应技能。
  final List<({String slug, String name})> _selectedSkills = [];

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverlayPortal());
  }

  void _removeSkillTag(String slug) {
    setState(() {
      _selectedSkills.removeWhere((s) => s.slug == slug);
    });
  }

  void addSelectedSkill({required String slug, required String name}) {
    final cleanSlug = slug.trim();
    if (cleanSlug.isEmpty) return;
    final cleanName = name.trim().isEmpty ? cleanSlug : name.trim();
    if (_selectedSkills.any((s) => s.slug == cleanSlug)) {
      widget.focusNode.requestFocus();
      return;
    }
    setState(() {
      _selectedSkills.add((slug: cleanSlug, name: cleanName));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.focusNode.requestFocus();
    });
  }

  /// 契约 §3.0f C7：已选技能随会话草稿 snapshot/restore（chat_session_view 调用）。
  List<({String slug, String name})> get selectedSkills =>
      List.unmodifiable(_selectedSkills);

  void restoreSelectedSkills(List<({String slug, String name})> skills) {
    if (!mounted) return;
    setState(() {
      _selectedSkills
        ..clear()
        ..addAll(skills);
    });
  }

  @override
  void didUpdateWidget(covariant PromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (oldWidget.overlayBuilder != widget.overlayBuilder) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverlayPortal());
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {});
  }

  void _focusEditorTail() {
    _richController?.activateTrailingTextBlock();
    refocusPromptInput(widget.focusNode);
  }

  void _syncOverlayPortal() {
    if (!mounted) return;
    if (widget.overlayBuilder == null) {
      _overlayController.hide();
    } else {
      _overlayController.show();
    }
  }

  RenderEditable? _findRenderEditable(RenderObject? root) {
    if (root == null) return null;
    if (root is RenderEditable) return root;
    RenderEditable? found;
    void visit(RenderObject child) {
      if (found != null) return;
      if (child is RenderEditable) {
        found = child;
        return;
      }
      child.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  Rect? _textOffsetRectInInput(int textOffset) {
    final inputRender = _inputCardKey.currentContext?.findRenderObject();
    final textRender = _textFieldKey.currentContext?.findRenderObject();
    if (inputRender is! RenderBox) return null;
    final editable = _findRenderEditable(textRender);
    if (editable == null || !editable.attached) return null;
    final safeOffset = textOffset.clamp(0, widget.controller.text.length);
    final localRect = editable.getLocalRectForCaret(
      TextPosition(offset: safeOffset),
    );
    final topLeft = editable.localToGlobal(
      localRect.topLeft,
      ancestor: inputRender,
    );
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      localRect.width,
      localRect.height,
    );
  }

  RichPromptController? get _richController =>
      widget.controller is RichPromptController
          ? widget.controller as RichPromptController
          : null;

  /// 在光标处插入文本（emoji）。无有效选区时追加到末尾。
  void _insertAtCursor(String snippet) {
    if (snippet.isEmpty) return;
    final value = widget.controller.value;
    final text = value.text;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, snippet);
    widget.controller.value = value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start + snippet.length),
      composing: TextRange.empty,
    );
    widget.focusNode.requestFocus();
  }

  Future<void> _pickEmoji() async {
    final picked = await showEmojiPickerSheet(context);
    if (picked == null) return;
    _insertAtCursor(picked);
  }

  Future<void> _openAppPlaza() async {
    // 「应用」→ 应用广场（会话维度可用应用 + 启动）。
    await showAppsPlazaSheet(context,
        conversationUuid: widget.conversationUuid);
  }

  void _comingSoon() {
    final notifier = widget.onNotify;
    if (notifier != null) {
      notifier('敬请期待');
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('敬请期待')));
  }

  void _insertNewLine() {
    final value = widget.controller.value;
    final selection = value.selection;
    final text = value.text;

    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final nextText = text.replaceRange(start, end, '\n');

    widget.controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  KeyEventResult _handleInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final rich = _richController;
    if (rich != null && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      return rich.moveToNextTextBlockFromCaretEnd()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (rich != null && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      return rich.moveToPreviousTextBlockFromCaretStart()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (rich != null && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return rich.moveToPreviousTextBlockFromCaretStart()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (rich != null && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return rich.moveToNextTextBlockFromCaretEnd()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (_pasteImageInFlight) return KeyEventResult.handled;
    _pasteImageInFlight = true;
    unawaited(_handlePasteShortcut().catchError((Object _) {
      final notifier = widget.onNotify;
      if (notifier != null) notifier('粘贴失败');
    }).whenComplete(() => _pasteImageInFlight = false));
    return KeyEventResult.handled;
  }

  Future<void> _handlePasteShortcut() async {
    final clipboardText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final rich = _richController;
    final richEntry = RichMessageClipboard.current;
    if (rich != null &&
        richEntry != null &&
        richEntry.blocks.isNotEmpty &&
        clipboardText == richEntry.plainText) {
      rich.insertMixedBlocks(richEntry.blocks);
      widget.focusNode.requestFocus();
      return;
    }

    final onPasteImage = widget.onPasteImage;
    if (onPasteImage != null) {
      final pastedImage = await onPasteImage();
      if (pastedImage) return;
    }

    if (clipboardText.isNotEmpty) {
      _insertAtCursor(clipboardText);
    }
  }

  void _trySend() {
    if (widget.isSending || !widget.sendReady) return;
    final rich = _richController;
    final hasText =
        rich?.hasRichContent ?? widget.controller.text.trim().isNotEmpty;
    final hasPending = rich?.hasAttachments ?? false;
    if (!hasText && !(widget.allowAttachmentOnlySend && hasPending)) {
      return;
    }
    if (rich?.hasUploading ?? false) {
      return;
    }
    if (rich?.hasFailed ?? false) {
      final notifier = widget.onNotify;
      if (notifier != null) {
        notifier('有文件上传失败，请移除后重试');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('有文件上传失败，请移除后重试'))
        );
      }
      return;
    }
    final skillSlugs =
        _selectedSkills.map((s) => s.slug).toList(growable: false);
    widget.onSend(skillSlugs);
    if (_selectedSkills.isNotEmpty) {
      setState(() => _selectedSkills.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;

    // 外层用 pageBg 同色 ColoredBox 兜底，避免消息列表向下滚时
    // 短暂从 composer 卡片左右边距/下边距的空隙里"漏"出来；
    // 同时也不再像旧实现那样在浅灰聊天主区上撕出一道生硬的白色 wrapper。
    // 输入框按设计图贴齐聊天列左右边缘，横向不再跟随消息列表留白。
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, _topMargin, 0, _bottomMargin),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OverlayPortal.overlayChildLayoutBuilder(
              controller: _overlayController,
              overlayChildBuilder: (context, info) {
                final builder = widget.overlayBuilder;
                if (builder == null) return const SizedBox.shrink();
                final inputOrigin = MatrixUtils.transformPoint(
                  info.childPaintTransform,
                  Offset.zero,
                );
                final inputWidth = info.childSize.width;
                final inputHeight = info.childSize.height;
                final metrics = PromptInputOverlayMetrics(
                  containerSize: Size(inputWidth, inputHeight),
                  textFieldOrigin: const Offset(14, 48),
                  textFieldWidth: (inputWidth - _contentHorizontalPadding * 2)
                      .clamp(0.0, double.infinity),
                  overlayOrigin: inputOrigin,
                  overlaySize: info.overlaySize,
                  textOffsetRect: _textOffsetRectInInput,
                );
                return builder(context, metrics);
              },
              child: AnimatedContainer(
                key: _inputCardKey,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                constraints: BoxConstraints(
                  minHeight: PlatformUtils.isMobile
                      ? _mobileInputMinHeight
                      : _desktopInputMinHeight,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(_inputRadius),
                  border: Border.all(
                    color: focused
                        ? UiFieldStyle.focusBorderColor(
                            Theme.of(context).colorScheme)
                        : UiFieldStyle.enabledBorderColor(
                            Theme.of(context).colorScheme),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F172A)
                          .withValues(alpha: focused ? 0.09 : 0.06),
                      blurRadius: focused ? 24 : 20,
                      spreadRadius: focused ? 0.5 : 0,
                      offset: const Offset(0, 8),
                    ),
                    BoxShadow(
                      color: const Color(0xFF475467)
                          .withValues(alpha: focused ? 0.035 : 0.025),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _focusEditorTail,
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, _) {
                      final rich = _richController;
                      final hasText =
                          rich?.hasRichContent ?? value.text.trim().isNotEmpty;
                      final hasUploading = rich?.hasUploading ?? false;
                      final canSend = widget.sendReady &&
                          !hasUploading &&
                          (hasText ||
                              (widget.allowAttachmentOnlySend &&
                                  (rich?.hasAttachments ?? false)));
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              _contentHorizontalPadding,
                              8,
                              _contentHorizontalPadding,
                              10,
                            ),
                            child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    minHeight: widget.runtimeControls == null
                                        ? 0
                                        : _desktopInputMinHeight - 18),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _ComposerToolBar(
                                            onPickEmoji: _pickEmoji,
                                            onUpload: () =>
                                                widget.onPickAttachment(
                                                    ChatAttachmentPickKind
                                                        .files),
                                            onPickFromDrive:
                                                widget.onPickFromDrive,
                                            onOpenAppPlaza: _openAppPlaza,
                                            onVoiceCall: widget.onVoiceCall,
                                            voiceCallActive:
                                                widget.voiceCallActive,
                                            voiceCallEnabled:
                                                widget.voiceCallEnabled,
                                            onVideoCall: widget.onVideoCall,
                                            videoCallActive:
                                                widget.videoCallActive,
                                            videoCallEnabled:
                                                widget.videoCallEnabled,
                                            onComingSoon: _comingSoon,
                                          ),
                                          if (_selectedSkills.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                for (final s in _selectedSkills)
                                                  _SelectedSkillTag(
                                                    label: s.name,
                                                    iconUrl:
                                                        widget.skillIconUrls[
                                                                s.slug] ??
                                                            '',
                                                    onRemove: () =>
                                                        _removeSkillTag(s.slug),
                                                  ),
                                              ],
                                            ),
                                          ],
                                          const SizedBox(height: 8),
                                          _buildComposerEditor(rich),
                                        ]),
                                    if (widget.runtimeControls != null)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(right: 42),
                                          child: widget.runtimeControls!),
                                  ],
                                )),
                          ),
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: widget.isSending
                                ? IconButtonSized(
                                    size: _sendButtonSize,
                                    child: IconButton.filled(
                                      onPressed: widget.onStop,
                                      constraints: BoxConstraints(
                                        minWidth: _iconSize,
                                        minHeight: _iconSize,
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.stop_fill,
                                        size: _iconSize,
                                        color: Colors.white,
                                      ),
                                      style: IconButton.styleFrom(
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  )
                                : IconButtonSized(
                                    size: _sendButtonSize,
                                    child: IconButton.filled(
                                      onPressed: canSend ? _trySend : null,
                                      constraints: BoxConstraints(
                                        minWidth: _iconSize,
                                        minHeight: _iconSize,
                                      ),
                                      icon: Icon(
                                        CupertinoIcons.paperplane_fill,
                                        size: _iconSize,
                                        color: Colors.white,
                                      ),
                                      style: IconButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF0F72FF),
                                        disabledBackgroundColor:
                                            const Color(0xFFE1E4EA),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (widget.showAiDisclaimer) ...[
              const SizedBox(height: 1),
              Text(
                '内容由AI生成，请仔细甄别',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: .65),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildComposerEditor(RichPromptController? rich) {
    Widget buildField({required bool reserveSendArea}) {
      return Padding(
        padding: EdgeInsets.only(
          right: reserveSendArea ? 58 : 0,
          bottom: reserveSendArea ? 42 : 8,
        ),
        child: Focus(
          onKeyEvent: _handleInputKey,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(
                LogicalKeyboardKey.enter,
                shift: true
              ): _InsertNewLineIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _InsertNewLineIntent: CallbackAction<_InsertNewLineIntent>(
                  onInvoke: (intent) {
                    _insertNewLine();
                    return null;
                  },
                ),
              },
              child: TextField(
                key: _textFieldKey,
                enabled: widget.enabled,
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: 1,
                maxLines: PlatformUtils.isMobile ? 6 : 8,
                textInputAction: TextInputAction.send,
                onEditingComplete: () {},
                onTapOutside: (_) {},
                onSubmitted: (_) => _trySend(),
                decoration: InputDecoration(
                  hintStyle: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.45),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  hintText: widget.runtimeControls != null
                      ? '发消息，让数字员工帮你处理文件、制作内容或编程...'
                      : '输入消息...',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (rich == null) return buildField(reserveSendArea: true);
    return RichDraftBlocksView(
      controller: rich,
      activeTextFieldBuilder: buildField,
      onFocusTrailingText: _focusEditorTail,
      textTrailingPadding: 58,
    );
  }
}

class _InsertNewLineIntent extends Intent {
  const _InsertNewLineIntent();
}

/// 输入框内部展示的"已选技能"小标签：浅紫底 + 关闭按钮。
/// 与 conversations.html 的 `.chat-skill-tag` 视觉对齐。
class _SelectedSkillTag extends StatelessWidget {
  const _SelectedSkillTag({
    required this.label,
    required this.iconUrl,
    required this.onRemove,
  });

  final String label;
  final String iconUrl;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFEEF0FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD7DBF7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 8),
          CompactCapabilityIcon(
            iconUrl: iconUrl,
            size: 16,
            borderRadius: 4,
            fallback: const Icon(
              CupertinoIcons.sparkles,
              size: 13,
              color: Color(0xFF7079C8),
            ),
          ),
          const SizedBox(width: 5),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF4F58B8),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(6, 8, 10, 8),
                child: Icon(
                  CupertinoIcons.xmark,
                  size: 12,
                  color: Color(0xFF7079C8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IconButtonSized extends StatelessWidget {
  const IconButtonSized({super.key, required this.child, required this.size});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: size, width: size, child: child);
  }
}

class _ComposerToolBar extends StatelessWidget {
  const _ComposerToolBar({
    required this.onPickEmoji,
    required this.onUpload,
    required this.onPickFromDrive,
    required this.onOpenAppPlaza,
    required this.onVoiceCall,
    required this.voiceCallActive,
    required this.voiceCallEnabled,
    required this.onVideoCall,
    required this.videoCallActive,
    required this.videoCallEnabled,
    required this.onComingSoon,
  });

  final VoidCallback onPickEmoji;
  final VoidCallback onUpload;
  final VoidCallback onPickFromDrive;
  final VoidCallback onOpenAppPlaza;
  final VoidCallback? onVoiceCall;
  final bool voiceCallActive;
  final bool voiceCallEnabled;
  final VoidCallback? onVideoCall;
  final bool videoCallActive;
  final bool videoCallEnabled;
  final VoidCallback onComingSoon;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      _ComposerToolButton(
        icon: CupertinoIcons.smiley,
        label: '表情',
        tooltip: '表情',
        onTap: onPickEmoji,
      ),
      _ComposerToolButton(
        icon: CupertinoIcons.tray_arrow_up,
        label: '文件',
        tooltip: '文件',
        onTap: onUpload,
      ),
      _ComposerToolButton(
        icon: CupertinoIcons.doc_text,
        label: '云盘',
        tooltip: '云盘',
        onTap: onPickFromDrive,
      ),
      _ComposerToolButton(
        icon: CupertinoIcons.square_grid_2x2,
        label: '应用',
        tooltip: '应用',
        onTap: onOpenAppPlaza,
      ),
      _ComposerToolButton(
        icon: CupertinoIcons.phone,
        label: '通话',
        tooltip: voiceCallActive ? '挂断语音' : '语音通话',
        enabled: voiceCallEnabled && onVoiceCall != null,
        active: voiceCallActive,
        onTap: (voiceCallEnabled && onVoiceCall != null)
            ? onVoiceCall!
            : onComingSoon,
      ),
      // Phase B：人↔人 1v1 视频通话入口。有 onVideoCall 回调 → 启用「视频」；
      // 否则保持「会议」置灰预留（敬请期待）。
      _ComposerToolButton(
        icon: CupertinoIcons.video_camera,
        label: onVideoCall != null ? '视频' : '会议',
        tooltip: videoCallActive ? '挂断视频' : '视频通话',
        enabled: videoCallEnabled && onVideoCall != null,
        active: videoCallActive,
        onTap: (videoCallEnabled && onVideoCall != null)
            ? onVideoCall!
            : onComingSoon,
      ),
      // 聊天历史: 原在右侧顶栏, 移到工具栏末尾 (会议之后), 切换聊天历史面板。
      const _HistoryToolButton(),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            items[i],
          ],
        ],
      ),
    );
  }
}

/// 聊天历史工具按钮: 自持有 provider 状态 (切换/高亮聊天历史面板)。
/// 原在右侧顶栏, 现移到工具栏末尾; PromptInput 是普通 StatefulWidget 拿不到 ref,
/// 故用独立 ConsumerWidget 自管, 避免穿透回调改动父链。
class _HistoryToolButton extends ConsumerWidget {
  const _HistoryToolButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var open = false;
    VoidCallback onTap = () {};
    try {
      open = ref.watch(chatHistoryPanelOpenProvider);
      onTap = () {
        final n = ref.read(chatHistoryPanelOpenProvider.notifier);
        n.state = !n.state;
      };
    } on StateError {
      // Isolated widget tests may render PromptInput without the app ProviderScope.
      // The real app always has ProviderScope; keep the button inert in isolation.
    }
    return _ComposerToolButton(
      icon: Icons.history_rounded,
      label: '聊天历史',
      tooltip: '聊天历史',
      active: open,
      onTap: onTap,
    );
  }
}

/// 输入框底部左侧工具按钮：32x32 hit area，只显示图标，hover 浅灰底圆角。
class _ComposerToolButton extends StatefulWidget {
  const _ComposerToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  /// false = 置灰预留（语音/会议本期未开发）；仍可点击，回调内提示「敬请期待」。
  final bool enabled;

  /// true = 高亮态（如聊天历史面板已打开），底色与图标用品牌色。
  final bool active;

  @override
  State<_ComposerToolButton> createState() => _ComposerToolButtonState();
}

class _ComposerToolButtonState extends State<_ComposerToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.enabled ? widget.tooltip : '${widget.tooltip}（敬请期待）',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 32,
            width: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : (_hover
                      ? UiFieldStyle.hoverFillColor(
                          Theme.of(context).colorScheme)
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Semantics(
              label: widget.label,
              button: true,
              child: Icon(
                widget.icon,
                size: 21,
                color: !widget.enabled
                    ? Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: .35)
                    : (widget.active
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
