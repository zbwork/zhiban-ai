import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final creatorImageReaderProvider = Provider<Future<Uint8List> Function(String)>(
  (ref) => readCreatorImage,
);

Future<Uint8List> readCreatorImage(String source) async {
  final uri = Uri.tryParse(source);
  const domains = ['douyinpic.com', 'douyincdn.com', 'byteimg.com'];
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !domains.any((domain) => uri.host.endsWith('.$domain'))) {
    throw const FormatException('此图片地址不在支持的抖音图片来源内。');
  }
  const maxBytes = 10 * 1024 * 1024;
  const timeout = Duration(seconds: 15);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200 ||
        response.contentLength > maxBytes ||
        response.headers.contentType?.primaryType != 'image') {
      throw const FormatException('图片无法读取或超过 10 MiB。');
    }
    final bytes = BytesBuilder(copy: false);
    final elapsed = Stopwatch()..start();
    await for (final chunk in response.timeout(timeout)) {
      if (elapsed.elapsed > timeout) {
        throw const FormatException('图片读取超时，请稍后重试。');
      }
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('图片超过 10 MiB。');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<String> recognizeCreatorImage(Uint8List bytes) async {
  const channel = MethodChannel('cn.qkfintech.zhiban/local-documents');
  final result =
      await channel.invokeMethod<String>('recognizeCreatorImage', bytes);
  final text = result?.trim() ?? '';
  if (text.isEmpty) throw const FormatException('这张图片未识别到可用文字。');
  return text;
}
