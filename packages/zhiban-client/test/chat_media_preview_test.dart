import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart' show imMessageIdentity;
import 'package:zhiban_client/pages/chat/widgets/chat_media_preview.dart';

// F09 P2 媒体消息体验 (2026-06): 图片大图预览收集纯函数 + 起始 index 定位。
// 见 docs/contracts/agent-bus-client-contract.md §「媒体消息体验 / 图片大图预览」.

ImMessage _txt(String id, {String text = 'hi'}) => ImMessage(
      messageId: id,
      clientMsgNo: 'c$id',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: text,
    );

ImMessage _img(
  String id, {
  String url = '/chat/media/i/preview',
  String name = '',
  ImSendStatus status = ImSendStatus.sent,
  bool revoked = false,
  int progress = -1,
  String localPath = '',
}) =>
    ImMessage(
      messageId: id,
      clientMsgNo: 'c$id',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: '',
      mediaKind: ImMediaKind.image,
      mediaUrl: url,
      mediaName: name,
      sendStatus: status,
      isRevoked: revoked,
      mediaLocalPath: localPath,
      uploadProgress: progress,
    );

ImMessage _mixed(String id, List<ImMessageBlock> blocks) => ImMessage(
      messageId: id,
      clientMsgNo: 'c$id',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: '',
      blocks: blocks,
    );

String _name(ImMessage m) => '张三';

void main() {
  group('collectPreviewableImages', () {
    test('顶层 image + 非空 url → 收集; 顺序与 messages 一致', () {
      final msgs = [
        _img('a', url: '/u/1'),
        _txt('b'),
        _img('c', url: '/u/2')
      ];
      final r = collectPreviewableImages(msgs, resolveSenderName: _name);
      expect(r.length, 2);
      expect(r[0].url, '/u/1');
      expect(r[1].url, '/u/2');
      expect(r[0].messageKey, imMessageIdentity(msgs[0]));
      expect(r[1].messageKey, imMessageIdentity(msgs[2]));
    });

    test('mixed 内 image block → 收集; file/skill/callEvent block 忽略', () {
      final m = _mixed('m', const [
        ImMessageBlock(kind: ImMessageBlockKind.text, text: 'hi'),
        ImMessageBlock(kind: ImMessageBlockKind.image, url: '/i/1'),
        ImMessageBlock(kind: ImMessageBlockKind.file, name: 'r.pdf', url: '/f'),
        ImMessageBlock(kind: ImMessageBlockKind.image, url: '/i/2'),
      ]);
      final r = collectPreviewableImages([m], resolveSenderName: _name);
      expect(r.length, 2);
      expect(r[0].url, '/i/1');
      expect(r[1].url, '/i/2');
    });

    test('撤回 / pending / failed / uploading 不收集 (无稳定 URL / 锚点)', () {
      final msgs = [
        _img('a', url: '/ok'),
        _img('rv', revoked: true),
        _img('p', status: ImSendStatus.pending),
        _img('f', status: ImSendStatus.failed),
        _img(
          'up',
          status: ImSendStatus.pending,
          localPath: '/tmp/p.png',
          progress: 30,
        ),
        _img('b', url: '/ok2'),
      ];
      final r = collectPreviewableImages(msgs, resolveSenderName: _name);
      expect(r.length, 2);
      expect(r.map((e) => e.url), ['/ok', '/ok2']);
    });

    test('空 url → 不收集', () {
      final msgs = [_img('a', url: '   ')];
      expect(
        collectPreviewableImages(msgs, resolveSenderName: _name),
        isEmpty
      );
    });

    test('messageKey 与 imMessageIdentity 一致', () {
      final msgs = [_img('M1')];
      final r = collectPreviewableImages(msgs, resolveSenderName: _name);
      expect(r.single.messageKey, imMessageIdentity(msgs.single));
    });
  });

  group('findImagePreviewIndex', () {
    test('命中起始消息 → 返回对应下标', () {
      final msgs = [_img('a'), _img('b'), _img('c')];
      final imgs = collectPreviewableImages(msgs, resolveSenderName: _name);
      final idx = findImagePreviewIndex(imgs, imMessageIdentity(msgs[1]));
      expect(idx, 1);
    });

    test('未命中 → 回退 0 (不 crash)', () {
      final msgs = [_img('a'), _img('b')];
      final imgs = collectPreviewableImages(msgs, resolveSenderName: _name);
      final idx = findImagePreviewIndex(imgs, 'cmn:nope');
      expect(idx, 0);
    });

    test('空列表 → 0', () {
      expect(findImagePreviewIndex(const [], 'whatever'), 0);
    });
  });
}
