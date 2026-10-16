// zhiban-app cutover (2026-05): login_account_provider 完全对齐 agent-bus 登录流。
//
// 与老 ai-office 版本的差异 (docs/contracts/agent-bus-client-contract.md §10):
//   - **不再**做登录前的"查账号 / 选公司"; 租户切换由 me + scope/switch 在登录后完成。
//   - 客户端只有一个统一入口 loginWithSmsApi: 后端 LoginSms 已合并"已注册登录"和
//     "未注册首次自助注册", 不再需要前端感知 register 流程或重发短信。
//   - 成功后 fetchMeApi 拉 scopes; 多 tenant 时由 UI 跳到 tenant_picker 页。
import 'dart:async';

import 'package:zhiban_client/pages/login/models/login_account_state.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final loginSmsCountdownProvider =
    NotifierProvider<LoginSmsCountdownNotifier, int>(
  LoginSmsCountdownNotifier.new,
);

class LoginSmsCountdownNotifier extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    ref.onDispose(() {
      _timer?.cancel();
    });
    return 0;
  }

  void start([int seconds = 60]) {
    _timer?.cancel();
    state = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (state <= 1) {
        timer.cancel();
        state = 0;
        return;
      }
      state -= 1;
    });
  }

  void reset() {
    _timer?.cancel();
    state = 0;
  }
}

/// 登录成功后供 UI 决定是否跳"选择租户"页。
class LoginOutcome {
  final bool success;
  final List<ScopeOption>
      tenantScopes; // success=true 时填; 长度 1 直接进主页, ≥2 跳 picker。
  const LoginOutcome({required this.success, this.tenantScopes = const []});
}

final loginAccountProvider =
    NotifierProvider<LoginAccountNotifier, LoginAccountState>(
  LoginAccountNotifier.new,
);

class LoginAccountNotifier extends Notifier<LoginAccountState> {
  static final RegExp _mobileRegex = RegExp(r'^1[3-9]\d{9}$');

  @override
  LoginAccountState build() => const LoginAccountState();

  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  void setAgreementChecked(bool checked) {
    state = state.copyWith(agreementChecked: checked, clearError: true);
  }

  /// 手机号变化: 清重置图形码场景外的派生态。
  void onMobileChanged() {
    ref.read(loginSmsCountdownProvider.notifier).reset();
    state = state.copyWith(
      clearError: true,
      isSendingSms: false,
      isLoggingIn: false,
      isRegistering: false,
    );
  }

  bool validateAgreement() {
    if (state.agreementChecked) return true;
    state = state.copyWith(error: '请先阅读并同意隐私政策');
    return false;
  }

  /// 打开图形验证码前的手机号轻量校验。
  bool validateSmsRequest({required String mobile}) {
    final trimmedMobile = mobile.trim();
    if (!_mobileRegex.hasMatch(trimmedMobile)) {
      state = state.copyWith(error: '请输入正确的手机号');
      return false;
    }
    return true;
  }

  Future<void> fetchCaptcha() async {
    state = state.copyWith(isCaptchaLoading: true, clearError: true);
    try {
      final captchaData = await getCaptchaApi();
      if (!ref.mounted) return;
      state = state.copyWith(captchaData: captchaData, isCaptchaLoading: false);
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        isCaptchaLoading: false,
        error: isTransientNetworkError(error) ? null : formatError(error),
      );
    }
  }

  /// 发送短信; 客户端统一走 scene=login: 后端 LoginSms 在账号不存在时会自助注册,
  /// 不再需要客户端感知 register scene (legacy 流程已删除)。
  Future<bool> sendSmsCode({
    required String mobile,
    required String captchaCode,
  }) async {
    final trimmedMobile = mobile.trim();
    final trimmedCaptcha = captchaCode.trim();
    final captchaData = state.captchaData;

    if (!validateSmsRequest(mobile: trimmedMobile)) return false;
    if (trimmedCaptcha.isEmpty) {
      state = state.copyWith(error: '请输入图形验证码');
      return false;
    }
    if (captchaData == null || captchaData.captchaId.isEmpty) {
      state = state.copyWith(error: '请先获取图形验证码');
      return false;
    }

    state = state.copyWith(isSendingSms: true, clearError: true);
    try {
      await sendSmsCodeApi(
        mobile: trimmedMobile,
        scene: 'login',
        captchaId: captchaData.captchaId,
        captchaCode: trimmedCaptcha,
      );
      if (!ref.mounted) return false;
      ref.read(loginSmsCountdownProvider.notifier).start();
      state = state.copyWith(isSendingSms: false);
      return true;
    } catch (error) {
      if (!ref.mounted) return false;
      state = state.copyWith(isSendingSms: false, error: formatError(error));
      await fetchCaptcha();
      return false;
    }
  }

  /// "注册 / 登录" 按钮统一入口。
  ///
  /// 后端 LoginSms 已合并 "登录" 与 "首次自助注册"：
  ///   - 已注册手机号 → 校验 SMS 码后发 session token；
  ///   - 未注册手机号 → 校验 SMS 码后同 tx 建租户 + 账号 + 管理员角色, 再发 token。
  ///
  /// 因此客户端无需感知 register/login 双流程：只调一次 loginWithSmsApi 即可。
  Future<LoginOutcome> submit({
    required String mobile,
    required String smsCode,
  }) async {
    final trimmedMobile = mobile.trim();
    final trimmedSmsCode = smsCode.trim();

    if (!_mobileRegex.hasMatch(trimmedMobile)) {
      state = state.copyWith(error: '请输入正确的手机号');
      return const LoginOutcome(success: false);
    }
    if (trimmedSmsCode.isEmpty) {
      state = state.copyWith(error: '请输入短信验证码');
      return const LoginOutcome(success: false);
    }

    state = state.copyWith(isLoggingIn: true, clearError: true);
    try {
      await loginWithSmsApi(mobile: trimmedMobile, code: trimmedSmsCode);
    } catch (error) {
      if (!ref.mounted) return const LoginOutcome(success: false);
      state = state.copyWith(isLoggingIn: false, error: formatError(error));
      return const LoginOutcome(success: false);
    }
    if (!ref.mounted) return const LoginOutcome(success: false);
    return _postSuccess();
  }

  /// 登录(含首次自助注册)成功后统一拉 me + 重置 loading + 返回 outcome。
  Future<LoginOutcome> _postSuccess() async {
    try {
      final me = await fetchMeApi();
      if (!ref.mounted) return const LoginOutcome(success: false);
      state = state.copyWith(
        isLoggingIn: false,
        isRegistering: false,
        clearError: true,
      );
      return LoginOutcome(success: true, tenantScopes: me.tenantScopes);
    } catch (error) {
      if (!ref.mounted) return const LoginOutcome(success: false);
      state = state.copyWith(
        isLoggingIn: false,
        isRegistering: false,
        error: formatError(error),
      );
      // me 拉失败仍视为成功登录 (token 已写盘); UI 兜底直接进主页。
      return const LoginOutcome(success: true);
    }
  }

  Future<LoginOutcome> submitPassword({
    required String identifier,
    required String password,
  }) async {
    if (state.isLoggingIn) return const LoginOutcome(success: false);
    if (identifier.trim().isEmpty || password.isEmpty) {
      state = state.copyWith(error: '请输入账号和密码');
      return const LoginOutcome(success: false);
    }
    state = state.copyWith(isLoggingIn: true, clearError: true);
    try {
      await loginWithPasswordApi(identifier: identifier, password: password);
    } catch (error) {
      if (!ref.mounted) return const LoginOutcome(success: false);
      state = state.copyWith(isLoggingIn: false, error: formatError(error));
      return const LoginOutcome(success: false);
    }
    if (!ref.mounted) return const LoginOutcome(success: false);
    return _postSuccess();
  }
}
