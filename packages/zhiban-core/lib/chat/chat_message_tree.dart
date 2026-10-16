import 'package:zhiban_core/emp/emp_attachment_links.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';

import 'chat_models.dart';

enum ChatConversationItemKind { pair, systemMessage, systemPrompt, welcome }

abstract class ChatConversationItem {
  const ChatConversationItem(this.kind);

  final ChatConversationItemKind kind;

  bool get isPair => kind == ChatConversationItemKind.pair;
  bool get isSystemMessage => kind == ChatConversationItemKind.systemMessage;
  bool get isSystemPrompt => kind == ChatConversationItemKind.systemPrompt;
  bool get isWelcome => kind == ChatConversationItemKind.welcome;
}

class ChatWelcomeConversationItem extends ChatConversationItem {
  const ChatWelcomeConversationItem() : super(ChatConversationItemKind.welcome);
}

class ChatPairConversationItem extends ChatConversationItem {
  const ChatPairConversationItem({
    required this.userMessage,
    required this.assistantMessage,
  }) : super(ChatConversationItemKind.pair);

  final ChatMessage? userMessage;
  final ChatAssistantMessageViewData? assistantMessage;
}

class ChatSystemConversationItem extends ChatConversationItem {
  const ChatSystemConversationItem({
    required this.content,
    required ChatConversationItemKind kind,
    this.messageId,
    this.metadata,
    this.createdAt,
  }) : super(kind);

  final String content;
  final String? messageId;

  /// F08 §8.2 #11 · 原 message 上的 metadata, 用于在 system 消息上叠加 cron chip
  /// (详 chat_system_message_view + cron_message_metadata 解析).
  final Map<String, dynamic>? metadata;

  /// 原 message created_at; cron 卡片头部右侧显示 HH:mm。
  final DateTime? createdAt;
}

enum ChatAssistantBlockKind { text, reasoning, toolCall, other, empBlocks }

abstract class ChatAssistantBlock {
  const ChatAssistantBlock(this.kind);

  final ChatAssistantBlockKind kind;
}

class ChatAssistantTextBlock extends ChatAssistantBlock {
  const ChatAssistantTextBlock({
    required this.content,
  }) : super(ChatAssistantBlockKind.text);

  final String content;
}

class ChatAssistantReasoningBlock extends ChatAssistantBlock {
  const ChatAssistantReasoningBlock({
    required this.content,
    this.initiallyExpanded = false,
  }) : super(ChatAssistantBlockKind.reasoning);

  final String content;
  final bool initiallyExpanded;
}

/// Plan 16 Batch 2 (2026-06-08) · 把 agent-bus `message.completed.blocks` (或历史
/// 接口返回的 EMP blocks) 原样塞进气泡渲染层。此 block 仅在终态出现 (流式中间态
/// 用 [ChatAssistantTextBlock] + `content`)。
///
/// `blocks` 是 `List<Map<String, dynamic>>`, 形态见 EMP registry: markdown / plain
/// / chart / form / approval / action / artifact / source / progress / app_card /
/// plan / tool_result / code / table / error / unknown 等。`EmpBlocksView` 负责真
/// 渲染; 不实现的 type 走 `empBlocksToReadableText` fallback。
///
/// 设计纪律 (Plan 16 §C 不变):
///   - 这是**只读**展示, 不暴露 form 提交 / approval 触发 / action callback;
///   - 不引入第三方依赖 (fl_chart 留 Phase 3 或单独提案);
///   - 字段类型不规范 → best-effort 回到 readable text fallback, 不抛异常;
///   - 不重复渲染 markdown content (上层在 `fromMessage` 中: 有 empBlocks 就**不**追加 TextBlock)。
class ChatAssistantEmpBlocksBlock extends ChatAssistantBlock {
  const ChatAssistantEmpBlocksBlock({required this.blocks})
      : super(ChatAssistantBlockKind.empBlocks);

  final List<Map<String, dynamic>> blocks;
}

enum ChatAssistantToolCallStatus { start, argsDelta, argsDone, done, failed }

class ChatAssistantToolCallBlock extends ChatAssistantBlock {
  const ChatAssistantToolCallBlock({
    required this.toolName,
    this.toolCallId,
    this.arguments,
    this.result,
    this.status = ChatAssistantToolCallStatus.start,
  }) : super(ChatAssistantBlockKind.toolCall);

  final String toolName;
  final String? toolCallId;
  final String? arguments;
  final String? result;
  final ChatAssistantToolCallStatus status;
}

class ChatAssistantOtherBlock extends ChatAssistantBlock {
  const ChatAssistantOtherBlock({
    required this.title,
    required this.content,
  }) : super(ChatAssistantBlockKind.other);

  final String title;
  final String content;
}

class ChatAssistantMessageViewData {
  const ChatAssistantMessageViewData({
    this.localId,
    required this.messageId,
    required this.uuid,
    required this.status,
    required this.feedback,
    required this.files,
    required this.blocks,
    this.timelineEntries = const [],
    this.failureMessage,
    this.deliveryNotice,
    this.reasoningContent = '',
    this.usageSummary,
    this.tokenUsage,
    this.streamStartedAt,
    this.streamEndedAt,
    this.agentMessageStatus,
    this.empBlocks = const <Map<String, dynamic>>[],
  });

  final String? localId;
  final String? messageId;
  final String? uuid;
  final BubbleStatus status;
  final FeedbackType feedback;
  final List<ChatFileItem> files;
  final List<ChatAssistantBlock> blocks;
  final List<ChatTimelineEntry> timelineEntries;
  final String reasoningContent;
  final String? failureMessage;
  final String? deliveryNotice;
  final String? usageSummary;
  final ChatTokenUsage? tokenUsage;
  final DateTime? streamStartedAt;
  final DateTime? streamEndedAt;

  /// Plan 16 §J / ADR-0028 — 后端 raw agent message status (例 'awaiting_user');
  /// `EmpBlocksView` 据此 4 条件 enable 富组件提交。
  final String? agentMessageStatus;

  /// 终态 EMP blocks (与 [ChatMessage.empBlocks] 同源); `EmpBlocksView` 需要原始
  /// blocks list (而非 ChatAssistantEmpBlocksBlock 包装) 以读取 approval/form/action
  /// 的字段 (actions[].id / fields[] / decision 等)。
  final List<Map<String, dynamic>> empBlocks;

  bool get isLoading => status == BubbleStatus.loading;
  bool get isError => status == BubbleStatus.error;

  factory ChatAssistantMessageViewData.fromMessage(ChatMessage message) {
    final blocks = <ChatAssistantBlock>[];
    // message.content 只含纯文本类 block(plainBlocksText 口径,见 chat_models.dart
    // fromAgentBusJson)、message.empBlocks 只含 typed 富 block(_readEmpBlocks 口径)——
    // 两者互斥取自原始 blocks 数组的不同子集,不是同一份内容的两种表示,可以且应该
    // 分开独立渲染,不是"二选一"。之前这里 empBlocks 非空就整段跳过 TextBlock,
    // 想避免"EmpBlocksView 渲染 markdown 导致双倍展示",但 EmpBlocksView 拿到的
    // message.empBlocks 本就不含 markdown/plain/text 类型的块,不存在双倍展示；
    // 二选一的后果反而是数字员工回复"介绍文字 + EMP 卡片"混排时介绍文字被吞
    // (2026-08-08 复现:只显示"操作·请选择功能"卡片,没有上面那段自我介绍)。
    final hasReadableEmpBlocks = message.empBlocks.isNotEmpty &&
        empBlocksToReadableText(message.empBlocks).trim().isNotEmpty;
    if ((message.content.isNotEmpty || message.isLoading) &&
        !(message.deliveryNotice != null &&
            message.content.trim() == message.failureMessage)) {
      final text = suppressDuplicateAttachmentLinks([
        {'type': 'markdown', 'text': message.content},
        ...message.empBlocks,
      ]).first['text'] as String;
      if (text.isNotEmpty || message.isLoading) {
        blocks.add(ChatAssistantTextBlock(content: text));
      }
    }
    if (hasReadableEmpBlocks) {
      blocks.add(ChatAssistantEmpBlocksBlock(blocks: message.empBlocks));
    }
    return ChatAssistantMessageViewData(
      localId: message.localId,
      messageId: message.messageId,
      uuid: message.uuid,
      status: message.status,
      deliveryNotice: message.deliveryNotice,
      failureMessage: message.failureMessage == message.content.trim()
          ? null
          : message.failureMessage,
      feedback: message.feedback,
      files: message.files,
      blocks: blocks,
      timelineEntries: message.timelineEntries,
      reasoningContent: message.reasoningContent,
      usageSummary: message.usageSummary,
      tokenUsage: message.tokenUsage,
      streamStartedAt: message.streamStartedAt,
      streamEndedAt: message.streamEndedAt,
      agentMessageStatus: message.agentMessageStatus,
      empBlocks: message.empBlocks,
    );
  }

  factory ChatAssistantMessageViewData.fromBlocks({
    String? messageId,
    String? uuid,
    BubbleStatus status = BubbleStatus.idle,
    FeedbackType feedback = FeedbackType.none,
    List<ChatFileItem> files = const [],
    List<ChatAssistantBlock> blocks = const [],
  }) {
    return ChatAssistantMessageViewData(
      messageId: messageId,
      uuid: uuid,
      status: status,
      feedback: feedback,
      files: files,
      blocks: blocks,
    );
  }

  ChatAssistantMessageViewData copyWith({
    String? messageId,
    String? uuid,
    BubbleStatus? status,
    FeedbackType? feedback,
    List<ChatFileItem>? files,
    List<ChatAssistantBlock>? blocks,
    List<ChatTimelineEntry>? timelineEntries,
    String? reasoningContent,
    String? failureMessage,
    String? deliveryNotice,
    String? usageSummary,
    ChatTokenUsage? tokenUsage,
    DateTime? streamStartedAt,
    DateTime? streamEndedAt,
    String? agentMessageStatus,
    List<Map<String, dynamic>>? empBlocks,
  }) {
    return ChatAssistantMessageViewData(
      localId: localId,
      messageId: messageId ?? this.messageId,
      uuid: uuid ?? this.uuid,
      status: status ?? this.status,
      failureMessage: failureMessage ?? this.failureMessage,
      deliveryNotice: deliveryNotice ?? this.deliveryNotice,
      feedback: feedback ?? this.feedback,
      files: files ?? this.files,
      blocks: blocks ?? this.blocks,
      timelineEntries: timelineEntries ?? this.timelineEntries,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      usageSummary: usageSummary ?? this.usageSummary,
      tokenUsage: tokenUsage ?? this.tokenUsage,
      streamStartedAt: streamStartedAt ?? this.streamStartedAt,
      streamEndedAt: streamEndedAt ?? this.streamEndedAt,
      agentMessageStatus: agentMessageStatus ?? this.agentMessageStatus,
      empBlocks: empBlocks ?? this.empBlocks,
    );
  }
}

List<ChatConversationItem> buildChatConversationItems(
  List<ChatMessage> messages, {
  bool includeWelcomeWhenEmpty = true,
}) {
  if (messages.isEmpty) {
    return includeWelcomeWhenEmpty
        ? const [ChatWelcomeConversationItem()]
        : const [];
  }

  final items = <ChatConversationItem>[];
  for (var i = 0; i < messages.length; i++) {
    final current = messages[i];
    if (current.isSystem) {
      items.add(
        ChatSystemConversationItem(
          kind: ChatConversationItemKind.systemMessage,
          content: current.content,
          messageId: current.messageId,
          metadata: current.metadata,
          createdAt: current.createdAt,
        ),
      );
      continue;
    }
    if (current.isSystemPrompt) {
      items.add(
        ChatSystemConversationItem(
          kind: ChatConversationItemKind.systemPrompt,
          content: current.content,
          messageId: current.messageId,
          metadata: current.metadata,
          createdAt: current.createdAt,
        ),
      );
      continue;
    }
    if (current.isQuestion) {
      if (_isCallEventMessage(current)) {
        items.add(
          ChatPairConversationItem(
            userMessage: current,
            assistantMessage: null,
          ),
        );
        continue;
      }
      ChatAssistantMessageViewData? assistant;
      if (i + 1 < messages.length && messages[i + 1].isAnswer) {
        assistant = ChatAssistantMessageViewData.fromMessage(messages[i + 1]);
        i += 1;
      }
      items.add(
        ChatPairConversationItem(
          userMessage: current,
          assistantMessage: assistant,
        ),
      );
      continue;
    }
    items.add(
      ChatPairConversationItem(
        userMessage: null,
        assistantMessage: ChatAssistantMessageViewData.fromMessage(current),
      ),
    );
  }
  return items;
}

bool _isCallEventMessage(ChatMessage message) =>
    message.metadata?['kind'] == 'call_event';
