import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/network/request_interceptor.dart';

/// 剥掉 markdown 角括号外壳:CommonMark `[label](<url>)` 语法允许 URL 外套
/// 一对 `<...>`,URL 含特殊字符时需要,ASCII-safe URL 上是冗余可选。
///
/// 服务端 publisher (`ai-office/.../worker_publish.go` Step 7) 已经会收尾剥
/// 一次,这里是客户端的二道兜底——历史消息 / skill 自吐 URL / markdown 库
/// (flutter_smooth_markdown 0.7.2 的 `_parseUrlAndTitle` 没剥角括号) 漏过来
/// 的字面 `<...>` 都在这里救回来,否则下面 [apiImageNeedsAuth] 看到首字符
/// 是 `<` 不会命中 `/app/` 前缀,认证头不带 → 401 / 破图。
String _stripUrlAngleBrackets(String url) {
  if (url.length >= 2 && url.startsWith('<') && url.endsWith('>')) {
    return url.substring(1, url.length - 1);
  }
  return url;
}

/// 凡是受保护的业务图片路径(`/app/...`、历史 `/api/app/...`、聊天媒体
/// `/chat/media/...` 或 message-files `/message-files/...`)的图片 URL,
/// 命中后必须:
///   1. 用 [apiImageResolveUrl] 补全 baseURL;
///   2. 用 [apiImageLoadHeaders] 拿到 Bearer token,塞进 image loader 的
///      `httpHeaders`(浏览器原生 `<img>` / Flutter 内置 NetworkImage 默认
///      不会带 Authorization,会被后端 401 拦掉)。
/// 普通公网 URL(http(s)://...)不命中,直接原样使用。
bool apiImageNeedsAuth(String url) {
  final stripped = _stripUrlAngleBrackets(url);
  final parsed = Uri.tryParse(stripped);
  final path = parsed?.hasScheme == true ? parsed!.path : stripped;
  return path.startsWith('/app/') ||
      path.startsWith('/api/app/') ||
      path.startsWith('/chat/media/') ||
      path.startsWith('/api/chat/media/') ||
      path.startsWith('/api/agent-bus/v1/chat/media/') ||
      path.startsWith('/knowledge-bases/') ||
      path.startsWith('/api/agent-bus/v1/knowledge-bases/') ||
      path.startsWith('/message-files/') ||
      path.startsWith('/api/agent-bus/v1/message-files/');
}

/// 把相对路径补成绝对 URL。普通 URL 原样返回。
///
/// 兼容历史:早期版本后端写过 `/api/app/openclaw-drive/...`(带 /api 前缀,
/// 跟 [AppConfig.apiUrl] 已经带的 /api 撞车 → 双 /api 404),所以两种都识别。
String apiImageResolveUrl(String url) {
  final stripped = _stripUrlAngleBrackets(url);
  if (!apiImageNeedsAuth(stripped)) return stripped;
  final base = AppConfig.apiUrl();
  final baseTrim =
      base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final parsed = Uri.tryParse(stripped);
  if (parsed?.hasScheme == true) return stripped;
  if (stripped.startsWith('/message-files/')) {
    return '$baseTrim$stripped';
  }
  if (stripped.startsWith('/api/')) {
    final origin = baseTrim.endsWith('/api')
        ? baseTrim.substring(0, baseTrim.length - 4)
        : baseTrim;
    return '$origin$stripped';
  }
  return '$baseTrim$stripped';
}

/// 同步取认证头：token 已在内存缓存时直接返回，让图片组件跳过 FutureBuilder、
/// 缓存命中当帧直出（不闪 placeholder）。
/// - 非受保护路径 → 返回 `const {}`（无需头，可直接渲染）。
/// - 受保护但 token 尚未就绪（冷启动首个请求前）→ 返回 null，调用方回退 [apiImageLoadHeaders]。
Map<String, String>? apiImageAuthHeadersSync(String url) {
  if (!apiImageNeedsAuth(url)) return const {};
  final token = RequestInterceptor.cachedToken;
  if (token == null || token.isEmpty) return null;
  return {'Authorization': 'Bearer $token'};
}

/// 预签名 URL 里每次刷新都会变、但不影响指向对象的签名/时效参数。
const _volatileSignQueryKeys = {
  'signature',
  'expires',
  'ossaccesskeyid',
  'security-token',
  'token',
};

/// 计算稳定的图片缓存键：剥掉 OSS/S3 预签名 URL 的签名/时效查询参数
/// （`X-Amz-*`、`Signature`、`Expires`、`OSSAccessKeyId` 等），让同一对象在
/// 后端每次重新签名后仍命中同一份缓存，避免 IM 重连 / 列表刷新时整图重下闪烁。
/// 非 URL（如纯 uuid）或无签名参数的 URL 原样返回。
String stableImageCacheKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.queryParameters.isEmpty) return url;
  final kept = <String, String>{};
  var stripped = false;
  uri.queryParameters.forEach((k, v) {
    final lower = k.toLowerCase();
    if (lower.startsWith('x-amz-') || _volatileSignQueryKeys.contains(lower)) {
      stripped = true;
    } else {
      kept[k] = v;
    }
  });
  if (!stripped) return url;
  final base = '${uri.host}${uri.path}';
  if (kept.isEmpty) return base;
  final q = (kept.keys.toList()..sort()).map((k) => '$k=${kept[k]}').join('&');
  return '$base?$q';
}

/// 异步读 token 拼 Authorization。非 ai-office 路径返回空 map。
Future<Map<String, String>> apiImageLoadHeaders(String url) async {
  if (!apiImageNeedsAuth(url)) return const {};
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
  if (token.isEmpty) return const {};
  return {'Authorization': 'Bearer $token'};
}
