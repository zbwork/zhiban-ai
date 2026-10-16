import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';

class _CountingContactsService extends ContactsService {
  int treeCalls = 0;
  int membersCalls = 0; // 按部门 id 查(有直属成员的部门各一次) + 不限部门 kind=agent 兜底一次
  int agentsCalls = 0;

  @override
  Future<List<ContactDepartment>> tree() async {
    treeCalls += 1;
    return const [
      ContactDepartment(
        id: 'dept-tech',
        name: '科技中心',
        parentId: '',
        depth: 0,
        humanCount: 1, // 有直属成员 → ContactsDirectoryStore 会查这个部门
        agentCount: 0,
        children: [],
      ),
    ];
  }

  @override
  Future<ContactAgentsSnapshot> agents({String keyword = ''}) async {
    agentsCalls += 1;
    return const ContactAgentsSnapshot(
      personal: [],
      enterprise: [],
      platform: [],
    );
  }

  @override
  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    membersCalls += 1;
    return const [];
  }
}

void main() {
  // 通讯录(部门树 + 成员)现在走 ContactsDirectoryStore:每次
  // contactsCacheRefreshProvider.refreshStale() 都无条件后台重新拉一遍全量数据
  // ("每次打开再拉一遍"), 不再像数字员工广场(contactAgentsProvider)那样按
  // 120s 过期才重拉——两者数据形态/更新频率诉求不同, 故意分开处理。
  test('directory store loads tree/members once on first read', () async {
    final service = _CountingContactsService();
    final container = ProviderContainer(
      overrides: [contactsServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final treeSubscription = container.listen(
      contactTreeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(contactTreeProvider.future);
    treeSubscription.close();

    expect(service.treeCalls, 1);
    // 1 个有成员的部门(dept-tech) + 1 次不限部门 kind=agent 兜底 = 2。
    expect(service.membersCalls, 2);
  });

  test('refreshStale unconditionally refetches directory store data', () async {
    final service = _CountingContactsService();
    final container = ProviderContainer(
      overrides: [contactsServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final treeSubscription = container.listen(
      contactTreeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(contactTreeProvider.future);

    container.read(contactsCacheRefreshProvider).refreshStale();
    // refresh() 是异步的(先拉 tree, 再并发拉各部门成员), 让事件循环跑完。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    treeSubscription.close();

    expect(service.treeCalls, 2);
    expect(service.membersCalls, 4);
  });

  test('contactAgentsProvider keeps cached data inside 120s stale time', () async {
    var now = DateTime(2026, 6, 3, 10);
    final service = _CountingContactsService();
    final container = ProviderContainer(
      overrides: [
        contactsServiceProvider.overrideWithValue(service),
        contactsCacheNowProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);

    final agentsSubscription = container.listen(
      contactAgentsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(contactAgentsProvider.future);
    agentsSubscription.close();

    now = now.add(contactsCacheStaleTime - const Duration(seconds: 1));
    container.read(contactsCacheRefreshProvider).refreshStale();
    await Future<void>.delayed(Duration.zero);
    expect(service.agentsCalls, 1); // 还没到 120s, 不重拉。

    now = now.add(const Duration(seconds: 2));
    container.read(contactsCacheRefreshProvider).refreshStale();

    final secondAgentsSubscription = container.listen(
      contactAgentsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(contactAgentsProvider.future);
    secondAgentsSubscription.close();

    expect(service.agentsCalls, 2);
  });
}
