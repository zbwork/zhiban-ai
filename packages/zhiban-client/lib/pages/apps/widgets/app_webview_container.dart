import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:zhiban_client/pages/apps/models/app_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

/// 桌面端「应用广场」点应用后打开的原生弹框（普通居中弹框，不是全屏/不是路由）。
/// 复用跟其它候选选择类弹框一致的 UiPickerDialog + UiSheetHeader 外壳。
Future<void> showAppWebViewDialog(
  BuildContext context, {
  required String launchUrl,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (ctx) => UiPickerDialog(
      size: UiDialogSize.wide,
      maxHeight: 720,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 4),
            child: UiSheetHeader(
              title: title.isEmpty ? '应用' : title,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 640,
            child: AppWebView(launchUrl: launchUrl)
          ),
        ],
      ),
    ),
  );
}

/// 打开应用 WebView; 按 displayMode 选容器形态。
///
/// - sidePanel    : 桌面端右侧抽屉 (Drawer-like); 移动端底部 modalBottomSheet 占 80% 高
/// - fullscreen   : Navigator.push 全屏页 + 顶部"返回"
/// - externalBrowser : url_launcher 系统浏览器 (v0.2 启用; v0.1 fallback 到 fullscreen)
Future<void> openAppWebView(
  BuildContext context, {
  required String launchUrl,
  required AppDisplayMode displayMode,
  String title = '',
  VoidCallback? onPresented,
}) async {
  switch (displayMode) {
    case AppDisplayMode.externalBrowser:
      final uri = Uri.parse(launchUrl);
      if (await url_launcher.canLaunchUrl(uri)) {
        final launched = await url_launcher.launchUrl(uri,
            mode: url_launcher.LaunchMode.externalApplication);
        if (launched) onPresented?.call();
      } else {
        if (!context.mounted) return;
        await _openFullscreen(
          context,
          launchUrl: launchUrl,
          title: title,
          onPresented: onPresented,
        );
      }
      break;
    case AppDisplayMode.fullscreen:
      await _openFullscreen(
        context,
        launchUrl: launchUrl,
        title: title,
        onPresented: onPresented,
      );
      break;
    case AppDisplayMode.sidePanel:
      final isDesktop = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.linux);
      if (isDesktop) {
        await _openDesktopSidePanel(context,
            launchUrl: launchUrl, title: title, onPresented: onPresented);
      } else {
        await _openMobileBottomSheet(context,
            launchUrl: launchUrl, title: title, onPresented: onPresented);
      }
      break;
  }
}

// =====================================================
// fullscreen
// =====================================================

Future<void> _openFullscreen(
  BuildContext context, {
  required String launchUrl,
  required String title,
  VoidCallback? onPresented,
}) async {
  final closed = Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (ctx) => _FullscreenAppPage(launchUrl: launchUrl, title: title),
    ),
  );
  onPresented?.call();
  await closed;
}

class _FullscreenAppPage extends StatelessWidget {
  const _FullscreenAppPage({required this.launchUrl, required this.title});

  final String launchUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title.isEmpty ? '应用' : title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回对话',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: AppWebView(launchUrl: launchUrl),
    );
  }
}

// =====================================================
// mobile bottom sheet (sidePanel @ mobile)
// =====================================================

Future<void> _openMobileBottomSheet(
  BuildContext context, {
  required String launchUrl,
  required String title,
  VoidCallback? onPresented,
}) async {
  final closed = showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      return SizedBox(
        height: mq.size.height * 0.85,
        child: Column(
          children: [
            _SheetHeader(
              title: title,
              onClose: () => Navigator.of(ctx).maybePop(),
            ),
            Expanded(child: AppWebView(launchUrl: launchUrl)),
          ],
        ),
      );
    },
  );
  onPresented?.call();
  await closed;
}

// =====================================================
// desktop side panel (sidePanel @ desktop)
// =====================================================

Future<void> _openDesktopSidePanel(
  BuildContext context, {
  required String launchUrl,
  required String title,
  VoidCallback? onPresented,
}) async {
  final closed = showGeneralDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    barrierLabel: '关闭',
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, __) {
      final media = MediaQuery.of(ctx);
      final w = (media.size.width * 0.4).clamp(360.0, 560.0);
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          child: SizedBox(
            width: w,
            height: media.size.height,
            child: Column(
              children: [
                _SheetHeader(
                  title: title,
                  onClose: () => Navigator.of(ctx).maybePop(),
                ),
                Expanded(child: AppWebView(launchUrl: launchUrl)),
              ],
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
  onPresented?.call();
  await closed;
}

// =====================================================
// 共用 widgets
// =====================================================

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.onClose});
  final String title;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.isEmpty ? '应用' : title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: '关闭',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class AppWebView extends StatefulWidget {
  const AppWebView({super.key, required this.launchUrl});
  final String launchUrl;

  @override
  State<AppWebView> createState() => AppWebViewState();
}

class AppWebViewState extends State<AppWebView> {
  double _progress = 0;

  Future<void> _ensureEmbeddedViewport(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(source: '''
      (function () {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        meta.content = 'width=device-width, initial-scale=1.0';
      })();
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRect(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.launchUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              useShouldOverrideUrlLoading: false,
              transparentBackground: true,
              useWideViewPort: true,
              loadWithOverviewMode: true,
              enableViewportScale: true,
              preferredContentMode: UserPreferredContentMode.MOBILE,
              // F04 §5.3 安全策略: v0.1 不暴露 native JS Bridge, 应用走标准 HTTPS API
              // 跟 Bus 通信; 关闭跨域 file 访问等高风险能力。
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
            ),
            onProgressChanged: (controller, progress) {
              setState(() => _progress = progress / 100.0);
            },
            onLoadStop: (controller, _) async {
              await _ensureEmbeddedViewport(controller);
            },
          ),
        ),
        if (_progress < 1)
          LinearProgressIndicator(value: _progress, minHeight: 2),
      ],
    );
  }
}
