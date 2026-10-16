import 'package:test/test.dart';
import 'package:zhiban_core/chat/cron_message_metadata.dart';

void main() {
  group('CronMessageMetadata.tryParse', () {
    test('returns null for empty / null metadata', () {
      expect(CronMessageMetadata.tryParse(null), isNull);
      expect(CronMessageMetadata.tryParse(<String, dynamic>{}), isNull);
    });

    test('returns null for non-cron metadata', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'user',
        'foo': 'bar',
      });
      expect(meta, isNull);
    });

    test('triggered_by=cron → kind=trigger', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'cron_job_name': '销售日报',
        'cron_job_uuid': 'JOB-1',
        'cron_run_uuid': 'RUN-1',
        'cron_owner_account_id': 42,
        'cron_agent_id': 91,
        'cron_agent_uuid': 'AGT-1',
      });
      expect(meta, isNotNull);
      expect(meta!.kind, CronMessageKind.trigger);
      expect(meta.isTrigger, isTrue);
      expect(meta.jobName, '销售日报');
      expect(meta.jobUuid, 'JOB-1');
      expect(meta.runUuid, 'RUN-1');
      expect(meta.ownerAccountId, 42);
      expect(meta.agentId, 91);
      expect(meta.agentUuid, 'AGT-1');
    });

    test('legacy job_uuid / run_uuid keys fallback', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'job_uuid': 'OLD-JOB',
        'run_uuid': 'OLD-RUN',
        'cron_job_name': '日报',
      });
      expect(meta?.jobUuid, 'OLD-JOB');
      expect(meta?.runUuid, 'OLD-RUN');
    });

    test('new cron_job_uuid takes priority over legacy job_uuid', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'job_uuid': 'OLD',
        'cron_job_uuid': 'NEW',
        'cron_job_name': '日报',
      });
      expect(meta?.jobUuid, 'NEW');
    });

    test('kind=cron_failure_notice → failureNotice', () {
      final meta = CronMessageMetadata.tryParse({
        'kind': 'cron_failure_notice',
        'cron_job_name': '销售日报',
        'cron_consecutive_failures': 3,
        'cron_failure_threshold': 3,
        'last_error_message': 'llm.upstream_timeout',
      });
      expect(meta, isNotNull);
      expect(meta!.isFailureNotice, isTrue);
      expect(meta.jobName, '销售日报');
      expect(meta.consecutiveFailures, 3);
      expect(meta.failureThreshold, 3);
      expect(meta.lastErrorMessage, 'llm.upstream_timeout');
    });

    test('kind=cron_trigger (future WuKong extra) → trigger', () {
      // 文档预期: 未来 WuKong chip extra 用 kind=cron_trigger 同款语义.
      final meta = CronMessageMetadata.tryParse({
        'kind': 'cron_trigger',
        'cron_job_name': '日报',
      });
      expect(meta?.isTrigger, isTrue);
    });

    test('displayJobLabel falls back to "定时任务" when name missing', () {
      final meta = CronMessageMetadata.tryParse({'triggered_by': 'cron'});
      expect(meta?.displayJobLabel, '定时任务');
    });

    test('numeric strings parsed for int fields', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'cron_owner_account_id': '17',
        'cron_agent_id': '99',
      });
      expect(meta?.ownerAccountId, 17);
      expect(meta?.agentId, 99);
    });

    test('whitespace-only string values treated as empty', () {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'cron_job_name': '   ',
      });
      expect(meta?.jobName, isNull);
      expect(meta?.displayJobLabel, '定时任务');
    });
  });
}
