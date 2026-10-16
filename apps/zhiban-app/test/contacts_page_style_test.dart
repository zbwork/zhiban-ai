import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:nexwork/pages/contacts/contacts_page.dart';
import 'package:zhiban_client/pages/contacts/contacts_sidebar.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';

ContactAgent _agent({
  required String id,
  required String name,
  required String source,
  String avatar = '',
  String subtitle = '',
}) =>
    ContactAgent(
      id: id,
      displayName: name,
      avatarUrl: avatar,
      subtitle: subtitle,
      positionLabel: '',
      departmentName: '',
      source: source,
      skills: const [],
      apps: const [],
      lifecycleStatus: '',
      canChat: true,
      canInviteToRoom: true,
    );

ContactDepartment _dept(String id, String name, String parent) =>
    ContactDepartment(
      id: id,
      name: name,
      parentId: parent,
      depth: 0,
      humanCount: 1,
      agentCount: 1,
      children: const [],
    );

ContactPerson _person({
  required String kind,
  required String id,
  required String name,
  String departmentId = 'dept-rd-1',
  String department = '研发一组',
  String subtitle = '',
}) =>
    ContactPerson(
      kind: kind,
      id: id,
      displayName: name,
      avatarUrl: '',
      subtitle: subtitle,
      positionLabel: '',
      departmentId: departmentId,
      departmentName: department,
      source: kind == 'agent' ? 'enterprise' : '',
      skills: const [],
      apps: const [],
      lifecycleStatus: '',
      canChat: true,
    );

class _ContactsStyleFakeService extends ContactsService {
  const _ContactsStyleFakeService({this.agentCount = 1});
  final int agentCount;

  @override
  Future<List<ContactDepartment>> tree() async => [
        _dept('dept-tech', '科技中心', ''),
        _dept('dept-rd', '研发部', 'dept-tech'),
        _dept('dept-rd-1', '研发一组', 'dept-rd'),
      ];

  @override
  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    if (departmentId != 'dept-rd-1') return const [];
    return [
      _person(kind: 'human', id: 'acc-1', name: '刘洋'),
      _person(
        kind: 'agent',
        id: 'de-1',
        name: '周芷涵',
        subtitle: '合同要点提取',
      ),
    ];
  }

  @override
  Future<ContactAgentsSnapshot> agents({String keyword = ''}) async =>
      ContactAgentsSnapshot(
        personal: [
          _agent(id: 'agent-personal', name: '真龙虾', source: 'personal'),
        ],
        enterprise: [
          for (var i = 0; i < agentCount; i++)
            _agent(
              id: 'agent-enterprise-$i',
              name: agentCount == 1 ? 'SystemsOpsBot(test)' : 'Employee $i',
              source: 'enterprise',
              subtitle: 'SystemsOpsBot(test)',
            ),
        ],
        platform: [],
      );
}

TextStyle _styleOf(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return text.style!;
}

List<TextStyle?> _stylesOf(WidgetTester tester, Finder finder) =>
    tester.widgetList<Text>(finder).map((text) => text.style).toList();

void main() {
  testWidgets('expanded employee tree scrolls without sidebar overflow',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        contactsServiceProvider
            .overrideWithValue(const _ContactsStyleFakeService(agentCount: 40))
      ],
      child: MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 400,
                child: ContactsSidebar(
                    selectedPersonId: null,
                    selectedAgentId: null,
                    selectedAgentFilter: AgentListFilter.enterprise,
                    onAgentFilterSelected: (_) {},
                    onAgentSelected: (_) {},
                    onDepartmentSelected: (_) {},
                    onHumanSelected: (_) {}))),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('企业创建的'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Employee 39'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Employee 39').hitTestable(), findsOneWidget);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'contacts page uses drive-style breadcrumb and full department path',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactsServiceProvider
              .overrideWithValue(const _ContactsStyleFakeService()),
        ],
        child: const MaterialApp(home: ContactsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final sidebarAgentText = find
        .ancestor(
          of: find.text('数字员工').first,
          matching: find.byType(InkWell),
        )
        .evaluate()
        .isNotEmpty;
    expect(sidebarAgentText, isTrue);

    expect(_styleOf(tester, find.text('组织架构')).fontSize, 15);
    expect(_styleOf(tester, find.text('科技中心')).fontSize, 15);

    await tester.tap(find.byIcon(CupertinoIcons.chevron_right).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('研发一组'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('通讯录'), findsNothing);
    expect(
      _stylesOf(tester, find.text('组织架构'))
          .every((style) => style?.fontSize == 15),
      isTrue,
    );
    expect(find.text('共 2 项'), findsNothing);
    expect(
      _stylesOf(tester, find.text('科技中心')).any(
        (style) =>
            style?.fontSize == 16 && style?.fontWeight == FontWeight.w700,
      ),
      isTrue,
    );
    expect(
      _stylesOf(tester, find.text('研发部')).any(
        (style) =>
            style?.fontSize == 16 && style?.fontWeight == FontWeight.w700,
      ),
      isTrue,
    );
    expect(
      _stylesOf(tester, find.text('研发一组')).any(
        (style) =>
            style?.fontSize == 16 && style?.fontWeight == FontWeight.w700,
      ),
      isTrue,
    );
    expect(_styleOf(tester, find.text('姓名 / 职位')).fontSize, 15);
    expect(
        _styleOf(tester, find.text('姓名 / 职位')).color, const Color(0xFF6B7280));
  });

  testWidgets('digital employee sidebar renders a tree and opens detail',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactsServiceProvider
              .overrideWithValue(const _ContactsStyleFakeService()),
        ],
        child: const MaterialApp(home: ContactsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('数字员工'), findsWidgets);
    expect(find.text('真龙虾'), findsWidgets);
    expect(find.text('企业创建的'), findsOneWidget);
    expect(find.text('BOT'), findsNothing);

    await tester.tap(find.text('企业创建的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      _stylesOf(tester, find.text('企业创建的')).any(
        (style) =>
            style?.color == const Color(0xFF165DFF) &&
            style?.fontWeight == FontWeight.w900,
      ),
      isTrue,
    );
    expect(find.text('真龙虾'), findsOneWidget);
    expect(find.text('数字员工'), findsWidgets);

    await tester.tap(find.text('SystemsOpsBot(test)').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('由企业管理员创建'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('添加到群聊'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('BOT'), findsOneWidget);
  });
}
