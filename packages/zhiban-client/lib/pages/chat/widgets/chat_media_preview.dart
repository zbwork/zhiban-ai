import 'package:flutter/cupertino.dart';
import 'attachment_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart'
    show resolveChatMediaUrlPublic;
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/widgets/ui/chat_platform_widgets.dart';
import 'package:zhiban_ui/widgets/ui_image_hero.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F09 P2 媒体消息体验 (2026-06): 图片大图预览 overlay.
///
/// 见 `docs/contracts/agent-bus-client-contract.md` §「媒体消息体验 / 图片大图预览」.
///
/// 视觉: 全屏黑底 overlay,中央 InteractiveViewer 居中图;顶栏左侧关闭, 中间「i / N」序号,
/// 右侧「保存」按钮 (走 `ChatMediaDownloadController.start`);左右两侧浮按钮上一张/下一张。
/// 仅含当前会话**已加载窗口**内的图片消息;不自动拉历史。
/// 失败/加载中: ColoredBox + Icon, 不 crash。

/// 单张图片描述: chat_media_ref URL + 发送人 + 文件名 (用于顶部计数 / 保存默认名)。
class ChatPreviewImage {
  const ChatPreviewImage({
    required this.url,
    required this.senderName,
    required this.fileName,
    required this.messageKey,
  });
  final String url;
  final String senderName;
  final String fileName;

  /// 用于在 `messages` 里回查这张图属于哪条消息 (= `imMessageIdentity(msg)`).
  final String messageKey;
}

/// 从一段消息列表中收集所有「可预览图片」 (顺序与 messages 一致, 升序时间)。
///
/// 收集规则:
///   - 顶层 image 媒体 + 非空 mediaUrl;
///   - mixed 内的 image block + 非空 url (mixed 内的 file/skill/callEvent 一律忽略);
///   - 已撤回 / pending / failed / uploading 的图片预留态**不**收集 (无稳定 URL)。
///
/// 返回的每张图都带 `messageKey` (`imMessageIdentity(msg)`),便于 `findImagePreviewIndex` 起点定位。
List<ChatPreviewImage> collectPreviewableImages(
  List<ImMessage> messages, {
  required String Function(ImMessage msg) resolveSenderName,
}) {
  final out = <ChatPreviewImage>[];
  for (final m in messages) {
    if (m.isRevoked) continue;
    if (m.isPending || m.isFailed || m.isUploading) continue;
    final sender = resolveSenderName(m);
    final keyId = _messageKey(m);
    if (m.mediaKind == ImMediaKind.image && m.mediaUrl.trim().isNotEmpty) {
      out.add(ChatPreviewImage(
        url: m.mediaUrl,
        senderName: sender,
        fileName: m.mediaName.trim().isNotEmpty ? m.mediaName : '[图片]',
        messageKey: keyId,
      ));
      continue;
    }
    if (m.isMixed) {
      for (final b in m.blocks) {
        if (b.isImage && b.url.trim().isNotEmpty) {
          out.add(ChatPreviewImage(
            url: b.url,
            senderName: sender,
            fileName: b.name.trim().isNotEmpty ? b.name : '[图片]',
            messageKey: keyId,
          ));
        }
      }
    }
  }
  return out;
}

/// 寻找 [startMessageKey] (即用户点击的那条消息) 在 [images] 里第一张图片的下标。
/// 找不到 → 0 (回退第一张, 不 crash)。
int findImagePreviewIndex(
  List<ChatPreviewImage> images,
  String startMessageKey,
) {
  if (images.isEmpty) return 0;
  for (int i = 0; i < images.length; i++) {
    if (images[i].messageKey == startMessageKey) return i;
  }
  return 0;
}

/// 内联使用的 messageKey (与 `imMessageIdentity` 同口径但避免引入跨文件依赖)。
String _messageKey(ImMessage m) {
  if (m.clientMsgNo.isNotEmpty) return 'cmn:${m.clientMsgNo}';
  if (m.messageId.isNotEmpty &&
      m.messageId != '0' &&
      !m.messageId.startsWith('local-')) {
    return 'srv:${m.messageId}';
  }
  return 'loc:${m.messageId}';
}

/// 展示图片预览 overlay。`initialIndex` 是 [images] 中的起始位置。
Future<void> showChatImagePreview({
  required BuildContext context,
  required List<ChatPreviewImage> images,
  required int initialIndex,
  Object? heroTag,
}) {
  if (images.isEmpty) return Future.value();
  final safeIndex = initialIndex.clamp(0, images.length - 1);
  final selected = images[safeIndex];
  if (tryOpenChatImagePreview(context,
      rawUrl: resolveChatMediaUrlPublic(selected.url),
      displayName: selected.fileName)) {
    return Future.value();
  }
  return showImagePreviewRoute<void>(
    context: context,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (_) => ChatImagePreviewDialog(
      images: images,
      initialIndex: safeIndex,
      heroTag: heroTag,
    ),
  );
}

class ChatImagePreviewDialog extends ConsumerStatefulWidget {
  const ChatImagePreviewDialog({
    super.key,
    required this.images,
    required this.initialIndex,
    this.heroTag,
  });
  final List<ChatPreviewImage> images;
  final int initialIndex;
  final Object? heroTag;

  @override
  ConsumerState<ChatImagePreviewDialog> createState() =>
      _ChatImagePreviewDialogState();
}

class _ChatImagePreviewDialogState
    extends ConsumerState<ChatImagePreviewDialog> {
  late PageController _pageCtrl;
  late int _index;
  Map<String, String>? _headers;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageCtrl = PageController(initialPage: _index);
    _loadHeaders();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _loadHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
    if (!mounted) return;
    setState(() {
      _headers = token.isEmpty ? {} : {'Authorization': 'Bearer $token'};
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _next() {
    if (_index >= widget.images.length - 1) return;
    _pageCtrl.animateToPage(
      _index + 1,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _prev() {
    if (_index <= 0) return;
    _pageCtrl.animateToPage(
      _index - 1,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _prev();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _save() {
    final cur = widget.images[_index];
    final ctl = ref.read(chatMediaDownloadControllerProvider);
    // ignore: discarded_futures
    ctl.start(
      url: cur.url,
      name: cur.fileName.startsWith('[') ? '图片.jpg' : cur.fileName,
      isImage: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.images[_index];
    final total = widget.images.length;
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    if (mobile) {
      return Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pageCtrl,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: total,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => _PreviewImageTile(
                key: ValueKey('$i:$_index'),
                url: widget.images[i].url,
                headers: _headers,
                mobile: true,
                hasMultipleImages: total > 1,
                onDismiss: () => Navigator.of(context).pop(),
                onNext: _index < total - 1 ? _next : null,
                onPrevious: _index > 0 ? _prev : null,
                onDownload: _save,
                heroTag:
                    i == widget.initialIndex && _index == widget.initialIndex
                        ? widget.heroTag
                        : null,
              ),
            ),
          ),
          Positioned(
              top: 0,
              left: 8,
              child: SafeArea(
                child: IconButton(
                  tooltip: '关闭',
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
                ),
              )),
          if (total > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: SafeArea(
                  top: false,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${_index + 1} / $total',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                height: 1.2,
                                fontWeight: FontWeight.w500,),
                      ),
                    ),
                  ),
                  ),
                ),
            ),
        ]),
      );
    }
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // 背景点击关闭。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: const SizedBox.expand(),
            ),
          ),
          // 图片切换 PageView。
          Positioned.fill(
            child: PageView.builder(
              controller: _pageCtrl,
              physics: mobile ? const NeverScrollableScrollPhysics() : null,
              itemCount: total,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final img = widget.images[i];
                return _PreviewImageTile(
                  key: mobile ? ValueKey('$i:$_index') : null,
                  url: img.url,
                  headers: _headers,
                  mobile: mobile,
                  hasMultipleImages: total > 1,
                  onDismiss: () => Navigator.of(context).pop(),
                  onNext: _index < total - 1 ? _next : null,
                  onPrevious: _index > 0 ? _prev : null,
                );
              },
            ),
          ),
          // 顶栏: 关闭 / 「i/N + 文件名」 / 保存。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(CupertinoIcons.xmark,
                          size: 20, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${_index + 1} / $total',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              cur.senderName.isNotEmpty
                                  ? '${cur.senderName} · ${cur.fileName}'
                                  : cur.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _save,
                      icon: const Icon(CupertinoIcons.cloud_download,
                          size: 18, color: Colors.white),
                      label: const Text('保存',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 左右浮按钮 (>=2 张图才显示)。
          if (total > 1) ...[
            Positioned(
              left: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: _NavButton(
                  icon: CupertinoIcons.chevron_left,
                  enabled: _index > 0,
                  onTap: _prev,
                ),
              ),
            ),
            Positioned(
              right: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: _NavButton(
                  icon: CupertinoIcons.chevron_right,
                  enabled: _index < total - 1,
                  onTap: _next,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewImageTile extends StatelessWidget {
  const _PreviewImageTile({
    super.key,
    required this.url,
    required this.headers,
    required this.mobile,
    required this.hasMultipleImages,
    required this.onDismiss,
    this.onNext,
    this.onPrevious,
    this.onDownload,
    this.heroTag,
  });
  final String url;
  final Map<String, String>? headers;
  final bool mobile;
  final bool hasMultipleImages;
  final VoidCallback onDismiss;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onDownload;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final resolved = resolveChatMediaUrlPublic(url);
    final image = headers == null
        ? const Center(child: CupertinoActivityIndicator(color: Colors.white))
        : UiNetworkImage(
            imageUrl: resolved,
            httpHeaders: headers,
            fit: BoxFit.contain,
            borderRadius: 0,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 48, color: Color(0xFF98A2B3)),
            ),
          );
    if (mobile) {
      return ChatPlatformWidgets.of(context).imageViewer(
        onDismiss: onDismiss,
        onDownload: onDownload,
        onNext: onNext,
        onPrevious: onPrevious,
        hasMultipleImages: hasMultipleImages,
        child: imagePreviewHero(tag: heroTag, child: image),
      );
    }
    return Center(
        child: InteractiveViewer(minScale: 0.5, maxScale: 4, child: image));
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.3,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
