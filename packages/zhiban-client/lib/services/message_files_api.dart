import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

/// F09 群聊附件链路客户端。
///
/// 端契约见 docs/contracts/agent-bus-client-contract.md。
///
/// 默认工作流：
/// 1. 客户端 multipart 上传到 `/message-files/upload`。
/// 2. Bus 服务端写对象存储 staging key 并复用 confirm 链路。
///
/// 兼容工作流：
/// 1. `presign({file_name, file_size, mime_type})` → 拿 `{file_uuid, upload_url,
///    upload_headers}`。
/// 2. 客户端 PUT 文件二进制到 `upload_url`，**不带** 业务鉴权头（OSS PUT
///    被业务拦截器加 Bearer 会破坏 OSS 签名校验，参考
///    `services/account_info_api.dart::uploadAvatar`）。
/// 3. `confirm({file_uuid})` 后拿到最终入库的 `file_uuid`。
/// 4. 把 `file_uuid` 数组拼进 IM payload 发出，群组里其他端通过 webhook backfill
///    看到 `conversation_message_files` 关联。
class MessageFilesService {
  MessageFilesService({Dio? ossDio}) : _ossDio = ossDio;

  final Dio? _ossDio;

  /// 第一步：换 presign。
  Future<MessageFilePresign> presign({
    required String fileName,
    required int fileSize,
    required String mimeType,
    String? conversationUuid,
    CancelToken? cancelToken,
  }) async {
    final resp = await request.post(
      '/message-files/presign',
      data: <String, dynamic>{
        'file_name': fileName,
        'file_size': fileSize,
        'mime_type': mimeType,
        if (conversationUuid != null && conversationUuid.isNotEmpty)
          'conversation_uuid': conversationUuid,
      },
      cancelToken: cancelToken,
    );
    return MessageFilePresign.fromJson(resp.data as Map<String, dynamic>);
  }

  /// 第二步：上传字节到 OSS。`presign.uploadHeaders` 必须原样回传。
  ///
  /// [onSendProgress] 透传 Dio 真实上传进度(sent/total);[cancelToken] 可真取消上传
  /// (取消时 Dio 抛 `DioException(type: cancel)`)。供"上传进度 / 取消上传"用。
  Future<void> putToOss({
    required MessageFilePresign presign,
    required String filePath,
    required String mimeType,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(filePath);
    final size = await file.length();
    final bytes = await file.readAsBytes();
    final dio = _ossDio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 300),
          receiveTimeout: const Duration(seconds: 30),
        ));
    final headers = <String, dynamic>{
      HttpHeaders.contentTypeHeader: mimeType,
      HttpHeaders.contentLengthHeader: size,
      ...presign.uploadHeaders,
    };
    final put = await dio.put(
      presign.uploadUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(headers: headers),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    if (put.statusCode == null || put.statusCode! >= 300) {
      throw HttpException('OSS PUT 失败: HTTP ${put.statusCode}');
    }
  }

  /// 第三步：confirm。返回最终 file_uuid（与 presign 相同，但状态切到 `ready`）。
  Future<String> confirm({
    required String fileUuid,
    String? storageKey,
    CancelToken? cancelToken,
  }) async {
    final resp = await request.post(
      '/message-files/confirm',
      data: <String, dynamic>{
        'file_uuid': fileUuid,
        if (storageKey != null && storageKey.isNotEmpty)
          'storage_key': storageKey,
      },
      cancelToken: cancelToken,
    );
    final data = resp.data as Map<String, dynamic>;
    return (data['file_uuid'] ?? fileUuid).toString();
  }

  /// 默认代理上传：客户端只访问 Bus，Bus 使用服务端网络写对象存储。
  Future<String> uploadFileViaBus({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? conversationUuid,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final fields = <String, dynamic>{
      'file_name': fileName,
      'mime_type': mimeType,
      if (conversationUuid != null && conversationUuid.isNotEmpty)
        'conversation_uuid': conversationUuid,
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    };
    final resp = await request.post(
      '/message-files/upload',
      data: FormData.fromMap(fields),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    final data = responseAsMap(resp);
    return (data['file_uuid'] ?? '').toString();
  }

  /// 上传整文件的一站式 helper。
  ///
  /// [onSendProgress]/[cancelToken] 透传给 Bus multipart 上传阶段。
  Future<String> uploadFile({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? conversationUuid,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    return uploadFileViaBus(
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      conversationUuid: conversationUuid,
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
  }

  /// 兼容直传路径：保留给内网环境或后续上传模式切换。
  Future<String> uploadFileDirect({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? conversationUuid,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final size = await File(filePath).length();
    final presign = await this.presign(
      fileName: fileName,
      fileSize: size,
      mimeType: mimeType,
      conversationUuid: conversationUuid,
      cancelToken: cancelToken,
    );
    await putToOss(
      presign: presign,
      filePath: filePath,
      mimeType: mimeType,
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    return confirm(
      fileUuid: presign.fileUuid,
      storageKey: presign.storageKey,
      cancelToken: cancelToken,
    );
  }
}

class MessageFilePresign {
  MessageFilePresign({
    required this.fileUuid,
    required this.uploadUrl,
    required this.storageKey,
    required this.uploadHeaders,
    required this.expiresAt,
    required this.stagedUntil,
  });

  final String fileUuid;
  final String uploadUrl;
  final String storageKey;
  final Map<String, String> uploadHeaders;
  final DateTime? expiresAt;
  final DateTime? stagedUntil;

  factory MessageFilePresign.fromJson(Map<String, dynamic> json) {
    final raw = (json['upload_headers'] as Map?) ?? const {};
    final headers = <String, String>{};
    raw.forEach((k, v) => headers[k.toString()] = v.toString());
    return MessageFilePresign(
      fileUuid: (json['file_uuid'] ?? '').toString(),
      uploadUrl: (json['upload_url'] ?? '').toString(),
      storageKey: (json['storage_key'] ?? '').toString(),
      uploadHeaders: headers,
      expiresAt: _parseTime(json['expires_at']),
      stagedUntil: _parseTime(json['staged_until']),
    );
  }
}

DateTime? _parseTime(dynamic raw) {
  if (raw == null) return null;
  if (raw is String && raw.isNotEmpty) {
    return DateTime.tryParse(raw)?.toUtc();
  }
  return null;
}
