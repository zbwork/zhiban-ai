import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zhiban_client/network/network.dart';

import '../models/local_coding_models.dart';

/// 契约 §4.5 · 从 Bus 拉取本租户的签名版本目录(灰度对 App 透明)。
///
/// 返回 null 表示 Bus 明确没有目录(接口未挂 / 404),App 应让 Bridge 清除
/// 已采用的目录;网络或服务端故障抛 [LocalCodingCatalogUnavailable],App 保留
/// Bridge 上次落盘的目录不动。
abstract interface class LocalCodingCatalogApi {
  Future<LocalCodingSignedCatalog?> fetchCatalog({
    required String platform,
    required String arch,
  });
}

/// 目录接口暂时取不到(网络 / 5xx / 响应不合法):不是"没有目录"。
class LocalCodingCatalogUnavailable implements Exception {
  const LocalCodingCatalogUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'LocalCodingCatalogUnavailable($reason)';
}

class DioLocalCodingCatalogApi implements LocalCodingCatalogApi {
  DioLocalCodingCatalogApi({Dio? dio}) : _dio = dio ?? sensitiveRequest;

  final Dio _dio;

  @override
  Future<LocalCodingSignedCatalog?> fetchCatalog({
    required String platform,
    required String arch,
  }) async {
    Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '/local-coding-tools/catalog',
        queryParameters: {'platform': platform, 'arch': arch},
        options: Options(extra: const {'silent': true, 'sensitive': true}),
      );
    } on DioException catch (error) {
      // 路由未挂(Bus 未配签名私钥)= 没有目录;其它一律视为暂时取不到。
      if (error.response?.statusCode == 404) return null;
      throw LocalCodingCatalogUnavailable(error.type.name);
    }
    final data = response.data;
    if (data is! Map) {
      throw const LocalCodingCatalogUnavailable('invalid_response');
    }
    try {
      return LocalCodingSignedCatalog.fromJson(Map<String, dynamic>.from(data));
    } on FormatException catch (error) {
      throw LocalCodingCatalogUnavailable(error.message);
    }
  }
}

/// 目录查询用的平台 / 架构名(与 Bridge initialize 的取值一致:macos|windows,
/// arm64|x64)。不支持的组合返回 null,此时不拉目录。
({String platform, String arch})? localCodingCatalogRuntime() {
  if (Platform.isWindows) {
    return Abi.current() == Abi.windowsX64
        ? (platform: 'windows', arch: 'x64')
        : null;
  }
  if (Platform.isMacOS) {
    return switch (Abi.current()) {
      Abi.macosArm64 => (platform: 'macos', arch: 'arm64'),
      Abi.macosX64 => (platform: 'macos', arch: 'x64'),
      _ => null,
    };
  }
  return null;
}
