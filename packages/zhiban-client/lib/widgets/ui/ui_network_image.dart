import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/network/api_image_auth.dart';

typedef UiNetworkPlaceholderBuilder = Widget Function(
  BuildContext context,
  String imageUrl
);

typedef UiNetworkErrorBuilder = Widget Function(
  BuildContext context,
  String imageUrl,
  Object error
);

/// 统一封装的网络图片组件。
/// - 默认 fadeIn/fadeOut 为 Duration.zero（无闪烁过渡）
/// - 默认 placeholder / error 为同款浅色圆角预留块
/// - 支持按场景覆写预留、错误态、alignment 与 imageBuilder
/// - URL 命中受保护路径（`/app/`、`/chat/media/` 等）时自动注入 Bearer token，
///   Future 缓存在 State 内，父级 rebuild 不会重置 FutureBuilder。
class UiNetworkImage extends StatefulWidget {
  const UiNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 6.0,
    this.httpHeaders,
    this.cacheKey,
    this.alignment = Alignment.center,
    this.fadeInDuration = Duration.zero,
    this.fadeOutDuration = Duration.zero,
    this.placeholderBuilder,
    this.errorBuilder,
    this.imageBuilder,
    this.clip = true,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;

  /// 显式传入时直接使用，跳过自动 token 检测。
  /// 传 `const {}` 可强制无 header 且不触发自动检测。
  final Map<String, String>? httpHeaders;
  final String? cacheKey;
  final Alignment alignment;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;
  final UiNetworkPlaceholderBuilder? placeholderBuilder;
  final UiNetworkErrorBuilder? errorBuilder;
  final Widget Function(BuildContext context, ImageProvider imageProvider)?
      imageBuilder;
  final bool clip;

  @override
  State<UiNetworkImage> createState() => _UiNetworkImageState();
}

class _UiNetworkImageState extends State<UiNetworkImage> {
  /// 已解析好的请求头（同步命中时直接用，跳过 FutureBuilder）。
  Map<String, String>? _headers;

  /// 仅在 token 尚未就绪、需异步取头时非空。
  Future<Map<String, String>>? _headersFuture;

  @override
  void initState() {
    super.initState();
    _resolveHeaders();
  }

  @override
  void didUpdateWidget(UiNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.httpHeaders != widget.httpHeaders) {
      _resolveHeaders();
    }
  }

  void _resolveHeaders() {
    _headers = null;
    _headersFuture = null;
    // Explicit headers take priority — skip auto-detection.
    if (widget.httpHeaders != null) {
      _headers = widget.httpHeaders;
      return;
    }
    // token 已在内存 → 同步取头，避免每次挂载闪一帧 placeholder；
    // 仅冷启动 token 未就绪时才回退异步。
    final sync = apiImageAuthHeadersSync(widget.imageUrl);
    if (sync != null) {
      _headers = sync;
      return;
    }
    _headersFuture = apiImageLoadHeaders(widget.imageUrl);
  }

  /// 小尺寸容器（如 22px 头像）按比例缩小图标，避免顶满/贴边；
  /// 常规尺寸维持 20px 不变。
  double get _placeholderIconSize {
    final dims = <double>[
      if (widget.width != null) widget.width!,
      if (widget.height != null) widget.height!,
    ];
    if (dims.isEmpty) return 20;
    final minDim = dims.reduce((a, b) => a < b ? a : b);
    return (minDim * 0.6).clamp(10.0, 20.0);
  }

  Widget _defaultPlaceholder() => Container(
        width: widget.width,
        height: widget.height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFEEF2F7),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: Icon(
          CupertinoIcons.photo,
          color: Colors.grey,
          size: _placeholderIconSize,
        ),
      );

  Widget _buildImage(Map<String, String>? headers) {
    final image = CachedNetworkImage(
      imageUrl: widget.imageUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      fadeInDuration: widget.fadeInDuration,
      fadeOutDuration: widget.fadeOutDuration,
      httpHeaders: headers,
      // 用稳定键缓存：剥掉预签名 URL 每次变化的签名参数，避免后端重签后整图重下闪烁。
      cacheKey: stableImageCacheKey(widget.cacheKey ?? widget.imageUrl),
      imageBuilder: widget.imageBuilder,
      placeholder: (ctx, url) =>
          widget.placeholderBuilder?.call(ctx, url) ?? _defaultPlaceholder(),
      errorWidget: (ctx, url, error) =>
          widget.errorBuilder?.call(ctx, url, error) ?? _defaultPlaceholder(),
    );
    if (!widget.clip) return image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: image,
    );
  }

  @override
  Widget build(BuildContext context) {
    final headersFuture = _headersFuture;
    if (headersFuture != null) {
      return FutureBuilder<Map<String, String>>(
        future: headersFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return widget.placeholderBuilder?.call(context, widget.imageUrl) ??
                _defaultPlaceholder();
          }
          return _buildImage(snap.data);
        },
      );
    }
    return _buildImage(_headers);
  }
}
