import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

import 'package:zhiban_client/config/client_assets.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/group_grid_avatar.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_action_menu.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

final chatSidebarContactSearchProvider =
    FutureProvider.family<List<ContactPerson>, String>((ref, keyword) async {
  final q = keyword.trim();
  if (q.isEmpty) return const <ContactPerson>[];
  return ref.read(contactsServiceProvider).members(keyword: q, kind: 'human');
});

/// 会话行标题：P2.1 direct(人/agent)/group 用后端聚合的 `title`(对端/群名)；
/// legacy single 会话用 `agentName`。
String conversationDisplayTitle(ConversationItem item) {
  if (item.isDirect || item.kind == 'group') {
    final t = item.title.trim();
    if (t.isNotEmpty && t != '未命名会话') return t;
  }
  final name = item.agentName.trim();
  if (name.isNotEmpty) return name;
  final t = item.title.trim();
  return t.isEmpty ? '未命名会话' : t;
}

bool conversationMatchesKeyword(ConversationItem item, String keyword) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return true;
  return conversationDisplayTitle(item).toLowerCase().contains(kw) ||
      (item.lastMessage ?? '').toLowerCase().contains(kw);
}

bool digitalEmployeeConversationMatchesKeyword(
  ConversationItem item,
  String keyword,
) {
  if (item.kind != 'agent_direct' && item.kind != 'single') return false;
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return true;
  return conversationDisplayTitle(item).toLowerCase().contains(kw);
}

List<GroupAvatarMember> _groupAvatarMembersFor(ConversationItem item) {
  if (!item.isGroup) return const <GroupAvatarMember>[];
  final fromParticipants = [
    for (final p in item.participants)
      if (p.displayName.trim().isNotEmpty)
        GroupAvatarMember(
          avatarUrl: p.avatar.isEmpty ? null : p.avatar,
          name: p.displayName.trim(),
        ),
  ];
  if (fromParticipants.isNotEmpty) {
    return fromParticipants.take(9).toList(growable: false);
  }

  // 刚建群或旧 DTO 尚未聚合 participants 时，避免群头像退回机器人预留：
  // 先从"李娜、王芳"这类群名拆出成员名，用姓氏头像临时拼九宫格。
  final title = conversationDisplayTitle(item);
  final names = title
      .split(RegExp(r'[、,，/\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && e != '未命名会话')
      .take(9)
      .toList(growable: false);
  if (names.isEmpty) {
    return const [GroupAvatarMember(name: '群')];
  }
  return [
    for (final name in names) GroupAvatarMember(name: name)
  ];
}

class ConversationSearchBar extends StatelessWidget {
  const ConversationSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    this.padding = const EdgeInsets.fromLTRB(12, 4, 12, 8),
    this.onTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final field = UiSearchField(
      hintText: '搜索',
      fillColor: Colors.white,
      showBorder: false,
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onClear: onClear,
    );
    return ColoredBox(
      color: const Color(0xFFEEF0F4),
      child: Padding(
        padding: padding,
        child: onTap == null
            ? field
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: AbsorbPointer(child: field),
              ),
      ),
    );
  }
}

class ConversationListPanel extends StatelessWidget {
  const ConversationListPanel({
    super.key,
    this.padding = EdgeInsets.zero,
    required this.selectedConversationId,
    required this.conversations,
    required this.loadingConversations,
    required this.onConversationSelected,
    this.menuCallbacks = const ConversationMenuCallbacks(),
    this.mobileSwipeActions = false,
    this.emptyLabel = '暂无会话',
    this.showLoadingIndicator = true,
  });

  final EdgeInsetsGeometry padding;
  final String? selectedConversationId;
  final List<ConversationItem> conversations;
  final bool loadingConversations;
  final bool showLoadingIndicator;
  final ValueChanged<ConversationItem> onConversationSelected;
  final ConversationMenuCallbacks menuCallbacks;
  final bool mobileSwipeActions;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: tenantSwitchInProgress,
      builder: (context, switching, _) {
        // Old-tenant rows must not remain visible or interactive while identity
        // changes. The shared banner owns progress; failure restores this list.
        if (switching) return const SizedBox.shrink();
        return _buildList(context);
      },
    );
  }

  Widget _buildList(BuildContext context) {
    if (loadingConversations && conversations.isEmpty) {
      return showLoadingIndicator
          ? const Center(child: CupertinoActivityIndicator())
          : const SizedBox.shrink();
    }
    if (conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              package: ClientAssets.packageName,
              'assets/images/conversation_list_empty.svg',
              width: 120,
              height: 120,
            ),
            const SizedBox(height: 16),
            Text(
              emptyLabel,
              style: const TextStyle(color: Color(0xFF98A2B3), fontSize: 12),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: padding,
      child: Column(
        children: [
          for (var index = 0; index < conversations.length; index++)
            _buildRow(index),
        ],
      ),
    );
  }

  Widget _buildRow(int index) {
    final item = conversations[index];
    final selected = item.conversationId == selectedConversationId;
    final nextSelected = index + 1 < conversations.length &&
        conversations[index + 1].conversationId == selectedConversationId;
    return Column(
      key: ValueKey('conversation-row-${item.conversationId}'),
      children: [
        _ConversationListTile(
          item: item,
          selected: selected,
          onTap: () => onConversationSelected(item),
          menuCallbacks: menuCallbacks,
          mobileSwipeActions: mobileSwipeActions,
        ),
        Divider(
          height: 1,
          thickness: mobileSwipeActions ? 0.5 : 0.6,
          indent: mobileSwipeActions ? 69 : 60,
          endIndent: mobileSwipeActions ? 15 : 12,
          color: index < conversations.length - 1 && !selected && !nextSelected
              ? (mobileSwipeActions
                  ? const Color(0xFFEAEAEA)
                  : const Color(0xFFEFF3F8))
              : Colors.transparent,
        ),
      ],
    );
  }

  static DateTime? _parseIso(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');

  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static String _formatConversationTime(String? updatedAt) {
    final parsed = _parseIso(updatedAt);
    if (parsed == null) return '';

    final now = DateTime.now();
    final diff = now.difference(parsed);
    if (diff.isNegative) {
      return '${_pad2(parsed.hour)}:${_pad2(parsed.minute)}';
    }

    if (_isSameDay(now, parsed)) {
      if (diff.inMinutes <= 0) return '刚刚';
      if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
      return '${_pad2(parsed.hour)}:${_pad2(parsed.minute)}';
    }

    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameDay(yesterday, parsed)) {
      return '昨天';
    }

    final dayBeforeYesterday = now.subtract(const Duration(days: 2));
    if (_isSameDay(dayBeforeYesterday, parsed)) {
      return '前天';
    }

    if (parsed.year == now.year) {
      return '${parsed.month}月${parsed.day}日';
    }
    return '${parsed.year}-${_pad2(parsed.month)}-${_pad2(parsed.day)}';
  }
}

class ConversationListHeader extends StatelessWidget {
  const ConversationListHeader({
    super.key,
    required this.controller,
    required this.onCreateGroup,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final TextEditingController controller;
  final VoidCallback? onCreateGroup;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: UiSearchField(
              hintText: '搜索',
              borderRadius: 6,
              fillColor: const Color(0xFFF3F4F6),
              showBorder: false,
              height: 36,
              controller: controller,
              onChanged: onSearchChanged,
              onClear: onClearSearch,
            ),
          ),
          if (onCreateGroup != null) ...[
            const SizedBox(width: 8),
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: '发起群聊',
              onPressed: onCreateGroup,
              style: IconButton.styleFrom(
                fixedSize: const Size(34, 34),
                minimumSize: const Size(34, 34),
                maximumSize: const Size(34, 34),
                backgroundColor: const Color(0xFFF3F4F6),
                hoverColor: const Color(0xFFE8EDF4),
                highlightColor: const Color(0xFFDDE3EC),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              icon: const Icon(
                CupertinoIcons.add,
                size: 20,
                color: Color(0xFF4B5563),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ConversationSearchResults extends StatelessWidget {
  const ConversationSearchResults({
    super.key,
    required this.contacts,
    required this.digitalEmployees,
    required this.groups,
    required this.onContactSelected,
    required this.onConversationSelected,
  });

  final AsyncValue<List<ContactPerson>> contacts;
  final List<ConversationItem> digitalEmployees;
  final List<ConversationItem> groups;
  final ValueChanged<ContactPerson> onContactSelected;
  final ValueChanged<ConversationItem> onConversationSelected;

  bool get _hasLoadedContacts =>
      contacts.hasValue || contacts.hasError || !contacts.isLoading;

  @override
  Widget build(BuildContext context) {
    final contactItems = contacts.asData?.value ?? const <ContactPerson>[];
    final noResults = _hasLoadedContacts &&
        contactItems.isEmpty &&
        digitalEmployees.isEmpty &&
        groups.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      children: [
        const _SearchSectionTitle('联系人'),
        contacts.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(child: CupertinoActivityIndicator(radius: 9)),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Text(
              '联系人搜索失败',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          data: (items) => Column(
            children: [
              for (final person in items)
                _SearchContactRow(
                  person: person,
                  onTap: () => onContactSelected(person),
                ),
            ],
          ),
        ),
        if (digitalEmployees.isNotEmpty) ...[
          const _SearchSectionTitle('数字员工'),
          for (final digitalEmployee in digitalEmployees)
            _SearchConversationRow(
              item: digitalEmployee,
              onTap: () => onConversationSelected(digitalEmployee),
            ),
        ],
        if (groups.isNotEmpty) ...[
          const _SearchSectionTitle('群聊'),
          for (final group in groups)
            _SearchConversationRow(
              item: group,
              onTap: () => onConversationSelected(group),
            ),
        ],
        if (noResults)
          const Padding(
            padding: EdgeInsets.only(top: 72),
            child: Center(
              child: Text(
                '无匹配结果',
                style: TextStyle(color: Color(0xFF98A2B3), fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

class _SearchSectionTitle extends StatelessWidget {
  const _SearchSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF667085),
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SearchContactRow extends StatelessWidget {
  const _SearchContactRow({required this.person, required this.onTap});

  final ContactPerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = _contactSubtitle(person);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            _Avatar(
              url: person.avatarUrl,
              fallbackText: person.displayName,
              isUser: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.displayName.isEmpty ? '未命名联系人' : person.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF101828),
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
                        height: 1.25,
                        color: Color(0xFF98A2B3),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchConversationRow extends StatelessWidget {
  const _SearchConversationRow({required this.item, required this.onTap});

  final ConversationItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lastMessage = (item.lastMessage ?? '').trim();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            if (item.isGroup)
              GroupGridAvatar(
                members: _groupAvatarMembersFor(item),
                size: 42
              )
            else
              _Avatar(
                url: item.isDirect ? item.convAvatar : item.agentAvatarUrl,
                fallbackText: conversationDisplayTitle(item),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversationDisplayTitle(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF101828),
                    ),
                  ),
                  if (lastMessage.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: Color(0xFF667085),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _contactSubtitle(ContactPerson person) {
  final parts = <String>[
    if (person.departmentName.trim().isNotEmpty) person.departmentName.trim(),
    if (person.positionLabel.trim().isNotEmpty) person.positionLabel.trim(),
  ];
  if (parts.isNotEmpty) return parts.join(' / ');
  return person.subtitle.trim();
}

class _ConversationListTile extends StatefulWidget {
  const _ConversationListTile({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.menuCallbacks,
    required this.mobileSwipeActions,
  });

  final ConversationItem item;
  final bool selected;
  final VoidCallback onTap;
  final ConversationMenuCallbacks menuCallbacks;
  final bool mobileSwipeActions;

  @override
  State<_ConversationListTile> createState() => _ConversationListTileState();
}

class _ConversationListTileState extends State<_ConversationListTile> {
  bool _pressed = false;
  bool _contextMenuOpen = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    _setPressed(true);
    widget.onTap();
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      _setPressed(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final selected = widget.selected;
    final mobile = widget.mobileSwipeActions;
    final contextHighlighted = _contextMenuOpen && !selected;
    // F09 P2 v2: 真红点 = unread_count > 0 或 marked_unread。
    // 标为未读时显示"无数字"红点 (按 ConversationItem.hasUnreadDot 决策)。
    final unread = selected ? 0 : widget.item.unreadCount;
    final showRedDotOnly =
        !selected && unread == 0 && widget.item.markedUnread; // 仅红点(无数字)
    final backgroundColor = selected
        ? primaryColor
        : (contextHighlighted
            ? Colors.white
            : _pressed
                ? const Color(0xFFEFF4FF)
                : widget.item.pinned
                    ? const Color(0xFFEEF0F4) // 置顶行底纹，与对话页 AppBar 同色
                    : Colors.white);

    final tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTap: _handleTap,
      child: Container(
        key: ValueKey('conversation-tile-${widget.item.conversationId}'),
        // 移动端点击会话后需要即时背景反馈，表示当前行已经收到点击。
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 15 : 10,
          vertical: mobile ? 14 : 8,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: mobile || PlatformUtils.isMobile
              ? null
              : BorderRadius.circular(8),
          border: mobile
              ? null
              : Border.all(
                  color: contextHighlighted ? primaryColor : Colors.transparent,
                  width: 1.2,
                ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _AvatarWithBadge(
              // P2.1:direct(人/agent)用会话对端头像;legacy agent 会话用 agentAvatarUrl。
              url: widget.item.isDirect
                  ? widget.item.convAvatar
                  : widget.item.agentAvatarUrl,
              fallbackText: widget.item.title,
              unreadCount: unread,
              showRedDotOnly: showRedDotOnly,
              muted: widget.item.muted,
              isUser: widget.item.kind == 'human_direct', // 人↔人:用户默认头像
              // P2.3a:群聊用成员头像九宫格。
              gridMembers: widget.item.isGroup
                  ? _groupAvatarMembersFor(widget.item)
                  : null,
              size: mobile ? 44 : 42,
              borderRadius: mobile ? 10 : 8,
            ),
            SizedBox(width: mobile ? 10 : 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversationDisplayTitle(widget.item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: mobile ? 16 : 15,
                            fontWeight:
                                mobile ? FontWeight.w600 : FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : mobile
                                    ? const Color(0xFF333333)
                                    : const Color(0xFF101828),
                          ),
                        ),
                      ),
                      // 免打扰 icon (在标题右侧, 时间左侧; 不算 unread 徽标)
                      if (widget.item.muted) ...[
                        const SizedBox(width: 4),
                        Icon(
                          CupertinoIcons.bell_slash_fill,
                          size: 13,
                          color: selected
                              ? Colors.white70
                              : const Color(0xFFB0B7C3),
                        ),
                      ],
                      // 置顶 icon (与时间共行右侧)
                      if (widget.item.pinned) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.push_pin_rounded,
                          size: 13,
                          color: selected
                              ? Colors.white70
                              : const Color(0xFFB0B7C3),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        ConversationListPanel._formatConversationTime(
                          widget.item.displayTimeRaw,
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: selected
                              ? Colors.white70
                              : mobile
                                  ? const Color(0xFF999999)
                                  : const Color(0xFF98A2B3),
                          fontWeight:
                              mobile ? FontWeight.w400 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Consumer(
                    builder: (context, ref, _) {
                      final mentioned = ref.watch(
                        mentionedConversationIdsProvider.select(
                            (s) => s.contains(widget.item.conversationId)),
                      );
                      final preview =
                          (widget.item.lastMessage ?? '').trim().isEmpty
                              ? '暂无消息'
                              : (widget.item.lastMessage ?? '').trim();
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              mentioned ? '[有人@我] $preview' : preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.25,
                                fontWeight: mentioned
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: mentioned
                                    ? (selected
                                        ? Colors.white
                                        : const Color(0xFFE64545))
                                    : (selected
                                        ? Colors.white.withValues(alpha: 0.92)
                                        : mobile
                                            ? const Color(0xFF999999)
                                            : const Color(0xFF667085)),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.mobileSwipeActions) {
      return ConversationSwipeActionRegion(
        item: widget.item,
        callbacks: widget.menuCallbacks,
        child: tile,
      );
    }

    return ConversationActionRegion(
      item: widget.item,
      callbacks: widget.menuCallbacks,
      onMenuOpenChanged: (value) {
        if (!mounted || _contextMenuOpen == value) return;
        setState(() => _contextMenuOpen = value);
      },
      child: tile,
    );
  }
}

class _Avatar extends StatefulWidget {
  const _Avatar({
    this.url,
    this.fallbackText,
    this.isUser = false,
    this.size = 42,
    this.borderRadius = 8,
  });

  final String? url;
  final String? fallbackText;

  /// 人↔人会话:头像缺省时用「用户」默认头像;否则用 bot 默认头像。
  final bool isUser;
  final double size;
  final double borderRadius;

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> {
  late String _resolvedUrl;

  @override
  void initState() {
    super.initState();
    _resolveAvatar();
  }

  @override
  void didUpdateWidget(covariant _Avatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _resolveAvatar();
    }
  }

  void _resolveAvatar() {
    final raw = (widget.url ?? '').trim();
    final needsAuth = apiImageNeedsAuth(raw);
    _resolvedUrl =
        needsAuth ? apiImageResolveUrl(raw) : resolveAgentAvatarUrl(raw);
  }

  @override
  Widget build(BuildContext context) {
    // 后端给的多是 `/api/agent-bus/v1/assets/...` 这种相对路径,
    // 经 resolveAgentAvatarUrl 补 origin 后才能交给 CachedNetworkImage 走。
    // `/message-files/...` 等受保护图片还要带 Bearer,否则会回退成默认机器人头像。
    // SVG / `/portrait/default/` 这类不是头像的预留 URL 仍当无头像处理。
    final lower = _resolvedUrl.toLowerCase();
    final hasUrl = _resolvedUrl.isNotEmpty &&
        !lower.contains('.svg') &&
        !lower.contains('/svg') &&
        !lower.contains('/portrait/default/');
    final initial = firstAvatarDisplayChar(widget.fallbackText);
    if (!hasUrl && widget.isUser && initial.isNotEmpty) {
      return _InitialAvatar(
        size: widget.size,
        initial: initial,
        borderRadius: widget.borderRadius,
      );
    }
    final fallback = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Image.asset(
        package: ClientAssets.packageName,
        widget.isUser ? 'assets/user_icon.png' : 'assets/bot_icon.jpeg',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => CircleAvatar(
          radius: widget.size / 2,
          backgroundColor: const Color(0xFFE4E7EC),
          child: Icon(
            widget.isUser ? Icons.person_rounded : Icons.smart_toy_rounded,
            size: 18,
            color: const Color(0xFF667085),
          ),
        ),
      ),
    );
    if (!hasUrl) return fallback;
    // 认证头由 UiNetworkImage 内部同步解析（token 已在内存），不再用本地 FutureBuilder，
    // 避免每次挂载先闪一帧 bot 占位图。
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: UiNetworkImage(
        imageUrl: _resolvedUrl,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheKey: _resolvedUrl,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// 头像+未读徽标（圆点/数字）。徽标贴在头像右上角，超出 4px。
/// F09 P2 v2: 增加 [showRedDotOnly] (仅红点不显数字) 与 [muted] (免打扰时数字+灰色)。
class _AvatarWithBadge extends StatelessWidget {
  const _AvatarWithBadge({
    required this.url,
    this.fallbackText,
    required this.unreadCount,
    this.showRedDotOnly = false,
    this.muted = false,
    this.isUser = false,
    this.gridMembers,
    this.size = 42,
    this.borderRadius = 8,
  });

  final String? url;
  final String? fallbackText;
  final int unreadCount;

  /// 仅红点(无数字)。配合「标为未读」: unread_count=0 但 marked_unread=true。
  final bool showRedDotOnly;

  /// 免打扰: 有未读时也只显示「灰色」红点(参考飞书/微信免打扰), 不显示数字。
  final bool muted;
  final bool isUser;
  final double size;
  final double borderRadius;

  /// P2.3a:非空时(群聊)渲染成员头像九宫格,替代单一头像。
  final List<GroupAvatarMember>? gridMembers;

  @override
  Widget build(BuildContext context) {
    final grid = gridMembers;
    final hasUnread = unreadCount > 0 || showRedDotOnly;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: (grid != null && grid.isNotEmpty)
                ? GroupGridAvatar(
                    members: grid,
                    size: size,
                    borderRadius: borderRadius,
                  )
                : _Avatar(
                    url: url,
                    fallbackText: fallbackText,
                    isUser: isUser,
                    size: size,
                    borderRadius: borderRadius,
                  ),
          ),
          if (hasUnread)
            Positioned(
              right: -7,
              top: -7,
              child: _AvatarUnreadBadge(
                count: unreadCount,
                showDotOnly: showRedDotOnly || muted,
                muted: muted,
              ),
            ),
        ],
      ),
    );
  }
}

class _AvatarUnreadBadge extends StatelessWidget {
  const _AvatarUnreadBadge({
    required this.count,
    this.showDotOnly = false,
    this.muted = false,
  });

  final int count;

  /// 不显示数字, 仅 8px 圆点 (用于「标为未读」与「免打扰」)。
  final bool showDotOnly;

  /// 免打扰: 红改灰 (#C0C4CC); 与 showDotOnly 配合。
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? const Color(0xFFC0C4CC) : const Color(0xFFFF3B30);
    if (showDotOnly) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.2),
        ),
      );
    }
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: EdgeInsets.symmetric(horizontal: count >= 10 ? 5 : 0),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({
    required this.size,
    required this.initial,
    this.borderRadius = 8,
  });

  final double size;
  final String initial;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: avatarGradientColors(initial),
        ),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}
