import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/task/providers/task_provider.dart';
import 'package:zhiban_client/pages/task/services/task_service.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';

class OfflineTasks extends BusTaskService {
  bool offline = true;
  @override
  Future<List<CronJob>> listJobs() async {
    if (offline) throw DioException(requestOptions: RequestOptions(path: '/cron/jobs'), type: DioExceptionType.unknown);
    return [CronJob.fromJson({'uuid': 'job', 'name': '已有任务'})];
  }
  @override
  Future<List<CronRunEntry>> listRecentRuns({int limit = 20}) async => [];
}
void main() {
  test('task offline cold load ends loading; recovery and later failure retain jobs', () async {
    final service = OfflineTasks();
    final container = ProviderContainer(overrides: [taskServiceProvider.overrideWithValue(service)]);
    addTearDown(container.dispose);
    final notifier = container.read(taskPageProvider.notifier);
    await notifier.load();
    expect(container.read(taskPageProvider).isLoading, isFalse);
    expect(container.read(taskPageProvider).errorMessage, isNull);
    service.offline = false;
    await notifier.refresh();
    expect(container.read(taskPageProvider).jobs, hasLength(1));
    service.offline = true;
    await notifier.refresh();
    expect(container.read(taskPageProvider).jobs, hasLength(1));
    expect(container.read(taskPageProvider).errorMessage, isNull);
    expect(container.read(taskPageProvider).isRefreshing, isFalse);
  });
}
