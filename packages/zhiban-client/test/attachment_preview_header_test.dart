import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_header.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

void main() {
  testWidgets('file identity is one compact row with actual size and actions',
      (tester) async {
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 650,
          child: AttachmentPreviewHeader(
            target: const AttachmentPreviewTarget(url: '', name: '季度采购.xlsx'),
            byteLength: 7680,
            onReload: () {},
            onDownload: () => downloads++,
            onClose: () {},
            onExpand: () {},
          )),
    ))));
    expect(find.text('文件预览'), findsNothing);
    expect(find.text('7.5 KB'), findsOneWidget);
    expect(
        tester
            .widget<FileAttachmentIcon>(find.byType(FileAttachmentIcon))
            .fileName,
        '季度采购.xlsx');
    await tester.tap(find.byTooltip('下载'));
    expect(downloads, 1);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
        'narrow large-text header keeps actions reachable in $brightness',
        (tester) async {
      var reloads = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
              body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 320,
                child: AttachmentPreviewHeader(
                  target: const AttachmentPreviewTarget(
                      url: '',
                      name: '很长的文件名称包含中文和英文以及项目记录',
                      mime: 'application/pdf'),
                  byteLength: 131072,
                  trailingInset: 64,
                  onReload: () => reloads++,
                  onDownload: () {},
                  onClose: () {},
                  onExpand: () {},
                ),
          ),
        ),
      ),
            ),
          ),
        );
      expect(find.text('128.0 KB'), findsNothing);
      expect(
          tester
              .widget<FileAttachmentIcon>(find.byType(FileAttachmentIcon))
              .fileName,
          'preview.pdf');
      expect(find.byTooltip('关闭预览'), findsOneWidget);
      expect(find.byTooltip('展开预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('更多文件操作'));
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(reloads, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
