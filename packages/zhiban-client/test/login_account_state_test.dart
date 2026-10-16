import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/login/models/login_account_state.dart';
import 'package:zhiban_client/pages/login/providers/login_account_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fail in [false, true]) {
    test('captcha completion after disposal is ignored (failure=$fail)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final entered = Completer<void>();
      final release = Completer<void>();
      final interceptor =
          InterceptorsWrapper(onRequest: (options, handler) async {
        if (!options.path.endsWith('/auth/captcha')) {
          handler.next(options);
          return;
        }
        entered.complete();
        await release.future;
        if (fail) {
          handler.reject(DioException(requestOptions: options));
        } else {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'success': true,
            'data': {'captchaId': 'test', 'captchaImage': 'test'}
          }));
        }
      });
      request.interceptors.insert(0, interceptor);
      addTearDown(() => request.interceptors.remove(interceptor));
      final container = ProviderContainer();
      final pending =
          container.read(loginAccountProvider.notifier).fetchCaptcha();
      await entered.future;
      container.dispose();
      release.complete();
      await expectLater(pending, completes);
    });
  }

  test('privacy agreement is not selected by default', () {
    expect(const LoginAccountState().agreementChecked, isFalse);
  });

  test('desktop agreement check is separate from mobile account validation',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(loginAccountProvider.notifier);

    expect(notifier.validateAgreement(), isFalse);
    expect(notifier.validateSmsRequest(mobile: '13800138000'), isTrue);
  });
}
