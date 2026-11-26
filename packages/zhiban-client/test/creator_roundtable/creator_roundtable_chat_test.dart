import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_chat.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

class _ChatStore extends Fake implements LocalWorkspaceStore {
  _ChatStore({this.topics = const {}});
  final Map<String, String> topics;
  final turns = <LocalRow>[];

  @override
  Future<LocalRow?> latestCreatorExpert(String creatorId) async => {
        'id': creatorId,
        'version': 2,
        'content': jsonEncode({
          'methods': [
            if (topics[creatorId] case final topic?)
              {'problem': topic, 'steps': []},
          ],
        }),
        'evidence': jsonEncode([
          {
            'id': 'source',
            'work_id': 'archived',
            'source_version': 4,
            'start_ms': 250,
            'end_ms': 1300,
            'text': '先核实支出',
            'url': 'https://www.douyin.com/video/1234567890123456789',
          }
        ]),
      };

  @override
  Future<List<LocalRow>> roundtableChats() async => turns.isEmpty
      ? []
      : [
          {'id': 'chat', 'title': '验证预算'}
        ];

  @override
  Future<List<LocalRow>> roundtableTurns(String chatId) async => turns;

  @override
  Future<String> saveRoundtableExchange({
    String? chatId,
    required String question,
    required Map<String, Object> model,
    required List<Map<String, Object>> replies,
  }) async {
    turns.add({
      'content': question,
      'role': 'user',
      'expert_snapshot': jsonEncode(model),
      'evidence': '[]'
    });
    for (final reply in replies) {
      turns.add({
        'content': reply['text'],
        'role': 'assistant',
        'expert_snapshot': jsonEncode({...model, 'expert': reply['expert']}),
        'evidence': jsonEncode(reply['evidence']),
      });
    }
    return 'chat';
  }
}

class _HistoryStore extends Fake implements LocalWorkspaceStore {
  final conversations = <LocalRow>[
    {'id': 'c1', 'title': '最新对话'},
    {'id': 'c2', 'title': '当前对话'},
    {'id': 'c3', 'title': '较早对话'},
  ];

  @override
  Future<List<LocalRow>> roundtableChats() async => conversations.toList();

  @override
  Future<List<LocalRow>> searchRoundtableChats(String query) async =>
      query == '正文里的发票'
          ? conversations.where((row) => row['id'] == 'c2').toList()
          : [];

  @override
  Future<List<LocalRow>> roundtableTurns(String chatId) async => [
        {
          'role': 'user',
          'content': '消息 $chatId',
          'expert_snapshot': '{}',
          'evidence': '[]',
        },
      ];

  @override
  Future<void> deleteRoundtableChat(String chatId) async {
    conversations.removeWhere((row) => row['id'] == chatId);
  }
}

void main() {
  testWidgets('从真实圆桌对话组件选专家、发送并展开引用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1050, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _ChatStore();
    Map<String, dynamic>? opened;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CreatorRoundtableChat(
      store: store,
      onOpenEvidence: (evidence) => opened = evidence,
      creators: const [
        {'id': 'expert', 'name': '预算博主'}
      ],
      resolveModel: (_) async => (
        snapshot: {'model_id': 'test-model'},
        complete: (_, __) async =>
            '{"points":[{"text":"核实已有支出","evidence_ids":["source"]}]}',
      ),
    ))));
    await tester.pumpAndSettle();
    final choose = find.byKey(const ValueKey('roundtable-chat-experts'));
    await tester.tap(choose);
    await tester.pumpAndSettle();
    final expertRow = find.ancestor(
        of: find.byIcon(Icons.check_rounded), matching: find.byType(ListTile));
    expect(tester.widget<ListTile>(expertRow).selected, isTrue);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '验证预算');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('核实已有支出 [1]'), findsOneWidget);
    expect(find.text('预算博主 · v2'), findsOneWidget);
    final history = find.byKey(const ValueKey('roundtable-chat-messages'));
    final questionBubble = find.widgetWithText(SelectableText, '验证预算');
    expect(tester.getTopLeft(questionBubble).dy - tester.getTopLeft(history).dy,
        inInclusiveRange(16, 32));
    expect(
        tester
            .widget<SingleChildScrollView>(history)
            .controller!
            .position
            .maxScrollExtent,
        0);
    final bubble = find.byKey(const ValueKey('roundtable-expert-bubble'));
    expect(tester.getSize(bubble).width, lessThan(280));
    expect(tester.getRect(bubble).top,
        greaterThan(tester.getRect(find.text('预算博主 · v2')).top));
    final toggle = find.byKey(const ValueKey('roundtable-citations-toggle'));
    final details = find.byKey(const ValueKey('roundtable-citation-details'));
    expect(tester.getSize(toggle).height, lessThanOrEqualTo(26));
    expect(details, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    expect(find.textContaining('00:00:00.250'), findsOneWidget);
    final quotation = find.widgetWithText(SelectableText, '先核实支出');
    expect(
        tester.widget<SelectableText>(quotation).style!.fontSize!,
        lessThan(
            tester.widget<SelectableText>(questionBubble).style!.fontSize!));
    await tester.tap(find.text('查看归档作品'));
    expect(opened?['work_id'], 'archived');
    expect(opened?['source_version'], 4);
    expect(opened?['start_ms'], 250);
    expect(tester.takeException(), isNull);
  });

  testWidgets('建议问题跟随专家，点击后填草稿并选中对应专家', (tester) async {
    const foodTopic = '山姆食品新品怎么选？';
    const truckTopic = '长途运输怎么安排加油？';
    final store = _ChatStore(topics: {'food': foodTopic, 'truck': truckTopic});
    var modelCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableChat(
          store: store,
          creators: const [
            {'id': 'food', 'name': '楠哥探味'},
            {'id': 'truck', 'name': '志龙的卡车生活'},
          ],
          resolveModel: (_) async {
            modelCalls++;
            throw StateError('问候和填写草稿由本机处理');
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('roundtable-chat-question'));
    final food = find.widgetWithText(OutlinedButton, foodTopic);
    final truck = find.widgetWithText(OutlinedButton, truckTopic);
    expect(food, findsOneWidget);
    expect(truck, findsOneWidget);
    expect(find.byTooltip(foodTopic), findsNothing);
    final foodStyle = tester.widget<OutlinedButton>(food).style!;
    final scheme = Theme.of(tester.element(food)).colorScheme;
    final cardColor =
        Color.alphaBlend(scheme.primary.withValues(alpha: .08), scheme.surface);
    expect(foodStyle.backgroundColor!.resolve({}), cardColor);
    expect(
        foodStyle.backgroundColor!.resolve({WidgetState.hovered}), cardColor);
    final firstCard = tester.getRect(food);
    final secondCard = tester.getRect(truck);
    expect(firstCard.size, secondCard.size);
    expect(firstCard.top, secondCard.top);
    expect(secondCard.left - firstCard.right, closeTo(8, .01));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(420, 660));
    await tester.pumpAndSettle();
    final firstNarrowCard = tester.getRect(food);
    final secondNarrowCard = tester.getRect(truck);
    expect(firstNarrowCard.size, secondNarrowCard.size);
    expect(firstNarrowCard.left, secondNarrowCard.left);
    expect(secondNarrowCard.top - firstNarrowCard.bottom, closeTo(8, .01));
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
    await tester.pumpAndSettle();
    await tester.enterText(input, '大家好');
    await tester.pump();
    expect(tester.widget<OutlinedButton>(food).onPressed, isNull);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(food, findsOneWidget);
    await tester.tap(food);
    await tester.pumpAndSettle();
    expect(tester.widget<UiInputField>(input).controller?.text,
        '请结合你的作品讲讲：$foodTopic');
    expect(find.text('1 位专家'), findsOneWidget);
    expect(truck, findsNothing);
    expect(store.turns, hasLength(3));
    expect(modelCalls, 0);
  });

  testWidgets('两位专家分别回复自然语言自我介绍请求', (tester) async {
    final store = _ChatStore();
    var modelCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableChat(
          store: store,
          creators: const [
            {'id': 'food', 'name': '楠哥探味'},
            {'id': 'truck', 'name': '志龙的卡车生活'},
          ],
          resolveModel: (_) async {
            modelCalls++;
            throw StateError('自我介绍由本机处理');
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('roundtable-chat-question'));
    for (final message in ['我想认识你们', '你们介绍下自己吧']) {
      await tester.enterText(input, message);
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
    }
    expect(modelCalls, 0);
    expect(
        store.turns.where((turn) => turn['role'] == 'assistant'), hasLength(4));
    expect(find.textContaining('我是「楠哥探味」的 AI 圆桌专家'), findsNWidgets(2));
    expect(find.textContaining('我是「志龙的卡车生活」的 AI 圆桌专家'), findsNWidgets(2));
  });

  testWidgets('显示待回复问题，模型失败后保留原问题可重发', (tester) async {
    final pending = Completer<String>();
    final store = _ChatStore();
    var modelCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableChat(
          store: store,
          creators: const [
            {'id': 'expert', 'name': '预算博主'}
          ],
          resolveModel: (_) async => (
            snapshot: {'model_id': 'test-model'},
            complete: (_, __) {
              if (modelCalls++ == 0) return pending.future;
              return Future.value(
                '{"points":[{"text":"核实已有支出","evidence_ids":["source"]}]}',
              );
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final send = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    final input = find.byKey(const ValueKey('roundtable-chat-question'));
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(input, '验证预算');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    expect(find.widgetWithText(SelectableText, '验证预算'), findsOneWidget);
    expect(find.text('专家正在回答…'), findsOneWidget);
    expect(tester.widget<UiInputField>(input).controller?.text, isEmpty);
    expect(store.turns, isEmpty);
    expect(tester.widget<IconButton>(send).onPressed, isNull);

    pending.completeError(StateError('model offline'));
    await tester.pumpAndSettle();
    expect(find.text('回答生成失败，请检查所选模型后重试。'), findsOneWidget);
    expect(tester.widget<UiInputField>(input).controller?.text, '验证预算');
    expect(find.text('专家正在回答…'), findsNothing);

    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(store.turns, hasLength(2));
    expect(find.widgetWithText(SelectableText, '验证预算'), findsOneWidget);
    expect(find.text('核实已有支出 [1]'), findsOneWidget);
    expect(tester.widget<UiInputField>(input).controller?.text, isEmpty);
  });

  testWidgets('长会话打开时显示最新消息，侧栏收起仍可切换历史', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 750);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _ChatStore();
    for (var index = 1; index <= 30; index++) {
      store.turns.add({'role': 'user', 'content': '第 $index 条问题'});
    }
    final session = RoundtableChatSession()..active = 'chat';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableChat(
          store: store,
          creators: const [],
          session: session,
          initiallyExpanded: true,
          resolveModel: (_) => throw StateError('本测试不调用模型'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 30 条问题').hitTestable(), findsOneWidget);
    expect(find.text('第 1 条问题').hitTestable(), findsNothing);
    final history = find.byKey(const ValueKey('roundtable-chat-messages'));
    expect(
        tester
            .widget<SingleChildScrollView>(history)
            .controller!
            .position
            .maxScrollExtent,
        greaterThan(0));
    await tester.drag(history, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.text('第 1 条问题').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('收起对话列表'));
    await tester.pumpAndSettle();
    final selector =
        find.byKey(const ValueKey('roundtable-chat-history-select'));
    final newChatButton = find.byTooltip('开启新对话');
    expect(tester.widget<UiSelect<String>>(selector).value, 'chat');

    await tester.tap(find.byTooltip('退出全屏对话'));
    await tester.pumpAndSettle();
    final selectorBounds = tester.getRect(selector);
    final newChatBounds = tester.getRect(newChatButton);
    final panel = find.byKey(const ValueKey('roundtable-chat-panel'));
    expect(selectorBounds.top - tester.getTopLeft(panel).dy, 8);
    expect(tester.getTopLeft(history).dy - selectorBounds.bottom, 9);
    expect(newChatBounds.left - selectorBounds.right, 6);
    expect(newChatBounds.center.dy, selectorBounds.center.dy);

    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(selectorBounds.width, lessThanOrEqualTo(176));
    final dropdown = find.byType(CompositedTransformFollower);
    expect(dropdown, findsOneWidget);
    expect(tester.getSize(dropdown).width, selectorBounds.width);
    expect(tester.getSize(dropdown).height, lessThan(60));
    final option = find.descendant(of: dropdown, matching: find.text('验证预算'));
    expect(tester.getTopLeft(option).dy, greaterThan(selectorBounds.bottom));
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(dropdown, findsNothing);
  });

  testWidgets('全屏历史按正文查找并保持相邻会话草稿', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _HistoryStore();
    final session = RoundtableChatSession()..active = 'c2';
    session.drafts['c3'] = '较早对话的未发草稿';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableChat(
          store: store,
          creators: const [],
          session: session,
          resolveModel: (_) => throw StateError('本测试不调用模型'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('放大对话'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('roundtable-history-search'));
    await tester.enterText(search, '正文里的发票');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '当前对话'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '较早对话'), findsNothing);

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除「当前对话」'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.conversations, hasLength(3));

    await tester.tap(find.byTooltip('删除「当前对话」'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(store.conversations.map((row) => row['id']), ['c1', 'c3']);
    expect(find.text('消息 c3'), findsOneWidget);
    final compose = find.byKey(const ValueKey('roundtable-chat-question'));
    expect(tester.widget<UiInputField>(compose).controller?.text, '较早对话的未发草稿');

    await tester.tap(find.byTooltip('删除「最新对话」'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('消息 c3'), findsOneWidget);
    expect(tester.widget<UiInputField>(compose).controller?.text, '较早对话的未发草稿');
  });
}
