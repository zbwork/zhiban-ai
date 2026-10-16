import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 云盘文件图标，三级优先级：
/// 1. 图片类型 + 传了 [fileUuid] → 实际缩略图（异步 presigned URL）
/// 2. 有对应 asset 图标 → fileAttachmentIconAsset
/// 3. 兜底 → assets/images/filesIcon/default.svg
class DriveFileIcon extends ConsumerStatefulWidget {
  const DriveFileIcon({
    super.key,
    required this.mimeType,
    required this.name,
    this.fileUuid,
    this.size = 36,
  });

  final String mimeType;
  final String name;

  /// 传入时才会尝试加载图片缩略图（图片类型才生效）。
  final String? fileUuid;
  final double size;

  @override
  ConsumerState<DriveFileIcon> createState() => _DriveFileIconState();
}

class _DriveFileIconState extends ConsumerState<DriveFileIcon> {
  String? _url;

  bool get _isImage {
    if (widget.mimeType.startsWith('image/')) return true;
    switch (fileAttachmentExtension(widget.name)) {
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
      case 'heic':
      case 'heif':
        return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _tryFetchPreviewUrl();
  }

  @override
  void didUpdateWidget(covariant DriveFileIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final uuidChanged = oldWidget.fileUuid != widget.fileUuid;
    final mimeChanged = oldWidget.mimeType != widget.mimeType;
    final nameChanged = oldWidget.name != widget.name;
    if (!uuidChanged && !mimeChanged && !nameChanged) return;
    // 列表复用时，文件可能切换成另一条记录，先清空旧缩略图再按新入参请求。
    _url = null;
    _tryFetchPreviewUrl();
  }

  void _tryFetchPreviewUrl() {
    if (_isImage && widget.fileUuid != null && widget.fileUuid!.isNotEmpty) {
      _fetchUrl();
    }
  }

  Future<void> _fetchUrl() async {
    try {
      final result = await ref
          .read(driveServiceProvider)
          .previewUrl(fileUuid: widget.fileUuid!);
      if (!mounted) return;
      setState(() => _url = result.url);
    } catch (_) {
      // silent — placeholder remains
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = widget.size;

    // 1. 图片 + 有 uuid → 缩略图
    if (_isImage && widget.fileUuid != null) {
      if (_url != null) {
        return UiNetworkImage(
          imageUrl: _url!,
          width: dim,
          height: dim,
          borderRadius: 6,
          cacheKey: widget.fileUuid,
        );
      }
      // loading 或 error 都用预留块（error 时不再重试，保持静默）
      return Container(
        width: dim,
        height: dim,
        decoration: BoxDecoration(
          color: const Color(0xFFEEF2F7),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }

    // 图片文件但没有可预览 uuid 时，至少展示图片语义图标，不再落到文档默认图标。
    if (_isImage) {
      return Container(
        width: dim,
        height: dim,
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(
          CupertinoIcons.photo,
          color: Color(0xFF2F7EF7),
          size: 20,
        ),
      );
    }

    // 2. 有 asset 类型图标
    final ext = fileAttachmentExtension(widget.name);
    final asset = fileAttachmentIconAsset(ext);
    if (asset != null) {
      return SizedBox(
        width: dim,
        height: dim,
        child: SvgPicture.asset(package: ClientAssets.packageName,
          asset, fit: BoxFit.contain),
      );
    }

    // 3. 兜底
    return SizedBox(
      width: dim,
      height: dim,
      child: SvgPicture.asset(
        package: ClientAssets.packageName,
        'assets/images/filesIcon/default.svg',
        fit: BoxFit.contain,
      ),
    );
  }
}
