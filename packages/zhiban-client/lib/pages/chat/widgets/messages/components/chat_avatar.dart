import 'package:zhiban_client/config/client_assets.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 聊天气泡左/右两侧 40x40 头像（知办AI 风格）。
///
/// - 圆角 10px，比 chat.html `rounded-md` 略圆，桌面端观感更柔；
/// - URL 为空 / 加载失败 / 是 SVG（暂未集成 flutter_svg）时回落到品牌默认头像；
/// - agent 默认头像在右下角带一个绿色"在线"小点，呼应"数字员工"在岗的语义。
class ChatAvatar extends StatefulWidget {
  const ChatAvatar({
    super.key,
    this.url,
    this.fallbackText,
    this.size = 40,
    this.kind = ChatAvatarKind.agent,
    this.showOnlineDot = false,
  });

  final String? url;
  final String? fallbackText;
  final double size;
  final ChatAvatarKind kind;

  /// 是否在右下角叠加在线绿点（agent 默认显示，user 不显示）。
  final bool showOnlineDot;

  @override
  State<ChatAvatar> createState() => _ChatAvatarState();
}

class _ChatAvatarState extends State<ChatAvatar> {
  String? _rawUrl;
  String _resolvedUrl = '';
  Future<Map<String, String>>? _headersFuture;

  @override
  void initState() {
    super.initState();
    _refreshResolvedUrl();
  }

  @override
  void didUpdateWidget(ChatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _refreshResolvedUrl();
    }
  }

  void _refreshResolvedUrl() {
    final raw = (widget.url ?? '').trim();
    if (_rawUrl == raw) return;
    _rawUrl = raw;
    final needsAuth = apiImageNeedsAuth(raw);
    _resolvedUrl =
        needsAuth ? apiImageResolveUrl(raw) : resolveAgentAvatarUrl(raw);
    _headersFuture =
        needsAuth && _resolvedUrl.isNotEmpty ? apiImageLoadHeaders(raw) : null;
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final defaultPlaceholder = _DefaultAvatar(
      size: widget.size,
      kind: widget.kind,
      fallbackText: widget.fallbackText,
    );
    // 后端 `digital_employees.avatar_url` 多是 `/api/agent-bus/v1/assets/...` 这种相对路径,
    // 经 resolveAgentAvatarUrl 补 origin 后才能交给 CachedNetworkImage 拉。
    final raw = _resolvedUrl;
    final headersFuture = _headersFuture;
    final lower = raw.toLowerCase();
    final isSvg = lower.contains('.svg') || lower.contains('/svg');
    // ai-office 给未上传头像的账号返回一张 bitmoji 风格的"圆形贴白方底" PNG
    // (`/portrait/default/nan.png` / `nv.png`)，按 10px 圆角方块裁出来视觉上
    // 是"白方框里嵌个圆"，跟左侧 agent 满铺方头像不统一；这里把这类预留 URL
    // 当作"无头像"处理，让它走我们自己的方头像 fallback。
    final isServerPlaceholder = lower.contains('/portrait/default/');
    final hasUrl = raw.isNotEmpty && !isSvg && !isServerPlaceholder;

    final imageBox = ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: hasUrl
            ? _ChatAvatarImage(
                imageUrl: raw,
                headersFuture: headersFuture,
                size: widget.size,
                fallback: defaultPlaceholder,
              )
            : defaultPlaceholder,
      ),
    );

    // 直接用图片本身，不再叠 1.5px 白色描边和阴影：
    // 1) 在线点 + 白边 + 圆角组合在视觉上会把方头像渲染成"圆头像"；
    // 2) 知办AI 聊天里头像就是 10px 圆角方块，去边后形状一目了然。
    final framed = SizedBox(
      width: widget.size,
      height: widget.size,
      child: imageBox,
    );

    if (!widget.showOnlineDot) return framed;

    final dotSize = widget.size * 0.28;
    return SizedBox(
      width: widget.size + 2,
      height: widget.size + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: 0, top: 0, child: framed),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: ChatTheme.wxOnline,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum ChatAvatarKind { user, agent }

class _ChatAvatarImage extends StatelessWidget {
  const _ChatAvatarImage({
    required this.imageUrl,
    required this.headersFuture,
    required this.size,
    required this.fallback,
  });

  final String imageUrl;
  final Future<Map<String, String>>? headersFuture;
  final double size;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    if (headersFuture == null) {
      return UiNetworkImage(
        imageUrl: imageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheKey: stableAvatarCacheKey(imageUrl),
        placeholderBuilder: (_, __) => fallback,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return FutureBuilder<Map<String, String>>(
      future: headersFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return fallback;
        }
        return UiNetworkImage(
          imageUrl: imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          httpHeaders: snap.data,
          cacheKey: stableAvatarCacheKey(imageUrl),
          placeholderBuilder: (_, __) => fallback,
          errorBuilder: (_, __, ___) => fallback,
        );
      },
    );
  }
}

class _DefaultAvatar extends StatelessWidget {
  const _DefaultAvatar({
    required this.size,
    required this.kind,
    this.fallbackText,
  });

  final double size;
  final ChatAvatarKind kind;
  final String? fallbackText;

  @override
  Widget build(BuildContext context) {
    final isUser = kind == ChatAvatarKind.user;
    final initial = firstAvatarDisplayChar(fallbackText);
    if (isUser && initial.isNotEmpty) {
      return _InitialAvatar(size: size, initial: initial);
    }
    // Agent / User 都用客户端内置静态资源做兜底：
    //  - agent: assets/bot_icon.jpeg  与"创建数字员工"弹框里的默认预留保持一致；
    //  - user : assets/user_icon.png  3D 头像风格，跟整体卡通插画系一致；
    // 任意一个 asset 缺失（比如旧版本 app）才退回渐变 + Icon 的兜底。
    final assetPath = isUser ? 'assets/user_icon.png' : 'assets/bot_icon.jpeg';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.asset(
        package: ClientAssets.packageName,
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _gradientFallback(isUser: isUser),
      ),
    );
  }

  Widget _gradientFallback({required bool isUser}) {
    final colors = isUser
        ? const [Color(0xFF34D399), Color(0xFF059669)]
        : const [Color(0xFF6366F1), Color(0xFF4F46E5)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(
        isUser ? Icons.person_rounded : Icons.smart_toy_rounded,
        color: Colors.white,
        size: size * 0.55,
      ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({required this.size, required this.initial});

  final double size;
  final String initial;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: avatarGradientColors(initial),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

String firstAvatarDisplayChar(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return '';
  final runes = text.runes.toList(growable: false);
  if (runes.isEmpty) return '';
  return String.fromCharCode(runes.first).toUpperCase();
}

List<Color> avatarGradientColors(String seed) {
  const palettes = <List<Color>>[
    [Color(0xFFA855F7), Color(0xFF7C3AED)], // purple
    [Color(0xFF2DD4BF), Color(0xFF0F766E)], // teal
    [Color(0xFF60A5FA), Color(0xFF2563EB)], // blue
    [Color(0xFF34D399), Color(0xFF059669)], // green
    [Color(0xFFF97316), Color(0xFFEA580C)], // orange
    [Color(0xFFEC4899), Color(0xFFBE185D)], // pink
    [Color(0xFF818CF8), Color(0xFF4F46E5)], // indigo
    [Color(0xFFF59E0B), Color(0xFFD97706)], // amber
  ];
  final runes = seed.runes.toList(growable: false);
  if (runes.isEmpty) return palettes.first;
  final sum = runes.fold<int>(0, (acc, v) => acc + v);
  return palettes[sum % palettes.length];
}
