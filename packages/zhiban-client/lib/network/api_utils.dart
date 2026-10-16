import 'dart:convert';

import 'package:dio/dio.dart';
import 'network.dart';

class ApiUploadFile {
  const ApiUploadFile({required this.path, required this.fileName});

  final String path;
  final String fileName;
}

Future<dynamic> uploadApiFile(
  String path, {
  required ApiUploadFile file,
  String fieldName = 'file',
}) async {
  final formData = FormData.fromMap({
    fieldName: await MultipartFile.fromFile(
      file.path,
      filename: file.fileName
    ),
  });
  return request.post(path, data: formData);
}

/// 带额外 form 字段的 multipart 上传(用于 KB 上传等需要 kbFolderId 等附加参数的场景)。
Future<dynamic> uploadApiFileWithFields(
  String path, {
  required String filePath,
  required String fileName,
  Map<String, dynamic> additionalFields = const {},
  String fieldName = 'file',
}) async {
  final fields = <String, dynamic>{
    ...additionalFields,
    fieldName: await MultipartFile.fromFile(filePath, filename: fileName),
  };
  return request.post(path, data: FormData.fromMap(fields));
}

Stream<String> apiSseLines(
  String path, {
  Map<String, dynamic>? queryParameters,
  bool silent = false,
}) async* {
  final response = await request.get<ResponseBody>(
    path,
    queryParameters: queryParameters,
    options: Options(
      responseType: ResponseType.stream,
      headers: const {
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
      },
      extra: {'silent': silent},
    ),
  );
  final body = response.data;
  if (body == null) return;
  yield* body.stream
      .map((chunk) => chunk.toList())
      .transform(utf8.decoder)
      .transform(const LineSplitter());
}

Map<String, dynamic> responseAsMap(dynamic raw) {
  final value = _responseData(raw);
  if (value is Map<String, dynamic>) {
    return value;
  }
  return const <String, dynamic>{};
}

List<dynamic> responseAsList(dynamic raw) {
  final value = _responseData(raw);
  if (value is List) {
    return value;
  }
  return const <dynamic>[];
}

dynamic _responseData(dynamic raw) {
  if (raw is Response) {
    return raw.data;
  }
  return raw;
}
