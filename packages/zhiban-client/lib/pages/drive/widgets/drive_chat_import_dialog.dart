import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_icon.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<List<String>?> showDriveChatImportDialog(
  BuildContext context,
  WidgetRef ref, {
  String title = '从聊天文件中选择',
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (PlatformUtils.isMobile) {
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => UncontrolledProviderScope(
        container: container,
        child: _ChatImportDialog(title: title),
      ),
    );
  }
  return showDialog<List<String>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => UncontrolledProviderScope(
      container: container,
      child: _ChatImportDialog(title: title),
    ),
  );
}

bool _isChatImportableConversation(ConversationItem c) =>
    c.kind == 'agent_direct' || c.kind == 'single';

class _ChatImportDialog extends ConsumerStatefulWidget {
  const _ChatImportDialog({required this.title});
  final String title;

  @override
  ConsumerState<_ChatImportDialog> createState() => _ChatImportDialogState();
}

class _ChatImportDialogState extends ConsumerState<_ChatImportDialog> {
  String _selectedConversationUuid = '';
  String _query = '';
  // 选中的 drive_file_uuid → ChatAttachment(回显数量 / 顺序)
  final Map<String, ChatAttachment> _selected = <String, ChatAttachment>{};

  @override
  Widget build(BuildContext context) {
    if (PlatformUtils.isMobile) return _buildMobile(context);

    return UiPickerDialog(
      size: UiDialogSize.wide,
      maxHeight: 600,
      child: SizedBox(
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 260,
                    child: Container(
                      decoration: const BoxDecoration(
                        border: Border(
                          right: BorderSide(color: Color(0xFFF0F0F0), width: 1),
                        ),
                      ),
                      child: _LeftPane(
                        selectedConversationUuid: _selectedConversationUuid,
                        onSelectConversation: (uuid) => setState(() {
                          _selectedConversationUuid = uuid;
                        }),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _RightPane(
                      conversationUuid: _selectedConversationUuid,
                      query: _query,
                      selectedFileUuids: _selected.keys.toSet(),
                      onQueryChanged: (v) => setState(() => _query = v),
                      onToggle: (item) => setState(() {
                        if (_selected.containsKey(item.driveFileUuid)) {
                          _selected.remove(item.driveFileUuid);
                        } else {
                          _selected[item.driveFileUuid] = item;
                        }
                      }),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFDDE2EA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          _buildHeader(context),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          SizedBox(
            height: _selectedConversationUuid.isEmpty ? 220 : 96,
            child: _ConversationStrip(
              selectedConversationUuid: _selectedConversationUuid,
              onSelectConversation: (uuid) => setState(() {
                _selectedConversationUuid = uuid;
              }),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Expanded(
            child: _RightPane(
              conversationUuid: _selectedConversationUuid,
              query: _query,
              selectedFileUuids: _selected.keys.toSet(),
              scrollController: scrollController,
              onQueryChanged: (v) => setState(() => _query = v),
              onToggle: (item) => setState(() {
                if (_selected.containsKey(item.driveFileUuid)) {
                  _selected.remove(item.driveFileUuid);
                } else {
                  _selected[item.driveFileUuid] = item;
                }
              }),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        isMobile ? 10 : 14,
        isMobile ? 12 : 16,
        12,
      ),
      child: isMobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiSheetHeader(
                  title: widget.title,
                  onClose: () => Navigator.pop(context),
                ),
                const SizedBox(height: 10),
                UiSearchField(
                  hintText: '搜索',
                  onChanged: (v) => setState(() => _query = v),
                  borderRadius: 8,
                  fillColor: const Color(0xFFF7F8FA),
                ),
              ],
            )
          : UiSheetHeader(
              title: widget.title,
              onClose: () => Navigator.pop(context),
              trailing: SizedBox(
                width: 220,
                child: UiSearchField(
                  hintText: '搜索',
                  showBorder: false,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final hasSelection = _selected.isNotEmpty;
    final isMobile = PlatformUtils.isMobile;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        10,
        isMobile ? 16 : 24,
        isMobile ? 14 : 12,
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length} 项',
            style: const TextStyle(fontSize: 13, color: Color(0xFF8C8C8C)),
          ),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF165DFF),
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 20 : 22,
                vertical: isMobile ? 11 : 9,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: hasSelection
                ? () => Navigator.pop(context, _selected.keys.toList())
                : null,
            child: const Text('导入'),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF595959),
              textStyle: const TextStyle(fontSize: 14),
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 14 : 18,
                vertical: isMobile ? 11 : 9,
              ),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

class _ConversationStrip extends ConsumerWidget {
  const _ConversationStrip({
    required this.selectedConversationUuid,
    required this.onSelectConversation,
  });

  final String selectedConversationUuid;
  final ValueChanged<String> onSelectConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convsAsync = ref.watch(conversationsProvider);
    return convsAsync.when(
      loading: () => const Center(child: CupertinoActivityIndicator(radius: 9)),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          '加载会话失败:$e',
          style: const TextStyle(fontSize: 12, color: Color(0xFFE5484D)),
        ),
      ),
      data: (all) {
        final list = all.where(_isChatImportableConversation).toList();
        if (list.isEmpty) {
          return const Center(
            child: Text(
              '暂无可导入的数字员工会话',
              style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C)),
            ),
          );
        }
        final selectedOnly = selectedConversationUuid.isEmpty
            ? list
            : list
                .where((c) => c.conversationId == selectedConversationUuid)
                .toList();
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          scrollDirection: Axis.horizontal,
          itemCount: selectedOnly.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final conversation = selectedOnly[i];
            final selected =
                conversation.conversationId == selectedConversationUuid;
            return _MobileConversationChip(
              conversation: conversation,
              selected: selected,
              onTap: () => onSelectConversation(conversation.conversationId),
            );
          },
        );
      },
    );
  }
}

class _MobileConversationChip extends StatelessWidget {
  const _MobileConversationChip({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final ConversationItem conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = conversation.title.isNotEmpty
        ? conversation.title
        : conversation.agentName;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: selected ? 180 : 156,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE6F0FF) : Colors.white,
          border: Border.all(
            color: selected ? const Color(0xFFB8D4FF) : const Color(0xFFE5E7EB),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            _ConvAvatar(conversation: conversation),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: const Color(0xFF1F2329),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftPane extends ConsumerWidget {
  const _LeftPane({
    required this.selectedConversationUuid,
    required this.onSelectConversation,
  });

  final String selectedConversationUuid;
  final ValueChanged<String> onSelectConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convsAsync = ref.watch(conversationsProvider);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      children: [
        convsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CupertinoActivityIndicator(radius: 9)
            ),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Text('加载会话失败:$e',
                style: const TextStyle(fontSize: 12, color: Color(0xFFE5484D))),
          ),
          data: (all) {
            final list = all.where(_isChatImportableConversation).toList();
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                child: Text('暂无可导入的数字员工会话',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in list)
                  _ConversationRow(
                    conversation: c,
                    selected: c.conversationId == selectedConversationUuid,
                    onTap: () => onSelectConversation(c.conversationId),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });
  final ConversationItem conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const selectedBg = Color(0xFFE6F0FF);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              _ConvAvatar(conversation: conversation),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conversation.title.isNotEmpty
                      ? conversation.title
                      : conversation.agentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF1F2329),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConvAvatar extends StatelessWidget {
  const _ConvAvatar({required this.conversation});
  final ConversationItem conversation;

  @override
  Widget build(BuildContext context) {
    final url = conversation.agentAvatarUrl ?? '';
    if (url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(0xFFEDF2FF),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: const Icon(CupertinoIcons.person_fill,
          size: 12, color: Color(0xFF165DFF)),
    );
  }
}

class _RightPane extends ConsumerWidget {
  const _RightPane({
    required this.conversationUuid,
    required this.query,
    required this.selectedFileUuids,
    required this.onQueryChanged,
    required this.onToggle,
    this.scrollController,
  });

  final String conversationUuid;
  final String query;
  final Set<String> selectedFileUuids;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<ChatAttachment> onToggle;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (conversationUuid.trim().isEmpty) {
      return const Center(
        child: Text(
          '请先选择一个会话',
          style: TextStyle(color: Color(0xFF8C8C8C))
        ),
      );
    }

    final async = ref.watch(driveChatAttachmentsProvider(conversationUuid.trim()));

    return async.when(
      loading: () =>
          const Center(child: CupertinoActivityIndicator(radius: 12)),
      error: (e, _) => Center(
        child:
            Text('加载失败:$e', style: const TextStyle(color: Color(0xFFE5484D))),
      ),
      data: (items) {
        var filtered = items;
        if (query.trim().isNotEmpty) {
          final q = query.trim().toLowerCase();
          filtered =
              items.where((f) => f.fileName.toLowerCase().contains(q)).toList();
        }
        if (filtered.isEmpty) {
          return const Center(
            child: Text('暂无附件', style: TextStyle(color: Color(0xFF8C8C8C))),
          );
        }
        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: filtered.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFFF5F5F5)),
          itemBuilder: (_, i) {
            final att = filtered[i];
            final selected = selectedFileUuids.contains(att.driveFileUuid);
            return _AttachmentRow(
              attachment: att,
              selected: selected,
              onTap: () => onToggle(att),
            );
          },
        );
      },
    );
  }
}

class _AttachmentRow extends StatefulWidget {
  const _AttachmentRow({
    required this.attachment,
    required this.selected,
    required this.onTap,
  });
  final ChatAttachment attachment;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AttachmentRow> createState() => _AttachmentRowState();
}

class _AttachmentRowState extends State<_AttachmentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final subtitleParts = <String>[];
    if (a.role == 'assistant_output' && a.agentName.isNotEmpty) {
      subtitleParts.add('来自:${a.agentName}');
    } else if (a.role == 'user_input') {
      subtitleParts.add('我上传的');
    } else if (a.agentName.isNotEmpty) {
      subtitleParts.add(a.agentName);
    }
    final subtitle = subtitleParts.join(' · ');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: widget.selected
              ? const Color(0xFFF0F6FF)
              : (_hover ? const Color(0xFFFAFAFA) : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: _CheckBox(checked: widget.selected),
              ),
              const SizedBox(width: 10),
              DriveFileIcon(mimeType: a.mimeType, name: a.fileName, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      a.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8C8C8C),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                a.sizeDisplay,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8C8C8C)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? const Color(0xFF165DFF) : Colors.white,
        border: Border.all(
          color: checked ? const Color(0xFF165DFF) : const Color(0xFFD9D9D9),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: checked
          ? const Icon(Icons.check, size: 12, color: Colors.white)
          : null,
    );
  }
}
