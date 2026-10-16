// agent-bus auth client。
//
// 端点对齐 docs/contracts/agent-bus-client-contract.md §10:
//   - GET  /auth/captcha
//   - POST /auth/sms/send         body {mobile, scene:"login"|"register", captchaId, captchaCode}
//   - POST /auth/login/sms        body {mobile, code}      → LoginResp
//   - POST /auth/register/sms     body {mobile, code}      → LoginResp  (自助注册, 同时新建默认租户)
//   - GET  /auth/me                                           → { account, scopes[] }
//   - POST /auth/scope/switch     body {kind:"tenant", tenantId}    → LoginResp (返新 accessToken)
//
// **本文件严禁出现任何 ai-office (/auth/account, /auth/oauth/qrcode 等) 端点的调用。**
import 'dart:async';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/im/im_credentials_storage.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_session_identity.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/models/login_captcha_data.dart';
import 'package:zhiban_client/services/billing_refresh_notifier.dart';
import 'package:zhiban_client/services/device_info_service.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/services/tenant_identity_preview.dart';

import 'package:zhiban_client/services/session_runtime.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// agent-bus 登录响应的精简 model。
class AuthLoginResult {
  final String accessToken;
  final String refreshToken;
  final Map<String, dynamic> account;
  final ScopeOption actScope;

  const AuthLoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.account,
    required this.actScope,
  });

  factory AuthLoginResult.fromJson(Map<String, dynamic> json) {
    return AuthLoginResult(
      accessToken: (json['accessToken'] ?? '').toString(),
      refreshToken: (json['refreshToken'] ?? '').toString(),
      account: (json['account'] as Map?)?.cast<String, dynamic>() ?? const {},
      actScope: ScopeOption.fromJson(
          (json['actScope'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }
}

/// /auth/me 与 LoginResp 中的 scope 选项。
class ScopeOption {
  final String kind; // platform / tenant / workspace
  final int tenantId;
  final String tenantSlug;
  final String tenantName;
  final String memberDisplayName;
  final int workspaceId;
  final String workspaceName;
  final List<String> roles;

  /// 该 scope 下的权限点全集 (F28: 客户端用 `tenant.member.invite` 控制
  /// 「添加企业成员」入口可见性; 服务端仍强制校验, 这里只是 UX)。
  final List<String> perms;

  /// 这个 scope(租户/平台)下账号是否可进管理后台 (后端 gateAdmin 同口径:
  /// platform.admin / tenant.admin / tenant.operator 任一)。
  /// 2026-08-24 起按每个 scope 单独算, 不再是"账号级、所有 scope 上值相同"——
  /// 账号在 A 租户是管理员、在 B 租户只是普通成员时, 这里 A/B 两个 ScopeOption
  /// 的 isAdmin 会不一样。UI 判断"要不要显示管理后台入口"必须用**当前所在租户**
  /// 对应的这个值, 不能用 scopes.any(...)。
  final bool isAdmin;

  const ScopeOption({
    required this.kind,
    this.tenantId = 0,
    this.tenantSlug = '',
    this.tenantName = '',
    this.memberDisplayName = '',
    this.workspaceId = 0,
    this.workspaceName = '',
    this.roles = const [],
    this.perms = const [],
    this.isAdmin = false,
  });

  factory ScopeOption.fromJson(Map<String, dynamic> json) {
    return ScopeOption(
      kind: (json['kind'] ?? '').toString(),
      tenantId: (json['tenantId'] as num?)?.toInt() ?? 0,
      tenantSlug: (json['tenantSlug'] ?? '').toString(),
      tenantName: (json['tenantName'] ?? '').toString(),
      memberDisplayName: (json['memberDisplayName'] ??
              json['member_display_name'] ??
              json['displayName'] ??
              json['display_name'] ??
              '')
          .toString(),
      workspaceId: (json['workspaceId'] as num?)?.toInt() ?? 0,
      workspaceName: (json['workspaceName'] ?? '').toString(),
      roles: ((json['roles'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      perms: ((json['perms'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      isAdmin: json['isAdmin'] == true,
    );
  }
}

class MeResult {
  final Map<String, dynamic> account;
  final List<ScopeOption> scopes;
  const MeResult({required this.account, required this.scopes});

  /// caller 真正能进的租户列表 (排除 platform/workspace, 后续按需扩展)。
  List<ScopeOption> get tenantScopes =>
      scopes.where((s) => s.kind == 'tenant' && s.tenantId > 0).toList();

  factory MeResult.fromJson(Map<String, dynamic> json) {
    return MeResult(
      account: (json['account'] as Map?)?.cast<String, dynamic>() ?? const {},
      scopes: ((json['scopes'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => ScopeOption.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

@visibleForTesting
Future<void> Function()? debugAuthRealtimeLogoutOverride;

@visibleForTesting
Future<void> Function()? debugAuthClearImTokensOverride;

@visibleForTesting
String? Function()? debugAuthConnectedUidOverride;

final _tenantSwitchInProgress = ValueNotifier<bool>(false);

/// Switch progress survives session ProviderScope replacement. UI observes the
/// same lock as the API, without writing to a disposed session container.
ValueListenable<bool> get tenantSwitchInProgress => _tenantSwitchInProgress;

/// 写入 access token / refresh token / account 摘要; 同时刷新 dio 拦截器 token 缓存。
///
/// 任一登录成功路径 (login/register/scope-switch) 都必须走这里, 保证 SharedPreferences
/// 与 RequestInterceptor 静态缓存一致。dashboard_token 写空对象, 兼容老页面读取。
Future<void> _persistLoginResult(AuthLoginResult res) async {
  if (res.accessToken.isEmpty) {
    throw Exception('登录失败，未获取到 accessToken');
  }
  if (!_tenantSwitchInProgress.value) clearTenantIdentityPreview();
  await LocalAgentService.instance.beforeIdentityChange(res.accessToken);
  final sp = await SharedPreferences.getInstance();
  await _resetRealtimeBeforeIdentityChange(sp, res.accessToken);
  await sp.setString(AppConfig.storageTokenKey, res.accessToken);
  if (res.refreshToken.isNotEmpty) {
    await sp.setString(AppConfig.storageRefreshTokenKey, res.refreshToken);
  } else {
    await sp.remove(AppConfig.storageRefreshTokenKey);
  }
  // 老页面 (recharge / wallet 等) 可能读 dashboard_token, 这里写空对象避免它们崩。
  await sp.setString(AppConfig.storageDashboardTokenKey,
      jsonEncode({'userToken': '', 'ssoToken': ''}));
  if (res.account.isNotEmpty) {
    await sp.setString(
        AppConfig.storageAccountInfoKey, jsonEncode(res.account));
  }
  RequestInterceptor.clearTokenCache();
  unawaited(sessionPushLifecycle.start());
}

Future<void> _resetRealtimeBeforeIdentityChange(
  SharedPreferences sp,
  String nextAccessToken,
) async {
  final nextUid = WukongSessionIdentity.fromJwt(nextAccessToken)?.uid;
  if (nextUid == null || nextUid.isEmpty) return;

  final previousToken = sp.getString(AppConfig.storageTokenKey) ?? '';
  final previousUid = WukongSessionIdentity.fromJwt(previousToken)?.uid;
  final connectedUid = (debugAuthConnectedUidOverride ??
          () => WukongImClient.shared.connectedUid)
      .call();
  final previousDiffers =
      previousUid != null && previousUid.isNotEmpty && previousUid != nextUid;
  final connectedDiffers = connectedUid != null &&
      connectedUid.isNotEmpty &&
      connectedUid != nextUid;
  if (!previousDiffers && !connectedDiffers) return;

  // 没走 SessionService.clearSessionStorage()（比如登录页直接登录了另一个账号，
  // 没先点退出）就切身份的路径，之前漏了撤销旧账号的推送设备注册——虽然新账号
  // 登录后 start() 的 upsert 理论上会把同一台设备的 installation_id 记录改绑到
  // 新账号，但那步是 unawaited 的，且失败时不会重试；这里跟显式退出登录一样先
  // 撤销一次，避免旧账号残留一条 active 的推送绑定收错/收不到通知。
  try {
    await sessionPushLifecycle.revoke();
  } catch (e) {
    debugPrint('[auth] revoke push device before identity switch failed: $e');
  }
  try {
    final logout =
        debugAuthRealtimeLogoutOverride ?? WukongImClient.shared.logout;
    await logout();
  } catch (e) {
    debugPrint('[auth] logout realtime IM before identity switch failed: $e');
  }
  try {
    final clearTokens =
        debugAuthClearImTokensOverride ?? IMCredentialsStorage().clearTokens;
    await clearTokens();
  } catch (e) {
    debugPrint('[auth] clear IM tokens before identity switch failed: $e');
  }
  resetSessionScope();
}

@visibleForTesting
Future<void> persistLoginResultForTest(AuthLoginResult res) =>
    _persistLoginResult(res);

Future<LoginCaptchaData> getCaptchaApi() async {
  final response = await request.get('/auth/captcha');
  final data = (response.data as Map).cast<String, dynamic>();
  // agent-bus captcha.Result: { captchaId, captchaImage } (image 是 data:image/png;base64,...)。
  return LoginCaptchaData(
    captchaId: (data['captchaId'] ?? '').toString(),
    captchaBase64:
        (data['captchaImage'] ?? data['captchaBase64'] ?? '').toString(),
  );
}

Future<void> sendSmsCodeApi({
  required String mobile,
  required String scene, // login / register
  required String captchaId,
  required String captchaCode,
}) async {
  await request.post(
    '/auth/sms/send',
    data: <String, dynamic>{
      'mobile': mobile,
      'scene': scene,
      'captchaId': captchaId,
      'captchaCode': captchaCode,
    },
  );
}

/// 已有账号密码登录，复用统一会话持久化，不自动注册。
Future<AuthLoginResult> loginWithPasswordApi({
  required String identifier,
  required String password,
}) async {
  final device = await collectLoginDeviceInfo();
  final response = await request.post(
    '/auth/login/password',
    data: <String, dynamic>{
      'identifier': identifier.trim(),
      'password': password,
      'device': device.toJson(),
    },
  );
  final result =
      AuthLoginResult.fromJson((response.data as Map).cast<String, dynamic>());
  await _persistLoginResult(result);
  return result;
}

/// 短信码登录或首次自助注册，由后端 LoginSms 决策。
Future<AuthLoginResult> loginWithSmsApi({
  required String mobile,
  required String code,
}) async {
  final device = await collectLoginDeviceInfo();
  final response = await request.post(
    '/auth/login/sms',
    data: <String, dynamic>{
      'mobile': mobile,
      'code': code,
      'device': device.toJson(),
    },
  );
  final res =
      AuthLoginResult.fromJson((response.data as Map).cast<String, dynamic>());
  await _persistLoginResult(res);
  return res;
}

/// 自助注册 (新手机号自动建账号 + 默认租户)。注册成功后状态等同登录, 不需要再单独 login。
Future<AuthLoginResult> registerWithSmsApi({
  required String mobile,
  required String code,
}) async {
  final device = await collectLoginDeviceInfo();
  final response = await request.post(
    '/auth/register/sms',
    data: <String, dynamic>{
      'mobile': mobile,
      'code': code,
      'device': device.toJson(),
    },
  );
  final res =
      AuthLoginResult.fromJson((response.data as Map).cast<String, dynamic>());
  await _persistLoginResult(res);
  return res;
}

/// 登录后拉账号 + 可切换 scope 列表; 客户端据此决定是否要跳"选择租户"页。
Future<MeResult> fetchMeApi() async {
  final response = await request.get('/auth/me');
  return MeResult.fromJson((response.data as Map).cast<String, dynamic>());
}

/// ===== §10.4 QR 扫码登录 (桌面端) =====

/// /auth/qr/create 响应。`qrcodePayload` 是二维码内嵌的字符串
/// (格式 `agentbus-qr:<key>`); `qrcodeImage` 是 data:image/png;base64 dataURI,
/// 桌面端可直接塞给 Image.memory(base64Decode(...)) 或 <img src="...">。
class QRLoginCreated {
  final String key;
  final String qrcodeImage;
  final String qrcodePayload;
  final int expireSeconds;
  const QRLoginCreated({
    required this.key,
    required this.qrcodeImage,
    required this.qrcodePayload,
    required this.expireSeconds,
  });
  factory QRLoginCreated.fromJson(Map<String, dynamic> j) => QRLoginCreated(
        key: (j['qrcodeKey'] ?? '').toString(),
        qrcodeImage: (j['qrcodeImage'] ?? '').toString(),
        qrcodePayload: (j['qrcodePayload'] ?? '').toString(),
        expireSeconds: (j['expireSeconds'] as num?)?.toInt() ?? 300,
      );
}

/// /auth/qr/status 响应。
/// 终态: confirmed / cancelled / expired (客户端停止轮询)。confirmed 时 login 非空。
class QRLoginStatus {
  final String status;
  final String statusDesc;
  final AuthLoginResult? login;
  const QRLoginStatus(
      {required this.status, required this.statusDesc, this.login});

  bool get isTerminal =>
      status == 'confirmed' || status == 'cancelled' || status == 'expired';

  factory QRLoginStatus.fromJson(Map<String, dynamic> j) => QRLoginStatus(
        status: (j['status'] ?? '').toString(),
        statusDesc: (j['statusDesc'] ?? '').toString(),
        login: (j['login'] is Map)
            ? AuthLoginResult.fromJson(
                (j['login'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// 桌面端拉一张二维码 (无身份)。
Future<QRLoginCreated> createQrApi() async {
  final device = await collectLoginDeviceInfo();
  final resp = await request.post(
    '/auth/qr/create',
    data: <String, dynamic>{'device': device.toJson()},
  );
  return QRLoginCreated.fromJson((resp.data as Map).cast<String, dynamic>());
}

/// 桌面端轮询; status=confirmed 时把 login 持久化到本地, 与短信登录同形。
Future<QRLoginStatus> qrStatusApi(String key) async {
  final resp = await request.get(
    '/auth/qr/status',
    queryParameters: <String, dynamic>{'key': key},
    options: Options(extra: <String, dynamic>{'silent': true}),
  );
  final s = QRLoginStatus.fromJson((resp.data as Map).cast<String, dynamic>());
  if (s.status == 'confirmed' && s.login != null) {
    await _persistLoginResult(s.login!);
  }
  return s;
}

/// 移动端 (已登录) 扫描后调用, 仅状态翻转 (pending → scanned)。
Future<void> qrScanApi(String key) async {
  await request.post('/auth/qr/scan', data: <String, dynamic>{'key': key});
}

/// 移动端 "同意登录"; tenantId=0 时复用 caller 当前 actScope 给桌面端签 token。
///
/// 电脑设备信息已在创建二维码时保存；手机只确认账号和租户。
Future<void> qrConfirmApi(String key, {int tenantId = 0}) async {
  await request.post(
    '/auth/qr/confirm',
    data: <String, dynamic>{'key': key, 'tenantId': tenantId},
  );
}

/// 移动端 "取消授权"。
Future<void> qrCancelApi(String key) async {
  await request.post('/auth/qr/cancel', data: <String, dynamic>{'key': key});
}

/// 切换到指定租户; 返新 accessToken, 覆盖本地存储。
Future<AuthLoginResult> switchToTenantApi(int tenantId) async {
  if (_tenantSwitchInProgress.value) {
    throw StateError('主体切换正在进行，请稍候');
  }
  _tenantSwitchInProgress.value = true;
  late final AuthLoginResult res;
  try {
    final response = await request.post(
      '/auth/scope/switch',
      data: <String, dynamic>{'kind': 'tenant', 'tenantId': tenantId},
    );
    res = AuthLoginResult.fromJson(
        (response.data as Map).cast<String, dynamic>());
    await _persistLoginResult(res);
  } finally {
    _tenantSwitchInProgress.value = false;
  }
  // SidebarBillingSection 是普通 StatefulWidget(不走 ref.watch), 自己管理 _wallet 本地态,
  // 只在 initState / app resume / billingSummaryRefreshNotifier 三个时机刷新。切租户虽然会
  // 重建 ProviderScope(见 main.dart resetSessionScope), 但 MainLayout 这条 GoRouter 路由页
  // 树挂在 MaterialApp.router builder 的 child 参数下, 由 Router 自己的 Navigator 维护,
  // 不会因为外层 ProviderScope 换 key 就被摧毁重建——SidebarBillingSection 的 State 原样
  // 留着, 显示的还是切租户前的旧积分, 只有点进积分页(onTap 里显式调这个通知)才会刷新。
  // 这里显式广播一次, 让它跟其它切租户入口(登录选租户/mine_drawer 等)保持一致。
  notifyBillingSummaryChanged();
  return res;
}
