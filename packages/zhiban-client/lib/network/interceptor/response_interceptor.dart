import 'dart:async';
import 'dart:convert';

import 'package:zhiban_client/network/user_refresh.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/network/res_data_model.dart';
import 'package:zhiban_core/network/public_auth_paths.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/analytics_service.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_client/window/window_controller.dart';

/// 响应拦截器
class ResponseInterceptor extends Interceptor {
  static bool _handlingUnauthorized = false;
  static bool _handlingMembershipInactive = false;
  static bool _showingQuotaDialog = false;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.requestOptions.responseType == ResponseType.stream) {
      handler.next(response);
    } else {
      // DELETE 等成功接口可以按 HTTP 语义返回 204 + 空 body。不能把契约规定的
      // 空成功误判成“响应格式异常”（F31 设备撤销即为此形态）。
      if (isSuccessfulNoContent(response.statusCode, response.data)) {
        handler.next(response);
        return;
      }
      if (response.data is! Map) {
        final status = response.statusCode ?? 0;
        final message = status >= 400 ? '请求失败(HTTP $status)' : '响应格式异常';
        final silent = response.requestOptions.extra['silent'] == true;
        final unauthorized = status == 401;
        final shouldHandleUnauthorized =
            unauthorized && !_isPublicAuthRequest(response.requestOptions);
        if (shouldHandleUnauthorized) {
          // 标记后抛错, 由链上后置的 AuthRefreshInterceptor 先尝试静默续期重试,
          // 判定性失败才 forceLogout——不再见 401 就直接踢登录页。
          response.requestOptions.extra['unauthorized'] = true;
        }
        if (!silent && !shouldHandleUnauthorized) {
          BotToast.showText(text: message, align: Alignment.center);
        }
        // 已在此处理并提示，标记后让 onError 原样透传，避免被覆盖成"网络异常"。
        response.requestOptions.extra['errorHandled'] = true;
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          error: message,
        );
      }
      final resDataModel =
          ResDataModel.fromJson((response.data as Map).cast<String, dynamic>());
      if (resDataModel.success != null && !resDataModel.success!) {
        _logApiFailure(
          DioException(
            requestOptions: response.requestOptions,
            response: response,
            type: DioExceptionType.badResponse,
          ),
          traceId: resDataModel.traceId,
          businessCode: resDataModel.message,
        );
        final message = formatBackendErrorMessage(
          resDataModel.message ?? '请求失败',
          fallback: '请求失败',
        );
        final unauthorized = _isUnauthorizedEnvelope(response, resDataModel);
        final shouldHandleUnauthorized =
            unauthorized && !_isPublicAuthRequest(response.requestOptions);
        final membershipInactive = !shouldHandleUnauthorized &&
            _isMembershipInactiveMessage(resDataModel.message);
        if (shouldHandleUnauthorized) {
          // 同上: 交给 AuthRefreshInterceptor 先续期重试。
          response.requestOptions.extra['unauthorized'] = true;
        } else if (membershipInactive) {
          _handleMembershipInactive();
        }
        final silent = response.requestOptions.extra['silent'] == true;
        if (!silent && !shouldHandleUnauthorized && !membershipInactive) {
          if (isQuotaErrorMessage(resDataModel.message ?? '')) {
            unawaited(_showQuotaDialog(message));
          } else {
            BotToast.showText(text: message, align: Alignment.center);
          }
        }
        // 业务错误（success:false）已在此格式化并提示，标记后让 onError 原样透传，
        // 避免 onError 因 DioException type=unknown 把真实 message 覆盖成"网络异常"。
        response.requestOptions.extra['errorHandled'] = true;
        throw DioException(
            requestOptions: response.requestOptions,
            response: response,
            error: message);
      }
      // 失败响应保留 envelope，供业务层读取机器错误码；仅成功时解包。
      response.data = resDataModel.data;
      handler.next(response);
    }
  }

  @visibleForTesting
  static bool isSuccessfulNoContent(int? statusCode, Object? data) {
    return statusCode == 204 && (data == null || data == '');
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401 &&
        !_isPublicAuthRequest(err.requestOptions)) {
      // 401 透传给后置的 AuthRefreshInterceptor 做续期重试; 不在这里登出。
      handler.next(err);
      return;
    }
    // 业务错误已在 onResponse 处理并提示，原样透传，保留真实 message，不再当成网络异常。
    if (err.requestOptions.extra['errorHandled'] == true) {
      handler.next(err);
      return;
    }
    final friendly = _friendlyErrorMessage(err);
    _logApiFailure(err);
    final silent = err.requestOptions.extra['silent'] == true;
    // silent 只管"别弹 toast 打扰用户"，不该连带跳过错误上报——静默请求（后台
    // 轮询等）出问题更不容易被人肉发现，反而更需要报到错误看板里。
    if (isTransientNetworkError(err) ||
        err.type == DioExceptionType.badCertificate) {
      UserRefresh.showNetworkError(friendly);
    } else if (!silent && err.type != DioExceptionType.cancel) {
      BotToast.showText(text: friendly, align: Alignment.center);
    }
    AnalyticsService.instance.recordApiErrorUnawaited(err);
    handler.next(DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: friendly,
      message: friendly,
    ));
  }

  static String _friendlyErrorMessage(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '网络连接超时，请检查网络后重试';
      case DioExceptionType.connectionError:
        return '无法连接到服务器，请检查网络设置';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode ?? 0;
        if (status == 403) return '没有访问权限';
        if (status == 404) return '请求的资源不存在';
        if (status >= 500) {
          final data = err.response?.data;
          final message = data is Map ? '${data['message'] ?? ''}' : '';
          final modelFailure = formatKnownModelFailure(message);
          if (modelFailure != null) return modelFailure;
          // Only known safe business codes; never expose arbitrary upstream text.
          for (final code in [
            'chat.model_unavailable',
            'chat.model_configuration_unavailable',
            'chat.local_offline',
            'chat.local_unavailable',
            'chat.local_upgrade_required'
          ]) {
            if (message == code || message.startsWith('$code:')) {
              return formatBackendErrorMessage(code);
            }
          }
          return '服务器繁忙，请稍后重试';
        }
        return '请求失败(HTTP $status)';
      default:
        return '网络异常，请稍后重试';
    }
  }

  /// 仅输出 HTTP 排障所需的固定字段；请求体、响应体、URL query、header 与
  /// 未验证的上游错误文本都不得进入客户端日志。
  static void _logApiFailure(
    DioException err, {
    String? traceId,
    String? businessCode,
  }) {
    if (err.requestOptions.extra['apiFailureLogged'] == true) return;
    err.requestOptions.extra['apiFailureLogged'] = true;
    debugPrint(diagnosticLine(
      err,
      traceId: traceId,
      businessCode: businessCode),
    );
  }

  @visibleForTesting
  static String diagnosticLine(
    DioException err, {
    String? traceId,
    String? businessCode,
  }) {
    final request = err.requestOptions;
    final operation =
        _safeValue(request.extra['diagnosticOperation'] as String?) ??
            'http.request';
    final path = request.uri.path.isEmpty ? '/' : request.uri.path;
    final status = err.response?.statusCode?.toString() ?? '-';
    final code = _stableCode(businessCode) ??
        _stableCode(_responseMessage(err.response?.data)) ??
        '-';
    final safeTrace = _safeValue(traceId) ??
        _safeValue(_responseTraceId(err.response?.data)) ??
        _safeValue(err.response?.headers.value('x-trace-id')) ??
        '-';
    return '[ApiError] operation=$operation method=${request.method} '
        'path=$path status=$status type=${err.type.name} '
        'code=$code trace_id=$safeTrace';
  }

  static String? _responseMessage(Object? data) {
    if (data is! Map) return null;
    final value = data['message'];
    return value is String ? value : null;
  }

  static String? _responseTraceId(Object? data) {
    if (data is! Map) return null;
    final value = data['traceId'];
    return value is String ? value : null;
  }

  static String? _stableCode(String? value) {
    if (value == null) return null;
    final candidate = value.trim().split(':').first.trim();
    return RegExp(r'^[a-z][a-z0-9_.-]{1,127}$').hasMatch(candidate)
        ? candidate
        : null;
  }

  static String? _safeValue(String? value) {
    if (value == null) return null;
    final candidate = value.trim();
    return RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(candidate)
        ? candidate
        : null;
  }

  static Future<void> _showQuotaDialog(String message) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || _showingQuotaDialog) {
      BotToast.showText(text: message, align: Alignment.center);
      return;
    }
    _showingQuotaDialog = true;
    final canManageBilling = await _canManageBilling();
    if (!context.mounted) {
      _showingQuotaDialog = false;
      BotToast.showText(text: message, align: Alignment.center);
      return;
    }
    unawaited(showUiConfirmDialog(
      context,
      title: '已达套餐上限',
      description: canManageBilling ? message : '$message\n\n请联系组织管理员调整套餐或配额。',
      confirmLabel: canManageBilling ? '查看套餐' : '知道了',
      cancelLabel: '关闭',
    ).then((confirmed) {
      if (confirmed && canManageBilling && context.mounted) {
        context.go(RoutePaths.billing);
      }
    }).whenComplete(() {
      _showingQuotaDialog = false;
    }));
  }

  static Future<bool> _canManageBilling() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConfig.storageAccountInfoKey);
      if (raw == null || raw.trim().isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final roles = <String>{};
      void collectRoles(Object? value) {
        if (value is List) {
          for (final item in value) {
            roles.add(item.toString());
          }
        }
      }

      collectRoles(decoded['roles']);
      final scopes = decoded['scopes'];
      if (scopes is List) {
        for (final scope in scopes) {
          if (scope is Map) collectRoles(scope['roles']);
        }
      }
      return roles.any((role) =>
          role == 'tenant.admin' ||
          role == 'tenant.operator' ||
          role == 'tenant.builder' ||
          role == 'tenant.owner');
    } catch (_) {
      return false;
    }
  }

  bool _isUnauthorizedEnvelope(Response response, ResDataModel model) {
    if (response.statusCode == 401 || model.code == 4010) return true;
    return (model.message ?? '').trim().toLowerCase() == 'unauthorized';
  }

  bool _isMembershipInactiveMessage(String? message) {
    final lower = (message ?? '').trim().toLowerCase();
    return lower.contains('membership.inactive') ||
        lower.contains('membership.suspended');
  }

  static bool _isPublicAuthRequest(RequestOptions options) {
    return isPublicAuthRequestPath(options.path);
  }

  /// 判定性登录失效(续期也救不回来)时的强制登出。由 AuthRefreshInterceptor 调用。
  static void forceLogout() => _handleUnauthorizedStatic();

  static void _handleUnauthorizedStatic() {
    if (_handlingUnauthorized) return;
    _handlingUnauthorized = true;
    unawaited(() async {
      try {
        await const SessionService().clearSessionStorage();
        await WindowController.instance.showLoginWindow();
        final context = rootNavigatorKey.currentContext;
        if (context != null && context.mounted) {
          context.go(RoutePaths.login);
        }
        BotToast.showText(text: '登录已过期，请重新登录', align: Alignment.center);
      } finally {
        _handlingUnauthorized = false;
      }
    }());
  }

  void _handleMembershipInactive() {
    if (_handlingMembershipInactive) return;
    _handlingMembershipInactive = true;
    unawaited(() async {
      try {
        await const SessionService().clearSessionStorage();
        await WindowController.instance.showLoginWindow();
        final context = rootNavigatorKey.currentContext;
        if (context != null && context.mounted) {
          context.go(RoutePaths.login);
        }
        BotToast.showText(
          text: '您在当前企业的账号已被管理员暂停，请联系管理员或切换到其他企业',
          align: Alignment.center,
        );
      } finally {
        _handlingMembershipInactive = false;
      }
    }());
  }
}
