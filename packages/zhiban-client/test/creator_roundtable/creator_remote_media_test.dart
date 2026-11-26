import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_remote_media.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

class _MediaAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bytes = [0, 0, 0, 12, ...ascii.encode('ftypisom')];
  final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==');

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.path == '/image') {
      return ResponseBody.fromBytes(image, 200);
    }
    if (options.uri.path == '/caption') {
      return ResponseBody.fromString(
          'WEBVTT\n\n00:00:00.200 --> 00:00:01.500\n作品原有字幕\n', 200);
    }
    if (options.uri.path == '/redirect') {
      return ResponseBody.fromString('', 302, headers: {
        'location': ['https://unrelated.invalid/video'],
      });
    }
    return ResponseBody.fromBytes(
        options.uri.path == '/bad' ? List.filled(12, 0) : bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('归档直链 MP4，复用已存文件并能补回丢失的副本', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final root =
        await Directory.systemTemp.createTemp('roundtable-media-test-');
    addTearDown(() => root.delete(recursive: true));
    final adapter = _MediaAdapter();
    final media = CreatorRemoteMedia(adapter: adapter);
    addTearDown(media.close);
    final works = [
      {
        'id': '1234567890123456789',
        'title': '可归档',
        'media_url': 'https://v5-dy-ov-experiment.zjcdn.com/video?signature=ephemeral',
        'subtitle_url': 'https://sf1.douyinstatic.com/caption'
      },
      {
        'id': '1234567890123456790',
        'title': '不可信跳转',
        'media_url': 'https://v.douyinvod.com/redirect'
      },
      {
        'id': '1234567890123456791',
        'title': '非视频',
        'media_url': 'https://v.douyinvod.com/bad'
      },
    ];
    final saved =
        await store.importCreatorWorks({'id': 'test', 'name': '测试博主'}, works);

    Future<CreatorMediaReport> archive(List<Map<String, dynamic>> input) =>
        media.archive(
          store: store,
          creatorId: saved.creatorId,
          works: input,
          root: root,
          maxBytes: 64,
          cancel: CancelToken(),
        );
    Future<LocalRow> archivedWork() async =>
        (await store.creatorWorks(saved.creatorId))
            .singleWhere((work) => work['title'] == '可归档');

    expect(await archive(works), (
      archived: 1,
      failed: 2,
      transcripts: 1,
      failedSubtitles: 0,
      images: 0,
      failedImages: 0
    ));
    expect(adapter.requests, hasLength(4));
    expect(
        adapter.requests.every((request) =>
            ['v.douyinvod.com', 'sf1.douyinstatic.com', 'v5-dy-ov-experiment.zjcdn.com']
                .contains(request.uri.host) &&
            request.followRedirects == false &&
            !request.headers.keys.any((key) => key.toLowerCase() == 'cookie')),
        isTrue);
    final row = await archivedWork();
    final metadata = row['metadata'] as String;
    expect(row['transcript'], '作品原有字幕');
    expect(jsonDecode(metadata)['transcript_cues'], [
      {'start_ms': 200, 'end_ms': 1500, 'text': '作品原有字幕'},
    ]);
    expect(metadata, isNot(contains('signature')));
    final path = '${root.path}/media';
    final name = creatorArchivedMediaName(jsonDecode(metadata) as Map)!;
    final file = File('$path/$name');
    expect(await file.readAsBytes(), adapter.bytes);
    expect(await Directory(path).list().length, 1);
    expect(await archive([works.first]), (
      archived: 0,
      failed: 0,
      transcripts: 0,
      failedSubtitles: 0,
      images: 0,
      failedImages: 0
    ));
    expect(adapter.requests, hasLength(4));
    await file.delete();
    expect(await archive([works.first]), (
      archived: 1,
      failed: 0,
      transcripts: 0,
      failedSubtitles: 0,
      images: 0,
      failedImages: 0
    ));
    final repaired = await archivedWork();
    expect(repaired['source_version'], row['source_version']);
    expect(await Directory(path).list().length, 1);
  });

  test('图文只归档有效图片，副本丢失可恢复并保持证据版本', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final root =
        await Directory.systemTemp.createTemp('roundtable-image-test-');
    addTearDown(() => root.delete(recursive: true));
    final adapter = _MediaAdapter();
    final media = CreatorRemoteMedia(adapter: adapter);
    addTearDown(media.close);
    const source = 'https://p3.douyinpic.com/image';
    final works = [
      {
        'id': '1234567890123456789',
        'title': '图文',
        'images': [source, 'https://p3.douyinpic.com/bad']
      },
    ];
    final archived = await store.importCreatorWorks({'id': 'test'}, works);
    Future<CreatorMediaReport> archive() => media.archive(
          store: store,
          creatorId: archived.creatorId,
          works: works,
          root: root,
          maxBytes: 64,
          cancel: CancelToken(),
        );
    Future<LocalRow> work() async =>
        (await store.creatorWorks(archived.creatorId)).single;
    final report = await archive();
    expect(report.images, 1);
    expect(report.failedImages, 1);
    final row = await work();
    final metadata = jsonDecode(row['metadata'] as String) as Map;
    final first = creatorArchivedImageName(metadata, 0, source)!;
    expect(creatorArchivedImageName(metadata, 1, source), isNull);
    expect(creatorArchivedImageName(metadata, 0, '$source?changed'), isNull);
    final file = File('${root.path}/images/$first');
    expect(await file.readAsBytes(), adapter.image);
    expect((await archive()).images, 0);
    await file.delete();
    expect((await archive()).images, 1);
    expect((await work())['source_version'], row['source_version']);
  });
}
