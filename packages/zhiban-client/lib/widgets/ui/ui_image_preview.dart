import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/services/device_media_actions.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/widgets/ui/chat_platform_widgets.dart';
import 'package:zhiban_ui/widgets/ui_image_hero.dart';

// 判断 url / 路径后缀是不是 svg。CachedNetworkImage / Image.file 都是 raster
// 解码器，遇到 svg 直接进 errorWidget（聊天大图预览里就是黑屏 + 灰图标）。
// 这里把 svg 路径单独走 flutter_svg 矢量渲染。
bool _isSvgPath(String s) {
  final stripped = s.split('?').first.split('#').first;
  return stripped.toLowerCase().endsWith('.svg');
}

const _kPreviewError = SizedBox(
  width: 120,
  height: 120,
  child: Center(
    child: Icon(CupertinoIcons.photo, size: 36, color: Color(0xFFB0B7C3)),
  ),
);

Widget _previewDialogImage({
  String? filePath,
  String? fileUrl,
  Map<String, String>? httpHeaders,
  String? cacheKey,
}) {
  final path = filePath?.trim();
  if (path != null && path.isNotEmpty) {
    try {
      if (File(path).existsSync()) {
        if (_isSvgPath(path)) {
          return SvgPicture.file(File(path), fit: BoxFit.contain);
        }
        return Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _kPreviewError,
        );
      }
    } catch (_) {}
  }
  final url = fileUrl?.trim();
  if (url != null && url.isNotEmpty) {
    if (_isSvgPath(url)) {
      return SvgPicture.network(url, fit: BoxFit.contain, headers: httpHeaders);
    }
    return UiNetworkImage(
      imageUrl: url,
      fit: BoxFit.contain,
      httpHeaders: httpHeaders,
      cacheKey: cacheKey ?? url,
      clip: false,
      errorBuilder: (_, __, ___) => _kPreviewError,
    );
  }
  return _kPreviewError;
}

class UiImagePreviewThumb extends StatelessWidget {
  const UiImagePreviewThumb({
    super.key,
    required this.width,
    required this.height,
    required this.borderRadius,
    this.filePath,
    this.fileUrl,
    this.httpHeaders,
    this.cacheKey,
    this.onTap,
    this.onPreview,
  });

  final double width;
  final double height;
  final double borderRadius;
  final String? filePath;
  final String? fileUrl;
  final Map<String, String>? httpHeaders;
  final String? cacheKey;
  final VoidCallback? onTap;
  final ValueChanged<Object>? onPreview;

  @override
  Widget build(BuildContext context) {
    return UiImageHero(
        builder: (context, heroTag) => GestureDetector(
              onTap: onPreview != null ? () => onPreview!(heroTag) : onTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(borderRadius),
                child: Container(
                  width: width,
                  height: height,
                  color: const Color(0xFFF1F2F4),
                  child: _buildImage(),
                ),
              ),
            ));
  }

  Widget _buildImage() {
    // 本机仍存在时优先本地图，避免上传完成后立刻切到网络图导致中间闪一下。
    final path = filePath?.trim();
    if (path != null && path.isNotEmpty) {
      try {
        if (File(path).existsSync()) {
          if (_isSvgPath(path)) {
            return SvgPicture.file(
              File(path),
              fit: BoxFit.cover,
              placeholderBuilder: (_) => const Icon(CupertinoIcons.photo),
            );
          }
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(CupertinoIcons.photo),
          );
        }
      } catch (_) {}
    }
    final url = fileUrl?.trim();
    if (url != null && url.isNotEmpty) {
      if (_isSvgPath(url)) {
        return SvgPicture.network(
          url,
          fit: BoxFit.cover,
          placeholderBuilder: (_) => const Icon(CupertinoIcons.photo),
        );
      }
      return UiNetworkImage(
        imageUrl: url,
        httpHeaders: httpHeaders,
        cacheKey: cacheKey,
        fit: BoxFit.cover,
        clip: false,
        placeholderBuilder: (_, __) => const Icon(CupertinoIcons.photo),
        errorBuilder: (_, __, ___) => const Icon(CupertinoIcons.photo),
      );
    }
    return const Icon(CupertinoIcons.photo);
  }
}

class UiImagePreviewDialog extends StatefulWidget {
  const UiImagePreviewDialog({
    super.key,
    this.filePath,
    this.fileUrl,
    this.httpHeaders,
    this.cacheKey,
    this.heroTag,
  });

  final String? filePath;
  final String? fileUrl;
  final Map<String, String>? httpHeaders;
  final String? cacheKey;
  final Object? heroTag;

  @override
  State<UiImagePreviewDialog> createState() => _UiImagePreviewDialogState();
}

class _UiImagePreviewDialogState extends State<UiImagePreviewDialog> {
  final _downloads = ChatMediaDownloadController();
  bool _savingLocal = false;

  @override
  void dispose() {
    _downloads.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    final path = widget.filePath?.trim() ?? '';
    if (path.isNotEmpty && File(path).existsSync()) {
      if (_savingLocal) return;
      _savingLocal = true;
      try {
        await requireDeviceMediaActions().saveImage(path);
        BotToast.showText(text: '已保存到相册');
      } catch (_) {
        BotToast.showText(text: '保存失败，请检查相册权限后重试');
      } finally {
        _savingLocal = false;
      }
      return;
    }
    final url = widget.fileUrl?.trim() ?? '';
    if (url.isEmpty) return;
    final segments = Uri.tryParse(url)?.pathSegments;
    final name =
        segments == null || segments.isEmpty ? '图片.jpg' : segments.last;
    await _downloads.start(url: url, name: name, isImage: true);
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.android) {
      return Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(children: [
          Positioned.fill(
            child: ChatPlatformWidgets.of(context).imageViewer(
              onDismiss: () => Navigator.of(context).pop(),
              onDownload: (widget.filePath?.isNotEmpty == true ||
                      widget.fileUrl?.isNotEmpty == true)
                  ? _download
                  : null,
              child: imagePreviewHero(
                  tag: widget.heroTag,
                  child: _previewDialogImage(
                    filePath: widget.filePath,
                    fileUrl: widget.fileUrl,
                    httpHeaders: widget.httpHeaders,
                    cacheKey: widget.cacheKey,
                  )),
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
            ),
          ),
        ]),
      );
    }
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: InteractiveViewer(
            maxScale: 4,
            child: _previewDialogImage(
              filePath: widget.filePath,
              fileUrl: widget.fileUrl,
              httpHeaders: widget.httpHeaders,
              cacheKey: widget.cacheKey,
            ),
          ),
        ),
      ),
    );
  }
}
