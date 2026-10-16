import 'package:zhiban_core/im/im_client.dart';

class RichMessageClipboardEntry {
  const RichMessageClipboardEntry({
    required this.blocks,
    required this.plainText,
  });

  final List<ImMessageBlock> blocks;
  final String plainText;
}

class RichMessageClipboard {
  static RichMessageClipboardEntry? _entry;

  static RichMessageClipboardEntry? get current => _entry;

  static void clear() {
    _entry = null;
  }

  static void writeFromMessage(ImMessage msg, {required String plainText}) {
    final blocks = copyableRichBlocksOf(msg);
    _entry = RichMessageClipboardEntry(
      blocks: blocks,
      plainText: plainText
    );
  }

  static List<ImMessageBlock> copyableRichBlocksOf(ImMessage msg) {
    if (msg.isMixed) {
      return msg.blocks
          .where((b) => b.isText || b.isMarkdown || b.isImage || b.isFile)
          .toList(growable: false);
    }
    if (msg.mediaKind == ImMediaKind.image) {
      return [
        ImMessageBlock(
          kind: ImMessageBlockKind.image,
          text: msg.text,
          url: msg.mediaUrl,
          fileUuid: msg.mediaFileUuid,
          refUuid: msg.mediaRefUuid,
          name: msg.mediaName,
          size: msg.mediaSize,
          mime: msg.mediaMime,
          width: msg.mediaWidth,
          height: msg.mediaHeight,
        ),
      ];
    }
    if (msg.mediaKind == ImMediaKind.file) {
      return [
        ImMessageBlock(
          kind: ImMessageBlockKind.file,
          text: msg.text,
          url: msg.mediaUrl,
          fileUuid: msg.mediaFileUuid,
          refUuid: msg.mediaRefUuid,
          name: msg.mediaName,
          size: msg.mediaSize,
          mime: msg.mediaMime,
          width: msg.mediaWidth,
          height: msg.mediaHeight,
        ),
      ];
    }
    final text = msg.text.trim();
    if (text.isEmpty) return const <ImMessageBlock>[];
    return [ImMessageBlock(kind: ImMessageBlockKind.text, text: text)];
  }
}
