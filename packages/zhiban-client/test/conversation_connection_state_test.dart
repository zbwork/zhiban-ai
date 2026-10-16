import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_connection_state.dart';

void main() {
  final options = RequestOptions(path: '/im/credentials');
  for (final type in DioExceptionType.values) {
    test('classifies Dio $type without inferring device offline', () {
      final error = DioException(requestOptions: options, type: type);
      final expected = switch (type) {
        DioExceptionType.cancel => ConversationConnectionState.cancelled,
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          ConversationConnectionState.unavailable,
        _ => ConversationConnectionState.setupFailed,
      };
      expect(ConversationConnectionState.fromError(error), expected);
    });
  }
  for (final entry in {
    400: ConversationConnectionState.setupFailed,
    401: ConversationConnectionState.authenticationRequired,
    403: ConversationConnectionState.authenticationRequired,
    429: ConversationConnectionState.rateLimited,
    500: ConversationConnectionState.unavailable,
    502: ConversationConnectionState.unavailable,
    503: ConversationConnectionState.unavailable,
    504: ConversationConnectionState.unavailable,
  }.entries) {
    test('classifies HTTP ${entry.key}', () {
      expect(
          ConversationConnectionState.fromError(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: entry.key),
          )),
          entry.value);
    });
  }
  for (final entry in {
    'imcred.refresh_expired':
        ConversationConnectionState.authenticationRequired,
    'imcred.device_mismatch':
        ConversationConnectionState.authenticationRequired,
    'imcred.refresh_invalid':
        ConversationConnectionState.authenticationRequired,
    'imcred.cross_tenant': ConversationConnectionState.authenticationRequired,
    'imcred.rate_limited': ConversationConnectionState.rateLimited,
    'imcred.wukong_upstream': ConversationConnectionState.unavailable,
    'wukong_disabled': ConversationConnectionState.setupFailed,
    'unknown': ConversationConnectionState.setupFailed,
  }.entries) {
    test('classifies business error ${entry.key}', () {
      expect(
          ConversationConnectionState.fromError(
              IMCredentialsException(entry.key)),
          entry.value);
    });
  }
  for (final error in <Object>[
    const SocketException('DNS failed'),
    TimeoutException('handshake timed out'),
    StateError('setup failed'),
    const FormatException('invalid response'),
  ]) {
    test('classifies ${error.runtimeType} and wrapped unknown errors', () {
      final expected = error is SocketException || error is TimeoutException
          ? ConversationConnectionState.unavailable
          : ConversationConnectionState.setupFailed;
      expect(ConversationConnectionState.fromError(error), expected);
      expect(
          ConversationConnectionState.fromError(DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: error,
          )),
          expected);
    });
  }
  test('only confirmed device offline displays banner in every IM state', () {
    for (final connection in ConversationConnectionState.values) {
      for (final network in ConversationNetworkState.values) {
        final snapshot = ConversationConnectionSnapshot(connection, network);
        expect(snapshot.isOffline, network == ConversationNetworkState.offline);
        expect(
            snapshot.isUnavailable, snapshot.isOffline || connection.isFailure);
      }
    }
  });
}
