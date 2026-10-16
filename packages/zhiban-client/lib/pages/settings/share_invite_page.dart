import 'package:zhiban_client/config/client_assets.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/settings/share_invite_api.dart';
import 'package:zhiban_client/pages/settings/share_invite_poster.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// F29 分享给朋友：移动端全屏页（复用桌面端弹框同一份数据源/海报渲染管线，
/// 布局改为纵向堆叠适配窄屏）。设计权威 docs/features/F29-friend-share-invite.md §1。

class ShareInvitePage extends ConsumerStatefulWidget {
  const ShareInvitePage({super.key});

  @override
  ConsumerState<ShareInvitePage> createState() => _ShareInvitePageState();
}

class _ShareInvitePageState extends ConsumerState<ShareInvitePage> {
  bool _savingPoster = false;

  @override
  Widget build(BuildContext context) {
    final inviteAsync = ref.watch(shareInviteProvider);
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '分享给朋友',
        backgroundColor: ColorConfig.pageBackground,
      ),
      body: SafeArea(
        child: inviteAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (_, __) => _buildError(),
          data: (invite) => _buildBody(invite),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '邀请信息加载失败，请稍后再试',
            style: TextStyle(fontSize: 14, color: Color(0xFF697386)),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => ref.invalidate(shareInviteProvider),
            child: const Text('重新加载'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ShareInvite invite) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PosterPreviewCard(invite: invite),
          const SizedBox(height: 24),
          const Text(
            '专属邀请信息',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '复制邀请码或链接，分享给好友快速体验知办AI',
            style: TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF697386)),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE9EEF5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CopyableField(
                  label: '专属邀请码',
                  value: invite.inviteCode,
                  onCopy: () => _copy(invite.inviteCode, '已复制邀请码'),
                ),
                const SizedBox(height: 18),
                _CopyableField(
                  label: '邀请链接',
                  value: invite.url,
                  onCopy: () => _copy(invite.url, '已复制邀请链接'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: () => _copy(invite.url, '已复制邀请链接'),
              icon: const Icon(CupertinoIcons.link, size: 16),
              label: const Text(
                '复制邀请链接',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _savingPoster ? null : () => _savePoster(invite),
              icon: _savingPoster
                  ? const CupertinoActivityIndicator(radius: 8)
                  : const Icon(CupertinoIcons.arrow_down_to_line, size: 16),
              label: const Text(
                '保存海报',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(String value, String toast) async {
    await Clipboard.setData(ClipboardData(text: value));
    BotToast.showText(text: toast);
  }

  Future<void> _savePoster(ShareInvite invite) async {
    setState(() => _savingPoster = true);
    try {
      final bytes = await renderShareInvitePoster(
        ShareInvitePosterSpec(url: invite.url, inviteCode: invite.inviteCode),
      );
      final path = await saveShareInvitePoster(bytes);
      if (path != null) BotToast.showText(text: '邀请海报已保存');
    } catch (_) {
      BotToast.showText(text: '保存海报失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _savingPoster = false);
    }
  }
}

/// 与桌面端弹框同款海报预览卡，改为全宽自适应（保持 412:572 的原始比例）。
class _PosterPreviewCard extends StatelessWidget {
  const _PosterPreviewCard({required this.invite});

  final ShareInvite invite;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 412 / 572,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              package: ClientAssets.packageName,
              'assets/images/share_invite_card_background.png',
              key: const ValueKey('share-invite-card-background'),
              fit: BoxFit.cover,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Color(0x1AFFFFFF), Color(0x00FFFFFF)],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 164,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('share-invite-bottom-contrast'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x00F7FBFF),
                        Color(0xDDF7FBFF),
                        Color(0xFFF7FBFF),
                      ],
                      stops: const [0, 0.42, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 28,
              top: 28,
              right: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.asset(
                          package: ClientAssets.packageName,
                          'assets/app_icon.png',
                          width: 26,
                          height: 26,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '知办AI',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '邀请好友使用',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const Text(
                    '知办AI',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '智能办公好搭档，效率从此加速',
                    style: TextStyle(fontSize: 13, color: Color(0xFF697386)),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 28,
              right: 24,
              bottom: 30,
              child: Row(
                key: const ValueKey('share-invite-bottom-content'),
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x140F3E84),
                          blurRadius: 10,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      key: const ValueKey('share-invite-qr'),
                      data: invite.url,
                      version: QrVersions.auto,
                      errorCorrectionLevel: QrErrorCorrectLevel.H,
                      size: 88,
                      gapless: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '扫码注册  体验智能办公',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                            color: Color(0xFF1D2129),
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '由我邀请，享受更快上手',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyableField extends StatelessWidget {
  const _CopyableField({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 9),
        Container(
          height: 52,
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE5EAF1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1D2129),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              UiIconButton(
                icon: CupertinoIcons.doc_on_doc,
                size: 32,
                iconSize: 16,
                tooltip: '复制',
                onTap: onCopy,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
