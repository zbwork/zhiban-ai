import 'package:zhiban_client/config/client_assets.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/settings/share_invite_api.dart';
import 'package:zhiban_client/pages/settings/share_invite_poster.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// F29 分享给朋友：桌面端弹框（左海报预览 + 右专属邀请信息）。
/// 设计权威 docs/features/F29-friend-share-invite.md §1；
/// 契约 docs/contracts/agent-bus-client-contract.md §17。

Future<void> showShareInviteDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const UiDialogShell(
      size: UiDialogSize.wide,
      maxHeight: 704,
      child: ShareInviteContent(),
    ),
  );
}

class ShareInviteContent extends ConsumerStatefulWidget {
  const ShareInviteContent({super.key});

  @override
  ConsumerState<ShareInviteContent> createState() => _ShareInviteContentState();
}

class _ShareInviteContentState extends ConsumerState<ShareInviteContent> {
  bool _savingPoster = false;

  @override
  Widget build(BuildContext context) {
    final inviteAsync = ref.watch(shareInviteProvider);
    return SizedBox(
      // 固定内容宽度贴合设计稿比例（左卡 412 + 间距 40 + 右栏 ~386）。
      width: 906,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(34, 28, 24, 0),
            child: UiSheetHeader(
              title: '分享给朋友',
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(34, 20, 34, 34),
              child: inviteAsync.when(
                loading: () => const SizedBox(
                  height: 572,
                  child: Center(child: CupertinoActivityIndicator()),
                ),
                error: (_, __) => _buildError(),
                data: (invite) => _buildBody(invite),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return SizedBox(
      height: 572,
      child: Center(
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
      ),
    );
  }

  Widget _buildBody(ShareInvite invite) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PosterPreviewCard(invite: invite),
        const SizedBox(width: 40),
        Expanded(child: _buildInviteInfo(invite)),
      ],
    );
  }

  Widget _buildInviteInfo(ShareInvite invite) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 38),
        const Text(
          '专属邀请信息',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111827),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '复制邀请码或链接，分享给好友快速体验知办AI',
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Color(0xFF697386)
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
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
              const SizedBox(height: 24),
              _CopyableField(
                label: '邀请链接',
                value: invite.url,
                onCopy: () => _copy(invite.url, '已复制邀请链接'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Row(
              children: [
                Expanded(
                  flex: 19,
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: () => _copy(invite.url, '已复制邀请链接'),
                      icon: const Icon(CupertinoIcons.link, size: 16),
                      label: const Text(
                        '复制邀请链接',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 18,
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed:
                          _savingPoster ? null : () => _savePoster(invite),
                      icon: _savingPoster
                          ? const CupertinoActivityIndicator(radius: 8)
                          : const Icon(
                              CupertinoIcons.arrow_down_to_line,
                              size: 16,
                            ),
                      label: const Text(
                        '下载海报',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

/// 左侧海报预览卡：生成式背景插画 + Flutter 叠加的准确品牌文案和动态二维码。
class _PosterPreviewCard extends StatelessWidget {
  const _PosterPreviewCard({required this.invite});

  final ShareInvite invite;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 412,
      height: 572,
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
                  key: ValueKey('share-invite-bottom-contrast'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00F7FBFF),
                        Color(0xDDF7FBFF),
                        Color(0xFFF7FBFF),
                      ],
                      stops: [0, 0.42, 1],
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
