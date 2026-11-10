import 'dart:convert';
import 'package:zhiban_core/chat/chat_models.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/message_bubble/components/message_bubble_file_attachments.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_turn_input.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_attachment.dart';

Uint8List document(Map<String, String> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('persisted local images reuse media classification without losing paths',
      () {
    for (final name in ['看板.png', 'PHOTO.JPG', 'image.jpeg', 'chart.webp']) {
      final attachment =
          LocalAttachment(name: name, path: '/tmp/$name', size: 42, text: '');
      final restored =
          LocalAttachment.decode(jsonEncode([attachment.toJson()])).single.file;
      expect(restored.fileType, ChatFileType.image);
      expect(restored.filePath, '/tmp/$name');
      expect(restored.fileLink, Uri.file('/tmp/$name').toString());
      expect(restored.sizeBytes, 42);
    }
    for (final name in [
      'report.xlsx',
      'report.docx',
      'README',
      'image.png.zip'
    ]) {
      expect(
          LocalAttachment(name: name, path: '/tmp/$name', size: 1, text: '')
              .file
              .fileType,
          ChatFileType.file);
    }
  });
  testWidgets(
      'local PNG renders a decoded thumbnail instead of a document card',
      (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('local-thumbnail-');
      try {
        final file = await File('${dir.path}/看板.png').writeAsBytes(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQyfj/HwAEygKLuK2khgAAAABJRU5ErkJggg=='));
        final attachment = LocalAttachment(
            name: '看板.png',
            path: file.path,
            size: await file.length(),
            text: '');
        await tester.pumpWidget(ProviderScope(
            child: MaterialApp(
                home: Scaffold(
                    body: MessageBubbleFileAttachments(
                        files: [attachment.file])))));
        await precacheImage(FileImage(file),
                tester.element(find.byType(MessageBubbleImageAttachment)))
            .timeout(const Duration(seconds: 5));
        await tester.pump();
        expect(find.byType(MessageBubbleImageAttachment), findsOneWidget);
        expect(find.byType(MessageBubbleDocumentAttachment), findsNothing);
        expect(find.byType(Image), findsOneWidget);
        expect(
            tester.widget<Image>(find.byType(Image)).image, isA<FileImage>());
        expect(tester.getSize(find.byType(Image)).height,
            kMessageBubbleImageHeight);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
  test('extracts Word paragraphs and Excel shared/inline/numeric cells', () {
    final word = document({
      'word/document.xml':
          '<w:document xmlns:w="urn:word"><w:body><w:p><w:r><w:t>合同金额</w:t></w:r><w:r><w:t>100元</w:t></w:r></w:p><w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>'
    });
    expect(extractDocumentText({'bytes': word, 'extension': 'docx'}),
        '合同金额100元\n第二段');
    final excel = document({
      'xl/sharedStrings.xml': '<sst><si><t>收入</t></si></sst>',
      'xl/worksheets/sheet1.xml':
          '<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>500</v></c><c r="C1" t="inlineStr"><is><t>元</t></is></c></row></sheetData></worksheet>'
    });
    expect(extractDocumentText({'bytes': excel, 'extension': 'xlsx'}),
        contains('A1: 收入\tB1: 500\tC1: 元'));
  });
  test('rejects empty, binary, oversized text and XML entities', () {
    for (final text in ['', '\u0000binary', 'a' * 60001]) {
      expect(
          () => extractDocumentText({
                'bytes': Uint8List.fromList(utf8.encode(text)),
                'extension': 'txt'
              }),
          throwsStateError);
    }
    expect(
        () => extractDocumentText({
              'bytes': document({
                'word/document.xml':
                    '<!DOCTYPE x [<!ENTITY a SYSTEM "file:///etc/passwd">]><x/>'
              }),
              'extension': 'docx'
            }),
        throwsStateError);
  });
  test(
      'bounded import accepts originals, rejects oversize and symlink; reads UTF8',
      () async {
    final dir = await Directory.systemTemp.createTemp('local-document-test-');
    try {
      final file = await File('${dir.path}/报价.txt').writeAsString('总计 200 元');
      final item = await LocalAttachmentService().read(file.path);
      expect(item.text, '总计 200 元');
      expect(
          LocalAttachment.decode(jsonEncode([item.toJson()]))
              .single
              .file
              .filePath,
          file.path);
      final huge = File('${dir.path}/huge.txt');
      final handle = await huge.open(mode: FileMode.write);
      await handle.truncate(LocalAttachmentService.maxBytes + 1);
      await handle.close();
      await expectLater(
          LocalAttachmentService().read(huge.path), throwsStateError);
      for (final name in [
        'old.doc',
        'photo.png',
        'bundle.zip',
        'README',
        'bad.docx'
      ]) {
        final raw =
            await File('${dir.path}/$name').writeAsBytes([0, 255, 1, 2]);
        final imported = await LocalAttachmentService().read(raw.path);
        expect(imported.text, isEmpty);
        expect(imported.digest, hasLength(64));
        expect(LocalTurnInput.content('', [imported]), contains('需通过本轮附件索引'));
      }
      final link = await Link('${dir.path}/link.txt').create(file.path);
      await expectLater(
          LocalAttachmentService().read(link.path), throwsStateError);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('opaque files persist and same-size source changes are rejected',
      () async {
    final dir = await Directory.systemTemp.createTemp('local-original-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    try {
      final file =
          await File('${dir.path}/bundle.zip').writeAsBytes([0, 255, 1, 2]);
      final service = LocalAttachmentService();
      final item = await service.read(file.path);
      final saved = (await service.persist('employee', [item])).single;
      expect(await File(saved.path).readAsBytes(), [0, 255, 1, 2]);
      expect(LocalAttachment.decode(jsonEncode([saved.toJson()])).single.digest,
          item.digest);
      await file.writeAsBytes([0, 255, 2, 1]);
      await expectLater(service.persist('employee', [item]), throwsStateError);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    }
  });
}
