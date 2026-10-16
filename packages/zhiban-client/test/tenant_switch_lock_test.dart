import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('switch lock rejects concurrent callers and releases after failure',
      () async {
    SharedPreferences.setMockInitialValues({});
    final previous = request.interceptors.toList();
    request.interceptors.clear();
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    request.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      calls++;
      if (calls == 1) {
        started.complete();
        await release.future;
      }
      handler.reject(DioException(requestOptions: options));
    }));
    addTearDown(() {
      request.interceptors.clear();
      request.interceptors.addAll(previous);
    });
    final first = switchToTenantApi(2);
    expect(tenantSwitchInProgress.value, true);
    final failed = expectLater(first, throwsA(isA<DioException>()));
    await started.future;
    await expectLater(switchToTenantApi(3), throwsStateError);
    expect(tenantSwitchInProgress.value, true);
    expect(calls, 1);
    release.complete();
    await failed;
    expect(tenantSwitchInProgress.value, false);
    await expectLater(switchToTenantApi(3), throwsA(isA<DioException>()));
    expect(calls, 2);
    expect(tenantSwitchInProgress.value, false);
  });
}
