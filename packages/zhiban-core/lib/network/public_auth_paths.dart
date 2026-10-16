/// Public login endpoints bypass access-token refresh.
bool isPublicAuthRequestPath(String rawPath) {
  final uri = Uri.tryParse(rawPath);
  final path = uri?.path ?? rawPath;
  const publicSuffixes = <String>{
    '/auth/captcha',
    '/auth/sms/send',
    '/auth/login/password',
    '/auth/login/sms',
    '/auth/register/sms',
    '/auth/qr/create',
    '/auth/qr/status',
  };
  return publicSuffixes.any(path.endsWith);
}
