import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'local_employee_execution.dart';

import '../../task/models/task_models.dart';
import '../../task/services/task_service.dart';
import 'local_task_schedule.dart';
import 'local_workspace_store.dart';

typedef LocalTaskExecutor = Future<LocalRow> Function(
    LocalRow employee, String prompt, CancelToken token);

/// Local adapter for the original task notifier and presentation. Credentials
/// remain exclusively in the existing chat/model service execution chain.
class LocalTaskService extends BusTaskService {
  LocalTaskService(this.store,
      {required this.execute,
      required this.isBusy,
      LocalEmployeeExecution? execution,
      DateTime Function()? now})
      : execution = execution ?? LocalEmployeeExecution(),
        now = now ?? DateTime.now;
  final LocalWorkspaceStore store;
  final LocalTaskExecutor execute;
  final LocalEmployeeExecution execution;
  final bool Function(String employee) isBusy;
  final DateTime Function() now;
  final Set<String> _employees = {};
  final Set<String> _jobs = {};
  Timer? _timer;
  bool _ticking = false, _closed = false;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_closed) _changes.add(null);
  }

  String? schedulerError;

  void start() {
    _timer ??= Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_safeTick()));
    unawaited(_safeTick());
  }

  Future<void> _safeTick() async {
    try {
      await tick();
      schedulerError = null;
    } catch (_) {
      schedulerError = '本地任务调度失败，请检查磁盘后重启客户端';
      _changed();
    }
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
    unawaited(_changes.close());
  }

  Map<String, dynamic> _body(LocalRow row) =>
      Map<String, dynamic>.from(jsonDecode(row['body'] as String) as Map);
  CronJob _job(LocalRow row) {
    final body = _body(row);
    return CronJob.fromJson({
      ...body,
      'id': row['id'],
      'enabled': row['enabled'] == 1,
      'status': row['enabled'] == 1 ? 'active' : 'paused',
      'next_run_at': row['next_run'],
      'updated_at': row['updated']
    });
  }

  Future<LocalRow> _row(String id) async {
    final rows =
        await store.db.query('local_tasks', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) throw StateError('任务已删除');
    return rows.single;
  }

  @override
  Future<List<CronJob>> listJobs() async =>
      (await store.db.query('local_tasks', orderBy: 'updated DESC, id'))
          .map(_job)
          .toList();

  int? _next(Map<String, dynamic> body, DateTime after) {
    if (body['run_once'] == true) return body['once_at'] as int;
    return LocalTaskSchedule(body['schedule_cron'] as String)
        .next(after)
        .millisecondsSinceEpoch;
  }

  Future<void> _save(CronJobDraft draft, String id,
      {bool creating = false}) async {
    if (draft.name.trim().isEmpty ||
        draft.message.trim().isEmpty ||
        draft.message.length > 150000) {
      throw StateError('请填写任务名称和有效执行内容（最多 150,000 字符）');
    }
    final employees = await store.employees();
    if (!employees.any((e) => e['id'] == draft.agentId)) {
      throw StateError('请选择本地数字员工');
    }
    if (draft.promptTemplateUuid != null ||
        (draft.conversationUuid.isNotEmpty &&
            draft.conversationUuid != draft.agentId &&
            draft.conversationUuid !=
                taskDirectDeliveryTargetId(draft.agentId))) {
      throw StateError('本地任务仅支持自定义提示词和该员工自己的对话');
    }
    final at = now();
    if (draft.scheduleType == 'once' &&
        (draft.runOnceAt == null || !draft.runOnceAt!.isAfter(at))) {
      throw StateError('请选择未来的单次执行时间');
    }
    final previous = creating ? <String, dynamic>{} : _body(await _row(id));
    final body = <String, dynamic>{
      ...previous,
      ...draft.toCreateJson(),
      'run_once': draft.scheduleType == 'once',
      'once_at': draft.runOnceAt?.millisecondsSinceEpoch,
      'payload': {'kind': 'agentTurn', 'message': draft.message.trim()},
      'delivery': {'conversation_uuid': draft.agentId},
      'timezone': 'local',
      'created_at': previous['created_at'] ?? at.millisecondsSinceEpoch
    };
    // Editing a completed once-task to a new future date explicitly rearms it.
    body.remove('last_run_at');
    body.remove('last_run_status');
    body.remove('last_run_summary');
    body.remove('consecutive_failures');
    final next = _next(body, at); // validate even if initially paused
    final row = <String, Object?>{
      'id': id,
      'employee_id': draft.agentId,
      'body': jsonEncode(body),
      'next_run': draft.enabled ? next : null,
      'enabled': draft.enabled ? 1 : 0,
      'updated': at.millisecondsSinceEpoch
    };
    if (creating) {
      await store.db.insert('local_tasks', row);
    } else {
      await store.db
          .update('local_tasks', row, where: 'id = ?', whereArgs: [id]);
    }
    _changed();
  }

  @override
  Future<CronJob> createJob(CronJobDraft draft) async {
    final id = LocalWorkspaceStore.uuid.v4();
    await _save(draft, id, creating: true);
    return _job(await _row(id));
  }

  @override
  Future<void> updateJob(String jobId, CronJobDraft draft) =>
      _save(draft, jobId);
  @override
  Future<void> updateJobEnabled(String jobId, bool enabled) async {
    final body = _body(await _row(jobId));
    final next = enabled ? _next(body, now()) : null;
    if (enabled &&
        body['run_once'] == true &&
        (body['last_run_at'] != null ||
            next! <= now().millisecondsSinceEpoch)) {
      throw StateError('单次任务已执行或已过期，请编辑执行时间');
    }
    await store.db.update(
        'local_tasks',
        {
          'enabled': enabled ? 1 : 0,
          'next_run': next,
          'updated': now().millisecondsSinceEpoch
        },
        where: 'id = ?',
        whereArgs: [jobId]);
    _changed();
  }

  @override
  Future<void> pauseJob(String jobId) => updateJobEnabled(jobId, false);
  @override
  Future<void> resumeJob(String jobId) => updateJobEnabled(jobId, true);
  @override
  Future<void> deleteJob(String jobId) async {
    await store.db.delete('local_tasks', where: 'id = ?', whereArgs: [jobId]);
    _changed();
  }

  Future<void> tick() async {
    if (_closed || _ticking) return;
    _ticking = true;
    try {
      final due = await store.db.query('local_tasks',
          where: 'enabled = 1 AND next_run <= ?',
          whereArgs: [now().millisecondsSinceEpoch],
          orderBy: 'next_run, id');
      for (final row in due) {
        if (_closed) break;
        await _launch(row['id'] as String, scheduled: true);
      }
    } finally {
      _ticking = false;
    }
  }

  @override
  Future<void> runJobNow(String jobId) => _launch(jobId, scheduled: false);

  Future<void> _launch(String id, {required bool scheduled}) async {
    if (_closed) throw StateError('本地调度器已停止');
    final row = await _row(id);
    final employeeId = row['employee_id'] as String;
    if (_jobs.contains(id) ||
        _employees.contains(employeeId) ||
        isBusy(employeeId)) {
      if (scheduled) return;
      throw StateError('该数字员工正在执行，请稍后重试');
    }
    // Acquire the same owner token used by interactive chat before claim IO.
    final token = execution.acquire(employeeId);
    if (token == null) {
      if (scheduled) return;
      throw StateError('该数字员工正在执行，请稍后重试');
    }
    // Reserve before the first asynchronous operation after the busy check.
    _jobs.add(id);
    _employees.add(employeeId);
    var launched = false;
    try {
      final at = now();
      final runId = LocalWorkspaceStore.uuid.v4();
      final claimed = await store.db.transaction((txn) async {
        final rows =
            await txn.query('local_tasks', where: 'id = ?', whereArgs: [id]);
        if (rows.isEmpty || token.isCancelled || _closed) return false;
        final current = rows.single;
        if (current['employee_id'] != employeeId) return false;
        if (scheduled &&
            (current['enabled'] != 1 ||
                current['next_run'] == null ||
                (current['next_run'] as int) > at.millisecondsSinceEpoch)) {
          return false;
        }
        final body = _body(current);
        final running = await txn.query('local_task_runs',
            where: 'employee_id = ? AND status = ?',
            whereArgs: [employeeId, 'running'],
            limit: 1);
        if (running.isNotEmpty) return false;
        if (!scheduled &&
            body['run_once'] == true &&
            body['last_run_at'] != null) {
          throw StateError('单次任务已经执行，请编辑执行时间');
        }
        final once = body['run_once'] == true;
        final next = current['enabled'] == 1 && !once ? _next(body, at) : null;
        await txn.update(
            'local_tasks',
            {
              'enabled': once ? 0 : current['enabled'],
              'next_run': next,
              'body': jsonEncode(
                  {...body, 'last_run_at': at.millisecondsSinceEpoch})
            },
            where: 'id = ?',
            whereArgs: [id]);
        await txn.insert('local_task_runs', {
          'id': runId,
          'job_id': id,
          'employee_id': employeeId,
          'job_name': body['name'],
          'started': at.millisecondsSinceEpoch,
          'status': 'running',
          'body': jsonEncode(body)
        });
        return true;
      });
      if (!claimed) return;
      _changed();
      // Execution proceeds independently of page lifetime and timer polling.
      launched = true;
      unawaited(_perform(runId, id, employeeId, at, token));
    } finally {
      if (!launched) {
        _jobs.remove(id);
        _employees.remove(employeeId);
        execution.release(employeeId, token);
      }
    }
  }

  Future<void> _perform(String runId, String jobId, String employeeId,
      DateTime started, CancelToken token) async {
    String status = 'error', summary = '', error = '本地任务执行失败，请检查模型配置或执行记录';
    String? messageId;
    try {
      final run = (await store.db
              .query('local_task_runs', where: 'id = ?', whereArgs: [runId]))
          .single;
      final body = _body(run);
      final employee = (await store.employees())
          .where((e) => e['id'] == employeeId)
          .firstOrNull;
      if (employee == null) throw StateError('数字员工已删除');
      if (token.isCancelled) throw token.cancelError!;
      final reply = await execute(
          employee, (body['payload'] as Map)['message'] as String, token);
      messageId = reply['id'] as String?;
      status = reply['status'] == 'complete'
          ? 'ok'
          : reply['status'] == 'interrupted'
              ? 'cancelled'
              : 'error';
      summary = reply['content'] as String? ?? '';
      error = status == 'ok'
          ? ''
          : status == 'cancelled'
              ? '本次执行已停止'
              : '本地任务执行失败，请查看对话中的执行记录';
    } catch (_) {
      if (token.isCancelled) {
        status = 'cancelled';
        error = '本次执行已停止';
      }
      // Deliberately exclude raw provider/credential errors.
    }
    try {
      await store.db.transaction((txn) async {
        await txn.update(
            'local_task_runs',
            {
              'status': status,
              'summary': summary,
              'error': error.isEmpty ? null : error,
              'message_id': messageId,
              'duration': now().difference(started).inMilliseconds
            },
            where: 'id = ?',
            whereArgs: [runId]);
        final rows =
            await txn.query('local_tasks', where: 'id = ?', whereArgs: [jobId]);
        if (rows.isNotEmpty) {
          final body = _body(rows.single);
          await txn.update(
              'local_tasks',
              {
                'body': jsonEncode({
                  ...body,
                  'last_run_status': status,
                  'last_run_summary': error,
                  'consecutive_failures': status == 'ok'
                      ? 0
                      : (body['consecutive_failures'] as int? ?? 0) + 1
                })
              },
              where: 'id = ?',
              whereArgs: [jobId]);
        }
      });
    } catch (_) {
      schedulerError = '任务执行状态保存失败，请检查磁盘后重启客户端';
    } finally {
      _jobs.remove(jobId);
      _employees.remove(employeeId);
      execution.release(employeeId, token);
      _changed();
    }
  }

  CronRunEntry _run(LocalRow row) => CronRunEntry.fromJson({
        'uuid': row['id'],
        'job_uuid': row['job_id'],
        'jobName': row['job_name'],
        'started_at': row['started'],
        'status': row['status'] == 'interrupted' ? 'cancelled' : row['status'],
        'summary': row['summary'],
        'error': row['error'],
        'duration_ms': row['duration'],
        'message_uuid': row['message_id'],
        'conversation_uuid': row['employee_id'],
      });
  @override
  Future<List<CronRunEntry>> listRecentRuns({int limit = 20}) async =>
      (await store.db.query('local_task_runs',
              orderBy: 'started DESC, rowid DESC', limit: limit))
          .map(_run)
          .toList();
  @override
  Future<List<CronRunEntry>> listJobRuns(String jobId,
          {int limit = 20}) async =>
      (await store.db.query('local_task_runs',
              where: 'job_id = ?',
              whereArgs: [jobId],
              orderBy: 'started DESC, rowid DESC',
              limit: limit))
          .map(_run)
          .toList();
}
