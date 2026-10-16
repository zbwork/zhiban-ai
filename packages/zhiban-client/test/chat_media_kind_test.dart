import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';

// F09 P2 媒体消息体验 (2026-06): 视频识别纯函数 + 历史 media tab 归类。
// 见 docs/contracts/agent-bus-client-contract.md §「媒体消息体验 / 视频消息基础支持」.

ImMessage _file({
  String name = 'a.mp4',
  String mime = '',
  String text = ''
}) =>
    ImMessage(
      messageId: 'm',
      clientMsgNo: 'c',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: text,
      mediaKind: ImMediaKind.file,
      mediaName: name,
      mediaMime: mime,
      mediaUrl: '/chat/media/x/download',
    );

ImMessage _img({String url = '/chat/media/i/preview'}) => ImMessage(
      messageId: 'mi',
      clientMsgNo: 'ci',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: '',
      mediaKind: ImMediaKind.image,
      mediaUrl: url,
    );

ImMessage _mixed(List<ImMessageBlock> blocks) => ImMessage(
      messageId: 'mm',
      clientMsgNo: 'cm',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000,
      text: '',
      blocks: blocks,
    );

void main() {
  test('video names and MIME preserve supported, uppercase and invalid cases', () {
    for (final ext in ['mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv', '3gp', 'mpg', 'mpeg', 'wmv', 'ogv']) {
      for (final name in ['clip.$ext', 'clip.${ext.toUpperCase()}']) {
        expect(isVideoFileName(name), isTrue, reason: name);
      }
    }
    for (final name in ['clip.pdf', 'clip.docx', 'clip.png', 'clip.jpg', 'clip.mp3', 'clip.wav', '', '   ', 'noext', 'a.']) {
      expect(isVideoFileName(name), isFalse, reason: name);
    }
    for (final (mime, expected) in [('video/mp4', true), ('VIDEO/webm', true), ('image/png', false), ('application/pdf', false), ('', false)]) {
      expect(isVideoMime(mime), expected, reason: mime);
    }
  });

  test('video, image and history classification preserve mixed-message boundaries', () {
    for (final (label, message, video, image, history) in [
      ('video filename', _file(name: 'clip.mp4'), true, false, true),
      ('video MIME', _file(name: 'unknown', mime: 'video/quicktime'), true, false, true),
      ('document', _file(name: 'report.pdf'), false, false, false),
      ('image', _img(), false, true, true),
      ('mixed video', _mixed(const [ImMessageBlock(kind: ImMessageBlockKind.file, name: 'x', mime: 'video/mp4')]), true, false, true),
      ('mixed file and image', _mixed(const [ImMessageBlock(kind: ImMessageBlockKind.file, name: 'a.mp4'), ImMessageBlock(kind: ImMessageBlockKind.image, url: '/x')]), false, true, true),
      ('mixed files', _mixed(const [ImMessageBlock(kind: ImMessageBlockKind.file, name: 'a.mp4'), ImMessageBlock(kind: ImMessageBlockKind.file, name: 'b.pdf')]), false, false, false),
      ('mixed image', _mixed(const [ImMessageBlock(kind: ImMessageBlockKind.image, url: '/x')]), false, true, true),
      ('history document', _file(name: 'r.pdf'), false, false, false),
      ('image gate video', _file(name: 'a.mp4'), true, false, true),
    ]) {
      expect(isVideoMessage(message), video, reason: label);
      expect(isImageMessage(message), image, reason: label);
      expect(isHistoryMediaMessage(message), history, reason: label);
    }
  });
}
