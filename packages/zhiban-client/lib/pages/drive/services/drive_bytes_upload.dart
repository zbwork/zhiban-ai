import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:zhiban_core/drive/drive_models.dart';

/// F06 upload protocol for a verified, immutable local snapshot. The caller owns
/// the fixed-login API client and cancellation; storage never receives its JWT.
class DriveBytesUpload {
  const DriveBytesUpload({required this.api, required this.storage});
  final Dio api;
  final Dio storage;

  Future<DriveFile> toPersonal({
    required Uint8List bytes,
    required String name,
    required String mime,
    required CancelToken cancel,
  }) async {
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
      throw StateError('文件为空或超过上传大小限制');
    }
    final bootstrap = DriveBootstrap.fromJson(
        _body(await api.post('/drive:bootstrap', cancelToken: cancel)));
    final personal = bootstrap.personal;
    if (personal == null || !personal.isPersonal || personal.uuid.isEmpty) {
      throw StateError('个人云盘暂不可用');
    }
    final fields = {
      'space_uuid': personal.uuid,
      'file_name': name,
      'mime_type': mime,
    };
    if (bytes.length < 10 * 1024 * 1024) {
      return _file(await api.post('/drive/files:upload',
          data: FormData.fromMap({
            ...fields,
            'file': MultipartFile.fromBytes(bytes, filename: name),
          }),
          cancelToken: cancel));
    }
    final ticket = PresignTicket.fromJson(_body(await api.post(
        '/drive/files:presign-put',
        data: {...fields, 'size_bytes': bytes.length},
        cancelToken: cancel)));
    if (ticket.fileUuid.isEmpty) throw StateError('上传凭据无效');
    if (!ticket.isMultipart) {
      await _put(ticket.presignUrl, bytes, cancel, mime: mime);
      return _file(await api.post('/drive/files:confirm',
          data: {'file_uuid': ticket.fileUuid}, cancelToken: cancel));
    }
    final size = ticket.partSize;
    if (size < 5 * 1024 * 1024 || size > 128 * 1024 * 1024) {
      throw StateError('上传分片凭据无效');
    }
    final count = (bytes.length + size - 1) ~/ size;
    if (ticket.partUrls.length != count) throw StateError('上传分片凭据不完整');
    final parts = <Map<String, dynamic>>[];
    for (var index = 0; index < count; index++) {
      final end = (index + 1) * size;
      final response = await _put(
          ticket.partUrls[index],
          Uint8List.sublistView(
              bytes, index * size, end > bytes.length ? bytes.length : end),
          cancel);
      final etag = response.headers.value('etag') ?? '';
      if (etag.isEmpty) throw StateError('上传分片未确认');
      parts.add({'part_number': index + 1, 'etag': etag});
    }
    return _file(await api.post('/drive/files:complete-multipart',
        data: {'file_uuid': ticket.fileUuid, 'parts': parts},
        cancelToken: cancel));
  }

  Future<Response<dynamic>> _put(
      String url, Uint8List bytes, CancelToken cancel,
      {String? mime}) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw StateError('上传地址无效');
    }
    return storage.put(url,
        data: Stream.fromIterable([bytes]),
        cancelToken: cancel,
        options: Options(followRedirects: false, headers: {
          'Content-Length': bytes.length,
          if (mime != null) 'Content-Type': mime,
        }));
  }

  static Map<String, dynamic> _body(Response<dynamic> response) {
    final raw = response.data;
    if (raw is! Map || raw['success'] == false) {
      throw StateError('云盘请求未完成');
    }
    final data = raw['data'] ?? raw;
    if (data is! Map) throw StateError('云盘响应无效');
    return data.cast<String, dynamic>();
  }

  static DriveFile _file(Response<dynamic> response) {
    final body = _body(response);
    final file = DriveFile.fromJson(body['file'] is Map
        ? (body['file'] as Map).cast<String, dynamic>()
        : body);
    if (file.uuid.isEmpty) throw StateError('上传结果未确认，请检查云盘');
    return file;
  }
}
