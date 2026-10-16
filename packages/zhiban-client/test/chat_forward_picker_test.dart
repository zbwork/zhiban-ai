import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_forward_picker.dart';

// F09 转发 v1: 转发目标列表过滤纯函数。
// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.

ConversationItem _conv({
  required String id,
  required String title,
  String kind = 'human_direct',
  String? channelId,
  int channelType = 1,
}) =>
    ConversationItem(
      conversationId: id,
      title: title,
      agentId: '',
      agentName: '',
      kind: kind,
      wukongChannelId: channelId ?? 'ch-$id',
      wukongChannelType: channelType,
    );

class _FakeChatSvc extends OpenClawChatService {
  _FakeChatSvc(this.items);
  final List<ConversationItem> items;

  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async =>
      items;
}

void main() {
  group('filterForwardTargets', () {
    test('排除 agent_direct (避免触发 Agent)', () {
      final r = filterForwardTargets(
        [
          _conv(id: 'a', title: '同事 A'),
          _conv(id: 'b', title: '数字员工 B', kind: 'agent_direct'),
          _conv(id: 'g', title: '群 C', kind: 'group', channelType: 2),
        ],
        ''
      );
      expect(r.map((c) => c.title), ['同事 A', '群 C']);
    });

    test('排除无 wukongChannelId 的会话', () {
      final r = filterForwardTargets(
        [
          _conv(id: 'a', title: 'A', channelId: ''),
          _conv(id: 'b', title: 'B'),
        ],
        ''
      );
      expect(r.map((c) => c.title), ['B']);
    });

    test('按 title 包含匹配 (大小写不敏感)', () {
      final r = filterForwardTargets(
        [
          _conv(id: 'a', title: 'Alice'),
          _conv(id: 'b', title: 'Bob'),
          _conv(id: 'c', title: 'Charlie'),
        ],
        'lI'
      );
      // 'lI' → 'li' 匹配 Alice 和 Charlie
      expect(r.map((c) => c.title).toList(), ['Alice', 'Charlie']);
    });

    test('空 query → 返回全部 (符合条件)', () {
      final r = filterForwardTargets(
        [
          _conv(id: 'a', title: 'A'),
          _conv(id: 'b', title: 'B'),
        ],
        '   '
      );
      expect(r.length, 2);
    });
  });

  group('filteredVisibleSelection (CR-B3 多目标搜索保留选中)', () {
    test('全部可见时返回原集合', () {
      final visible = [
        _conv(id: 'a', title: 'A'),
        _conv(id: 'b', title: 'B')
      ];
      final r = filteredVisibleSelection({'a', 'b'}, visible);
      expect(r, {'a', 'b'});
    });

    test('搜索过滤后, 仅返回搜索结果中的已选 id (不丢失但 widget 内部仍保留全集)', () {
      // 这是给「filtered 视图」用的辅助; widget 真实状态保留全集, 但 footer/UI 可用此过滤
      final visible = [_conv(id: 'a', title: 'A')];
      final r = filteredVisibleSelection({'a', 'b', 'c'}, visible);
      expect(r, {'a'});
    });

    test('一个都不可见 → 空集 (但 widget 内部 selectedKeys 不动)', () {
      final visible = <ConversationItem>[];
      expect(filteredVisibleSelection({'a', 'b'}, visible), <String>{});
    });
  });

  group('showChatForwardPickerDialog', () {
    testWidgets('root Navigator 在 ProviderScope 上层时仍能读取 conversationsProvider',
        (tester) async {
      List<ConversationItem>? picked;
      final target = _conv(id: 'zhang', title: '张伟', channelType: 2);

      await tester.pumpWidget(MaterialApp(
        home: ProviderScope(
          overrides: [
            chatServiceProvider.overrideWith((ref) => _FakeChatSvc([target])),
          ],
          child: Scaffold(
            body: Builder(builder: (context) {
              return TextButton(
                onPressed: () async {
                  picked = await showChatForwardPickerDialog(
                    context,
                    multi: true,
                  );
                },
                child: const Text('open'),
              );
            }),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('转发到…'), findsOneWidget);
      expect(find.text('张伟'), findsOneWidget);

      await tester.tap(find.text('张伟'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(picked?.map((e) => e.conversationId).toList(), ['zhang']);
    });
  });
}
