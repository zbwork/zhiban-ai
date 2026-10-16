import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/rich_message_clipboard.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(RichMessageClipboard.clear);

  testWidgets('PromptInput desktop min height is 1.5x taller', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester
        .pumpWidget(_host(controller: controller, focusNode: focusNode));

    final inputCard = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    final constraints = inputCard.constraints;
    expect(constraints?.minHeight, 231);
  });

  testWidgets('PromptInput text field width can use send-button upper area',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    PromptInputOverlayMetrics? metrics;
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _host(
        controller: controller,
        focusNode: focusNode,
        overlayBuilder: (context, m) {
          metrics = m;
          return const SizedBox.shrink();
        },
      ),
    );
    await tester.pump();

    final m = metrics;
    expect(m, isNotNull);
    expect(m!.textFieldWidth, m.containerSize.width - 28);
  });

  testWidgets('PromptInput card spans host width without side padding',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester
        .pumpWidget(_host(controller: controller, focusNode: focusNode));

    final inputCardRect = tester.getRect(find.byType(AnimatedContainer).first);
    expect(inputCardRect.left, 0);
    expect(inputCardRect.width, 600);
  });

  testWidgets('PromptInput toolbar does not render a bottom divider',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester
        .pumpWidget(_host(controller: controller, focusNode: focusNode));

    final toolbarDivider = find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final constraints = widget.constraints;
      final decoration = widget.decoration;
      return constraints == null &&
          widget.margin == const EdgeInsets.only(top: 8, bottom: 10) &&
          decoration == null &&
          widget.color == const Color(0xFFEEF2F7);
    });
    expect(toolbarDivider, findsNothing);
  });

  testWidgets('PromptInput Ctrl+V invokes paste image callback once',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    var pasteCalls = 0;
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': ''};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      _host(
        controller: controller,
        focusNode: focusNode,
        onPasteImage: () async {
          pasteCalls += 1;
          return true;
        },
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(pasteCalls, 1);
  });

  testWidgets('PromptInput Ctrl+V restores rich copied mixed blocks',
      (tester) async {
    final controller = RichPromptController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    const plainText = '这是一个文件\n这是一个图片';
    RichMessageClipboard.writeFromMessage(
      ImMessage(
        messageId: 'm-copy',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '4月cursor.pdf 这是一个文件 [图片] 这是一个图片',
        blocks: [
          ImMessageBlock(
            kind: ImMessageBlockKind.file,
            name: '4月cursor.pdf',
            url: '/chat/media/file/download',
          ),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个文件'),
          ImMessageBlock(
            kind: ImMessageBlockKind.image,
            name: '截图.png',
            url: '/chat/media/img/preview',
          ),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个图片'),
        ],
      ),
      plainText: plainText,
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': plainText};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester
        .pumpWidget(_host(controller: controller, focusNode: focusNode));
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('4月cursor.pdf'), findsOneWidget);
    expect(find.text('这是一个文件'), findsOneWidget);
    expect(find.text('这是一个图片'), findsOneWidget);
    expect(find.byType(UiImagePreviewThumb), findsOneWidget);
    expect(controller.toMixedBlocks().map((b) => b.kind), [
      ImMessageBlockKind.file,
      ImMessageBlockKind.text,
      ImMessageBlockKind.image,
      ImMessageBlockKind.text,
    ]);
  });

  testWidgets('rich pasted chat media image preview uses auth URL',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'test-token',
    });
    final controller = RichPromptController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.insertAttachment(RichPromptAttachment(
      id: 'img-chat-media',
      fileName: '截图.png',
      fileType: ChatFileType.image,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: const ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/ref-1/preview',
        name: '截图.png',
      ),
    ));

    await tester.pumpWidget(
      _host(controller: controller, focusNode: focusNode),
    );
    await tester.pump();
    await tester.pump();

    final image = tester.widget<UiNetworkImage>(find.byType(UiNetworkImage));
    expect(image.imageUrl, '${AppConfig.apiUrl()}/chat/media/ref-1/preview');
    expect(image.httpHeaders, {'Authorization': 'Bearer test-token'});
  });

  testWidgets('PromptInput can send pending attachment without text',
      (tester) async {
    final controller = RichPromptController();
    final focusNode = FocusNode();
    var sendCalls = 0;
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.insertAttachment(RichPromptAttachment(
      id: 'file-1',
      fileName: 'clipboard.png',
      fileType: ChatFileType.file,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: const ImMessageBlock(
        kind: ImMessageBlockKind.file,
        url: 'local://clipboard.png',
        name: 'clipboard.png',
      ),
    ));

    await tester.pumpWidget(
      _host(
        controller: controller,
        focusNode: focusNode,
        allowAttachmentOnlySend: true,
        onSend: (_) => sendCalls += 1,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(CupertinoIcons.paperplane_fill).first);
    await tester.pump();

    expect(sendCalls, 1);
  });

  testWidgets('rich media preview stays below toolbar and inside input card',
      (tester) async {
    final controller = RichPromptController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.insertAttachment(RichPromptAttachment(
      id: 'img-1',
      fileName: 'clipboard.png',
      fileType: ChatFileType.image,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/img/preview',
        name: 'clipboard.png',
      ),
    ));

    await tester.pumpWidget(
      _host(controller: controller, focusNode: focusNode),
    );
    await tester.pump();

    final cardTop = tester.getTopLeft(find.byType(AnimatedContainer).first).dy;
    final thumbTop = tester.getTopLeft(find.byType(UiImagePreviewThumb)).dy;

    // Card padding top(8) + toolbar height(32) + gap(8) = 48.
    // Rich draft cards must not rise into the toolbar row.
    expect(thumbTop, greaterThanOrEqualTo(cardTop + 48));
  });

  testWidgets('rich draft attachments stay before the active text editor',
      (tester) async {
    final controller = RichPromptController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.insertAttachment(RichPromptAttachment(
      id: 'img-1',
      fileName: 'clipboard.png',
      fileType: ChatFileType.image,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/img/preview',
        name: 'clipboard.png',
      ),
    ));
    controller.insertAttachment(RichPromptAttachment(
      id: 'img-2',
      fileName: 'second.png',
      fileType: ChatFileType.image,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/img2/preview',
        name: 'second.png',
      ),
    ));
    controller.insertAttachment(RichPromptAttachment(
      id: 'file-1',
      fileName: '计划表.xlsx',
      fileType: ChatFileType.file,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.file,
        url: '/chat/media/file/download',
        name: '计划表.xlsx',
      ),
    ));
    controller.text = '图片和文件后面的说明文字';

    await tester.pumpWidget(
      _host(controller: controller, focusNode: focusNode),
    );
    await tester.pump();

    final card = tester.getRect(find.byType(AnimatedContainer).first);
    final firstAttachment = tester.getRect(
      find.byKey(const ValueKey('rich-attachment-img-1')),
    );
    final secondAttachment = tester.getRect(
      find.byKey(const ValueKey('rich-attachment-img-2')),
    );
    final fileAttachment = tester.getRect(
      find.byKey(const ValueKey('rich-attachment-file-1')),
    );
    final textField = tester.getRect(find.byType(TextField));

    expect(firstAttachment.left, greaterThanOrEqualTo(card.left));
    expect(secondAttachment.right, lessThanOrEqualTo(card.right));
    expect(fileAttachment.right, lessThanOrEqualTo(card.right));
    expect(fileAttachment.width, lessThanOrEqualTo(240));
    expect(fileAttachment.height, lessThanOrEqualTo(54));
    expect(
      textField.top,
      greaterThan(fileAttachment.bottom - 0.5),
      reason: 'active TextField must be laid out after rich attachment blocks',
    );
    expect(find.text('图片和文件后面的说明文字'), findsOneWidget);
  });

  testWidgets('tapping previous rich text keeps caret after attachments',
      (tester) async {
    final controller = RichPromptController(text: '开头文字');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    controller.insertAttachment(RichPromptAttachment(
      id: 'img-1',
      fileName: 'clipboard.png',
      fileType: ChatFileType.image,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.image,
        url: '/chat/media/img/preview',
        name: 'clipboard.png',
      ),
    ));
    controller.text = '图片后文字';
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    controller.insertAttachment(RichPromptAttachment(
      id: 'file-1',
      fileName: '计划表.xlsx',
      fileType: ChatFileType.file,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.file,
        url: '/chat/media/file/download',
        name: '计划表.xlsx',
      ),
    ));
    controller.text = '';

    await tester.pumpWidget(
      _host(controller: controller, focusNode: focusNode),
    );
    await tester.pump();

    final trailingIndex = controller.activeTextBlockIndex;
    await tester.tap(find.text('图片后文字'));
    await tester.pump(const Duration(milliseconds: 60));

    final fileAttachment = tester.getRect(
      find.byKey(const ValueKey('rich-attachment-file-1')),
    );
    final textField = tester.getRect(find.byType(TextField));

    expect(controller.activeTextBlockIndex, trailingIndex);
    expect(controller.text, '');
    expect(
      textField.top,
      greaterThan(fileAttachment.bottom - 0.5),
      reason:
          'tapping old text must not move the active editor above later files',
    );
  });

  testWidgets('active text above attachment uses compact vertical spacing',
      (tester) async {
    final controller = RichPromptController(text: '文件上方文字');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    controller.insertAttachment(RichPromptAttachment(
      id: 'file-1',
      fileName: '3月cursor.pdf',
      fileType: ChatFileType.file,
      status: RichAttachmentStatus.ready,
      progress: 100,
      block: ImMessageBlock(
        kind: ImMessageBlockKind.file,
        url: '/chat/media/file/download',
        name: '3月cursor.pdf',
      ),
    ));
    controller.text = '文件下方文字';
    controller.selection = const TextSelection.collapsed(offset: 0);
    expect(controller.moveToPreviousTextBlockFromCaretStart(), isTrue);

    await tester.pumpWidget(
      _host(controller: controller, focusNode: focusNode),
    );
    await tester.pump();

    final textField = tester.getRect(find.byType(TextField));
    final fileAttachment = tester.getRect(
      find.byKey(const ValueKey('rich-attachment-file-1')),
    );

    expect(fileAttachment.top, greaterThan(textField.bottom));
    expect(
      fileAttachment.top - textField.bottom,
      lessThanOrEqualTo(14),
      reason:
          'middle text blocks must not keep the trailing editor send-button gap',
    );
  });
}

Widget _host({
  required TextEditingController controller,
  required FocusNode focusNode,
  PromptInputOverlayBuilder? overlayBuilder,
  Future<bool> Function()? onPasteImage,
  bool allowAttachmentOnlySend = false,
  ValueChanged<List<String>>? onSend,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: PromptInput(
            focusNode: focusNode,
            controller: controller,
            onPickAttachment: (_) {},
            onPickFromDrive: () {},
            onSend: onSend ?? (_) {},
            onStop: () {},
            isSending: false,
            showSkillChips: false,
            showSkillButton: false,
            overlayBuilder: overlayBuilder,
            onPasteImage: onPasteImage,
            allowAttachmentOnlySend: allowAttachmentOnlySend,
          ),
        ),
      ),
    ),
  );
}
