import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的」页账号信息服务。
///
/// agent-bus cutover:
/// - 资料读取走 `/auth/me` (替代老 ai-office `/account/info`)
/// - 修改昵称走 `PATCH /account/profile` body `{display_name}` (更新当前租户成员显示名)
/// - 更换头像走两段式: `/account/avatar/presign` → PUT OSS → `/account/avatar/confirm`
///
/// 完整契约见 docs/contracts/agent-bus-client-contract.md §11。
class AccountInfoService {
  Future<AccountInfo?> getCachedAccountInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(AppConfig.storageAccountInfoKey);
    if (cached == null || cached.isEmpty) return null;

    try {
      final json = jsonDecode(cached) as Map<String, dynamic>;
      return AccountInfo.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<AccountInfo> fetchAccountInfo() async {
    final me = await fetchMeApi();
    return _storeMeResult(me);
  }

  Future<AccountInfo> _storeMeResult(MeResult me) async {
    final activeTenantId = await SessionService().getTenantId();
    final info = AccountInfo.fromJson(<String, dynamic>{
      'account': me.account,
      'scopes': [
        for (final scope in me.scopes)
          <String, dynamic>{
            'kind': scope.kind,
            'tenantId': scope.tenantId,
            'tenantSlug': scope.tenantSlug,
            'tenantName': scope.tenantName,
            'memberDisplayName': scope.memberDisplayName,
            'workspaceId': scope.workspaceId,
            'workspaceName': scope.workspaceName,
            'roles': scope.roles,
            'isAdmin': scope.isAdmin,
          },
      ],
    },
        activeTenantId:
            activeTenantId?.isNotEmpty == true ? activeTenantId : null);
    await _writeCache(info);
    return info;
  }

  Future<AccountInfo> getAccountInfo({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await getCachedAccountInfo();
      if (cached != null) return cached;
    }
    return fetchAccountInfo();
  }

  /// 更换头像 (两段式上传)。
  ///
  /// 1. 客户端 → `POST /account/avatar/presign`，拿 OSS 预签名 PUT URL。
  /// 2. 客户端 → PUT 文件二进制到 `upload_url` (携带 `Content-Type`, **不带** 业务鉴权头)。
  /// 3. 客户端 → `POST /account/avatar/confirm`，后端校验 OSS ownership 后写库。
  /// 4. 重新拉一次 `/auth/me`，让缓存与展示同步刷新。
  Future<AccountInfo> uploadAvatar({
    required String filePath,
    required String fileName,
  }) async {
    final file = File(filePath);
    final size = await file.length();
    final contentType = _guessContentType(fileName);

    final presign = await request.post(
      '/account/avatar/presign',
      data: <String, dynamic>{
        'content_type': contentType,
        'size': size
      },
    );
    final presignData = presign.data as Map<String, dynamic>;
    final uploadUrl = (presignData['upload_url'] ?? '').toString();
    final storageKey = (presignData['storage_key'] ?? '').toString();
    if (uploadUrl.isEmpty || storageKey.isEmpty) {
      throw const FormatException(
          'avatar presign 响应缺少 upload_url 或 storage_key');
    }

    // OSS PUT 必须脱离 dio 全局拦截器 (鉴权头/响应解包都会破坏 OSS 签名校验)。
    final ossDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 120),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final fileBytes = await file.readAsBytes();
    final putResp = await ossDio.put(
      uploadUrl,
      data: Stream.fromIterable([fileBytes]),
      options: Options(
        headers: <String, dynamic>{
          HttpHeaders.contentTypeHeader: contentType,
          HttpHeaders.contentLengthHeader: size,
        },
      ),
    );
    if (putResp.statusCode == null || putResp.statusCode! >= 300) {
      throw HttpException('OSS PUT 失败: HTTP ${putResp.statusCode}');
    }

    await request.post(
      '/account/avatar/confirm',
      data: <String, dynamic>{'storage_key': storageKey},
    );

    return fetchAccountInfo();
  }

  /// 修改当前租户成员显示名。后端只接 `display_name` 一个字段——agent-bus 账号模型
  /// 里没有独立的姓名/昵称,`AccountInfo.name`/`.nickname` 都是同一份数据的镜像。
  Future<AccountInfo> updateProfile({required String displayName}) async {
    await request.patch(
      '/account/profile',
      data: <String, dynamic>{'display_name': displayName.trim()},
    );
    return fetchAccountInfo();
  }

  Future<void> _writeCache(AccountInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConfig.storageAccountInfoKey,
      jsonEncode(info.toJson()),
    );
  }

  String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }
}

/// 当前会话的 `/auth/me` 权威数据。
///
/// 侧栏账号信息、个人弹框和「我的企业」共同复用；ProviderScope 在退出登录或
/// 切租户时整体重建，因此缓存不会跨身份或租户沿用。
final authMeProvider = FutureProvider<MeResult>((ref) => fetchMeApi());

/// 当前登录用户的账号信息。
///
/// 行为：从 [authMeProvider] 派生，避免同一会话内多个组件重复请求 `/auth/me`；
/// 网络失败回退到 SharedPreferences 缓存，保证离线/弱网仍能渲染。
/// 想立即刷新（例如改完头像后）调用 `ref.invalidate(authMeProvider)` 即可，
/// 依赖它的账号视图会自动重算。
final accountInfoProvider = FutureProvider<AccountInfo?>((ref) async {
  final svc = AccountInfoService();
  try {
    final me = await ref.watch(authMeProvider.future);
    return await svc._storeMeResult(me);
  } catch (_) {
    return svc.getCachedAccountInfo();
  }
});
