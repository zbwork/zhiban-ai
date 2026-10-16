import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';

enum ConversationNetworkState { unknown, available, confirmingOffline, offline }

enum ConversationConnectionState {
  idle,
  connecting,
  connected,
  recovering,
  unavailable,
  cancelled,
  authenticationRequired,
  rateLimited,
  setupFailed,
  kicked;

  bool get isFailure => switch (this) {
        unavailable ||
        cancelled ||
        authenticationRequired ||
        rateLimited ||
        setupFailed ||
        kicked =>
          true,
        _ => false,
      };

  static ConversationConnectionState fromError(Object error) {
    if (error is IMCredentialsException) {
      if (error.needsReLogin) return authenticationRequired;
      if (error.code == 'imcred.rate_limited') return rateLimited;
      return error.isRetryable ? unavailable : setupFailed;
    }
    if (error is SocketException || error is TimeoutException) {
      return unavailable;
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) return authenticationRequired;
      if (status == 429) return rateLimited;
      if (status != null && status >= 500) return unavailable;
      return switch (error.type) {
        DioExceptionType.cancel => cancelled,
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          unavailable,
        DioExceptionType.unknown
            when error.error is SocketException ||
                error.error is TimeoutException =>
          unavailable,
        _ => setupFailed,
      };
    }
    return setupFailed;
  }
}

class ConversationConnectionSnapshot {
  const ConversationConnectionSnapshot(this.connection, this.network);

  final ConversationConnectionState connection;
  final ConversationNetworkState network;
  bool get isOffline => network == ConversationNetworkState.offline;
  bool get isUnavailable => isOffline || connection.isFailure;
}
