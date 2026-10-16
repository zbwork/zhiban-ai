import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';

void main() {
  test(
      'business responses keep their meaning while transport failures are network errors',
      () {
    final options = RequestOptions(path: '/cron/jobs');
    expect(taskUserMessage(DioException(requestOptions: options)),
        '网络异常，请检查网络后重试');
    expect(
        taskUserMessage(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 400),
          error: 'cron.run_active',
        )),
        '该任务正在排队或执行，请等待本次完成。');
  });

  test('taskUserMessage hides internal cron capability details', () {
    expect(
      taskUserMessage(
        'cron.agent_not_supported: agent 5123d597-2fef-4061-848d-73a70e79049c runtime framework="custom"',
      ),
      '该数字员工当前不支持自动任务，请更换数字员工或联系管理员。',
    );
  });
}
