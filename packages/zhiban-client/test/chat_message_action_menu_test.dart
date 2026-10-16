import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/services/rich_message_clipboard.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_action_menu.dart';

// 消息操作菜单(P2 + F09 P1 撤回):可用项纯函数 + 飞书风 overlay 菜单 + 复制写剪贴板 +
// 撤回入口 + tombstone 后无操作。

ImMessage _m({
  String messageId = 'm1',
  String clientMsgNo = '',
  String fromUid = 'me',
  String text = 'hello',
  ImSendStatus status = ImSendStatus.sent,
  ImMediaKind mediaKind = ImMediaKind.none,
  String mediaName = '',
  String mediaLocalPath = '',
  int uploadProgress = -1,
  bool isRevoked = false,
  String mediaUrl = '',
  String mediaFileUuid = '',
}) =>
    ImMessage(
      messageId: messageId,
      clientMsgNo: clientMsgNo,
      fromUid: fromUid,
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: text,
      sendStatus: status,
      mediaKind: mediaKind,
      mediaName: mediaName,
      mediaUrl: mediaUrl,
      mediaFileUuid: mediaFileUuid,
      mediaLocalPath: mediaLocalPath,
      uploadProgress: uploadProgress,
      isRevoked: isRevoked,
    );

ImMessage _mixed({
  required List<ImMessageBlock> blocks,
  String text = '',
  String mediaName = '',
  String fromUid = 'me',
  ImSendStatus status = ImSendStatus.sent,
}) =>
    ImMessage(
      messageId: 'mixed-1',
      clientMsgNo: '',
      fromUid: fromUid,
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: text,
      sendStatus: status,
      mediaName: mediaName,
      blocks: blocks,
    );

void main() {
  setUp(RichMessageClipboard.clear);

  group('availableMessageActions', () {
    test('对端文本 → 复制 + 引用 + 转发 + 多选 (无撤回 / 重发 / 删除)', () {
      // F09 v2: 引用 / 转发 / 多选 双向可见
      expect(
        availableMessageActions(msg: _m(fromUid: 'peer'), isMine: false),
        [
          ChatMessageAction.copy,
          ChatMessageAction.reply,
          ChatMessageAction.forward,
          ChatMessageAction.multiSelect,
        ]
      );
    });

    test('自己已发送文本 → 复制 + 引用 + 转发 + 多选 + 撤回 + 删除', () {
      expect(
        availableMessageActions(msg: _m(), isMine: true),
        [
          ChatMessageAction.copy,
          ChatMessageAction.reply,
          ChatMessageAction.forward,
          ChatMessageAction.multiSelect,
          ChatMessageAction.revoke,
          ChatMessageAction.delete,
        ]
      );
    });

    test('自己 failed 文本 → 复制 + 重发 + 删除(无引用 / 转发 / 多选 / 撤回:未到达服务端)', () {
      // F09 v2: failed 不允许引用 / 转发 / 多选 (无稳定锚点 / 不可重复用)
      expect(
        availableMessageActions(
            msg: _m(status: ImSendStatus.failed), isMine: true),
        [
          ChatMessageAction.copy,
          ChatMessageAction.resend,
          ChatMessageAction.delete,
        ],
      );
    });

    test('自己 pending(发送中)→ 仅复制(不重发、不撤回、不删除)', () {
      expect(
        availableMessageActions(
            msg: _m(status: ImSendStatus.pending), isMine: true),
        [ChatMessageAction.copy],
      );
    });

    test('自己 uploading 媒体 → 仅取消上传(不撤回)', () {
      final up = _m(
        text: '',
        status: ImSendStatus.pending,
        mediaKind: ImMediaKind.image,
        mediaName: 'a.png',
        mediaLocalPath: '/p/a.png',
        uploadProgress: 20,
      );
      expect(up.isUploading, isTrue);
      expect(
        availableMessageActions(msg: up, isMine: true),
        [ChatMessageAction.cancelUpload]
      );
    });

    test('媒体无 fileUuid → 复制 + 引用 + 多选 (对端; 无转发 fail-closed)', () {
      final media = _m(
          fromUid: 'peer',
          text: '',
          mediaKind: ImMediaKind.file,
          mediaName: 'report.pdf');
      expect(
        availableMessageActions(msg: media, isMine: false),
        [
          ChatMessageAction.copy,
          ChatMessageAction.reply,
          ChatMessageAction.multiSelect,
        ]
      );
    });

    test('无文本无媒体名 → 引用 + 多选 (无复制 / 转发; 因为没有可转发的文本)', () {
      // F09 v2: 没有可复制内容时仍可引用 / 多选 (锚点是 messageId/clientMsgNo, 不依赖文本)
      // 但没有文本无法转发 (canForwardMessage=false)
      final blank = _m(fromUid: 'peer', text: '', mediaName: '');
      expect(
        availableMessageActions(msg: blank, isMine: false),
        [
          ChatMessageAction.reply,
          ChatMessageAction.multiSelect,
        ]
      );
    });

    test('F09 P1: 已撤回 → 空, 不弹菜单', () {
      // 撤回后内容已清空, isRevoked=true
      final revoked = _m(text: '', isRevoked: true);
      expect(availableMessageActions(msg: revoked, isMine: true), isEmpty);
      expect(availableMessageActions(msg: revoked, isMine: false), isEmpty);
    });

    test(
        'F09 C: 自己 sent 媒体(file) → 复制 + 引用 + 多选 + 撤回 + 保存文件 + 删除 (无转发: media fail-closed)',
        () {
      final media = _m(
        text: '',
        mediaKind: ImMediaKind.file,
        mediaName: 'doc.pdf',
        // 注意: _m 不接受 mediaUrl, 在这里需要构造一个媒体 + url; 修扩 helper.
      );
      // 测试 helper 不暴露 mediaUrl, 通过直接构造:
      final withUrl = ImMessage(
        messageId: media.messageId,
        clientMsgNo: media.clientMsgNo,
        fromUid: media.fromUid,
        channelId: media.channelId,
        channelType: media.channelType,
        timestamp: media.timestamp,
        text: media.text,
        mediaKind: ImMediaKind.file,
        mediaName: 'doc.pdf',
        mediaUrl: '/chat/media/ref-1/download',
      );
      final acts = availableMessageActions(msg: withUrl, isMine: true);
      expect(acts, contains(ChatMessageAction.saveFile));
      expect(acts, contains(ChatMessageAction.copy));
      expect(acts, contains(ChatMessageAction.reply));
      expect(acts, contains(ChatMessageAction.multiSelect));
      // 媒体本轮不允许转发 (fail-closed; 见 docs/contracts §「消息操作菜单 v2」)
      expect(acts, isNot(contains(ChatMessageAction.forward)));
      expect(acts, contains(ChatMessageAction.revoke));
      expect(acts, contains(ChatMessageAction.delete));
    });

    test('F09 C: 对端 sent 媒体(带 fileUuid) → 可保存也可富转发', () {
      final media = ImMessage(
        messageId: 'mm',
        clientMsgNo: '',
        fromUid: 'peer',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '',
        mediaKind: ImMediaKind.image,
        mediaName: 'p.jpg',
        mediaUrl: '/chat/media/ref/preview',
        mediaFileUuid: 'drive-img',
      );
      final acts = availableMessageActions(msg: media, isMine: false);
      expect(acts, contains(ChatMessageAction.forward));
      expect(acts, contains(ChatMessageAction.saveFile));
      expect(acts, isNot(contains(ChatMessageAction.revoke)));
      expect(acts, isNot(contains(ChatMessageAction.delete)));
    });

    test('F09 C: pending 媒体不显示保存文件 (还没投递成功)', () {
      final media = ImMessage(
        messageId: 'mm',
        clientMsgNo: 'cmn',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '',
        sendStatus: ImSendStatus.pending,
        mediaKind: ImMediaKind.image,
        mediaName: 'p.jpg',
        mediaUrl: '/chat/media/ref/preview',
      );
      final acts = availableMessageActions(msg: media, isMine: true);
      expect(acts, isNot(contains(ChatMessageAction.saveFile)));
    });

    test(
        'F09 P1+v2: 自己 sent 媒体 (无 URL) → 复制 + 引用 + 多选 + 撤回 + 删除 (转发 fail-closed)',
        () {
      // 媒体消息 (image/file): 引用 ✓ / 多选 ✓ / 转发 ✗ (本轮 fail-closed)
      final media = _m(
        text: '',
        mediaKind: ImMediaKind.file,
        mediaName: 'doc.pdf',
      );
      expect(
        availableMessageActions(msg: media, isMine: true),
        [
          ChatMessageAction.copy,
          ChatMessageAction.reply,
          ChatMessageAction.multiSelect,
          ChatMessageAction.revoke,
          ChatMessageAction.delete,
        ]
      );
    });

    test('F09 转发: 文本可纯转发 / 媒体需 fileUuid 才可富转发 / 撤回和 pending 不可转发', () {
      expect(canForwardMessage(_m()), isTrue);
      final mediaWithoutFileUuid = _m(
        text: '',
        mediaKind: ImMediaKind.image,
        mediaName: 'a.png',
      );
      final mediaWithFileUuid = _m(
        text: '',
        mediaKind: ImMediaKind.image,
        mediaName: 'a.png',
        mediaUrl: '/chat/media/ref/preview',
        mediaFileUuid: 'drive-img',
      );
      expect(canForwardMessage(mediaWithoutFileUuid), isFalse);
      expect(canForwardRichMessage(mediaWithoutFileUuid), isFalse);
      expect(canForwardMessage(mediaWithFileUuid), isFalse);
      expect(canForwardRichMessage(mediaWithFileUuid), isTrue);
      expect(
        canForwardMessage(_m(isRevoked: true, text: '')),
        isFalse
      );
      expect(
        canForwardMessage(_m(status: ImSendStatus.pending)),
        isFalse
      );
    });

    // F09 转发 v1 严格 fail-closed 边界 (Codex review CR-A1): mixed blocks
    // 必须全部是 text/markdown 才可转发, 否则菜单**直接隐藏**, 不能让用户点完才发现没东西可发。

    ImMessage mixedMsg(List<ImMessageBlock> blocks) => ImMessage(
          messageId: 'mm',
          clientMsgNo: 'c',
          fromUid: 'me',
          channelId: 'c',
          channelType: 2,
          timestamp: 1700000000,
          text: '',
          blocks: blocks,
        );

    test('mixed: 全是 text + markdown 且非空 → 可转发, 文本按顺序换行拼接', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hello'),
        ImMessageBlock(kind: ImMessageBlockKind.markdown, text: '**world**'),
      ]);
      expect(canForwardMessage(m), isTrue);
      expect(chatForwardTextOf(m), 'hello\n**world**');
    });

    test('mixed: 含 callEvent block → 不可转发 (F16 通话卡片不是普通用户消息)', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
        ImMessageBlock(
            kind: ImMessageBlockKind.callEvent, callEndReason: 'normal'),
      ]);
      expect(canForwardMessage(m), isFalse);
      expect(
        availableMessageActions(msg: m, isMine: true),
        isNot(contains(ChatMessageAction.forward)),
      );
    });

    test('mixed: 含 skill block → 不可转发 (技能事件不是普通用户消息)', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
        ImMessageBlock(kind: ImMessageBlockKind.skill, skillSlug: 'image'),
      ]);
      expect(canForwardMessage(m), isFalse);
      expect(
        availableMessageActions(msg: m, isMine: true),
        isNot(contains(ChatMessageAction.forward)),
      );
    });

    test('mixed: text + image 无 fileUuid → 纯文本转发不可, 富转发仅保留文本可用', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
        ImMessageBlock(kind: ImMessageBlockKind.image, url: '/u'),
      ]);
      expect(canForwardMessage(m), isFalse);
      expect(canForwardRichMessage(m), isTrue);
    });

    test('mixed: text + image 带 fileUuid → 可富转发', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
        ImMessageBlock(
          kind: ImMessageBlockKind.image,
          url: '/u',
          fileUuid: 'drive-img',
        ),
      ]);
      expect(canForwardMessage(m), isFalse);
      expect(canForwardRichMessage(m), isTrue);
      expect(
        availableMessageActions(msg: m, isMine: false),
        contains(ChatMessageAction.forward),
      );
    });

    test('P2 (2026-06): 视频 file 消息 → 不可转发 (媒体 fail-closed; 视频按扩展识别)', () {
      // file wire + mp4 扩展 → 视频 → 转发隐藏
      final video = ImMessage(
        messageId: 'v',
        clientMsgNo: 'cv',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '',
        mediaKind: ImMediaKind.file,
        mediaName: 'clip.mp4',
        mediaUrl: '/chat/media/v/download',
      );
      expect(canForwardMessage(video), isFalse);
      expect(
        availableMessageActions(msg: video, isMine: true),
        isNot(contains(ChatMessageAction.forward)),
      );
    });

    test('mixed: blocks 都是 text/markdown 但抽出后全空 → 不可转发 (避免转空消息)', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: '   '),
        ImMessageBlock(kind: ImMessageBlockKind.markdown, text: ''),
      ]);
      expect(canForwardMessage(m), isFalse);
      expect(
        availableMessageActions(msg: m, isMine: true),
        isNot(contains(ChatMessageAction.forward)),
      );
    });

    test('mixed: 仅 callEvent 块 → 不可引用 / 不可多选 (非普通用户消息)', () {
      final m = mixedMsg(const [
        ImMessageBlock(
            kind: ImMessageBlockKind.callEvent, callEndReason: 'normal'),
      ]);
      expect(canReplyMessage(m), isFalse);
      expect(canSelectMessage(m), isFalse);
      expect(canForwardMessage(m), isFalse);
      // 菜单全空对端 / 全空自己: 仅 callEvent 块没有可复制文本, 不出菜单。
      final actsPeer = availableMessageActions(msg: m, isMine: false);
      expect(actsPeer, isNot(contains(ChatMessageAction.reply)));
      expect(actsPeer, isNot(contains(ChatMessageAction.forward)));
      expect(actsPeer, isNot(contains(ChatMessageAction.multiSelect)));
    });

    test('mixed: 仅 skill 块 → 不可引用 / 不可多选 / 不可转发', () {
      final m = mixedMsg(const [
        ImMessageBlock(kind: ImMessageBlockKind.skill, skillSlug: 's'),
      ]);
      expect(canReplyMessage(m), isFalse);
      expect(canSelectMessage(m), isFalse);
      expect(canForwardMessage(m), isFalse);
    });

    test('revoke notify (运行时字段) → 不可引用 / 不可转发 / 不可多选', () {
      final notify = ImMessage(
        messageId: 'r',
        clientMsgNo: 'c',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '',
        isRevokeNotify: true,
        revokedMessageId: 'orig',
      );
      expect(canReplyMessage(notify), isFalse);
      expect(canForwardMessage(notify), isFalse);
      expect(canSelectMessage(notify), isFalse);
    });

    test('F09 引用 v1: 撤回不可引用 / pending 不可引用 / sent 可引用', () {
      expect(canReplyMessage(_m()), isTrue);
      expect(canReplyMessage(_m(isRevoked: true, text: '')), isFalse);
      expect(canReplyMessage(_m(status: ImSendStatus.pending)), isFalse);
      expect(canReplyMessage(_m(status: ImSendStatus.failed)), isFalse);
    });

    test('F09 多选 v1: 撤回 / pending / failed / uploading 不可勾选', () {
      expect(canSelectMessage(_m()), isTrue);
      expect(canSelectMessage(_m(isRevoked: true, text: '')), isFalse);
      expect(canSelectMessage(_m(status: ImSendStatus.pending)), isFalse);
      expect(canSelectMessage(_m(status: ImSendStatus.failed)), isFalse);
    });
  });

  group('chatForwardTextOf', () {
    test('纯文本消息 → 返回 text trim', () {
      expect(chatForwardTextOf(_m(text: '  hi\n')), 'hi');
    });
    test('撤回 (canForward=false) 此处仍按文本规则返回 text', () {
      // 仅纯函数行为, 调用方应先 canForwardMessage 守卫
      expect(chatForwardTextOf(_m(text: 'x')), 'x');
    });
  });

  group('copyTextFor', () {
    test('文本优先', () {
      expect(copyTextFor(_m(text: 'hi', mediaName: 'a.png')), 'hi');
    });
    test('文本空 → 回退 mediaName', () {
      expect(copyTextFor(_m(text: '', mediaName: 'a.png')), 'a.png');
    });
    test('mixed 只复制 text/markdown 正文, 不复制 summary 里的媒体占位', () {
      final msg = _mixed(
        text: '4月cursor.pdf 这是一个文件 [图片] 这是一个图片',
        blocks: const [
          ImMessageBlock(
            kind: ImMessageBlockKind.file,
            name: '4月cursor.pdf'
          ),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个文件'),
          ImMessageBlock(kind: ImMessageBlockKind.image, name: '截图.png'),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个图片'),
        ],
      );
      expect(copyTextFor(msg), '这是一个文件\n这是一个图片');
    });
    test('mixed 无正文时回退首个媒体名', () {
      final msg = _mixed(
        text: '[图片] doc.pdf',
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.image),
          ImMessageBlock(kind: ImMessageBlockKind.file, name: 'doc.pdf'),
        ],
      );
      expect(copyTextFor(msg), 'doc.pdf');
    });
  });

  group('ChatMessageActionRegion widget', () {
    Widget host(ImMessage msg, bool isMine, {VoidCallback? onRevoke}) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ChatMessageActionRegion(
                msg: msg,
                isMine: isMine,
                onResend: () {},
                onDelete: () {},
                onCancelUpload: () {},
                onRevoke: onRevoke,
                child: Container(
                    width: 120, height: 40, color: const Color(0xFF2563EB)),
              ),
            ),
          ),
        );

    testWidgets('对端消息右键 → 仅「复制」, 无撤回入口', (tester) async {
      await tester.pumpWidget(host(_m(fromUid: 'peer'), false));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('撤回'), findsNothing);
      expect(find.text('重发'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('自己 sent 右键 → 复制 / 撤回 / 删除', (tester) async {
      await tester.pumpWidget(host(_m(), true, onRevoke: () {}));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('重发'), findsNothing);
    });

    testWidgets('自己 failed 右键 → 复制 / 重发 / 删除(无撤回)', (tester) async {
      await tester.pumpWidget(host(_m(status: ImSendStatus.failed), true));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('重发'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('撤回'), findsNothing);
    });

    testWidgets('F09 P1: 已撤回消息 → 右键不弹菜单', (tester) async {
      await tester.pumpWidget(host(_m(text: '', isRevoked: true), true));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      // 不弹任何菜单
      expect(find.text('复制'), findsNothing);
      expect(find.text('撤回'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('点「撤回」→ onRevoke 回调被调用一次', (tester) async {
      var called = 0;
      await tester.pumpWidget(host(_m(), true, onRevoke: () => called++));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(called, 1);
    });

    testWidgets('点「复制」→ 写入系统剪贴板', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(host(_m(text: '要复制的内容'), true));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(
        (calls.single.arguments as Map)['text'],
        '要复制的内容'
      );
    });

    testWidgets('点「复制」mixed 消息 → 同步写入 rich clipboard', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final msg = _mixed(
        text: '4月cursor.pdf 这是一个文件 [图片] 这是一个图片',
        blocks: const [
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
      );

      await tester.pumpWidget(host(msg, true));
      await tester.tap(find.byType(ChatMessageActionRegion),
          buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();

      expect((calls.single.arguments as Map)['text'], '这是一个文件\n这是一个图片');
      final rich = RichMessageClipboard.current;
      expect(rich, isNotNull);
      expect(rich!.blocks.map((b) => b.kind), [
        ImMessageBlockKind.file,
        ImMessageBlockKind.text,
        ImMessageBlockKind.image,
        ImMessageBlockKind.text,
      ]);
    });

    testWidgets('右键菜单贴近鼠标位置弹出', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 20,
                  child: ChatMessageActionRegion(
                    msg: _m(),
                    isMine: true,
                    onResend: () {},
                    onDelete: () {},
                    onCancelUpload: () {},
                    onRevoke: () {},
                    child: Container(
                      width: 300,
                      height: 180,
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      const click = Offset(142, 86);
      await tester.tapAt(click, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      final copyTopLeft = tester.getTopLeft(find.text('复制'));
      expect(copyTopLeft.dx, greaterThan(click.dx));
      expect(copyTopLeft.dx, lessThan(click.dx + 72));
      expect(copyTopLeft.dy, greaterThan(click.dy));
      expect(copyTopLeft.dy, lessThan(click.dy + 28));
    });

    testWidgets('可选文本气泡仍支持右键消息菜单', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMessageActionRegion(
              msg: _m(text: '可以拖动选取'),
              isMine: true,
              onDelete: () {},
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: SelectableText('可以拖动选取'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('可以拖动选取'), buttons: kSecondaryMouseButton);
      await tester.pump();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('菜单已打开时右键另一条消息 → 关闭旧菜单并打开新菜单', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ChatMessageActionRegion(
                  msg: _m(messageId: 'm1', fromUid: 'peer'),
                  isMine: false,
                  onReply: () {},
                  onMultiSelect: () {},
                  child: Container(
                    key: const ValueKey('message-region-1'),
                    width: 260,
                    height: 80,
                    color: const Color(0xFFEFEFEF),
                  ),
                ),
                ChatMessageActionRegion(
                  msg: _m(messageId: 'm2'),
                  isMine: true,
                  onReply: () {},
                  onMultiSelect: () {},
                  onRevoke: () {},
                  onDelete: () {},
                  child: Container(
                    key: const ValueKey('message-region-2'),
                    width: 260,
                    height: 80,
                    color: const Color(0xFFE0F2FE),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('message-region-1')),
          buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('message-region-2')),
          buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });
  });

  // F09 P1: ImMessage.withRevoked 把消息替成 tombstone (清掉 text / media / blocks)。
  group('ImMessage.withRevoked', () {
    test('清空 text / media / blocks; 保留 id+seq+timestamp; isRevoked=true', () {
      final orig = ImMessage(
        messageId: 'M-7',
        clientMsgNo: 'cmn-1',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1700000000,
        text: '秘密',
        messageSeq: 99,
        mediaKind: ImMediaKind.image,
        mediaUrl: '/chat/media/x/preview',
        mediaName: 'sec.png',
      );
      final r = orig.withRevoked();
      expect(r.isRevoked, isTrue);
      expect(r.text, '');
      expect(r.mediaKind, ImMediaKind.none);
      expect(r.mediaUrl, '');
      expect(r.mediaName, '');
      expect(r.messageId, 'M-7');
      expect(r.clientMsgNo, 'cmn-1');
      expect(r.messageSeq, 99);
      expect(r.timestamp, 1700000000);
    });
  });
}
