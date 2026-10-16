import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'dart:async';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_client/services/tenant_identity_preview.dart';


import 'package:flutter/foundation.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/services/session_runtime.dart';
import 'package:zhiban_core/session/token_refresher.dart';
import 'package:zhiban_core/session/local_token_claims.dart';
import 'package:zhiban_client/im/im_credentials_storage.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_client/pages/contacts/contacts_directory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final ValueNotifier<int> sessionScopeKey = ValueNotifier<int>(0);

void resetSessionScope() {
  ChatCacheScope.resetSession();
  ChatReceiptsController.debugClearMemoryCache();
  ConversationModels.instance.clear();
  sessionScopeKey.value += 1;
}

@visibleForTesting
Future<void> Function()? debugRealtimeLogoutOverride;

@visibleForTesting
Future<void> Function()? debugClearImCacheOverride;

Future<void> Function()? _sessionLogoutCleanup;

/// 注册必须在登录凭据移除前执行的设备级清理。
///
/// 当前由 macOS F31 本地编程工具接入使用；回调失败不能阻塞退出登录，且回调
/// 自身必须只抛脱敏错误。
void configureSessionLogoutCleanup(Future<void> Function()? cleanup) {
  _sessionLogoutCleanup = cleanup;
}

class SessionService {
  const SessionService();

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey);
    if (token == null || token.isEmpty) {
      return null;
    }
    // 预热内存 token：让首屏图片同步取认证头，避免闪 placeholder。
    RequestInterceptor.primeToken(token);
    return token;
  }

  /// 当前登录账号的稳定标识 (JWT `aid` claim, 跨租户切换不变——`switchToTenantApi`
  /// 换的是 `act_tid`, `aid` 是同一个人)。给需要"按用户隔离本地存储, 但不因为
  /// 切租户就失效/串号"的本地缓存用 (例如"模型服务"里用户自己配的 BYOK API Key)。
  /// 未登录 / token 解析失败 → null, 调用方应当把 null 当独立的匿名分区处理,
  /// 不要跟任何真实账号的分区共用。
  Future<String?> getAccountId() async {
    final token = await getToken();
    if (token == null) return null;
    final aid = LocalTokenClaims.read(token, 'aid');
    if (aid == null) return null;
    return aid.toString();
  }

  /// 当前 access token 的 active tenant 标识。只用于把非敏感本地重试元数据
  /// 绑定到正确登录身份，不能作为服务端授权依据。
  Future<String?> getTenantId() async {
    final token = await getToken();
    if (token == null) return null;
    final tenantId = LocalTokenClaims.read(token, 'act_tid');
    if (tenantId == null) return null;
    return tenantId.toString();
  }

  /// Non-secret identity for tenant-member initialization preferences.
  Future<String?> getAccountTenantScope() async {
    final token = await getToken();
    if (token == null) return null;
    final aid = LocalTokenClaims.read(token, 'aid');
    final tid = LocalTokenClaims.read(token, 'act_tid');
    if (aid == null || tid == null) return null;
    return '$aid:$tid';
  }

  Future<bool> hasValidSession() async {
    final token = await getToken();
    if (token == null) return false;
    if (LocalTokenClaims.isExpired(token)) {
      // 先静默续期; 只有判定性失败(refresh token 无效/撤销)才清凭证,
      // 网络问题保留凭证走登录页, 下次启动还能再试。
      switch (await tokenRefresher.refresh()) {
        case RefreshOutcome.ok:
          return true;
        case RefreshOutcome.invalid:
          await clearSessionStorage();
          return false;
        case RefreshOutcome.networkError:
          return false;
      }
    }
    // access 与 refresh 同为长 TTL: 只在过期瞬间才续期会撞上 refresh token 同时到期。
    // 签发已超 24h 就后台滑动一次(每天最多一次, 失败无感), 把两者一起顺延。
    if (LocalTokenClaims.isIssuedBefore(token, const Duration(hours: 24))) {
      unawaited(tokenRefresher.refresh());
    }
    return true;
  }

  Future<void> clearSessionStorage() async {
    clearTenantIdentityPreview();
    await LocalAgentService.instance.beforeIdentityChange(null);
    try {
      await _sessionLogoutCleanup?.call();
    } catch (e) {
      debugPrint('[session] device authorization cleanup failed (ignored): $e');
    }
    try {
      await sessionPushLifecycle.revoke();
    } catch (e) {
      debugPrint('[push] revoke failed during logout (ignored): $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.storageTokenKey);
    await prefs.remove(AppConfig.storageRefreshTokenKey);
    await prefs.remove(AppConfig.storageDashboardTokenKey);
    await prefs.remove(AppConfig.storageAccountInfoKey);
    await prefs.remove(AppConfig.storageWorkbenchAppsKey);
    // 通讯录快照按账号缓存意义不大(下个账号大概率是不同租户), 登出即清,
    // 避免切账号后瞬间闪出上一个租户的部门树/成员。
    await ContactsDirectoryStore.instance.clear();
    RequestInterceptor.clearTokenCache();
    // WuKong 长连接是进程级单例，必须在清 token 前主动断开，否则重新登录时
    // 单例仍持有旧 uid/token → SDK 用失效凭证不断重连。
    try {
      await WukongImClient.shared.logout();
    } catch (e) {
      debugPrint('[session] WuKong logout failed (ignored): $e');
    }
    // F09: 清掉 IM refresh token（不清 device_id，让设备保持稳定身份）。
    try {
      await IMCredentialsStorage().clearTokens();
    } catch (e) {
      debugPrint('[session] clear IM tokens failed (ignored): $e');
    }
    try {
      final logout =
          debugRealtimeLogoutOverride ?? WukongImClient.shared.logout;
      await logout();
    } catch (e) {
      debugPrint('[session] logout realtime IM failed (ignored): $e');
    }
    resetSessionScope();
  }

  /// 清除本地缓存，保留当前环境与 token 等登录凭证。
  Future<void> clearCacheStorage() async {
    final scope = await ChatCacheScope.current();
    try {
      // Capture the current identity partition before invalidating in-flight reads.
      ChatCacheScope.resetSession();
      await (debugClearImCacheOverride ??
          WukongImClient.shared.clearCurrentHistoryCache)();
      if (scope != null) {
        await (await ChatLocalStore.shared).clearScope(scope.key);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConfig.storageWorkbenchAppsKey);
    } finally {
      HumanDirectImController.clearMemoryCache();
      // Recreate consumers even after partial failure; never retain stale windows.
      resetSessionScope();
    }
  }
}
