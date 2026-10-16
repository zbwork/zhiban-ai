import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/group_title_edit.dart';

class _FakeChatService extends OpenClawChatService {
  _FakeChatService(this.items);

  final List<ConversationItem> items;

  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async {
    return items;
  }

  @override
  Future<List<AgentItem>> listAgents() async {
    return const <AgentItem>[];
  }
}

ConversationItem _group({
  String id = 'conv-1',
  String title = '旧群名'
}) {
  return ConversationItem(
    conversationId: id,
    title: title,
    agentId: '',
    agentName: '',
    kind: 'group',
    roomUuid: 'room-1',
    wukongChannelId: 'channel-1',
    wukongChannelType: 2,
  );
}

Future<(ProviderContainer, ConversationsNotifier)> _boot(
  List<ConversationItem> items,
) async {
  final container = ProviderContainer(
    overrides: [
      chatServiceProvider.overrideWith((ref) => _FakeChatService(items)),
    ],
  );
  await container.read(conversationsProvider.future);
  return (container, container.read(conversationsProvider.notifier));
}

void main() {
  group('group title edit validation', () {
    test('trims valid input and rejects blank / over limit titles', () {
      expect(normalizeGroupTitleInput('  新群名  '), '新群名');
      expect(groupTitleValidationError('   '), '群名不能为空');
      expect(groupTitleValidationError('知' * 65), '群名最多 64 个字符');
      expect(groupTitleValidationError('知' * 64), isNull);
    });

    test('maps forbidden rename to a creator-specific message', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/rooms/room-1'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/rooms/room-1'),
          statusCode: 403,
        ),
      );
      expect(groupRenameFailureMessage(error), '仅群主可修改群名');
      expect(groupRenameFailureMessage(Exception('offline')), '修改群名失败');
    });
  });

  group('GroupTitleEdit widget', () {
    testWidgets('non-owner sees a read-only title', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupTitleEdit(
              title: '只读群名',
              editable: false,
              onSubmit: (_) async => true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('只读群名'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('只读群名'), findsOneWidget);
    });

    testWidgets('submits normalized title when focus leaves the field',
        (tester) async {
      String? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                GroupTitleEdit(
                  title: '旧群名',
                  onSubmit: (title) async {
                    submitted = title;
                    return true;
                  },
                ),
                const Text('outside'),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('旧群名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  新群名  ');
      await tester.tap(find.text('outside'));
      await tester.pumpAndSettle();

      expect(submitted, '新群名');
    });
  });

  group('ConversationsNotifier.patchConversationTitle', () {
    test('updates only the matching group conversation title locally',
        () async {
      final (container, notifier) = await _boot([
        _group(id: 'conv-1', title: '旧群名'),
        _group(id: 'conv-2', title: '另一个群'),
      ]);
      addTearDown(container.dispose);

      notifier.patchConversationTitle('conv-1', '新群名');

      final items = container.read(conversationsProvider).asData!.value;
      expect(
          items.firstWhere((c) => c.conversationId == 'conv-1').title, '新群名');
      expect(
          items.firstWhere((c) => c.conversationId == 'conv-2').title, '另一个群',
        );
      },
    );
    });
  }
