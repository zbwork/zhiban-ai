import 'package:flutter_test/flutter_test.dart';
import 'package:wukongimfluttersdk/db/message.dart';

void main() {
  group('latest history remote sync policy', () {
    test('initial latest-page load always reconciles with the server', () {
      expect(
        shouldForceLatestHistoryRemoteSync(
          oldestOrderSeq: 0,
          pullMode: 0,
          forceRemoteLatest: true,
          initialAttempt: true,
        ),
        isTrue,
      );
    });

    test('recursive local read after sync does not sync again', () {
      expect(
        shouldForceLatestHistoryRemoteSync(
          oldestOrderSeq: 0,
          pullMode: 0,
          forceRemoteLatest: true,
          initialAttempt: false,
        ),
        isFalse,
      );
    });

    test('older-page pagination keeps the existing gap policy', () {
      expect(
        shouldForceLatestHistoryRemoteSync(
          oldestOrderSeq: 12000,
          pullMode: 0,
          forceRemoteLatest: true,
          initialAttempt: true,
        ),
        isFalse,
      );
    });

    test('normal cached latest-page load stays local-first', () {
      expect(
        shouldForceLatestHistoryRemoteSync(
          oldestOrderSeq: 0,
          pullMode: 0,
          forceRemoteLatest: false,
          initialAttempt: true,
        ),
        isFalse,
      );
    });
  });
}
