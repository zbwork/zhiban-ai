import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_avatar.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

const double _agentCardDescFontSize = 13;
const double _agentCardDescLineHeight = 1.45;
const int _agentCardDescMaxLines = 2;

const TextStyle _agentCardDescTextStyle = TextStyle(
  fontSize: _agentCardDescFontSize,
  height: _agentCardDescLineHeight,
  color: Color(0xFF5F6B7A),
  fontWeight: FontWeight.w500,
);

/// 用实际的系统字体缩放算预留高度，而不是按 1.0 倍写死——用户放大系统字体后
/// 固定像素高度会比真实渲染的文字矮，导致内容被裁切（见 issue 截图）。
double agentCardDescBlockHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_agentCardDescFontSize) *
    _agentCardDescLineHeight *
    _agentCardDescMaxLines;

const double _agentCapabilityChipFontSize = 12;
const double _agentCapabilityChipLineHeight = 1.12;
const double _agentCapabilityChipVerticalPadding = 6;

double agentCapabilityChipRowHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_agentCapabilityChipFontSize) *
        _agentCapabilityChipLineHeight +
    _agentCapabilityChipVerticalPadding * 2;

/// AgentCard 整卡高度（外层 padding + 头像行 + 两处固定高度内容块），随字体缩放同步
/// 变化。头像行按「带职位 pill」的更高分支算，保证跟同一 Wrap 行里任意 AgentCard
/// 对齐——非公式来源的高度（如 _AddMoreCard）应复用这个函数，不要另起一份数字。
double agentCardHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  const avatarSize = 40.0;
  final nameLineHeight = scaler.scale(15) * 1.18;
  final sourceTagHeight = 2 * 2 + scaler.scale(11) * 1.1;
  final positionPillHeight = 3 * 2 + scaler.scale(12) * 1.1;
  final tagRowHeight = sourceTagHeight > positionPillHeight
      ? sourceTagHeight
      : positionPillHeight;
  final nameColumnHeight = nameLineHeight + 6 + tagRowHeight;
  final headerRowHeight =
      avatarSize > nameColumnHeight ? avatarSize : nameColumnHeight;
  return 14 +
      headerRowHeight +
      8 +
      agentCardDescBlockHeight(context) +
      8 +
      agentCapabilityChipRowHeight(context) +
      12;
}

@visibleForTesting
bool debugShouldShowAgentCardMenu({
  required bool alwaysVisible,
  required bool cardActive,
}) {
  return alwaysVisible || cardActive;
}

@visibleForTesting
List<String> debugVisibleAgentCapabilityRowLabels({
  required List<String> skillNames,
  required List<String> appNames,
  required List<String> kbNames,
}) {
  return visibleCapabilityRows(
    skillNames: skillNames,
    appNames: appNames,
    kbNames: kbNames,
  ).map((row) => row.label).toList(growable: false);
}

List<String> dedupeCapabilityNames(Iterable<String> values) {
  final seen = <String>{};
  final out = <String>[];
  for (final value in values) {
    final name = value.trim();
    if (name.isEmpty || seen.contains(name)) continue;
    seen.add(name);
    out.add(name);
  }
  return out;
}

List<({String label, List<String> names})> visibleCapabilityRows({
  required List<String> skillNames,
  required List<String> appNames,
  required List<String> kbNames,
}) {
  return [
    if (skillNames.isNotEmpty) (label: '技能', names: skillNames),
    if (appNames.isNotEmpty) (label: '应用', names: appNames),
    if (kbNames.isNotEmpty) (label: '知识库', names: kbNames),
  ];
}

class AgentCard extends StatefulWidget {
  const AgentCard({
    super.key,
    required this.agent,
    required this.sourceLabel,
    required this.canEdit,
    this.mobile = false,
    this.menuAlwaysVisible = false,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final AgentItem agent;
  final String sourceLabel;
  final bool canEdit;
  final bool mobile;
  final bool menuAlwaysVisible;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<AgentCard> {
  bool _hover = false;
  bool _pressed = false;
  bool _menuExpanded = false;
  // 手指落在菜单按钮区域时置 true，阻止卡片 onTapDown 进入 pressed 态。
  bool _menuHit = false;

  bool get _active => _hover || _menuExpanded;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    if (value && _menuHit) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final desc =
        agent.description.trim().isEmpty ? '暂无简介' : agent.description.trim();
    final position = agent.positionLabel.trim();
    final skillNames = agent.skills
        .map((item) => item.skillName.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final showMenuButton = debugShouldShowAgentCardMenu(
      alwaysVisible: widget.menuAlwaysVisible,
      cardActive: _active,
    );
    final mobile = widget.mobile;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) {
        if (!mounted) return;
        setState(() => _hover = _menuExpanded);
      },
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTap: () {
          _setPressed(false);
          widget.onTap();
        },
        child: Container(
          key: mobile ? ValueKey('mobile-agent-card-${agent.agentId}') : null,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _pressed ? const Color(0xFFF4F8FF) : Colors.white,
            borderRadius: BorderRadius.circular(mobile ? 10 : 14),
            border: mobile
                ? null
                : Border.all(
                    color: _active
                        ? const Color(0xFFBDD0F5)
                        : const Color(0xFFE2E8F0),
                  ),
            boxShadow: [
              BoxShadow(
                color: mobile
                    ? const Color(0x1A000000)
                    : const Color(0xFF0F172A)
                        .withValues(alpha: _active ? 0.075 : 0.04),
                blurRadius: mobile ? 12 : (_active ? 16 : 10),
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: mobile
                    ? const EdgeInsets.fromLTRB(15, 20, 15, 20)
                    : const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AgentAvatar(
                          url: agent.avatarUrl,
                          size: mobile ? 42 : 40,
                        ),
                        SizedBox(width: mobile ? 15 : 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                    right: widget.canEdit ? 32 : 0),
                                child: Text(
                                  agent.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: mobile ? 16 : 15,
                                    fontWeight: mobile
                                        ? FontWeight.w600
                                        : FontWeight.w700,
                                    color: mobile
                                        ? const Color(0xFF333333)
                                        : const Color(0xFF111827),
                                    height: mobile ? 1.625 : 1.18,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  if (mobile)
                                    Flexible(
                                      child: AgentSourceTag(
                                        label: widget.sourceLabel,
                                        enterprise:
                                            widget.sourceLabel != '我创建的',
                                        mobile: true,
                                      ),
                                    )
                                  else
                                    AgentSourceTag(
                                      label: widget.sourceLabel,
                                      enterprise: widget.sourceLabel != '我创建的',
                                    ),
                                  if (!mobile && position.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Flexible(
                                        child:
                                            AgentPositionPill(label: position)),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (mobile) ...[
                      const SizedBox(height: 15),
                      const Divider(
                        key: ValueKey('mobile-agent-card-divider'),
                        height: 0.5,
                        thickness: 0.5,
                        color: Color(0xFFE6E6E6),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        desc,
                        maxLines: _agentCardDescMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 22 / 14,
                          color: Color(0xFF999999),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      if (skillNames.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _AgentSkillTagsRow(
                          names: skillNames,
                          mobile: true
                        ),
                      ],
                    ] else ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: agentCardDescBlockHeight(context),
                        child: Text(
                          desc,
                          maxLines: _agentCardDescMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: _agentCardDescTextStyle,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: agentCapabilityChipRowHeight(context),
                        child: skillNames.isEmpty
                            ? null
                            : _AgentSkillTagsRow(names: skillNames),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.canEdit)
                Positioned(
                  top: mobile ? 12 : 8,
                  right: mobile ? 12 : 8,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: showMenuButton ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !showMenuButton,
                      child: Listener(
                        onPointerDown: (_) => _menuHit = true,
                        onPointerUp: (_) => _menuHit = false,
                        onPointerCancel: (_) => _menuHit = false,
                        child: _AgentMenuButton(
                          filled: showMenuButton,
                          matchCardBackground: mobile,
                          onEdit: widget.onEdit,
                          onDelete: widget.onDelete,
                          onExpandedChanged: (expanded) {
                            if (!mounted) return;
                            setState(() {
                              _menuExpanded = expanded;
                              _hover = expanded;
                            });
                          },
                        ),
                      ),
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

class AgentCardSkeleton extends StatelessWidget {
  const AgentCardSkeleton({super.key, this.mobile = false});

  final bool mobile;

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return Container(
        padding: const EdgeInsets.fromLTRB(15, 20, 15, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                UiSkeletonBlock(width: 42, height: 42, radius: 21),
                SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UiSkeletonBlock(width: 112, height: 18, radius: 8),
                      SizedBox(height: 8),
                      UiSkeletonBlock(width: 80, height: 22, radius: 4),
                    ],
                  ),
                ),
                UiSkeletonBlock(width: 28, height: 28, radius: 8),
              ],
            ),
            const SizedBox(height: 15),
            const Divider(height: 0.5, thickness: 0.5),
            const SizedBox(height: 14),
            const UiSkeletonBlock(
              width: double.infinity,
              height: 14,
              radius: 6,
            ),
            const SizedBox(height: 8),
            const UiSkeletonBlock(width: 210, height: 14, radius: 6),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E6EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              UiSkeletonBlock(width: 48, height: 48, radius: 14),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UiSkeletonBlock(width: 122, height: 16, radius: 8),
                    SizedBox(height: 8),
                    UiSkeletonBlock(width: 88, height: 12, radius: 6),
                  ],
                ),
              ),
              UiSkeletonBlock(width: 28, height: 28, radius: 8),
            ],
          ),
          const SizedBox(height: 12),
          const UiSkeletonBlock(width: double.infinity, height: 12, radius: 6),
          const SizedBox(height: 7),
          const UiSkeletonBlock(width: 180, height: 12, radius: 6),
          const SizedBox(height: 12),
          Container(height: 1, color: const Color(0xFFF2F4F7)),
          const SizedBox(height: 12),
          const UiSkeletonBlock(width: double.infinity, height: 20, radius: 8),
          const SizedBox(height: 8),
          const UiSkeletonBlock(width: 210, height: 20, radius: 8),
        ],
      ),
    );
  }
}

class AgentSourceTag extends StatelessWidget {
  const AgentSourceTag({
    super.key,
    required this.label,
    required this.enterprise,
    this.mobile = false,
  });

  final String label;
  final bool enterprise;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: mobile
          ? const EdgeInsets.symmetric(horizontal: 6)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: mobile ? const Color(0xFFEDF6FF) : const Color(0xFFF3F7FF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment:
            mobile ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Icon(
            enterprise ? Icons.business_rounded : Icons.person_outline_rounded,
            size: mobile ? 12 : 11,
            color: mobile ? const Color(0xFF2B7EFE) : const Color(0xFF1D63F2),
          ),
          SizedBox(width: mobile ? 5 : 3),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: mobile ? 12 : 11,
                color:
                    mobile ? const Color(0xFF2B7EFE) : const Color(0xFF1D63F2),
                fontWeight: mobile ? FontWeight.w500 : FontWeight.w600,
                height: mobile ? 22 / 12 : 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentSkillTagsRow extends StatelessWidget {
  const _AgentSkillTagsRow({required this.names, this.mobile = false});

  final List<String> names;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < names.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == names.length - 1 ? 0 : 6),
              child: _AgentCapabilityChip(
                label: names[i],
                mobile: mobile
              ),
            ),
        ],
      ),
    );
  }
}

class AgentPositionPill extends StatelessWidget {
  const AgentPositionPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = _positionPillColors(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: colors.foreground,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}

({Color background, Color foreground}) _positionPillColors(String label) {
  const palettes = [
    (background: Color(0xFFEAF1FF), foreground: Color(0xFF2D6CDF)),
    (background: Color(0xFFEAF7E8), foreground: Color(0xFF4D8F3D)),
    (background: Color(0xFFF1EAFF), foreground: Color(0xFF7053D8)),
    (background: Color(0xFFFFF0E5), foreground: Color(0xFFC66D36)),
    (background: Color(0xFFE8F6F3), foreground: Color(0xFF168778)),
    (background: Color(0xFFFFF4CC), foreground: Color(0xFFB88700)),
  ];
  final sum = label.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return palettes[sum % palettes.length];
}

class AgentCapabilityRow extends StatelessWidget {
  const AgentCapabilityRow(
      {super.key, required this.label, required this.names});

  final String label;
  final List<String> names;

  static const _labelStyle = TextStyle(
    fontSize: 12,
    color: Color(0xFF98A2B3),
    fontWeight: FontWeight.w600,
    height: 1.5,
  );

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label:', maxLines: 1, style: _labelStyle),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final name in names) _AgentCapabilityChip(label: name),
          ],
        ),
      ],
    );
  }
}

class _AgentCapabilityChip extends StatelessWidget {
  const _AgentCapabilityChip({required this.label, this.mobile = false});

  final String label;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: mobile ? 22 : null,
      alignment: mobile ? Alignment.center : null,
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 9 : 10,
        vertical: mobile ? 0 : _agentCapabilityChipVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(mobile ? 4 : 8),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: mobile
            ? const TextStyle(
                fontSize: 12,
                color: Color(0xFF999999),
                fontWeight: FontWeight.w500,
                height: 22 / 12,
              )
            : _agentCapabilityChipTextStyle,
      ),
    );
  }
}

const TextStyle _agentCapabilityChipTextStyle = TextStyle(
  fontSize: _agentCapabilityChipFontSize,
  color: Color(0xFF4B5563),
  fontWeight: FontWeight.w500,
  height: _agentCapabilityChipLineHeight,
);

class _AgentMenuButton extends StatefulWidget {
  const _AgentMenuButton({
    required this.filled,
    required this.matchCardBackground,
    required this.onEdit,
    required this.onDelete,
    this.onExpandedChanged,
  });

  final bool filled;
  final bool matchCardBackground;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<_AgentMenuButton> createState() => _AgentMenuButtonState();
}

class _AgentMenuButtonState extends State<_AgentMenuButton> {
  bool _hover = false;
  bool _expanded = false;

  void _handleMenuSelected(String value) {
    if (value == 'edit') widget.onEdit();
    if (value == 'delete') widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    return UiDropdownMenu<String>(
      menuWidth: 132,
      items: const [
        UiDropdownMenuItem<String>(
          value: 'edit',
          label: '编辑',
          icon: CupertinoIcons.pencil,
        ),
        UiDropdownMenuItem<String>(
          value: 'delete',
          label: '删除',
          icon: CupertinoIcons.delete,
          danger: true,
        ),
      ],
      onSelected: _handleMenuSelected,
      onExpandedChanged: (expanded) {
        if (!mounted) return;
        setState(() => _expanded = expanded);
        widget.onExpandedChanged?.call(expanded);
      },
      // 数字员工卡片菜单先试点统一到 UiDropdownMenuItem，后续其他下拉可按此迁移。
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          key: const ValueKey('agent-card-menu-button'),
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.matchCardBackground
                ? Colors.transparent
                : (widget.filled || _hover || _expanded)
                    ? const Color(0xFFF7F8FA)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(
            Icons.more_horiz,
            size: 20,
            color: Color(0xFF86909C),
          ),
        ),
      ),
    );
  }
}
