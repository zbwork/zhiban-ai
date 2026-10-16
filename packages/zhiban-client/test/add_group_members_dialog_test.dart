import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/add_group_members_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/group_member_picker.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';

ContactPerson _person({
  required String kind,
  required String id,
  required String name,
  String position = '',
  String department = '',
  bool canInvite = true,
}) {
  return ContactPerson(
    kind: kind,
    id: id,
    displayName: name,
    avatarUrl: '',
    subtitle: '',
    positionLabel: position,
    departmentId: '',
    departmentName: department,
    source: kind == 'agent' ? 'enterprise' : '',
    skills: const [],
    apps: const [],
    lifecycleStatus: '',
    canChat: true,
    canInviteToRoom: canInvite,
  );
}

ContactDepartment _dept(String id, String name, String parent) => ContactDepartment(
      id: id,
      name: name,
      parentId: parent,
      depth: 0,
      humanCount: 0,
      agentCount: 0,
      children: const [],
    );

/// 技术部(d1) ├─ 张三(human) + 周芷涵(agent)
///           └─ 前端组(d2) ── 李四(human)
/// 数字员工分区:周芷涵(部门内) + 陈启航(无部门)
class _TreeFakeService extends ContactsService {
  const _TreeFakeService();

  @override
  Future<List<ContactDepartment>> tree() async =>
      [_dept('d1', '技术部', ''), _dept('d2', '前端组', 'd1')];

  @override
  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    if (kind == 'agent') {
      return [
        _person(kind: 'agent', id: 'de-1', name: '周芷涵', position: '合同审阅顾问', department: '技术部'),
        _person(kind: 'agent', id: 'de-2', name: '陈启航', department: ''),
      ];
    }
    return [
      _person(kind: 'human', id: 'acc-1', name: '张三', department: '技术部'),
      _person(kind: 'human', id: 'acc-2', name: '李四', department: '前端组'),
    ];
  }
}

Future<void> _pump(
  WidgetTester tester, {
  Set<String> existing = const {},
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AddGroupMembersDialog(
        contactsService: const _TreeFakeService(),
        existingMemberIds: existing,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('标题显示"数字员工"、不显示"智能机器人"，并加载 agent 候选', (tester) async {
    await _pump(tester);
    expect(find.text('智能机器人'), findsNothing);
    expect(find.text('数字员工'), findsWidgets); // 分区标题(+ agent tag)
    expect(find.text('陈启航'), findsOneWidget); // agent 候选已加载
  });

  testWidgets('默认顶层部门展开、二级折叠', (tester) async {
    await _pump(tester);
    expect(find.text('张三'), findsOneWidget); // 技术部展开
    expect(find.text('李四'), findsNothing); // 前端组默认折叠
    await tester.tap(find.text('前端组'));
    await tester.pumpAndSettle();
    expect(find.text('李四'), findsOneWidget); // 展开后可见
  });

  testWidgets('部门 tree 同时显示该部门的数字员工', (tester) async {
    await _pump(tester);
    expect(find.text('周芷涵'), findsNWidgets(2)); // 分区 + 技术部 tree
  });

  testWidgets('已存在 human/agent 置灰、不隐藏、不可勾选', (tester) async {
    await _pump(tester, existing: {'acc-1', 'de-1'}); // 张三 + 周芷涵 已在群
    // 不隐藏:仍展示。
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('周芷涵'), findsNWidgets(2));
    // 置灰提示。
    expect(find.text('已在群内'), findsWidgets);
    // 点击不加入右侧已选。
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();
    expect(find.text('选择联系人'), findsOneWidget); // 仍未选(count 0)
    expect(find.textContaining('已选择'), findsNothing);
  });

  MemberSquareCheckBox deptCb(WidgetTester tester, String deptId) =>
      tester.widget<MemberSquareCheckBox>(find.descendant(
        of: find.byKey(ValueKey('dept-cb-$deptId')),
        matching: find.byType(MemberSquareCheckBox),
      ));

  testWidgets('部门 subtree 全为 existing → 部门 checkbox 置灰、点击不选;名字仍可展开', (tester) async {
    // 前端组(d2)唯一成员李四(acc-2)已在群 → 该 subtree 无可选成员。
    await _pump(tester, existing: {'acc-2'});
    // 前端组 checkbox 置灰。
    expect(deptCb(tester, 'd2').disabled, isTrue);
    // 技术部仍有张三/周芷涵可选 → 不置灰(回归保护)。
    expect(deptCb(tester, 'd1').disabled, isFalse);
    // 点前端组 checkbox → 不选中任何人。
    await tester.tap(find.byKey(const ValueKey('dept-cb-d2')));
    await tester.pumpAndSettle();
    expect(find.text('选择联系人'), findsOneWidget); // 仍未选
    expect(find.textContaining('已选择'), findsNothing);
    // 点前端组名字 → 仍能展开,看到里面置灰的李四。
    await tester.tap(find.text('前端组'));
    await tester.pumpAndSettle();
    expect(find.text('李四'), findsOneWidget);
  });

  testWidgets('正常部门 checkbox 仍可勾选整棵 subtree(回归)', (tester) async {
    await _pump(tester); // 无 existing
    expect(deptCb(tester, 'd1').disabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('dept-cb-d1')));
    await tester.pumpAndSettle();
    // 技术部 subtree = 张三 + 周芷涵 + 李四 = 3。
    expect(find.text('已选择3个联系人'), findsOneWidget);
  });

  testWidgets('提交按 kind 拆分 human/agent', (tester) async {
    AddGroupMembersResult? popped;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                popped = await showDialog<AddGroupMembersResult>(
                  context: ctx,
                  builder: (_) => const AddGroupMembersDialog(
                    contactsService: _TreeFakeService(),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('陈启航')); // agent (section)
    await tester.pump();
    await tester.tap(find.text('张三')); // human (技术部)
    await tester.pump();
    await tester.tap(find.textContaining('添加（'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.accountUuids, ['acc-1']);
    expect(popped!.agentUuids, ['de-2']);
  });
}
