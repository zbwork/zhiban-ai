import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_detail_dialog.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_icon.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';

/// 技能广场弹框（合并版）。
///
/// 支持两种用法：
/// - **新建/编辑数字员工**：`agentId` 为 null 时隐藏自定义分组；
///   非空时展示并支持 [onTapCustomSkill] 点击进入对话。
/// - **聊天输入框"添加技能"**：`agentId` 必填，[onAddCustomSkill] 回调
///   负责关闭弹框并触发创建流程。
///
/// 返回 `Map<slug, displayTitle>` 或 null（取消 / 回调自行关闭）。
class SkillPickerDialog extends ConsumerStatefulWidget {
  const SkillPickerDialog({
    super.key,
    required this.initialSelected,
    this.agentId,
    this.onAddCustomSkill,
    this.onTapCustomSkill,
    this.useRootNavigatorForDetail = true,
    this.asPage = false,
  });

  final Map<String, String> initialSelected;

  /// null = 新建模式（隐藏自定义技能分组）。
  final String? agentId;

  /// "添加自定义技能" tile 点击回调。
  /// 接收 dialog 的 [BuildContext] 和当前自定义 [SkillGroup]，
  /// 回调内部自行负责关闭弹框 / 导航。
  final Future<void> Function(BuildContext ctx, SkillGroup group)?
      onAddCustomSkill;

  /// 自定义技能卡片点击（编辑数字员工模式）。
  /// null = 卡片不可点。
  final void Function(String agentId, String slug)? onTapCustomSkill;

  /// 技能详情子弹框是否走 root navigator（默认 true，覆盖整窗）。
  final bool useRootNavigatorForDetail;

  /// true = 渲染为 Scaffold + UiPageBar（用于移动端全屏底部弹出）。
  /// false = 渲染为 Dialog（默认，桌面端）。
  final bool asPage;

  @override
  ConsumerState<SkillPickerDialog> createState() => _SkillPickerDialogState();
}

class _SkillPickerDialogState extends ConsumerState<SkillPickerDialog> {
  final Map<String, String> _selected = {};
  final TextEditingController _searchController = TextEditingController();
  List<SkillCategory> _categories = const [];
  List<Skill> _skills = const [];
  int? _selectedCategoryId;
  SortOption _sort = SortOption.defaultSort;
  Timer? _searchDebounce;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialSelected);
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final service = ref.read(skillsServiceProvider);
      final categoriesFuture = _categories.isEmpty
          ? service.listCategories()
          : Future<List<SkillCategory>>.value(_categories);
      final skillsFuture = service.listSkills(
        keyword: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        categoryId: _selectedCategoryId,
        page: 1,
        pageSize: 200,
        sortBy: _sort.sortBy,
        sortOrder: _sort.sortOrder,
      );
      final results = await Future.wait<dynamic>([
        categoriesFuture,
        skillsFuture,
      ]);
      if (!mounted) return;
      final categories = results[0] as List<SkillCategory>;
      final skillsResult = results[1] as Map<String, dynamic>;
      final skills = (skillsResult['list'] as List<Skill>)
          .where((skill) => skill.source != 'custom')
          .toList(growable: false);
      setState(() {
        _categories = categories;
        _skills = skills;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _skills = const [];
        _loading = false;
        _loadError = '技能广场加载失败：$error';
      });
    }
  }

  void _toggle(Skill item) {
    if (!_selected.containsKey(item.slug) && item.isPaid) {
      _confirmPaidSkill(item);
      return;
    }
    setState(() {
      if (_selected.containsKey(item.slug)) {
        _selected.remove(item.slug);
      } else {
        _selected[item.slug] = item.displayTitle;
      }
    });
  }

  Future<void> _confirmPaidSkill(Skill item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (ctx) => _PaidSkillConfirmDialog(skill: item),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _selected[item.slug] = item.displayTitle;
      });
    }
  }

  void _setCategory(int? categoryId) {
    if (_selectedCategoryId == categoryId) return;
    setState(() => _selectedCategoryId = categoryId);
    unawaited(_load());
  }

  void _setSort(SortOption? sort) {
    if (sort == null || _sort == sort) return;
    setState(() => _sort = sort);
    unawaited(_load());
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  Future<void> _showSkillDetail(Skill item) async {
    final detail =
        item.supportsInstallAction ? await _loadLegacySkillDetail(item) : item;
    if (!mounted || detail == null) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      useRootNavigator: widget.useRootNavigatorForDetail,
      builder: (_) => SkillDetailDialog(skill: detail),
    );
  }

  Future<Skill?> _loadLegacySkillDetail(Skill item) async {
    try {
      return await ref.read(skillsServiceProvider).getSkillDetail(item.slug);
    } catch (_) {
      if (mounted) {
        BotToast.showText(text: '技能详情加载失败');
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF3B6FE5);
    final body = _buildBody(primary);

    if (widget.asPage) {
      return Scaffold(
        backgroundColor: const Color(0xFFF7F8FB),
        appBar: UiPageBar(
          title: '技能广场',
          backgroundColor: const Color(0xFFF7F8FB),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, Map.of(_selected)),
              child: const Text(
                '确定',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        body: SafeArea(top: false, child: body),
      );
    }

    return UiPickerDialog(
      size: UiDialogSize.wide,
      maxHeight: 820,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
            child: UiSheetHeader(
              title: '技能广场',
              subtitle: '浏览并筛选租户可用技能。',
              onClose: () => Navigator.pop(context),
              trailing: TextButton(
                onPressed: () => Navigator.pop(context, Map.of(_selected)),
                style: TextButton.styleFrom(
                  foregroundColor: primary,
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: const Text('确定'),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEDEFF5)),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildBody(Color primary) {
    if (_loading && _skills.isEmpty) {
      return const Center(child: CupertinoActivityIndicator(radius: 12));
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              style: const TextStyle(color: Color(0xFF667085), fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final selectedCategoryName = _selectedCategoryId == null
            ? '全部'
            : _categories
                .where((category) => category.id == _selectedCategoryId)
                .map((category) => category.name)
                .firstOrNull;
        final resultPane = _SkillResultsPane(
          title: selectedCategoryName ?? '全部',
          skills: _skills,
          selected: _selected,
          sort: _sort,
          loading: _loading,
          primary: primary,
          onSortChanged: _setSort,
          onToggle: _toggle,
          onShowDetail: _showSkillDetail,
        );

        if (constraints.maxWidth >= 720) {
          return Row(
            children: [
              SizedBox(
                key: const ValueKey('skill_picker_desktop_sidebar'),
                width: 224,
                child: _SkillMarketplaceSidebar(
                  categories: _categories,
                  selectedCategoryId: _selectedCategoryId,
                  searchController: _searchController,
                  primary: primary,
                  onCategoryChanged: _setCategory,
                  onSearchChanged: _onSearchChanged,
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0xFFEDEFF5)),
              Expanded(child: resultPane),
            ],
          );
        }

        return Column(
          children: [
            _CompactSkillMarketplaceToolbar(
              categories: _categories,
              selectedCategoryId: _selectedCategoryId,
              searchController: _searchController,
              sort: _sort,
              primary: primary,
              onCategoryChanged: _setCategory,
              onSearchChanged: _onSearchChanged,
              onSortChanged: _setSort,
            ),
            Expanded(child: resultPane.withoutHeader()),
          ],
        );
      },
    );
  }
}

// ─── 桌面分栏 / 窄屏紧凑筛选 ──────────────────────────────────

class _SkillMarketplaceSidebar extends StatelessWidget {
  const _SkillMarketplaceSidebar({
    required this.categories,
    required this.selectedCategoryId,
    required this.searchController,
    required this.primary,
    required this.onCategoryChanged,
    required this.onSearchChanged,
  });

  final List<SkillCategory> categories;
  final int? selectedCategoryId;
  final TextEditingController searchController;
  final Color primary;
  final ValueChanged<int?> onCategoryChanged;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFAFBFD),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '技能选择',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
          const SizedBox(height: 14),
          UiSearchField(
            hintText: '搜索技能',
            controller: searchController,
            onChanged: onSearchChanged,
            height: 38,
            borderRadius: 9,
            fillColor: Colors.white,
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFE7EAF0)),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                _SidebarCategoryTile(
                  label: '全部',
                  icon: CupertinoIcons.square_grid_2x2,
                  selected: selectedCategoryId == null,
                  primary: primary,
                  onTap: () => onCategoryChanged(null),
                ),
                for (final category in categories)
                  _SidebarCategoryTile(
                    label: category.name,
                    icon: _skillCategoryIcon(category.name),
                    selected: selectedCategoryId == category.id,
                    primary: primary,
                    onTap: () => onCategoryChanged(category.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactSkillMarketplaceToolbar extends StatelessWidget {
  const _CompactSkillMarketplaceToolbar({
    required this.categories,
    required this.selectedCategoryId,
    required this.searchController,
    required this.sort,
    required this.primary,
    required this.onCategoryChanged,
    required this.onSearchChanged,
    required this.onSortChanged,
  });

  final List<SkillCategory> categories;
  final int? selectedCategoryId;
  final TextEditingController searchController;
  final SortOption sort;
  final Color primary;
  final ValueChanged<int?> onCategoryChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<SortOption?> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFF),
        border: Border(bottom: BorderSide(color: Color(0xFFEDEFF5))),
      ),
      child: Column(
        children: [
          UiSearchField(
            hintText: '搜索技能',
            controller: searchController,
            onChanged: onSearchChanged,
            height: 38,
            borderRadius: 9,
            fillColor: Colors.white,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Row(
                    children: [
                      _CategoryPill(
                        label: '全部',
                        icon: null,
                        selected: selectedCategoryId == null,
                        primary: primary,
                        onTap: () => onCategoryChanged(null),
                      ),
                      for (final category in categories) ...[
                        const SizedBox(width: 8),
                        _CategoryPill(
                          label: category.name,
                          icon: _skillCategoryIcon(category.name),
                          selected: selectedCategoryId == category.id,
                          primary: primary,
                          onTap: () => onCategoryChanged(category.id),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 106,
                child: _SkillSortSelect(
                  sort: sort,
                  onChanged: onSortChanged
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SidebarCategoryTile extends StatefulWidget {
  const _SidebarCategoryTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  @override
  State<_SidebarCategoryTile> createState() => _SidebarCategoryTileState();
}

class _SidebarCategoryTileState extends State<_SidebarCategoryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: widget.selected
                  ? const Color(0xFFEFF4FF)
                  : _hovered
                      ? const Color(0xFFF3F5F9)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 17,
                  color: widget.selected
                      ? widget.primary
                      : const Color(0xFF667085),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          widget.selected ? FontWeight.w700 : FontWeight.w500,
                      color: widget.selected
                          ? const Color(0xFF1D4ED8)
                          : const Color(0xFF344054),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SkillResultsPane extends StatelessWidget {
  const _SkillResultsPane({
    required this.title,
    required this.skills,
    required this.selected,
    required this.sort,
    required this.loading,
    required this.primary,
    required this.onSortChanged,
    required this.onToggle,
    required this.onShowDetail,
    this.showHeader = true,
  });

  final String title;
  final List<Skill> skills;
  final Map<String, String> selected;
  final SortOption sort;
  final bool loading;
  final Color primary;
  final ValueChanged<SortOption?> onSortChanged;
  final ValueChanged<Skill> onToggle;
  final ValueChanged<Skill> onShowDetail;
  final bool showHeader;

  _SkillResultsPane withoutHeader() => _SkillResultsPane(
        title: title,
        skills: skills,
        selected: selected,
        sort: sort,
        loading: loading,
        primary: primary,
        onSortChanged: onSortChanged,
        onToggle: onToggle,
        onShowDetail: onShowDetail,
        showHeader: false,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showHeader)
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFEDEFF5))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF101828),
                    ),
                  ),
                ),
                Text(
                  '${skills.length} 个技能',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF98A2B3),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 112,
                  child: _SkillSortSelect(
                    sort: sort,
                    onChanged: onSortChanged
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              if (skills.isEmpty)
                const Center(
                  child: Text(
                    '暂无可用技能',
                    style: TextStyle(fontSize: 13, color: Color(0xFF98A2B3)),
                  ),
                )
              else
                ListView.separated(
                  key: const ValueKey('skill_picker_skill_list'),
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                  itemCount: skills.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final skill = skills[index];
                    return _MarketplaceSkillRow(
                      key: ValueKey('skill_picker_row_${skill.slug}'),
                      skill: skill,
                      selected: selected.containsKey(skill.slug),
                      primary: primary,
                      onTap: () => onToggle(skill),
                      onShowDetail: () => onShowDetail(skill),
                    );
                  },
                ),
              if (loading)
                const Positioned(
                  top: 10,
                  right: 20,
                  child: CupertinoActivityIndicator(radius: 9),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SkillSortSelect extends StatelessWidget {
  const _SkillSortSelect({required this.sort, required this.onChanged});

  final SortOption sort;
  final ValueChanged<SortOption?> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiSelect<SortOption>(
      value: sort,
      menuMaxHeight: 180,
      options: const [
        UiSelectOption(value: SortOption.defaultSort, label: '最热'),
        UiSelectOption(value: SortOption.updatedAt, label: '最新'),
        UiSelectOption(value: SortOption.downloadCount, label: '安装量'),
      ],
      onChanged: onChanged,
    );
  }
}

IconData _skillCategoryIcon(String name) {
  if (name.contains('办公') || name.contains('企业')) {
    return CupertinoIcons.briefcase_fill;
  }
  if (name.contains('电脑') || name.contains('设置')) {
    return CupertinoIcons.desktopcomputer;
  }
  if (name.contains('生活') || name.contains('日常')) {
    return CupertinoIcons.leaf_arrow_circlepath;
  }
  if (name.contains('休') || name.contains('娱乐')) {
    return CupertinoIcons.game_controller_solid;
  }
  return CupertinoIcons.square_grid_2x2_fill;
}

class _CategoryPill extends StatefulWidget {
  const _CategoryPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  @override
  State<_CategoryPill> createState() => _CategoryPillState();
}

class _CategoryPillState extends State<_CategoryPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFFEAF2FF)
                : _hovered
                    ? const Color(0xFFF2F6FF)
                    : Colors.white,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: active ? const Color(0xFFB7CCFF) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 14,
                  color: active ? widget.primary : const Color(0xFF667085),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? widget.primary : const Color(0xFF344054),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarketplaceSkillRow extends StatefulWidget {
  const _MarketplaceSkillRow({
    super.key,
    required this.skill,
    required this.selected,
    required this.primary,
    required this.onTap,
    required this.onShowDetail,
  });

  final Skill skill;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;
  final VoidCallback onShowDetail;

  @override
  State<_MarketplaceSkillRow> createState() => _MarketplaceSkillRowState();
}

class _MarketplaceSkillRowState extends State<_MarketplaceSkillRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Semantics(
          selected: widget.selected,
          button: true,
          label: widget.skill.displayTitle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              onTap: widget.onTap,
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: EdgeInsets.fromLTRB(
                  compact ? 12 : 14,
                  12,
                  compact ? 10 : 14,
                  12,
                ),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? const Color(0xFFF3F7FF)
                      : _hovered
                          ? const Color(0xFFFAFBFD)
                          : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.selected
                        ? const Color(0xFF80A7FF)
                        : _hovered
                            ? const Color(0xFFD8E2F5)
                            : const Color(0xFFEAECF0),
                    width: widget.selected ? 1.4 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    SkillIcon(
                      iconUrl: widget.skill.iconUrl,
                      size: compact ? 42 : 48,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    SizedBox(width: compact ? 11 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
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
                                    height: 20 / 15,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF101828),
                                  ),
                                ),
                              ),
                              if (widget.skill.isPaid) ...[
                                const SizedBox(width: 6),
                                SkillBillingBadge(skill: widget.skill),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.skill.description.trim().isEmpty
                                ? '暂无简介'
                                : widget.skill.description.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 17 / 12,
                              color: Color(0xFF667085),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Icon(
                                Icons.extension_rounded,
                                size: 13,
                                color: widget.primary,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  '${widget.skill.sourceLabel} · ${widget.skill.downloadCount} 人添加',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF98A2B3),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (compact)
                      IconButton(
                        tooltip: '查看详情',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onShowDetail,
                        icon: const Icon(
                          CupertinoIcons.info_circle,
                          size: 18,
                          color: Color(0xFF667085),
                        ),
                      )
                    else
                      TextButton(
                        onPressed: widget.onShowDetail,
                        style: TextButton.styleFrom(
                          foregroundColor: widget.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 34),
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: const Text('详情'),
                      ),
                    const SizedBox(width: 6),
                    Icon(
                      widget.selected
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.circle,
                      key: ValueKey(
                        'skill_picker_selected_${widget.skill.slug}',
                      ),
                      size: 21,
                      color: widget.selected
                          ? widget.primary
                          : const Color(0xFFC5CDD8),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PaidSkillConfirmDialog extends StatelessWidget {
  const _PaidSkillConfirmDialog({required this.skill});

  final Skill skill;

  @override
  Widget build(BuildContext context) {
    final hint = skill.isPerOperation
        ? '该技能按 API 消耗积分，不同接口可能价格不同，是否继续？'
        : '该技能使用时会消耗积分，是否继续？';
    return UiConfirmDialog(
      title: skill.displayTitle,
      description: hint,
      confirmLabel: '继续',
    );
  }
}
