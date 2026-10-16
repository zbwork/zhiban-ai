import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'attachment_preview_target.dart';
import 'local_artifact_source.dart';
import 'package:zhiban_client/services/local_agent_service.dart';

/// Only the configured Bus origin may receive the user's bearer credential.
bool isTrustedPreviewApi(Uri uri, Uri base) =>
    uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port;

class AttachmentPreviewLoader {
  AttachmentPreviewLoader(
      {Uri? apiBase, Future<Map<String, String>> Function()? loadAuthHeaders})
      : _apiBase = apiBase,
        _loadAuthHeaders = loadAuthHeaders;
  final Uri? _apiBase;
  final Future<Map<String, String>> Function()? _loadAuthHeaders;
  final _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60)));
  final _cancel = CancelToken();
  void dispose() {
    _cancel.cancel();
    _dio.close(force: true);
  }

  Future<String> resolve(String raw) async {
    raw = raw.trim();
    if (raw.isEmpty) throw const FormatException('文件地址为空');
    if (Platform.isWindows &&
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(raw) &&
        await File(raw).exists()) {
      return File(raw).uri.toString();
    }
    final base = _apiBase ?? Uri.parse(AppConfig.apiUrl());
    // Check the local path before URI parsing: a valid local filename may
    // contain a literal `%`, which is not URI percent encoding.
    if (await File(raw).exists()) return raw;
    final parsed = tryParsePreviewUri(raw);
    if (parsed == null) throw const FormatException('文件地址格式无效');
    if (parsed.scheme == 'file') {
      return raw;
    }
    Uri uri;
    if (!parsed.hasScheme) {
      final root = base.toString().replaceFirst(RegExp(r'/$'), '');
      uri = raw.startsWith('/api/')
          ? base.resolve(raw)
          : (tryParsePreviewUri(
                  '$root/${raw.replaceFirst(RegExp(r'^/'), '')}') ??
              (throw const FormatException('文件地址格式无效')));
    } else {
      uri = parsed;
    }
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const FormatException('不支持的文件地址');
    }
    final isApi = isTrustedPreviewApi(uri, base) &&
        (apiImageNeedsAuth(raw) || uri.path.contains('/drive/files/'));
    if (!isApi) return uri.toString();
    final headers = await (_loadAuthHeaders?.call() ??
        apiImageLoadHeaders('/message-files/'));
    final response = await _dio.get<dynamic>(uri.toString(),
        cancelToken: _cancel,
        options: Options(
            headers: {...headers, 'Accept': 'application/json'},
            followRedirects: false,
            validateStatus: (s) => s != null && s < 400));
    var signed = response.headers.value('location') ?? '';
    if (response.data is Map) {
      final outer = response.data as Map;
      final data = outer['data'] is Map ? outer['data'] as Map : outer;
      signed = (data['url'] ?? signed).toString();
    }
    final target = tryParsePreviewUri(signed);
    if (target == null ||
        !['http', 'https'].contains(target.scheme) ||
        signed == uri.toString()) {
      throw const FormatException('无法获取文件访问地址');
    }
    return signed;
  }

  Future<Uint8List> read(AttachmentPreviewTarget target, String format,
      {int? maxBytes}) async {
    final limit = maxBytes ?? attachmentPreviewLimit(format);
    String? expectedHash;
    var raw = target.url;
    if (Uri.tryParse(raw)?.scheme == 'local-artifact') {
      final source = LocalArtifactSource.parse(target.url);
      if (source == null) throw const FormatException('本地产物引用无效');
      try {
        return await LocalAgentService.instance
            .readArtifact(source, limit, _cancel);
      } catch (_) {
        if (_cancel.isCancelled || source.cloudUrl == null) rethrow;
        raw = source.cloudUrl!;
        expectedHash = source.sha256;
      }
    }
    final resolved = await resolve(raw);
    // `resolved` may be a local filesystem path, where URI parsing is both
    // unnecessary and incorrect for names containing a literal `%`.
    final localFile = File(resolved);
    if (await localFile.exists()) {
      if (await localFile.length() > limit) {
        throw StateError('文件超过 ${limit ~/ (1024 * 1024)} MiB，请下载查看');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in localFile.openRead()) {
        if (_cancel.isCancelled) throw StateError('预览已取消');
        if (bytes.length + chunk.length > limit) {
          throw StateError('文件超过 ${limit ~/ (1024 * 1024)} MiB，请下载查看');
        }
        bytes.add(chunk);
      }
      final result = bytes.takeBytes();
      if (expectedHash != null) {
        verifyArtifactHash(result, expectedHash, message: '云盘副本与原文件不一致');
      }
      return result;
    }
    final uri = tryParsePreviewUri(resolved);
    if (uri == null) throw const FormatException('文件地址格式无效');
    Stream<List<int>> stream;
    if (uri.scheme == 'file' || !uri.hasScheme) {
      final file = uri.scheme == 'file' ? File.fromUri(uri) : File(resolved);
      if (await file.length() > limit) {
        throw StateError('文件超过 ${limit ~/ (1024 * 1024)} MiB，请下载查看');
      }
      stream = file.openRead();
    } else {
      final response = await _dio.get<ResponseBody>(resolved,
          cancelToken: _cancel,
          options: Options(
              responseType: ResponseType.stream,
              headers: const {},
              followRedirects: true));
      final body = response.data!;
      final length = int.tryParse(body.headers['content-length']?.first ?? '');
      if (length != null && length > limit) {
        await body.stream.listen((_) {}).cancel();
        throw StateError('文件超过 ${limit ~/ (1024 * 1024)} MiB，请下载查看');
      }
      stream = body.stream;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (_cancel.isCancelled) throw StateError('预览已取消');
      if (bytes.length + chunk.length > limit) {
        throw StateError('文件超过 ${limit ~/ (1024 * 1024)} MiB，请下载查看');
      }
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (expectedHash != null) {
      verifyArtifactHash(result, expectedHash, message: '云盘副本与原文件不一致');
    }
    return result;
  }
}

/// A successful preview read invalidates only matching thumbnails. No bytes,
/// credentials or failed futures are cached across widgets/sessions.
class AttachmentPreviewRefresh extends ChangeNotifier {
  static final instance = AttachmentPreviewRefresh();
  String? url;
  void validatedRead(String source) {
    url = source;
    notifyListeners();
  }
}
