import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';

/// 覆盖本轮 item 一：URL 安全解码修复（此前 _safeDecodeFull/_safeDecodeComponent
/// 自递归，正常解码失效、非法编码会无限递归）。修复后应正常解码，且 malformed
/// percent-encoding 不抛错、返回原串。
void main() {
  group('safeDecodeFull', () {
    test('解码合法 percent-encoding', () {
      expect(safeDecodeFull('a%20b'), 'a b');
    });

    test('解码中文 percent-encoding', () {
      expect(safeDecodeFull('%E4%B8%AD'), '中');
    });

    test('malformed 不抛错、原样返回', () {
      expect(safeDecodeFull('a%ZZb'), 'a%ZZb');
      expect(() => safeDecodeFull('%'), returnsNormally);
      expect(safeDecodeFull('%'), '%');
    });

    test('空串', () {
      expect(safeDecodeFull(''), '');
    });
  });

  group('safeDecodeComponent', () {
    test('解码合法 + malformed 原样返回', () {
      expect(safeDecodeComponent('x%2Fy'), 'x/y');
      expect(safeDecodeComponent('%QQ'), '%QQ');
      expect(() => safeDecodeComponent('%'), returnsNormally);
    });
  });
}
