import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/client_assets.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_seat_layer.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_remote_media.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_seat_portrait.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';

class _PortraitAdapter implements HttpClientAdapter {
  _PortraitAdapter(this.reply);

  ResponseBody Function(RequestOptions request, Uint8List input) reply;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? input,
      Future<void>? cancel) async {
    final data = BytesBuilder();
    await for (final frame in input ?? const Stream<Uint8List>.empty()) {
      data.add(frame);
    }
    return reply(options, data.takeBytes());
  }

  @override
  void close({bool force = false}) {}
}

Future<Uint8List> _png({required bool transparent}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    transparent
        ? const ui.Rect.fromLTWH(4, 3, 8, 12)
        : const ui.Rect.fromLTWH(0, 0, 16, 16),
    ui.Paint()..color = const ui.Color(0xff37367c),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 16);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('图片编辑地址复用模型配置并仅允许 HTTPS 或本机 HTTP', () {
    expect(creatorPortraitEndpoint('https://test.example').toString(),
        'https://test.example/v1/images/edits');
    expect(
        creatorPortraitEndpoint('https://test.example/custom/images/edits/')
            .path,
        '/custom/images/edits');
    expect(creatorPortraitEndpoint('http://127.0.0.1:8188/v1').path,
        '/v1/images/edits');
    for (final target in ['http://test.example/v1', 'https://user@host/v1']) {
      expect(() => creatorPortraitEndpoint(target),
          throwsA(isA<CreatorWorkflowException>()));
    }
  });

  test('公开头像按席位生成透明图，失败保留上一版，不发登录态', () async {
    final root = await Directory.systemTemp.createTemp('creator-portrait-');
    addTearDown(() => root.delete(recursive: true));
    final avatar = await _png(transparent: false);
    final cutout = await _png(transparent: true);
    final avatarAdapter = _PortraitAdapter((request, _) {
      expect(request.uri.host, 'p3.douyinpic.com');
      expect(request.headers['authorization'], isNull);
      expect(request.headers['cookie'], isNull);
      return ResponseBody.fromBytes(avatar, 200);
    });
    var opaque = false;
    final gpu = _PortraitAdapter((request, input) {
      expect(request.uri.host, 'image.example');
      expect(request.uri.path, '/v1/images/edits');
      expect(request.headers['Authorization'], 'Bearer model-key');
      expect(request.followRedirects, isFalse);
      final body = utf8.decode(input, allowMalformed: true);
      expect(body, contains('avatar.png'));
      expect(body, contains('gpt-image-model'));
      expect(body, contains('transparent'));
      expect(body, contains('far-left of the table'));
      expect(body, contains('facing inward'));
      expect(body, contains('upper body from the waist up'));
      return ResponseBody.fromString(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(opaque ? avatar : cutout)}
            ],
          }),
          200);
    });
    final service = CreatorSeatPortraitService(
      transport: Dio()..httpClientAdapter = gpu,
      mediaFactory: () => CreatorRemoteMedia(adapter: avatarAdapter),
    );
    const source = 'https://p3.douyinpic.com/creator.png?original';
    Future<File> generate() => service.generate(
          root: root,
          creatorId: 'author',
          avatar: source,
          slot: 1,
          provider: const AiProviderConfig(
            id: 'provider',
            name: '图片服务',
            baseUrl: 'https://text.example/v1',
            imageEditBaseUrl: 'https://image.example/v1',
          ),
          model: 'gpt-image-model',
          key: 'model-key',
          cancel: CancelToken(),
        );
    final actual = await generate();
    final bytes = await actual.readAsBytes();
    final size = ByteData.sublistView(bytes);
    expect((size.getUint32(16), size.getUint32(20)), (8, 12));
    expect((await service.load(root, 'author', source, 1))?.path, actual.path);
    expect(
        (await service.load(root, 'author',
                'https://p3.douyinpic.com/creator.png?new-signature', 1))
            ?.path,
        actual.path);
    expect(await service.load(root, 'author', source, 2), isNull);
    opaque = true;
    await expectLater(generate(), throwsA(isA<CreatorWorkflowException>()));
    expect(await actual.readAsBytes(), bytes);
  });
  testWidgets('生成图只显示在对应席位，换人后不会沿用前一位的形象', (tester) async {
    final previousPackage = ClientAssets.packageName;
    ClientAssets.packageName = null;
    addTearDown(() => ClientAssets.packageName = previousPackage);
    final root = Directory.systemTemp.createTempSync('creator-seat-layer-');
    addTearDown(() => root.delete(recursive: true));
    final file = (await tester.runAsync(() async {
      return File('${root.path}/portrait.png')
          .writeAsBytes(await _png(transparent: true));
    }))!;
    final portrait = Future<File?>.value(file);
    const seatKey = ValueKey('generated-seat-0');
    const stageKey = ValueKey('stage');
    Widget stage(Future<File?>? current, {double scale = 1}) => MaterialApp(
          home: Center(
            child: SizedBox(
              key: stageKey,
              width: 800 * scale,
              height: 500 * scale,
              child: Stack(fit: StackFit.expand, children: [
                CreatorRoundtableSeatLayer(slot: 0, portrait: current),
                const CreatorRoundtableSeatLayer(slot: 1),
              ]),
            ),
          ),
        );
    await tester.pumpWidget(stage(portrait));
    await tester.pump();
    final seat = find.byKey(seatKey);
    expect(seat, findsOneWidget);
    expect(find.byKey(const ValueKey('generated-seat-1')), findsNothing);
    final stageRect = tester.getRect(find.byKey(stageKey));
    final seatRect = tester.getRect(seat);
    expect(seatRect.width, lessThan(stageRect.width / 2));
    expect(stageRect.contains(seatRect.center), isTrue);
    expect(seatRect.topLeft - stageRect.topLeft, const Offset(94, 211));
    final clip = tester
        .widget<ClipPath>(
          find.ancestor(of: seat, matching: find.byType(ClipPath)).first,
        )
        .clipper!;
    final nearLeft = clip.getClip(stageRect.size);
    expect(nearLeft.contains(const Offset(151, 280)), isTrue);
    expect(
      nearLeft.contains(const Offset(153, 407)),
      isFalse,
      reason: '椅子扶手在人体前方',
    );
    expect(
      nearLeft.contains(const Offset(235, 413)),
      isTrue,
      reason: '椅子旁边可显示小腿和鞋',
    );
    await tester.pumpWidget(stage(portrait, scale: .5));
    await tester.pump();
    final smallStage = tester.getRect(find.byKey(stageKey));
    final smallSeat = tester.getRect(seat);
    expect(smallSeat.topLeft - smallStage.topLeft, const Offset(47, 105.5));
    expect(smallSeat.size, seatRect.size / 2);
    expect(
      clip.getClip(smallStage.size).contains(const Offset(76.5, 203.5)),
      isFalse,
    );
    await tester.pumpWidget(stage(Future<File?>.value(null)));
    expect(seat, findsNothing);
    await tester.pump();
    expect(seat, findsNothing);
  });
}
