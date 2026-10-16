import 'package:riverpod/riverpod.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_source.dart';
import 'package:zhiban_client/pages/skills/services/skills_service.dart';

final skillsServiceProvider = Provider<OpenClawSkillsService>(
  (ref) => OpenClawSkillsService(),
);

enum SortOption { defaultSort, updatedAt, downloadCount }

extension SortOptionExtension on SortOption {
  String get label {
    switch (this) {
      case SortOption.defaultSort:
        return '最热';
      case SortOption.updatedAt:
        return '最新';
      case SortOption.downloadCount:
        return '安装量';
    }
  }

  String? get sortBy {
    switch (this) {
      case SortOption.defaultSort:
        return 'install_count';
      case SortOption.updatedAt:
        return 'updated_at';
      case SortOption.downloadCount:
        return 'install_count';
    }
  }

  String? get sortOrder {
    switch (this) {
      case SortOption.defaultSort:
        return 'desc';
      default:
        return 'desc';
    }
  }
}

class SkillsListState {
  const SkillsListState({
    required this.skills,
    required this.hasReachedMax,
    required this.isLoading,
    required this.isRefreshing,
    required this.error,
    this.categories = const <SkillCategory>[],
    this.selectedCategoryId,
  });

  final List<Skill> skills;
  final bool hasReachedMax;
  final bool isLoading;
  final bool isRefreshing;
  final String? error;
  final List<SkillCategory> categories;
  final int? selectedCategoryId;

  SkillsListState copyWith({
    List<Skill>? skills,
    bool? hasReachedMax,
    bool? isLoading,
    bool? isRefreshing,
    String? error,
    List<SkillCategory>? categories,
    int? selectedCategoryId,
    bool clearSelectedCategory = false,
    bool clearError = false,
  }) {
    return SkillsListState(
      skills: skills ?? this.skills,
      hasReachedMax: hasReachedMax ?? this.hasReachedMax,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      error: clearError ? null : error ?? this.error,
      categories: categories ?? this.categories,
      selectedCategoryId: clearSelectedCategory
          ? null
          : selectedCategoryId ?? this.selectedCategoryId,
    );
  }
}

final skillsProvider = AsyncNotifierProvider<SkillsNotifier, SkillsListState>(
  SkillsNotifier.new,
);

final installedSkillsProvider =
    FutureProvider<List<InstalledSkill>>((ref) async {
  final service = ref.watch(skillsServiceProvider);
  return service.listInstalledSkills();
});

/// 移动端「全部」总览查询条件。
///
/// 分类 ID 使用稳定字符串参与 provider family 的相等判断，避免页面 rebuild 时
/// 因 List 实例变化重复发起四组分类请求。
class MobileSkillsOverviewQuery {
  const MobileSkillsOverviewQuery({
    required this.categoryIdsKey,
    required this.keyword,
    required this.source,
    required this.sort,
  });

  final String categoryIdsKey;
  final String keyword;
  final SkillSource source;
  final SortOption sort;

  Iterable<int> get categoryIds => categoryIdsKey
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .where((id) => id > 0);

  @override
  bool operator ==(Object other) {
    return other is MobileSkillsOverviewQuery &&
        other.categoryIdsKey == categoryIdsKey &&
        other.keyword == keyword &&
        other.source == source &&
        other.sort == sort;
  }

  @override
  int get hashCode => Object.hash(categoryIdsKey, keyword, source, sort);
}

class MobileSkillSectionData {
  const MobileSkillSectionData({
    required this.skills,
    this.error
  });

  final List<Skill> skills;
  final String? error;
}

/// 移动端总览按分类独立取数；桌面分页 provider 不受影响。
final mobileSkillsOverviewProvider = FutureProvider.autoDispose
    .family<Map<int, MobileSkillSectionData>, MobileSkillsOverviewQuery>(
  (ref, query) async {
    final service = ref.watch(skillsServiceProvider);
    final entries = await Future.wait(
      query.categoryIds.map((categoryId) async {
        try {
          final result = await service.listSkills(
            keyword: query.keyword.isEmpty ? null : query.keyword,
            source: query.source.value.isEmpty ? null : query.source.value,
            categoryId: categoryId,
            page: 1,
            pageSize: 200,
            sortBy: query.sort.sortBy,
            sortOrder: query.sort.sortOrder,
          );
          return MapEntry(
            categoryId,
            MobileSkillSectionData(
              skills: result['list'] as List<Skill>
            ),
          );
        } catch (error) {
          return MapEntry(
            categoryId,
            MobileSkillSectionData(
              skills: const <Skill>[],
              error: error.toString(),
            ),
          );
        }
      }),
    );
    return Map<int, MobileSkillSectionData>.fromEntries(entries);
  }
);

class SkillsNotifier extends AsyncNotifier<SkillsListState> {
  String _keyword = '';
  SkillSource _source = SkillSource.all;
  SortOption _sort = SortOption.defaultSort;
  int? _categoryId;
  List<SkillCategory>? _categories;
  int _page = 1;
  int _requestVersion = 0;
  static const int _pageSize = 20;

  @override
  Future<SkillsListState> build() async {
    return _loadSkills();
  }

  Future<SkillsListState> _loadSkills() async {
    try {
      return await _fetchSkillsState();
    } catch (e) {
      return SkillsListState(
        skills: const [],
        hasReachedMax: false,
        isLoading: false,
        isRefreshing: false,
        error: e.toString(),
        categories: _categories ?? const <SkillCategory>[],
        selectedCategoryId: _categoryId,
      );
    }
  }

  Future<SkillsListState> _fetchSkillsState() async {
    final service = ref.read(skillsServiceProvider);

    final skillsFuture = service.listSkills(
      keyword: _keyword.isEmpty ? null : _keyword,
      source: _source.value.isEmpty ? null : _source.value,
      categoryId: _categoryId,
      page: _page,
      pageSize: _pageSize,
      sortBy: _sort.sortBy,
      sortOrder: _sort.sortOrder,
    );
    // 首次进入时 categories 与 skills 互相独立，并行拉取（此前串行等待）；
    // _categories 拿到后缓存在 notifier 字段，后续刷新/翻页只拉 skills。
    final cached = _categories;
    final List<SkillCategory> categories;
    final Map<String, dynamic> result;
    if (cached == null) {
      final fetched = await Future.wait<Object?>([
        service.listCategories(),
        skillsFuture,
      ]);
      categories = fetched[0]! as List<SkillCategory>;
      result = fetched[1]! as Map<String, dynamic>;
    } else {
      categories = cached;
      result = await skillsFuture;
    }
    _categories = categories;

    final skills = result['list'] as List<Skill>;
    final total = result['total'] as int;

    return SkillsListState(
      skills: skills,
      hasReachedMax: skills.length >= total,
      isLoading: false,
      isRefreshing: false,
      error: null,
      categories: categories,
      selectedCategoryId: _categoryId,
    );
  }

  Future<void> loadMore() async {
    final currentState = state.value;
    if (currentState == null ||
        currentState.hasReachedMax ||
        currentState.isLoading ||
        currentState.isRefreshing) {
      return;
    }

    state = AsyncData(currentState.copyWith(isLoading: true, clearError: true));

    final service = ref.read(skillsServiceProvider);
    _page++;

    try {
      final result = await service.listSkills(
        keyword: _keyword.isEmpty ? null : _keyword,
        source: _source.value.isEmpty ? null : _source.value,
        categoryId: _categoryId,
        page: _page,
        pageSize: _pageSize,
        sortBy: _sort.sortBy,
        sortOrder: _sort.sortOrder,
      );

      final newSkills = result['list'] as List<Skill>;
      final total = result['total'] as int;

      state = AsyncData(
        currentState.copyWith(
          skills: [...currentState.skills, ...newSkills],
          hasReachedMax: currentState.skills.length + newSkills.length >= total,
          isLoading: false,
          isRefreshing: false,
          categories: currentState.categories,
          selectedCategoryId: _categoryId,
        ),
      );
    } catch (e) {
      _page--;
      state = AsyncData(
        currentState.copyWith(
          isLoading: false,
          isRefreshing: false,
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> refresh() async {
    _page = 1;
    final previous = state.value;
    if (previous != null) {
      state =
          AsyncData(previous.copyWith(isRefreshing: true, clearError: true));
    } else {
      state = const AsyncLoading();
    }
    state = await AsyncValue.guard(() => _loadSkills());
  }

  Future<void> setKeyword(String keyword) async {
    if (_keyword != keyword) {
      _keyword = keyword;
      await _reloadFirstPage();
    }
  }

  Future<void> setSource(SkillSource source) async {
    if (_source != source) {
      _source = source;
      await _reloadFirstPage();
    }
  }

  Future<void> setSort(SortOption sort) async {
    if (_sort != sort) {
      _sort = sort;
      await _reloadFirstPage();
    }
  }

  Future<void> setCategory(int? categoryId) async {
    if (_categoryId != categoryId) {
      _categoryId = categoryId;
      await _reloadFirstPage();
    }
  }

  Future<Skill> installSkill(String slug) async {
    final service = ref.read(skillsServiceProvider);
    final skill = await _installSkillAndWait(service, slug);
    _replaceSkill(skill);
    return skill;
  }

  Future<void> uninstallSkill(String slug) async {
    final service = ref.read(skillsServiceProvider);
    await service.uninstallSkill(slug);
    _updateSkillStatus(
      slug: slug,
      isInstalled: false,
      installStatus: 'uninstalled',
    );
  }

  Future<Skill> _installSkillAndWait(
    OpenClawSkillsService service,
    String slug,
  ) async {
    final status = _normalizeInstallStatus(await service.installSkill(slug));
    if (status == 'installed') {
      return await service.getSkillDetail(slug);
    }
    if (status == 'failed') {
      throw StateError('技能安装失败');
    }

    const pollInterval = Duration(seconds: 2);
    const maxAttempts = 15;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future<void>.delayed(pollInterval);
      final detailStatus = _normalizeInstallStatus(
        (await service.getSkillDetail(slug)).installStatus,
      );
      if (detailStatus == 'installing') {
        continue;
      }
      if (detailStatus == 'installed') {
        return await service.getSkillDetail(slug);
      }
      if (detailStatus == 'failed') {
        throw StateError('技能安装失败');
      }
    }
    throw StateError('技能安装超时');
  }

  void _replaceSkill(Skill skill) {
    final current = state.value;
    if (current == null) return;
    final updated = current.skills
        .map((item) => item.slug == skill.slug ? skill : item)
        .toList();
    state = AsyncData(current.copyWith(skills: updated));
  }

  void _updateSkillStatus({
    required String slug,
    required bool isInstalled,
    required String installStatus,
  }) {
    final current = state.value;
    if (current == null) return;
    final updated = current.skills.map((item) {
      if (item.slug != slug) return item;
      return item.copyWith(
        isInstalled: isInstalled,
        installStatus: installStatus,
      );
    }).toList();
    state = AsyncData(current.copyWith(skills: updated));
  }

  String _normalizeInstallStatus(String? status) {
    return status?.trim().toLowerCase() ?? '';
  }

  Future<void> _reloadFirstPage() async {
    _page = 1;
    final version = ++_requestVersion;
    final previous = state.value;
    if (previous == null) {
      state = const AsyncLoading();
    } else {
      state = AsyncData(
        previous.copyWith(
          isRefreshing: true,
          isLoading: false,
          clearError: true,
          selectedCategoryId: _categoryId,
          clearSelectedCategory: _categoryId == null,
        ),
      );
    }
    try {
      final next = await _fetchSkillsState();
      if (version == _requestVersion) {
        state = AsyncData(next);
      }
    } catch (e) {
      if (version != _requestVersion || previous == null) return;
      state = AsyncData(
        previous.copyWith(
          isRefreshing: false,
          isLoading: false,
          error: e.toString(),
          selectedCategoryId: _categoryId,
          clearSelectedCategory: _categoryId == null,
        ),
      );
    }
  }

  String get keyword => _keyword;
  SortOption get sort => _sort;
  SkillSource get source => _source;
}
