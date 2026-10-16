import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_mixed_message_bubble.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';

/// F09 P1 已读回执 indicator + popover (轻量 / 飞书企微风)。
///
/// 见 docs/contracts/agent-bus-client-contract.md §「消息级已读回执 v1」。
///
/// 显示规则 (调用方决定是否调用本组件; 这里不重复判断业务条件):
///   - 自己 sent 非 revoked/pending/failed/uploading 才调.
///   - messageSeq <= 0 → [ChatReceiptStatusSlot] 显示静态弱灰占位,不请求回执.
///   - snapshot=null (尚未拉到 / 接口失败) 或无可统计对象 (isEmpty) → 弱灰空心圆占位
///     ([ChatReceiptStatusDot], 稳定宽度, **不**渲染假回执, 不可点)。
///   - allRead=true → 青绿色 outline check-circle (单聊 / 群聊一致)。
///   - 群聊 read_count>0 → 浅蓝 outline 数字 badge (已读人数)。
///   - 单聊未读 / 群聊还没人读 → 弱灰空心圆 (不显示数字 0)。
///
/// 单聊仅展示状态；群聊点击 (有真实 snapshot 时) → ChatReadReceiptPopover。
/// Snapshot 缺失时只展示静态状态点, 不可点, 不弹假数据弹层。
///
/// **数据获取**: 调用方传 [controller] (per-conversation cache+debounce) + [messageSeq],
/// 本 widget 自动 listen + 首帧 requestSeqs; controller 拉到后 notifyListeners → rebuild。
class ChatReadReceiptIndicator extends StatefulWidget {
  const ChatReadReceiptIndicator({
    super.key,
    required this.controller,
    required this.messageSeq,
    required this.isGroup,
    this.size = 14,
  });

  final ChatReceiptsController controller;
  final int messageSeq;

  /// 群聊 (true) vs 单聊 (false)。单聊**永远不显示数字 badge** (read_count 只可能是 0/1,
  /// 显示 "0" 会误导)；群聊 read_count>0 才显示数字。
  final bool isGroup;
  final double size;

  @override
  State<ChatReadReceiptIndicator> createState() =>
      _ChatReadReceiptIndicatorState();
}

class _ChatReadReceiptIndicatorState extends State<ChatReadReceiptIndicator> {
  static const Color _readGreen = Color(0xFF00B578);
  static const Color _partialBlue = Color(0xFF2F80ED);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.requestSeqs([widget.messageSeq]);
    });
  }

  @override
  void didUpdateWidget(covariant ChatReadReceiptIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
    if (oldWidget.messageSeq != widget.messageSeq) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.controller.requestSeqs([widget.messageSeq]);
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.controller.snapshotFor(widget.messageSeq);
    final size = widget.size;
    // snapshot=null (拉取中 / 拉取失败 / 后端拒) 或无可统计对象 (group 只剩自己 /
    // direct peer 退群) → 弱灰空心圆占位:保留稳定宽度的「已发送, 待已读」状态位,
    // 不渲染假回执、不可点 (无真实数据不弹层)。数据回来后 notifyListeners 重建为真状态。
    if (snap == null || snap.isEmpty) {
      return Tooltip(
          message: '已读状态未知', child: ChatReceiptStatusDot(size: size));
    }
    final Widget icon;
    if (snap.allRead) {
      // 全部已读 → 青绿 check-circle (单聊 / 群聊一致, 保留既有契约)。
      icon = ChatReceiptReadCheck(size: size, color: _readGreen);
    } else if (widget.isGroup && snap.readCount > 0) {
      // 群聊部分已读 → 蓝色圆形数字 badge (已读人数)。
      icon =
          _NumberBadge(count: snap.readCount, size: size, color: _partialBlue);
    } else {
      // 单聊未读, 或群聊还没人读 → 弱灰空心圆 (不显示数字 0)。
      icon = ChatReceiptStatusDot(size: size);
    }
    // 单聊对端唯一，仅展示回执；群聊才需要查看已读/未读成员。
    if (!widget.isGroup) return icon;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _open(context, d.globalPosition),
      child: icon,
    );
  }

  Future<void> _open(BuildContext context, Offset pos) async {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;
    // FX3 P2: 点击入口时触发 refresh, popover 内部监听 controller 自动用最新 snapshot.
    widget.controller.refreshNow([widget.messageSeq]);
    await showChatReadReceiptPopover(
      context: context,
      globalPosition: pos,
      controller: widget.controller,
      messageSeq: widget.messageSeq,
      overlaySize: overlayBox.size,
    );
  }
}

/// 已读回执状态位的圆圈描边宽度——三种状态(已读勾/未读空心圆/群聊数字徽标)
/// 共用同一个值，避免切换状态时圆圈粗细跳变(2026-08-07 用户反馈原来 1.6/1.05/1.2
/// 三个不同宽度混用，观感不统一)。
const double _kReceiptRingWidth = 1.0;

/// 自己消息左侧「已读」状态:绿色空心圆 + check。
///
/// 不使用系统图标,是为了贴近 IM 截图里的轻量描边圆勾,并保证尺寸 / 线宽稳定。
class ChatReceiptReadCheck extends StatelessWidget {
  const ChatReceiptReadCheck({
    super.key,
    this.size = 14,
    this.color = const Color(0xFF00B578),
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: _kReceiptRingWidth),
              color: Colors.white,
            ),
          ),
          Icon(
            CupertinoIcons.checkmark,
            size: size * 0.66,
            color: color
          ),
        ],
      ),
    );
  }
}

/// 「已发送, 待已读」弱灰空心圆状态位。
///
/// 用于:① snapshot 没回来 / 失败 / 无可统计对象的占位 (不可点);② 单聊未读 /
/// 群聊读数为 0 的真实态 (由 [ChatReadReceiptIndicator] 包 GestureDetector 后可点弹层)。
/// 固定 [size] 宽高, 保证 snapshot 前后布局不跳。不渲染假「已读」。
class ChatReceiptStatusDot extends StatelessWidget {
  const ChatReceiptStatusDot({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: const Color(0xFFBFC4CC), width: _kReceiptRingWidth),
        color: Colors.white,
      ),
    );
  }
}

/// 自己 sent 消息左侧的「已读回执状态位」组合件 (仅 IM human_direct / group)。
///
/// - [controller] 就绪 且 [messageSeq] > 0 → 真正的 [ChatReadReceiptIndicator]
///   (其内部 snapshot 没回来时仍保留弱灰占位);
/// - 否则 (会话 receipts controller 尚未就绪 / seq 未 ack) → 静态弱灰占位
///   ([ChatReceiptStatusDot]):稳定宽度, 不可点, 不弹假弹层。
///
/// pending / failed / uploading 由调用方用既有 ChatSendStatusIndicator /
/// ChatUploadProgressIndicator 处理, **不**经过本组件;对端消息不应使用本组件。
class ChatReceiptStatusSlot extends StatelessWidget {
  const ChatReceiptStatusSlot({
    super.key,
    required this.controller,
    required this.messageSeq,
    required this.isGroup,
    this.size = 14,
  });

  final ChatReceiptsController? controller;
  final int messageSeq;
  final bool isGroup;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c != null && messageSeq > 0) {
      return ChatReadReceiptIndicator(
        controller: c,
        messageSeq: messageSeq,
        isGroup: isGroup,
        size: size,
      );
    }
    return ChatReceiptStatusDot(size: size);
  }
}

/// IM 自己消息是否应显示左侧回执状态位。
///
/// 通话事件卡片(如「通话时长 01:53」)是系统侧信道消息,不属于普通用户内容,
/// 不展示已读/未读状态位。
bool shouldShowSelfReceiptStatusSlot({
  required ImMessage msg,
  required bool isPeer,
}) {
  return !isPeer &&
      !isCallEventLikeMessage(msg) &&
      !msg.isRevoked &&
      !msg.isPending &&
      !msg.isFailed &&
      !msg.isUploading;
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({
    required this.count,
    required this.size,
    required this.color,
  });
  final int count;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99' : '$count';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: _kReceiptRingWidth),
        color: Colors.white,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: size * 0.62,
          color: color,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}

/// 弹层: 已读 N / 未读 M tab + 成员列表。
///
/// 视觉同会话菜单: 白底 / 8px 圆角 / 轻阴影 / 浅边框。
/// FX3: 接收 [controller] + [messageSeq], 内部监听; refresh 完成后自动用最新 snapshot.
Future<void> showChatReadReceiptPopover({
  required BuildContext context,
  required Offset globalPosition,
  required ChatReceiptsController controller,
  required int messageSeq,
  required Size overlaySize,
}) async {
  const popoverW = 260.0;
  // 估算高度: 用当前 cached snapshot 算; refresh 后内容变化 popover 内部自适应 (ListView).
  final initial = controller.snapshotFor(messageSeq);
  final estRows = (initial == null
          ? 1
          : (initial.readMembers.length + initial.unreadMembers.length))
      .clamp(1, 5);
  final popoverH = (44 + 36 + 48.0 * estRows + 12).clamp(140.0, 360.0);
  double x = globalPosition.dx;
  double y = globalPosition.dy;
  if (x + popoverW > overlaySize.width - 8) {
    x = overlaySize.width - popoverW - 8;
  }
  if (y + popoverH > overlaySize.height - 8) {
    y = overlaySize.height - popoverH - 8;
  }
  if (x < 8) x = 8;
  if (y < 8) y = 8;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    useRootNavigator: false,
    builder: (ctx) {
      return Stack(
        children: [
          Positioned(
            left: x,
            top: y,
            width: popoverW,
            child: _PopoverCard(
              controller: controller,
              messageSeq: messageSeq
            ),
          ),
        ],
      );
    },
  );
}

class _PopoverCard extends StatefulWidget {
  const _PopoverCard({
    required this.controller,
    required this.messageSeq
  });
  final ChatReceiptsController controller;
  final int messageSeq;

  @override
  State<_PopoverCard> createState() => _PopoverCardState();
}

class _PopoverCardState extends State<_PopoverCard> {
  int _tab = 0; // 0=已读, 1=未读

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.controller.snapshotFor(widget.messageSeq);
    // refresh 进行中时 snap 可能仍是旧值; controller 拿到新值会 notify → 重建.
    // snap=null (例如缓存被 invalidate 后) → popover 仅显示空 tab, 不闪退.
    final readMembers =
        snap == null ? const <ChatReceiptMember>[] : snap.readMembers;
    final unreadMembers =
        snap == null ? const <ChatReceiptMember>[] : snap.unreadMembers;
    final readCount = snap?.readCount ?? 0;
    final unreadCount = snap?.unreadCount ?? 0;
    final members = _tab == 0 ? readMembers : unreadMembers;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEAEAEA)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tab row
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  _TabButton(
                    label: '$readCount 已读',
                    active: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: 18),
                  _TabButton(
                    label: '$unreadCount 未读',
                    active: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF0F2F5)),
            // member list
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: members.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          '暂无成员',
                          style:
                              TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: members.length,
                      itemBuilder: (_, i) => _MemberRow(member: members[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? const Color(0xFF2F80ED) : const Color(0xFF4E5969),
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});
  final ChatReceiptMember member;

  @override
  Widget build(BuildContext context) {
    final subtitle = member.subtitle.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          ChatAvatar(
            url: member.avatar.isEmpty ? null : member.avatar,
            fallbackText: member.displayName,
            kind: ChatAvatarKind.user,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.displayName.isEmpty ? '匿名' : member.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF1D2129),
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF86909C),
                        height: 1.0,
                      ),
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
