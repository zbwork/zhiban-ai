import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/wukong_history_completion.dart';

void main() {
  group('waitForWukongHistory', () {
    test('syncBack 只表示远端同步开始, 不提前完成空历史', () async {
      final future = waitForWukongHistory<String>(
        fallbackTimeout: const Duration(milliseconds: 300),
        start: (completeWithMessages, onRemoteSyncStarted) {
          onRemoteSyncStarted();
          Future<void>.delayed(const Duration(milliseconds: 100), () {
            completeWithMessages(const ['hello']);
          });
        },
      );

      final early = await future.timeout(
        const Duration(milliseconds: 20),
        onTimeout: () => const ['not-yet'],
      );
      expect(early, const ['not-yet']);

      await expectLater(future, completion(const ['hello']));
    });

    test('结果回调不来时抛超时，不能伪造空历史', () async {
      final future = waitForWukongHistory<String>(
        fallbackTimeout: const Duration(milliseconds: 10),
        start: (_, onRemoteSyncStarted) {
          onRemoteSyncStarted();
        },
      );

      await expectLater(future, throwsA(isA<TimeoutException>()));
    });
  });
}
