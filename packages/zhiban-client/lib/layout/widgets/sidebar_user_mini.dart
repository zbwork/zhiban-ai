import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

String sidebarDisplayName(AccountInfo? info) {
  if (info == null) return '加载中...';
  if (info.name.trim().isNotEmpty) return info.name.trim();
  if (info.nickname.trim().isNotEmpty) return info.nickname.trim();
  if (info.email.trim().isNotEmpty) return info.email.trim();
  return '加载中...';
}

class SidebarUserMini extends StatefulWidget {
  const SidebarUserMini({
    super.key,
    required this.info,
    required this.onTap,
    this.collapsed = false,
  });

  final AccountInfo? info;
  final VoidCallback onTap;
  final bool collapsed;

  @override
  State<SidebarUserMini> createState() => _SidebarUserMiniState();
}

class _SidebarUserMiniState extends State<SidebarUserMini> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // 企业微信式左上角用户块: 只有头像 + 名字, 点击弹个人弹框。
    final name = sidebarDisplayName(widget.info);
    final content = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: EdgeInsets.symmetric(
              horizontal: widget.collapsed ? 0 : 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.64)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SidebarUserAvatar(
                  info: widget.info, size: widget.collapsed ? 36 : 44),
              if (!widget.collapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF172033),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return widget.collapsed ? Tooltip(message: name, child: content) : content;
  }
}

class SidebarUserAvatar extends StatelessWidget {
  const SidebarUserAvatar({super.key, required this.info, this.size = 38});

  final AccountInfo? info;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = info?.avatar.trim() ?? '';
    final lower = url.toLowerCase();
    final hasNetworkAvatar = url.startsWith('http') &&
        !lower.endsWith('/portrait/default.png') &&
        !lower.endsWith('/portrait/default.jpg');
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
      ),
      child: hasNetworkAvatar
          ? UiNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              borderRadius: size / 2,
              placeholderBuilder: (_, __) => _SidebarAvatarDefault(size: size),
              errorBuilder: (_, __, ___) => _SidebarAvatarDefault(size: size),
            )
          : _SidebarAvatarDefault(size: size),
    );
  }
}

class _SidebarAvatarDefault extends StatelessWidget {
  const _SidebarAvatarDefault({this.size = 38});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Image.asset(
        package: ClientAssets.packageName,
        'assets/user_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}
