import 'dart:convert';
import 'package:zhiban_client/config/community_resources.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same anonymous origin as the skill marketplace; no session interceptors.
class CommunityEmployeeCatalog {
  CommunityEmployeeCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                baseUrl: CommunityResources.agentsBaseUrl,
                followRedirects: false,
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 15)));
  final Dio _dio;
  String get _key =>
      'community_employee_catalog_github_v1.${_dio.options.baseUrl}';
  Future<List<Map<String, dynamic>>> cached() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      return raw == null ? [] : _parse(jsonDecode(raw));
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> _parse(dynamic value) {
    if (value is! List) throw const FormatException('数字员工目录无效');
    final seen = <String>{};
    return value.map((raw) {
      if (raw is! Map) throw const FormatException('数字员工条目无效');
      final item = Map<String, dynamic>.from(raw);
      if (item['uuid'] is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(item['uuid'] as String) ||
          !seen.add(item['uuid']) ||
          item['name'] is! String ||
          item['system_prompt'] is! String ||
          item['requires_backend'] is! bool ||
          item['skill_uuids'] is! List ||
          (item['skill_uuids'] as List).any((id) => id is! String)) {
        throw const FormatException('数字员工字段无效');
      }
      if (item['unavailable_capabilities'] != null &&
          (item['unavailable_capabilities'] is! List ||
              (item['unavailable_capabilities'] as List)
                  .any((v) => v is! String))) {
        throw const FormatException('员工能力说明无效');
      }
      for (final key in [
        'intro',
        'description',
        'welcome_msg',
        'avatar_url',
        'local_engine',
        'execution_locus',
        'updated_at'
      ]) {
        if (item[key] != null && item[key] is! String) {
          throw const FormatException('数字员工字段无效');
        }
      }
      if (item['tags'] != null &&
          (item['tags'] is! List ||
              (item['tags'] as List).any((v) => v is! String))) {
        throw const FormatException('数字员工标签无效');
      }
      final avatar = item['avatar_url'] as String? ?? '';
      if (avatar.isNotEmpty) {
        item['avatar_url'] =
            CommunityResources.resolve(_dio.options.baseUrl, avatar);
      }
      return item;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> fetch() async {
    final response = await _dio.get(CommunityResources.resolve(
        _dio.options.baseUrl, 'catalog/v1/employees.json'));
    final envelope = response.data;
    if (envelope is! Map ||
        envelope['format_version'] != 1 ||
        envelope['success'] != true ||
        envelope['data'] is! Map) {
      throw const FormatException('数字员工目录响应无效');
    }
    final data = envelope['data'] as Map;
    if (data['items'] is! List ||
        data['total'] != (data['items'] as List).length) {
      throw const FormatException('数字员工目录不完整');
    }
    final parsed = _parse(data['items']);
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(parsed));
    return parsed;
  }
}
