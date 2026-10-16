import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';

class ChatContactProfile {
  const ChatContactProfile({
    required this.kind,
    required this.accountUuid,
    required this.displayName,
    this.avatarUrl = '',
    this.departmentName = '',
    this.positionLabel = '',
    this.email = '',
    this.companyName = '',
    this.capabilityNames = const <String>[],
    this.isSelf = false,
  });

  final String kind;
  final String accountUuid;
  final String displayName;
  final String avatarUrl;
  final String departmentName;
  final String positionLabel;
  final String email;
  final String companyName;
  final List<String> capabilityNames;
  final bool isSelf;

  bool get isHuman => kind == 'human';
}

Future<void> showChatContactProfileCard(
  BuildContext context, {
  required Offset anchor,
  required ChatContactProfile profile,
  VoidCallback? onMessage,
  VoidCallback? onVoiceCall,
  VoidCallback? onVideoCall,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭名片',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 90),
    pageBuilder: (dialogContext, _, __) {
      return _ProfileCardRoute(
        anchor: anchor,
        profile: profile,
        onMessage: onMessage,
        onVoiceCall: onVoiceCall,
        onVideoCall: onVideoCall,
      );
    },
  );
}

class _ProfileCardRoute extends StatelessWidget {
  const _ProfileCardRoute({
    required this.anchor,
    required this.profile,
    this.onMessage,
    this.onVoiceCall,
    this.onVideoCall,
  });

  static const double _cardWidth = 326;
  static const double _cardHeight = 326;

  final Offset anchor;
  final ChatContactProfile profile;
  final VoidCallback? onMessage;
  final VoidCallback? onVoiceCall;
  final VoidCallback? onVideoCall;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final left = math.min(
          math.max(12, anchor.dx + 10),
          math.max(12, maxW - _cardWidth - 12),
        );
        final top = math.min(
          math.max(12, anchor.dy - 12),
          math.max(12, maxH - _cardHeight - 12),
        );
        return Stack(
          children: [
            Positioned(
              left: left.toDouble(),
              top: top.toDouble(),
              width: _cardWidth,
              child: _ChatContactProfileCard(
                profile: profile,
                onMessage: onMessage,
                onVoiceCall: onVoiceCall,
                onVideoCall: onVideoCall,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChatContactProfileCard extends StatelessWidget {
  const _ChatContactProfileCard({
    required this.profile,
    this.onMessage,
    this.onVoiceCall,
    this.onVideoCall,
  });

  final ChatContactProfile profile;
  final VoidCallback? onMessage;
  final VoidCallback? onVoiceCall;
  final VoidCallback? onVideoCall;

  void _run(BuildContext context, VoidCallback? callback) {
    if (callback == null) return;
    Navigator.of(context).pop();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final name =
        profile.displayName.trim().isEmpty ? '未命名' : profile.displayName.trim();
    final position = profile.positionLabel.trim();
    final dept = profile.departmentName.trim();
    final email = _displayValue(profile.email);
    final company = _displayValue(profile.companyName);
    final capabilities = profile.capabilityNames
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .take(4)
        .join('、');
    final subtitle = [
      if (position.isNotEmpty) position,
      if (dept.isNotEmpty) dept,
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E6EB), width: 0.8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ChatAvatar(
                  url: profile.avatarUrl.isEmpty ? null : profile.avatarUrl,
                  fallbackText: name,
                  kind: profile.isHuman
                      ? ChatAvatarKind.user
                      : ChatAvatarKind.agent,
                  size: 58,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1D2129),
                                height: 1.2,
                              ),
                            ),
                          ),
                          if (profile.isSelf) ...[
                            const SizedBox(width: 8),
                            _SmallTag(text: '我'),
                          ],
                        ],
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF86909C),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1, color: Color(0xFFE8EDF4)),
            const SizedBox(height: 14),
            _InfoRow(label: '邮箱', value: email),
            const SizedBox(height: 8),
            _InfoRow(label: '部门', value: _displayValue(dept)),
            const SizedBox(height: 8),
            _InfoRow(label: '企业', value: company),
            if (!profile.isHuman && capabilities.isNotEmpty) ...[
              const SizedBox(height: 8),
              _InfoRow(label: '技能', value: capabilities),
            ],
            if (onMessage != null ||
                onVoiceCall != null ||
                onVideoCall != null) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: '发消息',
                      primary: true,
                      icon: CupertinoIcons.chat_bubble_text_fill,
                      onPressed: onMessage == null
                          ? null
                          : () => _run(context, onMessage),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: '语音',
                      icon: CupertinoIcons.phone_fill,
                      onPressed: onVoiceCall == null
                          ? null
                          : () => _run(context, onVoiceCall),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: '视频',
                      icon: CupertinoIcons.video_camera_solid,
                      onPressed: onVideoCall == null
                          ? null
                          : () => _run(context, onVideoCall),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _displayValue(String value) {
    final text = value.trim();
    return text.isEmpty ? '未设置' : text;
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF86909C),
              height: 1.4,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF1D2129),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFF2563EB),
          height: 1.0,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    this.primary = false,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = primary
        ? Colors.white
        : enabled
            ? const Color(0xFF1D2129)
            : const Color(0xFFC9CDD4);
    final bg = primary
        ? (enabled ? const Color(0xFF2F7DF6) : const Color(0xFFBBD4FF))
        : enabled
            ? const Color(0xFFF4F6FA)
            : const Color(0xFFF7F8FA);
    return SizedBox(
      height: 38,
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: fg,
          backgroundColor: bg,
          disabledForegroundColor: fg,
          disabledBackgroundColor: bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
