import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

bool isReportableApiError(DioException err) {
  final status = err.response?.statusCode;
  // 400+ 全记（401 已在 response_interceptor 里单独处理跳登录，走到这里说明
  // 已经不是"过期登录态"这种预期内情况）；cancel 之类没有状态码
  // 的类型继续走下面 switch 过滤。
  if (status != null && status >= 400) return true;
  switch (err.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
    case DioExceptionType.badCertificate:
      return true;
    default:
      return false;
  }
}

class ActiveSessionDecision {
  const ActiveSessionDecision({
    required this.sessionId,
    required this.shouldReport,
  });

  final String sessionId;
  final bool shouldReport;
}

bool isCollectibleFlutterError(Object error) =>
    error is! DioException &&
    error is! HttpException &&
    error is! SocketException &&
    error is! TimeoutException;

/// 布局类框架错误（如 RenderFlex overflow）没有调用栈（details.stack 为 null），
/// 之前兜底 StackTrace.current 只能采到本错误处理器自己的帧，看板上无法定位。
/// 改为采诊断文本：其中 "The relevant error-causing widget was:" 的下一行带
/// 出错 widget 的 file:行:列，提到首帧——看板"报错位置"直接可读，且 fingerprint
/// 按首帧计算，不同位置的布局错误不再被合并成同一条。
StackTrace flutterErrorDetailsStack(FlutterErrorDetails details) {
  final stack = details.stack;
  if (stack != null) return stack;
  final text = details.toString();
  final lines = text.split('\n');
  final marker =
      lines.indexWhere((line) => line.contains('error-causing widget'));
  final location =
      marker >= 0 && marker + 1 < lines.length ? lines[marker + 1].trim() : '';
  return StackTrace.fromString(location.isEmpty ? text : '$location\n$text');
}

class ActiveSessionTracker {
  static const timeout = Duration(minutes: 30);
  static const _uuid = Uuid();

  String? _sessionId;
  DateTime? _startedAt;
  bool _activeReported = false;

  ActiveSessionDecision next(DateTime now) {
    _ensureSession(now);
    final shouldReport = !_activeReported;
    _activeReported = true;
    return ActiveSessionDecision(
      sessionId: _sessionId!,
      shouldReport: shouldReport,
    );
  }

  String sessionId(DateTime now) {
    _ensureSession(now);
    return _sessionId!;
  }

  void _ensureSession(DateTime now) {
    final elapsed = _startedAt == null ? null : now.difference(_startedAt!);
    final shouldRenew =
        _sessionId == null || elapsed!.isNegative || elapsed >= timeout;
    if (shouldRenew) {
      _sessionId = _uuid.v4();
      _startedAt = now;
      _activeReported = false;
    }
  }
}

class AnalyticsEventSanitizer {
  const AnalyticsEventSanitizer();

  static final _customEventPattern = RegExp(r'^custom_[a-z][a-z0-9_]{1,47}$');
  static final _propertyKeyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final _sensitiveKeyPattern = RegExp(
    r'(phone|mobile|email|token|secret|password|authorization|content|message|query|filename|file_name)',
    caseSensitive: false,
  );
  static final _bearerPattern = RegExp(
    r'\bbearer\s+[a-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _secretAssignmentPattern = RegExp(
    r'\b(access_token|refresh_token|token|secret|password|authorization)\s*[:=]\s*[^\s&]+',
    caseSensitive: false,
  );
  static final _emailPattern = RegExp(
      r'\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b',
      caseSensitive: false);
  static final _phonePattern = RegExp(r'\b1[3-9][0-9]{9}\b');
  static final _uuidPattern = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final _urlQueryPattern =
      RegExp(r'([?&][a-z0-9_.-]+)=([^&\s]+)', caseSensitive: false);
  static final _unixUserPattern = RegExp(r'/Users/[^/]+/');
  static final _windowsUserPattern =
      RegExp(r'[a-z]:\\Users\\[^\\]+\\', caseSensitive: false);

  bool isCustomEventName(String name) => _customEventPattern.hasMatch(name);

  Map<String, dynamic> customProperties(
    String name,
    Map<String, Object?> properties,
  ) {
    if (!isCustomEventName(name)) return const {};
    final result = <String, dynamic>{};
    for (final entry in properties.entries) {
      if (result.length == 10) break;
      if (!_propertyKeyPattern.hasMatch(entry.key) ||
          _sensitiveKeyPattern.hasMatch(entry.key) ||
          !_isShortPrimitive(entry.value)) {
        continue;
      }
      if (entry.value is String &&
          _redact(entry.value as String) != entry.value) {
        continue;
      }
      result[entry.key] = entry.value;
    }
    return result;
  }

  Map<String, dynamic> errorProperties(
    Object error,
    StackTrace stack, {
    required String mechanism,
  }) {
    final type = _truncate(error.runtimeType.toString(), 128);
    final safeMessage = _truncate(_redact(error.toString()), 512);
    final safeStack = _truncate(_redact(stack.toString()), 8192);
    final firstFrame = safeStack.split('\n').first.replaceAll(
          RegExp(r':[0-9]+:[0-9]+'),
          ':#:#'
        );
    final fingerprint =
        sha256.convert(utf8.encode('$type\n$firstFrame')).toString();
    return {
      'error_type': type,
      'error_message': safeMessage,
      'stacktrace': safeStack,
      'fingerprint': fingerprint,
      'mechanism': mechanism,
      'severity': 'error',
    };
  }

  bool _isShortPrimitive(Object? value) =>
      value is bool || value is num || (value is String && value.length <= 64);

  String _redact(String input) => input
      .replaceAll(_bearerPattern, 'Bearer [redacted]')
      .replaceAllMapped(
        _secretAssignmentPattern,
        (match) => '${match.group(1)}=[redacted]',
      )
      .replaceAll(_emailPattern, '[redacted]')
      .replaceAll(_phonePattern, '[redacted]')
      .replaceAll(_uuidPattern, '[redacted]')
      .replaceAllMapped(
        _urlQueryPattern,
        (match) => '${match.group(1)}=[redacted]',
      )
      .replaceAll(_unixUserPattern, '/Users/[redacted]/')
      .replaceAll(_windowsUserPattern, r'C:\Users\[redacted]\');

  String _truncate(String value, int limit) =>
      value.length <= limit ? value : value.substring(0, limit);
}

class AnalyticsService with WidgetsBindingObserver {
  AnalyticsService._();

  static final instance = AnalyticsService._();
  static const _uuid = Uuid();
  static const _activeSources = {'launch', 'login', 'resume'};

  static const _sanitizer = AnalyticsEventSanitizer();
  final _activeSession = ActiveSessionTracker();
  final _reportDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  // debug 模式(flutter run 本地调试)不走完整发布管线,build number 等
  // 元数据经常缺失/不准确，不应该上报生产分析事件污染看板。
  final bool _enabled = !kDebugMode;
  bool _observingLifecycle = false;
  bool _errorHandlersInstalled = false;
  String _appVersion = '';

  Future<void> initialize() async {
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (error) {
      debugPrint('analytics: metadata initialization failed: $error');
    }
  }

  void installGlobalErrorHandlers() {
    if (_errorHandlersInstalled) return;
    _errorHandlersInstalled = true;
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutterHandler?.call(details);
      recordErrorUnawaited(
        details.exception,
        flutterErrorDetailsStack(details),
        mechanism: 'flutter',
      );
    };
    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      recordErrorUnawaited(error, stack, mechanism: 'platform');
      return previousPlatformHandler?.call(error, stack) ?? false;
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // app_active 按 account_id 去重，退出登录后没有账号可归因，不应再上报。
    if (RequestInterceptor.cachedToken == null) return;
    trackActiveUnawaited('resume');
  }

  Future<void> trackActive(String source) async {
    if (!_enabled || !_activeSources.contains(source)) return;
    final decision = _activeSession.next(DateTime.now());
    if (!decision.shouldReport) return;
    await _track('app_active', decision.sessionId, {'source': source});
  }

  void trackActiveUnawaited(String source) {
    unawaited(trackActive(source));
  }

  Future<void> trackCustom(
    String name, [
    Map<String, Object?> properties = const {},
  ]) async {
    if (!_enabled || !_sanitizer.isCustomEventName(name)) return;
    await _track(
      name,
      _activeSession.sessionId(DateTime.now()),
      _sanitizer.customProperties(name, properties),
    );
  }

  void trackCustomUnawaited(
    String name, [
    Map<String, Object?> properties = const {},
  ]) {
    unawaited(trackCustom(name, properties));
  }

  Future<void> recordError(
    Object error,
    StackTrace stack, {
    String mechanism = 'manual',
  }) async {
    if (!_enabled ||
        !isCollectibleFlutterError(error) ||
        !{'flutter', 'platform', 'manual'}.contains(mechanism)) {
      return;
    }
    await _track(
      'app_error',
      _activeSession.sessionId(DateTime.now()),
      _sanitizer.errorProperties(error, stack, mechanism: mechanism),
    );
  }

  void recordErrorUnawaited(
    Object error,
    StackTrace stack, {
    String mechanism = 'manual',
  }) {
    unawaited(recordError(error, stack, mechanism: mechanism));
  }

  Future<void> recordApiError(DioException err) async {
    if (!_enabled || !isReportableApiError(err)) return;
    final properties = _sanitizer.errorProperties(
      err,
      err.stackTrace,
      mechanism: 'manual',
    );
    final method = err.requestOptions.method;
    final path = err.requestOptions.path;
    final statusCode = err.response?.statusCode;
    final context = statusCode != null
        ? '$method $path (status=$statusCode): '
        : '$method $path: ';
    properties['error_message'] = _sanitizer._truncate(
      '$context${properties['error_message']}',
      512,
    );
    await _track(
      'app_error',
      _activeSession.sessionId(DateTime.now()),
      properties,
    );
  }

  void recordApiErrorUnawaited(DioException err) {
    unawaited(recordApiError(err));
  }

  Future<void> _track(
    String name,
    String sessionId,
    Map<String, Object?> properties,
  ) async {
    if (!_enabled) return;
    try {
      if (!_isSupportedPlatform) return;
      final response = await _reportDio.post<dynamic>(
        '${AppConfig.apiUrl()}/analytics/events',
        options: Options(
          headers: {
            if (RequestInterceptor.cachedToken != null)
              'Authorization': 'Bearer ${RequestInterceptor.cachedToken}',
          },
        ),
        data: {
          'events': [
            {
              'event_id': _uuid.v4(),
              'name': name,
              'schema_version': 1,
              'session_id': sessionId,
              'platform': _platform,
              'app_version': _appVersion,
              'properties': properties,
              'occurred_at': DateTime.now().toUtc().toIso8601String(),
            },
          ],
        },
      );
      final accepted = response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
      if (!accepted) {
        throw StateError(
          'analytics request rejected: status=${response.statusCode}',
        );
      }
      debugPrint('analytics: event accepted: $name');
    } catch (error) {
      debugPrint('analytics: event dropped: name=$name error=$error');
    }
  }

  bool get _isSupportedPlatform =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  String get _platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    return 'windows';
  }
}
