import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/wukong_incremental_history.dart';

void main() {
  test('offline tail larger than one page is fully synchronized', () async {
    final cursors = <int>[];
    final result = await loadIncrementalHistory<int>(
        afterSeq: 10,
        fetch: (cursor) async {
          cursors.add(cursor);
          return cursor == 10
              ? const HistoryDeltaPage([11, 12], 12, true)
              : const HistoryDeltaPage([13], 13, false);
        });
    expect(cursors, [10, 12]);
    expect(result, [11, 12, 13]);
  });
  test('non-progressing server cursor fails instead of skipping a gap',
      () async {
    await expectLater(
        loadIncrementalHistory<int>(
            afterSeq: 10,
            fetch: (_) async => const HistoryDeltaPage([], 10, true)),
        throwsStateError);
  });
}
