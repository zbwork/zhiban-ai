import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';

void main() {
  group('CronJob.fromJson', () {
    test('parses Bus cron job DTO', () {
      final job = CronJob.fromJson({
        'uuid': 'job-1',
        'name': '销售日报',
        'description': '每天提醒销售员总结',
        'agent_uuid': 'agent-1',
        'enabled': true,
        'schedule_cron': '*/5 * * * *',
        'timezone': 'Asia/Shanghai',
        'payload': {'prompt': '生成今天的销售日报'},
        'delivery': {
          'mode': 'conversation',
          'conversation_uuid': 'conv-1'
        },
        'next_run_at': '2026-06-06T09:30:00+08:00',
        'last_run_at': '2026-06-06T09:00:00+08:00',
        'last_run_status': 'succeeded',
        'consecutive_failures': 2,
        'created_at': '2026-06-01T00:00:00+08:00',
        'updated_at': '2026-06-02T00:00:00+08:00',
      });

      expect(job.id, 'job-1');
      expect(job.name, '销售日报');
      expect(job.agentId, 'agent-1');
      expect(job.conversationUuid, 'conv-1');
      expect(job.delivery.conversationUuid, 'conv-1');
      expect(job.enabled, isTrue);
      expect(job.schedule.kind, 'cron');
      expect(job.schedule.expr, '*/5 * * * *');
      expect(job.timezone, 'Asia/Shanghai');
      expect(job.payload.displayText, '生成今天的销售日报');
      expect(job.state.lastRunStatus, 'ok');
      expect(job.state.consecutiveErrors, 2);
      expect(job.createdAtMs, greaterThan(0));
      expect(job.updatedAtMs, greaterThan(0));
    });
  });

  group('CronRunEntry.fromJson', () {
    test('parses Bus cron run DTO', () {
      final run = CronRunEntry.fromJson({
        'uuid': 'run-1',
        'job_uuid': 'job-1',
        'status': 'failed',
        'trigger_kind': 'schedule',
        'started_at': '2026-06-06T09:00:00+08:00',
        'duration_ms': 1234,
        'rendered_prompt_snapshot': '生成今天的销售日报',
        'conversation_uuid': 'conv-1',
        'message_uuid': 'msg-1',
        'error_message': 'cron.agent_not_in_group',
      });

      expect(run.sessionId, 'run-1');
      expect(run.jobId, 'job-1');
      expect(run.status, 'error');
      expect(run.action, 'schedule');
      expect(run.durationMs, 1234);
      expect(run.summary, '生成今天的销售日报');
      expect(run.conversationUuid, 'conv-1');
      expect(run.messageUuid, 'msg-1');
      expect(run.delivered, isTrue);
      expect(run.error, 'cron.agent_not_in_group');
    });
  });

  group('CronJobDraft.toCreateJson', () {
    test('emits Bus snake_case payload', () {
      const draft = CronJobDraft(
        name: '销售日报',
        description: '每天提醒销售员总结',
        agentId: 'agent-1',
        conversationUuid: 'conv-1',
        enabled: true,
        scheduleType: 'interval',
        interval: 5,
        intervalUnit: 'minute',
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: '生成今天的销售日报',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'conversation',
        deliveryChannel: '',
        deliveryRecipient: '',
      );

      final json = draft.toCreateJson();
      expect(json['name'], '销售日报');
      expect(json['description'], '每天提醒销售员总结');
      expect(json['agent_uuid'], 'agent-1');
      expect(json['conversation_uuid'], 'conv-1');
      expect(json['schedule_cron'], '*/5 * * * *');
      expect(json['prompt'], '生成今天的销售日报');
      expect(json.containsKey('agentId'), isFalse);
      expect(json.containsKey('cronExpr'), isFalse);
      expect(json.containsKey('payload'), isFalse);
    });

    test('logical direct target emits delivery_kind without placeholder uuid',
        () {
      const agentUuid = 'agent-new';
      final draft = CronJobDraft(
        name: '新员工日报',
        description: '',
        agentId: agentUuid,
        conversationUuid: taskDirectDeliveryTargetId(agentUuid),
        enabled: true,
        scheduleType: 'interval',
        interval: 5,
        intervalUnit: 'minute',
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: '生成日报',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'conversation',
        deliveryChannel: '',
        deliveryRecipient: '',
      );

      final json = draft.toCreateJson();
      expect(json['delivery_kind'], 'direct');
      expect(json.containsKey('conversation_uuid'), isFalse);
      expect(
          json.values, isNot(contains(taskDirectDeliveryTargetId(agentUuid))));
    });
  });

  group('CronJobDraft 调度往返对称（cron → interval 反推回显）', () {
    CronJob jobWithCron(String expr) {
      return CronJob.fromJson({
        'uuid': 'job-rt',
        'name': 'rt',
        'enabled': true,
        'schedule_cron': expr,
        'payload': {'prompt': 'p'},
        'delivery': {'mode': 'conversation', 'conversation_uuid': 'conv-1'},
      });
    }

    test('toScheduleCron 生成的标准形态都能反推回间隔模式', () {
      final cases = <String, (int, String)>{
        '* * * * *': (1, 'minute'),
        '*/30 * * * *': (30, 'minute'),
        '0 * * * *': (1, 'hour'),
        '0 */2 * * *': (2, 'hour'),
        '0 0 * * *': (1, 'day'),
      };
      cases.forEach((expr, expected) {
        final draft = CronJobDraft.fromJob(jobWithCron(expr));
        expect(draft.scheduleType, 'interval', reason: expr);
        expect(draft.interval, expected.$1, reason: expr);
        expect(draft.intervalUnit, expected.$2, reason: expr);
        expect(draft.toScheduleCron(), expr, reason: '$expr 应往返一致');
      });
    });

    test('每周星期 D 反推为周模式并保留 weekday，再生成保持一致', () {
      final draft = CronJobDraft.fromJob(jobWithCron('0 0 * * 3'));
      expect(draft.scheduleType, 'interval');
      expect(draft.intervalUnit, 'week');
      expect(draft.weekday, 3);
      expect(draft.toScheduleCron(), '0 0 * * 3');
    });

    test('日周月模式支持指定执行时间并可反推回显', () {
      final daily = CronJobDraft.fromJob(jobWithCron('30 18 * * *'));
      expect(daily.scheduleType, 'interval');
      expect(daily.intervalUnit, 'day');
      expect(daily.interval, 1);
      expect(daily.scheduleHour, 18);
      expect(daily.scheduleMinute, 30);
      expect(daily.toScheduleCron(), '30 18 * * *');

      final weekly = CronJobDraft.fromJob(jobWithCron('45 8 * * 1'));
      expect(weekly.scheduleType, 'interval');
      expect(weekly.intervalUnit, 'week');
      expect(weekly.weekday, 1);
      expect(weekly.scheduleHour, 8);
      expect(weekly.scheduleMinute, 45);
      expect(weekly.toScheduleCron(), '45 8 * * 1');

      final monthly = CronJobDraft.fromJob(jobWithCron('0 10 15 * *'));
      expect(monthly.scheduleType, 'interval');
      expect(monthly.intervalUnit, 'month');
      expect(monthly.monthDay, 15);
      expect(monthly.scheduleHour, 10);
      expect(monthly.scheduleMinute, 0);
      expect(monthly.toScheduleCron(), '0 10 15 * *');
    });

    test('手写复杂表达式保持 Cron 模式回显（含存量「每隔 N 天」）', () {
      // '0 0 */3 * *' 是旧版「每隔 3 天」产物：编辑器已不提供该档位，
      // 回落 Cron 模式显示真实表达式，不得静默改写成「每天」。
      for (final expr in [
        '15 8 * * 1-5',
        '0 0 1 1 *',
        '*/5 9-18 * * *',
        '0 0 */3 * *',
      ]) {
        final draft = CronJobDraft.fromJob(jobWithCron(expr));
        expect(draft.scheduleType, 'cron', reason: expr);
        expect(draft.schedule, expr, reason: expr);
      }
    });

    test('存量 everyMs 隔 N 天任务回落 Cron 模式并合成等价表达式', () {
      final job = CronJob.fromJson({
        'uuid': 'job-legacy',
        'name': 'legacy',
        'enabled': true,
        'schedule': {'kind': 'every', 'everyMs': 172800000},
        'payload': {'prompt': 'p'},
        'delivery': {'mode': 'conversation', 'conversation_uuid': 'conv-1'},
      });
      final draft = CronJobDraft.fromJob(job);
      expect(draft.scheduleType, 'cron');
      expect(draft.schedule, '0 0 */2 * *');

      // 每 1 天（86400000ms）仍是间隔模式「每天 00:00」。
      final daily = CronJob.fromJson({
        'uuid': 'job-daily',
        'name': 'daily',
        'enabled': true,
        'schedule': {'kind': 'every', 'everyMs': 86400000},
        'payload': {'prompt': 'p'},
        'delivery': {'mode': 'conversation', 'conversation_uuid': 'conv-1'},
      });
      final dailyDraft = CronJobDraft.fromJob(daily);
      expect(dailyDraft.scheduleType, 'interval');
      expect(dailyDraft.intervalUnit, 'day');
      expect(dailyDraft.interval, 1);
      expect(dailyDraft.toScheduleCron(), '0 0 * * *');
    });

    test('周模式 toScheduleCron 锁定每周（不再丢 N）并默认 00:00', () {
      const draft = CronJobDraft(
        name: 'w',
        description: '',
        agentId: 'a',
        conversationUuid: 'c',
        enabled: true,
        scheduleType: 'interval',
        interval: 1,
        intervalUnit: 'week',
        weekday: 5,
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: 'm',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: 'last',
        deliveryRecipient: '',
      );
      expect(draft.toScheduleCron(), '0 0 * * 5');
    });

    test('日周月模式生成指定执行时间', () {
      // day 锁 N=1：即使 draft 带了 N>1 也生成「每天」（日字段 */N 按月重置，
      // 表达不了准确的「每 N 天」，编辑器已不提供该档位）。
      const daily = CronJobDraft(
        name: 'd',
        description: '',
        agentId: 'a',
        conversationUuid: 'c',
        enabled: true,
        scheduleType: 'interval',
        interval: 2,
        intervalUnit: 'day',
        scheduleHour: 7,
        scheduleMinute: 5,
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: 'm',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: 'last',
        deliveryRecipient: '',
      );
      expect(daily.toScheduleCron(), '5 7 * * *');

      const weekly = CronJobDraft(
        name: 'w',
        description: '',
        agentId: 'a',
        conversationUuid: 'c',
        enabled: true,
        scheduleType: 'interval',
        interval: 1,
        intervalUnit: 'week',
        weekday: 6,
        scheduleHour: 9,
        scheduleMinute: 30,
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: 'm',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: 'last',
        deliveryRecipient: '',
      );
      expect(weekly.toScheduleCron(), '30 9 * * 6');

      const monthly = CronJobDraft(
        name: 'm',
        description: '',
        agentId: 'a',
        conversationUuid: 'c',
        enabled: true,
        scheduleType: 'interval',
        interval: 1,
        intervalUnit: 'month',
        monthDay: 15,
        scheduleHour: 10,
        scheduleMinute: 0,
        schedule: '',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: 'm',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: 'last',
        deliveryRecipient: '',
      );
      expect(monthly.toScheduleCron(), '0 10 15 * *');
    });
  });

  group('CronJobDraft 单次执行 (run_once 变通实现)', () {
    const base = CronJobDraft(
      name: 'once',
      description: '',
      agentId: 'agent-1',
      conversationUuid: 'conv-1',
      enabled: true,
      scheduleType: 'once',
      interval: null,
      intervalUnit: 'hour',
      schedule: '',
      sessionTarget: 'isolated',
      payloadKind: 'agentTurn',
      message: 'm',
      wakeMode: 'now',
      timeout: null,
      deliveryMode: 'none',
      deliveryChannel: 'last',
      deliveryRecipient: '',
    );

    test('toScheduleCron 只取月/日/时/分四段（cron 无年字段）', () {
      final draft = CronJobDraft(
        name: base.name,
        description: base.description,
        agentId: base.agentId,
        conversationUuid: base.conversationUuid,
        enabled: base.enabled,
        scheduleType: 'once',
        interval: base.interval,
        intervalUnit: base.intervalUnit,
        schedule: base.schedule,
        sessionTarget: base.sessionTarget,
        payloadKind: base.payloadKind,
        message: base.message,
        wakeMode: base.wakeMode,
        timeout: base.timeout,
        deliveryMode: base.deliveryMode,
        deliveryChannel: base.deliveryChannel,
        deliveryRecipient: base.deliveryRecipient,
        runOnceAt: DateTime(2027, 3, 5, 14, 30),
      );
      expect(draft.toScheduleCron(), '30 14 5 3 *');
    });

    test('toCreateJson 只在 once 档位带 run_once=true, 其它档位不带该字段', () {
      final once = CronJobDraft(
        name: base.name,
        description: base.description,
        agentId: base.agentId,
        conversationUuid: base.conversationUuid,
        enabled: base.enabled,
        scheduleType: 'once',
        interval: base.interval,
        intervalUnit: base.intervalUnit,
        schedule: base.schedule,
        sessionTarget: base.sessionTarget,
        payloadKind: base.payloadKind,
        message: base.message,
        wakeMode: base.wakeMode,
        timeout: base.timeout,
        deliveryMode: base.deliveryMode,
        deliveryChannel: base.deliveryChannel,
        deliveryRecipient: base.deliveryRecipient,
        runOnceAt: DateTime(2027, 3, 5, 14, 30),
      );
      expect(once.toCreateJson()['run_once'], isTrue);

      final interval = CronJobDraft(
        name: base.name,
        description: base.description,
        agentId: base.agentId,
        conversationUuid: base.conversationUuid,
        enabled: base.enabled,
        scheduleType: 'interval',
        interval: 30,
        intervalUnit: 'minute',
        schedule: base.schedule,
        sessionTarget: base.sessionTarget,
        payloadKind: base.payloadKind,
        message: base.message,
        wakeMode: base.wakeMode,
        timeout: base.timeout,
        deliveryMode: base.deliveryMode,
        deliveryChannel: base.deliveryChannel,
        deliveryRecipient: base.deliveryRecipient,
      );
      expect(interval.toCreateJson().containsKey('run_once'), isFalse);
    });

    test('toUpdateJson 必须显式带 run_once（true/false），不能像 create 一样省略', () {
      final once = CronJobDraft(
        name: base.name,
        description: base.description,
        agentId: base.agentId,
        conversationUuid: base.conversationUuid,
        enabled: base.enabled,
        scheduleType: 'once',
        interval: base.interval,
        intervalUnit: base.intervalUnit,
        schedule: base.schedule,
        sessionTarget: base.sessionTarget,
        payloadKind: base.payloadKind,
        message: base.message,
        wakeMode: base.wakeMode,
        timeout: base.timeout,
        deliveryMode: base.deliveryMode,
        deliveryChannel: base.deliveryChannel,
        deliveryRecipient: base.deliveryRecipient,
        runOnceAt: DateTime(2027, 3, 5, 14, 30),
      );
      expect(once.toUpdateJson()['run_once'], isTrue);

      final interval = CronJobDraft(
        name: base.name,
        description: base.description,
        agentId: base.agentId,
        conversationUuid: base.conversationUuid,
        enabled: base.enabled,
        scheduleType: 'interval',
        interval: 30,
        intervalUnit: 'minute',
        schedule: base.schedule,
        sessionTarget: base.sessionTarget,
        payloadKind: base.payloadKind,
        message: base.message,
        wakeMode: base.wakeMode,
        timeout: base.timeout,
        deliveryMode: base.deliveryMode,
        deliveryChannel: base.deliveryChannel,
        deliveryRecipient: base.deliveryRecipient,
      );
      // 关键：显式 false，不是"没有这个 key"——编辑器把「单次执行」切回「固定
      // 频率」保存时，必须能清掉后端旧的 metadata.run_once 标记。
      expect(interval.toUpdateJson()['run_once'], isFalse);
    });

    test('fromJob 优先识别 metadata.run_once，不会被误判成月模式固定频率', () {
      final job = CronJob.fromJson({
        'uuid': 'job-once',
        'name': 'once-job',
        'enabled': true,
        'schedule_cron': '30 14 5 3 *',
        'run_once': true,
        'payload': {'prompt': 'p'},
        'delivery': {'mode': 'conversation', 'conversation_uuid': 'conv-1'},
      });
      expect(job.runOnce, isTrue);

      final draft = CronJobDraft.fromJob(job);
      expect(draft.scheduleType, 'once');
      expect(draft.runOnceAt, isNotNull);
      expect(draft.runOnceAt!.month, 3);
      expect(draft.runOnceAt!.day, 5);
      expect(draft.runOnceAt!.hour, 14);
      expect(draft.runOnceAt!.minute, 30);
      // 年份是猜的（cron 无年字段，取离现在最近的未来那次），但重新生成的
      // 表达式必须跟原始一致——往返对称不依赖猜中了哪一年。
      expect(draft.toScheduleCron(), '30 14 5 3 *');
    });

    test('CronJob.fromJson 默认 run_once=false（老任务 / 普通任务不受影响）', () {
      final job = CronJob.fromJson({
        'uuid': 'job-plain',
        'name': 'plain',
        'enabled': true,
        'schedule_cron': '0 9 * * *',
        'payload': {'prompt': 'p'},
        'delivery': {'mode': 'conversation', 'conversation_uuid': 'conv-1'},
      });
      expect(job.runOnce, isFalse);
      expect(CronJobDraft.fromJob(job).scheduleType, 'interval');
    });
  });
}
