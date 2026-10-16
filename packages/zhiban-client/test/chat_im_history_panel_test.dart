import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 聊天历史抽屉组件(P2):tab 切换 / 搜索 / 空态 / 加载更多。

ImMessage _m(
  String id,
  int seq, {
  String text = '',
  ImMediaKind mediaKind = ImMediaKind.none,
  String mediaName = '',
  String mediaUrl = '',
  int mediaSize = 0,
  String mediaMime = '',
  String fromUid = 'me',
  int? timestamp,
}) =>
    ImMessage(
      messageId: id,
      clientMsgNo: '',
      fromUid: fromUid,
      channelId: 'c',
      channelType: 2,
      timestamp: timestamp ?? 1700000000 + seq,
      text: text,
      messageSeq: seq,
      mediaKind: mediaKind,
      mediaName: mediaName,
      mediaUrl: mediaUrl,
      mediaSize: mediaSize,
      mediaMime: mediaMime,
    );

void main() {
  final now = DateTime(2026, 6, 4, 20, 0);
  final msgs = <ImMessage>[
    _m('m1', 1, text: '早上好', fromUid: 'peer'),
    _m('m2', 2,
        mediaKind: ImMediaKind.image, mediaName: 'photo.png', mediaSize: 2048),
    _m('m3', 3,
        mediaKind: ImMediaKind.file,
        mediaName: 'report.pdf',
        mediaSize: 55 * 1024),
    _m('m4', 4, text: '晚安啦', fromUid: 'peer'),
  ];

  Widget host({
    List<ImMessage>? messages,
    bool hasMore = false,
    bool loadingMore = false,
    Future<void> Function()? onLoadMore,
    VoidCallback? onClose,
    void Function(ImMessage msg)? onSelectMessage,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 900,
            child: ChatImHistoryPanel(
              messages: messages ?? msgs,
              selfUid: 'me',
              resolveSenderName: (_) => '对方',
              hasMore: hasMore,
              loadingMore: loadingMore,
              onLoadMore: onLoadMore,
              onClose: onClose ?? () {},
              onSelectMessage: onSelectMessage,
              now: now,
            ),
          ),
        ),
      );

  testWidgets('全部 tab → 展示全部摘要 + 发送人(我 / 对方)', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('搜索聊天记录'), findsOneWidget);
    expect(find.text('发送人'), findsOneWidget);
    expect(find.text('日期'), findsOneWidget);
    expect(find.text('晚安啦'), findsOneWidget);
    // 图片消息在「全部」里展示大图预览,不额外露出文件名。
    expect(find.text('photo.png'), findsNothing);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('55K'), findsOneWidget);
    expect(find.text('对方'), findsWidgets); // 对端消息
    expect(find.text('我'), findsWidgets); // 自己消息

    final text = tester.widget<Text>(find.text('晚安啦'));
    expect(text.style?.fontWeight, isNull);
  });

  testWidgets('切到「文件」tab → 资源列表样式:仅文件 + 文件搜索 + 类型筛选', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('搜索文件名称'), findsOneWidget);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.textContaining('55K'), findsOneWidget);
    expect(find.text('photo.png'), findsNothing);
    expect(find.text('早上好'), findsNothing);
  });

  testWidgets('切到「图片与视频」tab → 资源列表样式:仅图片与视频', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('图片与视频'));
    await tester.pumpAndSettle();
    expect(find.text('搜索图片与视频'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.textContaining('2K'), findsOneWidget);
    expect(find.text('report.pdf'), findsNothing);
    expect(find.text('早上好'), findsNothing);
  });

  testWidgets('发送人筛选可点击并只保留该发送人的消息', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(
      find.byKey(const ValueKey('chat-history-sender-filter'))
    );
    await tester.pumpAndSettle();
    expect(find.text('我'), findsWidgets);
    expect(find.text('对方'), findsWidgets);

    await tester.tap(find.text('对方').last);
    await tester.pumpAndSettle();
    expect(find.text('早上好'), findsOneWidget);
    expect(find.text('晚安啦'), findsOneWidget);
    expect(find.text('report.pdf'), findsNothing);
  });

  testWidgets('文件类型筛选可点击并在切出文件 tab 后重置', (tester) async {
    final files = [
      _m(
        'pdf',
        1,
        mediaKind: ImMediaKind.file,
        mediaName: 'report.pdf'
      ),
      _m(
        'excel',
        2,
        mediaKind: ImMediaKind.file,
        mediaName: 'budget.xlsx'
      ),
    ];
    await tester.pumpWidget(host(messages: files));

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('chat-history-type-filter'))
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PDF'));
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('budget.xlsx'), findsNothing);

    await tester.tap(find.text('图片与视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('budget.xlsx'), findsOneWidget);
  });

  testWidgets('日期筛选可点击并按本地自然日过滤', (tester) async {
    final dated = [
      _m(
        'today',
        1,
        text: '今天消息',
        timestamp: DateTime(2026, 6, 4, 8).millisecondsSinceEpoch,
      ),
      _m(
        'yesterday',
        2,
        text: '昨天消息',
        timestamp: DateTime(2026, 6, 3, 23, 30).millisecondsSinceEpoch,
      ),
      _m(
        'older',
        3,
        text: '更早消息',
        timestamp: DateTime(2026, 5, 1, 12).millisecondsSinceEpoch,
      ),
    ];
    await tester.pumpWidget(host(messages: dated));

    await tester.tap(
      find.byKey(const ValueKey('chat-history-date-filter'))
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('昨天'));
    await tester.pumpAndSettle();

    expect(find.text('昨天消息'), findsOneWidget);
    expect(find.text('今天消息'), findsNothing);
    expect(find.text('更早消息'), findsNothing);
  });

  testWidgets('图片历史使用带鉴权的绝对 URL 加载缩略图', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'token-1',
    });
    await tester.pumpWidget(host(messages: [
      _m(
        'img',
        1,
        mediaKind: ImMediaKind.image,
        mediaName: 'photo.png',
        mediaUrl: '/chat/media/ref-1/preview',
      ),
    ]));
    await tester.tap(find.text('图片与视频'));
    await tester.pump();
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(image.imageUrl, '${AppConfig.apiUrl()}/chat/media/ref-1/preview');
    expect(image.cacheKey, image.imageUrl);
    expect(image.httpHeaders, {'Authorization': 'Bearer token-1'});
  });

  testWidgets('搜索过滤(包含匹配)', (tester) async {
    await tester.pumpWidget(host());
    await tester.enterText(find.byType(EditableText).first, '晚安');
    await tester.pumpAndSettle();
    // 搜索框回显 '晚安',结果摘要为 '晚安啦' → 结果唯一可断言。
    expect(find.text('晚安啦'), findsOneWidget);
    expect(find.text('早上好'), findsNothing);
    expect(find.text('photo.png'), findsNothing);
  });

  testWidgets('空结果 → 「暂无相关历史」', (tester) async {
    await tester.pumpWidget(host(messages: const []));
    await tester.pumpAndSettle();
    expect(find.text('暂无相关历史'), findsOneWidget);
  });

  testWidgets('hasMore → 「加载更多」可点,触发 onLoadMore', (tester) async {
    var loaded = 0;
    await tester.pumpWidget(host(
      messages: [_m('only', 1, text: '一条消息')],
      hasMore: true,
      onLoadMore: () async => loaded++,
    ));
    await tester.pumpAndSettle();
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(loaded, 1);
  });

  // ── Codex P2 修复:空结果 + hasMore 仍能「加载更多」───────────────────────────
  testWidgets('文件 tab 无命中 + hasMore → 「暂无相关历史」+「加载更多」,点击触发一次', (tester) async {
    var loaded = 0;
    // 仅文本/图片,无 file → 切「文件」tab 后结果为空。
    final noFile = <ImMessage>[
      _m('m1', 1, text: 'hi'),
      _m('m2', 2, mediaKind: ImMediaKind.image, mediaName: 'a.png'),
    ];
    await tester.pumpWidget(host(
      messages: noFile,
      hasMore: true,
      onLoadMore: () async => loaded++),
    );
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('暂无相关历史'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(loaded, 1);
  });

  testWidgets('空结果 + loadingMore → 转圈,不显示「加载更多」按钮', (tester) async {
    await tester.pumpWidget(host(
      messages: const [],
      hasMore: true,
      loadingMore: true,
      onLoadMore: () async {},
    ));
    // 不用 pumpAndSettle:CircularProgressIndicator 持续动画不会 settle。
    await tester.pump();
    expect(find.text('暂无相关历史'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  // ── Task B:点击结果回调目标消息(不再只是关闭)──────────────────────────────
  testWidgets('点击历史结果 → onSelectMessage 收到对应 ImMessage(而非仅关闭)', (tester) async {
    ImMessage? selected;
    var closed = false;
    await tester.pumpWidget(host(
      onSelectMessage: (m) => selected = m,
      onClose: () => closed = true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('晚安啦'));
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expect(selected!.messageId, 'm4');
    expect(closed, isFalse); // onSelectMessage 存在时不走 onClose;关抽屉由 pane 负责
  });

  group('ChatLocateHighlight', () {
    testWidgets('active=true → 有高亮底色;active=false → 透明', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChatLocateHighlight(active: true, child: SizedBox(height: 20)),
        ),
      ));
      await tester.pumpAndSettle();
      final box1 =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      expect(
          (box1.decoration as BoxDecoration).color, isNot(Colors.transparent));

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChatLocateHighlight(active: false, child: SizedBox(height: 20)),
        ),
      ));
      await tester.pumpAndSettle();
      final box2 =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      expect((box2.decoration as BoxDecoration).color, Colors.transparent);
    });
  });
}
