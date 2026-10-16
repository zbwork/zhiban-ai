import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'skill_icon.dart';

/// 技能广场卡片（2026-07-17 设计稿版式，F03 §1.5.4）：
/// - 首行：技能 icon + 技能名称 + 标签行（分类 + 计费）
/// - 描述最多 2 行
/// - 底行：🔥 N人在用 + 右侧「添加」
/// - 尾部：例：示例文案，最多 2 行（usage_example 为空时隐藏）
class SkillCard extends StatefulWidget {
  const SkillCard({
    required this.skill,
    required this.onTap,
    this.onAdd,
    this.categoryName,
    super.key,
  });

  final Skill skill;
  final VoidCallback onTap;

  /// 非空时底行右侧展示「添加」直达按钮（F03 §1.5.4 技能广场闭环）。
  final VoidCallback? onAdd;

  /// 技能所属分类名（由列表侧按 categoryId 解析传入），空则不展示分类标签。
  final String? categoryName;

  @override
  State<SkillCard> createState() => _SkillCardState();
}

class _SkillCardState extends State<SkillCard> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    final description =
        skill.description.isEmpty ? '暂无描述' : skill.description;
    final example = _exampleOneliner(skill.usageExample);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            // 设计稿：浅灰细描边、弱阴影卡片；hover 时仅轻微加深反馈。
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isHovering
                  ? const Color(0xFFD0D5DD)
                  : const Color(0xFFEAECF0),
            ),
            boxShadow: _isHovering
                ? [
                    BoxShadow(
                      color: const Color(0xFF101828).withValues(alpha: 0.05),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: const Color(0xFF101828).withValues(alpha: 0.02),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            // 顶部信息块靠上，「N人在用 + 添加 + 示例」钉底；
            // 移动端列表高度自适应时 spaceBetween 等效顶部排列，安全。
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SkillIcon(
                        iconUrl: skill.iconUrl,
                        size: 56,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              skill.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.2,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1D2129),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if ((widget.categoryName ?? '')
                                    .isNotEmpty) ...[
                                  _SkillTagPill(label: widget.categoryName!),
                                  const SizedBox(width: 6),
                                ],
                                SkillBillingBadge(skill: skill),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Color(0xFF4E5969),
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        CupertinoIcons.flame_fill,
                        size: 14,
                        color: Color(0xFFF97316),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${formatSkillInstallCount(skill.downloadCount)}人在用',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF86909C),
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (widget.onAdd != null) ...[
                        const SizedBox(width: 8),
                        _SkillAddButton(
                          // 付费技能用实心主按钮突出（点击仍走付费确认 + 添加，
                          // EasyO 无按技能买断，不用「购买」文案）。
                          filled: skill.isPaid,
                          onPressed: widget.onAdd!,
                        ),
                      ],
                    ],
                  ),
                  if (example.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(height: 1, color: const Color(0xFFF1F4F8)),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            CupertinoIcons.chat_bubble,
                            size: 13,
                            color: Color(0xFF98A2B3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '例：$example',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: Color(0xFF86909C),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// usage_example 是 Markdown 多行文本；卡片里压成一行纯文本示例。
  static String _exampleOneliner(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final joined = trimmed
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    // 去掉常见 Markdown 标记字符，避免卡片里出现 # * ` > 噪音。
    return joined.replaceAll(RegExp(r'[#*`>]'), '').trim();
  }
}

/// 分类标签小胶囊（浅灰底）。
class _SkillTagPill extends StatelessWidget {
  const _SkillTagPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4E5969),
          height: 1.3,
        ),
      ),
    );
  }
}

class _SkillAddButton extends StatelessWidget {
  const _SkillAddButton({required this.onPressed, this.filled = false});

  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    // 设计稿规格：圆角矩形（radius 10）、高 36、宽 ≥76；
    // 免费=白底中性浅灰描边+蓝字，付费=实心蓝底白字。
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    const textStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600);
    if (filled) {
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1677FF),
          minimumSize: const Size(76, 36),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: shape,
          textStyle: textStyle,
        ),
        onPressed: onPressed,
        child: const Text('添加'),
      );
    }
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF1677FF),
        side: const BorderSide(color: Color(0xFFE4E7EC)),
        backgroundColor: Colors.white,
        minimumSize: const Size(76, 36),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: shape,
        textStyle: textStyle,
      ),
      onPressed: onPressed,
      child: const Text('添加'),
    );
  }
}

/// 技能来源展示元数据（详情弹框等处共用）。
class SkillSourceMeta {
  const SkillSourceMeta({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  factory SkillSourceMeta.fromSkill(Skill skill) {
    switch (skill.source) {
      case 'open_source':
      case 'community':
        return const SkillSourceMeta(
          label: 'GitHub',
          icon: Icons.code_rounded,
          color: Color(0xFF111827),
        );
      case 'third_party':
        return const SkillSourceMeta(
          label: 'ClawHub',
          icon: Icons.public_rounded,
          color: Color(0xFFE11D48),
        );
      case 'internal':
      case 'official':
      default:
        return SkillSourceMeta(
          label: skill.scopeKind == 'tenant' ? '企业技能' : 'SkillHub',
          icon: Icons.extension_rounded,
          color: const Color(0xFF1677FF),
        );
    }
  }
}

String formatSkillInstallCount(int count) {
  if (count <= 0) return '0';
  if (count >= 10000) {
    final value = count / 10000;
    final text =
        value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '${text.replaceAll('.0', '')}万';
  }
  if (count >= 1000) {
    final value = count / 1000;
    final text =
        value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '${text.replaceAll('.0', '')}千';
  }
  return count.toString();
}

class SkillBillingBadge extends StatelessWidget {
  const SkillBillingBadge({
    super.key,
    required this.skill,
    this.fontSize = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
  });

  final Skill skill;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final isPaid = skill.isPaid;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isPaid ? const Color(0xFFFFF7ED) : const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        skill.billingBadgeText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: isPaid ? const Color(0xFFD97706) : const Color(0xFF059669),
          height: 1.3,
        ),
      ),
    );
  }
}
