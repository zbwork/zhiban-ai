import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/analytics_service.dart';

void main() {
  test('service and network errors are excluded from Flutter error collection',
      () {
    expect(
      isCollectibleFlutterError(
        DioException(requestOptions: RequestOptions(path: '/auth/me')),
      ),
      isFalse,
    );
    expect(isCollectibleFlutterError(const HttpException('HTTP 500')), isFalse);
    expect(isCollectibleFlutterError(const SocketException('offline')), isFalse);
    expect(
      isCollectibleFlutterError(TimeoutException('request timed out')),
      isFalse,
    );
  });

  test('Flutter and Dart logic errors remain collectible', () {
    expect(isCollectibleFlutterError(FlutterError('layout failed')), isTrue);
    expect(isCollectibleFlutterError(StateError('bad state')), isTrue);
  });

  test('stackless layout errors surface the error-causing widget as first frame',
      () {
    final details = FlutterErrorDetails(
      exception:
          FlutterError('A RenderFlex overflowed by 31 pixels on the bottom.'),
      library: 'rendering library',
      informationCollector: () => [
        ErrorDescription(
          'The relevant error-causing widget was:\n'
          '  Column Column:file:///Users/dev/easyo/apps/zhiban-app/lib/pages/login/login_page.dart:422:36',
        ),
      ],
    );
    final stack = flutterErrorDetailsStack(details).toString();
    expect(stack.split('\n').first, contains('login_page.dart:422:36'));
    expect(stack, contains('RenderFlex overflowed'));
  });

  test('errors with a real stack keep it untouched', () {
    final details = FlutterErrorDetails(
      exception: StateError('bad state'),
      stack: StackTrace.current,
    );
    expect(flutterErrorDetailsStack(details), same(details.stack));
  });
}
