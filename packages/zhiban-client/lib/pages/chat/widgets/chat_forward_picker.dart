import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';

/// F09 转发 v1: 文本转发 target picker dialog (2026-06 升级支持多目标).
///
/// 见 `docs/contracts/agent-bus-client-contract.md` §「消息操作菜单 v2」.
///
/// 仅列出**已存在**会话 (复用 `conversationsProvider` 快照, 不走通讯录拉取);
/// kind ∈ {human_direct, group}, agent_direct 不在列表 (避免触发 Agent 误用);
/// 无 `wukongChannelId` 的会话也不在列表 (无 IM 通道)。
///
/// 模式:
///   - **单选 (multi=false)**: 点行立即 pop 返回 `[item]`;无确认按钮。
///   - **多选 (multi=true)**: 行左侧 checkbox + 整行点击 toggle;底部确认按钮返回所有已选。
///
/// 调用方一律收 `List<ConversationItem>?` (null=用户取消);单选时长度恒为 1。
class ChatForwardPickerDialog extends ConsumerStatefulWidget {
  const ChatForwardPickerDialog({
    super.key,
    this.title = '转发到…',
    this.subtitle,
    this.multi = false,
  });

  final String title;
  final String? subtitle;

  /// false=单选 (点行立即 pop), true=多选 (checkbox + 确认按钮)。
  final bool multi;

  @override
  ConsumerState<ChatForwardPickerDialog> createState() =>
      _ChatForwardPickerDialogState();
}

class _ChatForwardPickerDialogState
    extends ConsumerState<ChatForwardPickerDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _q = '';
  // selectionKey = (conversationId)。搜索时不清除已选 (保留跨搜索状态)。
  final Set<String> _selectedKeys = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _keyOf(ConversationItem c) => c.conversationId;

  void _toggle(ConversationItem c) {
    final k = _keyOf(c);
    setState(() {
      if (_selectedKeys.contains(k)) {
        _selectedKeys.remove(k);
      } else {
        _selectedKeys.add(k);
      }
    });
  }

  List<ConversationItem> _collectSelected(List<ConversationItem> all) {
    final out = <ConversationItem>[];
    for (final c in all) {
      if (_selectedKeys.contains(_keyOf(c))) out.add(c);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(conversationsProvider);
    final all = async.asData?.value ?? const <ConversationItem>[];
    final filtered = filterForwardTargets(all, _q);
    return UiPickerDialog(
      size: UiDialogSize.compact,
      maxHeight: 540,
      child: SizedBox(
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 14, 12),
              child: UiSheetHeader(
                title: widget.title,
                subtitle:
                    (widget.subtitle ?? '').isEmpty ? null : widget.subtitle,
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: UiSearchField(
                hintText: '搜索同事 / 群聊',
                showBorder: false,
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: async.isLoading && all.isEmpty
                  ? const Center(child: CupertinoActivityIndicator())
                  : filtered.isEmpty
                      ? const Center(
                          child: Text('没有匹配的会话',
                              style: TextStyle(
                                  color: Color(0xFF86909C), fontSize: 13)))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(
                              height: 1, color: Color(0xFFF1F3F5)),
                          itemBuilder: (_, i) {
                            final c = filtered[i];
                            final checked = _selectedKeys.contains(_keyOf(c));
                            return _ForwardTargetTile(
                              item: c,
                              multi: widget.multi,
                              checked: checked,
                              onTap: () {
                                if (widget.multi) {
                                  _toggle(c);
                                } else {
                                  Navigator.of(context)
                                      .pop(<ConversationItem>[c]);
                                }
                              },
                            );
                          },
                        ),
            ),
            if (widget.multi)
              _MultiSelectFooter(
                selectedCount: _selectedKeys.length,
                onCancel: () => Navigator.of(context).pop(),
                onConfirm: _selectedKeys.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_collectSelected(all)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 转发目标过滤纯函数: 只展示 human_direct + group; 关键字按 title 包含匹配 (大小写不敏感).
/// 不展示 agent_direct (避免转发误触发 Agent), 不展示无 wukongChannelId 的会话 (无 IM 通道).
List<ConversationItem> filterForwardTargets(
    List<ConversationItem> all, String q) {
  final out = <ConversationItem>[];
  final qq = q.trim().toLowerCase();
  for (final c in all) {
    if (!(c.isHumanDirect || c.isGroup)) continue;
    final ch = (c.wukongChannelId ?? '').trim();
    if (ch.isEmpty) continue;
    if (qq.isEmpty) {
      out.add(c);
    } else if (c.title.toLowerCase().contains(qq)) {
      out.add(c);
    }
  }
  return out;
}

/// 给定当前所有 [selected] 选中项 + [next] 经过 (搜索过滤/排序) 后的可见列表,
/// 返回搜索后仍然有效的 selection (按 conversationId 比对; 不存在的会话保留也无害,
/// 但**确认时**仍以原始全量 list 为锚回填,避免搜索过滤掉视图但用户其实想转发到那个会话)。
///
/// 这是个纯函数, 主要给测试用; widget 真实状态用 [_selectedKeys] 集合。
Set<String> filteredVisibleSelection(
    Set<String> selectedConversationIds, List<ConversationItem> visible) {
  final visibleIds = visible.map((c) => c.conversationId).toSet();
  return selectedConversationIds.intersection(visibleIds);
}

class _ForwardTargetTile extends StatelessWidget {
  const _ForwardTargetTile({
    required this.item,
    required this.multi,
    required this.checked,
    required this.onTap,
  });
  final ConversationItem item;
  final bool multi;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isGroup = item.isGroup;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (multi) ...[
              _ForwardCheckbox(checked: checked),
              const SizedBox(width: 8),
            ],
            ChatAvatar(
              url: item.convAvatar,
              fallbackText: item.title,
              kind: ChatAvatarKind.user,
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF1D2129))),
                  const SizedBox(height: 2),
                  Text(isGroup ? '群聊' : '同事',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF86909C))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForwardCheckbox extends StatelessWidget {
  const _ForwardCheckbox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: checked ? const Color(0xFF2563EB) : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: checked ? const Color(0xFF2563EB) : const Color(0xFFCBD3DD),
          width: 1.4,
        ),
      ),
      child: checked
          ? const Icon(CupertinoIcons.checkmark, size: 12, color: Colors.white)
          : null,
    );
  }
}

class _MultiSelectFooter extends StatelessWidget {
  const _MultiSelectFooter({
    required this.selectedCount,
    required this.onCancel,
    this.onConfirm,
  });
  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFF1F3F5))),
      ),
      child: Row(
        children: [
          Text('已选 $selectedCount 个会话',
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF4E5969)),
              ),
          const Spacer(),
          TextButton(
            onPressed: onCancel,
            child: const Text('取消')
          ),
          const SizedBox(width: 6),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}

/// 展示转发选会话 dialog (单选 = legacy; multi=true 支持多目标)。
///
/// 返回选中目标列表; null=用户取消; 空列表绝不返回 (多选时无选未确认就只能 cancel)。
Future<List<ConversationItem>?> showChatForwardPickerDialog(
  BuildContext context, {
  String title = '转发到…',
  String? subtitle,
  bool multi = false,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return showDialog<List<ConversationItem>>(
    context: context,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: ChatForwardPickerDialog(
        title: title,
        subtitle: subtitle,
        multi: multi,
      ),
    ),
  );
}
