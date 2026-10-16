import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart'
    show imMessageIdentity;

/// F09 多选 v1: 一次最多勾选的消息数. 见 docs/contracts/agent-bus-client-contract.md
/// §「消息操作菜单 v2」.
const int kChatMultiSelectMax = 50;

/// 多选模式 selection key: 复用 [imMessageIdentity] 的同款规则 (clientMsgNo 优先),
/// 这样和 _messageKeys / dedupe 完全一致, 不会因为 server ack 后 key 漂移.
String messageSelectionKey(ImMessage m) => imMessageIdentity(m);

/// 多选批量操作条: 底部悬浮胶囊,保留逐条转发 / 合并转发 / 删除 / 取消.
///
/// 视觉对齐办公 IM 的底部多选操作栏:白底圆角 + 轻阴影,图标在上、文字在下;
/// 取消为右侧圆形 X 按钮.
/// onForwardSeparate / onForwardMerged / onDelete / onCancel 为 null 时对应按钮 disable.
/// 计数为 0 时转发 / 删除全 disable。
///
/// **`forwarding=true` 防重入态 (CR-2026-06-P2)**:批量转发执行中, 调用方应:
///   ① 转发 callback 传 null (转发按钮灰显, 阻止同一批重复发送);
///   ② `onDelete` 传 null (避免发送期间同时改选择集);
///   ③ `onCancel` 传 null (避免转发中途取消选择 → mounted 后状态错乱);
///   ④ 同时设置 `forwarding=true`,「转发」动作切到 spinner, 提示用户「正在发送」。
/// 调用方传 null callback 后, 即便没显式设 `forwarding=true`, 按钮也是 disabled (callback null 守卫);
/// 但 `forwarding=true` 视觉切换是用户能看到的反馈, 应**同时**设置。
class ChatBatchActionBar extends StatelessWidget {
  const ChatBatchActionBar({
    super.key,
    required this.selectedCount,
    this.onCancel,
    this.onForwardSeparate,
    this.onForwardMerged,
    this.onDelete,
    this.forwarding = false,
  });

  final int selectedCount;
  final VoidCallback? onCancel;
  final VoidCallback? onForwardSeparate;
  final VoidCallback? onForwardMerged;
  final VoidCallback? onDelete;

  /// 批量转发执行态。true → 转发动作显示 spinner, 提示用户操作进行中。
  /// 按钮 disable 由 callback 是否传 null 决定 (避免出现「按钮亮但点了没反应」的歧义)。
  final bool forwarding;

  @override
  Widget build(BuildContext context) {
    final enabled = selectedCount > 0;
    return Container(
      key: const ValueKey('chat-batch-action-bar-shell'),
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE8EDF4), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BatchAction(
            icon: CupertinoIcons.arrowshape_turn_up_right,
            label: forwarding ? '转发中' : '逐条转发',
            enabled: enabled && onForwardSeparate != null,
            onTap: onForwardSeparate,
            loading: forwarding,
          ),
          const SizedBox(width: 10),
          _BatchAction(
            icon: CupertinoIcons.arrowshape_turn_up_right_fill,
            label: '合并转发',
            enabled: enabled && !forwarding && onForwardMerged != null,
            onTap: onForwardMerged,
          ),
          const SizedBox(width: 10),
          _BatchAction(
            icon: CupertinoIcons.trash,
            label: '删除',
            enabled: enabled && onDelete != null,
            onTap: onDelete,
          ),
          const SizedBox(width: 10),
          _BatchCancelAction(
            enabled: onCancel != null,
            onTap: onCancel
          ),
        ],
      ),
    );
  }
}

class _BatchCancelAction extends StatefulWidget {
  const _BatchCancelAction({
    required this.enabled,
    this.onTap
  });
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_BatchCancelAction> createState() => _BatchCancelActionState();
}

class _BatchCancelActionState extends State<_BatchCancelAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.enabled ? const Color(0xFF111827) : const Color(0xFFB0B8C1);
    return Tooltip(
      message: '取消',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: Semantics(
            button: true,
            label: '取消',
            enabled: widget.enabled,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hover && widget.enabled
                    ? const Color(0xFFEFF2F6)
                    : const Color(0xFFF4F6F9),
              ),
              alignment: Alignment.center,
              child: Icon(CupertinoIcons.xmark, size: 24, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchAction extends StatefulWidget {
  const _BatchAction({
    required this.icon,
    required this.label,
    required this.enabled,
    this.loading = false,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback? onTap;

  @override
  State<_BatchAction> createState() => _BatchActionState();
}

class _BatchActionState extends State<_BatchAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        !widget.enabled ? const Color(0xFFB0B8C1) : const Color(0xFF111827);
    final bg = (widget.enabled && _hover)
        ? const Color(0xFFF5F5F7)
        : Colors.transparent;
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minWidth: 58),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CupertinoActivityIndicator(radius: 9),
                )
              else
                Icon(widget.icon, size: 23, color: fg),
              const SizedBox(height: 4),
              Text(widget.label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: fg,
                    height: 1.1),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选模式下气泡左侧的圆形 checkbox; 透明区可点击, 整行点 toggle.
class ChatSelectionCheckbox extends StatelessWidget {
  const ChatSelectionCheckbox({
    super.key,
    required this.checked,
    required this.enabled,
  });

  final bool checked;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? const Color(0xFFD1D5DB)
        : checked
            ? const Color(0xFF2563EB)
            : const Color(0xFFCBD3DD);
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color:
            checked && enabled ? const Color(0xFF2563EB) : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.4),
      ),
      child: checked && enabled
          ? const Icon(CupertinoIcons.checkmark, size: 12, color: Colors.white)
          : null,
    );
  }
}

/// 把任意 [child] 包装成「多选模式可点击」: 单击整行 → toggle (仅在 enabled 时);
/// disabled (撤回 / pending 等) 时点击不响应, checkbox 也灰显 (上层负责 enabled).
/// checkbox 固定在消息行左侧, 对齐飞书/企业 IM 的多选体验。
class ChatSelectableBubble extends StatelessWidget {
  const ChatSelectableBubble({
    super.key,
    required this.checked,
    required this.enabled,
    required this.isPeer,
    required this.child,
    this.onToggle,
  });

  final bool checked;
  final bool enabled;
  final bool isPeer;
  final Widget child;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onToggle : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 8),
            child: ChatSelectionCheckbox(checked: checked, enabled: enabled),
          ),
          Expanded(child: IgnorePointer(child: child)),
        ],
      ),
    );
  }
}
