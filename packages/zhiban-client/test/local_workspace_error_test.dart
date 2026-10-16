import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/local_workspace_error.dart';

void main() {
  DioException failure(int status, Object code) => DioException(
      requestOptions: RequestOptions(path: 'private-path'),
      response: Response(
          requestOptions: RequestOptions(path: 'private-path'),
          statusCode: status,
          data: {
            'error': {'code': code, 'message': 'SECRET private details'}
          }));

  test(
      'a rejected conversation stays denied and never offers a new workspace context',
      () {
    final error = LocalWorkspaceError.from(failure(403, 'local.denied'));
    expect(error.message, contains('会话不可访问'));
    expect(error.message, contains('HTTP 403'));
    expect(error.canChooseDirectory, isFalse);
    expect(error.contextId, isEmpty);
  });
  test(
      'unknown errors do not leak codes or response text and do not enable recovery',
      () {
    final error = LocalWorkspaceError.from(
        failure(500, 'SECRET arbitrary code'),
        contextId: 'context');
    expect(error.message, contains('工作目录初始化失败'));
    expect(error.toString(), isNot(contains('SECRET')));
    expect(error.code, 'local.workspace_initialization_failed');
    expect(error.canChooseDirectory, isFalse);
  });
}
