import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';

void main() {
  // [ChatSelectionController] 可以驱动气泡里任意数量的 [ChatSelectableSurface]
  // (图文混排时,文字被图片隔开成好几段,每段一个 surface)。这里只覆盖它在没有
  // 任何 surface 挂载时的默认状态——挂载后的聚合行为(全选所有段落 / 拼接选区
  // 文本)需要真实渲染 SelectableRegion,属于 widget test 覆盖范围。
  group('ChatSelectionController', () {
    test('没有 surface 挂载时 selectedText 为空', () {
      final c = ChatSelectionController();
      expect(c.selectedText, isEmpty);
      c.dispose();
    });

    test('clear 在没有 surface 挂载时不报错', () {
      final c = ChatSelectionController();
      c.clear();
      expect(c.selectedText, isEmpty);
      c.dispose();
    });

    test('selectAllWithHandles 在没有 surface 挂载时不报错', () {
      final c = ChatSelectionController();
      c.selectAllWithHandles();
      c.dispose();
    });
  });
}
