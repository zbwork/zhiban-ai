// zhiban-app cutover (2026-05):
//   - 去掉 legacy ai-office 流里的 step / accountData / selectedTenantId 字段。
//     租户选择改到登录后 tenant_picker 页, 这里只保留登录表单所需状态。
//   - 去掉 needsRegister: 后端 LoginSms 在账号不存在时直接自助注册 + 发 token,
//     客户端无需感知 register 流程。
import 'login_captcha_data.dart';

class LoginAccountState {
  final LoginCaptchaData? captchaData;
  final String? error;
  final bool isCaptchaLoading;
  final bool isSendingSms;
  final bool isLoggingIn;
  final bool isRegistering;
  final bool agreementChecked;

  const LoginAccountState({
    this.captchaData,
    this.error,
    this.isCaptchaLoading = false,
    this.isSendingSms = false,
    this.isLoggingIn = false,
    this.isRegistering = false,
    this.agreementChecked = false,
  });

  LoginAccountState copyWith({
    LoginCaptchaData? captchaData,
    bool clearCaptchaData = false,
    String? error,
    bool clearError = false,
    bool? isCaptchaLoading,
    bool? isSendingSms,
    bool? isLoggingIn,
    bool? isRegistering,
    bool? agreementChecked,
  }) {
    return LoginAccountState(
      captchaData: clearCaptchaData ? null : (captchaData ?? this.captchaData),
      error: clearError ? null : (error ?? this.error),
      isCaptchaLoading: isCaptchaLoading ?? this.isCaptchaLoading,
      isSendingSms: isSendingSms ?? this.isSendingSms,
      isLoggingIn: isLoggingIn ?? this.isLoggingIn,
      isRegistering: isRegistering ?? this.isRegistering,
      agreementChecked: agreementChecked ?? this.agreementChecked,
    );
  }
}
