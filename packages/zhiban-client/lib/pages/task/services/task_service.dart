import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';


import 'package:zhiban_client/pages/task/models/task_models.dart';

final _readOptions = Options(
  receiveTimeout: const Duration(seconds: 15),
  extra: const {'silent': true, 'pageRead': true},
);

class BusTaskService {
  BusTaskService();

  static const String _jobs = '/cron/jobs';
  static const String _runs = '/cron/runs';

  Future<List<CronJob>> listJobs() async {
    final data = responseAsMap(await request.get(_jobs, options: _readOptions));
    final jobs = (data['items'] as List? ?? data['jobs'] as List? ?? const []);
    return jobs
        .whereType<Map>()
        .map((item) => CronJob.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<CronJob> createJob(CronJobDraft draft) async {
    final created = CronJob.fromJson(
      responseAsMap(await request.post(_jobs, data: draft.toCreateJson())),
    );
    if (!draft.enabled) {
      await pauseJob(created.id);
      final detail = responseAsMap(
        await request.get('$_jobs/${Uri.encodeComponent(created.id)}'),
      );
      return CronJob.fromJson(detail);
    }
    return created;
  }

  Future<void> updateJob(String jobId, CronJobDraft draft) async {
    await request.patch(
      '$_jobs/${Uri.encodeComponent(jobId)}',
      data: draft.toUpdateJson(),
    );
  }

  Future<void> updateJobEnabled(String jobId, bool enabled) async {
    if (enabled) {
      await resumeJob(jobId);
    } else {
      await pauseJob(jobId);
    }
  }

  Future<void> pauseJob(String jobId) async {
    await request.post('$_jobs/${Uri.encodeComponent(jobId)}/pause');
  }

  Future<void> resumeJob(String jobId) async {
    await request.post('$_jobs/${Uri.encodeComponent(jobId)}/resume');
  }

  Future<void> deleteJob(String jobId) async {
    await request.delete('$_jobs/${Uri.encodeComponent(jobId)}');
  }

  Future<void> runJobNow(String jobId) async {
    await request.post(
      '$_jobs/${Uri.encodeComponent(jobId)}/run',
      data: const {},
    );
  }

  Future<List<CronRunEntry>> listJobRuns(String jobId, {int limit = 20}) async {
    final data = responseAsMap(
      await request.get(
        '$_jobs/${Uri.encodeComponent(jobId)}/runs',
        queryParameters: {'limit': limit},
      ),
    );
    final entries =
        (data['items'] as List? ?? data['entries'] as List? ?? const []);
    return entries
        .whereType<Map>()
        .map((item) => CronRunEntry.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<List<CronRunEntry>> listRecentRuns({int limit = 20}) async {
    final data = responseAsMap(
      await request
          .get(_runs, options: _readOptions, queryParameters: {'limit': limit}),
    );
    final entries =
        (data['items'] as List? ?? data['entries'] as List? ?? const []);
    return entries
        .whereType<Map>()
        .map((item) => CronRunEntry.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<CronRunOpenChatResponse> openRunChat({
    required CronRunEntry entry,
  }) async {
    final runUUID = (entry.sessionId ?? '').trim();
    if (runUUID.isEmpty) {
      throw Exception('当前运行记录缺少 run_uuid，无法在会话中查看');
    }
    final response = await request.post(
      '$_runs/${Uri.encodeComponent(runUUID)}/open-chat',
      data: const {},
    );
    return CronRunOpenChatResponse.fromJson(responseAsMap(response));
  }
}
