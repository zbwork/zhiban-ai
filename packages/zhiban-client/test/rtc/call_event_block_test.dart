import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_mixed_message_bubble.dart';

void main() {
  group('WkMixedContent.summaryOf call_event (FE-05)', () {
    test('call_event 纳入 summary，不变成 [非文本消息]', () {
      final s = WkMixedContent.summaryOf(const [
        ImMessageBlock(
            kind: ImMessageBlockKind.callEvent,
            text: '通话时长 01:23',
            callEndReason: 'normal'),
      ]);
      expect(s, '通话时长 01:23');
      expect(s, isNot('[非文本消息]'));
    });

    test('call_event 空 text → 兜底「语音通话」', () {
      final s = WkMixedContent.summaryOf(
          const [ImMessageBlock(kind: ImMessageBlockKind.callEvent)]);
      expect(s, '语音通话');
    });

    test('mixed encode keeps type=110 for webhook decode', () {
      final content = WkMixedContent()
        ..blocks = const [
          ImMessageBlock(
            kind: ImMessageBlockKind.callEvent,
            text: '通话时长 01:23',
            callEndReason: 'normal',
          ),
        ];
      final json = content.encodeJson();
      expect(json['type'], 110);
      expect(json['blocks'], isA<List<dynamic>>());
    });

    test('普通 text/image/file summary 不回退', () {
      expect(
          WkMixedContent.summaryOf(const [
            ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
          ]),
          'hi');
      expect(
          WkMixedContent.summaryOf(const [
            ImMessageBlock(kind: ImMessageBlockKind.image, url: 'u'),
          ]),
          '[图片]');
    });
  });

  group('ImMessageBlock.fromJson call_event (FE-05)', () {
    test('call_event block parses kind + text + end_reason', () {
      final b = ImMessageBlock.fromJson({
        'type': 'call_event',
        'text': '未接听',
        'end_reason': 'timeout',
        'media_kind': 'audio',
      });
      expect(b, isNotNull);
      expect(b!.isCallEvent, isTrue);
      expect(b.text, '未接听');
      expect(b.callEndReason, 'timeout');
    });

    test('normal text/image/file blocks unaffected (no callEvent fallback)',
        () {
      expect(ImMessageBlock.fromJson({'type': 'text', 'text': 'hi'})!.isText,
          isTrue);
      expect(ImMessageBlock.fromJson({'type': 'image', 'url': 'u'})!.isImage,
          isTrue);
      expect(ImMessageBlock.fromJson({'type': 'file', 'url': 'u'})!.isFile,
          isTrue);
      // 未知 type（含误入的 1001 控制信令）→ null，不渲染成块。
      expect(ImMessageBlock.fromJson({'type': 'rtc_call_signal'}), isNull);
      expect(ImMessageBlock.fromJson({'type': '1001'}), isNull);
    });

    test('round-trip toJson keeps call_event + end_reason', () {
      final b = ImMessageBlock(
          kind: ImMessageBlockKind.callEvent,
          text: '通话时长 01:23',
          callEndReason: 'normal');
      final j = b.toJson();
      expect(j['type'], 'call_event');
      expect(j['end_reason'], 'normal');
      final back = ImMessageBlock.fromJson(j)!;
      expect(back.isCallEvent, isTrue);
      expect(back.callEndReason, 'normal');
    });
  });

  testWidgets('ChatMixedMessageBubble renders call_event block',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatMixedMessageBubble(
          backgroundColor: const Color(0xFFFFFFFF),
          blocks: const [
            ImMessageBlock(
              kind: ImMessageBlockKind.callEvent,
              text: '未接听',
              callEndReason: 'timeout',
            ),
          ],
        ),
      ),
    ));
    expect(find.text('未接听'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone_fill), findsOneWidget);
    // 普通占位不出现。
    expect(find.text('[非文本消息]'), findsNothing);
  });

  testWidgets('single call_event is a standalone pill without mixed bubble',
      (tester) async {
    const selfBubbleColor = Color(0xFFDBEAFE);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatMixedMessageBubble(
          backgroundColor: selfBubbleColor,
          blocks: const [
            ImMessageBlock(
              kind: ImMessageBlockKind.callEvent,
              text: '通话时长 02:51',
              callEndReason: 'normal',
            ),
          ],
        ),
      ),
    ));

    expect(find.text('通话时长 02:51'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone_fill), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! Container) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.color == selfBubbleColor;
      }),
      findsNothing,
    );
  });

  test('summary-only old call event message is rendered as call card', () {
    final msg = ImMessage(
      messageId: 'm1',
      clientMsgNo: 'c1',
      fromUid: 'u1',
      channelId: 'ch',
      channelType: 1,
      timestamp: 1,
      text: '语音通话 · 通话时长 15:09',
    );

    expect(isCallEventLikeMessage(msg), isTrue);
    expect(callEventMessageLabel(msg), '通话时长 15:09');
  });

  testWidgets('普通 text block 仍渲染，不被通话卡片影响', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatMixedMessageBubble(
          backgroundColor: const Color(0xFFFFFFFF),
          blocks: const [
            ImMessageBlock(kind: ImMessageBlockKind.text, text: '你好'),
          ],
        ),
      ),
    ));
    expect(find.text('你好'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone_fill), findsNothing);
  });
}
