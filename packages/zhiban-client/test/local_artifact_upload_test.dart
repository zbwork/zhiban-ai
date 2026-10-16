import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/drive/services/drive_bytes_upload.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_panel.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';

void main() {
  final personal = {
    'spaces': {
      'personal': {'uuid': 'personal1', 'kind': 'personal'}
    }
  };
  test(
      'small snapshots use the personal-space proxy without exposing an OS path',
      () async {
    final api = Dio(BaseOptions(
        baseUrl: 'https://bus.example/api/agent-bus/v1',
        headers: {'Authorization': 'Bearer fixture'}));
    final storage = Dio();
    final calls = <String>[];
    api.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      calls.add(options.path);
      if (options.path == '/drive:bootstrap') {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'success': true, 'data': personal}));
      } else {
        final form = options.data as FormData;
        expect(Map.fromEntries(form.fields), {
          'space_uuid': 'personal1',
          'file_name': 'report.txt',
          'mime_type': 'text/plain'
        });
        expect(form.files.single.value.filename, 'report.txt');
        expect(form.files.single.value.length, 3);
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'data': {
            'file': {'uuid': 'file1'}
          }
        }));
      }
    }));
    try {
      final file = await DriveBytesUpload(api: api, storage: storage)
          .toPersonal(
              bytes: Uint8List.fromList([1, 2, 3]),
              name: 'report.txt',
              mime: 'text/plain',
              cancel: CancelToken());
      expect(file.uuid, 'file1');
      expect(calls, ['/drive:bootstrap', '/drive/files:upload']);
    } finally {
      api.close();
      storage.close();
    }
  });

  test(
      'multipart transfer keeps JWT on Bus, confirms the exact parts and cancels without automatic retry',
      () async {
    for (final abortFirstPart in [false, true]) {
      final api = Dio(BaseOptions(
          baseUrl: 'https://bus.example/api/agent-bus/v1',
          headers: {'Authorization': 'Bearer fixture'}));
      final storage = Dio();
      final cancel = CancelToken();
      var parts = 0;
      var confirmed = false;
      api.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.headers['Authorization'], 'Bearer fixture');
        dynamic body = personal;
        if (options.path.endsWith(':presign-put')) {
          body = {
            'mode': 'multipart',
            'ticket': {
              'file_uuid': 'file2',
              'part_size': 5 * 1024 * 1024,
              'part_urls': [
                'https://storage.example/part1',
                'https://storage.example/part2'
              ]
            }
          };
        } else if (options.path.endsWith(':complete-multipart')) {
          confirmed = true;
          expect(options.data, {
            'file_uuid': 'file2',
            'parts': [
              {'part_number': 1, 'etag': 'etag1'},
              {'part_number': 2, 'etag': 'etag2'}
            ]
          });
          body = {
            'file': {'uuid': 'file2'}
          };
        }
        handler.resolve(Response(
            requestOptions: options, statusCode: 200, data: {'data': body}));
      }));
      storage.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('authorization')));
        expect(options.followRedirects, false);
        expect(options.headers['Content-Length'], 5 * 1024 * 1024);
        parts++;
        if (abortFirstPart) cancel.cancel('test stop');
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            headers: Headers.fromMap({
              'etag': ['etag$parts']
            })));
      }));
      try {
        final result = DriveBytesUpload(api: api, storage: storage).toPersonal(
            bytes: Uint8List(10 * 1024 * 1024),
            name: 'report.bin',
            mime: 'application/octet-stream',
            cancel: cancel);
        if (abortFirstPart) {
          await expectLater(result, throwsA(isA<DioException>()));
          expect(parts, 1);
          expect(confirmed, false);
        } else {
          expect((await result).uuid, 'file2');
          expect(parts, 2);
          expect(confirmed, true);
        }
      } finally {
        api.close();
        storage.close();
      }
    }
  });

  test('a rejected bootstrap never starts an upload', () async {
    final api = Dio();
    final storage = Dio();
    var calls = 0;
    api.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      calls++;
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'success': false, 'data': personal}));
    }));
    try {
      await expectLater(
          DriveBytesUpload(api: api, storage: storage).toPersonal(
              bytes: Uint8List(1),
              name: 'x',
              mime: 'text/plain',
              cancel: CancelToken()),
          throwsStateError);
      expect(calls, 1);
    } finally {
      api.close();
      storage.close();
    }
  });

  testWidgets(
      'local preview has no manual cloud upload button',
      (tester) async {
    final source = LocalArtifactSource(
        artifactId: '33333333-3333-4333-8333-333333333333',
        deviceId: '44444444-4444-4444-8444-444444444444',
        sha256: 'a' * 64,
        conversationId: '22222222-2222-4222-8222-222222222222');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AttachmentPreviewPanel(
                target: AttachmentPreviewTarget(
                    url: source.url, name: 'report.bin'),
                onClose: () {}))));
    expect(find.byTooltip('上传到我的云盘'), findsNothing);
    expect(find.text('确认上传'), findsNothing);
  });
}
