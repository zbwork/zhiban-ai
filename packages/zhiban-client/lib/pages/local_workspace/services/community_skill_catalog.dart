import 'package:dio/dio.dart';
import 'package:zhiban_client/config/community_resources.dart';
import 'dart:typed_data';

/// Anonymous catalog client: intentionally has no session interceptors.
class CommunitySkillCatalog {
  CommunitySkillCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: CommunityResources.skillsBaseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: false,
            ));
  final Dio _dio;

  final Map<String, Map<String, dynamic>> _bundles = {};

  Uri _bundleUri(String value) {
    final uri =
        Uri.parse(CommunityResources.resolve(_dio.options.baseUrl, value));
    final base = CommunityResources.origin(_dio.options.baseUrl);
    if (uri.origin != base.origin ||
        !uri.path.startsWith('${base.path}packages/')) {
      throw const FormatException('技能包下载来源无效');
    }
    return uri;
  }

  Future<({Uint8List bytes, String sha256})> downloadBundle(String uuid) async {
    if (!_bundles.containsKey(uuid)) await fetch();
    final item = _bundles[uuid];
    if (item == null ||
        item['bundle_url'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(item['bundle_sha256'] as String? ?? '')) {
      throw StateError('技能包未发布，请刷新技能广场后重试');
    }
    var uri = _bundleUri(item['bundle_url'] as String);
    for (var redirect = 0; redirect <= 5; redirect++) {
      final response = await _dio.get<ResponseBody>(uri.toString(),
          options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (s) => s != null && s >= 200 && s < 400,
              receiveTimeout: const Duration(minutes: 2)));
      final body = response.data!;
      if ((response.statusCode ?? 0) >= 300) {
        await body.stream.drain<void>();
        final location = response.headers.value('location');
        if (location == null) {
          throw StateError('技能包跳转地址无效');
        }
        uri = _bundleUri(uri.resolve(location).toString());
        continue;
      }
      final type = body.headers['content-type']?.first ?? '';
      if (!type.contains('zip') && !type.contains('octet-stream')) {
        await body.stream.drain<void>();
        throw StateError('技能包响应无效');
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
        sha256: item['bundle_sha256'] as String
      );
    }
    throw StateError('技能包跳转次数过多');
  }

  Future<Map<String, dynamic>> fetch() async {
    final response = await _dio.get(CommunityResources.resolve(
        _dio.options.baseUrl, 'catalog/v1/skills.json'));
    final envelope = response.data;
    if (envelope is! Map ||
        envelope['format_version'] != 1 ||
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
      final icon = raw['icon_url'] as String? ?? '';
      if (icon.isNotEmpty) {
        raw['icon_url'] =
            CommunityResources.resolve(_dio.options.baseUrl, icon);
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
    _bundles.clear();
    for (final raw in data['items'] as List) {
      _bundles[raw['skill_uuid'] as String] =
          Map<String, dynamic>.from(raw as Map);
    }
    return data;
  }
}
