import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'chat_local_store.dart';

/// Raw Bus DTOs are stored losslessly. Runtime partials remain in ChatNotifier;
/// only authenticated server snapshots enter this durable cache.
class ChatHistoryRepository {
  ChatHistoryRepository(
      {required this.dio,
      this.store,
      this.scopeResolver = ChatCacheScope.current});
  final Dio dio;
  final ChatLocalStore? store;
  final Future<ChatCacheScope?> Function() scopeResolver;
  final Map<String, Future<List<Map<String, dynamic>>>> _requests = {};

  final Map<String, Future<void>> _queues = {};

  static const _conversationListKey = '@conversation-list';
  int _listRequest = 0;

  Future<List<Map<String, dynamic>>?> cachedConversationList() async {
    final identity = await scope();
    if (identity == null) return null;
    final db = await _store();
    try {
      final row = await db?.read(identity.key, _conversationListKey, 'list');
      if (row == null || !await _current(identity)) return null;
      final items = _items(row);
      debugPrint('[conversation-cache] hit count=${items.length}');
      return items;
    } catch (e) {
      debugPrint('[conversation-cache] read failed (${e.runtimeType})');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> conversationList(
      Map<String, dynamic> query,
      {required bool cacheDefaultPage}) async {
    final identity = await scope();
    final requestId = cacheDefaultPage ? ++_listRequest : 0;
    final db = cacheDefaultPage && identity != null ? await _store() : null;
    final revision = identity == null
        ? 0
        : db?.revision(identity.key, _conversationListKey) ?? 0;
    try {
      final response = await dio.get('/chat/conversations',
          queryParameters: query,
          options: Options(
              receiveTimeout: const Duration(seconds: 20),
              extra: {'silent': true, 'pageRead': true}));
      if (!await _current(identity)) throw StateError('聊天账号已切换');
      final items = _items(responseAsMap(response));
      if (db != null && identity != null && requestId == _listRequest) {
        try {
          await db.write(
              identity.key, _conversationListKey, 'list', {'items': items},
              expectedRevision: revision);
        } catch (e) {
          debugPrint('[conversation-cache] write failed (${e.runtimeType})');
        }
      }
      return items;
    } on DioException catch (error) {
      if (identity != null &&
          db != null &&
          [401, 403].contains(error.response?.statusCode)) {
        await db.remove(identity.key, _conversationListKey);
      }
      rethrow;
    }
  }

  Future<void> deleteConversation(String conversation) async {
    final identity = await scope();
    final db = identity == null ? null : await _store();
    if (identity != null) await db?.remove(identity.key, conversation);
    await dio.delete('/chat/conversations/${Uri.encodeComponent(conversation)}');
    if (identity != null) {
      await db?.removeListItem(
          identity.key, _conversationListKey, 'list', conversation);
    }
  }

  Future<ChatCacheScope?> scope() async {
    try {
      return await scopeResolver();
    } catch (_) {
      return null;
    }
  }

  Future<ChatLocalStore?> _store() async {
    try {
      return store ?? await ChatLocalStore.shared;
    } catch (e) {
      debugPrint('[chat-cache] database unavailable (${e.runtimeType})');
      return null;
    }
  }

  Future<bool> _current(ChatCacheScope? identity) async {
    if (identity == null) return true;
    final now = await scope();
    return now?.key == identity.key && now?.generation == identity.generation;
  }

  Future<List<Map<String, dynamic>>> cached(String conversation,
      {String? clearedAt}) async {
    final identity = await scope();
    if (identity == null) return [];
    final db = await _store();
    try {
      final row = await db?.read(identity.key, conversation, 'history');
      if (!await _current(identity)) return [];
      final items = _items(row);
      final cutoff = DateTime.tryParse(clearedAt ?? '');
      if (cutoff != null &&
          items.any((item) {
            final created =
                DateTime.tryParse(item['created_at']?.toString() ?? '');
            return created == null || !created.isAfter(cutoff);
          })) {
        await db?.remove(identity.key, conversation);
        return [];
      }
      return items;
    } catch (e) {
      debugPrint('[chat-cache] read failed (${e.runtimeType})');
      return [];
    }
  }

  static List<Map<String, dynamic>> _items(Map<String, dynamic>? row) =>
      (row?['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  static String _id(Map<String, dynamic> item) =>
      (item['uuid'] ?? '').toString();

  Future<void> remove(String conversation) async {
    final identity = await scope();
    if (identity == null) return;
    final db = await _store();
    await db?.remove(identity.key, conversation);
  }

  Future<List<Map<String, dynamic>>> _fetch(
      String conversation,
      String suffix,
      Map<String, dynamic> query,
      ChatCacheScope? identity,
      ChatLocalStore? db) async {
    if (!await _current(identity)) throw StateError('聊天账号已切换');
    try {
      final result = await dio.get(
          '/chat/conversations/${Uri.encodeComponent(conversation)}/messages$suffix',
          queryParameters: query,
          options: Options(
              receiveTimeout: const Duration(seconds: 20),
              extra: {'silent': true}));
      if (!await _current(identity)) throw StateError('聊天账号已切换');
      return _items(responseAsMap(result));
    } on DioException catch (e) {
      if ([401, 403, 404].contains(e.response?.statusCode) &&
          identity != null) {
        await db?.remove(identity.key, conversation);
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> latest(String conversation,
      {int limit = 50, bool incremental = false, String? before}) async {
    final identity = await scope();
    final key =
        '${identity?.key}/${identity?.generation}/$conversation/$limit/$incremental/$before';
    final existing = _requests[key];
    if (existing != null) return existing;
    final queueKey = '${identity?.key}/${identity?.generation}/$conversation';
    final previous = _queues[queueKey] ?? Future<void>.value();
    final operation = previous.then((_) => _load(conversation, identity,
        limit: limit, incremental: incremental, before: before));
    final finished =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _queues[queueKey] = finished;
    return _requests[key] = operation.whenComplete(() {
      _requests.remove(key);
      if (identical(_queues[queueKey], finished)) _queues.remove(queueKey);
    });
  }

  Future<List<Map<String, dynamic>>> _load(
      String conversation, ChatCacheScope? identity,
      {required int limit, required bool incremental, String? before}) async {
    final db = identity == null ? null : await _store();
    final revision =
        identity == null ? 0 : db?.revision(identity.key, conversation) ?? 0;
    Map<String, dynamic>? row;
    try {
      if (identity != null) {
        row = await db?.read(identity.key, conversation, 'history');
      }
    } catch (e) {
      debugPrint('[chat-cache] read failed (${e.runtimeType})');
    }
    final old = _items(row);
    var next = List<Map<String, dynamic>>.of(old);
    List<Map<String, dynamic>> result;
    if (before != null && before.isNotEmpty) {
      final anchor = old.indexWhere((e) => _id(e) == before);
      if (anchor >= limit || (anchor >= 0 && row?['complete_before'] == true)) {
        return old.sublist(anchor > limit ? anchor - limit : 0, anchor);
      }
      // before includes the anchor. Existing Bus accepts after >= 1; discard
      // the anchor and newer side rather than pretending latest supports offset.
      final around = await _fetch(
          conversation,
          '/around',
          {
            'anchor_message_uuid': before,
            'before': limit + 1,
            'after': 1,
          },
          identity,
          db);
      final index = around.indexWhere((e) => _id(e) == before);
      if (index < 0) throw StateError('历史分页锚点不存在');
      result = around.take(index).toList();
      // Only extend a contiguous cached window. Search/around pages must not
      // silently bridge a gap to the newest tail.
      if (anchor >= 0) {
        final ids = result.map(_id).toSet();
        next = [...result, ...old.where((e) => !ids.contains(_id(e)))];
        if (result.length < limit) row = {...?row, 'complete_before': true};
      }
    } else if (incremental && old.isNotEmpty) {
      // Update tail and unfinished rows independently of append-only sync.
      final anchors = <String>{
        _id(old.last),
        ...old
            .where((e) => ['streaming', 'pending', 'running', 'awaiting_user']
                .contains(e['status']))
            .map(_id)
      };
      for (final anchor in anchors) {
        final updates = await _fetch(
            conversation,
            '/around',
            {
              'anchor_message_uuid': anchor,
              'before': 1,
              'after': 1,
            },
            identity,
            db);
        final byId = {for (final e in updates) _id(e): e};
        next = next
            .map((e) => byId.containsKey(_id(e))
                ? <String, dynamic>{...e, ...byId[_id(e)]!}
                : e)
            .toList();
      }
      var cursor = _id(old.last);
      final seenCursors = <String>{cursor};
      while (true) {
        final newer = await _fetch(
            conversation,
            '/newer',
            {
              'since_message_uuid': cursor,
              'limit': 100,
            },
            identity,
            db);
        if (newer.isEmpty) break;
        final newCursor = _id(newer.last);
        if (newCursor.isEmpty || !seenCursors.add(newCursor)) {
          throw StateError('聊天增量同步游标未前进');
        }
        final ids = next.map(_id).toSet();
        next.addAll(newer.where((e) => ids.add(_id(e))));
        cursor = newCursor;
        if (newer.length < 100) break;
      }
      result = next;
    } else {
      result = await _fetch(conversation, '', {'limit': limit}, identity, db);
      // A latest-page refresh can skip an offline gap. Replace the cached
      // window rather than claiming the old and new tails are contiguous.
      final overlap = result.isEmpty
          ? -1
          : old.indexWhere((e) => _id(e) == _id(result.first));
      if (overlap >= 0 && result.length >= limit) {
        next = [...old.take(overlap), ...result];
      } else {
        next = result;
        row = {'complete_before': result.length < limit};
      }
    }
    if (!await _current(identity)) throw StateError('聊天账号已切换');
    if (identity != null && db != null) {
      if (revision != db.revision(identity.key, conversation)) {
        throw StateError('聊天缓存已清除，请重新打开会话');
      }
      final truncated = next.length > 1000;
      if (truncated) next = next.sublist(next.length - 1000);
      try {
        await db.write(
            identity.key,
            conversation,
            'history',
            {
              'items': next,
              'complete_before': !truncated && row?['complete_before'] == true,
            },
            expectedRevision: revision);
      } catch (e) {
        debugPrint('[chat-cache] write failed (${e.runtimeType})');
      }
    }
    return result;
  }
}
