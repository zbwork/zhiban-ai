import 'package:flutter/material.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

enum SkillsTab { market, mine }

/// 「技能广场 / 我的技能」分段切换（shadcn segmented 风格）。
class SkillsTabSwitcher extends StatelessWidget {
  const SkillsTabSwitcher({
    super.key,
    required this.tab,
    required this.compact,
    required this.onChanged,
  });

  final SkillsTab tab;
  final bool compact;
  final ValueChanged<SkillsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiSegmentedTabs<SkillsTab>(
      expand: compact,
      trackColor: const Color(0xFFF2F4F7),
      trackRadius: 10,
      fontSize: 13,
      activeColor: const Color(0xFF1D2129),
      inactiveColor: const Color(0xFF667085),
      segmentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      current: tab,
      onChanged: onChanged,
      tabs: const [
        UiSegmentedTab(value: SkillsTab.market, label: '技能广场'),
        UiSegmentedTab(value: SkillsTab.mine, label: '我的技能'),
      ],
    );
  }
}
