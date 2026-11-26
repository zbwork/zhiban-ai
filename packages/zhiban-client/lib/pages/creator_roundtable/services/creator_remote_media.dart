import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../local_workspace/services/local_workspace_store.dart';
import 'creator_subtitles.dart';
import 'douyin_creator_service.dart';

typedef CreatorMediaReport = ({
  int archived,
  int failed,
  int transcripts,
  int failedSubtitles,
  int images,
  int failedImages,
});

const maxCreatorImageBytes = 10 * 1024 * 1024;
const maxCreatorMediaBytes = 256 * 1024 * 1024;

String? creatorArchivedImageName(Map metadata, int index, String source) {
  final files = metadata['local_images'];
  if (files is! Map || files['$index'] is! Map) return null;
  final entry = files['$index'] as Map;
  final name = entry['file'];
  return entry['source'] == source &&
          name is String &&
          RegExp(r'^[0-9a-f-]{36}\.(jpg|png|webp|gif)$').hasMatch(name)
      ? name
      : null;
}

String? creatorArchivedMediaName(Map metadata) {
  final name = metadata['local_media_file'];
  return name is String &&
          RegExp(r'^[0-9a-f-]{36}\.(mp4|mov|m4a)$').hasMatch(name)
      ? name
      : null;
}

class CreatorRemoteMedia {
  CreatorRemoteMedia({HttpClientAdapter? adapter})
      : _http = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (status) => status != null,
          headers: const {
            HttpHeaders.refererHeader: 'https://www.douyin.com/',
            HttpHeaders.userAgentHeader: DouyinCreatorService.userAgent,
          },
        )) {
    if (adapter != null) _http.httpClientAdapter = adapter;
  }

  final Dio _http;

  bool _allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasFragment &&
      (uri.host == 'v5-dy-ov-experiment.zjcdn.com' ||
          [
            'douyinvod.com',
            'douyinvod.net',
            'douyin.com',
            'douyinstatic.com',
            'amemv.com',
            'bytecdn.cn',
            'snssdk.com',
            'douyinpic.com',
            'douyincdn.com',
            'byteimg.com'
          ].any(
              (domain) => uri.host == domain || uri.host.endsWith('.$domain')));

  Future<CreatorMediaReport> archive({
    required LocalWorkspaceStore store,
    required String creatorId,
    required List<Map<String, dynamic>> works,
    required Directory root,
    required int maxBytes,
    required CancelToken cancel,
    void Function(String)? onVideoFailure,
    void Function(int current, int total)? onWork,
  }) async {
    final inputs = {for (final work in works) work['id']: work};
    final directory = Directory('${root.path}/media');
    var archived = 0;
    var failed = 0;
    var transcripts = 0;
    var failedSubtitles = 0;
    var images = 0;
    var failedImages = 0;
    final matchedWorks = (await store.creatorWorks(creatorId))
        .where((work) => inputs.containsKey(work['source_work_id']))
        .toList();
    for (final (index, work) in matchedWorks.indexed) {
      if (cancel.isCancelled) break;
      final input = inputs[work['source_work_id']]!;
      onWork?.call(index + 1, matchedWorks.length);
      final workId = work['id'] as String;
      var sourceVersion = work['source_version'] as int;
      final transcript = work['transcript'] as String? ?? '';
      final subtitle = input['subtitle_url'];
      if (transcript.isEmpty && subtitle is String && subtitle.isNotEmpty) {
        try {
          final cues =
              await _read(Uri.parse(subtitle), maxCreatorSubtitleBytes, cancel,
                  (stream) async {
            return parseCreatorSubtitles(
                await utf8.decoder.bind(stream).join());
          });
          if (cancel.isCancelled) break;
          await store.saveCreatorTranscript(
            workId: workId,
            sourceVersion: sourceVersion,
            transcript: cues.map((cue) => cue.text).join('\n'),
            cues: [
              for (final cue in cues)
                {
                  'start_ms': cue.startMs,
                  'end_ms': cue.endMs,
                  'text': cue.text
                },
            ],
            source: 'platform_subtitle',
          );
          sourceVersion++;
          transcripts++;
        } on Exception {
          if (!cancel.isCancelled) failedSubtitles++;
        } on StateError {
          if (!cancel.isCancelled) failedSubtitles++;
        }
      }
      if (cancel.isCancelled) break;
      final metadata = jsonDecode(work['metadata'] as String) as Map;
      final imageUrls =
          (metadata['images'] as List? ?? const []).cast<String>();
      if (imageUrls.isNotEmpty) {
        final imageDir = Directory('${root.path}/images');
        for (final (index, source) in imageUrls.indexed) {
          if (cancel.isCancelled) break;
          final name = creatorArchivedImageName(metadata, index, source);
          if (name != null && await File('${imageDir.path}/$name').exists()) {
            continue;
          }
          File? output;
          var saved = false;
          try {
            final (:bytes, :extension) = await readImage(source, cancel);
            if (cancel.isCancelled) break;
            final fileName = '${LocalWorkspaceStore.uuid.v4()}.$extension';
            await imageDir.create(recursive: true);
            output = File('${imageDir.path}/$fileName');
            await output.writeAsBytes(bytes, flush: true);
            if (cancel.isCancelled) break;
            await store.saveCreatorImageFile(
              workId: workId,
              index: index,
              source: source,
              fileName: fileName,
              digest: sha256.convert(bytes).toString(),
            );
            saved = true;
            images++;
          } on DioException catch (error) {
            debugPrint(
                '[creator-roundtable] image transport: ${error.type.name}');
            if (!cancel.isCancelled) failedImages++;
          } on FormatException catch (error) {
            debugPrint('[creator-roundtable] image rejected: ${error.message}');
            if (!cancel.isCancelled) failedImages++;
          } on Exception {
            if (!cancel.isCancelled) failedImages++;
          } on StateError {
            if (!cancel.isCancelled) failedImages++;
          } finally {
            if (!saved && output != null) {
              try {
                if (await output.exists()) await output.delete();
              } on FileSystemException {
                // The incomplete file was never added to the archive.
              }
            }
          }
        }
        continue;
      }
      final existing = creatorArchivedMediaName(metadata);
      if (existing != null &&
          await File('${directory.path}/$existing').exists()) {
        continue;
      }
      final url = input['media_url'];
      if (url is! String || url.isEmpty) {
        if (url == '' && (input['images'] as List?)?.isEmpty == true) {
          failed++;
          onVideoFailure?.call('抖音没有提供可下载的原片地址。');
        }
        continue;
      }
      final name = '${LocalWorkspaceStore.uuid.v4()}.mp4';
      final file = File('${directory.path}/$name');
      var saved = false;
      try {
        await directory.create(recursive: true);
        await _read(Uri.parse(url), maxBytes, cancel,
            (stream) => _writeVideo(stream, file));
        if (cancel.isCancelled) break;
        final digest = (await sha256.bind(file.openRead()).first).toString();
        if (cancel.isCancelled) break;
        saved = await store.saveCreatorMedia(
          workId: workId,
          sourceVersion: sourceVersion,
          fileName: name,
          digest: digest,
          replaceMissingFile: existing,
        );
        if (saved) archived++;
      } on DioException catch (error) {
        debugPrint(
            '[creator-roundtable] archive transport: ${error.type.name}');
        if (!cancel.isCancelled) {
          failed++;
          onVideoFailure?.call('连接媒体服务器失败。');
        }
      } on FormatException catch (error) {
        debugPrint('[creator-roundtable] archive rejected: ${error.message}');
        if (!cancel.isCancelled) {
          failed++;
          onVideoFailure?.call(error.message);
        }
      } on Exception {
        if (!cancel.isCancelled) failed++;
      } on StateError {
        if (!cancel.isCancelled) failed++;
      } finally {
        if (!saved) {
          try {
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            // An interrupted download never becomes a work's current file.
          }
        }
      }
    }
    return (
      archived: archived,
      failed: failed,
      transcripts: transcripts,
      failedSubtitles: failedSubtitles,
      images: images,
      failedImages: failedImages,
    );
  }

  Future<({Uint8List bytes, String extension})> readImage(
      String source, CancelToken cancel) async {
    final bytes = await _read(Uri.parse(source), maxCreatorImageBytes, cancel,
        (stream) async {
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        buffer.add(chunk);
      }
      return buffer.takeBytes();
    });
    if (bytes.length < 16) throw const FormatException('图片文件不完整。');
    final extension = switch (bytes) {
      [255, 216, 255, ...] => 'jpg',
      [137, 80, 78, 71, 13, 10, 26, 10, ...] => 'png',
      [82, 73, 70, 70, _, _, _, _, 87, 69, 66, 80, ...] => 'webp',
      [71, 73, 70, 56, 55 || 57, 97, ...] => 'gif',
      _ => throw const FormatException('不支持该图片格式。'),
    };
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 24000000) {
        throw const FormatException('图片超过 2400 万像素。');
      }
    } on StateError {
      throw const FormatException('无法解码图片。');
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
    return (bytes: bytes, extension: extension);
  }

  Future<T> _read<T>(Uri uri, int maxBytes, CancelToken cancel,
      Future<T> Function(Stream<List<int>>) consume) async {
    for (var hop = 0; hop <= 3; hop++) {
      if (!_allowed(uri)) {
        throw FormatException(
            '不支持该媒体域名 (${uri.host.split('.').reversed.take(2).toList().reversed.join('.')})');
      }
      final response =
          await _http.getUri<ResponseBody>(uri, cancelToken: cancel);
      final stream = response.data!.stream;
      final status = response.statusCode;
      if ([301, 302, 303, 307, 308].contains(status)) {
        await stream.listen((_) {}).cancel();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        uri = uri.resolve(location);
        continue;
      }
      final length = int.tryParse(
          response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
      if (status != 200 || (length != null && length > maxBytes)) {
        await stream.listen((_) {}).cancel();
        throw FormatException(
            '媒体不可用或超出归档大小 (HTTP $status, ${length ?? 'unknown'} bytes)');
      }
      return consume(_bounded(stream, maxBytes, length));
    }
    throw const FormatException('媒体重定向未返回可用文件');
  }

  Stream<List<int>> _bounded(
      Stream<List<int>> input, int maxBytes, int? length) async* {
    var written = 0;
    await for (final chunk in input) {
      written += chunk.length;
      if (written > maxBytes) throw const FormatException('媒体超出归档大小');
      yield chunk;
    }
    if (length != null && written != length) {
      throw const FormatException('媒体内容不完整');
    }
  }

  Future<void> _writeVideo(Stream<List<int>> stream, File file) async {
    final writer = file.openWrite();
    final header = <int>[];
    try {
      await writer.addStream(stream.map((chunk) {
        if (header.length < 12) {
          header.addAll(chunk.take(12 - header.length));
          if (header.length == 12 &&
              String.fromCharCodes(header, 4, 8) != 'ftyp') {
            throw const FormatException('渠道返回的文件不是 MP4');
          }
        }
        return chunk;
      }));
    } finally {
      await writer.close();
    }
    if (header.length < 12) throw const FormatException('媒体内容不完整');
  }

  void close() => _http.close(force: true);
}
