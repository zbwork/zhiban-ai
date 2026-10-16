import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';

class OpenClawSkillsService {
  OpenClawSkillsService();

  static const String _skillsPath = '/skills';
  static const String _legacySkillsPath = '/app/openclaw-agent/skills';

  Future<Map<String, dynamic>> listSkills({
    String? keyword,
    String? source,
    int? categoryId,
    int page = 1,
    int pageSize = 20,
    String? sortBy,
    String? sortOrder,
  }) async {
    return _withTenantScopeRetry(
      () => _listSkillsOnce(
        keyword: keyword,
        source: source,
        categoryId: categoryId,
        page: page,
        pageSize: pageSize,
        sortBy: sortBy,
        sortOrder: sortOrder,
      ),
    );
  }

  Future<Map<String, dynamic>> _listSkillsOnce({
    String? keyword,
    String? source,
    int? categoryId,
    int page = 1,
    int pageSize = 20,
    String? sortBy,
    String? sortOrder,
  }) async {
    final offset = (page - 1) * pageSize;
    final queryParams = <String, dynamic>{
      'limit': pageSize,
      'offset': offset < 0 ? 0 : offset,
    };
    if (keyword != null && keyword.isNotEmpty) queryParams['q'] = keyword;
    if (source != null && source.isNotEmpty) queryParams['source'] = source;
    if (categoryId != null) queryParams['category_id'] = categoryId;
    if (sortBy != null && sortBy.isNotEmpty) queryParams['sort_by'] = sortBy;
    if (sortOrder != null && sortOrder.isNotEmpty) {
      queryParams['sort_order'] = sortOrder;
    }

    final data = responseAsMap(
      await request.get(_skillsPath, queryParameters: queryParams),
    );
    final listData = _extractList(data);
    final rawSkills =
        listData.whereType<Map<String, dynamic>>().map(Skill.fromJson).toList();
    final filteredSkills = source == null || source.isEmpty
        ? rawSkills
        : rawSkills.where((skill) => skill.source == source).toList();
    final skills = _sortSkills(
      filteredSkills,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
    final total = source == null || source.isEmpty
        ? _extractTotal(data, listData.length)
        : skills.length;

    return {
      'list': skills,
      'total': total,
      'page': _readInt(data['page']) ?? _readInt(data['pageNum']) ?? page,
      'pageSize':
          _readInt(data['pageSize']) ?? _readInt(data['page_size']) ?? pageSize,
    };
  }

  Future<List<SkillCategory>> listCategories() async {
    return _withTenantScopeRetry(_listCategoriesOnce);
  }

  Future<List<SkillCategory>> _listCategoriesOnce() async {
    final data = responseAsMap(await request.get('/skill-categories'));
    final raw = data['items'];
    if (raw is! List) return const <SkillCategory>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SkillCategory.fromJson)
        .where((category) => category.id > 0 && category.name.isNotEmpty)
        .toList(growable: false);
  }

  /// 拉取「技能广场」分组列表：业务线=nexwork、技能类型=场景技能。
  /// 服务端按 tag.group_key 把上架技能切成若干组，最末尾追加 custom 组
  /// （用户名下所有 agent 的自定义技能聚合）。
  Future<List<SkillGroup>> listSkillsGrouped({String? keyword}) async {
    final query = <String, dynamic>{};
    if (keyword != null && keyword.isNotEmpty) {
      query['keyword'] = keyword;
    }
    final result = await listSkills(
      keyword: keyword,
      page: 1,
      pageSize: 200
    );
    final skills = result['list'] as List<Skill>;
    final platformSkills =
        skills.where((skill) => skill.scopeKind != 'tenant').toList();
    final tenantSkills =
        skills.where((skill) => skill.scopeKind == 'tenant').toList();

    return [
      if (platformSkills.isNotEmpty)
        SkillGroup(
          groupKey: 'platform',
          groupName: '平台技能',
          skills: platformSkills,
        ),
      if (tenantSkills.isNotEmpty)
        SkillGroup(
          groupKey: 'tenant',
          groupName: '企业技能',
          skills: tenantSkills
        ),
    ];
  }

  Future<Skill> getSkillDetail(String slug) async {
    return Skill.fromJson(
      responseAsMap(
        await request.get('$_legacySkillsPath/${Uri.encodeComponent(slug)}'),
      ),
    );
  }

  Future<List<InstalledSkill>> listInstalledSkills() async {
    final list =
        responseAsList(await request.get('$_legacySkillsPath/installed'));
    return list
        .map((item) => InstalledSkill.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<String> installSkill(String slug) async {
    final data = responseAsMap(
      await request
          .post('$_legacySkillsPath/${Uri.encodeComponent(slug)}/install'),
    );
    return _readString(data['status']) ?? '';
  }

  /// 把 SkillHub 的某个技能装到指定 agent 下。
  /// 对应后端 POST /app/openclaw-agent/agents/{agentId}/skills/{slug}/install。
  Future<String> installAgentSkill(String agentId, String slug) async {
    final data = responseAsMap(
      await request.post(
        '/app/openclaw-agent/agents/${Uri.encodeComponent(agentId)}/skills/${Uri.encodeComponent(slug)}/install',
      ),
    );
    return _readString(data['status']) ?? '';
  }

  Future<void> uninstallSkill(String slug) async {
    await request
        .delete('$_legacySkillsPath/${Uri.encodeComponent(slug)}/install');
  }

  List<dynamic> _extractList(Map<String, dynamic> data) {
    const possibleKeys = ['list', 'items', 'records', 'data'];
    for (final key in possibleKeys) {
      final value = data[key];
      if (value is List) return value;
    }
    return const [];
  }

  int _extractTotal(Map<String, dynamic> data, int fallback) {
    const possibleKeys = ['total', 'count', 'total_count', 'totalCount'];
    for (final key in possibleKeys) {
      final value = _readInt(data[key]);
      if (value != null) return value;
    }
    return fallback;
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  String? _readString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  List<Skill> _sortSkills(
    List<Skill> skills, {
    String? sortBy,
    String? sortOrder,
  }) {
    if (sortBy == null || sortBy.isEmpty) return skills;
    final sorted = [...skills];
    switch (sortBy) {
      case 'install_count':
      case 'download_count':
        sorted.sort((a, b) => a.downloadCount.compareTo(b.downloadCount));
        break;
      default:
        return skills;
    }
    return sortOrder == 'desc' ? sorted.reversed.toList() : sorted;
  }

  Future<T> _withTenantScopeRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      if (!_isTenantScopeError(error)) rethrow;
      final me = await fetchMeApi();
      final tenants = me.tenantScopes;
      if (tenants.length != 1) rethrow;
      await switchToTenantApi(tenants.first.tenantId);
      return action();
    }
  }

  bool _isTenantScopeError(Object error) {
    if (error is DioException) {
      final message = [
        error.error?.toString(),
        error.message,
        error.response?.data?.toString(),
      ].whereType<String>().join(' ');
      return message.contains('need act_scope=tenant');
    }
    return error.toString().contains('need act_scope=tenant');
  }
}
