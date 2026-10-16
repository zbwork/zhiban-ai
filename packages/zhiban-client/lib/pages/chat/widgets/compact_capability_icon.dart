import 'package:flutter/material.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 对话区紧凑能力图标。
///
/// 能力条、输入框已选标签和已发送消息标签共用，确保同一个技能在三个阶段
/// 展示同一图标；无图、SVG/data URI 或加载失败时由调用方提供统一 fallback。
class CompactCapabilityIcon extends StatelessWidget {
  const CompactCapabilityIcon({
    super.key,
    required this.iconUrl,
    required this.size,
    required this.borderRadius,
    required this.fallback,
  });

  final String iconUrl;
  final double size;
  final double borderRadius;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final resolved = resolveAgentAvatarUrl(iconUrl.trim());
    final lower = resolved.toLowerCase();
    final hasIcon = resolved.isNotEmpty &&
        !lower.startsWith('data:') &&
        !lower.contains('.svg') &&
        !lower.contains('/svg');
    if (!hasIcon) return fallback;
    return UiNetworkImage(
      imageUrl: resolved,
      width: size,
      height: size,
      fit: BoxFit.cover,
      borderRadius: borderRadius,
      placeholderBuilder: (_, __) => fallback,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
