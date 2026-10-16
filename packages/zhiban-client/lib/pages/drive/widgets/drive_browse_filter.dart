import 'package:flutter/material.dart';
import 'package:zhiban_core/drive/drive_models.dart';

enum DriveFileType {
  all('全部'),
  image('图片'),
  video('视频'),
  document('文档'),
  audio('音频');

  const DriveFileType(this.label);
  final String label;
}

/// 路由局部的浏览条件，不修改目录缓存或其他页面的 selection。
class DriveBrowseFilter extends InheritedWidget {
  const DriveBrowseFilter({
    super.key,
    required this.query,
    required this.type,
    this.controls,
    required super.child,
    this.breadcrumbs,
  });

  /// 页内路径作为工具栏左侧内容，由目录列表与原有操作共同布局。
  final Widget? breadcrumbs;
  final String query;
  final DriveFileType type;
  final Widget? controls;

  static DriveBrowseFilter? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DriveBrowseFilter>();

  bool matchesName(String name) =>
      name.toLowerCase().contains(query.trim().toLowerCase());

  bool matchesFolder(String name) =>
      type == DriveFileType.all && matchesName(name);

  bool matchesFile(DriveFile file) {
    if (!matchesName(file.name)) return false;
    final mime = file.mimeType.toLowerCase();
    final ext = file.name.toLowerCase().split('.').last;
    final image = mime.startsWith('image/') ||
        const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'svg', 'bmp'}
            .contains(ext);
    final video = mime.startsWith('video/') ||
        const {'mp4', 'mov', 'mkv', 'avi', 'webm'}.contains(ext);
    final audio = mime.startsWith('audio/') ||
        const {'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'}.contains(ext);
    return switch (type) {
      DriveFileType.all => true,
      DriveFileType.image => image,
      DriveFileType.video => video,
      DriveFileType.audio => audio,
      DriveFileType.document => mime.startsWith('text/') ||
          const {
            'application/pdf',
            'application/msword',
            'application/rtf',
            'application/vnd.ms-excel',
            'application/vnd.ms-powerpoint'
          }.contains(mime) ||
          mime.startsWith('application/vnd.openxmlformats-officedocument.') ||
          mime.startsWith('application/vnd.oasis.opendocument.') ||
          const {
            'pdf',
            'doc',
            'docx',
            'xls',
            'xlsx',
            'ppt',
            'pptx',
            'txt',
            'md',
            'csv',
            'rtf',
            'odt',
            'ods',
            'odp'
          }.contains(ext),
    };
  }

  @override
  bool updateShouldNotify(DriveBrowseFilter oldWidget) =>
      query != oldWidget.query ||
      type != oldWidget.type ||
      breadcrumbs != oldWidget.breadcrumbs ||
      controls != oldWidget.controls;
}
