import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_source.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:nexwork/widgets/page_header.dart';

import 'skills_dropdown_field.dart';

class SkillsFiltersBar extends StatelessWidget {
  const SkillsFiltersBar({
    required this.mobile,
    required this.searchBar,
    required this.source,
    required this.sort,
    required this.categories,
    required this.selectedCategoryId,
    required this.onSourceChanged,
    required this.onSortChanged,
    required this.onCategoryChanged,
    required this.onRefresh,
    required this.isRefreshing,
    this.tabSwitcher,
    super.key,
  });

  final bool mobile;
  final Widget searchBar;
  final SkillSource source;
  final SortOption sort;
  final List<SkillCategory> categories;
  final int? selectedCategoryId;
  final ValueChanged<SkillSource> onSourceChanged;
  final ValueChanged<SortOption> onSortChanged;
  final ValueChanged<int?> onCategoryChanged;
  final VoidCallback onRefresh;
  final bool isRefreshing;

  /// 「技能广场 / 我的技能」切换（F03 §1.5.4 闭环）；桌面端放在页头 trailing。
  final Widget? tabSwitcher;

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return Container(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        decoration: const BoxDecoration(
          color: ColorConfig.pageBackground,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: searchBar,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 42,
              child: ListView(
                key: const Key('mobile-skills-category-chips'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _SkillCategoryPill(
                    label: '全部',
                    selected: selectedCategoryId == null,
                    mobile: true,
                    onTap: () => onCategoryChanged(null),
                  ),
                  for (final category in categories) ...[
                    const SizedBox(width: 10),
                    _SkillCategoryPill(
                      label: category.name,
                      selected: selectedCategoryId == category.id,
                      mobile: true,
                      onTap: () => onCategoryChanged(category.id),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: SkillsDropdownField<SkillSource>(
                      label: '来源',
                      value: source,
                      items: SkillSource.values,
                      itemLabelBuilder: (item) => item.displayName,
                      onChanged: (value) {
                        if (value != null) onSourceChanged(value);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SkillsDropdownField<SortOption>(
                      label: '排序',
                      value: sort,
                      items: SortOption.values,
                      itemLabelBuilder: (item) => item.label,
                      onChanged: (value) {
                        if (value != null) onSortChanged(value);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          title: '技能广场',
          subtitle: '浏览并筛选租户可用技能。',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tabSwitcher != null) ...[
                tabSwitcher!,
                const SizedBox(width: 12),
              ],
              if (isRefreshing)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: CupertinoActivityIndicator(radius: 8),
                ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF475467),
                  side: const BorderSide(color: Color(0xFFE4E7EC)),
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: isRefreshing ? null : onRefresh,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.refresh, size: 14),
                    SizedBox(width: 6),
                    Text('刷新'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          decoration: const BoxDecoration(
            color: Color(0xFFF8FAFD),
            border: Border(
              top: BorderSide(color: Color(0xFFF1F4F8)),
              bottom: BorderSide(color: Color(0xFFEFF3F8)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _SkillCategoryPill(
                        label: '全部',
                        selected: selectedCategoryId == null,
                        onTap: () => onCategoryChanged(null),
                      ),
                      for (final category in categories) ...[
                        const SizedBox(width: 12),
                        _SkillCategoryPill(
                          label: category.name,
                          icon: _categoryIcon(category.code),
                          selected: selectedCategoryId == category.id,
                          onTap: () => onCategoryChanged(category.id),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                  width: _responsiveSearchWidth(context), child: searchBar),
              const SizedBox(width: 10),
              SizedBox(
                width: 116,
                child: SkillsDropdownField<SortOption>(
                  label: '排序',
                  value: sort,
                  items: SortOption.values,
                  itemLabelBuilder: (item) => item.label,
                  onChanged: (value) {
                    if (value != null) onSortChanged(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

double _responsiveSearchWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1280) return 280;
  if (width >= 1040) return 220;
  return 180;
}

IconData _categoryIcon(String code) {
  switch (code) {
    case 'office_study':
      return Icons.business_center_rounded;
    case 'computer_setup':
      return Icons.desktop_windows_rounded;
    case 'daily_life':
      return Icons.eco_rounded;
    case 'leisure_entertainment':
      return Icons.sports_esports_rounded;
    default:
      return Icons.category_rounded;
  }
}

class _SkillCategoryPill extends StatelessWidget {
  const _SkillCategoryPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.mobile = false,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final background = mobile
        ? (selected ? const Color(0xFF171717) : Colors.white)
        : (selected
            ? const Color(0xFFEAF3FF)
            : Colors.white.withValues(alpha: 0.66));
    final foreground = mobile
        ? (selected ? Colors.white : const Color(0xFF1D2129))
        : (selected ? const Color(0xFF1677FF) : const Color(0xFF1D2129));
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(19),
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: onTap,
        child: Container(
          height: mobile ? 42 : 38,
          padding: EdgeInsets.symmetric(horizontal: mobile ? 20 : 18),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: mobile
                  ? (selected
                      ? const Color(0xFF171717)
                      : const Color(0xFFE4E7EC))
                  : (selected
                      ? const Color(0xFFBFD9FF)
                      : Colors.white.withValues(alpha: 0.82)),
            ),
            boxShadow: mobile
                ? [
                    BoxShadow(
                      color: const Color(0xFF101828).withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : selected
                    ? [
                        BoxShadow(
                          color:
                              const Color(0xFF101828).withValues(alpha: 0.04),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color:
                              const Color(0xFF101828).withValues(alpha: 0.025),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: mobile ? 14 : 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
