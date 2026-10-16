import 'package:zhiban_core/chat/chat_models.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_ui/widgets/ui_ai_generated_label.dart';

import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/pages/chat/widgets/compact_capability_icon.dart';
import 'components/message_bubble_file_attachments.dart';

/// 用户/智能体消息气泡（办公协作风格）。
///
/// - 右侧：用户消息气泡，飞书式浅蓝 [ChatTheme.wxUserBubble]，头像放在气泡右侧。
/// - 左侧：智能体兜底气泡（常规情况下 assistant 走 [ChatAssistantMessageView]，
///   这里仅作为非典型场景兜底），浅灰气泡，头像放左侧。
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.item,
    this.maxWidth,
    this.onOpenAttachment,
    this.avatarUrl,
    this.skillIconUrls = const {},
  });

  final ChatMessage item;
  final double? maxWidth;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  /// 该气泡发送方头像 URL（用户气泡 → 当前用户头像；assistant 兜底 → agent 头像）。
  final String? avatarUrl;
  final Map<String, String> skillIconUrls;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final maxWidth = widget.maxWidth;
    final onOpenAttachment = widget.onOpenAttachment;
    final isQuestion = item.role == ChatRole.question;
    final selectedSkillTags = item.selectedSkillTags;
    final maxBubbleWidth = maxWidth ?? 760;
    if (_isCallEventMessage(item)) {
      return _BubbleRow(
        avatarOnRight: true,
        bubble: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: _CallEventBubble(
            content: item.content,
            mediaKind: item.metadata?['media_kind']?.toString(),
          ),
        ),
      );
    }

    // 只有正文文字包 ChatSelectableSurface(永久 IgnorePointer)——技能标签是
    // 静态展示,文件附件([MessageBubbleFileAttachments])有自己的点击下载,包在
    // 选中区域里会被一起挡住,必须留在外面。
    final bubbleContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedSkillTags.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in selectedSkillTags)
                _SentSkillTag(
                  label: tag.label,
                  iconUrl: widget.skillIconUrls[tag.slug] ?? '',
                ),
            ],
          ),
          if (item.files.isNotEmpty || item.content.isNotEmpty)
            const SizedBox(height: 8),
        ],
        if (item.files.isNotEmpty)
          MessageBubbleFileAttachments(
            files: item.files,
            onOpenAttachment: onOpenAttachment,
          ),
        if (item.content.isNotEmpty)
          ChatSelectableSurface(
            child: isQuestion
                ? Text(
                    item.content,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      color: ChatTheme.wxUserBubbleText,
                    ),
                  )
                : ChatMarkdownWidget(content: item.content, selectable: false),
          ),
        if (!isQuestion &&
            !item.isLoading &&
            (item.files.isNotEmpty ||
                (item.content.trim().isNotEmpty && !item.isError)))
          const UiAiGeneratedLabel(),
      ],
    );

    // 人↔agent 消息右键菜单:本轮只承诺本地可执行项 —— 复制整条消息文本。
    // 内容为空(仅附件)时不显示「复制」,region 透明返回 child(见 ChatLocalMessageActionRegion)。
    final localActions = <ChatLocalMenuItem>[
      if (item.content.trim().isNotEmpty)
        ChatLocalMenuItem(
          icon: CupertinoIcons.doc_on_doc,
          label: '复制',
          isCopy: true,
          onSelected: () {
            // ignore: discarded_futures
            copyChatMessageText(item.content);
          },
        ),
    ];

    if (isQuestion) {
      return _BubbleRow(
        avatarOnRight: true,
        bubble: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: ChatLocalMessageActionRegion(
            items: localActions,
            child: _UserBubbleShell(child: bubbleContent),
          ),
        ),
      );
    }

    return _BubbleRow(
      avatarOnRight: false,
      bubble: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
        child: ChatLocalMessageActionRegion(
          items: localActions,
          child: _AiBubbleShell(child: bubbleContent),
        ),
      ),
    );
  }
}

/// 已发送用户消息里的只读技能标签。它表明本轮执行携带了哪个 skill block，
/// 不属于正文，也不提供删除入口。
class _SentSkillTag extends StatelessWidget {
  const _SentSkillTag({required this.label, required this.iconUrl});

  final String label;
  final String iconUrl;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '已选择技能：$label',
      child: Container(
        key: ValueKey('chat_message_skill_tag_$label'),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFEEF0FF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFD7DBF7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF4F58B8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isCallEventMessage(ChatMessage item) =>
    item.metadata?['kind'] == 'call_event';

class _CallEventBubble extends StatelessWidget {
  const _CallEventBubble({
    required this.content,
    this.mediaKind
  });

  final String content;
  final String? mediaKind;

  @override
  Widget build(BuildContext context) {
    final displayText =
        content.replaceFirst(RegExp(r'^(语音通话|视频通话)\s*·\s*'), '');
    final iconData = mediaKind == 'video'
        ? CupertinoIcons.video_camera_solid
        : CupertinoIcons.phone_fill;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: Color(0xFFE8F0FF),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              iconData,
              size: 14,
              color: const Color(0xFF2F6BFF)
            ),
          ),
          const SizedBox(width: 8),
          Text(
            displayText,
            style: const TextStyle(
              fontSize: 15,
              height: 1.35,
              color: Color(0xFF1F2329),
            ),
          ),
        ],
      ),
    );
  }
}

/// 气泡水平排版（不再画头像，仅按发送方左右对齐）。
class _BubbleRow extends StatelessWidget {
  const _BubbleRow({
    required this.bubble,
    required this.avatarOnRight
  });

  final Widget bubble;
  final bool avatarOnRight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment:
            avatarOnRight ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );
  }
}

/// 用户浅蓝气泡：飞书式扁平浅蓝、紧凑内边距。
class _UserBubbleShell extends StatelessWidget {
  const _UserBubbleShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: ChatTheme.wxUserBubble,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ChatTheme.enterpriseSelfBubbleBorder),
      ),
      child: child,
    );
  }
}

/// AI 浅灰气泡：飞书式扁平浅灰、紧凑阅读密度。
class _AiBubbleShell extends StatelessWidget {
  const _AiBubbleShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ChatTheme.wxAiBubble,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ChatTheme.wxAiBubbleBorder),
      ),
      child: child,
    );
  }
}
