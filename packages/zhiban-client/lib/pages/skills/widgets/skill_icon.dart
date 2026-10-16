import 'package:flutter/material.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 技能图标统一展示组件。
///
/// 处理两类 fallback：
/// 1. `iconUrl` 为空 → 渲染本地 Material 扳手图标。
/// 2. `iconUrl` 以 `data:` 开头（后端的默认 SVG data URI）→ 也回落到本地扳手图标，
///    避免端上没有 flutter_svg 导致 Image.network 加载失败。
///
/// [size] 控制图标容器边长（含背景色块），实际 icon/图片会自动适配。
class SkillIcon extends StatelessWidget {
  const SkillIcon({
    super.key,
    required this.iconUrl,
    this.size = 40,
    this.borderRadius,
    this.backgroundColor = const Color(0xFFEEF2FF),
    this.fallbackColor = const Color(0xFF6366F1),
  });

  final String iconUrl;
  final double size;
  final BorderRadius? borderRadius;
  final Color backgroundColor;
  final Color fallbackColor;

  bool get _useFallback {
    final url = iconUrl.trim();
    if (url.isEmpty) return true;
    // 后端默认值是 SVG data URI，前端没有 svg 渲染能力时统一回落到本地扳手。
    if (url.startsWith('data:')) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(size * 0.25);
    if (_useFallback) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: radius
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.handyman_rounded,
          size: size * 0.55,
          color: fallbackColor,
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: UiNetworkImage(
        imageUrl: iconUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholderBuilder: (_, __) => Container(
          width: size,
          height: size,
          color: backgroundColor
        ),
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          color: backgroundColor,
          alignment: Alignment.center,
          child: Icon(
            Icons.handyman_rounded,
            size: size * 0.55,
            color: fallbackColor,
          ),
        ),
      ),
    );
  }
}
