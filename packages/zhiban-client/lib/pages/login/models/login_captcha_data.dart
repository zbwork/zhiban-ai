class LoginCaptchaData {
  final String captchaId;
  final String captchaBase64;

  const LoginCaptchaData({
    required this.captchaId,
    required this.captchaBase64,
  });

  factory LoginCaptchaData.fromJson(Map<String, dynamic> json) {
    return LoginCaptchaData(
      captchaId: (json['captchaId'] ?? '').toString(),
      captchaBase64: (json['captchaBase64'] ?? '').toString(),
    );
  }
}
