import 'dart:convert';

import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_action_menu.dart';

enum ChatForwardMode { separate, merged }

class ChatForwardPayload {
  const ChatForwardPayload({
    required this.blocks,
    this.summary = ''
  });

  final List<ImMessageBlock> blocks;
  final String summary;

  bool get isEmpty => blocks.isEmpty;
  bool get isPlainText =>
      blocks.length == 1 &&
      blocks.single.isText &&
      blocks.single.text.trim().isNotEmpty;
  String get plainText => isPlainText ? blocks.single.text.trim() : '';
}

typedef ForwardPayloadSendFn = Future<void> Function(
  String channelId,
  int channelType,
  ChatForwardPayload payload,
);

typedef ForwardMediaCloneFn = Future<ImMessageBlock?> Function(
  String targetConversationUuid,
  ImMessageBlock block,
);

typedef ForwardSenderNameFn = String Function(ImMessage message);

/// F09 转发 v1 (2026-06 多目标增量): 把 N 条**可转发**消息按时间升序逐条发到 M 个目标会话.
/// **绝不**携带 mentions metadata (避免目标群 @数字员工 被 mentions parser 拾起触发 Agent).
///
/// 调用方:
///   - 单条转发: `messages=[oneMsg]`, `targets=picked (1..N)`
///   - 批量转发: `messages=selectedMsgs (按时间升序)`, `targets=picked (1..N)`
///
/// 实现说明:
///   - 内层循环顺序: 对每个 target, 逐条 send (按消息时间升序);
///     这样目标会话里收到的消息顺序与源会话一致, 不会被 target 之间穿插。
///   - 单条 send 失败不阻塞同 target 后续, 也不阻塞其它 target。
///   - 单条转发仍由 `canForwardMessage` fail-closed。
///   - 批量转发可开启 [allowMixedMediaText]，仅抽 mixed 图文/文件消息里的 text/markdown
///     说明文字；图片/文件本体仍不转发。
///
/// 返回 [ChatForwardResult] (成功条数 / 失败条数 / 已成功的目标数 / 全失败的目标数)。
class ChatForwardResult {
  const ChatForwardResult({
    required this.sentSends,
    required this.failedSends,
    required this.targetsWithAnySuccess,
    required this.targetsAllFailed,
    required this.totalTargets,
    required this.totalMessagesPerTarget,
  });
  final int sentSends;
  final int failedSends;
  final int targetsWithAnySuccess;
  final int targetsAllFailed;
  final int totalTargets;
  final int totalMessagesPerTarget;

  bool get hasFailure => failedSends > 0;
  bool get allFailed => sentSends == 0 && failedSends > 0;
}

typedef ForwardSendFn = Future<void> Function(
    String channelId, int channelType, String text);

/// 把 [messages] 转发到 [targets] (按目标 → 按消息顺序逐条调 [send]).
/// 目标无 `wukongChannelId` / `channelType` → 跳过 (计入 `failedSends`)。
Future<ChatForwardResult> forwardMessagesToTargets({
  required List<ImMessage> messages,
  required List<ConversationItem> targets,
  required ForwardSendFn send,
  bool allowMixedMediaText = false,
}) async {
  // 提前抽出所有非空文本; 不可转发或抽出后为空的丢弃。
  final texts = <String>[];
  for (final m in messages) {
    final t = allowMixedMediaText
        ? chatBatchForwardTextOf(m).trim()
        : (canForwardMessage(m) ? chatForwardTextOf(m).trim() : '');
    if (t.isEmpty) continue;
    texts.add(t);
  }
  if (texts.isEmpty || targets.isEmpty) {
    return ChatForwardResult(
      sentSends: 0,
      failedSends: 0,
      targetsWithAnySuccess: 0,
      targetsAllFailed: 0,
      totalTargets: targets.length,
      totalMessagesPerTarget: 0,
    );
  }
  var sentSends = 0;
  var failedSends = 0;
  var targetsWithAnySuccess = 0;
  var targetsAllFailed = 0;
  for (final t in targets) {
    final ch = (t.wukongChannelId ?? '').trim();
    final ct = t.wukongChannelType ?? 0;
    if (ch.isEmpty || ct == 0) {
      // 跳过整个 target; 计为本 target 全失败 (per-message 计 fail 数)。
      failedSends += texts.length;
      targetsAllFailed++;
      continue;
    }
    var perTargetOk = 0;
    var perTargetFail = 0;
    for (final text in texts) {
      try {
        await send(ch, ct, text);
        perTargetOk++;
      } catch (_) {
        perTargetFail++;
      }
    }

    sentSends += perTargetOk;
    failedSends += perTargetFail;
    if (perTargetOk > 0) {
      targetsWithAnySuccess++;
    } else {
      targetsAllFailed++;
    }
  }
  return ChatForwardResult(
    sentSends: sentSends,
    failedSends: failedSends,
    targetsWithAnySuccess: targetsWithAnySuccess,
    targetsAllFailed: targetsAllFailed,
    totalTargets: targets.length,
    totalMessagesPerTarget: texts.length,
  );
}

Future<ChatForwardResult> forwardRichMessagesToTargets({
  required List<ImMessage> messages,
  required List<ConversationItem> targets,
  required ForwardPayloadSendFn send,
  required ForwardMediaCloneFn cloneMediaBlock,
  required ChatForwardMode mode,
  ForwardSenderNameFn? senderNameOf,
  String mergeTitle = '聊天记录',
}) async {
  if (messages.isEmpty || targets.isEmpty) {
    return ChatForwardResult(
      sentSends: 0,
      failedSends: 0,
      targetsWithAnySuccess: 0,
      targetsAllFailed: 0,
      totalTargets: targets.length,
      totalMessagesPerTarget: 0,
    );
  }

  var sentSends = 0;
  var failedSends = 0;
  var targetsWithAnySuccess = 0;
  var targetsAllFailed = 0;
  var totalMessagesPerTarget = 0;

  for (final target in targets) {
    final ch = (target.wukongChannelId ?? '').trim();
    final ct = target.wukongChannelType ?? 0;
    final convId = target.conversationId.trim();
    if (ch.isEmpty || ct == 0 || convId.isEmpty) {
      final count = mode == ChatForwardMode.merged ? 1 : messages.length;
      failedSends += count;
      targetsAllFailed++;
      totalMessagesPerTarget =
          totalMessagesPerTarget == 0 ? count : totalMessagesPerTarget;
      continue;
    }

    final payloads = mode == ChatForwardMode.merged
        ? <ChatForwardPayload>[
            await _buildMergedForwardPayload(
              messages: messages,
              targetConversationUuid: convId,
              cloneMediaBlock: cloneMediaBlock,
              senderNameOf: senderNameOf,
              title: mergeTitle,
            )
          ].where((p) => !p.isEmpty).toList(growable: false)
        : await _buildSeparateForwardPayloads(
            messages: messages,
            targetConversationUuid: convId,
            cloneMediaBlock: cloneMediaBlock,
          );
    if (totalMessagesPerTarget == 0) totalMessagesPerTarget = payloads.length;
    if (payloads.isEmpty) {
      targetsAllFailed++;
      continue;
    }

    var perTargetOk = 0;
    var perTargetFail = 0;
    for (final payload in payloads) {
      try {
        await send(ch, ct, payload);
        perTargetOk++;
      } catch (_) {
        perTargetFail++;
      }
    }
    sentSends += perTargetOk;
    failedSends += perTargetFail;
    if (perTargetOk > 0) {
      targetsWithAnySuccess++;
    } else {
      targetsAllFailed++;
    }
  }

  return ChatForwardResult(
    sentSends: sentSends,
    failedSends: failedSends,
    targetsWithAnySuccess: targetsWithAnySuccess,
    targetsAllFailed: targetsAllFailed,
    totalTargets: targets.length,
    totalMessagesPerTarget: totalMessagesPerTarget,
  );
}

Future<List<ChatForwardPayload>> _buildSeparateForwardPayloads({
  required List<ImMessage> messages,
  required String targetConversationUuid,
  required ForwardMediaCloneFn cloneMediaBlock,
}) async {
  final out = <ChatForwardPayload>[];
  for (final message in messages) {
    final payload = await _buildForwardPayload(
      message,
      targetConversationUuid: targetConversationUuid,
      cloneMediaBlock: cloneMediaBlock,
    );
    if (payload != null && !payload.isEmpty) out.add(payload);
  }
  return out;
}

Future<ChatForwardPayload?> _buildForwardPayload(
  ImMessage message, {
  required String targetConversationUuid,
  required ForwardMediaCloneFn cloneMediaBlock,
}) async {
  if (!canForwardRichMessage(message)) return null;
  final blocks = <ImMessageBlock>[];
  if (message.isMixed) {
    for (final block in message.blocks) {
      if (block.isText || block.isMarkdown) {
        final text = block.text.trim();
        if (text.isNotEmpty) {
          blocks.add(ImMessageBlock(kind: block.kind, text: text));
        }
      } else if (block.isImage || block.isFile) {
        final cloned = await _tryCloneMediaBlock(
          cloneMediaBlock,
          targetConversationUuid,
          block,
        );
        if (cloned != null) blocks.add(cloned);
      }
    }
  } else if (message.isMedia) {
    final block = ImMessageBlock(
      kind: message.mediaKind == ImMediaKind.image
          ? ImMessageBlockKind.image
          : ImMessageBlockKind.file,
      url: message.mediaUrl,
      fileUuid: message.mediaFileUuid,
      refUuid: message.mediaRefUuid,
      name: message.mediaName,
      size: message.mediaSize,
      mime: message.mediaMime,
      width: message.mediaWidth,
      height: message.mediaHeight,
      text: message.text,
    );
    final cloned = await _tryCloneMediaBlock(
      cloneMediaBlock,
      targetConversationUuid,
      block,
    );
    if (cloned != null) blocks.add(cloned);
  } else {
    final text = chatForwardTextOf(message).trim();
    if (text.isNotEmpty) {
      blocks.add(ImMessageBlock(kind: ImMessageBlockKind.text, text: text));
    }
  }
  if (blocks.isEmpty) return null;
  return ChatForwardPayload(
    blocks: blocks,
    summary: _summaryOfBlocks(blocks)
  );
}

Future<ImMessageBlock?> _tryCloneMediaBlock(
  ForwardMediaCloneFn cloneMediaBlock,
  String targetConversationUuid,
  ImMessageBlock block,
) async {
  try {
    return await cloneMediaBlock(targetConversationUuid, block);
  } catch (_) {
    return null;
  }
}

Future<ChatForwardPayload> _buildMergedForwardPayload({
  required List<ImMessage> messages,
  required String targetConversationUuid,
  required ForwardMediaCloneFn cloneMediaBlock,
  ForwardSenderNameFn? senderNameOf,
  required String title,
}) async {
  final entries = <Map<String, dynamic>>[];
  for (final message in messages) {
    final payload = await _buildForwardPayload(
      message,
      targetConversationUuid: targetConversationUuid,
      cloneMediaBlock: cloneMediaBlock,
    );
    if (payload == null || payload.isEmpty) continue;
    entries.add({
      'sender': senderNameOf?.call(message) ?? message.fromUid,
      'timestamp': message.timestamp,
      'summary': payload.summary,
      'blocks': payload.blocks.map((b) => b.toJson()).toList(growable: false),
    });
  }
  if (entries.isEmpty) return const ChatForwardPayload(blocks: []);
  final card = {
    'title': title,
    'entries': entries
  };
  return ChatForwardPayload(
    summary: title,
    blocks: [
      ImMessageBlock(
        kind: ImMessageBlockKind.forwardRecord,
        name: title,
        text: jsonEncode(card),
      ),
    ],
  );
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
    } else if (b.isForwardRecord) {
      parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[聊天记录]');
    }
  }
  return parts.join(' ').trim();
}

/// 批量转发文本抽取。
///
/// 与单条菜单不同，批量场景允许选中 mixed 图文/文件消息后只转发其中的
/// text/markdown 说明文字；媒体本体仍跳过。这样用户批量选择「图片 + 说明」
/// 不会因为图片 block 存在而整条提示「无可转发文本」。
String chatBatchForwardTextOf(ImMessage msg) {
  if (msg.isRevoked || msg.isRevokeNotify) return '';
  if (msg.isPending || msg.isFailed || msg.isUploading) return '';
  if (!msg.isMixed) {
    return canForwardMessage(msg) ? chatForwardTextOf(msg).trim() : '';
  }

  final parts = <String>[];
  for (final b in msg.blocks) {
    if (b.isSkill || b.isCallEvent) return '';
    if (b.isText || b.isMarkdown) {
      final t = b.text.trim();
      if (t.isNotEmpty) parts.add(t);
    }
  }
  return parts.join('\n').trim();
}

bool canBatchForwardMessage(ImMessage msg) =>
    canForwardRichMessage(msg) || chatBatchForwardTextOf(msg).isNotEmpty;

/// 给定 [ChatForwardResult] 和场景 (单条/批量), 返回 toast 文案。
/// 文案分两类:① 单条 1→N 目标;② 批量 N 条 → M 目标。
String chatForwardResultToast({
  required ChatForwardResult result,
  required bool isBatch,
  String? singleTargetName,
}) {
  if (result.totalTargets == 0) return '未选择目标会话';
  if (result.sentSends == 0) {
    return isBatch ? '全部转发失败 (${result.totalTargets} 个目标)' : '转发失败';
  }
  // 单条单目标: 「已转发到 X」
  if (!isBatch && result.totalTargets == 1) {
    if (result.failedSends == 0) {
      return singleTargetName != null && singleTargetName.isNotEmpty
          ? '已转发到 $singleTargetName'
          : '已转发';
    }
    return '转发失败';
  }
  // 单条多目标: 「已转发到 K 个会话 (M 个失败)」
  if (!isBatch) {
    if (result.failedSends == 0) {
      return '已转发到 ${result.targetsWithAnySuccess} 个会话';
    }
    return '已转发到 ${result.targetsWithAnySuccess} 个会话, ${result.targetsAllFailed} 个失败';
  }
  // 批量: 「已转发 N 条 × K 个会话 (M 条失败)」
  if (result.failedSends == 0) {
    return '已转发 ${result.totalMessagesPerTarget} 条到 ${result.targetsWithAnySuccess} 个会话';
  }
  return '已转发 ${result.sentSends} 条 (${result.targetsWithAnySuccess}/${result.totalTargets} 个会话), ${result.failedSends} 条失败';
}
