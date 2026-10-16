import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

import '../models/prewarm_task.dart';

/// doc-10 S6 客户端预热 service：只调 /api/agent-bus/v1/runtime/*（不碰 admin API）。
/// baseUrl 由 RequestInterceptor 注入，故路径不带 /api/agent-bus/v1 前缀。
class PrewarmService {
  const PrewarmService();

  static const String _ensure = '/runtime/ensure';
  static const String _tasks = '/runtime/tasks';

  /// 登录后调一次：触发预热，立即返回任务清单 + 降级信息。
  Future<PrewarmEnsureResult> ensure() async {
    final response = await request.post(
      _ensure,
      data: const <String, dynamic>{},
      options: Options(extra: const {'diagnosticOperation': 'runtime.ensure'}),
    );
    return PrewarmEnsureResult.fromJson(responseAsMap(response));
  }

  /// 轮询：当前用户预热任务列表。
  Future<List<PrewarmTask>> listTasks() async {
    final map = responseAsMap(await request.get(
      _tasks,
      options: Options(extra: const {'diagnosticOperation': 'runtime.tasks'}),
    ));
    final raw = map['items'];
    if (raw is! List) return const <PrewarmTask>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(PrewarmTask.fromJson)
        .toList();
  }
}
