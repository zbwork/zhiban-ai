import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/services/rich_message_clipboard.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_menu_overlay.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';

/// 消息气泡操作菜单(人↔人 + 群聊共用)。
///
/// 飞书风轻量菜单(白底 / 8px 圆角 / 轻阴影 / 14px / 危险红)。
/// 只展示**真实可执行**项;无任何可用操作时**不弹**菜单(透明返回 child)。
///
/// 见 `docs/contracts/agent-bus-client-contract.md` §「消息撤回 v1」 + §「消息操作菜单」。
enum ChatMessageAction {
  copy,
  reply,
  forward,
  multiSelect,
  resend,
  revoke,
  saveFile,
  delete,
  cancelUpload,
}

/// F09 引用回复 v1 + 转发 v1 + 多选 v1: 当前气泡是否可以参与对应交互。纯函数,
/// 复用于菜单可见性 + 多选模式 checkbox 可勾选过滤 + 转发媒体 fail-closed.
///
/// 「普通用户消息」(2026-06 v2 范围) 定义:
///   - text / mixed (文本 / 图片 / 文件 blocks) / image / file 媒体消息
///   - **非** 撤回 tombstone (`isRevoked`)
///   - **非** WuKong type=98 撤回通知 (`isRevokeNotify`,运行时字段, 通常已被 controller 吞掉)
///   - **非** mixed 仅 callEvent / skill 块构成的「系统侧信道消息」 (F16 通话卡片 / 技能事件)
///   - **非** 发送中 / 失败 / 上传中 等无稳定 server 锚点的态
///
/// 不引入新的 system message 类型, 仅排除现有非普通消息形态。
bool _isMixedAllSystemOrNonUser(ImMessage msg) {
  if (!msg.isMixed) return false;
  for (final b in msg.blocks) {
    if (!(b.isCallEvent || b.isSkill)) return false;
  }
  return true;
}

bool canReplyMessage(ImMessage msg) {
  // 撤回 tombstone / pending / failed / uploading / revoke notify
  // / 仅 callEvent / 仅 skill 块的 mixed → 都不允许引用 (无稳定锚点 / 摘要无意义)。
  if (msg.isRevoked || msg.isRevokeNotify) return false;
  if (msg.isPending || msg.isFailed || msg.isUploading) return false;
  if (_isMixedAllSystemOrNonUser(msg)) return false;
  return true;
}

/// 转发(本轮仅文本 + mixed-text): 已撤回 / pending / failed / uploading / 媒体 / 系统消息 → 不可。
/// 媒体 fail-closed: 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.
///
/// **严格 fail-closed 规则**:
///   1. revoked / revokeNotify / pending / failed / uploading → 不可。
///   2. media (image/file 顶层) → 不可。
///   3. mixed 中**任何** non-text/non-markdown 块 (image / file / skill / callEvent / 未知)
///      → 不可。**只有** blocks 全是 text/markdown 才进入下一步。
///   4. 抽出文本后 (`chatForwardTextOf` trim) 不能为空, 否则 fail-closed
///      (避免菜单出现转发但用户点完目标后才发现没东西可发)。
bool canForwardMessage(ImMessage msg) {
  if (msg.isRevoked || msg.isRevokeNotify) return false;
  if (msg.isPending || msg.isFailed || msg.isUploading) return false;
  if (msg.isMedia) return false;
  // P2 (2026-06): 视频文件 (file wire + 视频扩展/mime) 视同媒体 → fail-closed。
  if (isVideoMessage(msg)) return false;
  if (msg.isMixed) {
    // mixed 必须全部是 text/markdown blocks; image/file/skill/callEvent/未知 → fail-closed.
    for (final b in msg.blocks) {
      if (!(b.isText || b.isMarkdown)) return false;
    }
  }
  // 最终抽出文本须非空, 这样和 chatForwardTextOf 完全闭环, 菜单不会出现“点了才告诉你不行”。
  if (chatForwardTextOf(msg).trim().isEmpty) return false;
  return true;
}

/// 富转发入口可见性：单条消息可转发文本、图片、文件或 mixed 图文/文件。
///
/// 媒体转发不复用原会话 `chat_media_ref`，执行阶段会按目标会话重新创建 ref；
/// 因此媒体 block 必须带 `fileUuid`。没有 fileUuid 的历史图片只能按文本规则转发。
bool canForwardRichMessage(ImMessage msg) {
  if (msg.isRevoked || msg.isRevokeNotify) return false;
  if (msg.isPending || msg.isFailed || msg.isUploading) return false;
  if (canForwardMessage(msg)) return true;
  if (msg.isMedia) {
    if (isVideoMessage(msg)) return false;
    return msg.mediaFileUuid.trim().isNotEmpty;
  }
  if (!msg.isMixed) return false;
  var hasPayload = false;
  for (final b in msg.blocks) {
    if (b.isSkill || b.isCallEvent || b.isForwardRecord) return false;
    if ((b.isText || b.isMarkdown) && b.text.trim().isNotEmpty) {
      hasPayload = true;
    } else if ((b.isImage || b.isFile) && b.fileUuid.trim().isNotEmpty) {
      hasPayload = true;
    }
  }
  return hasPayload;
}

/// 多选模式可勾选: 撤回 / pending / failed / uploading / 仅 system block 的 mixed → 不可选。
bool canSelectMessage(ImMessage msg) {
  if (msg.isRevoked || msg.isRevokeNotify) return false;
  if (msg.isPending || msg.isFailed || msg.isUploading) return false;
  if (_isMixedAllSystemOrNonUser(msg)) return false;
  return true;
}

/// 纯函数:给定消息与"是否本人发送",返回该气泡可展示的操作项(顺序即菜单顺序)。
///
/// 规则:
/// - **已撤回**(`msg.isRevoked`)→ 无任何操作,菜单不弹。
/// - 本人 `uploading`(媒体上传中)→ 只「取消上传」(不重发、不删除,避免取消 / 上传竞态)。
/// - 其余:有可复制内容([copyTextFor] 非空)→「复制」;
///   非 pending/failed/uploading 且非撤回 →「引用」;
///   文本 / mixed-text → 「转发」(媒体 fail-closed,本轮不做);
///   →「多选」(进入多选模式);
///   本人 `failed` →「重发」;
///   本人 `sent` 非 revoked →「撤回」;
///   本人非 `pending` / 非 `uploading`(即 `sent` / `failed`)→「本地删除」。
/// - 对端消息:复制 / 引用 / 转发 / 多选 可见(条件同上);本人 `pending`(发送中):只「复制」。
List<ChatMessageAction> availableMessageActions({
  required ImMessage msg,
  required bool isMine,
}) {
  if (msg.isRevoked) return const <ChatMessageAction>[]; // 撤回后无操作
  // 通话卡片(仅 callEvent/skill 块构成的系统侧信道消息):不提供任何操作
  // (复制/撤回/删除等都没有意义)。引用/多选/转发已经各自用
  // _isMixedAllSystemOrNonUser 排除,这里统一在最前面拦掉,不用逐项排除。
  if (_isMixedAllSystemOrNonUser(msg)) return const <ChatMessageAction>[];
  if (isMine && msg.isUploading) {
    return const <ChatMessageAction>[ChatMessageAction.cancelUpload];
  }
  final actions = <ChatMessageAction>[];
  final hasCopyable = _hasCopyableMessage(msg);
  if (hasCopyable) actions.add(ChatMessageAction.copy);
  // F09 引用回复 v1: 任一侧 sent 非 revoked/pending/failed/uploading 都可引用.
  if (canReplyMessage(msg)) actions.add(ChatMessageAction.reply);
  // F09 转发 v1: 文本 / mixed-text 才能转发 (媒体 fail-closed).
  if (canForwardRichMessage(msg)) actions.add(ChatMessageAction.forward);
  // F09 多选 v1: 进入多选模式 (任意非 revoked/pending/failed/uploading 消息触发).
  if (canSelectMessage(msg)) actions.add(ChatMessageAction.multiSelect);
  if (isMine && msg.isFailed) actions.add(ChatMessageAction.resend);
  // F09 P1 撤回: 自己 sent 才能撤; pending/failed/uploading 都不允许 (未到达服务端 / 已失败 / 上传中)。
  if (isMine && !msg.isPending && !msg.isFailed && !msg.isUploading) {
    actions.add(ChatMessageAction.revoke);
  }
  // F09 C 「保存文件」: 任一侧 (自己 / 对端) 媒体消息 (image/file) 且非 pending/failed/uploading
  // 且 mediaUrl 非空时可见. 桌面端会下载到下载目录 + reveal; 移动端只下载.
  if (msg.isMedia &&
      msg.mediaUrl.trim().isNotEmpty &&
      !msg.isPending &&
      !msg.isFailed &&
      !msg.isUploading) {
    actions.add(ChatMessageAction.saveFile);
  }
  if (isMine && !msg.isUploading && !msg.isPending) {
    actions.add(ChatMessageAction.delete);
  }
  return actions;
}

/// 复制时写入剪贴板的文本。
///
/// mixed 的 [msg.text] 是列表/搜索 summary，可能包含 `[图片]` / 文件名占位；
/// 复制到输入框时只应取真实 text/markdown block 正文，避免把媒体占位当成用户输入。
String copyTextFor(ImMessage msg) {
  if (msg.isMixed) {
    final text = _mixedTextBlocksOf(msg);
    if (text.isNotEmpty) return text;
    final mediaName = _firstMixedMediaName(msg);
    if (mediaName.isNotEmpty) return mediaName;
  }
  return msg.text.trim().isNotEmpty ? msg.text : msg.mediaName;
}

bool _hasCopyableMessage(ImMessage msg) {
  if (copyTextFor(msg).trim().isNotEmpty) return true;
  return RichMessageClipboard.copyableRichBlocksOf(msg).isNotEmpty;
}

String _mixedTextBlocksOf(ImMessage msg) {
  final parts = <String>[];
  for (final b in msg.blocks) {
    if (b.isText || b.isMarkdown) {
      final t = b.text.trim();
      if (t.isNotEmpty) parts.add(t);
    }
  }
  return parts.join('\n');
}

String _firstMixedMediaName(ImMessage msg) {
  for (final b in msg.blocks) {
    if ((b.isImage || b.isFile) && b.name.trim().isNotEmpty) {
      return b.name.trim();
    }
  }
  return msg.mediaName.trim();
}

/// F09 转发 v1 (纯函数):
/// 给定一条**可转发**消息 (`canForwardMessage`=true),返回**纯文本**形式的转发内容。
/// 现轮版本仅文本: text 直接发; mixed 拼所有 text/markdown block (顺序保持) + 用换行连接.
/// 见 `docs/contracts/agent-bus-client-contract.md` §「消息操作菜单 v2」.
String chatForwardTextOf(ImMessage msg) {
  if (msg.isMixed) {
    return _mixedTextBlocksOf(msg);
  }
  return msg.text.trim();
}

/// 转发选目标 dialog 的副标题: 显示一条文本预览 (截断 60 char),帮助用户确认。
String chatForwardSubtitleOf(ImMessage msg) {
  final text = chatForwardTextOf(msg);
  if (text.isEmpty) return '';
  final firstLine = text.split('\n').first.trim();
  final runes = firstLine.runes.toList(growable: false);
  if (runes.length <= 60) return firstLine;
  return '${String.fromCharCodes(runes.take(60))}…';
}

({IconData icon, String label, bool danger}) _actionMeta(ChatMessageAction a) {
  switch (a) {
    case ChatMessageAction.copy:
      return (icon: CupertinoIcons.doc_on_doc, label: '复制', danger: false);
    case ChatMessageAction.reply:
      return (
        icon: CupertinoIcons.reply,
        label: '引用',
        danger: false
      );
    case ChatMessageAction.forward:
      return (
        icon: CupertinoIcons.arrowshape_turn_up_right,
        label: '转发',
        danger: false,
      );
    case ChatMessageAction.multiSelect:
      return (
        icon: CupertinoIcons.check_mark_circled,
        label: '多选',
        danger: false,
      );
    case ChatMessageAction.resend:
      return (icon: Icons.refresh_rounded, label: '重发', danger: false);
    case ChatMessageAction.revoke:
      return (
        icon: CupertinoIcons.arrow_uturn_left,
        label: '撤回',
        danger: false
      );
    case ChatMessageAction.saveFile:
      return (
        icon: CupertinoIcons.cloud_download,
        label: '保存到下载',
        danger: false,
      );
    case ChatMessageAction.delete:
      return (
        icon: CupertinoIcons.trash,
        label: '删除',
        danger: true
      );
    case ChatMessageAction.cancelUpload:
      return (icon: CupertinoIcons.xmark, label: '取消上传', danger: false);
  }
}

int _actionVisualGroup(ChatMessageAction action) {
  switch (action) {
    case ChatMessageAction.copy:
    case ChatMessageAction.reply:
    case ChatMessageAction.forward:
    case ChatMessageAction.multiSelect:
      return 0;
    case ChatMessageAction.saveFile:
      return 1;
    case ChatMessageAction.resend:
    case ChatMessageAction.revoke:
    case ChatMessageAction.cancelUpload:
      return 2;
    case ChatMessageAction.delete:
      return 3;
  }
}

/// 在 [globalPosition] 弹出消息操作菜单。复制由本函数直接写系统剪贴板;其余动作回调上抛。
/// 无可用操作 → 不弹。
///
/// [selectedTextProvider] 非空 (右键前有真实文本选区) 时,「复制」写入选中片段的
/// 纯文本 (并清掉进程内 rich clipboard,避免在本应用粘贴时恢复成整条旧消息);
/// 为空时按整条消息复制 (纯文本 + rich blocks)。用函数而不是直接传字符串——
/// 菜单开着的时候用户还能拖手柄改选区,点「复制」那一刻要读最新值,不是弹菜单
/// 那一刻的快照。
///
/// callbacks 为 null 时,该项**不**显示 (调用方未实现 = 业务上不支持):
/// onReply / onForward / onMultiSelect 缺省即视为该容器尚未接通 v2 操作。
///
/// 返回被选中的操作;点击外部关闭 / 无可用操作 → 返回 null(调用方据此判断
/// "是否真的选中了某一项",决定要不要清空选区)。
Future<ChatMessageAction?> showChatMessageActionMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ImMessage msg,
  required bool isMine,
  String Function()? selectedTextProvider,
  Object? groupId,
  Rect? safeZone,
  ValueListenable<bool>? menuVisible,
  VoidCallback? onReply,
  VoidCallback? onForward,
  VoidCallback? onMultiSelect,
  VoidCallback? onResend,
  VoidCallback? onRevoke,
  VoidCallback? onSaveFile,
  VoidCallback? onDelete,
  VoidCallback? onCancelUpload,
}) async {
  final actions = availableMessageActions(msg: msg, isMine: isMine).where((a) {
    switch (a) {
      case ChatMessageAction.reply:
        return onReply != null;
      case ChatMessageAction.forward:
        return onForward != null;
      case ChatMessageAction.multiSelect:
        return onMultiSelect != null;
      default:
        return true;
    }
  }).toList(growable: false);
  if (actions.isEmpty) return null;
  final index = await showChatFeishuMenu(
    context: context,
    globalPosition: globalPosition,
    groupId: groupId,
    safeZone: safeZone,
    visible: menuVisible,
    items: actions.indexed.map((entry) {
      final i = entry.$1;
      final a = entry.$2;
      final meta = _actionMeta(a);
      return ChatMenuOverlayItem(
        icon: meta.icon,
        label: meta.label,
        danger: meta.danger,
        separatedBefore: i > 0 &&
            _actionVisualGroup(a) != _actionVisualGroup(actions[i - 1]),
      );
    }).toList(growable: false),
  );
  if (index == null || index < 0 || index >= actions.length) return null;
  final selected = actions[index];
  switch (selected) {
    case ChatMessageAction.copy:
      final liveSelectedText = selectedTextProvider?.call() ?? '';
      if (liveSelectedText.trim().isNotEmpty) {
        // 右键前选中的片段:只写纯文本,并清掉 rich clipboard,
        // 否则本应用内粘贴会优先恢复成整条旧消息的 rich blocks。
        RichMessageClipboard.clear();
        await Clipboard.setData(ClipboardData(text: liveSelectedText));
        break;
      }
      final text = copyTextFor(msg);
      RichMessageClipboard.writeFromMessage(msg, plainText: text);
      await Clipboard.setData(ClipboardData(text: text));
      break;
    case ChatMessageAction.reply:
      onReply?.call();
      break;
    case ChatMessageAction.forward:
      onForward?.call();
      break;
    case ChatMessageAction.multiSelect:
      onMultiSelect?.call();
      break;
    case ChatMessageAction.resend:
      onResend?.call();
      break;
    case ChatMessageAction.revoke:
      onRevoke?.call();
      break;
    case ChatMessageAction.saveFile:
      onSaveFile?.call();
      break;
    case ChatMessageAction.delete:
      onDelete?.call();
      break;
    case ChatMessageAction.cancelUpload:
      onCancelUpload?.call();
      break;
  }
  return selected;
}

/// 包裹一条气泡内容,提供右键(桌面 secondary tap)/ 长按(移动端)弹出操作菜单。
/// 无任何可用操作时**透明**(不拦手势,气泡照常 tap/预览)。
///
/// 手势机制见 [ChatSelectionGestureMixin]:气泡容器级的长按 / 右键,和气泡里有没有
/// 可选文字无关。
class ChatMessageActionRegion extends StatefulWidget {
  const ChatMessageActionRegion({
    super.key,
    required this.child,
    required this.msg,
    required this.isMine,
    this.onReply,
    this.onForward,
    this.onMultiSelect,
    this.onResend,
    this.onRevoke,
    this.onSaveFile,
    this.onDelete,
    this.onCancelUpload,
  });

  final Widget child;
  final ImMessage msg;
  final bool isMine;
  final VoidCallback? onReply;
  final VoidCallback? onForward;
  final VoidCallback? onMultiSelect;
  final VoidCallback? onResend;
  final VoidCallback? onRevoke;
  final VoidCallback? onSaveFile;
  final VoidCallback? onDelete;
  final VoidCallback? onCancelUpload;

  @override
  State<ChatMessageActionRegion> createState() =>
      _ChatMessageActionRegionState();
}

class _ChatMessageActionRegionState extends State<ChatMessageActionRegion>
    with ChatSelectionGestureMixin<ChatMessageActionRegion> {
  @override
  bool get hasAnyAction =>
      availableMessageActions(msg: widget.msg, isMine: widget.isMine)
          .isNotEmpty;

  @override
  Future<bool> showMenu(
    Offset globalPosition, {
    ValueListenable<bool>? menuVisible,
  }) async {
    final chosen = await showChatMessageActionMenu(
      context: context,
      globalPosition: globalPosition,
      msg: widget.msg,
      isMine: widget.isMine,
      selectedTextProvider: () => selectionController.selectedText,
      groupId: menuGroupId,
      safeZone: menuSafeZone,
      menuVisible: menuVisible,
      onReply: widget.onReply,
      onForward: widget.onForward,
      onMultiSelect: widget.onMultiSelect,
      onResend: widget.onResend,
      onRevoke: widget.onRevoke,
      onSaveFile: widget.onSaveFile,
      onDelete: widget.onDelete,
      onCancelUpload: widget.onCancelUpload,
    );
    return chosen != null;
  }

  @override
  Widget build(BuildContext context) =>
      buildSelectionRegion(child: widget.child);
}
