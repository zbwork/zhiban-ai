import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_source.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_detail_dialog.dart';
import 'package:zhiban_client/pages/skills/widgets/skills_content.dart';
import 'package:zhiban_client/pages/skills/widgets/skills_filters_bar.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import 'community_market_providers.dart';

class CommunitySkillsMarket extends ConsumerStatefulWidget {
  const CommunitySkillsMarket({super.key, this.headerTrailing});

  final Widget? headerTrailing;

  @override
  ConsumerState<CommunitySkillsMarket> createState() =>
      _CommunitySkillsMarketState();
}

class _CommunitySkillsMarketState extends ConsumerState<CommunitySkillsMarket> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  SkillSource _source = SkillSource.all;
  SortOption _sort = SortOption.values.first;
  int? _category;
  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _detail(Skill skill) => showDialog<void>(
        context: context,
        builder: (_) => SkillDetailDialog(
          skill: skill,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(communitySkillsProvider);
    final data = catalog.asData?.value;
    final keyword = _search.text.trim().toLowerCase();
    final skills = (data?.skills ?? <Skill>[])
        .where(
          (skill) =>
              (_category == null || skill.categoryId == _category) &&
              (_source == SkillSource.all || skill.source == _source.value) &&
              '${skill.displayTitle} ${skill.slug} ${skill.description}'
                  .toLowerCase()
                  .contains(keyword),
        )
        .toList();
    if (_sort.sortBy == 'install_count' || _sort.sortBy == 'download_count') {
      skills.sort((a, b) => _sort.sortOrder == 'desc'
          ? b.downloadCount.compareTo(a.downloadCount)
          : a.downloadCount.compareTo(b.downloadCount));
    }
    return Column(
      children: [
        SkillsFiltersBar(
          mobile: false,
          tabSwitcher: widget.headerTrailing,
          searchBar: UiSearchField(
            controller: _search,
            hintText: '搜索公共技能',
            onChanged: (_) => setState(() {}),
          ),
          source: _source,
          sort: _sort,
          categories: data?.categories ?? const [],
          selectedCategoryId: _category,
          onSourceChanged: (value) => setState(() => _source = value),
          onSortChanged: (value) => setState(() => _sort = value),
          onCategoryChanged: (value) => setState(() => _category = value),
          subtitle: '浏览公共技能，当前服务器技能可在“当前服务器”中管理。',
        ),
        if (catalog.hasError)
          TextButton(
            onPressed: () => ref.invalidate(communitySkillsProvider),
            child: const Text('公共技能加载失败，点击重试'),
          ),
        Expanded(
          child: SkillsContent(
            state: SkillsListState(
              skills: skills,
              hasReachedMax: true,
              isLoading: catalog.isLoading,
              isRefreshing: false,
              error: catalog.hasError ? '公共技能加载失败，请重试' : null,
              categories: data?.categories ?? const [],
            ),
            scrollController: _scroll,
            onSkillTap: _detail,
            onSkillAdd: _detail,
            addLabel: (_) => '查看详情',
            onLoadMore: () {},
          ),
        ),
      ],
    );
  }
}
