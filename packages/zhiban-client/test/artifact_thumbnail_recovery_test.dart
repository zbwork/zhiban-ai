import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_card.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_loader.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';

class _Loader extends AttachmentPreviewLoader {
  _Loader(this.load);
  final Future<Uint8List> Function() load;
  @override
  Future<Uint8List> read(AttachmentPreviewTarget target, String format,
          {int? maxBytes}) =>
      load();
}

void main() {
  final svg = Uint8List.fromList(utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="blue"/></svg>'));
  const first = AttachmentPreviewTarget(
      url: 'https://example.test/one.svg',
      name: 'one.svg',
      mime: 'image/svg+xml');
  const second = AttachmentPreviewTarget(
      url: 'https://example.test/two.svg',
      name: 'two.svg',
      mime: 'image/svg+xml');
  Widget card(
          AttachmentPreviewTarget target, Future<Uint8List> Function() read) =>
      MaterialApp(
          home: Scaffold(
              body: ChatArtifactCard(
                  target: target, loaderFactory: () => _Loader(read))));
  testWidgets('desktop SVG thumbnail recovers after a verified preview read',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(card(first, () async {
      if (++attempts == 1) throw StateError('transient');
      return svg;
    }));
    await tester.pumpAndSettle();
    expect(find.text('缩略图加载失败，点击预览查看'), findsOneWidget);
    AttachmentPreviewRefresh.instance.validatedRead(second.url);
    await tester.pump();
    expect(attempts, 1);
    AttachmentPreviewRefresh.instance.validatedRead(first.url);
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('缩略图加载失败，点击预览查看'), findsNothing);
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox());
    AttachmentPreviewRefresh.instance.validatedRead(first.url);
    expect(tester.takeException(), isNull);
  });
  testWidgets('old load failure cannot overwrite a newer successful source',
      (tester) async {
    final old = Completer<Uint8List>();
    await tester.pumpWidget(card(first, () => old.future));
    await tester.pumpWidget(card(second, () async => svg));
    await tester.pumpAndSettle();
    old.completeError(StateError('old result'));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('缩略图加载失败，点击预览查看'), findsNothing);
  });
  test(
      'immutable SHA mismatch remains rejected for local and cloud preview reads',
      () {
    verifyArtifactHash(svg, crypto.sha256.convert(svg).toString());
    expect(() => verifyArtifactHash(svg, 'a' * 64), throwsStateError);
    expect(() => verifyArtifactHash(svg, 'not-a-hash'), throwsStateError);
    expect(
        () => verifyArtifactHash(Uint8List.fromList([...svg, 0]),
            crypto.sha256.convert(svg).toString()),
        throwsStateError);
  });
}
