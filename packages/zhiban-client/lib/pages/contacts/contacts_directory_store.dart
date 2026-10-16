import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通讯录 + 发起群聊/加人 共用的本地快照:部门树(扁平) + 全量 human/agent。
/// 一次拉全, 按部门 id 分组匹配(不再按名字字符串), 不会因为 100 条上限
/// 截断或重名部门互相串人。
class ContactsDirectorySnapshot {
  const ContactsDirectorySnapshot({
    required this.departments,
    required this.humans,
    required this.agents,
    required this.fetchedAt,
  });

  final List<ContactDepartment> departments; // 扁平, 未组树
  final List<ContactPerson> humans;
  final List<ContactPerson> agents;
  final DateTime fetchedAt;

  List<ContactDepartment> get tree => buildContactDepartmentTree(departments);

  List<ContactPerson> peopleForDepartment(String departmentId) {
    if (departmentId.isEmpty) return const <ContactPerson>[];
    return [
      ...humans.where((p) => p.departmentId == departmentId),
      ...agents.where((p) => p.departmentId == departmentId),
    ];
  }

  Map<String, dynamic> toJson() => {
        'departments': departments.map((d) => d.toJson()).toList(),
        'humans': humans.map((p) => p.toJson()).toList(),
        'agents': agents.map((p) => p.toJson()).toList(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  static ContactsDirectorySnapshot? tryFromJson(Map<String, dynamic> json) {
    try {
      final departments = (json['departments'] as List)
          .whereType<Map>()
          .map((e) => ContactDepartment.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
      final humans = (json['humans'] as List)
          .whereType<Map>()
          .map((e) => ContactPerson.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
      final agents = (json['agents'] as List)
          .whereType<Map>()
          .map((e) => ContactPerson.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
      final fetchedAt =
          DateTime.tryParse((json['fetchedAt'] ?? '').toString()) ??
              DateTime.now();
      return ContactsDirectorySnapshot(
        departments: departments,
        humans: humans,
        agents: agents,
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      return null; // 缓存格式损坏/版本不兼容, 当没有缓存处理, 走网络冷启动。
    }
  }

  /// 业务内容是否相同(忽略 fetchedAt)。拉新数据后据此判断要不要真的落盘 +
  /// 通知刷新, 内容没变就跳过, 避免无意义的 setState/磁盘写入。
  bool sameContentAs(ContactsDirectorySnapshot other) {
    return jsonEncode(_contentOnlyJson()) ==
        jsonEncode(other._contentOnlyJson());
  }

  Map<String, dynamic> _contentOnlyJson() => {
        'departments': departments.map((d) => d.toJson()).toList(),
        'humans': humans.map((p) => p.toJson()).toList(),
        'agents': agents.map((p) => p.toJson()).toList(),
      };
}

/// 单例:通讯录 / 发起群聊 / 加群成员 三个入口共用同一份数据。
/// 策略:先给已有数据(内存 > 磁盘缓存), 界面先展示; 同时后台重新拉取真实数据,
/// 内容有差异才落盘 + 通知监听方刷新展示。
class ContactsDirectoryStore {
  ContactsDirectoryStore._(this._service, {bool persistToDisk = true})
      : _persistToDisk = persistToDisk;

  /// 全局单例:通讯录侧栏 + 发起群聊 + 加群成员三处入口在生产环境下真正共用
  /// 的那一份(落盘缓存 + 内存都共享)。
  static final ContactsDirectoryStore instance =
      ContactsDirectoryStore._(const ContactsService());

  /// 测试 / Provider 覆盖专用:每次调用给一个独立实例(不落盘、不跟全局单例
  /// 共享内存),避免测试注入的假 ContactsService 污染生产单例的磁盘缓存,
  /// 也避免多个测试用例互相串数据。
  factory ContactsDirectoryStore.forService(ContactsService service) =>
      ContactsDirectoryStore._(service, persistToDisk: false);

  final ContactsService _service;
  final bool _persistToDisk;

  /// 当前快照; 变化时触发监听方(Riverpod provider / 手动 addListener)刷新。
  final ValueNotifier<ContactsDirectorySnapshot?> notifier = ValueNotifier(
    null,
  );

  ContactsDirectorySnapshot? get current => notifier.value;

  bool _diskLoadAttempted = false;
  Future<ContactsDirectorySnapshot>? _inFlight;

  /// 需要数据时调用:有内存快照直接返回(同时后台刷新一次); 没有则先尝试磁盘
  /// 缓存(有则先用, 仍旧后台刷新); 磁盘也没有(真正冷启动/首次登录)才等网络。
  Future<ContactsDirectorySnapshot> ensureLoaded() async {
    final mem = notifier.value;
    if (mem != null) {
      refreshInBackground();
      return mem;
    }
    if (!_diskLoadAttempted) {
      _diskLoadAttempted = true;
      final cached = await _loadFromDisk();
      if (cached != null) {
        notifier.value = cached;
        refreshInBackground();
        return cached;
      }
    }
    return refresh();
  }

  /// 强制重新拉取全量数据。多处并发调用时共用同一个 in-flight Future,
  /// 不会因为通讯录页 + 发起群聊弹窗同时打开而各打一遍请求。
  Future<ContactsDirectorySnapshot> refresh() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  void refreshInBackground() {
    unawaited(refresh().then<void>((_) {}, onError: (Object error, StackTrace stack) {
      // HTTP failures have already been logged/reported by the interceptor.
      debugPrint('[ContactsDirectory] background refresh failed: ${error.runtimeType}');
    }));
  }

  static const int _fetchConcurrency = 8;

  /// 后端 `/contacts` 的 cursor 分页没有真正实现(收到非空 cursor 只是忽略,
  /// 不报错——见 contacts/service.go List() 注释), 不限部门直接拉 kind=human
  /// 全量只会拿到按名字排序的前 100/200 条, 几千人的租户里后面的人全部丢失
  /// (2026-08-19 真实数据踩过: 唐宁排不进前 100, 通讯录里人就消失了)。
  /// 只能按部门 id 分别查(每个部门天然人少, 不会撞上限), 只查有直属成员的
  /// 部门(tree 已经给了 humanCount/agentCount, 都是 0 的部门跳过, 不用挨个
  /// 打空请求), 有限并发(8 个)避免几百个部门瞬间打满连接。
  Future<ContactsDirectorySnapshot> _doRefresh() async {
    final depts = await _service.tree();
    final withMembers =
        depts.where((d) => d.humanCount > 0 || d.agentCount > 0).toList();

    final humans = <ContactPerson>[];
    final agents = <ContactPerson>[];
    final sem = <Future<void>>[];
    var index = 0;

    Future<void> worker() async {
      while (index < withMembers.length) {
        final dept = withMembers[index++];
        final people = await _service.members(
          departmentId: dept.id,
          kind: 'all',
        );
        for (final p in people) {
          if (p.isAgent) {
            agents.add(p);
          } else {
            humans.add(p);
          }
        }
      }
    }

    for (var i = 0; i < _fetchConcurrency; i++) {
      sem.add(worker());
    }
    await Future.wait(sem);

    // agent 常无部门(独立数字员工), 上面按部门查不到——单独兜底拉一次不限部门
    // 的 kind=agent(数字员工总数通常远小于人数, 触发同一个 100 条上限的概率
    // 低很多; 真撞上限也只是"数字员工"分区显示不全, 不会像人员那样整个部门
    // 的人消失)。按 id 去重, 避免部门内已经拿到的重复加一遍。
    final noDeptAgents = await _service.members(kind: 'agent');
    final existingAgentIds = agents.map((a) => a.id).toSet();
    agents.addAll(
      noDeptAgents.where((a) => !existingAgentIds.contains(a.id))
    );

    final fresh = ContactsDirectorySnapshot(
      departments: depts,
      humans: humans,
      agents: agents,
      fetchedAt: DateTime.now(),
    );
    final prev = notifier.value;
    if (prev == null || !fresh.sameContentAs(prev)) {
      notifier.value = fresh;
      unawaited(_saveToDisk(fresh));
      return fresh;
    }
    return prev;
  }

  Future<ContactsDirectorySnapshot?> _loadFromDisk() async {
    if (!_persistToDisk) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConfig.storageContactsDirectoryKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ContactsDirectorySnapshot.tryFromJson(
        decoded.cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToDisk(ContactsDirectorySnapshot snapshot) async {
    if (!_persistToDisk) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AppConfig.storageContactsDirectoryKey,
        jsonEncode(snapshot.toJson()),
      );
    } catch (_) {
      // 落盘失败不影响本次内存态展示, 下次 refresh 再试。
    }
  }

  /// 登出清空:内存 + 磁盘都清, 避免下个账号登录后瞬间看到上个租户的通讯录残留。
  Future<void> clear() async {
    notifier.value = null;
    _diskLoadAttempted = false;
    if (!_persistToDisk) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConfig.storageContactsDirectoryKey);
    } catch (_) {}
  }
}
