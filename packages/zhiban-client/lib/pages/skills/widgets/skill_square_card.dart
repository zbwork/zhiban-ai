import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'skill_card.dart';
import 'skill_icon.dart';

/// 技能广场列表里的方形卡片（共用）。
class SkillSquareCard extends StatefulWidget {
  const SkillSquareCard({
    super.key,
    required this.skill,
    required this.selected,
    required this.primaryColor,
    required this.onTap,
    this.onShowDetail,
    this.showCheckMark = true,
  });

  final Skill skill;
  final bool selected;
  final Color primaryColor;
  final VoidCallback onTap;
  final VoidCallback? onShowDetail;
  final bool showCheckMark;

  @override
  State<SkillSquareCard> createState() => _SkillSquareCardState();
}

class _SkillSquareCardState extends State<SkillSquareCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primaryColor;
    final selectedBg = primary.withValues(alpha: 0.06);
    final hoverBg = const Color(0xFFF5F7FA);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          decoration: BoxDecoration(
            color: widget.selected
                ? selectedBg
                : (_hovered ? hoverBg : Colors.white),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.selected ? primary : const Color(0xFFE7ECF5),
              width: 1.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SkillIcon(
                iconUrl: widget.skill.iconUrl,
                size: 44,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.skill.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF101828),
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (widget.skill.isPaid) ...[
                          const SizedBox(width: 6),
                          SkillBillingBadge(skill: widget.skill),
                        ],
                      ],
                    ),
                    if (widget.skill.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.skill.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Color(0xFF667085),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (widget.onShowDetail != null) ...[
                _DetailChip(
                  primaryColor: primary,
                  onTap: widget.onShowDetail
                ),
                const SizedBox(width: 10),
              ],
              if (widget.showCheckMark)
                Icon(
                  widget.selected
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.circle,
                  size: 20,
                  color: widget.selected ? primary : const Color(0xFFD0D5DD),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailChip extends StatefulWidget {
  const _DetailChip({required this.primaryColor, required this.onTap});

  final Color primaryColor;
  final VoidCallback? onTap;

  @override
  State<_DetailChip> createState() => _DetailChipState();
}

class _DetailChipState extends State<_DetailChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.primaryColor
                .withValues(alpha: _hovered ? 0.14 : 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '详情',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: widget.primaryColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 技能广场分组标题（左侧带主题色装饰条）。
class SkillGroupLabel extends StatelessWidget {
  const SkillGroupLabel({
    super.key,
    required this.text,
    this.accentColor = const Color(0xFF3B6FE5),
  });

  final String text;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF344054),
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
