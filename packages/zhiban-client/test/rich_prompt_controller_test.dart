import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ImMessageBlock textBlock(String text) =>
      ImMessageBlock(kind: ImMessageBlockKind.text, text: text);
  ImMessageBlock imageBlock(String name) => ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/img/preview',
        name: name,
      );
  ImMessageBlock fileBlock(String name) => ImMessageBlock(
        kind: ImMessageBlockKind.file,
        url: '/chat/media/file/download',
        name: name,
        size: 128,
      );

  RichPromptAttachment readyAttachment({
    required String id,
    required String name,
    required ChatFileType type,
    required ImMessageBlock block,
  }) =>
      RichPromptAttachment(
        id: id,
        fileName: name,
        fileType: type,
        status: RichAttachmentStatus.ready,
        progress: 100,
        block: block,
      );

  test('toMixedBlocks preserves text, multiple images, and files order', () {
    final c = RichPromptController(text: '开头 ');
    c.insertAttachment(readyAttachment(
      id: 'file-1',
      name: 'EasyO软件源代码.docx',
      type: ChatFileType.file,
      block: fileBlock('EasyO软件源代码.docx'),
    ));
    c.text = '${c.text} 中间 ';
    c.insertAttachment(readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    ));
    c.text = '${c.text} 继续 ';
    c.insertAttachment(readyAttachment(
      id: 'img-2',
      name: 'b.png',
      type: ChatFileType.image,
      block: imageBlock('b.png'),
    ));
    c.text = '${c.text} 结尾 ';
    c.insertAttachment(readyAttachment(
      id: 'file-2',
      name: '计划表.xlsx',
      type: ChatFileType.file,
      block: fileBlock('计划表.xlsx'),
    ));

    final blocks = c.toMixedBlocks();
    expect(blocks.map((b) => b.kind).toList(), [
      ImMessageBlockKind.text,
      ImMessageBlockKind.file,
      ImMessageBlockKind.text,
      ImMessageBlockKind.image,
      ImMessageBlockKind.text,
      ImMessageBlockKind.image,
      ImMessageBlockKind.text,
      ImMessageBlockKind.file,
    ]);
    expect(blocks[1].name, 'EasyO软件源代码.docx');
    expect(blocks[3].name, 'a.png');
    expect(blocks[5].name, 'b.png');
    expect(blocks[7].name, '计划表.xlsx');
  });

  test('summaryOfBlocks uses readable media labels in message preview', () {
    final summary = RichPromptController.summaryOfBlocks([
      textBlock('文字一'),
      imageBlock('a.png'),
      fileBlock('计划表.xlsx'),
      textBlock('文字二'),
    ]);
    expect(summary, '文字一 [图片] 计划表.xlsx 文字二');
  });

  test('removeAttachment deletes its private token and keeps normal text', () {
    final c = RichPromptController(text: 'before ');
    c.insertAttachment(readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    ));
    c.text = '${c.text}after';

    c.removeAttachment('img-1');

    expect(c.text, 'before after');
    expect(c.toMixedBlocks().single.text, 'before after');
  });

  testWidgets('buildTextSpan stays plain text; attachments are draft blocks',
      (tester) async {
    final c = RichPromptController(text: 'before ');
    c.insertAttachment(readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    ));
    c.text = '${c.text}after';

    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        final span = c.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 15),
          withComposing: false,
        );
        final widgetSpans = (span.children ?? const <InlineSpan>[])
            .whereType<WidgetSpan>()
            .toList();
        expect(widgetSpans, isEmpty);
        expect(span.text, 'after');
        expect(c.draftBlocks.map((b) => b.kind).toList(), [
          RichPromptDraftBlockKind.text,
          RichPromptDraftBlockKind.attachment,
          RichPromptDraftBlockKind.text,
        ]);
        expect(c.draftBlocks.first.text, 'before ');
        expect(c.draftBlocks[1].attachment?.fileName, 'a.png');
        expect(c.draftBlocks.last.text, 'after');
        return const SizedBox.shrink();
      }),
    ));
  });

  testWidgets('leading attachment moves active caret to trailing text block',
      (tester) async {
    final c = RichPromptController();
    c.insertAttachment(readyAttachment(
      id: 'file-1',
      name: '计划表.xlsx',
      type: ChatFileType.file,
      block: fileBlock('计划表.xlsx'),
    ));
    c.text = '${c.text}说明文字';

    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        final span = c.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 15),
          withComposing: false,
        );
        expect(span.text, '说明文字');
        expect(c.activeTextBlockIndex, 2);
        expect(c.draftBlocks[1].attachment?.fileName, '计划表.xlsx');
        return const SizedBox.shrink();
      }),
    ));
  });

  test('attachment inserted at end keeps previous text before media', () {
    final c = RichPromptController(text: 'before');
    c.selection = const TextSelection.collapsed(offset: 6);
    c.insertAttachment(readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    ));

    expect(c.text, '');
    expect(c.selection.baseOffset, 0);
    expect(c.textWithoutAttachmentTokens, 'before');
    expect(c.toMixedBlocks().map((b) => b.kind).toList(), [
      ImMessageBlockKind.text,
      ImMessageBlockKind.image,
    ]);
    expect(c.toMixedBlocks().first.text, 'before');
  });

  test('trailing focus and arrow keys can recover across attachment blocks',
      () {
    final c = RichPromptController(text: 'before');
    c.selection = const TextSelection.collapsed(offset: 6);
    c.insertAttachment(readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    ));
    c.text = 'after';

    c.activateTextBlock(0);
    expect(c.text, 'before');
    expect(c.moveToNextTextBlockFromCaretEnd(), isTrue);
    expect(c.text, 'after');
    expect(c.selection.baseOffset, 0);

    c.activateTrailingTextBlock();
    expect(c.activeTextBlockIndex, c.draftBlocks.length - 1);
    expect(c.text, 'after');

    c.selection = const TextSelection.collapsed(offset: 0);
    expect(c.moveToPreviousTextBlockFromCaretStart(), isTrue);
    expect(c.text, 'before');
    expect(c.selection.baseOffset, 'before'.length);
  });

  testWidgets('protected image preview waits for auth headers before loading',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'test-token',
    });
    final attachment = readyAttachment(
      id: 'img-1',
      name: 'a.png',
      type: ChatFileType.image,
      block: imageBlock('a.png'),
    );

    await tester.pumpWidget(MaterialApp(
      home: RichPromptAttachmentPreview(
        attachment: attachment,
        onRemove: () {},
      ),
    ));

    expect(find.byType(UiNetworkImage), findsNothing);

    await tester.pumpAndSettle();

    expect(find.byType(UiNetworkImage), findsOneWidget);
  });

  test('up and down arrow semantics cross attachment blocks at text edges', () {
    final c = RichPromptController(text: 'before file');
    c.selection = TextSelection.collapsed(offset: c.text.length);
    c.insertAttachment(readyAttachment(
      id: 'file-1',
      name: '3月cursor.pdf',
      type: ChatFileType.file,
      block: fileBlock('3月cursor.pdf'),
    ));
    c.text = 'after file';

    c.selection = const TextSelection.collapsed(offset: 0);
    expect(c.moveToPreviousTextBlockFromCaretStart(), isTrue);
    expect(c.text, 'before file');
    expect(c.selection.baseOffset, 'before file'.length);

    expect(c.moveToNextTextBlockFromCaretEnd(), isTrue);
    expect(c.text, 'after file');
    expect(c.selection.baseOffset, 0);
  });

  test('snapshotDraft/restoreDraft 保留有序 blocks、附件与光标（契约 §3.0f C7）', () {
    final a = RichPromptController(text: '前段 ');
    a.selection = TextSelection.collapsed(offset: a.text.length);
    a.insertAttachment(readyAttachment(
      id: 'img-1',
      name: '海报.png',
      type: ChatFileType.image,
      block: imageBlock('海报.png'),
    ));
    a.text = '后段';
    a.selection = const TextSelection.collapsed(offset: 1);
    final snap = a.snapshotDraft();
    expect(snap.hasContent, isTrue);

    // 恢复到另一个 controller（模拟切回会话）：blocks 顺序 / 附件 / 光标一致。
    final b = RichPromptController(text: '别的会话残留');
    b.restoreDraft(snap);
    expect(b.attachments.single.id, 'img-1');
    expect(
      b.toMixedBlocks().map((blk) => blk.kind).toList(),
      [
        ImMessageBlockKind.text,
        ImMessageBlockKind.image,
        ImMessageBlockKind.text,
      ]
    );
    expect(b.text, '后段');
    expect(b.selection.baseOffset, 1);

    // restoreDraft(null) = 无草稿的新会话 → 清空。
    b.restoreDraft(null);
    expect(b.hasRichContent, isFalse);
  });
}
