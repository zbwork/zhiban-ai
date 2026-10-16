import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

final localRuntimeApiProvider =
    Provider<LocalRuntimeApi>((ref) => LocalRuntimeApi());
final localDesktopOnlineProvider =
    StateProvider.autoDispose<bool>((ref) => false);
final localDesktopStatusMessageProvider =
    StateProvider.autoDispose<String>((ref) => '正在确认电脑状态…');

class LocalDesktopStatus {
  const LocalDesktopStatus({required this.available, required this.message});
  final bool available;
  final String message;
  factory LocalDesktopStatus.fromJson(Map<String, dynamic> data) {
    final available = data['available'] == true ||
        (!data.containsKey('available') && data['online'] == true);
    return LocalDesktopStatus(
        available: available,
        message: available
            ? '电脑在线，任务将在电脑上执行'
            : data['reason'] == 'upgrade_required'
                ? '电脑已在线，请更新电脑端后再派活'
                : '电脑未在线，请打开电脑端知办AI');
  }
}

/// Login-authenticated client control plane; never carries the desktop run capability.
class LocalRuntimeApi {
  // Control-plane polling must not inherit the chat stream's 900-second timeout.
  Future<T> _bounded<T>(Future<T> Function(CancelToken) action) async {
    final cancel = CancelToken();
    return action(cancel).timeout(const Duration(seconds: 5), onTimeout: () {
      cancel.cancel('Local control request timed out');
      throw TimeoutException('Local control request timed out');
    });
  }

  Future<Map<String, dynamic>> conversation(String id) async {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) return {};
    return responseAsMap(await _bounded((cancel) =>
        request.get('/local-runtime/conversations/$id', cancelToken: cancel,
            options: Options(extra: {'silent': true}))));
  }

  Future<LocalDesktopStatus> desktopStatus() async =>
      LocalDesktopStatus.fromJson(responseAsMap(await _bounded((cancel) =>
          request.get('/local-runtime/desktop', cancelToken: cancel,
              options: Options(extra: {'silent': true})))));

  Future<bool> online() async => (await desktopStatus()).available;

  Future<List<Map<String, dynamic>>> approvals(String conversation) async {
    if (conversation.isNotEmpty &&
        !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(conversation)) {
      return [];
    }
    final data = responseAsMap(await _bounded((cancel) => request.get(
        '/local-runtime/approvals',
        cancelToken: cancel,
        options: Options(extra: {'silent': true}),
        queryParameters: {'conversation_id': conversation})));
    return (data['items'] as List? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>> decide(
      Map<String, dynamic> approval, bool approved, String scope) async {
    final result = responseAsMap(await _bounded((cancel) => request.post(
            '/local-runtime/approvals/${approval['id']}',
            cancelToken: cancel,
            data: {
              'revision': approval['revision'],
              'intent_hash': approval['intent_hash'],
              'approved': approved,
              'scope': scope,
            })));
    if (!['approved', 'rejected', 'expired'].contains(result['status'])) {
      throw StateError('审批状态尚未确认');
    }
    return result;
  }
}
