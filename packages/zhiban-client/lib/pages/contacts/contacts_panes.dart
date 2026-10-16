import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';
import 'package:zhiban_client/pages/contacts/member_invite_api.dart';
import 'package:zhiban_client/pages/contacts/widgets/add_member_dialog.dart';
import 'package:zhiban_client/pages/contacts/contacts_shared_widgets.dart';
import 'package:zhiban_client/pages/contacts/contacts_skeletons.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

class AgentsPane extends ConsumerWidget {
  const AgentsPane({
    super.key,
    required this.selectedAgent,
    required this.selectedFilter,
    required this.onSelect,
    required this.onMessage,
  });

  final ContactAgent? selectedAgent;
  final AgentListFilter selectedFilter;
  final ValueChanged<ContactAgent> onSelect;
  final ValueChanged<ContactAgent> onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = selectedAgent;
    if (selected != null) {
      return _PaneScaffold(
        eyebrow: 'NEXWORK / 通讯录',
        title: selected.displayName,
        showHeader: false,
        trailing: const SizedBox.shrink(),
        child: _AgentDetailStage(
          agent: selected,
          onMessage: () => onMessage(selected),
        ),
      );
    }

    final agents = ref.watch(contactAgentsProvider);
    // 新建/编辑数字员工统一走「数字员工」页，通讯录不再提供创建入口。
    return _PaneScaffold(
      eyebrow: 'NEXWORK / 通讯录',
      title: '数字员工',
      breadcrumbLabels: agentBreadcrumbLabels(selectedFilter),
      trailing: const SizedBox.shrink(),
      child: agents.when(
        data: (snapshot) {
          final items = filteredAgents(snapshot, selectedFilter);
          if (items.isEmpty) {
            return const EmptyState(text: '暂无数字员工');
          }
          return ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
            children: [
              const _AgentsHeader(),
              const SizedBox(height: 8),
              for (final item in items)
                AgentRow(
                  agent: item,
                  onTap: () => onSelect(item)
                ),
            ],
          );
        },
        loading: () => const ContactsRowsSkeleton(kind: ContactsRowsKind.agent),
        error: (error, _) => PaneError(message: '$error'),
      ),
    );
  }
}

class OrgMembersPane extends ConsumerWidget {
  const OrgMembersPane({
    super.key,
    required this.selectedPerson,
    required this.onHumanSelected,
    required this.onMessage,
    required this.onAgentMessage,
    required this.onVoiceCall,
    required this.onDepartmentSelected,
  });

  final ContactPerson? selectedPerson;
  final ValueChanged<ContactPerson> onHumanSelected;
  final ValueChanged<ContactPerson> onMessage;
  // doc-13 §C: 点部门内数字员工 → 进入数字员工单聊（区别于 human onMessage 走 C2C）。
  final ValueChanged<ContactPerson> onAgentMessage;

  /// 名片「语音通话」: 仅 human 同事开放 (跳转对话后发起 1v1 RTC); agent 维持敬请期待。
  final ValueChanged<ContactPerson> onVoiceCall;

  /// 面包屑点祖先部门时跳转过去（PC 面包屑之前是纯文字不可点，这里补上）。
  final ValueChanged<ContactDepartment> onDepartmentSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (selectedPerson != null) {
      return _PaneScaffold(
        eyebrow: 'NEXWORK / 组织',
        title: selectedPerson!.displayName,
        showHeader: false,
        trailing: const SizedBox.shrink(),
        child: _PersonDetailStage(
          person: selectedPerson!,
          onMessage: () {
            final p = selectedPerson!;
            // human → /direct-rooms C2C; agent → 数字员工单聊 (doc-13 §C).
            if (p.isAgent) {
              onAgentMessage(p);
            } else {
              onMessage(p);
            }
          },
          onVoiceCall: selectedPerson!.isHuman && selectedPerson!.canChat
              ? () => onVoiceCall(selectedPerson!)
              : null,
        ),
      );
    }

    final selected = ref.watch(selectedContactDepartmentProvider);
    final tree = ref.watch(contactTreeProvider).value ?? const [];
    final members = ref.watch(contactMembersProvider);
    // F28: 「添加企业成员」只挂组织架构根部门 header（selected 是树顶层节点），
    // 且当前租户 scope 需有 tenant.member.invite（fail-closed，取不到即隐藏）。
    final isRootDept =
        selected != null && tree.any((d) => d.id == selected.id);
    final canInvite = ref.watch(canInviteMemberProvider).value ?? false;
    final breadcrumbPath = departmentBreadcrumbPath(tree, selected);
    return _PaneScaffold(
      eyebrow: 'NEXWORK / 组织',
      title: selected?.name ?? '成员列表',
      breadcrumbLabels: selected == null
          ? const ['成员列表']
          : breadcrumbPath.map((d) => d.name).toList(growable: false),
      breadcrumbOnTaps: selected == null
          ? null
          : [
              for (var i = 0; i < breadcrumbPath.length; i++)
                i == breadcrumbPath.length - 1
                    ? null
                    : () => onDepartmentSelected(breadcrumbPath[i]),
            ],
      showHeader: selectedPerson == null,
      trailing: isRootDept && canInvite
          ? const _AddMemberEntryButton()
          : const SizedBox.shrink(),
      child: members.when(
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(text: '暂无成员');
          }
          return ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
            children: [
              const _MembersHeader(),
              const SizedBox(height: 8),
              for (final item in items)
                _MemberRow(
                  item: item,
                  // 人员 → 选中看详情；数字员工 → 直接进单聊（doc-13 §C）。
                  onTap: item.isHuman
                      ? () => onHumanSelected(item)
                      : () => onAgentMessage(item),
                ),
            ],
          );
        },
        loading: () =>
            const ContactsRowsSkeleton(kind: ContactsRowsKind.member),
        error: (error, _) => PaneError(message: '$error'),
      ),
    );
  }
}

/// F28 组织架构根部门 header 右侧「添加企业成员」入口（仅管理员可见）。
class _AddMemberEntryButton extends StatelessWidget {
  const _AddMemberEntryButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: OutlinedButton.icon(
        onPressed: () => showAddMemberDialog(context),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.45)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6)
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        icon: const Icon(CupertinoIcons.person_add, size: 15),
        label: const Text(
          '添加企业成员',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _PaneScaffold extends StatelessWidget {
  const _PaneScaffold({
    required this.eyebrow,
    required this.title,
    required this.trailing,
    required this.child,
    this.breadcrumbLabels,
    this.breadcrumbOnTaps,
    this.showHeader = true,
  });

  final String eyebrow;
  final String title;
  final Widget trailing;
  final Widget child;
  final List<String>? breadcrumbLabels;
  final List<VoidCallback?>? breadcrumbOnTaps;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final effectiveBreadcrumbLabels =
        breadcrumbLabels ?? contactsBreadcrumbLabels(eyebrow, title);
    return Column(
      children: [
        if (showHeader)
          Container(
            padding: const EdgeInsets.fromLTRB(42, 24, 34, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFE9EEF6))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: contactsBreadcrumbWidgets(
                            effectiveBreadcrumbLabels,
                            onTaps: breadcrumbOnTaps,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                trailing,
              ],
            ),
          ),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(color: ColorConfig.pageBackground),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _PersonDetailStage extends StatelessWidget {
  const _PersonDetailStage({
    required this.person,
    required this.onMessage,
    this.onVoiceCall,
  });

  final ContactPerson person;
  final VoidCallback onMessage;
  final VoidCallback? onVoiceCall;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: PersonDetailCard(
            person: person,
            onMessage: onMessage,
            onVoiceCall: onVoiceCall,
          ),
        ),
      ),
    );
  }
}

class PersonDetailCard extends ConsumerWidget {
  const PersonDetailCard({
    super.key,
    required this.person,
    required this.onMessage,
    this.onVoiceCall,
  });

  final ContactPerson person;
  final VoidCallback onMessage;

  /// null = 不开放 (agent / 自己): 按钮维持「敬请期待」置灰。
  final VoidCallback? onVoiceCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 企业 = 当前租户名称 (不再写死); accountInfoProvider 登录后即有缓存。
    final tenantName =
        ref.watch(accountInfoProvider).value?.tenantName.trim() ?? '';
    final title = person.displayName.isEmpty ? '未命名成员' : person.displayName;
    final department =
        person.departmentName.isEmpty ? '未分配部门' : person.departmentName;
    final role = person.subtitle.isEmpty
        ? (person.isAgent ? '数字员工' : '成员')
        : person.subtitle;
    return Container(
      padding: PlatformUtils.isMobile
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(30, 28, 30, 28),
      decoration: PlatformUtils.isMobile
          ? null
          : BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFDDE6F2)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x120F172A),
                  blurRadius: 26,
                  offset: Offset(0, 14),
                ),
              ],
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ContactAvatar(url: person.avatarUrl, name: title, size: 64),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.1,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          person.isAgent
                              ? CupertinoIcons.sparkles
                              : CupertinoIcons.person_fill,
                          size: 18,
                          color: const Color(0xFF0F6BFF),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      role,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: Color(0xFF466092),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Divider(height: 1, color: Color(0xFFDDE6F2)),
          const SizedBox(height: 20),
          _DetailLine(label: '邮箱', value: emailValue(person)),
          _DetailLine(label: '部门', value: department),
          _DetailLine(
              label: '企业', value: tenantName.isEmpty ? '—' : tenantName),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _DetailActionButton(
                  label: '发消息',
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  primary: true,
                  onTap: person.canChat ? onMessage : null,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: _DetailActionButton(
                  label: '写邮件',
                  icon: CupertinoIcons.envelope,
                  comingSoon: true,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _DetailActionButton(
                  label: '语音通话',
                  icon: CupertinoIcons.phone_fill,
                  comingSoon: onVoiceCall == null,
                  onTap: onVoiceCall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                height: 1.25,
                color: Color(0xFF536CA0),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                height: 1.25,
                color: Color(0xFF111827),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailActionButton extends StatelessWidget {
  const _DetailActionButton({
    required this.label,
    this.icon,
    this.primary = false,
    this.comingSoon = false,
    this.onTap,
  });

  final String label;

  /// 为 null 时只显示文字（如「更多」没有合适的图标）。
  final IconData? icon;
  final bool primary;

  /// 功能尚未上线的占位入口：置灰展示，点击提示「敬请期待」。
  final bool comingSoon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = (onTap != null || !primary) && !comingSoon;
    final Color fgColor = comingSoon
        ? const Color(0xFF9CA3AF)
        : (primary ? Colors.white : const Color(0xFF111827));
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: comingSoon ? () => BotToast.showText(text: '敬请期待') : onTap,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary
              ? (enabled ? null : const Color(0xFFBFD2F4))
              : (comingSoon
                  ? const Color(0xFFF9FAFB)
                  : const Color(0xFFF4F5F7)),
          gradient: primary && enabled
              ? const LinearGradient(
                  colors: [Color(0xFF2D8BF2), Color(0xFF1677EE)],
                )
              : null,
          borderRadius: BorderRadius.circular(7),
          border: primary ? null : Border.all(color: const Color(0xFFE7EAF0)),
          boxShadow: primary
              ? const [
                  BoxShadow(
                    color: Color(0x240F6BFF),
                    blurRadius: 16,
                    offset: Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: fgColor
              ),
              const SizedBox(width: 10),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: fgColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentsHeader extends StatelessWidget {
  const _AgentsHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(width: 320, child: Text('名称', style: contactsListHeaderStyle)),
        Expanded(child: Text('简介', style: contactsListHeaderStyle)),
        SizedBox(
          width: 92,
          child: Text(
            '来源',
            textAlign: TextAlign.right,
            style: contactsListHeaderStyle,
          ),
        ),
      ],
    );
  }
}

class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.agent,
    required this.onTap
  });

  final ContactAgent agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEEEEEE)),
        ),
        child: Row(
          children: [
            Flexible(
              flex: 1,
              child: Row(
                children: [
                  ContactAvatar(
                    url: agent.avatarUrl,
                    name: agent.displayName,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      agent.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Text(
                agent.subtitle.isEmpty ? '暂无简介' : agent.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280)
                ),
              ),
            ),
            SizedBox(
              width: 92,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SourceChip(source: agent.source)
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentDetailStage extends StatelessWidget {
  const _AgentDetailStage({
    required this.agent,
    required this.onMessage
  });

  final ContactAgent agent;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: AgentDetailCard(
            agent: agent,
            onMessage: onMessage
          ),
        ),
      ),
    );
  }
}

class AgentDetailCard extends StatelessWidget {
  const AgentDetailCard({
    super.key,
    required this.agent,
    required this.onMessage,
  });

  final ContactAgent agent;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final title = agent.displayName.isEmpty ? '未命名数字员工' : agent.displayName;
    final intro = agent.subtitle.isEmpty ? title : agent.subtitle;
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.1,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const AgentBotBadge(),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      agentCreatedByLabel(agent.source),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 28),
              ContactAvatar(url: agent.avatarUrl, name: title, size: 86),
            ],
          ),
          const SizedBox(height: 34),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 86,
                child: Text(
                  '简介',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  intro,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 38),
          Row(
            children: [
              Expanded(
                child: _DetailActionButton(
                  label: '发消息',
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  primary: true,
                  onTap: agent.canChat ? onMessage : null,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: _DetailActionButton(
                  label: '添加到群聊',
                  icon: CupertinoIcons.person_add,
                  comingSoon: true,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: _DetailActionButton(
                  label: '更多',
                  comingSoon: true
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.item, this.onTap});

  final ContactPerson item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEEEEEE)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 320,
              child: Row(
                children: [
                  ContactAvatar(
                      url: item.avatarUrl, name: item.displayName, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2329),
                            ),
                          ),
                        ),
                        if (item.isAgent) ...[
                          const SizedBox(width: 8),
                          SourceChip(source: item.source),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Text(
                item.subtitle.isEmpty ? '暂无描述' : item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280)
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersHeader extends StatelessWidget {
  const _MembersHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          SizedBox(
            width: 320,
            child: Text('姓名 / 职位', style: contactsListHeaderStyle),
          ),
          Expanded(
            child: Text('角色描述', style: contactsListHeaderStyle)
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: const TextStyle(color: Color(0xFF94A3B8))),
    );
  }
}

class PaneError extends StatelessWidget {
  const PaneError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFDC2626))
      ),
    );
  }
}
