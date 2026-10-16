import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/create_group_dialog.dart';
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

ContactDepartment _dept(String id, String name, String parent) =>
    ContactDepartment(
      id: id,
      name: name,
      parentId: parent,
      depth: 0,
      humanCount: 0,
      agentCount: 0,
      children: const [],
    );

/// 假 ContactsService —— 1 human + 1 agent，不打网络（保留原 doc-13 §B 用例）。
class _FakeContactsService extends ContactsService {
  const _FakeContactsService();

  @override
  Future<List<ContactDepartment>> tree() async => const [];

  @override
  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    if (kind == 'agent') {
      return [
        _person(kind: 'agent', id: 'de-1', name: '周芷涵', position: '合同审阅顾问')
      ];
    }
    return [_person(kind: 'human', id: 'acc-1', name: '张三')];
  }
}

/// 带两级部门 + 部门内数字员工的假服务:
///   技术部(d1) ├─ 张三(human) + 周芷涵(agent)
///             └─ 前端组(d2) ── 李四(human)
///   数字员工分区:周芷涵(部门内) + 陈启航(无部门)
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
        _person(
            kind: 'agent',
            id: 'de-1',
            name: '周芷涵',
            position: '合同审阅顾问',
            department: '技术部'),
        _person(kind: 'agent', id: 'de-2', name: '陈启航', department: ''),
      ];
    }
    return [
      _person(kind: 'human', id: 'acc-1', name: '张三', department: '技术部'),
      _person(kind: 'human', id: 'acc-2', name: '李四', department: '前端组'),
    ];
  }
}

class _SelfFakeService extends ContactsService {
  const _SelfFakeService();

  @override
  Future<List<ContactDepartment>> tree() async => [_dept('d1', '科技中心', '')];

  @override
  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    if (kind == 'agent') {
      return [
        _person(kind: 'agent', id: 'de-1', name: '周芷涵', department: '科技中心')
      ];
    }
    return [
      _person(kind: 'human', id: 'self-1', name: '李娜', department: '科技中心'),
      _person(kind: 'human', id: 'acc-1', name: '张三', department: '科技中心'),
    ];
  }
}

Future<void> _pump(
  WidgetTester tester, {
  ContactsService? svc,
  String? currentAccountUuid,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CreateGroupDialog(
        contactsService: svc ?? const _TreeFakeService(),
        currentAccountUuid: currentAccountUuid,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('群聊成立按总参与者计数，不要求额外人类成员', () {
    expect(hasMinimumGroupInvitees(0), isFalse);
    expect(hasMinimumGroupInvitees(1), isFalse);
    expect(hasMinimumGroupInvitees(2), isTrue);
    expect(hasMinimumGroupInvitees(5), isTrue);
  });

  testWidgets('数字员工分区 + agent tag + human（doc-13 §B 保留）', (tester) async {
    await _pump(tester, svc: const _FakeContactsService());
    expect(find.text('数字员工'), findsOneWidget);
    expect(find.text('周芷涵'), findsOneWidget);
    expect(find.text('合同审阅顾问'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('智能机器人'), findsNothing);
  });

  testWidgets('默认顶层部门展开、二级部门折叠', (tester) async {
    await _pump(tester);
    expect(find.text('技术部'), findsOneWidget); // 顶层部门行
    expect(find.text('前端组'), findsOneWidget); // 二级部门行(顶层展开可见)
    expect(find.text('张三'), findsOneWidget); // 技术部展开 → human 可见
    expect(find.text('李四'), findsNothing); // 前端组默认折叠 → 不可见
  });

  testWidgets('点击二级部门名展开 → 显示其成员', (tester) async {
    await _pump(tester);
    expect(find.text('李四'), findsNothing);
    await tester.tap(find.text('前端组'));
    await tester.pumpAndSettle();
    expect(find.text('李四'), findsOneWidget);
  });

  testWidgets('点击部门名只折叠/展开，不改变选中', (tester) async {
    await _pump(tester);
    expect(find.text('选择联系人'), findsOneWidget); // 未选
    await tester.tap(find.text('技术部')); // 折叠顶层
    await tester.pumpAndSettle();
    expect(find.text('张三'), findsNothing); // 已折叠
    expect(find.text('选择联系人'), findsOneWidget); // 选中未变(没误勾)
    expect(find.textContaining('已选择'), findsNothing);
  });

  testWidgets('点击部门 checkbox 才勾选整棵 subtree', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('dept-cb-d1')));
    await tester.pumpAndSettle();
    // 技术部 subtree = 张三 + 周芷涵 + 李四(前端组) = 3 个唯一 id（周芷涵 section/tree 同 id 只算一次）。
    expect(find.text('已选择3个联系人'), findsOneWidget);
  });

  testWidgets('数字员工分区可折叠/展开', (tester) async {
    await _pump(tester);
    expect(find.text('陈启航'), findsOneWidget); // section 内（无部门 agent）
    await tester.tap(find.byKey(const ValueKey('member-agent-section-header')));
    await tester.pumpAndSettle();
    expect(find.text('陈启航'), findsNothing); // 折叠后隐藏
    expect(find.text('周芷涵'), findsOneWidget); // 仍在技术部 tree 下
    await tester.tap(find.byKey(const ValueKey('member-agent-section-header')));
    await tester.pumpAndSettle();
    expect(find.text('陈启航'), findsOneWidget); // 重新展开
  });

  testWidgets('部门 tree 同时显示该部门的数字员工', (tester) async {
    await _pump(tester);
    // 周芷涵 同时在 数字员工分区 + 技术部 tree → 出现 2 次。
    expect(find.text('周芷涵'), findsNWidgets(2));
  });

  testWidgets('section 与 tree 中同一 agent 勾选同步，右侧只一次', (tester) async {
    await _pump(tester);
    expect(find.text('周芷涵'), findsNWidgets(2));
    await tester.tap(find.text('周芷涵').first); // 点 section 里的周芷涵
    await tester.pumpAndSettle();
    expect(find.text('已选择1个联系人'), findsOneWidget); // 去重 → 1
    // 左侧 2 行 + 右侧已选 1 行 = 3。
    expect(find.text('周芷涵'), findsNWidgets(3));
  });

  testWidgets('发起群聊禁选当前登录人，部门全选不包含自己', (tester) async {
    await _pump(
      tester,
      svc: const _SelfFakeService(),
      currentAccountUuid: 'self-1',
    );

    expect(find.text('李娜'), findsOneWidget);
    expect(find.text('自己'), findsOneWidget);

    await tester.tap(find.text('李娜'));
    await tester.pumpAndSettle();
    expect(find.text('不能选择自己，发起人会自动加入群聊'), findsOneWidget);
    expect(find.text('选择联系人'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dept-cb-d1')));
    await tester.pumpAndSettle();

    expect(find.text('已选择2个联系人'), findsOneWidget);
    expect(find.text('张三'), findsNWidgets(2)); // 左侧 + 右侧
    expect(find.text('周芷涵'), findsNWidgets(3)); // section + tree + 右侧
    expect(find.text('李娜'), findsOneWidget); // 自己只在左侧, 未进入右侧
  });
}
