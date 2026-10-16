import 'package:file_selector/file_selector.dart' show XFile;

/// 移动入口安装能力；共享选图/下载不依赖原生插件实现。
class DeviceMediaActions {
  const DeviceMediaActions({
    required this.pickSingleImage,
    required this.pickImages,
    required this.takePhoto,
    required this.saveImage,
  });

  final Future<XFile?> Function() pickSingleImage;
  final Future<List<XFile>> Function() pickImages;
  final Future<XFile?> Function() takePhoto;
  final Future<void> Function(String path) saveImage;
}

DeviceMediaActions? deviceMediaActions;

DeviceMediaActions requireDeviceMediaActions() =>
    deviceMediaActions ?? (throw StateError('移动入口未安装 DeviceMediaActions'));
