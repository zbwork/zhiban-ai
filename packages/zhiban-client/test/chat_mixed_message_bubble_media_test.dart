import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_mixed_message_bubble.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

// CR-2026-06 P2 媒体消息体验: ChatMixedMessageBubble 必须把 image / file block 的点击
// 路由到 pane 的 onPreviewImage / onOpenVideo, 不再卡在 HumanDirectMediaImage 原 fallback。
// 见 docs/contracts/agent-bus-client-contract.md §「媒体消息体验 (P2 2026-06)」。
//
// 图片路径直接读取 HumanDirectMediaImage tap,避免网络图片加载影响测试。
// 视频路径必须用 tester.tap(HumanDirectFileCard) 覆盖真实点击,避免只手动调用回调漏掉手势竞争。

ImMessage _mixedParent(List<ImMessageBlock> blocks) => ImMessage(
      messageId: 'M-mixed',
      clientMsgNo: 'cmn-mixed',
      fromUid: 'me',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: '',
      blocks: blocks,
    );

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Future<void> _tapFileCard(WidgetTester tester) async {
  await tester.tap(find.byType(HumanDirectFileCard));
  // HumanDirectFileCard supports both tap and double-tap, so Flutter waits for
  // the double-tap timeout before firing the single-tap callback.
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  group('ChatMixedMessageBubble — CR-2026-06 image/video tap 接线', () {
    testWidgets('mixed text block uses selectable text on desktop',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '可以拖动选取'),
        ],
        backgroundColor: Colors.white,
      )));

      expect(find.text('可以拖动选取'), findsOneWidget);
      expect(find.byType(ChatSelectableSurface), findsOneWidget);
    });

    testWidgets('markdown-only Agent final keeps reply mention in mixed bubble',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: const [
          ImMessageBlock(
            kind: ImMessageBlockKind.markdown,
            text: '在听，刚刚没掉线。',
          ),
        ],
        backgroundColor: Colors.white,
        mentionNames: const {'李强'},
        replyMentionPrefix: '@李强',
      )));

      expect(find.text('@李强'), findsOneWidget);
      expect(find.textContaining('在听，刚刚没掉线'), findsOneWidget);
    });

    testWidgets(
        'mixed image block → HumanDirectMediaImage tap 调外部 onPreviewImage(parent)',
        (tester) async {
      ImMessage? captured;
      Object? capturedTag;
      String? capturedUrl;
      final parent = _mixedParent(const [
        ImMessageBlock(
            kind: ImMessageBlockKind.image, url: '/chat/media/x/preview'),
      ]);
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: parent.blocks,
        backgroundColor: Colors.white,
        parentMessage: parent,
        onPreviewImage: (m, {Object? heroTag, String? imageUrl}) {
          captured = m;
          capturedTag = heroTag;
          capturedUrl = imageUrl;
        },
      )));
      // image widget 第一帧就在 widget tree 里 (FutureBuilder 顶层就是 HumanDirectMediaImage)。
      final imageWidget = tester.widget<HumanDirectMediaImage>(
        find.byType(HumanDirectMediaImage),
      );
      expect(imageWidget.onPreviewWithHero, isNotNull,
          reason: 'bubble 必须给 image block 传 onTap');
      // 直接触发, 验证 wiring 正确路由到外部回调。
      await tester.tap(find.byType(HumanDirectMediaImage));
      expect(captured, isNotNull);
      expect(captured!.messageId, 'M-mixed');
      expect(capturedTag, isNotNull);
      expect(capturedUrl, '/chat/media/x/preview');
    });

    testWidgets('mixed 单 file 视频 (mime=video/mp4) → 真实 tap 调 onOpenVideo',
        (tester) async {
      ImMessage? captured;
      final parent = _mixedParent(const [
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          name: 'clip.mp4',
          mime: 'video/mp4',
          url: '/chat/media/v/download',
        ),
      ]);
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: parent.blocks,
        backgroundColor: Colors.white,
        parentMessage: parent,
        onOpenVideo: (m, _) => captured = m,
      )));
      await _tapFileCard(tester);
      expect(captured?.messageId, 'M-mixed');
    });

    testWidgets('mixed 单 file 视频 (按扩展 .mp4, 无 mime) → 真实 tap 触发 onOpenVideo',
        (tester) async {
      ImMessage? captured;
      final parent = _mixedParent(const [
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          name: 'clip.mp4',
          url: '/chat/media/v/download',
        ),
      ]);
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: parent.blocks,
        backgroundColor: Colors.white,
        parentMessage: parent,
        onOpenVideo: (m, _) => captured = m,
      )));
      await _tapFileCard(tester);
      expect(captured?.messageId, 'M-mixed');
    });

    testWidgets('mixed 文本 + mime-only 视频 → 用被点击的 block url 打开并显示视频角标',
        (tester) async {
      ImMessage? capturedParent;
      ImMessageBlock? capturedBlock;
      final parent = _mixedParent(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: '请看视频'),
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          name: 'recording',
          mime: 'video/mp4',
          url: '/chat/media/video-block/download',
        ),
      ]);
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: parent.blocks,
        backgroundColor: Colors.white,
        parentMessage: parent,
        onOpenVideo: (m, b) {
          capturedParent = m;
          capturedBlock = b;
        },
      )));
      expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);

      await _tapFileCard(tester);

      expect(capturedParent?.messageId, 'M-mixed');
      expect(capturedBlock?.url, '/chat/media/video-block/download');
      expect(capturedBlock?.name, 'recording');
    });

    testWidgets('mixed 普通 pdf → bubble 不传 onOpen, 普通文件走 FileCard 原下载',
        (tester) async {
      var videoCalled = 0;
      final parent = _mixedParent(const [
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          name: 'report.pdf',
          mime: 'application/pdf',
          url: '/chat/media/r/download',
        ),
      ]);
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: parent.blocks,
        backgroundColor: Colors.white,
        parentMessage: parent,
        onOpenVideo: (_, __) => videoCalled++,
      )));
      final fileCardFinder = find.byType(HumanDirectFileCard);
      expect(fileCardFinder, findsOneWidget);
      final card = tester.widget<HumanDirectFileCard>(fileCardFinder);
      expect(card.onOpen, isNull, reason: '普通 pdf 不应覆盖默认下载行为');
      expect(videoCalled, 0);
    });

    testWidgets(
        'parentMessage=null → bubble 给 image block 的 onTap 是 null (回退原 fallback)',
        (tester) async {
      var previewCalled = 0;
      await tester.pumpWidget(_wrap(ChatMixedMessageBubble(
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.image, url: '/i/1'),
        ],
        backgroundColor: Colors.white,
        onPreviewImage: (_, {Object? heroTag, String? imageUrl}) =>
            previewCalled++,
      )));
      final imageWidget = tester.widget<HumanDirectMediaImage>(
        find.byType(HumanDirectMediaImage),
      );
      expect(imageWidget.onPreviewWithHero, isNull,
          reason: 'parentMessage=null 时 bubble 不应给 image 传 onTap, 回退 fallback');
      expect(previewCalled, 0);
    });
  });
}
