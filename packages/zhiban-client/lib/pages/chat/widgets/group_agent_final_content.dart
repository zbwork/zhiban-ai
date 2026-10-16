import 'package:flutter/material.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_mention.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';

/// 群聊 Agent final 同时含 Markdown 与 EMP 卡片时，正文必须独立保留。
///
/// [empBlocks] 会负责 source/form/table 等交互块；这里仅返回普通正文块，避免
/// image/file 等已进入 EMP 原始块的内容被重复渲染。
List<ImMessageBlock> groupAgentFinalTextBlocks(
  Iterable<ImMessageBlock> blocks,
) {
  return blocks
      .where(
        (block) =>
            (block.isText || block.isMarkdown) && block.text.trim().isNotEmpty,
      )
      .toList(growable: false);
}

class GroupAgentFinalTextBlocksView extends StatelessWidget {
  const GroupAgentFinalTextBlocksView({
    super.key,
    required this.blocks,
    this.mentionNames = const <String>{},
  });

  final List<ImMessageBlock> blocks;
  final Set<String> mentionNames;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final block in groupAgentFinalTextBlocks(blocks)) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      if (block.isMarkdown) {
        children.add(
          ChatSelectableSurface(
            child: ChatMarkdownWidget(
              content: block.text.trim(),
              compact: true,
              selectable: false,
            ),
          ),
        );
      } else {
        children.add(
          ChatSelectableSurface(
            child: Text.rich(
              TextSpan(
                children: mentionHighlightSpans(
                  block.text.trim(),
                  mentionNames,
                ),
              ),
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF1D2129),
                height: 1.5,
              ),
            ),
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
