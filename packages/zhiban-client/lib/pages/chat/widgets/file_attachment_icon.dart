import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 与 zhirong-web [ICON_SIZES] / [FileAttachmentIcon] 一致的尺寸。
enum FileAttachmentIconSize {
  sm(16),
  md(24),
  lg(32),
  xl(46);

  const FileAttachmentIconSize(this.pixels);
  final double pixels;
}

/// 从文件名解析扩展名（与 zhirong-web [getFileExtension] 行为一致）。
String fileAttachmentExtension(String fileName) {
  if (fileName.isEmpty) return '';
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot == -1 || lastDot == fileName.length - 1) return '';
  return fileName.substring(lastDot + 1).toLowerCase().trim();
}

/// 扩展名 → 资源路径，与 zhirong-web [icon-mapping.ts] 中 [DEFAULT_FILE_TYPES] 一致。
///
/// assets/images/filesIcon/ 目前是 svg 图标集(2026-08-17 换的,原先是 png)。
/// 未覆盖的压缩包等类型先用 default.svg,不再掉到通用系统图标。
String? fileAttachmentIconAsset(String extension) {
  switch (extension) {
    case 'doc':
    case 'docx':
    case 'rtf':
      return 'assets/images/filesIcon/doc.svg';
    case 'pdf':
      return 'assets/images/filesIcon/pdf.svg';
    case 'txt':
    case 'md':
    case 'json':
    case 'xml':
    case 'yaml':
    case 'yml':
      return 'assets/images/filesIcon/txt.svg';
    case 'xls':
    case 'xlsx':
      return 'assets/images/filesIcon/xls.svg';
    case 'csv':
      return 'assets/images/filesIcon/csv.svg';
    case 'ppt':
    case 'pptx':
      return 'assets/images/filesIcon/ppt.svg';
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return 'assets/images/filesIcon/zip.svg';
    case 'png':
    case 'webp':
    case 'bmp':
    case 'heic':
    case 'heif':
      return 'assets/images/filesIcon/png.svg';
    case 'jpg':
    case 'jpeg':
      return 'assets/images/filesIcon/jpg.svg';
    case 'gif':
      return 'assets/images/filesIcon/gif.svg';
    case 'html':
    case 'htm':
      return 'assets/images/filesIcon/html.svg';
    case 'mp4':
    case 'mov':
    case 'avi':
    case 'mkv':
    case 'webm':
      return 'assets/images/filesIcon/video.svg';
    default:
      return null;
  }
}

/// 按扩展名展示 doc/pdf/txt/xls 图标，否则为通用文档图标（对齐 zhirong-web [FileAttachmentIcon]）。
class FileAttachmentIcon extends StatelessWidget {
  const FileAttachmentIcon({
    super.key,
    required this.fileName,
    this.size = FileAttachmentIconSize.md,
    this.fallbackIconColor,
    this.customDimension,
  });

  final String fileName;
  final FileAttachmentIconSize size;
  final Color? fallbackIconColor;

  /// 不在 [FileAttachmentIconSize] 几档里、单个调用点需要的一次性尺寸，
  /// 传了就覆盖 [size]，不动共享枚举(枚举跟 zhirong-web ICON_SIZES 对齐,
  /// 不为单个调用点改)。
  final double? customDimension;

  @override
  Widget build(BuildContext context) {
    final ext = fileAttachmentExtension(fileName);
    final dim = customDimension ?? size.pixels;

    // Pictures should be recognizable at small header/card sizes, without
    // the lettered document silhouette used by the legacy image assets.
    if (const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
      'avif',
      'ico',
      'svg',
      'tif',
      'tiff',
    }.contains(ext)) {
      return Icon(CupertinoIcons.photo_fill,
          size: dim, color: CupertinoTheme.of(context).primaryColor);
    }

    final asset = fileAttachmentIconAsset(ext);
    if (asset == null) {
      return _fallback(dim);
    }

    return SvgPicture.asset(
      package: ClientAssets.packageName,
      asset,
      width: dim,
      height: dim,
      fit: BoxFit.contain,
      placeholderBuilder: (_) => _fallback(dim),
    );
  }

  Widget _fallback(double dim) {
    // 未识别的扩展名统一走图标集自带的"综合文档"图标,不再落到系统空白文档符号。
    return SvgPicture.asset(
      package: ClientAssets.packageName,
      'assets/images/filesIcon/default.svg',
      width: dim,
      height: dim,
      fit: BoxFit.contain,
      placeholderBuilder: (_) => Icon(
        CupertinoIcons.doc,
        size: dim,
        color: fallbackIconColor ?? const Color(0xFF64748B),
      ),
    );
  }
}
