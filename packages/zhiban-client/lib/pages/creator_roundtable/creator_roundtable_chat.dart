import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

import '../chat/widgets/chat_theme.dart';
import '../local_workspace/services/local_workspace_store.dart';
import 'creator_roundtable_controls.dart';
import 'creator_roundtable_seat_layer.dart';
import 'services/creator_expert_workflow.dart';
import 'services/creator_subtitles.dart';

typedef RoundtableModel = ({
  Map<String, Object> snapshot,
  CreatorCompletion complete
});

class RoundtableChatSession {
  String? active;
  final drafts = <String?, String>{};
  Set<String>? selected;
}

class CreatorRoundtableChat extends StatefulWidget {
  static Duration transitionDuration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260);

  const CreatorRoundtableChat(
      {super.key,
      required this.store,
      required this.creators,
      required this.resolveModel,
      this.initiallyExpanded = false,
      this.expertsOnly = false,
      this.avatarBuilder,
      this.session,
      this.stageFrame,
      this.onOpenEvidence});

  final LocalWorkspaceStore store;
  final List<LocalRow> creators;
  final Future<RoundtableModel> Function(CancelToken) resolveModel;
  final bool initiallyExpanded, expertsOnly;
  final Widget Function(LocalRow, double)? avatarBuilder;
  final RoundtableChatSession? session;
  final Rect? Function()? stageFrame;
  final ValueChanged<Map<String, dynamic>>? onOpenEvidence;

  @override
  State<CreatorRoundtableChat> createState() => _CreatorRoundtableChatState();
}

class _CreatorRoundtableChatState extends State<CreatorRoundtableChat> {
  final _question = TextEditingController();
  final _questionFocus = FocusNode();
  final _historyFilter = TextEditingController();
  final _messages = ScrollController(keepScrollOffset: false);
  final _experts = <LocalRow>[];
  final _selected = <String>{};
  late final _session = widget.session ?? RoundtableChatSession();
  Map<String?, String> get _drafts => _session.drafts;
  List<LocalRow> _chats = const [], _turns = const [];
  String? _chatId, _error, _pendingQuestion;
  Future<List<LocalRow>>? _historyMatches;
  bool _loading = true;
  late bool _expanded = widget.initiallyExpanded;
  bool _showHistory = true;
  bool _selecting = false;
  CancelToken? _running;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final chats = await widget.store.roundtableChats();
      final ready = <LocalRow>[];
      for (final creator in widget.creators) {
        final expert =
            await widget.store.latestCreatorExpert(creator['id'] as String);
        if (expert != null) {
          ready.add({
            ...expert,
            'name': creator['name'],
            'avatar_url': creator['avatar_url'],
          });
        }
      }
      final active = _session.active;
      final id = chats.any((row) => row['id'] == active) ? active : null;
      final turns =
          id == null ? <LocalRow>[] : await widget.store.roundtableTurns(id);
      if (!mounted) return;
      _question.text = _drafts[id] ?? '';
      setState(() {
        _chats = chats;
        _chatId = id;
        _turns = turns;
        _experts.addAll(ready);
        _selected.addAll(ready
            .map((expert) => expert['id'] as String)
            .where((id) => _session.selected?.contains(id) ?? true));
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本地专家和对话。');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _showLatestMessages();
        _focusQuestionAfterLayout();
      }
    }
  }

  void _focusQuestionAfterLayout() {
    if (widget.expertsOnly || _experts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_loading &&
          _running == null &&
          ModalRoute.of(context)?.isCurrent == true) {
        _questionFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _running?.cancel();
    if (!_loading) {
      _session.active = _chatId;
      if (_running == null) _drafts[_chatId] = _question.text;
      _session.selected = _selected.toSet();
    }
    _question.dispose();
    _questionFocus.dispose();
    _historyFilter.dispose();
    _messages.dispose();
    super.dispose();
  }

  void _selectAll() {
    _selected.addAll(_experts.map((expert) => expert['id'] as String));
    _session.selected = _selected.toSet();
  }

  Future<void> _startNew() async {
    await _open(null);
    if (!mounted || _chatId != null) return;
    setState(() {
      _selectAll();
    });
  }

  Future<void> _open(String? id) async {
    if (_chatId == id || _running != null) return;
    _drafts[_chatId] = _question.text;
    setState(() {
      _selecting = false;
      _loading = true;
    });
    try {
      final turns =
          id == null ? <LocalRow>[] : await widget.store.roundtableTurns(id);
      if (!mounted) return;
      _question.text = _drafts[id] ?? '';
      setState(() {
        _chatId = id;
        _turns = turns;
        _error = null;
      });
      _showLatestMessages();
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开该会话。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete([String? itemId]) async {
    final id = itemId ?? _chatId;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
          title: const Text('删除对话'),
          content: const Text('删除此会话及其中的消息？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除')),
          ]),
    );
    if (!mounted || confirmed != true || _loading || _running != null) return;
    final index = _chats.indexWhere((row) => row['id'] == id);
    if (index < 0) return;
    final deletingActive = id == _chatId;
    setState(() => _loading = true);
    try {
      await widget.store.deleteRoundtableChat(id);
      if (!mounted) return;
      final remaining = _chats.where((row) => row['id'] != id).toList();
      _drafts.remove(id);
      setState(() {
        _chats = remaining;
        _historyMatches = _searchHistory();
        if (deletingActive) {
          _chatId = null;
          _turns = [];
          _question.text = _drafts[null] ?? '';
        }
      });
      if (deletingActive && remaining.isNotEmpty) {
        final neighbor = remaining[index.clamp(0, remaining.length - 1)];
        await _open(neighbor['id'] as String);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '删除对话失败，请重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<LocalRow>>? _searchHistory() {
    final query = _historyFilter.text.trim();
    return query.isEmpty ? null : widget.store.searchRoundtableChats(query);
  }

  Future<void> _send() async {
    final draft = _question.text;
    final question = draft.trim();
    if (question.isEmpty || _loading || _running != null || _selected.isEmpty) {
      return;
    }
    final token = CancelToken();
    final chatId = _chatId;
    String? savedChatId;
    _drafts[chatId] = draft;
    setState(() {
      _running = token;
      _question.clear();
      _pendingQuestion = question;
      _selecting = false;
      _error = null;
    });
    _showLatestMessages();
    try {
      final experts =
          _experts.where((expert) => _selected.contains(expert['id'])).toList();
      final introduction = roundtableIntroduction(question, experts);
      final List<Map<String, Object>> replies;
      final Map<String, Object> modelSnapshot;
      if (introduction != null) {
        replies = introduction;
        modelSnapshot = const {'source': 'local'};
      } else {
        final model = await widget.resolveModel(token);
        modelSnapshot = model.snapshot;
        replies = await answerCreatorRoundtable(
          question: question,
          complete: model.complete,
          experts: experts,
          context: _turns.reversed.take(6).toList().reversed.map((turn) {
            final content = turn['content'] as String;
            return '${turn['role']}: ${String.fromCharCodes(content.runes.take(1200))}';
          }).toList(),
        );
      }
      if (!mounted || token.isCancelled) return;
      final id = await widget.store.saveRoundtableExchange(
          chatId: chatId,
          question: question,
          replies: replies,
          model: modelSnapshot);
      savedChatId = id;
      if (_drafts[chatId] == draft) _drafts.remove(chatId);
      final chats = await widget.store.roundtableChats();
      final turns = await widget.store.roundtableTurns(id);
      if (!mounted) return;
      final followReply =
          !_messages.hasClients || _messages.position.extentAfter < 48;
      setState(() {
        _chatId = id;
        _pendingQuestion = null;
        _chats = chats;
        _historyMatches = _searchHistory();
        _turns = turns;
      });
      if (followReply) _showLatestMessages();
    } catch (error) {
      if (mounted) {
        setState(() {
          if (savedChatId != null) {
            _chatId = savedChatId;
            _error = '本轮已保存，重新打开对话可查看回复。';
          } else {
            _question.value = TextEditingValue(
              text: draft,
              selection: TextSelection.collapsed(offset: draft.length),
            );
            _error = error is CreatorWorkflowException
                ? error.message
                : '回答生成失败，请检查所选模型后重试。';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = null;
          _pendingQuestion = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) =>
            _buildPanel(context, constraints.biggest),
      );

  Widget _buildPanel(BuildContext context, Size viewport) {
    final enabled = !_loading && _running == null;
    final window = Offset.zero & viewport;
    final visibleStage = widget.stageFrame?.call()?.intersect(window);
    final frame =
        visibleStage == null || visibleStage.isEmpty ? window : visibleStage;
    final ratio = creatorRoundtableSceneSize.aspectRatio;
    final sceneSize = frame.size.aspectRatio > ratio
        ? Size(frame.height * ratio, frame.height)
        : Size(frame.width, frame.width / ratio);
    final scene = Rect.fromLTWH(frame.center.dx - sceneSize.width / 2,
        frame.top, sceneSize.width, sceneSize.height);
    final wide = frame.width >= 690;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final historyVisible = _expanded && _showHistory && wide;
    const toolbarVerticalPadding = 8.0;
    final duration = CreatorRoundtableChat.transitionDuration(context);
    if (widget.expertsOnly) {
      return Dialog(
        alignment: wide ? const Alignment(-.36, 1) : Alignment.bottomCenter,
        insetPadding: const EdgeInsets.fromLTRB(12, 12, 12, 76),
        insetAnimationDuration: duration,
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: SizedBox(
          width: 326,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 270),
            child: _expertPicker(enabled),
          ),
        ),
      );
    }
    final panelBounds = (_expanded ? frame : scene).deflate(12);
    return Dialog(
      insetAnimationDuration: duration,
      alignment: _expanded ? Alignment.center : Alignment.bottomCenter,
      insetPadding: EdgeInsets.fromLTRB(
        panelBounds.left.clamp(0.0, viewport.width),
        panelBounds.top.clamp(0.0, viewport.height),
        (viewport.width - panelBounds.right).clamp(0.0, viewport.width),
        (viewport.height - panelBounds.bottom).clamp(0.0, viewport.height),
      ),
      backgroundColor: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        key: const ValueKey('roundtable-chat-panel'),
        width:
            _expanded ? frame.width : (scene.width * .84).clamp(600.0, 1060.0),
        height:
            _expanded ? frame.height : (scene.height * .72).clamp(350.0, 540.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (historyVisible) ...[
                        SizedBox(width: 220, child: _historyRail(enabled)),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: toolbarVerticalPadding,
                              ),
                              child: Row(
                                children: [
                                  if (_expanded && wide)
                                    UiIconButton(
                                      tooltip:
                                          historyVisible ? '收起对话列表' : '展开对话列表',
                                      onTap: () => setState(
                                          () => _showHistory = !_showHistory),
                                      icon: CupertinoIcons.sidebar_left,
                                    ),
                                  Expanded(
                                    child: historyVisible
                                        ? Text(_chatTitle,
                                            style: theme.textTheme.titleSmall,
                                            overflow: TextOverflow.ellipsis)
                                        : Row(
                                            children: [
                                              Flexible(
                                                child: ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                          maxWidth: 176),
                                                  child: UiSelect<String>(
                                                    key: const ValueKey(
                                                        'roundtable-chat-history-select'),
                                                    height:
                                                        roundtableControlHeight,
                                                    menuMaxHeight: 216,
                                                    placeholder: '新对话',
                                                    value: _chatId,
                                                    enabled: enabled &&
                                                        _chats.isNotEmpty,
                                                    options: [
                                                      for (final chat in _chats)
                                                        UiSelectOption(
                                                          value: chat['id']
                                                              as String,
                                                          label:
                                                              '${chat['title']}',
                                                        ),
                                                    ],
                                                    onChanged: _open,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              UiIconButton(
                                                tooltip: '开启新对话',
                                                onTap:
                                                    enabled ? _startNew : null,
                                                icon: CupertinoIcons.pencil,
                                              ),
                                            ],
                                          ),
                                  ),
                                  if (_chatId != null)
                                    UiIconButton(
                                      tooltip: '删除对话',
                                      onTap: enabled ? _delete : null,
                                      icon: CupertinoIcons.trash,
                                    ),
                                  if (_expanded)
                                    UiIconButton(
                                      tooltip: '收起对话',
                                      onTap: () => Navigator.pop(context),
                                      icon: CupertinoIcons.chevron_down,
                                    ),
                                  UiIconButton(
                                    tooltip: _expanded ? '退出全屏对话' : '关闭',
                                    onTap: _expanded
                                        ? () {
                                            setState(() => _expanded = false);
                                            _focusQuestionAfterLayout();
                                          }
                                        : () => Navigator.pop(context),
                                    icon: _expanded
                                        ? CupertinoIcons.fullscreen_exit
                                        : CupertinoIcons.xmark,
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: _messageHistory(),
                            ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(_error!,
                                    style: TextStyle(color: scheme.error)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      RoundtableExpertControl(
                        key: const ValueKey('roundtable-chat-experts'),
                        experts: _experts
                            .where((expert) => _selected.contains(expert['id']))
                            .toList(),
                        avatarBuilder: widget.avatarBuilder,
                        onPressed: enabled && _experts.isNotEmpty
                            ? () => setState(() {
                                  _selecting = !_selecting;
                                })
                            : null,
                      ),
                      const SizedBox(width: roundtableComposerGap),
                      Expanded(
                        child: UiInputField(
                          key: const ValueKey('roundtable-chat-question'),
                          height: roundtableControlHeight,
                          borderRadius: roundtableControlRadius,
                          controller: _question,
                          focusNode: _questionFocus,
                          enabled: enabled && _experts.isNotEmpty,
                          maxLength: 2000,
                          hintText: roundtableQuestionHint,
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: roundtableComposerGap),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _question,
                        builder: (context, value, child) {
                          final canSend = enabled &&
                              _selected.isNotEmpty &&
                              value.text.trim().isNotEmpty;
                          return IconButton(
                            style: roundtableIconControlStyle,
                            tooltip: '发送',
                            onPressed: canSend ? _send : null,
                            icon: Ink(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: canSend
                                    ? scheme.primary
                                    : scheme.onSurface.withValues(alpha: .12),
                              ),
                              child: Icon(
                                Icons.send_rounded,
                                size: 15,
                                color: canSend
                                    ? scheme.onPrimary
                                    : scheme.onSurface.withValues(alpha: .38),
                              ),
                            ),
                          );
                        },
                      ),
                      if (!_expanded) ...[
                        const SizedBox(width: roundtableComposerGap),
                        UiIconButton(
                          tooltip: '放大对话',
                          onTap: () {
                            setState(() {
                              _expanded = true;
                            });
                            _focusQuestionAfterLayout();
                          },
                          icon: CupertinoIcons.fullscreen,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (_selecting)
              Positioned(
                bottom: 62,
                left: 10,
                width: viewport.width < 346 ? viewport.width - 44 : 300,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: _expertPicker(enabled),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String get _chatTitle =>
      '${_chats.where((chat) => chat['id'] == _chatId).firstOrNull?['title'] ?? '新对话'}';

  Widget _historyRail(bool enabled) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text('对话列表', style: theme.textTheme.titleSmall)),
              UiIconButton(
                tooltip: '开启新对话',
                onTap: enabled ? _startNew : null,
                icon: CupertinoIcons.pencil,
              ),
            ]),
            TextField(
              key: const ValueKey('roundtable-history-search'),
              controller: _historyFilter,
              decoration: const InputDecoration(
                hintText: '搜索对话标题或内容',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                final matches = _searchHistory();
                setState(() {
                  _historyMatches = matches;
                });
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<LocalRow>>(
                future: _historyMatches,
                builder: (context, state) {
                  if (state.hasError) {
                    return const Center(child: Text('无法搜索对话'));
                  }
                  if (_historyMatches != null &&
                      state.connectionState == ConnectionState.waiting) {
                    return const Center(child: Text('正在搜索…'));
                  }
                  final visible =
                      _historyMatches == null ? _chats : state.data ?? [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('最近对话 · ${visible.length}',
                          style: theme.textTheme.labelSmall),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final chat in visible)
                              ListTile(
                                visualDensity: VisualDensity.compact,
                                selectedTileColor:
                                    theme.colorScheme.primaryContainer,
                                selected: chat['id'] == _chatId,
                                title: Text('${chat['title']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                onTap: enabled
                                    ? () => _open(chat['id'] as String)
                                    : null,
                                trailing: UiIconButton(
                                  tooltip: '删除「${chat['title']}」',
                                  onTap: enabled
                                      ? () => _delete(chat['id'] as String)
                                      : null,
                                  icon: CupertinoIcons.trash,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _expertPicker(bool enabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hover = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return scheme.onSurface.withValues(alpha: .12);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return scheme.onSurface.withValues(alpha: .07);
      }
      return null;
    });
    final foreground = WidgetStateProperty.resolveWith<Color?>((states) =>
        states.contains(WidgetState.disabled)
            ? scheme.onSurface.withValues(alpha: .38)
            : scheme.onSurfaceVariant);
    final textAction = roundtableTextControlStyle.copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
      fixedSize: const WidgetStatePropertyAll(Size.fromHeight(28)),
      padding:
          const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      foregroundColor: foreground,
      overlayColor: hover,
    );
    return Material(
      elevation: 4,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(
              title: '选择专家',
              onClose: widget.expertsOnly ? () => Navigator.pop(context) : null,
              trailing: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${_selected.length} 位',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 6),
                  TextButton(
                    style: textAction,
                    onPressed: enabled && _selected.length < _experts.length
                        ? () => setState(_selectAll)
                        : null,
                    child: const Text('全选'),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    style: textAction,
                    onPressed: enabled && _selected.isNotEmpty
                        ? () => setState(() {
                              _selected.clear();
                              _session.selected = <String>{};
                            })
                        : null,
                    child: const Text('清空'),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_experts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error ?? '暂无可用专家，请先在博主详情生成专家。'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final expert in _experts)
                      _expertPickerRow(expert, enabled),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text('修改只影响下一条消息。',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _expertPickerRow(LocalRow expert, bool enabled) {
    final id = expert['id'] as String;
    final selected = _selected.contains(id);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        checked: selected,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          minTileHeight: 40,
          horizontalTitleGap: 8,
          minLeadingWidth: 26,
          leading: widget.avatarBuilder?.call(expert, 26),
          title: Text('${expert['name']}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          titleTextStyle: Theme.of(context).textTheme.bodyMedium,
          selected: selected,
          selectedColor: scheme.onSurface,
          selectedTileColor: Color.alphaBlend(
              scheme.primary.withValues(alpha: .09), scheme.surface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
            side: selected
                ? BorderSide(color: scheme.primary.withValues(alpha: .22))
                : BorderSide.none,
          ),
          trailing: SizedBox.square(
            dimension: 18,
            child: selected
                ? Icon(Icons.check_rounded, color: scheme.primary, size: 16)
                : null,
          ),
          onTap: enabled
              ? () => setState(() {
                    if (selected) {
                      _selected.remove(id);
                    } else {
                      _selected.add(id);
                    }
                    _session.selected = _selected.toSet();
                  })
              : null,
        ),
      ),
    );
  }

  void _showLatestMessages() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messages.hasClients) return;
      final position = _messages.position;
      if (position.hasContentDimensions && position.extentAfter > 0) {
        _messages.jumpTo(position.maxScrollExtent);
      }
    });
  }

  List<({String id, String name, String topic})> _suggestedQuestions() {
    final topicsByExpert = <({String id, String name, List<String> topics})>[];
    for (final expert in _experts) {
      final id = expert['id'] as String;
      if (!_selected.contains(id) || expert['content'] is! String) continue;
      final Object? content;
      try {
        content = jsonDecode(expert['content'] as String);
      } on FormatException {
        continue;
      }
      if (content is! Map || content['methods'] is! List) continue;
      final topics = (content['methods'] as List)
          .whereType<Map>()
          .map((method) => method['problem'])
          .whereType<String>()
          .map((problem) => problem.trim())
          .where((problem) => problem.isNotEmpty && problem.length <= 120)
          .toSet()
          .take(2)
          .toList();
      if (topics.isNotEmpty) {
        topicsByExpert.add((id: id, name: '${expert['name']}', topics: topics));
      }
    }
    return [
      for (var index = 0; index < 2; index++)
        for (final expert in topicsByExpert)
          if (index < expert.topics.length)
            (id: expert.id, name: expert.name, topic: expert.topics[index]),
    ].take(4).toList();
  }

  Widget? _questionSuggestions() {
    final suggestions = _suggestedQuestions();
    if (suggestions.isEmpty) return null;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final topicHeight = textScaler.scale(13) * 2.8;
    final cardHeight = textScaler.scale(11) * 1.4 + topicHeight + 24;
    const gap = 8.0;
    final cardStyle = roundtableTextControlStyle.copyWith(
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 9)),
      alignment: Alignment.centerLeft,
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurfaceVariant
            : scheme.onSurface,
      ),
      backgroundColor: WidgetStatePropertyAll(
        Color.alphaBlend(scheme.primary.withValues(alpha: .08), scheme.surface),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused) ||
                states.contains(WidgetState.pressed)
            ? scheme.onSurface.withValues(alpha: .08)
            : states.contains(WidgetState.hovered)
                ? scheme.onSurface.withValues(alpha: .04)
                : Colors.transparent,
      ),
      side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
    );
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: suggestions.length == 1 ? 300 : 520),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 420;
            final cardWidth = twoColumns
                ? (constraints.maxWidth - gap) / 2
                : constraints.maxWidth;
            return ValueListenableBuilder<TextEditingValue>(
              valueListenable: _question,
              builder: (context, draft, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('建议提问',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: gap),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final suggestion in suggestions)
                        SizedBox(
                          width: cardWidth,
                          height: cardHeight,
                          child: OutlinedButton(
                            style: cardStyle,
                            onPressed: draft.text.isNotEmpty || _running != null
                                ? null
                                : () => _fillSuggestedQuestion(
                                    suggestion.id, suggestion.topic),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(suggestion.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11,
                                        height: 1.4,
                                        color: scheme.onSurfaceVariant)),
                                const SizedBox(height: 4),
                                SizedBox(
                                  height: topicHeight,
                                  child: Text(suggestion.topic,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13, height: 1.4)),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _fillSuggestedQuestion(String expertId, String topic) {
    final question = '请结合你的作品讲讲：$topic';
    setState(() {
      _selected
        ..clear()
        ..add(expertId);
      _session.selected = _selected.toSet();
      _selecting = false;
      _question.value = TextEditingValue(
        text: question,
        selection: TextSelection.collapsed(offset: question.length),
      );
    });
    _questionFocus.requestFocus();
  }

  Widget _messageHistory() {
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final pending = _pendingQuestion;
    if (_turns.isEmpty && pending == null) {
      final suggestions = _questionSuggestions();
      return Center(
        child: suggestions == null
            ? Text(_experts.isEmpty
                ? '请先在博主详情生成专家。'
                : _selected.isEmpty
                    ? '选择专家后开始提问。'
                    : '你好，今天想和圆桌专家聊些什么？')
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: suggestions,
              ),
      );
    }
    final latestReplies =
        _turns.reversed.takeWhile((turn) => turn['role'] == 'assistant');
    final followUp = pending == null &&
            latestReplies.isNotEmpty &&
            latestReplies.every((turn) => turn['evidence'] == '[]')
        ? _questionSuggestions()
        : null;

    return SingleChildScrollView(
      key: const ValueKey('roundtable-chat-messages'),
      controller: _messages,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final turn in _turns) _message(turn),
          if (followUp != null)
            Padding(
              padding: const EdgeInsets.only(left: 36, bottom: 6),
              child: followUp,
            ),
          if (pending != null) ...[
            _message({'role': 'user', 'content': pending}),
            Semantics(
              liveRegion: true,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    CupertinoActivityIndicator(),
                    SizedBox(width: 8),
                    Text('专家正在回答…'),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _message(LocalRow turn) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final messageStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.5);
    final bubbleRadius = BorderRadius.circular(10);
    const bubblePadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    if (turn['role'] == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 530),
          margin: const EdgeInsets.only(bottom: 14, left: 36),
          padding: bubblePadding,
          decoration: BoxDecoration(
            color: dark ? scheme.primaryContainer : ChatTheme.wxUserBubble,
            borderRadius: bubbleRadius,
          ),
          child: SelectableText(turn['content'] as String,
              style: messageStyle?.copyWith(
                  color: dark
                      ? scheme.onPrimaryContainer
                      : ChatTheme.wxUserBubbleText)),
        ),
      );
    }
    final snapshot = jsonDecode(turn['expert_snapshot'] as String);
    final expert = snapshot is Map ? snapshot['expert'] as Map? : null;
    final sources = (jsonDecode(turn['evidence'] as String) as List)
        .whereType<Map>()
        .toList();
    final creator = widget.creators
        .where((creator) => creator['id'] == expert?['id'])
        .firstOrNull;
    final name = expert == null
        ? '圆桌总结'
        : '${expert['name']}${expert['version'] == null ? '' : ' · v${expert['version']}'}';
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14, right: 22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (creator != null && widget.avatarBuilder != null)
              widget.avatarBuilder!(creator, 28)
            else
              CircleAvatar(
                radius: 14,
                backgroundColor: scheme.surfaceContainerHigh,
                child: Icon(
                    expert == null
                        ? Icons.summarize_outlined
                        : Icons.person_outline,
                    size: 16,
                    color: scheme.onSurfaceVariant),
              ),
            const SizedBox(width: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Container(
                      key: const ValueKey('roundtable-expert-bubble'),
                      padding: bubblePadding,
                      decoration: BoxDecoration(
                        color: dark
                            ? scheme.surfaceContainerHigh
                            : ChatTheme.wxAiBubble,
                        borderRadius: bubbleRadius,
                      ),
                      child: SelectableText(turn['content'] as String,
                          style: messageStyle),
                    ),
                    if (sources.isNotEmpty)
                      _RoundtableCitations(
                        key: ValueKey(turn['id'] ?? turn),
                        sources: sources,
                        onOpenEvidence: widget.onOpenEvidence,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundtableCitations extends StatefulWidget {
  const _RoundtableCitations({
    super.key,
    required this.sources,
    required this.onOpenEvidence,
  });

  final List<Map> sources;
  final ValueChanged<Map<String, dynamic>>? onOpenEvidence;

  @override
  State<_RoundtableCitations> createState() => _RoundtableCitationsState();
}

class _RoundtableCitationsState extends State<_RoundtableCitations> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 24),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      textStyle: theme.textTheme.labelSmall,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            expanded: _expanded,
            child: TextButton(
              key: const ValueKey('roundtable-citations-toggle'),
              style: compactStyle.copyWith(
                  foregroundColor:
                      WidgetStatePropertyAll(scheme.onSurfaceVariant)),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.link, size: 12),
                  const SizedBox(width: 4),
                  Text(_expanded ? '收起引用' : '查看引用'),
                  const SizedBox(width: 4),
                  Text('${widget.sources.length}'),
                  const SizedBox(width: 4),
                  Icon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 9),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              margin: const EdgeInsets.only(left: 4, top: 2),
              padding: const EdgeInsets.only(left: 8, top: 2),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Column(
                key: const ValueKey('roundtable-citation-details'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, source) in widget.sources.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '[${index + 1}] ${creatorEvidenceLocation(source)}',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          SelectableText('${source['text']}',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                          TextButton(
                            style: compactStyle.copyWith(
                                padding: const WidgetStatePropertyAll(
                                    EdgeInsets.zero)),
                            onPressed: () => _openSource(source),
                            child: Text(widget.onOpenEvidence != null &&
                                    source['work_id'] is String
                                ? '查看归档作品'
                                : '打开原作品'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _openSource(Map source) {
    if (widget.onOpenEvidence != null && source['work_id'] is String) {
      widget.onOpenEvidence!(Map<String, dynamic>.from(source));
      return;
    }
    final url = Uri.tryParse('${source['url']}');
    if (url?.scheme == 'https' && url?.host == 'www.douyin.com') {
      launchUrl(url!, mode: LaunchMode.externalApplication);
    }
  }
}
