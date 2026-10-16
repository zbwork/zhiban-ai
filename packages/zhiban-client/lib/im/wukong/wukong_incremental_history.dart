/// Pull every missing page. A non-advancing cursor is an error, never a reason
/// to silently declare a partially synchronized conversation up to date.
class HistoryDeltaPage<T> {
  const HistoryDeltaPage(this.items, this.lastSeq, this.hasMore);
  final List<T> items;
  final int lastSeq;
  final bool hasMore;
}

Future<List<T>> loadIncrementalHistory<T>({
  required int afterSeq,
  required Future<HistoryDeltaPage<T>> Function(int cursor) fetch,
}) async {
  final items = <T>[];
  var cursor = afterSeq;
  while (true) {
    final page = await fetch(cursor);
    items.addAll(page.items);
    if (!page.hasMore) return items;
    if (page.lastSeq <= cursor) throw StateError('聊天增量同步游标未前进');
    cursor = page.lastSeq;
  }
}
