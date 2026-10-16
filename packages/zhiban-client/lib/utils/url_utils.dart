import 'dart:convert';

import 'package:zhiban_client/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 把 [params] 以 query 形式拼到 [url] 上；已有 query 用 `&`，否则 `?`。
/// 值会做 URL 编码，空值不会被跳过——调用方自己过滤 empty。
String appendQueryParams(String url, Map<String, String> params) {
  if (params.isEmpty) return url;
  final query = params.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
  final separator = url.contains('?') ? '&' : '?';
  return '$url$separator$query';
}

/// 把数字员工 / 会话头像的 raw URL 规整成可直接交给 `UiNetworkImage` 的串：
///  - 空 / `oss://` 协议（未签名）→ 返回空串，调用方走 fallback；
///  - 已带 scheme（http/https/…）→ 原样返回；
///  - 以 `/` 开头的相对路径 → 补 [AppConfig.apiUrl] 的 origin；
///  - 其它（非 URL 文本）→ 原样返回，让上层自行处理。
///
/// 历史背景：agent-bus `digital_employees.avatar_url` 存的是相对路径
/// (e.g. `/api/agent-bus/v1/assets/agent-avatars/xxx.jpg`)，数字员工卡片
/// 调了这个 helper 才能加载；聊天侧栏 / 顶栏忘了拼 origin，CachedNetworkImage
/// 直接 404 → fallback 到机器人。统一从这里出口避免再分叉。
String resolveAgentAvatarUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.startsWith('oss://')) return '';
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) return value;
  if (value.startsWith('/')) {
    final base = Uri.parse(AppConfig.apiUrl());
    return '${base.origin}$value';
  }
  return value;
}

/// 头像缓存身份（cacheKey）helper：把易变的预签名 URL 归一成稳定资源身份。
///
/// 背景：后端头像 `oss://` / storage key 引用每次接口返回前都会被现签成短期 GET URL，
/// 签名 / 过期 query 每次都可能不同。若用完整 URL 当 `CachedNetworkImage` 的 cacheKey，
/// 每次刷新缓存都 miss → 重新下载 → 头像「刷新闪动」。客户端应依赖**稳定资源路径**而非
/// 预签名 query：对同一头像资源 path 应稳定、换头像时 path/version 应变化（部分 agent/media
/// 头像使用内容寻址 sha256 路径；账号头像可能使用 timestamp/random 版本化路径），故剥掉
/// query/fragment 的路径是稳定且「换图即变」的缓存身份。
///
/// 规则:
///  - `http`/`https` URL → `scheme + host[:port] + path`（剥除 query/fragment，保留显式端口）；
///  - 以 `/` 开头的相对 URL（如 `/api/...`）→ `path`（剥除 query/fragment）；
///  - 空 / 非法 / 其它协议（如 `oss://`、`data:`）→ 返回 `null`，调用方沿用默认行为
///    （`UiNetworkImage` cacheKey=null 时回落到用完整 URL，当前行为不变，无回归）。
///
/// **仅用于头像**；消息图片 / 文件预览 / markdown 图等非头像媒体不要用本 helper。
/// 约定见 docs/contracts/agent-bus-client-contract.md「头像加载 / 缓存身份约定」+
/// docs/pitfalls/presigned-url-as-avatar-cache-key.md。
String? stableAvatarCacheKey(String? url) {
  final value = url?.trim() ?? '';
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    if (uri.host.isEmpty) return null;
    // 保留显式端口（避免 `:8443` 与默认端口 origin 撞 cacheKey）；userInfo 不进缓存身份。
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port${uri.path}';
  }
  // 相对路径（无 scheme，以 / 开头）：取 path，剥 query/fragment。
  if (scheme.isEmpty && value.startsWith('/')) {
    final path = uri.path;
    return path.isEmpty ? null : path;
  }
  return null;
}

/// 标准化用户输入的 URL：补 scheme（默认 https）、空字符串返回 null。
Uri? normalizeUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parsed = Uri.tryParse(text);
  if (parsed == null) return null;
  if (parsed.hasScheme) return parsed;
  if (text.startsWith('//')) return Uri.tryParse('https:$text');
  return Uri.tryParse('https://$text');
}

/// 从 SharedPreferences 的 dashboardToken 中读 `userToken` / `ssoToken`，
/// 以 query 参数形式拼到 [url] 上。
/// 没有登录态 / 解析失败时原样返回，保证调用方拿到的始终是可用 Uri。
Future<Uri> attachDashboardTokens(Uri url) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(AppConfig.storageDashboardTokenKey);
  if (raw == null || raw.isEmpty) return url;
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final userToken = (map['userToken'] ?? '').toString();
    final ssoToken = (map['ssoToken'] ?? '').toString();
    if (userToken.isEmpty && ssoToken.isEmpty) return url;
    final next = appendQueryParams(url.toString(), {
      if (userToken.isNotEmpty) 'userToken': userToken,
      if (ssoToken.isNotEmpty) 'ssoToken': ssoToken,
    });
    return Uri.tryParse(next) ?? url;
  } catch (_) {
    return url;
  }
}
