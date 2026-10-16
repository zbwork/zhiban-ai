import 'dart:async';

import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:riverpod/riverpod.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/contacts/contacts_directory_store.dart';

/// 生产环境下唯一的规范实例——`const ContactsService()` 在 Dart 里是编译期
/// 常量, 所有未加限定符的 `const ContactsService()` 表达式都指向同一个对象,
/// 所以能用 `identical()` 判断 [contactsServiceProvider] 是否被 override 过
/// (测试用 `overrideWithValue` 传入的假实现绝不会跟这个常量恒等)。
const _defaultContactsService = ContactsService();

final contactsServiceProvider =
    Provider<ContactsService>((_) => _defaultContactsService);

/// [ContactsDirectoryStore] 的 Riverpod 入口。生产环境(未 override
/// contactsServiceProvider)路由到跨入口共享的全局单例([ContactsDirectoryStore]
/// .instance——通讯录侧栏、发起群聊、加群成员三处入口都读这一份数据)；
/// 测试 override 了 contactsServiceProvider 时给一个独立、不落盘的实例,
/// 避免假数据污染磁盘缓存或串到其它用例。
final contactsDirectoryStoreProvider = Provider<ContactsDirectoryStore>((
  ref
) {
  final service = ref.watch(contactsServiceProvider);
  if (identical(service, _defaultContactsService)) {
    return ContactsDirectoryStore.instance;
  }
  return ContactsDirectoryStore.forService(service);
});

final contactsKeywordProvider = StateProvider<String>((_) => '');

const contactsCacheStaleTime = Duration(seconds: 120);

enum ContactsCacheEntry { agents }

final contactsCacheNowProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

final _contactsFetchedAtProvider =
    StateProvider<Map<ContactsCacheEntry, DateTime>>((_) => const {});

final contactsCacheRefreshProvider = Provider<ContactsCacheRefresh>(
  (ref) => ContactsCacheRefresh(ref),
);

class ContactsCacheRefresh {
  ContactsCacheRefresh(this._ref);

  final Ref _ref;

  /// 通讯录页 / 发起群聊等入口每次打开都调这个:部门树 + 成员走共用的
  /// [ContactsDirectoryStore]，无条件后台重新拉一遍全量数据（内容有差异
  /// 才会真的落盘 + 通知刷新，参见 store 内部 diff 逻辑）；数字员工广场
  /// (`contactAgentsProvider`) 仍走原来 120s 过期判定，两者数据形态不同、
  /// 不共用同一份快照。
  void refreshStale() {
    // ignore: discarded_futures
    _ref.read(contactsDirectoryStoreProvider).refreshInBackground();

    final now = _ref.read(contactsCacheNowProvider)();
    final fetchedAt = _ref.read(_contactsFetchedAtProvider);
    if (_isStale(fetchedAt[ContactsCacheEntry.agents], now)) {
      _ref.invalidate(contactAgentsProvider);
    }
  }

  bool _isStale(DateTime? fetchedAt, DateTime now) {
    if (fetchedAt == null) return false;
    return !now.difference(fetchedAt).isNegative &&
        now.difference(fetchedAt) >= contactsCacheStaleTime;
  }
}

Future<T> _markContactCacheFetched<T>(
  Ref ref,
  ContactsCacheEntry entry,
  Future<T> future,
) async {
  final value = await future;
  final now = ref.read(contactsCacheNowProvider)();
  ref.read(_contactsFetchedAtProvider.notifier).update(
        (state) => {
          ...state,
          entry: now
        }
      );
  return value;
}

/// 通讯录 + 发起群聊/加人共用的本地快照。三处入口(通讯录侧栏、
/// CreateGroupDialog、AddGroupMembersDialog)都从这一份数据派生, 不再各自
/// 发请求; store 自带"内存 > 磁盘缓存 > 网络"三级兜底 + 后台刷新。
///
/// 用 StreamProvider 而不是 FutureProvider: store 的后台 refresh() 完成后只更新
/// 自己的 ValueNotifier, 不会主动通知 Riverpod——必须桥接 notifier 的变化到
/// stream, 界面才能在"内容有差异"时自动重建, 而不是永远停在第一次拿到的快照。
final contactsDirectorySnapshotProvider =
    StreamProvider<ContactsDirectorySnapshot>((ref) {
  final store = ref.watch(contactsDirectoryStoreProvider);
  final controller = StreamController<ContactsDirectorySnapshot>();

  void emitCurrent() {
    final v = store.notifier.value;
    if (v != null && !controller.isClosed) controller.add(v);
  }

  store.notifier.addListener(emitCurrent);
  ref.onDispose(() {
    store.notifier.removeListener(emitCurrent);
    controller.close();
  });

  // ignore: discarded_futures
  store.ensureLoaded().then((v) {
    if (!controller.isClosed) controller.add(v);
  }, onError: (Object error, StackTrace stack) {
    if (!controller.isClosed) controller.addError(error, stack);
  });

  return controller.stream;
});

final contactTreeProvider = FutureProvider<List<ContactDepartment>>((
  ref,
) async {
  final snapshot = await ref.watch(contactsDirectorySnapshotProvider.future);
  return snapshot.tree;
});

final selectedContactDepartmentProvider =
    StateProvider<ContactDepartment?>((_) => null);

/// 选中部门(或未选中=全部)的成员列表, 本地按 departmentId 过滤 + 关键字过滤,
/// 不再单独发网络请求。
final contactMembersProvider = FutureProvider<List<ContactPerson>>((
  ref
) async {
  final snapshot = await ref.watch(contactsDirectorySnapshotProvider.future);
  final selected = ref.watch(selectedContactDepartmentProvider);
  final keyword = ref.watch(contactsKeywordProvider).trim().toLowerCase();
  final deptId = selected?.id ?? '';
  final all = deptId.isEmpty
      ? [...snapshot.humans, ...snapshot.agents]
      : snapshot.peopleForDepartment(deptId);
  if (keyword.isEmpty) return all;
  return all.where((p) => _matchesKeyword(p, keyword)).toList(
        growable: false
      );
});

// 组织树下挂的成员: human + agent 都拉(kind 走 service 默认 'all'), UI 端按 isAgent 区分.
final contactDepartmentMembersProvider =
    FutureProvider.family<List<ContactPerson>, String>((ref, id) async {
  final snapshot = await ref.watch(contactsDirectorySnapshotProvider.future);
  final keyword = ref.watch(contactsKeywordProvider).trim().toLowerCase();
  final people = snapshot.peopleForDepartment(id);
  if (keyword.isEmpty) return people;
  return people.where((p) => _matchesKeyword(p, keyword)).toList(
        growable: false
      );
});

/// 手机部门内容使用自己的查询条件，避免根页搜索词限制部门内再次搜索。
/// 仍只读取当前账号/租户已经授权的通讯录快照。
final contactMobileDepartmentMembersProvider = FutureProvider.autoDispose
    .family<List<ContactPerson>, ({String departmentId, String keyword})>(
        (ref, query) async {
  final snapshot = await ref.watch(contactsDirectorySnapshotProvider.future);
  final people = snapshot.peopleForDepartment(query.departmentId);
  final keyword = query.keyword.trim().toLowerCase();
  return keyword.isEmpty
      ? people
      : people
          .where((p) => _matchesKeyword(p, keyword))
          .toList(growable: false);
});

bool _matchesKeyword(ContactPerson p, String keyword) {
  return p.displayName.toLowerCase().contains(keyword) ||
      p.subtitle.toLowerCase().contains(keyword) ||
      p.departmentName.toLowerCase().contains(keyword);
}

/// 搜索时用于隐藏"命中数为 0"的部门节点。关键字非空时，对整棵部门树按
/// [contactDepartmentMembersProvider] 预取各节点的关键字匹配结果（与
/// `_DepartmentTile` 渲染时用的是同一个 provider，不会重复请求），自底向上
/// 算出"自身有匹配 或 子树有匹配"的部门 id 集合。关键字为空时返回 null
/// （不过滤，展示全部）。
final contactSearchVisibleDepartmentIdsProvider =
    FutureProvider<Set<String>?>((ref) async {
  final keyword = ref.watch(contactsKeywordProvider).trim();
  if (keyword.isEmpty) return null;
  final tree = await ref.watch(contactTreeProvider.future);
  final visible = <String>{};

  Future<bool> visit(ContactDepartment dept) async {
    final ownMembersFuture =
        ref.watch(contactDepartmentMembersProvider(dept.id).future);
    final childResults = await Future.wait(dept.children.map(visit));
    final ownMembers = await ownMembersFuture;
    final hasMatch = ownMembers.isNotEmpty || childResults.any((v) => v);
    if (hasMatch) visible.add(dept.id);
    return hasMatch;
  }

  await Future.wait(tree.map(visit));
  return visible;
});

final contactAgentsProvider = FutureProvider<ContactAgentsSnapshot>((ref) {
  final keyword = ref.watch(contactsKeywordProvider);
  return _markContactCacheFetched(
    ref,
    ContactsCacheEntry.agents,
    ref.read(contactsServiceProvider).agents(keyword: keyword),
  );
});
