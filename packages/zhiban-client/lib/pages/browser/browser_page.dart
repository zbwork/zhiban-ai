import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.title,
    required this.url
  });

  final String title;
  final Uri url;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late String _title;
  String? _currentUrl;
  bool _canGoForward = false;
  VoidCallback? _goForward;
  VoidCallback? _reload;
  VoidCallback? _handleBack;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _currentUrl = widget.url.toString();
  }

  Future<void> _copyLink() async {
    final url = _currentUrl ?? widget.url.toString();
    await Clipboard.setData(ClipboardData(text: url));
  }

  Future<void> _openInBrowser() async {
    final url = _currentUrl ?? widget.url.toString();
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: UiPageBar(
        title: _title,
        onBack: () { if (_handleBack != null) { _handleBack!(); } else { context.pop(); } },
        leadingWidth: 116,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 12),
            _BrowserIconButton(
              icon: CupertinoIcons.chevron_left,
              onPressed: () { if (_handleBack != null) { _handleBack!(); } else { context.pop(); } },
            ),
            const SizedBox(width: 4),
            _BrowserIconButton(
              icon: CupertinoIcons.chevron_right,
              onPressed: _canGoForward ? _goForward : null,
            ),
            const SizedBox(width: 4),
            _BrowserIconButton(
              icon: CupertinoIcons.arrow_clockwise,
              onPressed: _reload,
            ),
          ],
        ),
        actions: [
          UiDropdownMenu<String>(
            menuWidth: 168,
            offset: const Offset(0, 8),
            onSelected: (value) {
              if (value == 'copy') _copyLink();
              if (value == 'open') _openInBrowser();
            },
            items: const [
              UiDropdownMenuItem<String>(
                value: 'copy',
                label: '复制链接',
                icon: Icons.copy_rounded,
              ),
              UiDropdownMenuItem<String>(
                value: 'open',
                label: '从浏览器打开',
                icon: Icons.open_in_new_rounded,
              ),
            ],
            child: const SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                Icons.more_horiz_rounded,
                size: 22,
                color: Color(0xFF475467),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: BrowserTab(
          initialTitle: widget.title,
          initialUrl: widget.url,
          showHeader: false,
          onTitleChanged: (t) => setState(() => _title = t),
          onIconChanged: (_) {},
          onIconUrlChanged: (_) {},
          onUrlChanged: (url) => _currentUrl = url,
          onClose: () => context.pop(),
          onNavigationChanged: (canGoBack, canGoForward) {
            if (mounted) setState(() => _canGoForward = canGoForward);
          },
          onControlsReady: (goForward, reload, handleBack) {
            _goForward = goForward;
            _reload = reload;
            _handleBack = handleBack;
          },
        ),
      ),
    );
  }
}

class BrowserTab extends StatefulWidget {
  const BrowserTab({
    super.key,
    required this.initialTitle,
    required this.initialUrl,
    required this.onTitleChanged,
    required this.onIconChanged,
    required this.onIconUrlChanged,
    this.onClose,
    this.onUrlChanged,
    this.showHeader = true,
    this.onNavigationChanged,
    this.onControlsReady,
  });

  final String initialTitle;
  final Uri initialUrl;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<Uint8List?> onIconChanged;
  final ValueChanged<String?> onIconUrlChanged;
  final VoidCallback? onClose;
  final ValueChanged<String>? onUrlChanged;
  final bool showHeader;
  final void Function(bool canGoBack, bool canGoForward)? onNavigationChanged;
  final void Function(VoidCallback goForward, VoidCallback reload, VoidCallback handleBack)? onControlsReady;

  @override
  State<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends State<BrowserTab> {
  static const _mobileUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  InAppWebViewController? _controller;
  String _title = '';
  String? _currentUrl;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _loading = true;
  String? _errorMessage;
  // tracks whether the current main-frame navigation resulted in an error,
  // so onLoadStop doesn't clear error state that was just set.
  bool _mainFrameError = false;

  @override
  void initState() {
    super.initState();
    _title = widget.initialTitle;
    _currentUrl = widget.initialUrl.toString();
    widget.onControlsReady?.call(_goForward, _reload, _handleBackPressed);
  }

  Future<void> _syncNavigationState() async {
    final controller = _controller;
    if (controller == null) return;
    final canGoBack = await controller.canGoBack();
    final canGoForward = await controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
    widget.onNavigationChanged?.call(canGoBack, canGoForward);
  }

  Future<void> _handleBackPressed() async {
    final controller = _controller;
    if (controller != null) {
      final canGoBack = await controller.canGoBack();
      if (!mounted) return;
      if (canGoBack) {
        // 返回按钮每次实时查询 WebView 历史,避免本地 _canGoBack 状态滞后导致到头后无法退出路由。
        await controller.goBack();
        await _syncNavigationState();
        return;
      }
      if (_canGoBack) setState(() => _canGoBack = false);
    }
    widget.onClose?.call();
  }

  Future<void> _goForward() async {
    final controller = _controller;
    if (controller == null || !_canGoForward) return;
    await controller.goForward();
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _errorMessage = null;
      _mainFrameError = false;
      _loading = true;
    });
    await controller.reload();
  }

  Future<void> _copyCurrentLink() async {
    final url = _currentUrl ?? widget.initialUrl.toString();
    await Clipboard.setData(ClipboardData(text: url));
  }

  Future<void> _openInBrowser() async {
    final url = _currentUrl ?? widget.initialUrl.toString();
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _handleTitleChanged(String? title) {
    final nextTitle = (title == null || title.trim().isEmpty)
        ? widget.initialTitle
        : title.trim();
    if (_title == nextTitle) return;
    setState(() => _title = nextTitle);
    widget.onTitleChanged(nextTitle);
  }

  void _handleIconChanged(Uint8List? iconBytes) {
    widget.onIconChanged(iconBytes);
  }

  Future<void> _syncFaviconUrl() async {
    final controller = _controller;
    if (controller == null) return;
    final favicons = await controller.getFavicons();
    if (!mounted) return;
    if (favicons.isEmpty) {
      widget.onIconUrlChanged(null);
      return;
    }
    widget.onIconUrlChanged(favicons.first.url.toString());
  }

  Future<void> _ensureMobileViewport(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: '''
      (function () {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
      })();
    ''');
  }

  String _friendlyError(WebResourceError error) {
    final t = error.type;
    if (t == WebResourceErrorType.HOST_LOOKUP) {
      return '无法找到服务器，请检查网络或地址是否正确';
    }
    if (t == WebResourceErrorType.CANNOT_CONNECT_TO_HOST) {
      return '无法连接到服务器';
    }
    if (t == WebResourceErrorType.TIMEOUT) {
      return '连接超时，请稍后重试';
    }
    if (t == WebResourceErrorType.FAILED_SSL_HANDSHAKE ||
        t == WebResourceErrorType.SECURE_CONNECTION_FAILED) {
      return '安全连接失败';
    }
    if (t == WebResourceErrorType.NOT_CONNECTED_TO_INTERNET ||
        t == WebResourceErrorType.NETWORK_CONNECTION_LOST) {
      return '网络连接不可用，请检查网络设置';
    }
    return '页面加载失败';
  }

  @override
  Widget build(BuildContext context) {
    final inner = Column(
      children: [
        if (widget.showHeader) Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: ColorConfig.pageBackground,
              border: Border(
                bottom: BorderSide(color: Color(0xFFE1E9F8), width: 1),
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _BrowserIconButton(
                        icon: CupertinoIcons.chevron_left,
                        onPressed: _handleBackPressed,
                      ),
                      const SizedBox(width: 8),
                      _BrowserIconButton(
                        icon: CupertinoIcons.chevron_right,
                        onPressed: _canGoForward ? _goForward : null,
                      ),
                      const SizedBox(width: 8),
                      _BrowserIconButton(
                        icon: CupertinoIcons.arrow_clockwise,
                        onPressed: _reload,
                      ),
                    ],
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF162033),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  child: UiDropdownMenu<String>(
                    menuWidth: 168,
                    offset: const Offset(0, 8),
                    onSelected: (value) {
                      switch (value) {
                        case 'copy':
                          _copyCurrentLink();
                          break;
                        case 'open':
                          _openInBrowser();
                          break;
                      }
                    },
                    items: const [
                      UiDropdownMenuItem<String>(
                        value: 'copy',
                        label: '复制链接',
                        icon: Icons.copy_rounded,
                      ),
                      UiDropdownMenuItem<String>(
                        value: 'open',
                        label: '从浏览器打开',
                        icon: Icons.open_in_new_rounded,
                      ),
                    ],
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 22,
                        color: Color(0xFF475467),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  color: ColorConfig.pageBackground,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final webWidth = constraints.maxWidth < 430
                          ? constraints.maxWidth
                          : 430.0;
                      return Center(
                        child: SizedBox(
                          width: webWidth,
                          height: constraints.maxHeight,
                          child: InAppWebView(
                            initialUrlRequest: URLRequest(
                              url: WebUri(widget.initialUrl.toString()),
                            ),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              javaScriptCanOpenWindowsAutomatically: false,
                              supportMultipleWindows: false,
                              transparentBackground: false,
                              useWideViewPort: true,
                              loadWithOverviewMode: true,
                              enableViewportScale: true,
                              preferredContentMode:
                                  UserPreferredContentMode.MOBILE,
                              userAgent: _mobileUserAgent,
                            ),
                            onWebViewCreated: (controller) {
                              _controller = controller;
                              _syncNavigationState();
                              _syncFaviconUrl();
                            },
                            onLoadStart: (controller, url) {
                              if (!mounted) return;
                              _mainFrameError = false;
                              setState(() {
                                _loading = true;
                                _errorMessage = null;
                              });
                              if (url != null) {
                                _currentUrl = url.toString();
                                widget.onUrlChanged?.call(_currentUrl!);
                              }
                              _syncNavigationState();
                            },
                            onLoadStop: (controller, url) async {
                              if (!mounted) return;
                              if (url != null) {
                                _currentUrl = url.toString();
                                widget.onUrlChanged?.call(_currentUrl!);
                              }
                              if (_mainFrameError) return;
                              await _ensureMobileViewport(controller);
                              _syncNavigationState();
                              await _syncFaviconUrl();
                              if (mounted) setState(() => _loading = false);
                            },
                            onTitleChanged: (controller, title) {
                              _handleTitleChanged(title);
                            },
                            onReceivedIcon: (controller, icon) {
                              _handleIconChanged(icon);
                            },
                            onUpdateVisitedHistory:
                                (controller, url, androidIsReload) {
                              if (url != null) _currentUrl = url.toString();
                              _syncNavigationState();
                            },
                            onReceivedError: (controller, request, error) {
                              if (request.isForMainFrame != true) return;
                              if (error.type ==
                                  WebResourceErrorType.CANCELLED) {
                                return;
                              }
                              _mainFrameError = true;
                              if (!mounted) return;
                              setState(() {
                                _loading = false;
                                _errorMessage = _friendlyError(error);
                              });
                            },
                            onReceivedHttpError:
                                (controller, request, errorResponse) {
                              if (request.isForMainFrame != true) return;
                              if (!mounted) return;
                              setState(() {
                                _loading = false;
                                _errorMessage =
                                    '页面加载失败（HTTP ${errorResponse.statusCode}）';
                              });
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_loading)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Color(0x1AFFFFFF),
                        child: Center(
                          child: CupertinoActivityIndicator(radius: 8),
                        ),
                      ),
                    ),
                  ),
                if (_errorMessage != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Color(0xFFF5F7FB),
                      child: Center(
                        child: Container(
                          width: 260,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                CupertinoIcons.exclamationmark_triangle_fill,
                                color: Color(0xFFD92D20),
                                size: 28,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: Color(0xFF344054),
                                ),
                              ),
                              const SizedBox(height: 14),
                              FilledButton.tonal(
                                onPressed: _reload,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    if (!widget.showHeader) return inner;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPressed();
      },
      child: inner,
    );
  }
}

class _BrowserIconButton extends StatelessWidget {
  const _BrowserIconButton({
    required this.icon,
    required this.onPressed
  });

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled ? const Color(0xFFF6F8FB) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? const Color(0xFF344054) : const Color(0xFFB3B9C6),
          ),
        ),
      ),
    );
  }
}
