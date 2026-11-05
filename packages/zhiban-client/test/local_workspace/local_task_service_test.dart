import 'package:zhiban_client/pages/local_workspace/services/local_employee_execution.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_task_schedule.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_task_service.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';

CronJobDraft draft(
        {String name = '测试任务',
        String rule = '* * * * *',
        DateTime? once,
        bool enabled = true}) =>
    CronJobDraft(
        name: name,
        description: '',
        agentId: 'employee',
        conversationUuid: 'direct-agent:employee',
        enabled: enabled,
        scheduleType: once == null ? 'cron' : 'once',
        interval: 1,
        intervalUnit: 'minute',
        schedule: rule,
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: '分析文件',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: '',
        deliveryRecipient: '',
        runOnceAt: once);

Future<void> until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('local execution did not settle');
}

void main() {
  sqfliteFfiInit();
  test('cron supports steps, ranges, month ends, leap dates and DOM/DOW OR',
      () {
    expect(
        LocalTaskSchedule('*/15 9-10 * * 1-5')
            .next(DateTime(2026, 11, 6, 10, 59)),
        DateTime(2026, 11, 9, 9));
    expect(LocalTaskSchedule('0 9 31 * *').next(DateTime(2026, 4, 1)),
        DateTime(2026, 5, 31, 9));
    expect(LocalTaskSchedule('0 0 29 2 *').next(DateTime(2096, 3, 1)),
        DateTime(2104, 2, 29));
    expect(LocalTaskSchedule('0 9 3 * */2').next(DateTime(2026, 11, 3, 10)),
        DateTime(2026, 12, 3, 9));
    expect(LocalTaskSchedule('0 9 13 * 1').next(DateTime(2026, 11, 6)),
        DateTime(2026, 11, 9, 9));
    expect(LocalTaskSchedule('0 9 * * 7').next(DateTime(2026, 11, 6)),
        DateTime(2026, 11, 8, 9));
    for (final rule in [
      'bad',
      '60 * * * *',
      '*/0 * * * *',
      '1-0 * * * *',
      '0 0 31 2 *'
    ]) {
      expect(() => LocalTaskSchedule(rule).next(DateTime(2026)),
          throwsFormatException);
    }
  });

  test('calendar wildcard steps retain date and weekday constraints', () {
    expect(LocalTaskSchedule('0 9 */2 * *').next(DateTime(2026, 11, 1, 10)),
        DateTime(2026, 11, 3, 9));
    expect(LocalTaskSchedule('0 9 * * */2').next(DateTime(2026, 11, 2, 10)),
        DateTime(2026, 11, 3, 9));
    expect(LocalTaskSchedule('0 9 */2 * 1').next(DateTime(2026, 11, 1, 10)),
        DateTime(2026, 11, 9, 9));
    expect(LocalTaskSchedule('0 9 */2 * */2').next(DateTime(2026, 11, 1, 10)),
        DateTime(2026, 11, 3, 9));
    expect(LocalTaskSchedule('0 9 3 * */2').next(DateTime(2026, 11, 3, 10)),
        DateTime(2026, 12, 3, 9));
    expect(LocalTaskSchedule('0 9 13 * 1').next(DateTime(2026, 11, 6)),
        DateTime(2026, 11, 9, 9));
  });

  late LocalWorkspaceStore store;
  late LocalTaskService service;
  late DateTime clock;
  late Completer<LocalRow> reply;
  var calls = 0;
  var busy = false;
  setUp(() async {
    store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    await store.saveEmployee({
      'id': 'employee',
      'name': '助手',
      'prompt': '',
      'provider_id': 'p',
      'model_id': 'm',
      'skills': '[]',
      'created': 1
    });
    clock = DateTime(2026, 11, 5, 9);
    reply = Completer<LocalRow>();
    calls = 0;
    busy = false;
    service = LocalTaskService(store,
        now: () => clock,
        isBusy: (_) => busy,
        execute: (employee, prompt, token) {
          calls++;
          expect(prompt, '分析文件');
          return reply.future;
        });
  });
  tearDown(() async {
    service.dispose();
    await store.db.close();
  });

  test(
      'shared owner blocks chat before claim IO and stays held through completion',
      () async {
    final reserved = Completer<void>();
    final execution = LocalEmployeeExecution(onChanged: () {
      if (!reserved.isCompleted) reserved.complete();
    });
    service.dispose();
    service = LocalTaskService(store,
        now: () => clock,
        isBusy: execution.busy,
        execution: execution,
        execute: (_, __, token) {
          expect(execution.owns('employee', token), true);
          expect(execution.acquire('employee'), isNull);
          calls++;
          return reply.future;
        });
    final job = await service
        .createJob(draft(once: clock.add(const Duration(hours: 1))));
    final launching = service.runJobNow(job.id);
    await reserved.future;
    expect(execution.acquire('employee'), isNull);
    await launching;
    await until(() async => calls == 1);
    expect(execution.busy('employee'), true);
    reply.complete({'status': 'complete', 'content': '完成'});
    await until(() async => !execution.busy('employee'));
    expect((await service.listRecentRuns()).single.status, 'ok');
  });

  test('chat owner leaves due once task untouched then executes exactly once',
      () async {
    final execution = LocalEmployeeExecution();
    service.dispose();
    service = LocalTaskService(store,
        now: () => clock,
        isBusy: execution.busy,
        execution: execution,
        execute: (_, __, token) {
          calls++;
          return reply.future;
        });
    final job = await service
        .createJob(draft(once: clock.add(const Duration(minutes: 1))));
    final chat = execution.acquire('employee')!;
    clock = clock.add(const Duration(minutes: 2));
    await service.tick();
    expect((await service.listJobs()).single.enabled, true);
    expect(await service.listRecentRuns(), isEmpty);
    await expectLater(service.runJobNow(job.id), throwsStateError);
    execution.release('employee', chat);
    await service.tick();
    await until(() async => calls == 1);
    reply.complete({'status': 'complete'});
    await until(() async => !execution.busy('employee'));
    await service.tick();
    expect(calls, 1);
    expect((await service.listJobs()).single.enabled, false);
  });

  test('failed claim releases owner without consuming task', () async {
    final execution = LocalEmployeeExecution();
    service.dispose();
    service = LocalTaskService(store,
        now: () => clock,
        isBusy: execution.busy,
        execution: execution,
        execute: (_, __, token) {
          calls++;
          return reply.future;
        });
    final job = await service.createJob(draft());
    final row = (await store.db.query('local_tasks')).single;
    final body = jsonDecode(row['body'] as String) as Map;
    body['schedule_cron'] = 'invalid';
    await store.db.update('local_tasks', {'body': jsonEncode(body)});
    await expectLater(service.runJobNow(job.id), throwsFormatException);
    expect(execution.busy('employee'), false);
    expect(await service.listRecentRuns(), isEmpty);
    expect(calls, 0);
  });

  test('stop during claim releases owner and leaves once task enabled',
      () async {
    late LocalEmployeeExecution execution;
    execution =
        LocalEmployeeExecution(onChanged: () => execution.stop('employee'));
    service.dispose();
    service = LocalTaskService(store,
        now: () => clock,
        isBusy: execution.busy,
        execution: execution,
        execute: (_, __, token) {
          calls++;
          return reply.future;
        });
    final job = await service
        .createJob(draft(once: clock.add(const Duration(hours: 1))));
    await service.runJobNow(job.id);
    expect((await service.listJobs()).single.enabled, true);
    expect(execution.busy('employee'), false);
    expect(await service.listRecentRuns(), isEmpty);
    expect(calls, 0);
  });

  test(
      'missed runs coalesce once; busy employee and duplicate manual runs cannot overlap',
      () async {
    final job = await service.createJob(draft());
    clock = clock.add(const Duration(days: 3));
    busy = true;
    await service.tick();
    expect(calls, 0);
    busy = false;
    await Future.wait([service.tick(), service.tick()]);
    await until(() async => calls == 1);
    await expectLater(service.runJobNow(job.id), throwsStateError);
    final next = (await service.listJobs()).single.state.nextRunAtMs!;
    expect(next, greaterThan(clock.millisecondsSinceEpoch));
    await service.tick();
    expect(calls, 1);
    reply.complete({'id': 'reply', 'status': 'complete', 'content': '完成'});
    await until(
        () async => (await service.listRecentRuns()).single.status == 'ok');
    expect((await service.listRecentRuns()).single.messageUuid, 'reply');
    await service.deleteJob(job.id);
    expect(await service.listJobs(), isEmpty);
    expect((await service.listRecentRuns()).single.jobName, '测试任务');
  });

  test('once dates keep year, disable on claim, and failure never retries',
      () async {
    final at = DateTime(2028, 2, 29, 9);
    final job = await service.createJob(draft(once: at));
    expect(CronJobDraft.fromJob(job).runOnceAt, at);
    clock = at.add(const Duration(days: 1));
    await service.tick();
    await until(() async => calls == 1);
    expect((await service.listJobs()).single.enabled, false);
    reply.completeError(StateError('secret upstream failure'));
    await until(
        () async => (await service.listRecentRuns()).single.status == 'error');
    expect((await service.listRecentRuns()).single.error,
        isNot(contains('secret')));
    await service.tick();
    expect(calls, 1);
    await expectLater(service.runJobNow(job.id), throwsStateError);
  });

  test('completion does not undo pause or edit; cancellation is recorded',
      () async {
    final job = await service.createJob(draft());
    await service.runJobNow(job.id);
    await until(() async => calls == 1);
    await service.updateJob(job.id, draft(name: '已改名', enabled: false));
    reply.complete({'id': 'reply', 'status': 'interrupted', 'content': '已停止'});
    await until(() async =>
        (await service.listRecentRuns()).single.status == 'cancelled');
    expect((await service.listJobs()).single.name, '已改名');
    expect((await service.listJobs()).single.enabled, false);
    expect((await service.listRecentRuns()).single.jobName, '测试任务');
    await service.updateJobEnabled(job.id, true);
    expect((await service.listJobs()).single.state.nextRunAtMs,
        greaterThan(clock.millisecondsSinceEpoch));
  });

  test('deleting an employee removes schedules and preserves run history',
      () async {
    final job = await service.createJob(draft());
    await service.runJobNow(job.id);
    await until(() async => calls == 1);
    reply.complete({'id': 'reply', 'status': 'complete', 'content': '完成'});
    await until(
        () async => (await service.listRecentRuns()).single.status == 'ok');
    await store.deleteEmployee('employee');
    expect(await service.listJobs(), isEmpty);
    expect(await service.listRecentRuns(), hasLength(1));
  });

  test('v6 upgrade preserves messages and creates task tables', () async {
    final dir = await Directory.systemTemp.createTemp('local-task-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';
    var old =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    await old.saveEmployee({
      'id': 'old',
      'name': '旧员工',
      'prompt': '',
      'provider_id': 'p',
      'model_id': 'm',
      'skills': '[]',
      'created': 1
    });
    await old.addMessage('old', 'user', '旧消息');
    await old.db.execute('DROP TABLE local_task_runs');
    await old.db.execute('DROP TABLE local_tasks');
    await old.db.setVersion(6);
    await old.db.close();
    old =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    expect((await old.employees()).single['name'], '旧员工');
    expect((await old.messages('old')).single['content'], '旧消息');
    expect(await old.db.query('local_tasks'), isEmpty);
    expect(await old.db.getVersion(), 7);
    await old.db.close();
  });

  test(
      'restart persists tasks and marks running record interrupted without retrying once',
      () async {
    final dir = await Directory.systemTemp.createTemp('local-task-reopen-');
    addTearDown(() => dir.delete(recursive: true));
    var disk = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: '${dir.path}/db');
    await disk.saveEmployee({
      'id': 'employee',
      'name': '助手',
      'prompt': '',
      'provider_id': 'p',
      'model_id': 'm',
      'skills': '[]',
      'created': 1
    });
    var local = LocalTaskService(disk,
        now: () => clock,
        isBusy: (_) => false,
        execute: (_, __, token) async => {'status': 'complete'});
    final once = await local
        .createJob(draft(once: clock.add(const Duration(minutes: 1))));
    final repeat = await local.createJob(draft(name: '重复'));
    await disk.db.update('local_tasks', {'enabled': 0, 'next_run': null},
        where: 'id = ?', whereArgs: [once.id]);
    await disk.db.insert('local_task_runs', {
      'id': 'crashed',
      'job_id': once.id,
      'employee_id': 'employee',
      'job_name': once.name,
      'started': 1,
      'status': 'running',
      'body': jsonEncode({})
    });
    local.dispose();
    await disk.db.close();
    disk = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: '${dir.path}/db');
    var resumed = 0;
    clock = clock.add(const Duration(hours: 4));
    local = LocalTaskService(disk,
        now: () => clock,
        isBusy: (_) => false,
        execute: (_, __, token) async {
          resumed++;
          return {'status': 'complete', 'content': '恢复'};
        });
    expect((await local.listRecentRuns()).single.status, 'cancelled');
    await local.tick();
    await until(() async =>
        (await local.listJobRuns(repeat.id)).firstOrNull?.status == 'ok');
    expect(resumed, 1);
    expect((await local.listJobs()).firstWhere((j) => j.id == once.id).enabled,
        false);
    local.dispose();
    await disk.db.close();
  });
}
