import 'package:flutter/material.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: sourceColor(source).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        sourceLabel(source),
        style: TextStyle(
          fontSize: 11,
          color: sourceColor(source),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AgentBotBadge extends StatelessWidget {
  const AgentBotBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2F4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'BOT',
        style: TextStyle(
          fontSize: 13,
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ContactAvatar extends StatelessWidget {
  const ContactAvatar({
    super.key,
    required this.url,
    required this.name,
    required this.size,
    this.borderRadius,
    this.fontSize,
  });

  final String url;
  final String name;
  final double size;
  final double? borderRadius;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    // 后端 avatarUrl 可能是 `/api/agent-bus/v1/assets/...` 或受保护的
    // `/message-files/...`。后者必须补 agent-bus baseURL 并带 Bearer。
    final raw = url.trim().startsWith('/message-files/')
        ? apiImageResolveUrl(url)
        : resolveAgentAvatarUrl(url);
    final lower = raw.toLowerCase();
    final hasAvatar = raw.isNotEmpty &&
        !lower.contains('.svg') &&
        !lower.contains('/svg') &&
        !lower.contains('/portrait/default/');
    final radius = borderRadius ?? (size >= 80 ? 12.0 : 6.0);
    final initial = firstAvatarDisplayChar(name).isEmpty
        ? (size >= 44 ? 'AI' : '')
        : firstAvatarDisplayChar(name);
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: avatarGradientColors(initial),
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: size >= 80
            ? const [
                BoxShadow(
                  color: Color(0x1F0F172A),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize ?? size * 0.42,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
    if (!hasAvatar) return fallback;
    return UiNetworkImage(
      imageUrl: raw,
      width: size,
      height: size,
      fit: BoxFit.cover,
      borderRadius: radius,
      cacheKey: stableAvatarCacheKey(raw),
      placeholderBuilder: (_, __) => fallback,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
