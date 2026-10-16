import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

const _communityQrAsset = 'assets/images/community_qr.png';

Future<void> showOfficialCommunityDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x8A0F172A),
    builder: (_) => const OfficialCommunityDialog(),
  );
}

class SidebarCommunitySection extends StatefulWidget {
  const SidebarCommunitySection({super.key, this.collapsed = false});

  final bool collapsed;

  @override
  State<SidebarCommunitySection> createState() =>
      _SidebarCommunitySectionState();
}

class _SidebarCommunitySectionState extends State<SidebarCommunitySection> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: UiIconButton.custom(
          icon: const _CommunityIcon(size: 32),
          size: 44,
          tooltip: '官方社群',
          onTap: () => showOfficialCommunityDialog(context),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF165DFF).withValues(alpha: 0.09),
              blurRadius: 16,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: UiTapSurface(
          onTap: () => showOfficialCommunityDialog(context),
          onHover: (value) => setState(() => _hovered = value),
          color: _hovered
              ? Colors.white.withValues(alpha: 0.98)
              : Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: _hovered ? const Color(0xFFC7DCFF) : const Color(0xFFDDEBFF),
          ),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(
              children: [
                _CommunityIcon(size: 38),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '官方社群',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF172033),
                        ),
                      ),
                      SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '免费福利 · 新品内测 · 官方答疑',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5D6B82),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfficialCommunityDialog extends StatelessWidget {
  const OfficialCommunityDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return UiContentDialog(
      size: UiDialogSize.compact,
      maxHeight: 620,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _CommunityIcon(size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: UiSheetHeader(
                    title: '加入知办AI官方社群',
                    subtitle: '第一时间获取福利、内测资格和产品答疑',
                    onClose: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _CommunityBenefitChips(),
            const SizedBox(height: 16),
            Container(
              width: 268,
              height: 268,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF6B74FF).withValues(alpha: 0.16),
                    const Color(0xFF6B74FF).withValues(alpha: 0),
                  ],
                ),
              ),
              child: Container(
                width: 236,
                height: 236,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.12),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Image.asset(
                  package: ClientAssets.packageName,
                  _communityQrAsset,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  semanticLabel: '知办AI官方社群二维码',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '微信扫码，立即加入',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '和更多 AI 实践者一起交流',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommunityIcon extends StatelessWidget {
  const _CommunityIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7B83FF), Color(0xFF375DFB), Color(0xFF753BEB)],
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x3D536DFE),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Icon(
              CupertinoIcons.chat_bubble_2_fill,
              size: size * 0.5,
              color: Colors.white,
            ),
          ),
          Positioned(
            right: size * 0.12,
            top: size * 0.1,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: size * 0.22,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommunityBenefitChips extends StatelessWidget {
  const _CommunityBenefitChips();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _BenefitChip(
          icon: Icons.stars_rounded,
          label: '免费福利',
          foreground: Color(0xFF2563EB),
          background: Color(0xFFEFF6FF),
        ),
        SizedBox(width: 8),
        _BenefitChip(
          icon: Icons.science_rounded,
          label: '新品内测',
          foreground: Color(0xFF7C3AED),
          background: Color(0xFFF5F0FF),
        ),
        SizedBox(width: 8),
        _BenefitChip(
          icon: Icons.forum_rounded,
          label: '官方答疑',
          foreground: Color(0xFF059669),
          background: Color(0xFFECFDF5),
        ),
      ],
    );
  }
}

class _BenefitChip extends StatelessWidget {
  const _BenefitChip({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
