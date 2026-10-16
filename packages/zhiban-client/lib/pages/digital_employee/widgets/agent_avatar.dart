import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 圆形头像，支持网络图片 + 渐变 fallback；遇到 SVG URL 自动走 fallback
/// （未集成 flutter_svg）。
class AgentAvatar extends StatefulWidget {
  const AgentAvatar({
    super.key,
    required this.url,
    required this.size
  });

  final String url;
  final double size;

  @override
  State<AgentAvatar> createState() => _AgentAvatarState();
}

class _AgentAvatarState extends State<AgentAvatar> {
  late String _rawUrl;
  late bool _hasUrl;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant AgentAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    _rawUrl = widget.url.trim().startsWith('/message-files/')
        ? apiImageResolveUrl(widget.url)
        : resolveAgentAvatarUrl(widget.url);
    final lower = _rawUrl.toLowerCase();
    final isSvg = lower.contains('.svg') || lower.contains('/svg');
    _hasUrl = _rawUrl.isNotEmpty && !isSvg;
  }

  @override
  Widget build(BuildContext context) {
    // 没上传头像时，直接展示客户端内置的 bot_icon.jpeg。
    // 这样列表 / 对话头像 与"创建数字员工"弹框里的默认预留是同一只机器人。
    final fallback = ClipOval(
      child: Image.asset(
        package: ClientAssets.packageName,
        'assets/bot_icon.jpeg',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: widget.size,
          height: widget.size,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
            ),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.smart_toy_rounded,
            color: Colors.white,
            size: widget.size * 0.5,
          ),
        ),
      ),
    );

    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        // UiNetworkImage 同步取已就绪的请求头，让缓存头像首帧直接显示；
        // 仅冷启动鉴权未就绪时由共享组件异步加载，不再外包 FutureBuilder。
        child: _hasUrl
            ? UiNetworkImage(
                imageUrl: _rawUrl,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                cacheKey: stableAvatarCacheKey(_rawUrl),
                placeholderBuilder: (_, __) => fallback,
                errorBuilder: (_, __, ___) => fallback,
              )
            : fallback,
      ),
    );
  }
}
