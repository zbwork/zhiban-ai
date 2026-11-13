/// Anonymous official resource publication; never falls back to a Bus host.
class CommunityResources {
  static const skillsBaseUrl = String.fromEnvironment(
      'COMMUNITY_SKILLS_BASE_URL',
      defaultValue: 'https://zbwork.github.io/skills/');
  static const agentsBaseUrl = String.fromEnvironment(
      'COMMUNITY_AGENTS_BASE_URL',
      defaultValue: 'https://zbwork.github.io/agents/');

  static Uri origin(String base) =>
      Uri.parse(base.endsWith('/') ? base : '$base/');
  static String resolve(String base, String path) {
    final uri = origin(base).resolve(path);
    if (uri.userInfo.isNotEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw const FormatException('官方资源地址无效');
    }
    return uri.toString();
  }

  static bool isOfficialImage(String url) {
    final uri = Uri.tryParse(imageUrl(url));
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return false;
    return [skillsBaseUrl, agentsBaseUrl].any((url) {
      final base = origin(url);
      return uri.origin == base.origin &&
          uri.path.startsWith('${base.path}assets/');
    });
  }

  /// Old saved official employees/conversations retain content-addressed avatars.
  static String imageUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final match = RegExp(
            r'^/api/public/v1/(agents|skills)/[^/]+/(avatar|icon)/([a-f0-9]{64}\.(?:png|jpg|jpeg|webp|svg))$')
        .firstMatch(uri.path);
    if (match == null) return url;
    return resolve(match[1] == 'agents' ? agentsBaseUrl : skillsBaseUrl,
        'assets/${match[1]}/${match[3]}');
  }
}
