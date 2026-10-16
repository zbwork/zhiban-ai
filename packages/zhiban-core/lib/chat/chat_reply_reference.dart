/// F09 引用回复 v1 客户端 model (2026-06).
///
/// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」。
///
/// 设计:
///   - reply metadata 走 WuKong mixed payload 的 `reply` 字段 (encode/decode 在
///     WkMixedContent), 不塞进可见正文 / Markdown.
///   - 客户端发送时, 即使用户只输入文本, 只要 `replyRef != null` 就把发送 payload
///     **晋升为 mixed**: blocks=[text block], 顶层带 reply.
///   - 字段优先按 `clientMsgNo` 定位原消息 (与 `imMessageIdentity` 一致), 再按
///     `messageId` / `messageSeq` 兜底.
library;

import 'package:zhiban_core/im/im_client.dart';

/// 引用消息引用快照.
///
/// 发送时随消息一起带上去; 接收方解码后构造同结构, 用于气泡渲染 + 点击定位.
class ChatReplyReference {
  const ChatReplyReference({
    required this.messageId,
    required this.clientMsgNo,
    required this.messageSeq,
    required this.senderUid,
    required this.senderName,
    required this.summary,
    this.kind = ChatReplyKind.text,
    this.isUnavailable = false,
  });

  /// WuKong message_id (服务端 id, 字符串 / 数字均存为字符串). 可为空字符串 (未 ack).
  final String messageId;

  /// 客户端原消息的 clientMsgNo (最稳定的定位键).
  final String clientMsgNo;

  /// WuKong message_seq; 0 = 未 ack.
  final int messageSeq;

  /// 原消息发送者的 WuKong uid (`t_{tenant}_u_{account_uuid}` / agent uid).
  final String senderUid;

  /// 显示名 (发送时由客户端从 participants 取). 不依赖此名校验权限, 仅展示.
  final String senderName;

  /// 摘要文本 (≤80 char text / `[图片]` / `[文件] xxx` / `原消息不可用`).
  final String summary;

  /// 原消息类型, 用于气泡内引用块图标(text/image/file/mixed/system).
  final ChatReplyKind kind;

  /// 客户端渲染时若发现原消息已撤回 / 不可用, 标记此项 (覆盖 summary 文案).
  /// **不**作为 wire 字段 (encode 不带); 接收端按需自行根据 controller.messages 标记.
  final bool isUnavailable;

  bool get hasIdentity =>
      messageId.isNotEmpty || clientMsgNo.isNotEmpty || messageSeq > 0;

  Map<String, dynamic> toJson() {
    return {
      if (messageId.isNotEmpty) 'message_id': messageId,
      if (clientMsgNo.isNotEmpty) 'client_msg_no': clientMsgNo,
      if (messageSeq > 0) 'message_seq': messageSeq,
      'sender_uid': senderUid,
      'sender_name': senderName,
      'summary': summary,
      'kind': kind.wireName,
    };
  }

  factory ChatReplyReference.fromJson(Map<String, dynamic> j) {
    final seq = j['message_seq'];
    return ChatReplyReference(
      messageId: (j['message_id'] ?? '').toString(),
      clientMsgNo: (j['client_msg_no'] ?? '').toString(),
      messageSeq: seq is num ? seq.toInt() : 0,
      senderUid: (j['sender_uid'] ?? '').toString(),
      senderName: (j['sender_name'] ?? '').toString(),
      summary: (j['summary'] ?? '').toString(),
      kind: ChatReplyKindX.parse((j['kind'] ?? 'text').toString()),
    );
  }

  ChatReplyReference copyWith({
    bool? isUnavailable,
    String? summary,
  }) {
    return ChatReplyReference(
      messageId: messageId,
      clientMsgNo: clientMsgNo,
      messageSeq: messageSeq,
      senderUid: senderUid,
      senderName: senderName,
      summary: summary ?? this.summary,
      kind: kind,
      isUnavailable: isUnavailable ?? this.isUnavailable,
    );
  }
}

enum ChatReplyKind { text, image, file, mixed, system, unknown }

extension ChatReplyKindX on ChatReplyKind {
  String get wireName {
    switch (this) {
      case ChatReplyKind.text:
        return 'text';
      case ChatReplyKind.image:
        return 'image';
      case ChatReplyKind.file:
        return 'file';
      case ChatReplyKind.mixed:
        return 'mixed';
      case ChatReplyKind.system:
        return 'system';
      case ChatReplyKind.unknown:
        return 'unknown';
    }
  }

  static ChatReplyKind parse(String s) {
    switch (s) {
      case 'text':
        return ChatReplyKind.text;
      case 'image':
        return ChatReplyKind.image;
      case 'file':
        return ChatReplyKind.file;
      case 'mixed':
        return ChatReplyKind.mixed;
      case 'system':
        return ChatReplyKind.system;
      default:
        return ChatReplyKind.unknown;
    }
  }
}

/// 摘要纯函数: 给定原消息 + 显示用 sender 名, 返回 [ChatReplyReference].
///
/// 调用方: 用户点「引用回复」时由 pane 调; 转发不需要.
ChatReplyReference buildReplyRefFromMessage({
  required ImMessage source,
  required String senderName,
}) {
  final kind = _classifyKind(source);
  final summary = quotedSummaryOf(source);
  return ChatReplyReference(
    messageId: source.messageId,
    clientMsgNo: source.clientMsgNo,
    messageSeq: source.messageSeq,
    senderUid: source.fromUid,
    senderName: senderName,
    summary: summary,
    kind: kind,
    isUnavailable: source.isRevoked,
  );
}

/// 摘要规则(契约同步):
///   text  → 首行截断 80 char
///   image → `[图片]`
///   file  → `[文件] <name>` (name 空时 `[文件]`)
///   mixed → 优先首个 text block 摘要;空则首媒体 block
///   空 / 撤回 → `原消息不可用`
String quotedSummaryOf(ImMessage msg) {
  if (msg.isRevoked) return '原消息不可用';
  if (msg.isMixed) {
    for (final b in msg.blocks) {
      if (b.isText || b.isMarkdown) {
        final t = b.text.trim();
        if (t.isNotEmpty) return _truncateForQuote(t);
      }
    }
    for (final b in msg.blocks) {
      if (b.isImage) return '[图片]';
      if (b.isFile) {
        final n = b.name.trim();
        return n.isNotEmpty ? '[文件] $n' : '[文件]';
      }
    }
    return '[非文本消息]';
  }
  switch (msg.mediaKind) {
    case ImMediaKind.image:
      return '[图片]';
    case ImMediaKind.file:
      final name = msg.mediaName.trim();
      return name.isNotEmpty ? '[文件] $name' : '[文件]';
    case ImMediaKind.none:
      break;
  }
  final t = msg.text.trim();
  if (t.isEmpty) return '原消息不可用';
  return _truncateForQuote(t);
}

String _truncateForQuote(String s) {
  // 首行 + 80 字符上限 (字符按 rune 计, 中英文都安全).
  final firstLine = s.split('\n').first.trim();
  final runes = firstLine.runes.toList(growable: false);
  if (runes.length <= 80) return firstLine;
  return '${String.fromCharCodes(runes.take(80))}…';
}

ChatReplyKind _classifyKind(ImMessage m) {
  if (m.isMixed) return ChatReplyKind.mixed;
  switch (m.mediaKind) {
    case ImMediaKind.image:
      return ChatReplyKind.image;
    case ImMediaKind.file:
      return ChatReplyKind.file;
    case ImMediaKind.none:
      return ChatReplyKind.text;
  }
}
