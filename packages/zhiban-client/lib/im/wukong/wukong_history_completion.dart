import 'dart:async';

typedef WukongHistoryStart<T> = void Function(
  void Function(List<T> items) completeWithMessages,
  void Function() onRemoteSyncStarted,
);

/// Bridges WuKong SDK history callbacks into one Future.
///
/// The SDK's `syncBack` callback means "remote sync has started", not
/// "history is complete". Completing on it makes a cold conversation render an
/// empty state before `/im/wukong/messagesync` has returned.
Future<List<T>> waitForWukongHistory<T>({
  required WukongHistoryStart<T> start,
  Duration fallbackTimeout = const Duration(seconds: 20),
}) {
  final completer = Completer<List<T>>();

  void completeWithMessages(List<T> items) {
    if (!completer.isCompleted) {
      completer.complete(List<T>.unmodifiable(items));
    }
  }

  start(
    completeWithMessages,
    () {
      // Remote sync just started. Wait for the real result callback or the
      // timeout error below.
    },
  );

  // A missing callback is a failed read, never authoritative empty history.
  return completer.future.timeout(fallbackTimeout);
}
