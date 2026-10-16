import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_mention.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

class ChatMixedMessageBubble extends StatelessWidget {
  const ChatMixedMessageBubble({
    super.key,
    required this.blocks,
    required this.backgroundColor,
    this.isPeer = false,
    this.mentionNames = const <String>{},
    this.replyMentionPrefix = '',
    this.parentMessage,
    this.onPreviewImage,
    this.onOpenVideo,
  });

  final List<ImMessageBlock> blocks;
  final Color backgroundColor;
  final bool isPeer;
  final Set<String> mentionNames;

  /// 群聊 Agent final 的回复对象。仅由群聊气泡传入；普通 mixed 消息保持空。
  /// 文本/Markdown 首块与 mention 共用首行，避免纯 Markdown 与 EMP 分支展示不一致。
  final String replyMentionPrefix;

  /// P2 (2026-06): mixed 气泡所属的父 [ImMessage]。
  /// 当用户点击 mixed 内的 image / file block 时, 回调用这个 parent message
  /// 触发对外回调 (pane 用它定位整条消息, 走 `collectPreviewableImages` 的同一锚点)。
  /// null 时 fallback 为原行为 (image 走 `HumanDirectMediaImage` 单图 dialog;
  /// file 走 `HumanDirectFileCard` 双击下载)。
  final ImMessage? parentMessage;

  /// P2 (2026-06): 点击 image block (含 mixed 内任意 image) → 大图预览,
  /// pane 在收到 `parentMessage` 后调 `collectPreviewableImages`。
  final void Function(ImMessage parent, {Object? heroTag, String? imageUrl})?
      onPreviewImage;

  /// P2 (2026-06): mixed 单 file 视频时点击 → 下载 + 系统打开。
  /// 触发条件: `isVideoMessage(parentMessage)` (mixed 内仅一个 file block 且 mime/扩展为视频),
  /// 与 `canForwardMessage` / 历史 media tab 同口径。回调携带被点击的 file block,
  /// 让 pane 使用 block.url/name/mime, 不依赖 parent.mediaUrl。普通 file 走原下载链路。
  final void Function(ImMessage parent, ImMessageBlock block)? onOpenVideo;

  @override
  Widget build(BuildContext context) {
    final visibleBlocks = blocks.where(_isRenderableBlock).toList();
    if (visibleBlocks.length == 1 && visibleBlocks.first.isCallEvent) {
      final block = visibleBlocks.first;
      return ChatCallEventCard(
        label: callEventBlockLabel(block),
        endReason: block.callEndReason,
      );
    }

    final children = <Widget>[];
    var mentionPending = replyMentionPrefix.trim().isNotEmpty;
    for (final block in blocks) {
      var w = _blockWidget(context, block);
      if (w == null) continue;
      if (mentionPending) {
        final mention = Text.rich(
          TextSpan(
            children: mentionHighlightSpans(
              replyMentionPrefix.trim(),
              mentionNames,
            ),
          ),
        );
        if (block.isText || block.isMarkdown) {
          w = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mention,
              const SizedBox(width: 6),
              Flexible(child: w),
            ],
          );
        } else {
          children.add(mention);
          children.add(const SizedBox(height: 4));
        }
        mentionPending = false;
      }
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(w);
    }
    if (children.isEmpty) {
      children.add(const Text('[非文本消息]'));
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: isPeer
            ? Border.all(color: ChatTheme.enterprisePeerBubbleBorder)
            : null,
      ),
      // 文字块(text/markdown)各自单独包了 ChatSelectableSurface(见
      // _blockWidget),图片/文件/通话/转发卡片不包——不能在这里再包一层笼统的
      // ChatSelectableSurface,那样会把这些卡片也一起挡住点击(IgnorePointer),
      // 也会跟 pane 级别可能存在的外层 ChatSelectableSurface 形成嵌套
      // SelectableRegion(Flutter 不支持)。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  bool _isRenderableBlock(ImMessageBlock block) {
    if (block.isText || block.isMarkdown) return block.text.trim().isNotEmpty;
    if (block.isImage) return block.url.isNotEmpty;
    if (block.isFile) return block.url.isNotEmpty;
    if (block.isCallEvent) return true;
    if (block.isForwardRecord) return block.text.trim().isNotEmpty;
    return false;
  }

  Widget? _blockWidget(BuildContext context, ImMessageBlock block) {
    if (block.isText) {
      final text = block.text.trim();
      if (text.isEmpty) return null;
      return ChatSelectableSurface(
        child: Text.rich(
          TextSpan(children: mentionHighlightSpans(text, mentionNames)),
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF1D2129),
            height: 1.5,
          ),
        ),
      );
    }
    if (block.isMarkdown) {
      final text = block.text.trim();
      if (text.isEmpty) return null;
      // selectable: false — 外面已经包了这个块自己的 ChatSelectableSurface,
      // markdown 不需要(也不能)再自建一层 SelectableRegion(Flutter 不支持嵌套)。
      return ChatSelectableSurface(
        child:
            ChatMarkdownWidget(content: text, compact: true, selectable: false),
      );
    }
    if (block.isImage && block.url.isNotEmpty) {
      // P2 (2026-06): 接通多图预览。parentMessage + onPreviewImage 任一为 null →
      // 回退原 fallback (HumanDirectMediaImage 自己的单图 dialog)。
      final parent = parentMessage;
      final cb = onPreviewImage;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: HumanDirectMediaImage(
          url: block.url,
          onPreviewWithHero: (parent != null && cb != null)
              ? (tag) => cb(parent, heroTag: tag, imageUrl: block.url)
              : null,
        ),
      );
    }
    if (block.isFile && block.url.isNotEmpty) {
      // P2 (2026-06): mixed 单 file 视频时点击 → block-aware onOpenVideo。
      // 普通 file 不传 onOpen, 走 HumanDirectFileCard 自己的下载 controller 链路。
      final parent = parentMessage;
      final videoCb = onOpenVideo;
      final isVideo = parent != null && isVideoMessage(parent);
      return HumanDirectFileCard(
        url: block.url,
        name: block.name.trim().isNotEmpty ? block.name.trim() : '[文件]',
        size: block.size,
        mime: block.mime,
        isVideoOverride: isVideo,
        onOpen:
            isVideo && videoCb != null ? () => videoCb(parent, block) : null,
      );
    }
    if (block.isCallEvent) {
      return ChatCallEventCard(
        label: callEventBlockLabel(block),
        endReason: block.callEndReason,
      );
    }
    if (block.isForwardRecord) {
      final data = ForwardRecordData.tryParse(block);
      if (data == null) return null;
      return ForwardRecordCard(data: data);
    }
    return null;
  }
}

class ForwardRecordData {
  const ForwardRecordData({
    required this.title,
    required this.entries
  });

  final String title;
  final List<ForwardRecordEntry> entries;

  static ForwardRecordData? tryParse(ImMessageBlock block) {
    try {
      final decoded = jsonDecode(block.text);
      if (decoded is! Map) return null;
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) return null;
      final entries = rawEntries
          .whereType<Map>()
          .map((e) => ForwardRecordEntry.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.blocks.isNotEmpty)
          .toList(growable: false);
      if (entries.isEmpty) return null;
      final title = (decoded['title'] ?? block.name).toString().trim();
      return ForwardRecordData(
        title: title.isNotEmpty ? title : '聊天记录',
        entries: entries,
      );
    } catch (_) {
      return null;
    }
  }
}

class ForwardRecordEntry {
  const ForwardRecordEntry({
    required this.sender,
    required this.timestamp,
    required this.summary,
    required this.blocks,
  });

  final String sender;
  final int timestamp;
  final String summary;
  final List<ImMessageBlock> blocks;

  factory ForwardRecordEntry.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'];
    final blocks = rawBlocks is List
        ? rawBlocks
            .whereType<Map>()
            .map((b) => ImMessageBlock.fromJson(b.cast<String, dynamic>()))
            .whereType<ImMessageBlock>()
            .where((b) =>
                (b.isText || b.isMarkdown) && b.text.trim().isNotEmpty ||
                b.isImage && b.url.trim().isNotEmpty ||
                b.isFile && b.url.trim().isNotEmpty)
            .toList(growable: false)
        : <ImMessageBlock>[];
    return ForwardRecordEntry(
      sender: (json['sender'] ?? '成员').toString(),
      timestamp: _readInt(json['timestamp']),
      summary: (json['summary'] ?? '').toString(),
      blocks: blocks,
    );
  }
}

class ForwardRecordCard extends StatelessWidget {
  const ForwardRecordCard({
    super.key,
    required this.data
  });

  final ForwardRecordData data;

  @override
  Widget build(BuildContext context) {
    final previews = data.entries.take(3).map((e) {
      final summary = e.summary.trim().isNotEmpty
          ? e.summary.trim()
          : _summaryOfBlocks(e.blocks);
      return '${e.sender}: $summary';
    }).toList(growable: false);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => ForwardRecordDialog(data: data),
        ),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    CupertinoIcons.chat_bubble_text,
                    size: 18,
                    color: Color(0xFF111827),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...previews.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Color(0xFF8A94A6),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '查看聊天记录',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ForwardRecordDialog extends StatelessWidget {
  const ForwardRecordDialog({
    super.key,
    required this.data
  });

  final ForwardRecordData data;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return UiContentDialog(
      maxHeight: size.height * 0.82,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
            child: UiSheetHeader(
              title: data.title,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFE1E6EF)),
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
              itemBuilder: (context, index) =>
                  ForwardRecordEntryView(entry: data.entries[index]),
              separatorBuilder: (_, __) => const SizedBox(height: 22),
              itemCount: data.entries.length,
            ),
          ),
        ],
      ),
    );
  }
}

class ForwardRecordEntryView extends StatelessWidget {
  const ForwardRecordEntryView({
    super.key,
    required this.entry
  });

  final ForwardRecordEntry entry;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final block in entry.blocks) {
      final child = _forwardRecordBlockWidget(block);
      if (child == null) continue;
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(child);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${entry.sender}  ${_formatForwardRecordTime(entry.timestamp)}',
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF8A94A6),
            height: 1.3,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget? _forwardRecordBlockWidget(ImMessageBlock block) {
    if (block.isText || block.isMarkdown) {
      final text = block.text.trim();
      if (text.isEmpty) return null;
      return Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          height: 1.45,
          color: Color(0xFF111827),
        ),
      );
    }
    if (block.isImage && block.url.trim().isNotEmpty) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: ForwardRecordImage(url: block.url),
      );
    }
    if (block.isFile && block.url.trim().isNotEmpty) {
      return ForwardRecordFileCard(
        url: block.url,
        name: block.name.trim().isNotEmpty ? block.name.trim() : '[文件]',
        size: block.size,
        mime: block.mime,
      );
    }
    return null;
  }
}

class ForwardRecordImage extends StatelessWidget {
  const ForwardRecordImage({
    super.key,
    required this.url
  });

  final String url;

  @override
  Widget build(BuildContext context) {
    final resolved = apiImageResolveUrl(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: UiNetworkImage(
        imageUrl: resolved,
        cacheKey: resolved,
        fit: BoxFit.cover,
        borderRadius: 8,
        clip: false,
        placeholderBuilder: (_, __) => Container(
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F2F4),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        errorBuilder: (_, __, ___) => Container(
          height: 220,
          color: const Color(0xFFF1F2F4),
          alignment: Alignment.center,
          child: const Icon(
            CupertinoIcons.photo,
            color: Color(0xFF98A2B3),
            size: 28,
          ),
        ),
      ),
    );
  }
}

class ForwardRecordFileCard extends StatelessWidget {
  const ForwardRecordFileCard({
    super.key,
    required this.url,
    required this.name,
    required this.size,
    this.mime = '',
  });

  final String url;
  final String name;
  final int size;
  final String mime;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          FileAttachmentIcon(
            fileName: name,
            size: FileAttachmentIconSize.lg
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _humanFileSize(size),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8A94A6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _summaryOfBlocks(List<ImMessageBlock> blocks) {
  final parts = <String>[];
  for (final b in blocks) {
    if (b.isText || b.isMarkdown) {
      final text = b.text.trim();
      if (text.isNotEmpty) parts.add(text);
    } else if (b.isImage) {
      parts.add('[图片]');
    } else if (b.isFile) {
      parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[文件]');
    }
  }
  return parts.join(' ').trim();
}

String _formatForwardRecordTime(int timestamp) {
  if (timestamp <= 0) return '';
  final ms = timestamp > 1000000000000 ? timestamp : timestamp * 1000;
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _humanFileSize(int bytes) {
  if (bytes <= 0) return '文件';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse((value ?? '').toString()) ?? 0;
}

bool isCallEventLikeMessage(ImMessage msg) {
  if (msg.isRevoked || msg.isMedia) return false;
  final renderableBlocks = msg.blocks.where((b) {
    if (b.isCallEvent) return true;
    if (b.isText || b.isMarkdown) return b.text.trim().isNotEmpty;
    if (b.isImage || b.isFile) return true;
    return false;
  }).toList(growable: false);
  if (renderableBlocks.isNotEmpty) {
    return renderableBlocks.every((b) => b.isCallEvent);
  }
  return callEventSummaryLabel(msg.text) != null;
}

String callEventMessageLabel(ImMessage msg) {
  final callBlock = firstCallEventBlock(msg);
  if (callBlock != null) return callEventBlockLabel(callBlock);
  return callEventSummaryLabel(msg.text) ?? '通话已结束';
}

String callEventMessageEndReason(ImMessage msg) {
  final callBlock = firstCallEventBlock(msg);
  return callBlock?.callEndReason ?? '';
}

ImMessageBlock? firstCallEventBlock(ImMessage msg) {
  for (final block in msg.blocks) {
    if (block.isCallEvent) return block;
  }
  return null;
}

String callEventBlockLabel(ImMessageBlock block) {
  final text = block.text.trim();
  if (text.isNotEmpty) return text;
  return callEventSummaryLabel(text) ?? '通话已结束';
}

String? callEventSummaryLabel(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^(语音通话|视频通话)\s*·\s*(.+)$').firstMatch(trimmed);
  if (match != null) {
    final label = match.group(2)?.trim() ?? '';
    return label.isNotEmpty ? label : null;
  }
  const known = <String>{'未接听', '已取消', '已拒绝', '通话异常结束', '通话已结束'};
  if (known.contains(trimmed) || trimmed.startsWith('通话时长 ')) {
    return trimmed;
  }
  return null;
}

/// F16 通话卡片小块（飞书质感：电话图标 + 状态/时长，紧凑，不做大卡）。
class ChatCallEventCard extends StatelessWidget {
  const ChatCallEventCard({
    super.key,
    required this.label,
    required this.endReason,
  });

  final String label;
  final String endReason;

  @override
  Widget build(BuildContext context) {
    // 未接 / 被拒 → 红；正常通话 / 其它 → 品牌蓝。
    final missed = endReason == 'timeout' || endReason == 'callee_reject';
    final color = missed ? const Color(0xFFFF3B30) : const Color(0xFF2563EB);
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
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
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(CupertinoIcons.phone_fill, size: 13, color: color),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                height: 1.25,
                color: Color(0xFF1D2129),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
