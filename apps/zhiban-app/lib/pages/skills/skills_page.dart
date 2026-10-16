import 'dart:async';

import 'package:zhiban_client/config/color_config.dart';
import 'widgets/my_skills_view.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_install_agent_dialog.dart';
import 'widgets/skills_content.dart';
import 'package:zhiban_client/pages/skills/widgets/skills_error.dart';
import 'widgets/skills_filters_bar.dart';
import 'widgets/skills_search_bar.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_source.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_detail_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexwork/widgets/page_header.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

/// 技能广场页顶层视图：广场浏览 / 我的技能（F03 §1.5.4 闭环）。
enum _SkillsTab { market, mine }

class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: SafeArea(
        bottom: false,
        child: SkillsPageBody(compact: false),
      ),
    );
  }
}

/// 技能页共享的业务主体，不持有平台页面壳。
class SkillsPageBody extends ConsumerStatefulWidget {
  const SkillsPageBody({
    super.key,
    required this.compact,
    this.onSectionChanged,
  });

  final bool compact;
  final ValueChanged<String>? onSectionChanged;

  @override
  ConsumerState<SkillsPageBody> createState() => _SkillsPageBodyState();
}

class _SkillsPageBodyState extends ConsumerState<SkillsPageBody> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  _SkillsTab _tab = _SkillsTab.market;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    // 中文等输入法组词过程中 controller.text 会跟着每个拼音字母变化，
    // composing 区间非空说明还没上屏，此时不该拿半成品拼音去触发搜索。
    final composing = _searchController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      ref
          .read(skillsProvider.notifier)
          .setKeyword(_searchController.text.trim());
    });
  }

  void _switchTab(_SkillsTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    widget.onSectionChanged?.call(
      tab == _SkillsTab.mine ? '我的技能' : '技能广场',
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(skillsProvider);
    final notifier = ref.read(skillsProvider.notifier);
    final compact = widget.compact;
    final tabSwitcher = _SkillsTabSwitcher(
      tab: _tab,
      compact: compact,
      onChanged: _switchTab,
    );

    return _tab == _SkillsTab.mine
        ? _MySkillsTabBody(
            compact: compact,
            tabSwitcher: tabSwitcher,
            onGoMarket: () => _switchTab(_SkillsTab.market),
          )
        : asyncState.when(
            data: (state) => _SkillsPageBody(
              state: state,
              compact: compact,
              scrollController: _scrollController,
              searchController: _searchController,
              source: notifier.source,
              sort: notifier.sort,
              tabSwitcher: tabSwitcher,
              onSourceChanged: notifier.setSource,
              onSortChanged: notifier.setSort,
              onCategoryChanged: notifier.setCategory,
              onSkillTap: (skill) => _showDetailDialog(context, skill),
              onSkillAdd: (skill) => _showInstallDialog(context, skill),
              onLoadMore: notifier.loadMore,
              onRefresh: notifier.refresh,
            ),
            loading: () => _SkillsPageBody(
              state: const SkillsListState(
                skills: [],
                hasReachedMax: false,
                isLoading: true,
                isRefreshing: false,
                error: null,
              ),
              compact: compact,
              scrollController: _scrollController,
              searchController: _searchController,
              source: notifier.source,
              sort: notifier.sort,
              tabSwitcher: tabSwitcher,
              onSourceChanged: notifier.setSource,
              onSortChanged: notifier.setSort,
              onCategoryChanged: notifier.setCategory,
              onSkillTap: (skill) => _showDetailDialog(context, skill),
              onSkillAdd: (skill) => _showInstallDialog(context, skill),
              onLoadMore: notifier.loadMore,
              onRefresh: notifier.refresh,
            ),
            error: (error, _) => SkillsError(
              message: error.toString(),
              onRetry: () => ref.read(skillsProvider.notifier).refresh(),
            ),
          );
  }

  void _showDetailDialog(BuildContext context, Skill skill) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      barrierDismissible: true,
      builder: (_) => SkillDetailDialog(skill: skill, enableInstall: true),
    );
  }

  void _showInstallDialog(BuildContext context, Skill skill) {
    showSkillInstallAgentDialog(context, skill: skill);
  }
}

/// 「我的技能」tab 主体：桌面端带页头，移动端顶部放切换器。
class _MySkillsTabBody extends StatelessWidget {
  const _MySkillsTabBody({
    required this.compact,
    required this.tabSwitcher,
    required this.onGoMarket,
  });

  final bool compact;
  final Widget tabSwitcher;
  final VoidCallback onGoMarket;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Align(alignment: Alignment.centerLeft, child: tabSwitcher),
          )
        else
          PageHeader(
            title: '我的技能',
            subtitle: '管理你创建的数字员工已添加的技能。',
            trailing: tabSwitcher,
          ),
        Expanded(child: MySkillsView(onGoMarket: onGoMarket)),
      ],
    );
  }
}

class _SkillsPageBody extends StatelessWidget {
  const _SkillsPageBody({
    required this.state,
    required this.compact,
    required this.scrollController,
    required this.searchController,
    required this.source,
    required this.sort,
    required this.tabSwitcher,
    required this.onSourceChanged,
    required this.onSortChanged,
    required this.onCategoryChanged,
    required this.onSkillTap,
    required this.onSkillAdd,
    required this.onLoadMore,
    required this.onRefresh,
  });

  final SkillsListState state;
  final bool compact;
  final ScrollController scrollController;
  final TextEditingController searchController;
  final SkillSource source;
  final SortOption sort;
  final Widget tabSwitcher;
  final ValueChanged<SkillSource> onSourceChanged;
  final ValueChanged<SortOption> onSortChanged;
  final ValueChanged<int?> onCategoryChanged;
  final ValueChanged<Skill> onSkillTap;
  final ValueChanged<Skill> onSkillAdd;
  final VoidCallback onLoadMore;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Align(alignment: Alignment.centerLeft, child: tabSwitcher),
          ),
        SkillsFiltersBar(
          mobile: compact,
          searchBar: SkillsSearchBar(
            controller: searchController,
          ),
          source: source,
          sort: sort,
          categories: state.categories,
          selectedCategoryId: state.selectedCategoryId,
          tabSwitcher: compact ? null : tabSwitcher,
          onSourceChanged: onSourceChanged,
          onSortChanged: onSortChanged,
          onCategoryChanged: onCategoryChanged,
          onRefresh: onRefresh,
          isRefreshing: state.isRefreshing,
        ),
        Expanded(
          child: SkillsContent(
            state: state,
            scrollController: scrollController,
            onSkillTap: onSkillTap,
            onSkillAdd: onSkillAdd,
            onLoadMore: onLoadMore,
          ),
        ),
      ],
    );
  }
}

/// 「技能广场 / 我的技能」分段切换（shadcn segmented 风格）。
class _SkillsTabSwitcher extends StatelessWidget {
  const _SkillsTabSwitcher({
    required this.tab,
    required this.compact,
    required this.onChanged,
  });

  final _SkillsTab tab;
  final bool compact;
  final ValueChanged<_SkillsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiSegmentedTabs<_SkillsTab>(
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
        UiSegmentedTab(value: _SkillsTab.market, label: '技能广场'),
        UiSegmentedTab(value: _SkillsTab.mine, label: '我的技能'),
      ],
    );
  }
}
