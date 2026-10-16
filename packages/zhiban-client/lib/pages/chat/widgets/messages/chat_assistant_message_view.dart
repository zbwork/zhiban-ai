import 'dart:async';
import 'dart:convert';

import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'chat_markdown.dart';
import 'message_bubble/components/message_bubble_file_attachments.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/widgets/copy_widget.dart';
import 'package:zhiban_ui/widgets/ui_ai_generated_label.dart';

/// 智能体消息气泡（办公协作风格）。
///
/// 视觉与 cmd/web/html/zhiban/chat.html 中 `.ai-bubble` 对齐：
/// - 左侧 40x40 头像（圆角 6px）；
/// - 白底气泡 + 1px 描边 + 4px 圆角，左上角带小三角箭头；
/// - 内部内容自上而下：执行过程时间线 → 思考块 → 正文 → 工具调用块；
/// - 完成后的耗时/积分估算在桌面 hover/focus 时显示在气泡下方。
class ChatAssistantMessageView extends StatelessWidget {
  const ChatAssistantMessageView({
    super.key,
    required this.item,
    this.maxWidth,
    this.onOpenAttachment,
    this.onStop,
    this.avatarUrl,
    this.conversationUuid,
    this.respondHandler,
  });

  final ChatAssistantMessageViewData item;
  final double? maxWidth;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  /// 保留现有调用签名供上层页面级停止入口使用；气泡内不再渲染停止按钮。
  final VoidCallback? onStop;

  /// 智能体头像 URL（左侧 40x40 显示）。
  final String? avatarUrl;

  /// ADR-0028 §4.6 — HITL `/chat/respond` 上下文。
  /// 由消息列表上层 (chat_conversation_content) 注入 state.activeConversationId。
  final String? conversationUuid;

  /// ADR-0028 §4.9 — HITL 提交回调集; null 时 [EmpBlocksView] 仍只读。
  /// 由消息列表上层从 ChatNotifier.respondToAgentMessage 包装注入。
  final EmpBlocksRespondHandler? respondHandler;

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth = maxWidth ?? 760;
    final children = <Widget>[];

    // 处理中直接展示执行进度，不再用“处理中 + 停止”重复占一行；
    // 错误仍保留明确提示，避免失败被误解为静默结束。
    if (item.isError) {
      children.add(
        _AssistantStatusBar(item: item)
      );
      if (item.deliveryNotice != null ||
          item.failureMessage?.trim().isNotEmpty == true) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            item.deliveryNotice ?? item.failureMessage!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        ));
      }
    }

    if (item.files.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: MessageBubbleFileAttachments(
            files: item.files,
            onOpenAttachment: onOpenAttachment,
            alignment: CrossAxisAlignment.start,
          ),
        ),
      );
    }

    // 是否已经开始流式输出最终回答正文。"已开始"的判定：item.blocks 里出现
    // 任意非空 text 块。一旦开始，_TimelinePanel 自动从 "思考中…(展开)"
    // 切到 "已完成思考(折叠)"，与微信/ChatGPT 设计稿一致。
    final hasResponseText = item.blocks.any(
      (b) => b is ChatAssistantTextBlock && b.content.trim().isNotEmpty,
    );
    // phase=in_progress 产生的通用 thinking 只是“本轮已开始”的占位信号，
    // 不能单独遮掉等待阶段梯。只有 runtime 发来 reasoning / stage / tool /
    // generating，才说明已经有值得展示的真实执行过程。
    final hasMeaningfulTimeline = item.timelineEntries.any(
      (e) =>
          e.kind == ChatTimelineKind.reasoning ||
          e.kind == ChatTimelineKind.stage ||
          e.kind == ChatTimelineKind.tool ||
          e.kind == ChatTimelineKind.generating,
    );
    // main 68b15f0c：停止态（用户点停/运行被终止）。无可见过程时间线时用
    // 独立的「已停止」状态行兜底展示（门控用 hasMeaningfulTimeline——通用
    // thinking 占位不算可见过程，thinking-only 被停止的轮次也要有着落）。
    final isStopped = item.agentMessageStatus == 'cancelled' ||
        item.timelineEntries.any(
          (entry) =>
              entry.kind == ChatTimelineKind.stopped ||
              entry.status == ChatTimelineStatus.stopped,
        );

    // 「思考中… / 已完成思考」折叠块：放在最终回答正文之前，
    // 让用户先看到 agent 正在做什么、做完了什么，再读最终结论。
    // _TimelinePanel 会在 entries 没有可展示项（仅 lifecycle / usage / done 等噪音）
    // 时自动返回 SizedBox.shrink，不占空间。
    if (hasMeaningfulTimeline) {
      children.add(_TimelinePanel(
        entries: item.timelineEntries,
        hasResponseText: hasResponseText,
        streamActive: item.isLoading,
      ));
      // 时间线行都已结束、正文还没流出的静默期（LLM 生成中）：追加 shimmer
      // 「正在生成回复…」。baigong 侧文字阶段梯已默认关（BAIGONG_PROGRESS_TEXT），
      // 过程指示统一由客户端原生渲染。
      final hasRunningEntry = item.timelineEntries.any((e) => e.isRunning);
      if (item.isLoading && !hasResponseText && !hasRunningEntry) {
        children.add(
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _Shimmer(
                enabled: true,
                child: Text(
                  '正在生成回复…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    if (isStopped && !hasMeaningfulTimeline) {
      children.add(const _StoppedStatus());
    }

    for (final block in item.blocks) {
      switch (block.kind) {
        case ChatAssistantBlockKind.text:
          final textBlock = block as ChatAssistantTextBlock;
          if (textBlock.content.trim().isNotEmpty) {
            children.add(
              ChatSelectableSurface(
                child: ChatMarkdownWidget(
                  content: textBlock.content,
                  compact: true,
                  selectable: false,
                ),
              ),
            );
          }
          break;
        case ChatAssistantBlockKind.reasoning:
          children.add(
            _ReasoningBlock(block: block as ChatAssistantReasoningBlock),
          );
          break;
        case ChatAssistantBlockKind.toolCall:
          children.add(
            _ToolCallBlock(block: block as ChatAssistantToolCallBlock),
          );
          break;
        case ChatAssistantBlockKind.other:
          children.add(
            _OtherBlock(block: block as ChatAssistantOtherBlock)
          );
          break;
        case ChatAssistantBlockKind.empBlocks:
          final empBlock = block as ChatAssistantEmpBlocksBlock;
          children.add(
            EmpBlocksView(
              blocks: empBlock.blocks,
              agentMessageStatus: item.agentMessageStatus,
              agentMessageUuid: item.messageId,
              conversationUuid: conversationUuid,
              respondHandler: respondHandler,
            ),
          );
          break;
      }
    }

    // 处理中但气泡里既没工具时间线也没正文（OpenClaw prep stages 30~50s 静默期），
    // 显示“思考中...”预留，避免白板。第一帧到达后 timeline / blocks 把它顶下去。
    final hasNonStatusContent = hasMeaningfulTimeline ||
        item.blocks.any((b) =>
            b is! ChatAssistantTextBlock || b.content.trim().isNotEmpty) ||
        item.files.isNotEmpty;
    if (item.isLoading && !hasNonStatusContent) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _SparkleWaiting(startedAt: item.streamStartedAt),
        ),
      );
    }

    final hasGeneratedContent = item.files.isNotEmpty ||
        item.blocks.any((block) =>
            block is ChatAssistantEmpBlocksBlock && block.blocks.isNotEmpty) ||
        (hasResponseText &&
            (!item.isError ||
                item.failureMessage != null ||
                item.deliveryNotice != null));
    if (!item.isLoading && hasGeneratedContent) {
      children.add(const UiAiGeneratedLabel());
    }

    // 完成后才显示底部操作条；流式生成中不出现，避免抢戏。
    final showActions = !item.isLoading && children.isNotEmpty;

    final hasEmpBlocks = item.blocks.any(
      (b) => b.kind == ChatAssistantBlockKind.empBlocks,
    );
    // 人↔agent agent 回复右键菜单:本轮只承诺本地可执行项 —— 复制整条回复文本,
    // 与底部复制按钮 (assistantPlainText) 结果一致。内容为空时不显示「复制」。
    final copyText = assistantPlainText(item);
    final localActions = <ChatLocalMenuItem>[
      if (copyText.isNotEmpty)
        ChatLocalMenuItem(
          icon: CupertinoIcons.doc_on_doc,
          label: '复制',
          isCopy: true,
          onSelected: () {
            // ignore: discarded_futures
            copyChatMessageText(copyText);
          },
        ),
    ];
    final bubbleContent = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxBubbleWidth, minWidth: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ChatLocalMessageActionRegion(
            items: localActions,
            child: _AiBubbleShell(
              // 不整体包 ChatSelectableSurface:markdown 正文块已经各自单独
              // 包了(见上面 for 循环里的 text case),EmpBlocksView / 推理 /
              // 工具调用块有自己的交互(展开折叠、表单按钮),包在永久
              // IgnorePointer 的选中区域里会被一起挡住。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children:
                    children.isEmpty ? const [_SparkleWaiting()] : children,
              ),
            ),
          ),
        ],
      ),
    );
    final hoverMeta = _AssistantMessageHoverMeta(
      item: item,
      alwaysVisible: PlatformUtils.isMobile,
      actions: showActions ? _AssistantActionBar(item: item) : null,
      child: bubbleContent,
    );
    final bubbleWithMeta = hasEmpBlocks
        // EMP rich blocks contain charts/forms/tables with their own intrinsic
        // constraints. Wrapping them in IntrinsicWidth can leave RenderBox
        // without a size in the real chat scroll tree, which then breaks hit
        // testing for the whole page. Keep the hover container constrained to
        // the same max width as the EMP bubble so its footer cannot align to
        // the wider message track. Plain bubbles share their intrinsic width.
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: hoverMeta,
          )
        : IntrinsicWidth(child: hoverMeta);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: bubbleWithMeta
      ),
    );
  }
}

/// 智能体气泡下方的灰色操作条：点赞 / 点踩 / 复制 / 重新回答。
///
/// 只展示视觉反馈；按钮尺寸与 tooltip 统一走 [OptionWrapper] / [CopyWidget]。
/// 真正的反馈接口在 host 层面对接，这里保持纯 UI 层。
/// 把 assistant 气泡内可见 block 摊平成纯文本(底部复制按钮 + 右键「复制」共用,
/// 保证两条路径复制结果一致)。
///  - TextBlock 保留原 content 行为 (markdown / plain 字面);
///  - EmpBlocksBlock 走 [empBlocksToReadableText] 一行/多行只读 fallback 文本
///    (markdown 原样 + typed 富 block 走 "[图表] ..."、"[审批] ..." 等);
///  - 多种 block 混排时用空行拼接, 保持顺序与气泡渲染一致;
///  - reasoning / toolCall / other block 不进复制 (与旧行为一致, 那些是过程附属信息)。
String assistantPlainText(ChatAssistantMessageViewData item) {
  final buf = StringBuffer();
  for (final block in item.blocks) {
    String? piece;
    if (block is ChatAssistantTextBlock) {
      piece = block.content;
    } else if (block is ChatAssistantEmpBlocksBlock) {
      piece = empBlocksToReadableText(block.blocks);
    }
    if (piece == null) continue;
    final trimmed = piece.trim();
    if (trimmed.isEmpty) continue;
    if (buf.isNotEmpty) buf.write('\n\n');
    buf.write(trimmed);
  }
  return buf.toString().trim();
}

class _AssistantActionBar extends StatelessWidget {
  const _AssistantActionBar({required this.item});

  final ChatAssistantMessageViewData item;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      // 底部操作按钮之间保留统一间距，按钮自身尺寸仍复用标准组件。
      spacing: 8,
      children: [
        CopyWidget(content: assistantPlainText(item), iconSize: 14)
      ],
    );
  }
}

/// 完成消息的次要元信息：桌面在整条消息 hover/focus 后出现，移动端常显。
/// MouseRegion 包住气泡和 footer，因此指针从正文移到指标上时不会提前消失。
class _AssistantMessageHoverMeta extends StatefulWidget {
  const _AssistantMessageHoverMeta({
    required this.item,
    required this.alwaysVisible,
    this.actions,
    required this.child,
  });

  final ChatAssistantMessageViewData item;
  final bool alwaysVisible;

  /// 复制按钮插槽(null = 不展示)——与耗时/积分 meta 同一行,复制不受 hover
  /// 门控,meta 桌面端仍要 hover/focus 才出现。
  final Widget? actions;
  final Widget child;

  @override
  State<_AssistantMessageHoverMeta> createState() =>
      _AssistantMessageHoverMetaState();
}

class _AssistantMessageHoverMetaState
    extends State<_AssistantMessageHoverMeta> {
  bool _hovered = false;
  bool _focused = false;

  Duration? get _elapsed {
    final start = widget.item.streamStartedAt;
    final end = widget.item.streamEndedAt;
    if (start == null || end == null || end.isBefore(start)) return null;
    return end.difference(start);
  }

  ChatTokenUsage? get _billableUsage {
    final usage = widget.item.tokenUsage;
    return usage != null && usage.hasBillableBreakdown ? usage : null;
  }

  bool get _hasMeta =>
      !widget.item.isLoading &&
      !widget.item.isError &&
      (_elapsed != null || _billableUsage != null);

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsed;
    final usage = _billableUsage;
    final showMeta = _hasMeta && (widget.alwaysVisible || _hovered || _focused);
    final semantics = <String>[
      if (elapsed != null) '耗时 ${formatAssistantElapsed(elapsed)}',
      if (usage != null) '消耗积分估算 ${usage.estimatedCredits}',
    ].join('，');

    return Focus(
      canRequestFocus: _hasMeta && !widget.alwaysVisible,
      skipTraversal: !_hasMeta || widget.alwaysVisible,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      child: MouseRegion(
        key: const ValueKey('assistant-message-hover-region'),
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: Semantics(
          label: semantics.isEmpty ? null : semantics,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.child,
              // 复制按钮插槽 + 耗时/积分 meta 同一行(左复制右 meta)，不再各占一行——
              // 2026-08-08 用户反馈。
              if (widget.actions != null || showMeta)
                Padding(
                  key: const ValueKey('assistant-completion-meta'),
                  padding: const EdgeInsets.only(top: 6, right: 2),
                  // spaceBetween 而不是 Spacer:这一行有的场景外层是 IntrinsicWidth
                  // (非 EMP 气泡按内容宽度收缩),Spacer(Expanded flex:1)在 intrinsic
                  // 尺寸测算里会被算成 0 宽,导致内容宽度不够、meta 挤没了甚至不显示；
                  // spaceBetween 不依赖 flex 子项的 intrinsic 宽度,同样效果更稳。
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      widget.actions ?? const SizedBox.shrink(),
                      if (showMeta)
                        _AssistantCompletionMetaRow(
                          elapsed: elapsed,
                          usage: usage,
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantCompletionMetaRow extends StatelessWidget {
  const _AssistantCompletionMetaRow({this.elapsed, this.usage});

  final Duration? elapsed;
  final ChatTokenUsage? usage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (elapsed != null)
          _AssistantMetaMetric(
            icon: Icons.schedule_outlined,
            text: formatAssistantElapsed(elapsed!),
            tooltip: '耗时',
          ),
        if (elapsed != null && usage != null) const SizedBox(width: 14),
        if (usage != null)
          _AssistantMetaMetric(
            icon: Icons.auto_awesome_outlined,
            text: '约 ${usage!.estimatedCredits} 积分',
            tooltip: '预估消耗积分',
          ),
      ],
    );
  }
}

class _AssistantMetaMetric extends StatelessWidget {
  const _AssistantMetaMetric({
    required this.icon,
    required this.text,
    required this.tooltip,
  });

  final IconData icon;
  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: false,
      verticalOffset: 8,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      decoration: BoxDecoration(
        color: const Color(0xFF2F3035),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Semantics(
        label: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: ChatTheme.usageText),
            const SizedBox(width: 4),
            Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.2,
                color: ChatTheme.usageText,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatAssistantElapsed(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 1) return '<1s';
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return '${hours}h ${remainingMinutes}m';
}

/// AI 气泡外壳：飞书式浅灰底 + 扁平 10px 圆角，不使用阴影。
class _AiBubbleShell extends StatelessWidget {
  const _AiBubbleShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('assistant-message-bubble'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: ChatTheme.wxAiBubble,
        borderRadius: BorderRadius.circular(10),
        // border: Border.all(color: ChatTheme.wxAiBubbleBorder),
        // 助手消息按产品要求去掉阴影，保持更扁平的阅读样式。
      ),
      child: child,
    );
  }
}

/// 等待第一个事件时的阶段梯（2026-07-15 用户拍板：等待期必须始终有过程感，
/// 否则静默段看着像卡死）。两级时间驱动，替代 runtime 侧已关掉的文字梯：
///   正在思考… → 1.5s → 正在处理…
/// 第二级文案 2026-08-02 用户拍板「正在处理」：中性短句，先想后干语序对、
/// 长挂十几秒不违和，也不与「正在生成回复…」撞语义（技术腔「等待模型响应」
/// 与温度系「理解你的需求」均被否）。
/// 已过的级亮绿勾，当前级 shimmer。工具帧/正文一到，外层 children 非空，本梯
/// 被真实时间线/正文替换（真实工具行 + "正在生成回复…"尾行接力）。
///
/// 阶段按 [startedAt]（消息 streamStartedAt）推导而非本地计时器状态：send
/// 响应回填 agent_message_uuid 会让消息行 key 变化、本组件被整体重建
/// （2026-07-18 实锤：梯子跑到第二级后回退重跑），重建时按真实经过时间
/// 直接恢复到应处的级。
class _SparkleWaiting extends StatefulWidget {
  const _SparkleWaiting({this.startedAt});

  final DateTime? startedAt;

  @override
  State<_SparkleWaiting> createState() => _SparkleWaitingState();
}

class _SparkleWaitingState extends State<_SparkleWaiting> {
  // 阶段文案；_stage 是当前进行到的下标（0=思考,1=处理）。
  static const _stages = ['正在思考', '正在处理'];
  static const _stageUpDelay = Duration(milliseconds: 1500);
  int _stage = 0;
  Timer? _t1;

  @override
  void initState() {
    super.initState();
    final started = widget.startedAt;
    final elapsed =
        started == null ? Duration.zero : DateTime.now().difference(started);
    if (elapsed >= _stageUpDelay) {
      _stage = 1;
      return;
    }
    // 快轮（首帧 <1.5s 到达）本梯已被替换，不会看到升级。
    _t1 = Timer(_stageUpDelay - elapsed, () {
      if (mounted) setState(() => _stage = 1);
    });
  }

  @override
  void dispose() {
    _t1?.cancel();
    super.dispose();
  }

  Widget _doneRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(width: 4),
          const Icon(
            CupertinoIcons.check_mark_circled_solid,
            size: 12,
            color: Color(0xFF10B981),
          ),
        ],
      ),
    );
  }

  Widget _shimmerRow(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: _Shimmer(
        enabled: true,
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF9CA3AF),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == 0) {
      return SizedBox(
        height: 22,
        child: Align(
          alignment: Alignment.centerLeft,
          child: _shimmerRow('${_stages[0]}…'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _stage; i++) _doneRow(_stages[i]),
        _shimmerRow('${_stages[_stage]}…'),
      ],
    );
  }
}

/// 「已停止」状态行（main 68b15f0c）：停止且无可见过程时间线时的兜底展示。
class _StoppedStatus extends StatelessWidget {
  const _StoppedStatus();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.minus_circle,
            size: 14,
            color: Color(0xFF9CA3AF)
          ),
          SizedBox(width: 5),
          Text(
            '已停止',
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

// ====================== 状态条 ======================

/// assistant bubble 顶部错误状态条。处理中直接展示时间线，完成态不展示状态条。
///
/// 配色对齐 chat.html 的 `.oc-status-chip`：
/// - error：浅红胶囊；
class _AssistantStatusBar extends StatelessWidget {
  const _AssistantStatusBar({required this.item});

  final ChatAssistantMessageViewData item;

  @override
  Widget build(BuildContext context) {
    final start = item.streamStartedAt;
    final end = item.streamEndedAt;
    final elapsed = start != null && end != null && !end.isBefore(start)
        ? end.difference(start)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: ChatTheme.statusErrorBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ChatTheme.statusErrorBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: ChatTheme.statusErrorText,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              item.deliveryNotice != null ? '已保留文件' : '出错',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ChatTheme.statusErrorText,
              ),
            ),
            if (elapsed != null) ...[
              const SizedBox(width: 4),
              Text(
                '· ${formatAssistantElapsed(elapsed)}',
                style: TextStyle(
                  fontSize: 11,
                  color: ChatTheme.statusErrorText.withValues(alpha: 0.75),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ====================== 执行过程时间线 ======================

/// 折叠面板：标题 "执行过程 · N 步"（默认展开），下方列出各执行步骤。
/// 每行带 emoji 图标 + 主标题 + 灰色用时（"0ms"/"14s"/"3m12s"），
/// tool 类型支持嵌套显示参数 / 结果。
class _TimelinePanel extends StatefulWidget {
  const _TimelinePanel({
    required this.entries,
    required this.hasResponseText,
    this.streamActive = false,
  });

  final List<ChatTimelineEntry> entries;

  /// 父级判定：assistant 的最终回答正文是否已开始流出。
  /// 一旦从 false 变 true，本 panel 自动折叠并把 header 切成 "已完成思考"。
  final bool hasResponseText;

  /// 消息仍在流式生成中。attach 回放会把 tool_call/tool_result 一起送到，
  /// 工具行"出生即完成"没有过程感——流式期挂载即 done 的工具行先显示
  /// 一小段运行态再落勾（历史回看 streamActive=false，不闪）。
  final bool streamActive;

  @override
  State<_TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<_TimelinePanel> {
  Timer? _ticker;
  // 设计稿（图 1 / 图 2）：默认整条时间线一直展开，让用户能完整看到执行流程，
  // 不再随 hasResponseText 翻转。用户可点 header 手动折叠/展开。
  bool _expanded = true;

  bool get _isStopped => widget.entries.any(
        (entry) =>
            entry.kind == ChatTimelineKind.stopped ||
            entry.status == ChatTimelineStatus.stopped,
      );

  /// 仅展示"对用户有意义"的过程：tool / thinking / reasoning / stage。
  /// 把 lifecycle / usage / done / error / stopped / idleHint 这些 wrap 类
  /// 噪音过滤掉，让面板贴近 ChatGPT 风格的"已完成思考"清单。
  ///
  /// generating（"输出回答 · N 字" + 正文尾部片段）与下方正文逐字重复，
  /// 不进时间线（2026-07-14 用户反馈：重复内容没必要显示）——纯问答轮
  /// 因此整个面板都不出现，只留正文。
  ///
  /// 按事件原始顺序展示 thinking/reasoning/stage/tool。工具出现后仍保留
  /// 前置与后置思考步骤，让用户能看到“先判断、调用工具、拿结果后继续
  /// 整理”的完整执行过程。
  List<ChatTimelineEntry> get _visibleEntries {
    return widget.entries
        .where(
          (e) =>
              e.kind == ChatTimelineKind.thinking ||
              e.kind == ChatTimelineKind.reasoning ||
              e.kind == ChatTimelineKind.stage ||
              e.kind == ChatTimelineKind.tool,
        )
        .toList(growable: false);
  }

  /// header 文案 / 计数依据：当前 message 调过的真实工具数。reasoning / thinking
  /// 不算工具。0 时回退为 thinking/reasoning 预留状态显示"思考中…/已完成思考"。
  int get _toolCount =>
      widget.entries.where((e) => e.kind == ChatTimelineKind.tool).length;

  @override
  void initState() {
    super.initState();
    _expanded = !_isStopped;
    // 设计稿（图 1 / 图 2）：默认展开整条时间线，跟正文一起渲染，不再"出正文就折叠"。
    _maybeStartTicker();
  }

  @override
  void didUpdateWidget(covariant _TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasStopped = oldWidget.entries.any(
      (entry) =>
          entry.kind == ChatTimelineKind.stopped ||
          entry.status == ChatTimelineStatus.stopped,
    );
    if (!wasStopped && _isStopped) {
      _expanded = false;
    }
    // 设计稿（图 1 / 图 2）：执行流程要一直跟正文同时可见，不再"hasResponseText
    // 自动折叠"。用户仍可手动点 header 折叠/展开（_userToggled 保留）。
    _maybeStartTicker();
  }

  void _maybeStartTicker() {
    // 即便不再展示"· 1.6s"耗时，也保留 ticker：running 状态下 header
    // 文案在「思考中…」与「已完成思考」之间切换，需要触发 rebuild 检测。
    final hasRunning = widget.entries.any((e) => e.isRunning);
    if (hasRunning && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else if (!hasRunning && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleEntries;
    if (visible.isEmpty) {
      // 只剩 lifecycle / usage / done 这种噪音 entry 时整体不显示，
      // 避免出现一个空壳子 "已完成思考"。
      return const SizedBox.shrink();
    }

    // UI 兜底：kind=stage 同一时刻只允许"最后一条 running"真正显示 spinner，
    // 其余即便 status=running 也强制按 done 渲染（绿勾）。原因：
    // 1) 后端是否按时序发 stage_done、provider 标 done 是否在 _upsertEntry 之前
    //    生效，都依赖 microtask 顺序；任何一处出问题用户就会看到"几条同时转圈"，
    //    完全失去进度感（用户截图反馈过此现象）。
    // 2) stage 的真实进度由后端按时间线推送，UI 上"前面的早就过去了"是绝对不变量，
    //    比起依赖状态机修复，直接用渲染层强约束更稳。
    String? lastRunningStageKey;
    for (final e in visible) {
      if (e.kind == ChatTimelineKind.stage && e.isRunning) {
        lastRunningStageKey = e.key;
      }
    }
    final running = widget.entries.any((e) => e.isRunning);
    final stopped = _isStopped;
    final toolCount = _toolCount;
    final hasTools = toolCount > 0;
    // 文案规则（2026-07-30 用户拍板去掉"调用"这类机械措辞）：
    //  - 有工具步骤，仍在跑 → "处理中 · N 个步骤"（N 持续累加）
    //  - 有工具步骤，已结束 → "完成 N 个步骤"
    //  - 无工具步骤，仍在跑且回答没出 → "思考中…"
    //  - 无工具步骤，已结束/正在写回答 → "已完成思考"
    final archiveStages =
        visible.where((e) => e.key == 'stage:local-archive' && e.isRunning);
    final archiveTitle = widget.streamActive && archiveStages.isNotEmpty
        ? archiveStages.last.title
        : null;
    final summary = stopped
        ? '已停止'
        : archiveTitle ??
            (hasTools
                ? (running ? '处理中 · $toolCount 个步骤' : '完成 $toolCount 个步骤')
                : ((running && !widget.hasResponseText) ? '思考中…' : '已完成思考'));

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() {
              _expanded = !_expanded;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  _Shimmer(
                    // 仅"思考中…"（无工具、正文未出）时 shimmer；其余状态静态。
                    enabled: running && !hasTools && !widget.hasResponseText,
                    child: Text(
                      summary,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 11,
                    color: const Color(0xFF9CA3AF),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < visible.length; i++)
                    _TimelineRow(
                      entry: visible[i],
                      isFirst: i == 0,
                      isLast: i == visible.length - 1,
                      forceDone: visible[i].kind == ChatTimelineKind.stage &&
                          visible[i].isRunning &&
                          visible[i].key != lastRunningStageKey,
                      streamActive: widget.streamActive,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 单行执行步骤：bullet • + 工具图标 + 中文动词式标题（"执行了命令 ..." /
/// "写入了 xxx" / "读取了 xxx" 等），与新版"已完成思考"设计稿一致。
///
/// 当 entry 带有可展开内容（toolArgs 命令 / snippet / toolResult 摘要）时，
/// 行尾出现 chevron `>`，点击在原行下方插入一个等宽字体片段。设计稿截图 2
/// 中"node ~/Library/Application\\ Support/QClaw/openclaw/co..."这类一行
/// 灰色命令预览即此形态。
class _TimelineRow extends StatefulWidget {
  const _TimelineRow({
    required this.entry,
    required this.isFirst,
    required this.isLast,
    this.forceDone = false,
    this.streamActive = false,
  });

  final ChatTimelineEntry entry;

  /// 上层 _TimelinePanel 决策：当前 entry 即便 status=running 也强制按 done 渲染。
  /// 用于多条 stage 同时 running 时只让最后一条 spinner，其余亮绿勾。
  final bool forceDone;

  /// 消息仍在流式生成中（见 _TimelinePanel.streamActive）。
  final bool streamActive;

  /// 在时间线中的位置（首/尾节点）。决定 rail 上下两段竖线是否绘制。
  final bool isFirst;
  final bool isLast;

  @override
  State<_TimelineRow> createState() => _TimelineRowState();
}

class _TimelineRowState extends State<_TimelineRow> {
  bool _expanded = false;

  /// 最短运行态（2026-07-31 真机两轮反馈）：真实检索常发生在 App 挂流之前，
  /// 回放时 tool_call/tool_result 同批（或前后脚）到达——工具行"出生即完成"
  /// 或运行态只闪一帧，没有"在干活"的过程感。流式期给运行态一个最短可见
  /// 时长兜底：不足就先保持运行态渲染，到时再落勾。两条路径都要覆盖：
  ///   ① 挂载时已 done（同批回放）；② running→done 翻转过快（前后脚到达）。
  /// 仅影响视觉徽标/时态，不改任何事件或状态语义；历史回看 streamActive
  /// =false 不生效。
  static const _minRunningVisible = Duration(milliseconds: 1000);
  bool _holdRunning = false;
  DateTime? _runningShownAt;
  Timer? _holdTimer;

  void _startHold(Duration remaining) {
    _holdRunning = true;
    _holdTimer?.cancel();
    _holdTimer = Timer(remaining, () {
      if (mounted) setState(() => _holdRunning = false);
    });
  }

  @override
  void initState() {
    super.initState();
    if (!widget.streamActive ||
        widget.forceDone ||
        widget.entry.kind != ChatTimelineKind.tool) {
      return;
    }
    if (widget.entry.status == ChatTimelineStatus.done) {
      _startHold(_minRunningVisible); // 路径①：出生即完成
    } else if (widget.entry.status == ChatTimelineStatus.running) {
      _runningShownAt = DateTime.now();
    }
  }

  @override
  void didUpdateWidget(covariant _TimelineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.streamActive ||
        widget.forceDone ||
        widget.entry.kind != ChatTimelineKind.tool) {
      return;
    }
    if (widget.entry.status == ChatTimelineStatus.running) {
      _runningShownAt ??= DateTime.now();
      return;
    }
    // 路径②：running→done 翻转，但运行态可见时长不足最短值 → 补足。
    if (oldWidget.entry.status == ChatTimelineStatus.running &&
        widget.entry.status == ChatTimelineStatus.done &&
        !_holdRunning) {
      final shown = _runningShownAt == null
          ? Duration.zero
          : DateTime.now().difference(_runningShownAt!);
      if (shown < _minRunningVisible) {
        _startHold(_minRunningVisible - shown);
      }
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  ChatTimelineEntry get entry => widget.entry;

  /// 行尾状态徽标：done=绿勾、error=红叉、stopped=灰叉、running=转圈。
  /// 与左侧工具图标 dot 解耦——dot 表"什么类型"，trailing 表"做完没"。
  Widget _trailingStatusIcon() {
    final effective = widget.forceDone
        ? ChatTimelineStatus.done
        : (_holdRunning ? ChatTimelineStatus.running : entry.status);
    switch (effective) {
      case ChatTimelineStatus.done:
        // 无底色的细对勾：结果确认即可，不抢正文（实心绿圆徽标 2026-07-30
        // 用户反馈观感突兀，弃用）。
        return const Icon(
          CupertinoIcons.checkmark,
          size: 11,
          color: Color(0xFF10B981), // emerald-500
        );
      case ChatTimelineStatus.error:
        return const Icon(
          CupertinoIcons.xmark_circle_fill,
          size: 12,
          color: Color(0xFFEF4444), // red-500
        );
      case ChatTimelineStatus.stopped:
        return const Icon(
          CupertinoIcons.minus_circle,
          size: 12,
          color: Color(0xFF9CA3AF),
        );
      case ChatTimelineStatus.running:
        // running 不放行尾图标——进行中的信号由标题文字的灰色脉冲承载
        // （对齐 Workbuddy 形态，用户拍板；转圈在 10px 量级观感发跳已弃用）。
        return const SizedBox.shrink();
    }
  }

  /// 出错 / 停止时整行变红/灰，正常和 running 都用统一深灰。
  Color _titleColor() {
    switch (entry.status) {
      case ChatTimelineStatus.error:
        return const Color(0xFFB91C1C);
      case ChatTimelineStatus.stopped:
        return const Color(0xFF9CA3AF);
      case ChatTimelineStatus.done:
      case ChatTimelineStatus.running:
        return const Color(0xFF6B7280); // 比正文轻一档，过程信息不抢正文的戏
    }
  }

  /// 把 toolArgs JSON 串里的常见字段抽出来，凑出 ChatGPT 风格的中文动词标题。
  /// 时态跟随状态（2026-07-30 用户两轮反馈定稿）：
  ///   running → "正在<动作>…"；done / error / stopped → 裸"<动作>"，
  ///   结果交给行尾徽标（绿勾/红叉/灰减号）表达——"调用了/已调用"这类
  ///   机械措辞全部去掉。
  /// 失败时（解析不动 / 不是 tool 类型）回退到原始 entry.title。
  String _displayTitle() {
    if (entry.kind != ChatTimelineKind.tool) {
      return entry.title;
    }
    final base = _toolActionPhrase();
    final effective = widget.forceDone
        ? ChatTimelineStatus.done
        : (_holdRunning ? ChatTimelineStatus.running : entry.status);
    if (effective == ChatTimelineStatus.running) {
      // 英文工具名直接拼"正在"会挤在一起，补一个空格。
      final sep = base.startsWith(RegExp(r'[A-Za-z0-9]')) ? ' ' : '';
      return '正在$sep$base…';
    }
    return base;
  }

  /// 领域工具名 → 中文动作短语。命名对齐 baigong 创业助手工具集；
  /// 未命中的走 [_toolActionPhrase] 的通用 switch / 原名兜底。
  static const Map<String, String> _domainToolPhrases = {
    'start_company_registration': '发起公司注册',
    'update_registration_info': '更新注册信息',
    'query_registration_progress': '查询办理进度',
    'view_registration_info': '查看注册信息',
    'show_registration_form': '调出注册表单',
    'check_company_name': '核查公司名',
    'start_bookkeeping_evaluation': '评估记账服务',
    'cancel_bookkeeping_service': '取消记账服务',
    'cancel_registration': '取消注册申请',
    'start_cancel_flow': '发起注销流程',
    'request_expedite': '申请加急',
    'render_chart': '生成图表',
    // 对齐 Claude Code / Codex 的记忆操作口径（2026-07-31 用户拍板）：
    // 运行态"正在写入记忆…"、完成"写入记忆 ✓"，不用"记录偏好"这类模糊说法。
    'remember_preference': '写入记忆',
    'view_startup_guide': '查阅创业指南',
    'search_knowledge': '检索知识库',
    'knowledge_search': '检索知识库',
    'kb_search': '检索知识库',
    'memory_search': '检索记忆',
  };

  /// 不带时态的动作短语（如“检查公司名”“搜索网络 "..."”），由
  /// [_displayTitle] 按状态加“正在/已”前缀。
  String _toolActionPhrase() {
    final name = (entry.toolName ?? '').toLowerCase();
    String? cmd;
    String? pathArg;
    String? urlArg;
    String? query;
    String? toAgentName;
    String? skillArg;
    final raw = entry.toolArgs ?? '';
    if (raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          cmd = (parsed['command'] ?? parsed['cmd'] ?? parsed['shell'])
              ?.toString();
          pathArg = (parsed['path'] ??
                  parsed['file'] ??
                  parsed['file_path'] ??
                  parsed['filename'])
              ?.toString();
          urlArg = (parsed['url'] ?? parsed['link'])?.toString();
          query =
              (parsed['query'] ?? parsed['q'] ?? parsed['pattern'])?.toString();
          toAgentName =
              (parsed['to_agent_name'] ?? parsed['agent_name'])?.toString();
          skillArg = (parsed['skill_name'] ??
                  parsed['skill_slug'] ??
                  parsed['name'] ??
                  parsed['slug'])
              ?.toString();
        }
      } catch (_) {
        // toolArgs 还在流式拼接中，可能是不合法 JSON 片段。下面 fallback。
      }
    }

    String shorten(String s, int maxLen) {
      final cleaned = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.length <= maxLen) return cleaned;
      return '${cleaned.substring(0, maxLen)}…';
    }

    String basename(String p) {
      final clean = p.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty);
      return clean.isEmpty ? p : clean.last;
    }

    switch (name) {
      case 'a2a.invoke':
      case 'digital_employee_collaboration':
        return toAgentName != null && toAgentName.isNotEmpty
            ? '请求 ${shorten(toAgentName, 24)} 协助'
            : '请求其他数字员工协助';
      case 'bash':
      case 'shell':
      case 'run_shell_command':
      case 'execute_command':
      case 'exec':
        return cmd != null && cmd.isNotEmpty
            ? '执行命令 ${shorten(cmd, 80)}'
            : '执行命令';
      case 'read':
      case 'read_file':
        return pathArg != null && pathArg.isNotEmpty
            ? '读取 ${basename(pathArg)}'
            : '读取文件';
      case 'write':
      case 'write_file':
      case 'create':
      case 'create_file':
        return pathArg != null && pathArg.isNotEmpty
            ? '写入 ${basename(pathArg)}'
            : '写入文件';
      case 'skill_view':
        return skillArg != null && skillArg.isNotEmpty
            ? '查看技能 ${shorten(skillArg, 40)}'
            : '查看技能';
      case 'edit':
      case 'str_replace':
      case 'replace':
      case 'patch':
        return pathArg != null && pathArg.isNotEmpty
            ? '修改 ${basename(pathArg)}'
            : '修改文件';
      case 'glob':
      case 'ls':
      case 'list_files':
        return pathArg != null && pathArg.isNotEmpty
            ? '查看目录 ${shorten(pathArg, 60)}'
            : '查看目录';
      case 'grep':
      case 'search':
      case 'search_files':
        return query != null && query.isNotEmpty
            ? '搜索 "${shorten(query, 40)}"'
            : '搜索内容';
      case 'image_generate':
        return '生成图片';
      case 'video_generate':
        return '生成视频';
      case 'web_fetch':
      case 'fetch':
        return urlArg != null && urlArg.isNotEmpty
            ? '获取网页 ${shorten(urlArg, 60)}'
            : '获取网页';
      case 'web_search':
        return query != null && query.isNotEmpty
            ? '搜索网络 "${shorten(query, 40)}"'
            : '搜索网络';
      case 'browser':
        return urlArg != null && urlArg.isNotEmpty
            ? '打开 ${shorten(urlArg, 60)}'
            : '操作浏览器';
      default:
        return _domainToolPhrases[name] ?? (entry.toolName ?? '处理中');
    }
  }

  /// 单行可展开后看到的"详情文本"。优先级：
  ///   1. tool 类型 + toolArgs 解析出 command/cmd/shell  →  完整命令字符串
  ///   2. snippet（thinking / reasoning / generating 片段）
  ///   3. toolArgs（其他 tool 的原始 args）
  ///   4. toolResult（兜底，截断后的输出摘要）
  /// 任一非空就允许展开；都为空则不显示 chevron，行只读。
  String? _detailText() {
    if (entry.kind == ChatTimelineKind.tool) {
      final raw = entry.toolArgs ?? '';
      if (raw.isNotEmpty) {
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            final cmd = (parsed['command'] ?? parsed['cmd'] ?? parsed['shell'])
                ?.toString();
            if (cmd != null && cmd.trim().isNotEmpty) return cmd.trim();
          }
        } catch (_) {
          // 流式 args 还没收齐，先用原串预览。
        }
        return raw.trim();
      }
    }
    final snip = entry.snippet?.trim();
    if (snip != null && snip.isNotEmpty) return snip;
    final res = entry.toolResult?.trim();
    if (res != null && res.isNotEmpty) return res;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detailText();
    final canExpand = detail != null && detail.isNotEmpty;
    final pulsing = !widget.forceDone &&
        (_holdRunning || entry.status == ChatTimelineStatus.running);

    // —— 标题行：rail (dot + 上下竖线) + 文本 + 状态徽标 + chevron —— //
    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(
            isFirst: widget.isFirst,
            isLast: widget.isLast
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    // Align 让 shimmer 收缩到文字实际宽度——直接包在 Expanded 里
                    // ShaderMask 会被撑到整行宽，亮带大部分时间扫在文字外（实测无感）。
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Shimmer(
                        enabled: pulsing,
                        child: Text(
                          _displayTitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            fontWeight: FontWeight.w400,
                            color: _titleColor(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _trailingStatusIcon(),
                  if (canExpand) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 11,
                      color: const Color(0xFF9CA3AF),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final rowTappable = canExpand
        ? InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() => _expanded = !_expanded),
            child: row,
          )
        : row;

    if (!canExpand || !_expanded) return rowTappable;

    // —— 展开详情：跟标题文本左缘对齐（rail 宽度 = 28），下方再缩进一点喘气。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        rowTappable,
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 2, 0, 8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              detail,
              maxLines: 8,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF6B7280),
                fontFamily: 'Menlo',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 进行中状态的灰字 shimmer：一条亮带在文字上从左到右扫过
/// （对齐 Workbuddy「等待模型响应」形态，2026-07-15 用户截图拍板）。
/// enabled=false 时零开销直接透传 child。
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  void _sync() {
    if (widget.enabled && _ctrl == null) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat();
    } else if (!widget.enabled && _ctrl != null) {
      _ctrl!.dispose();
      _ctrl = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    if (ctrl == null) return widget.child;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, child) => ShaderMask(
        shaderCallback: (bounds) {
          // 亮带位置随动画从文字左外侧滑到右外侧（srcIn 用渐变替换文字像素色）。
          final dx = bounds.width * (ctrl.value * 3 - 1.5);
          return const LinearGradient(
            colors: [
              Color(0xFF9CA3AF), // 基底灰
              Color(0xFFE5E7EB), // 扫过的亮带
              Color(0xFF9CA3AF),
            ],
            stops: [0.35, 0.5, 0.65],
          ).createShader(
            Rect.fromLTWH(dx, 0, bounds.width, bounds.height)
          );
        },
        blendMode: BlendMode.srcIn,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 时间线左侧的 28px 列：上半段竖线 + 中间 emoji 节点 + 下半段竖线。
/// 跟 [_TimelineRow] 拼成 rail + content 的两列时间线布局，对齐微信 / ChatGPT
/// 风格的"步骤流程图"。首行不画上半段、末行不画下半段，让时间线起止干净。
class _Rail extends StatelessWidget {
  const _Rail({
    required this.isFirst,
    required this.isLast
  });

  final bool isFirst;
  final bool isLast;

  static const double _railWidth = 28;
  static const double _emojiBoxSize = 16;
  static const double _dotSize = 6;
  static const double _lineGap = 3;
  static const double _rowVerticalPadding = 6;
  static const double _titleLineHeight =
      13 * 1.4; // 与 _TimelineRow 标题 fontSize 同步
  static const Color _lineColor = Color(0xFFE5E7EB); // gray-200

  @override
  Widget build(BuildContext context) {
    const nodeCenterY = _rowVerticalPadding + _titleLineHeight / 2;
    const emojiTop = nodeCenterY - _emojiBoxSize / 2;
    const upperLineHeight = emojiTop - _lineGap;
    const lowerLineTop = emojiTop + _emojiBoxSize + _lineGap;

    return SizedBox(
      width: _railWidth,
      child: Stack(
        children: [
          // 上半段竖线：停在 emoji 上方一点,避免连接线直接顶到图标。
          Positioned(
            left: (_railWidth - 2) / 2,
            top: 0,
            height: upperLineHeight,
            width: 2,
            child: ColoredBox(
              color: isFirst ? const Color(0x00000000) : _lineColor,
            ),
          ),
          // 下半段竖线：从 emoji 下方留白后继续,让节点和连线有呼吸感。
          Positioned(
            left: (_railWidth - 2) / 2,
            top: lowerLineTop,
            bottom: 0,
            width: 2,
            child: ColoredBox(
              color: isLast ? const Color(0x00000000) : _lineColor,
            ),
          ),
          // 节点用统一的中性圆点（2026-07-30 用户反馈 emoji 图标观感差且
          // 中英混排大小不一，全部去掉），中心对齐右侧标题文字的视觉中心。
          Positioned(
            left: (_railWidth - _emojiBoxSize) / 2,
            top: emojiTop,
            width: _emojiBoxSize,
            height: _emojiBoxSize,
            child: Center(
              child: Container(
                width: _dotSize,
                height: _dotSize,
                decoration: const BoxDecoration(
                  color: Color(0xFFD1D5DB), // gray-300，安静的过程节点
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ====================== 思考 / 工具调用块 ======================

class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({required this.block});

  final ChatAssistantReasoningBlock block;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  late bool _expanded = widget.block.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ChatTheme.timelineBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? CupertinoIcons.chevron_down
                        : CupertinoIcons.chevron_right,
                    size: 12,
                    color: ChatTheme.timelineMeta,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    '思考过程',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF4B5563),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                widget.block.content,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.55,
                  color: Color(0xFF4B5563),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolCallBlock extends StatelessWidget {
  const _ToolCallBlock({required this.block});

  final ChatAssistantToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (block.status) {
      ChatAssistantToolCallStatus.start => '开始调用',
      ChatAssistantToolCallStatus.argsDelta => '参数生成中',
      ChatAssistantToolCallStatus.argsDone => '参数已完成',
      ChatAssistantToolCallStatus.done => '已完成',
      ChatAssistantToolCallStatus.failed => '调用失败',
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ChatTheme.timelineBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.wrench,
                size: 12,
                color: Color(0xFF4B5563),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  block.toolName,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
              Text(
                statusLabel,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF6B7280)
                ),
              ),
            ],
          ),
          if ((block.arguments ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              block.arguments!,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF374151),
                fontFamily: 'Menlo',
              ),
            ),
          ],
          if ((block.result ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              block.result!,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF374151),
                fontFamily: 'Menlo',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OtherBlock extends StatelessWidget {
  const _OtherBlock({required this.block});

  final ChatAssistantOtherBlock block;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ChatTheme.timelineBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            block.title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4B5563),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            block.content,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }
}
