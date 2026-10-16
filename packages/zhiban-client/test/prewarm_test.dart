import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_group.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_task.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';
import 'package:zhiban_client/pages/runtime_prewarm/services/prewarm_service.dart';
import 'package:zhiban_client/pages/runtime_prewarm/widgets/prewarm_overlay.dart';

PrewarmTask _mk(
  String kind, {
  String? de,
  String? deName,
  String? slug,
  String status = 'running',
  String env = 'OpenClaw 工作负载服务',
  String uuid = 'u',
}) =>
    PrewarmTask.fromJson({
      'uuid': uuid,
      'task_kind': kind,
      'status': status,
      'runtime_environment_uuid': 'env-uuid',
      'runtime_environment_name': env,
      if (de != null) 'digital_employee_uuid': de,
      if (deName != null) 'digital_employee_name': deName,
      if (slug != null) 'skill_slug': slug,
    });

/// 注入固定 state 的预热控制器 (widget 测试用, 不挂 timer)。
class _FixedPrewarmController extends PrewarmController {
  _FixedPrewarmController(this._fixed);
  final PrewarmState _fixed;
  @override
  PrewarmState build() => _fixed;
}

/// 假预热 service: ensure 返回固定结果; 记录 listTasks 调用次数 (验证"无 active → 不轮询")。
class _FakePrewarmService extends PrewarmService {
  _FakePrewarmService(this.result);
  final PrewarmEnsureResult result;
  int ensureCalls = 0;
  int listTasksCalls = 0;
  @override
  Future<PrewarmEnsureResult> ensure() async {
    ensureCalls++;
    return result;
  }

  @override
  Future<List<PrewarmTask>> listTasks() async {
    listTasksCalls++;
    return result.tasks;
  }
}

class _MutablePrewarmService extends PrewarmService {
  _MutablePrewarmService({
    required this.ensureResult,
    required this.taskSnapshot,
  });

  PrewarmEnsureResult ensureResult;
  List<PrewarmTask> taskSnapshot;
  bool failListTasks = false;
  int listTasksCalls = 0;

  @override
  Future<PrewarmEnsureResult> ensure() async => ensureResult;

  @override
  Future<List<PrewarmTask>> listTasks() async {
    listTasksCalls++;
    if (failListTasks) {
      throw StateError('list tasks failed');
    }
    return taskSnapshot;
  }
}

class _PendingPrewarmService extends PrewarmService {
  final Completer<PrewarmEnsureResult> completer =
      Completer<PrewarmEnsureResult>();
  int listTasksCalls = 0;

  @override
  Future<PrewarmEnsureResult> ensure() => completer.future;

  @override
  Future<List<PrewarmTask>> listTasks() async {
    listTasksCalls++;
    return const <PrewarmTask>[];
  }
}

void main() {
  group('prewarmTitle (degraded 不撒谎; 一级用进度条, 标题不带 x/y 计数)', () {
    test('active → 正在准备运行环境 (无计数)', () {
      final t =
          prewarmTitle(hasActive: true, hasFailed: false, degraded: false);
      expect(t, '正在准备运行环境');
      expect(t.contains('/'), isFalse);
    });

    test('ensure 请求中且尚无任务 → 正在准备运行环境', () {
      final t = prewarmTitle(
        hasActive: false,
        hasFailed: false,
        degraded: false,
        isEnsuring: true,
      );
      expect(t, '正在准备运行环境');
    });

    test('failed → 部分准备失败', () {
      expect(
        prewarmTitle(hasActive: false, hasFailed: true, degraded: false),
        '部分准备失败',
      );
    });

    test('degraded 且无 active/failed → 已转为按需初始化 (不是已就绪)', () {
      final title =
          prewarmTitle(hasActive: false, hasFailed: false, degraded: true);
      expect(title, '已转为按需初始化');
      expect(title.contains('就绪'), isFalse);
    });

    test('全 succeeded 无 degraded → 已就绪', () {
      expect(
        prewarmTitle(hasActive: false, hasFailed: false, degraded: false),
        '运行环境已就绪',
      );
    });

    test('active 优先于 degraded', () {
      expect(
        prewarmTitle(hasActive: true, hasFailed: false, degraded: true),
        '正在准备运行环境',
      );
    });
  });

  group('PrewarmTask.fromJson', () {
    test('agent_register 带 digital_employee_name + 状态解析', () {
      final t = PrewarmTask.fromJson(const {
        'uuid': 'u1',
        'task_kind': 'agent_register',
        'status': 'waiting_instance',
        'runtime_environment_uuid': 'env-uuid',
        'runtime_environment_name': '客服 Runtime',
        'digital_employee_uuid': 'de1',
        'digital_employee_name': '客服接待员',
      });
      expect(t.isAgentRegister, isTrue);
      expect(t.status, PrewarmTaskStatus.waitingInstance);
      expect(t.displayTitle, '客服接待员'); // agent_register 用数字员工名
      expect(t.status.isTerminal, isFalse);
    });

    test('instance_init displayTitle 用环境名; succeeded 终态', () {
      final t = PrewarmTask.fromJson(const {
        'uuid': 'u2',
        'task_kind': 'instance_init',
        'status': 'succeeded',
        'runtime_environment_uuid': 'env-uuid',
        'runtime_environment_name': '客服 Runtime',
      });
      expect(t.displayTitle, '客服 Runtime');
      expect(t.status.isTerminal, isTrue);
      expect(t.digitalEmployeeName, isNull);
    });

    test('未知 status → unknown, 不崩', () {
      final t = PrewarmTask.fromJson(const {
        'uuid': 'u3',
        'task_kind': 'instance_init',
        'status': 'weird',
        'runtime_environment_uuid': '',
        'runtime_environment_name': '',
      });
      expect(t.status, PrewarmTaskStatus.unknown);
      expect(t.displayTitle, '运行环境'); // 环境名空时兜底
    });
  });

  group('PrewarmTask 按 task_kind 分流 title/subtitle', () {
    PrewarmTask mk(String kind,
            {String? de, String? slug, String env = 'OpenClaw 工作负载服务'}) =>
        PrewarmTask.fromJson({
          'uuid': 'u',
          'task_kind': kind,
          'status': 'succeeded',
          'runtime_environment_uuid': 'env-uuid',
          'runtime_environment_name': env,
          if (de != null) 'digital_employee_name': de,
          if (de != null) 'digital_employee_uuid': 'de-uuid',
          if (slug != null) 'skill_slug': slug,
        });

    test('instance_init → 标题=环境名, 副标题=运行实例', () {
      final t = mk('instance_init');
      expect(t.kind, PrewarmTaskKind.instanceInit);
      expect(t.displayTitle, 'OpenClaw 工作负载服务');
      expect(t.displaySubtitle, '运行实例');
    });

    test('agent_register → 标题=数字员工名, 副标题=数字员工', () {
      final t = mk('agent_register', de: '陈启航');
      expect(t.displayTitle, '陈启航');
      expect(t.displaySubtitle, '数字员工');
    });

    test('skill_register → 副标题=技能安装, 标题=数字员工名 (绝不是 OpenClaw 环境名)', () {
      final t = mk('skill_register', de: '陈启航');
      expect(t.displaySubtitle, '技能安装');
      expect(t.displayTitle, '陈启航');
      expect(t.displayTitle.contains('OpenClaw'), isFalse);
      expect(t.displayTitle.contains('工作负载'), isFalse);
    });

    test('skill_register 带 skill_slug → 标题=员工 · slug', () {
      final t = mk('skill_register', de: '陈启航', slug: 'lead-scoring');
      expect(t.displayTitle, '陈启航 · lead-scoring');
      expect(t.displaySubtitle, '技能安装');
    });

    test('skill_unregister → 副标题=技能卸载, 标题=数字员工名', () {
      final t = mk('skill_unregister', de: '陈启航');
      expect(t.displaySubtitle, '技能卸载');
      expect(t.displayTitle, '陈启航');
    });

    test('未知 task_kind → 副标题=准备任务, 标题优先数字员工名', () {
      final t = mk('something_new', de: '周芷涵');
      expect(t.kind, PrewarmTaskKind.unknown);
      expect(t.displaySubtitle, '准备任务');
      expect(t.displayTitle, '周芷涵');
    });

    test('未知 task_kind 无数字员工 → 标题回退环境名', () {
      final t = mk('something_new');
      expect(t.displayTitle, 'OpenClaw 工作负载服务');
      expect(t.displaySubtitle, '准备任务');
    });
  });

  group('aggregatePrewarmTasks 聚合准备视图 (§5b)', () {
    test('instance_init 聚合为「初始化运行环境」, 子项=运行环境名', () {
      final groups = aggregatePrewarmTasks([
        _mk('instance_init',
            env: 'OpenClaw 工作负载服务', status: 'succeeded', uuid: 'i1'),
      ]);
      expect(groups.length, 1);
      expect(groups.first.kind, PrewarmGroupKind.runtimeInit);
      expect(groups.first.title, '初始化运行环境');
      expect(groups.first.children.single.label, 'OpenClaw 工作负载服务');
    });

    test('同一数字员工 agent_register + 多个 skill_register → 一行「加载数字员工 - 名」', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register',
            de: 'de1', deName: '陈启航', status: 'succeeded', uuid: 'a1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', slug: 'lead-scoring', uuid: 's1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', slug: 'contract-risk', uuid: 's2'),
      ]);
      expect(groups.length, 1);
      expect(groups.first.kind, PrewarmGroupKind.digitalEmployee);
      expect(groups.first.title, '加载数字员工 - 陈启航');
      expect(groups.first.children.length, 3); // 1 注册 + 2 技能
    });

    test('技能只在数字员工展开子项, 不平铺/不进一级标题', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register', de: 'de1', deName: '陈启航', uuid: 'a1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', slug: 'lead-scoring', uuid: 's1'),
      ]);
      final g = groups.single;
      expect(g.title.contains('lead-scoring'), isFalse);
      expect(g.title.contains('技能'), isFalse);
      expect(g.children.first.label, '注册数字员工'); // agent_register 在前
      expect(g.children.any((c) => c.label == '安装技能 · lead-scoring'), isTrue);
    });

    test('skill_unregister → 「更新数字员工」, 子项=卸载技能, 注册子项文案=更新数字员工', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register', de: 'de1', deName: '陈启航', uuid: 'a1'),
        _mk('skill_unregister',
            de: 'de1', deName: '陈启航', slug: 'old-skill', uuid: 'r1'),
      ]);
      final g = groups.single;
      expect(g.title, '更新数字员工 - 陈启航');
      expect(g.children.first.label, '更新数字员工');
      expect(g.children.any((c) => c.label == '卸载技能 · old-skill'), isTrue);
    });

    test('纯技能变更(无 agent_register) → 「更新数字员工」', () {
      final groups = aggregatePrewarmTasks([
        _mk('skill_register',
            de: 'de1', deName: '陈启航', slug: 'new-skill', uuid: 's1'),
      ]);
      expect(groups.single.title, '更新数字员工 - 陈启航');
    });

    test('进度: succeeded+failed 算终态, active 计未完成 → 比例 = 终态/总数', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register',
            de: 'de1', deName: '陈启航', status: 'succeeded', uuid: 'a1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', status: 'failed', slug: 's', uuid: 's1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', status: 'running', slug: 't', uuid: 's2'),
      ]);
      final g = groups.single;
      expect(g.total, 3);
      expect(g.terminalCount, 2); // succeeded + failed 都算终态
      expect(g.progress, closeTo(2 / 3, 1e-9));
    });

    test('failed 子任务 → 一级状态「部分失败」', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register',
            de: 'de1', deName: '陈启航', status: 'succeeded', uuid: 'a1'),
        _mk('skill_register',
            de: 'de1', deName: '陈启航', status: 'failed', slug: 's', uuid: 's1'),
      ]);
      expect(groups.single.statusLabel, '部分失败');
    });

    test('全 succeeded → 「已就绪」+ progress 1.0', () {
      final groups = aggregatePrewarmTasks([
        _mk('instance_init', status: 'succeeded', uuid: 'i1'),
      ]);
      expect(groups.single.statusLabel, '已就绪');
      expect(groups.single.progress, 1.0);
    });

    test('retrying(无 failed) → 「初始化中」', () {
      final groups = aggregatePrewarmTasks([
        _mk('instance_init', status: 'retrying', uuid: 'i1'),
      ]);
      expect(groups.single.statusLabel, '初始化中');
    });

    test('运行环境组恒最前; 多数字员工按首次出现顺序', () {
      final groups = aggregatePrewarmTasks([
        _mk('agent_register', de: 'de2', deName: '许文博', uuid: 'a2'),
        _mk('instance_init', uuid: 'i1'),
        _mk('agent_register', de: 'de1', deName: '陈启航', uuid: 'a1'),
      ]);
      expect(groups[0].kind, PrewarmGroupKind.runtimeInit);
      expect(groups[1].title, '加载数字员工 - 许文博'); // de2 先出现
      expect(groups[2].title, '加载数字员工 - 陈启航');
    });

    test('空任务 → 空分组; 空组 total=0 → 不确定进度, progress null, 不崩', () {
      expect(aggregatePrewarmTasks(const []), isEmpty);
      const g = PrewarmGroup(
        kind: PrewarmGroupKind.runtimeInit,
        key: 'runtime',
        title: '初始化运行环境',
        children: [],
      );
      expect(g.indeterminate, isTrue);
      expect(g.progress, isNull);
    });
  });

  group('PrewarmEnsureResult.fromJson', () {
    test('degraded + skipped_reason + tasks 解析', () {
      final r = PrewarmEnsureResult.fromJson(const {
        'degraded': true,
        'skipped_reason': 'account_queue_full',
        'created': 0,
        'reused': 0,
        'tasks': <dynamic>[],
      });
      expect(r.degraded, isTrue);
      expect(r.skippedReason, 'account_queue_full');
      expect(r.tasks, isEmpty);
    });
  });

  group('PrewarmController 获取/展示时机 (§5b)', () {
    test('阶段开关关闭时 startOnce 和 ensureNow 都不请求云端 runtime', () async {
      final fake = _FakePrewarmService(const PrewarmEnsureResult(
        degraded: false,
        created: 0,
        reused: 0,
        tasks: [],
      ));
      final c = ProviderContainer(
        overrides: [prewarmServiceProvider.overrideWithValue(fake)],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      await c.read(prewarmControllerProvider.notifier).ensureNow();

      expect(fake.ensureCalls, 0);
      expect(fake.listTasksCalls, 0);
      expect(c.read(prewarmControllerProvider).visible, isFalse);
    });

    test('ensure 请求未返回 → 先展示右下角准备中占位', () async {
      final fake = _PendingPrewarmService();
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      final future = c.read(prewarmControllerProvider.notifier).startOnce();
      await Future<void>.delayed(Duration.zero);

      var st = c.read(prewarmControllerProvider);
      expect(st.ensuring, isTrue);
      expect(st.visible, isTrue);
      expect(fake.listTasksCalls, 0);

      fake.completer.complete(const PrewarmEnsureResult(
        degraded: false,
        created: 0,
        reused: 0,
        tasks: [],
      ));
      await future;

      st = c.read(prewarmControllerProvider);
      expect(st.ensuring, isFalse);
      expect(st.visible, isFalse);
      expect(fake.listTasksCalls, 1);
    });

    test('ensure 返回空任务且任务快照也为空 → 浮层不展示、不轮询 (无 actionable)', () async {
      final fake = _FakePrewarmService(const PrewarmEnsureResult(
        degraded: false,
        created: 0,
        reused: 0,
        tasks: [],
      ));
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      final st = c.read(prewarmControllerProvider);
      expect(st.tasks, isEmpty);
      expect(st.visible, isFalse); // 不弹右下角浮层
      expect(fake.listTasksCalls, 1); // 空 ensure 后补拉一次, 用于恢复服务端失败快照
    });

    test('ensure 返回空任务但 /runtime/tasks 有 failed → 重启后恢复右下角失败任务栏', () async {
      final failed = _mk('agent_register',
          de: 'de1', deName: '创小融-创业版', status: 'failed', uuid: 'f1');
      final fake = _MutablePrewarmService(
        ensureResult: const PrewarmEnsureResult(
          degraded: false,
          created: 0,
          reused: 0,
          tasks: [],
        ),
        taskSnapshot: [failed],
      );
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      final st = c.read(prewarmControllerProvider);
      expect(fake.listTasksCalls, 1);
      expect(st.visible, isTrue);
      expect(st.hasFailed, isTrue);
      expect(st.tasks.single.uuid, 'f1');
    });

    test('重新预热返回空且快照也为空 → 清空本地 failed 并隐藏任务栏', () async {
      final failed = _mk('agent_register',
          de: 'de1', deName: '创小融-创业版', status: 'failed', uuid: 'f1');
      final fake = _MutablePrewarmService(
        ensureResult: PrewarmEnsureResult(
          degraded: false,
          created: 1,
          reused: 0,
          tasks: [failed],
        ),
        taskSnapshot: [failed],
      );
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      expect(c.read(prewarmControllerProvider).hasFailed, isTrue);

      fake.ensureResult = const PrewarmEnsureResult(
        degraded: false,
        created: 0,
        reused: 0,
        tasks: [],
      );
      fake.taskSnapshot = const <PrewarmTask>[];

      await c.read(prewarmControllerProvider.notifier).retry();
      final st = c.read(prewarmControllerProvider);
      expect(st.visible, isFalse);
      expect(st.hasFailed, isFalse);
      expect(st.tasks, isEmpty);
    });

    test('重新预热快照拉取失败时才临时保留本地 failed', () async {
      final failed = _mk('agent_register',
          de: 'de1', deName: '创小融-创业版', status: 'failed', uuid: 'f1');
      final fake = _MutablePrewarmService(
        ensureResult: PrewarmEnsureResult(
          degraded: false,
          created: 1,
          reused: 0,
          tasks: [failed],
        ),
        taskSnapshot: [failed],
      );
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      expect(c.read(prewarmControllerProvider).hasFailed, isTrue);

      fake.ensureResult = const PrewarmEnsureResult(
        degraded: false,
        created: 0,
        reused: 0,
        tasks: [],
      );
      fake.failListTasks = true;

      await c.read(prewarmControllerProvider.notifier).retry();
      final st = c.read(prewarmControllerProvider);
      expect(st.visible, isTrue);
      expect(st.hasFailed, isTrue);
      expect(st.tasks.single.uuid, 'f1');
    });

    test('ensure 返回 active 任务 → 浮层展示且进入轮询态', () async {
      final fake = _FakePrewarmService(PrewarmEnsureResult(
        degraded: false,
        created: 1,
        reused: 0,
        tasks: [
          _mk('agent_register', de: 'de1', deName: '陈启航', status: 'running')
        ],
      ));
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      final st = c.read(prewarmControllerProvider);
      expect(st.visible, isTrue);
      expect(st.hasActive, isTrue); // 有 active → _startPolling 启动轮询
    });

    test('手动收起不关闭任务; 可再次展开', () async {
      final fake = _FakePrewarmService(PrewarmEnsureResult(
        degraded: false,
        created: 1,
        reused: 0,
        tasks: [
          _mk('agent_register', de: 'de1', deName: '陈启航', status: 'running')
        ],
      ));
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(c.dispose);

      await c.read(prewarmControllerProvider.notifier).startOnce();
      c.read(prewarmControllerProvider.notifier).collapse();

      var st = c.read(prewarmControllerProvider);
      expect(st.visible, isTrue);
      expect(st.collapsed, isTrue);
      expect(st.hasActive, isTrue);

      c.read(prewarmControllerProvider.notifier).expand();
      st = c.read(prewarmControllerProvider);
      expect(st.visible, isTrue);
      expect(st.collapsed, isFalse);
    });

    test('ensure 返回前 provider 被 dispose → 忽略旧结果且不抛错', () async {
      final fake = _PendingPrewarmService();
      final c = ProviderContainer(
        overrides: [
          cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
          prewarmServiceProvider.overrideWithValue(fake),
        ],
      );

      final future = c.read(prewarmControllerProvider.notifier).startOnce();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(prewarmControllerProvider).ensuring, isTrue);

      c.dispose();
      fake.completer.complete(PrewarmEnsureResult(
        degraded: false,
        created: 1,
        reused: 0,
        tasks: [
          _mk('agent_register', de: 'de1', deName: '陈启航', status: 'running')
        ],
      ));

      await future;
      expect(fake.listTasksCalls, 0);
    });
  });

  group('PrewarmOverlay 聚合渲染 (技能只在展开区)', () {
    testWidgets('ensure 请求中先显示占位进度', (tester) async {
      final state = PrewarmState(ensuring: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prewarmControllerProvider
                .overrideWith(() => _FixedPrewarmController(state)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(children: [PrewarmOverlay()])
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('正在准备运行环境'), findsOneWidget);
      expect(find.text('初始化运行环境'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('一级只显示聚合标题; 技能子项点击展开后才出现', (tester) async {
      final state = PrewarmState(tasks: [
        _mk('agent_register',
            de: 'de1', deName: '陈启航', status: 'running', uuid: 'a1'),
        _mk('skill_register',
            de: 'de1',
            deName: '陈启航',
            slug: 'lead-scoring',
            status: 'running',
            uuid: 's1'),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prewarmControllerProvider
                .overrideWith(() => _FixedPrewarmController(state)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(children: [PrewarmOverlay()])
            ),
          ),
        ),
      );
      await tester.pump();

      // 一级聚合行可见。
      expect(find.text('加载数字员工 - 陈启航'), findsOneWidget);
      // 折叠时技能/注册子项不在一级列表。
      expect(find.text('安装技能 · lead-scoring'), findsNothing);
      expect(find.text('注册数字员工'), findsNothing);

      // 展开。
      await tester.tap(find.text('加载数字员工 - 陈启航'));
      await tester.pump();

      expect(find.text('注册数字员工'), findsOneWidget);
      expect(find.text('安装技能 · lead-scoring'), findsOneWidget);
    });

    testWidgets('右上角收起后显示轻量任务栏入口; 点击入口展开', (tester) async {
      final state = PrewarmState(tasks: [
        _mk('agent_register',
            de: 'de1', deName: '陈启航', status: 'running', uuid: 'a1'),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prewarmControllerProvider
                .overrideWith(() => _FixedPrewarmController(state)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(children: [PrewarmOverlay()])
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byIcon(CupertinoIcons.xmark), findsNothing);
      expect(find.byIcon(CupertinoIcons.minus), findsOneWidget);
      expect(find.byTooltip('收起任务栏'), findsOneWidget);
      expect(find.text('加载数字员工 - 陈启航'), findsOneWidget);

      await tester.tap(find.byTooltip('收起任务栏'));
      await tester.pump();

      expect(find.byIcon(CupertinoIcons.minus), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byTooltip('正在准备运行环境'), findsOneWidget);
      expect(find.text('加载数字员工 - 陈启航'), findsNothing);

      await tester.tap(find.byTooltip('正在准备运行环境'));
      await tester.pump();

      expect(find.byTooltip('收起任务栏'), findsOneWidget);
      expect(find.text('加载数字员工 - 陈启航'), findsOneWidget);
    });
  });
}
