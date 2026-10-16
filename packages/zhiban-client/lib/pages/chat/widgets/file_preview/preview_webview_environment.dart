import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Win32's default WebView2 cache sits beside the executable, which is not
/// writable after installation in Program Files. All preview panels share this
/// environment; its lifetime is the application lifetime.
class PreviewWebViewEnvironment {
  static const viewerAsset = 'assets/file_preview/viewer.html';
  static String? get viewerFileUrl => Platform.isWindows
      ? File('${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.pathSeparator}data/flutter_assets/$viewerAsset')
          .uri
          .toString()
      : null;

  static Future<WebViewEnvironment>? _windows;

  static Future<WebViewEnvironment?> load() async {
    if (!Platform.isWindows) return null;
    final pending = _windows ??= _create();
    try {
      return await pending;
    } catch (_) {
      if (identical(_windows, pending)) _windows = null;
      rethrow;
    }
  }

  static Future<WebViewEnvironment> _create() async {
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null || version.isEmpty) {
        throw StateError('文件预览需要 Microsoft Edge WebView2 Runtime，请安装后重试。');
      }
      final support = await getApplicationSupportDirectory();
      final cache = Directory(
          '${support.path}${Platform.pathSeparator}file-preview-webview2');
      await cache.create(recursive: true);
      return await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: cache.path));
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('无法初始化文件预览组件，请检查 WebView2 Runtime 后重试。');
    }
  }
}
