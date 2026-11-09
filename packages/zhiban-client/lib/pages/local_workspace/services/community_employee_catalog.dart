import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same anonymous origin as the skill marketplace; no session interceptors.
class CommunityEmployeeCatalog {
  CommunityEmployeeCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                baseUrl: const String.fromEnvironment(
                    'COMMUNITY_SKILLS_BASE_URL',
                    defaultValue: 'https://zb.qkfintech.cn'),
                followRedirects: false,
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 15)));
  final Dio _dio;
  String get _key => 'community_employee_catalog_v1.${_dio.options.baseUrl}';
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
      return item;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> fetch() async {
    final all = <dynamic>[];
    for (var page = 0; page < 200; page++) {
      final response = await _dio.get('/api/public/v1/agents',
          queryParameters: {'limit': 50, 'offset': page * 50});
      final envelope = response.data;
      if (envelope is! Map ||
          envelope['success'] != true ||
          envelope['data'] is! Map) {
        throw const FormatException('数字员工目录响应无效');
      }
      final data = envelope['data'] as Map;
      if (data['items'] is! List || data['total'] is! int) {
        throw const FormatException('数字员工目录响应无效');
      }
      final items = data['items'] as List;
      all.addAll(items);
      if (all.length >= (data['total'] as int)) {
        final parsed = _parse(all);
        await (await SharedPreferences.getInstance())
            .setString(_key, jsonEncode(parsed));
        return parsed;
      }
      if (items.length != 50) throw const FormatException('数字员工目录不完整');
    }
    throw const FormatException('数字员工目录过大');
  }
}
