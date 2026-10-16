import 'package:dio/dio.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zhiban_core/chat/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';


/// Message receipts remain separate from delivery state. Requests are serialized:
/// old HTTP responses cannot overwrite a newer receipt response.
class ChatReceiptsController extends ChangeNotifier {
  ChatReceiptsController({
    required this.conversationUuid,
    required OpenClawChatService service,
    Duration debounce = const Duration(milliseconds: 100),
    this.cacheScope,
    this.initialTimeout = const Duration(seconds: 5),
  })  : _service = service,
        _debounce = debounce {
    _identity = cacheScope == null ? ChatCacheScope.resolved : null;
    _snapshots.addAll(_memorySnapshots[_cacheKey] ?? {});
  }

  final String conversationUuid;
  final OpenClawChatService _service;
  final Duration _debounce;
  final Duration initialTimeout;

  /// Explicit scope for isolated tests; production resolves authenticated scope.
  final String? cacheScope;
  ChatCacheScope? _identity;
  ChatLocalStore? _store;
  int _storeRevision = 0;
  String? get _cacheKey => cacheScope != null
      ? '$cacheScope/$conversationUuid'
      : _identity == null
          ? null
          : '${_identity!.key}/${_identity!.generation}/$conversationUuid';
  static final Map<String, Map<int, ChatReceiptSnapshot>> _memorySnapshots = {};
  static void debugClearMemoryCache() => _memorySnapshots.clear();

  final Map<int, ChatReceiptSnapshot> _snapshots = {};
  final Set<int> _pending = {};
  final Set<int> _watchedSeqs = {};
  final Set<int> _attempted = {};
  final Map<int, int> _invalidations = {};
  Timer? _flushTimer;
  Future<void>? _flushing;
  Future<void>? _preparing;
  bool _restoreExpired = false;
  bool _restored = false;
  final Set<int> _initialSeqs = {};
  int _initialReadSeq = 0;
  bool _disposed = false;
  bool accessDenied = false;
  int _reportedSeq = 0;
  int _pendingReadSeq = 0;
  int _readFailures = 0;
  bool _reporting = false;
  Timer? _markReadTimer;

  bool hasSnapshots(Iterable<int> seqs) =>
      seqs.where((s) => s > 0).every(_snapshots.containsKey);

  ChatReceiptSnapshot? snapshotFor(int seq) => _snapshots[seq];

  /// Called before the pane exposes its first message frame. Disk restore and
  /// missing receipt fetch have one bounded gate; cached summaries need no HTTP
  /// round-trip before rendering. Re-entry still refreshes authoritative values.
  Future<void> prepareInitial(Iterable<int> seqs, {int readThrough = 0}) {
    if (_disposed) return Future<void>.value();
    if (readThrough > _initialReadSeq) _initialReadSeq = readThrough;
    _initialSeqs.addAll(seqs.where((s) => s > 0));
    if (_restored) {
      reportReadWatermark(_initialReadSeq);
      for (final seq in _initialSeqs) {
        if (_attempted.add(seq)) {
          _pending.add(seq);
        }
      }
    }
    return _preparing ??= _prepareInitial();
  }

  Future<void> _prepareInitial() async {
    final deadline = DateTime.now().add(initialTimeout);
    try {
      await _restore().timeout(initialTimeout);
      if (_disposed) return;
      _restored = true;
      // Reading this conversation does not depend on querying who read our
      // outgoing messages. Keep the watermark independent of the display gate.
      reportReadWatermark(_initialReadSeq);
      _watchedSeqs.addAll(_initialSeqs);
      if (_initialSeqs.any((s) => !_snapshots.containsKey(s))) {
        // A mixed cache hit must revalidate old snapshots as well as fill gaps.
        _pending.addAll(_initialSeqs);
      }
      _attempted.addAll(_initialSeqs);
      if (_pending.isNotEmpty) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw TimeoutException('receipt deadline');
        }
        await _flush().timeout(remaining);
      } else {
        refreshNow(_initialSeqs);
      }
    } on TimeoutException {
      // The pane opens with explicit unknown state, never an invented receipt.
      _restoreExpired = true;
      debugPrint('[chat-receipts] initial snapshot timed out');
    }
  }

  Future<void> _restore() async {
    if (cacheScope != null) return;
    try {
      _identity = await ChatCacheScope.current();
      final identity = _identity;
      if (identity == null || _disposed || _restoreExpired) return;
      _store = await ChatLocalStore.shared;
      _storeRevision = _store!.revision(identity.key, conversationUuid);
      final cached =
          await _store!.read(identity.key, conversationUuid, 'receipts');
      if (_disposed || _restoreExpired || !await identity.isCurrent()) return;
      _snapshots.addAll(_memorySnapshots[_cacheKey] ?? {});
      for (final item in (cached?['items'] as List? ?? const [])) {
        final snap =
            ChatReceiptSnapshot.fromJson((item as Map).cast<String, dynamic>());
        _snapshots.putIfAbsent(snap.messageSeq, () => snap);
      }
    } catch (e) {
      debugPrint('[chat-receipts] cache unavailable (${e.runtimeType})');
    }
  }

  void requestSeqs(Iterable<int> seqs) {
    if (_disposed || conversationUuid.isEmpty) return;
    for (final seq in seqs) {
      if (seq > 0 && !_snapshots.containsKey(seq) && _attempted.add(seq)) {
        _pending.add(seq);
      }
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_disposed || _pending.isEmpty || _flushing != null) return;
    // A burst cannot perpetually restart the timer and starve a request.
    _flushTimer ??= Timer(_debounce, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  void invalidate(int seq) {
    if (_disposed) return;
    _invalidations[seq] = (_invalidations[seq] ?? 0) + 1;
    _pending.remove(seq);
    _attempted.remove(seq);
    if (_snapshots.remove(seq) != null) {
      _memorySnapshots[_cacheKey]?.remove(seq);
      unawaited(_persist());
      notifyListeners();
    }
  }

  void refreshNow(Iterable<int> seqs) {
    if (_disposed || conversationUuid.isEmpty) return;
    _pending.addAll(seqs.where((s) => s > 0));
    _scheduleFlush();
  }

  void recordSentSeqs(Iterable<int> seqs) {
    final next = seqs.where((s) => s > 0).toSet().toList()..sort();
    _watchedSeqs
      ..clear()
      ..addAll(next.skip(next.length > 50 ? next.length - 50 : 0));
    requestSeqs(_watchedSeqs);
  }

  void refreshReadThrough(int watermark) {
    refreshNow(_watchedSeqs.where((seq) => seq <= watermark));
  }

  Future<void> _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _flushing ??= _drain().whenComplete(() {
      _flushing = null;
      _scheduleFlush();
    });
  }

  Future<void> _drain() async {
    while (!_disposed && _pending.isNotEmpty) {
      final seqs = _pending.take(100).toList();
      final versions = {for (final s in seqs) s: _invalidations[s] ?? 0};
      _pending.removeAll(seqs);
      try {
        if (_identity != null && !await _identity!.isCurrent()) return;
        final items = await _service.getReadReceipts(
            conversationId: conversationUuid, messageSeqs: seqs);
        if (_disposed || (_identity != null && !await _identity!.isCurrent())) {
          return;
        }
        accessDenied = false;
        for (final item in items) {
          final snap = ChatReceiptSnapshot.fromJson(item);
          if (versions.containsKey(snap.messageSeq) &&
              versions[snap.messageSeq] ==
                  (_invalidations[snap.messageSeq] ?? 0)) {
            _snapshots[snap.messageSeq] = snap;
          }
        }
        if (_snapshots.length > 1000) {
          final keys = _snapshots.keys.toList()..sort();
          for (final seq in keys.take(keys.length - 1000)) {
            _snapshots.remove(seq);
          }
        }
        final key = _cacheKey;
        if (key != null) {
          if (_memorySnapshots.length >= 200) {
            _memorySnapshots.remove(_memorySnapshots.keys.first);
          }
          _memorySnapshots[key] = Map.of(_snapshots);
        }
        unawaited(_persist());
        notifyListeners();
      } catch (e) {
        if (e is DioException && [401, 403].contains(e.response?.statusCode)) {
          accessDenied = true;
          _snapshots.clear();
          _memorySnapshots.remove(_cacheKey);
          if (_identity != null) {
            await _store?.remove(_identity!.key, conversationUuid);
          }
          if (!_disposed) notifyListeners();
        }
        debugPrint('[chat-receipts] refresh failed (${e.runtimeType})');
        // Keep last real snapshot. Re-entry/reconnect/manual refresh can retry.
      }
    }
  }

  Future<void> _persist() async {
    final identity = _identity;
    final store = _store;
    if (identity == null || store == null || _disposed) return;
    try {
      if (!await identity.isCurrent() || _disposed) return;
      final entries = _snapshots.values.toList()
        ..sort((a, b) => a.messageSeq.compareTo(b.messageSeq));
      await store.write(
          identity.key,
          conversationUuid,
          'receipts',
          {
            'items': entries
                .skip(entries.length > 1000 ? entries.length - 1000 : 0)
                .map((s) => {
                      'message_seq': s.messageSeq,
                      'read_count': s.readCount,
                      'unread_count': s.unreadCount,
                      'all_read': s.allRead
                    })
                .toList(),
          },
          expectedRevision: _storeRevision);
    } catch (e) {
      debugPrint('[chat-receipts] cache write failed (${e.runtimeType})');
    }
  }

  /// First watermark is immediate; subsequent watermarks coalesce behind the
  /// in-flight request. Acknowledged and desired watermarks are independent.
  void reportReadWatermark(int seq, {Iterable<int> selfSeqs = const []}) {
    if (_disposed || conversationUuid.isEmpty || seq <= _reportedSeq) return;
    if (seq > _pendingReadSeq) _pendingReadSeq = seq;
    if (!_reporting && _markReadTimer == null) unawaited(_reportRead());
  }

  Future<void> _reportRead() async {
    if (_disposed || _reporting || _pendingReadSeq <= _reportedSeq) return;
    _reporting = true;
    final seq = _pendingReadSeq;
    try {
      if (_identity != null && !await _identity!.isCurrent()) {
        _pendingReadSeq = _reportedSeq;
        return;
      }
      await _service.markConversationRead(conversationUuid,
          lastReadMessageSeq: seq);
      if (_disposed) return;
      if (_identity != null && !await _identity!.isCurrent()) {
        _pendingReadSeq = _reportedSeq;
        return;
      }
      _reportedSeq = seq;
      _readFailures = 0;
    } catch (e) {
      _readFailures++;
      debugPrint('[chat-receipts] watermark failed (${e.runtimeType})');
    } finally {
      _reporting = false;
      if (!_disposed && _pendingReadSeq > _reportedSeq && _readFailures <= 3) {
        _markReadTimer = Timer(
            _readFailures == 0
                ? const Duration(milliseconds: 200)
                : Duration(seconds: 1 << (_readFailures - 1)), () {
          _markReadTimer = null;
          unawaited(_reportRead());
        });
      }
    }
  }

  void onReconnect() {
    _readFailures = 0;
    refreshNow(_watchedSeqs);
    if (!_reporting && _markReadTimer == null) unawaited(_reportRead());
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _markReadTimer?.cancel();
    super.dispose();
  }
}
