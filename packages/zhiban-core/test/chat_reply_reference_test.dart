import 'package:test/test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_reply_reference.dart';

// F09 引用回复 v1: ChatReplyReference model + quotedSummaryOf 纯函数。
// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.

ImMessage _msg({
  String text = '',
  String messageId = 'm1',
  String clientMsgNo = 'cmn-1',
  int messageSeq = 10,
  String fromUid = 'u',
  ImMediaKind mediaKind = ImMediaKind.none,
  String mediaName = '',
  List<ImMessageBlock> blocks = const [],
  bool isRevoked = false,
}) =>
    ImMessage(
      messageId: messageId,
      clientMsgNo: clientMsgNo,
      fromUid: fromUid,
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: text,
      messageSeq: messageSeq,
      mediaKind: mediaKind,
      mediaName: mediaName,
      blocks: blocks,
      isRevoked: isRevoked,
    );

void main() {
  group('quotedSummaryOf', () {
    test('纯文本 → 首行截断 80 char', () {
      expect(quotedSummaryOf(_msg(text: 'hello world')), 'hello world');
    });

    test('多行文本 → 只取首行', () {
      expect(quotedSummaryOf(_msg(text: 'line1\nline2\nline3')), 'line1');
    });

    test('文本超 80 rune → 截断 + …', () {
      final s = '一' * 100;
      final r = quotedSummaryOf(_msg(text: s));
      expect(r.endsWith('…'), isTrue);
      expect(r.runes.length, 81); // 80 + …
    });

    test('image 媒体 → [图片]', () {
      expect(
        quotedSummaryOf(
            _msg(text: '', mediaKind: ImMediaKind.image, mediaName: 'p.png')),
        '[图片]',
      );
    });

    test('file 媒体 → [文件] name', () {
      expect(
        quotedSummaryOf(_msg(
            text: '', mediaKind: ImMediaKind.file, mediaName: 'doc.pdf')),
        '[文件] doc.pdf',
      );
    });

    test('file 媒体无 name → [文件]', () {
      expect(
        quotedSummaryOf(
            _msg(text: '', mediaKind: ImMediaKind.file, mediaName: '')),
        '[文件]',
      );
    });

    test('mixed: 优先首个 text block', () {
      expect(
        quotedSummaryOf(_msg(blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.image, url: '/x'),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hello'),
        ])),
        'hello',
      );
    });

    test('mixed: 无 text block → 首个 image → [图片]', () {
      expect(
        quotedSummaryOf(_msg(blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.image, url: '/x'),
        ])),
        '[图片]',
      );
    });

    test('撤回 → 原消息不可用', () {
      expect(
        quotedSummaryOf(_msg(text: 'x', isRevoked: true)),
        '原消息不可用',
      );
    });

    test('空文本无媒体 → 原消息不可用', () {
      expect(
        quotedSummaryOf(_msg(text: '')),
        '原消息不可用',
      );
    });
  });

  group('ChatReplyReference toJson/fromJson', () {
    test('roundtrip 保留所有字段', () {
      const ref = ChatReplyReference(
        messageId: 'M-1',
        clientMsgNo: 'cmn-7',
        messageSeq: 42,
        senderUid: 't_t_u_uu',
        senderName: '张三',
        summary: 'hi',
        kind: ChatReplyKind.text,
      );
      final j = ref.toJson();
      final back = ChatReplyReference.fromJson(j);
      expect(back.messageId, 'M-1');
      expect(back.clientMsgNo, 'cmn-7');
      expect(back.messageSeq, 42);
      expect(back.senderUid, 't_t_u_uu');
      expect(back.senderName, '张三');
      expect(back.summary, 'hi');
      expect(back.kind, ChatReplyKind.text);
    });

    test('isUnavailable 不上 wire (encode 不带)', () {
      const ref = ChatReplyReference(
        messageId: 'M',
        clientMsgNo: '',
        messageSeq: 0,
        senderUid: 'u',
        senderName: 'n',
        summary: 's',
        isUnavailable: true,
      );
      final j = ref.toJson();
      expect(j.containsKey('isUnavailable'), isFalse);
      expect(j.containsKey('is_unavailable'), isFalse);
    });

    test('seq=0 时 message_seq 不进 wire', () {
      const ref = ChatReplyReference(
        messageId: 'M',
        clientMsgNo: 'cmn',
        messageSeq: 0,
        senderUid: 'u',
        senderName: 'n',
        summary: 's',
      );
      expect(ref.toJson().containsKey('message_seq'), isFalse);
    });
  });

  group('buildReplyRefFromMessage', () {
    test('text 消息 → kind=text + summary 取自 text', () {
      final ref = buildReplyRefFromMessage(
        source: _msg(text: 'hello', fromUid: 't_x_u_abc'),
        senderName: '张三',
      );
      expect(ref.kind, ChatReplyKind.text);
      expect(ref.summary, 'hello');
      expect(ref.senderName, '张三');
      expect(ref.senderUid, 't_x_u_abc');
      expect(ref.isUnavailable, isFalse);
    });

    test('撤回 → isUnavailable=true + summary=原消息不可用', () {
      final ref = buildReplyRefFromMessage(
        source: _msg(text: 'x', isRevoked: true),
        senderName: '张三',
      );
      expect(ref.isUnavailable, isTrue);
      expect(ref.summary, '原消息不可用');
    });

    test('image 媒体 → kind=image + summary=[图片]', () {
      final ref = buildReplyRefFromMessage(
        source: _msg(
            text: '', mediaKind: ImMediaKind.image, mediaName: 'a.png'),
        senderName: '张三',
      );
      expect(ref.kind, ChatReplyKind.image);
      expect(ref.summary, '[图片]');
    });
  });
}
