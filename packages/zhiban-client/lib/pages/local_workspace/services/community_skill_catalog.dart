import 'package:dio/dio.dart';
import 'dart:typed_data';

/// Anonymous catalog client: intentionally has no session interceptors.
class CommunitySkillCatalog {
  CommunitySkillCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: const String.fromEnvironment('COMMUNITY_SKILLS_BASE_URL',
                  defaultValue: 'https://zb.qkfintech.cn'),
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: false,
            ));
  final Dio _dio;

  Future<({Uint8List bytes, String sha256})> downloadBundle(String uuid) async {
    final response = await _dio.post<ResponseBody>(
        '/api/public/v1/skills:export',
        data: {
          'skill_uuids': [uuid]
        },
        options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(minutes: 2)));
    final body = response.data!;
    if (!(body.headers['content-type']?.first ?? '')
        .contains('application/zip')) {
      await body.stream.drain<void>();
      throw StateError('该技能暂未开放下载，请刷新技能广场后重试');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > 200 * 1024 * 1024) {
        throw StateError('技能包过大');
      }
      bytes.add(chunk);
    }
    return (
      bytes: bytes.takeBytes(),
      sha256: body.headers['x-content-sha256']?.first ?? ''
    );
  }

  Future<Map<String, dynamic>> fetch() async {
    final response = await _dio.get('/api/public/v1/skills');
    final envelope = response.data;
    if (envelope is! Map ||
        envelope['success'] != true ||
        envelope['data'] is! Map) {
      throw const FormatException('技能目录响应无效');
    }
    final data = Map<String, dynamic>.from(envelope['data'] as Map);
    if (data['items'] is! List ||
        data['categories'] is! List ||
        data['total'] != (data['items'] as List).length) {
      throw const FormatException('技能目录不完整');
    }
    final codes = <String>{};
    for (final raw in data['items'] as List) {
      if (raw is! Map ||
          raw['code'] is! String ||
          (raw['code'] as String).isEmpty ||
          raw['skill_uuid'] is! String ||
          (raw['skill_uuid'] as String).isEmpty ||
          raw['name'] is! String ||
          !codes.add(raw['code'] as String)) {
        throw const FormatException('技能目录条目无效');
      }
      for (final field in [
        'description',
        'latest_version',
        'usage_example',
        'icon_url',
        'source'
      ]) {
        if (raw[field] != null && raw[field] is! String) {
          throw const FormatException('技能目录字段无效');
        }
      }
      for (final field in ['category_id', 'sort_order', 'install_count']) {
        if (raw[field] != null && raw[field] is! int) {
          throw const FormatException('技能目录数字字段无效');
        }
      }
    }
    for (final raw in data['categories'] as List) {
      if (raw is! Map ||
          raw['id'] is! int ||
          raw['code'] is! String ||
          raw['name'] is! String ||
          raw['sort_order'] is! int) {
        throw const FormatException('技能分类无效');
      }
    }
    return data;
  }
}
