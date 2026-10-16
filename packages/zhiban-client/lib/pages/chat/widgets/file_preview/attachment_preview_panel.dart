import 'package:zhiban_client/config/client_assets.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'attachment_preview_header.dart';
import 'package:url_launcher/url_launcher.dart';
import 'attachment_preview_loader.dart';
import 'attachment_preview_target.dart';
import 'chat_artifact_download.dart';
import 'preview_webview_environment.dart';

class AttachmentPreviewPanel extends StatefulWidget {
  const AttachmentPreviewPanel(
      {super.key,
      required this.target,
      required this.onClose,
      this.onExpand,
      this.expanded = false,
      this.mobile = false,
      this.frameBuilder});
  final AttachmentPreviewTarget target;
  final VoidCallback onClose;
  final VoidCallback? onExpand;
  final bool expanded, mobile;
  final Widget Function(Widget body, int? byteLength, bool saving,
      VoidCallback reload, VoidCallback save)? frameBuilder;
  @override
  State<AttachmentPreviewPanel> createState() => _AttachmentPreviewPanelState();
}

class _AttachmentPreviewPanelState extends State<AttachmentPreviewPanel> {
  AttachmentPreviewLoader? _loader;
  WebViewEnvironment? _webViewEnvironment;
  String? _html, _payload, _error;
  int _generation = 0;
  int? _byteLength;
  Brightness? _brightness;
  bool _rendering = true;
  bool _dispatched = false;
  static Future<String>? _shell;
  Timer? _loadDeadline;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness != null && _brightness != brightness) _load();
    _brightness = brightness;
  }

  @override
  void didUpdateWidget(AttachmentPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) _load();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload must also refresh the generated viewer used by native QA.
    _shell = null;
    rootBundle.evict('assets/file_preview/viewer.html');
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _loadDeadline?.cancel();
    _loader?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _loadDeadline?.cancel();
    _loadDeadline = Timer(const Duration(minutes: 2), () {
      if (!mounted || generation != _generation) return;
      _generation++;
      _loader?.dispose();
      setState(() {
        _error = '预览加载超时，请重试或下载查看';
        _rendering = false;
      });
    });
    _loader?.dispose();
    final loader = AttachmentPreviewLoader();
    _loader = loader;
    setState(() {
      _byteLength = null;
      _html = null;
      _payload = null;
      _error = null;
      _rendering = true;
      _dispatched = false;
    });
    final format = attachmentPreviewFormat(
        widget.target.name, widget.target.url, widget.target.mime);
    if (format == 'unsupported') {
      _loadDeadline?.cancel();
      setState(() {
        _error = '暂不支持此格式的在线预览，请下载或在外部应用中打开。';
        _rendering = false;
      });
      return;
    }
    try {
      final environment = await PreviewWebViewEnvironment.load();
      if (!mounted || generation != _generation) return;
      final bytes = await loader.read(widget.target, format);
      if (!mounted || generation != _generation) return;
      AttachmentPreviewRefresh.instance.validatedRead(widget.target.url);
      final shell = await (_shell ??=
          rootBundle.loadString(ClientAssets.path('assets/file_preview/viewer.html'),
      ));
      if (!mounted || generation != _generation) return;
      setState(() {
        _webViewEnvironment = environment;
        _byteLength = bytes.length;
        _html = shell;
        _payload = jsonEncode({
          'base64': base64Encode(bytes),
          'format': format,
          'name': widget.target.name,
          'mime': widget.target.mime,
          'dark': Theme.of(context).brightness == Brightness.dark,
          'mobile': widget.mobile,
          'palette': _palette(Theme.of(context).colorScheme),
        });
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        _loadDeadline?.cancel();
        setState(() {
          _error = error is StateError
              ? error.message.toString()
              : error is FormatException
                  ? error.message
                  : '无法预览：文件不可访问或下载失败。请重试，或在外部打开。';
          _rendering = false;
        });
      }
    }
  }

  Map<String, String> _palette(ColorScheme colors) {
    String css(Color color) =>
        '#${color.toARGB32().toRadixString(16).substring(2)}';
    return {
      'paper': css(colors.surface),
      'bg': css(colors.surfaceContainerLow),
      'fg': css(colors.onSurface),
      'muted': css(colors.onSurfaceVariant),
      'line': css(colors.outlineVariant),
      'primary': css(colors.primary),
      'active': css(colors.primaryContainer),
    };
  }

  bool _saving = false;
  Future<void> _download({bool external = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await downloadChatArtifact(context, widget.target,
          openAfterSave: external);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('无法下载或打开文件，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final generation = _generation;
    final body = Column(children: [
      if (!widget.mobile)
        AttachmentPreviewHeader(
          target: widget.target,
          byteLength: _byteLength,
          onReload: _load,
          onDownload: _download,
          onClose: widget.onClose,
          onExpand: widget.onExpand,
          expanded: widget.expanded,
          trailingInset: AppConfig.env == AppEnv.prod ? 0 : 64,
        ),
      Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.doc_text_search,
                            size: 36, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 16),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        Wrap(spacing: 12, children: [
                          OutlinedButton(
                              onPressed: _load, child: const Text('重试')),
                          FilledButton(
                              onPressed: () => _download(external: true),
                              child: const Text('外部打开'))
                        ])
                      ])))
              : Stack(children: [
                  if (_html != null)
                    Positioned.fill(
                        child: InAppWebView(
                      webViewEnvironment: _webViewEnvironment,
                      key: ValueKey(generation),
                      onWebViewCreated: (controller) {
                        controller.addJavaScriptHandler(
                            handlerName: 'openPreviewLink',
                            callback: (args) async {
                              if (!mounted ||
                                  generation != _generation ||
                                  args.length != 1 ||
                                  args.first is! String) {
                                return false;
                              }
                              final url = args.first as String;
                              if (!isAllowedPreviewLink(url)) return false;
                              try {
                                final uri = tryParsePreviewUri(url);
                                if (uri == null) return false;
                                return await launchUrl(uri,
                                    mode: LaunchMode.externalApplication);
                              } catch (_) {
                                return false;
                              }
                            });
                      },
                      // WebView2 Navigate requires a URI; the Windows plugin's
                      // loadFile passes an unencoded native path instead.
                      initialUrlRequest:
                          PreviewWebViewEnvironment.viewerFileUrl != null
                              ? URLRequest(
                                  url: WebUri(
                                      PreviewWebViewEnvironment.viewerFileUrl!))
                              : null,
                      initialData: PreviewWebViewEnvironment.viewerFileUrl !=
                              null
                          ? null
                          : InAppWebViewInitialData(
                              data: _html!,
                              baseUrl:
                                  WebUri('https://preview.zhiban.invalid/')),
                      initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          transparentBackground: true,
                          useShouldOverrideUrlLoading: true,
                          javaScriptCanOpenWindowsAutomatically: false,
                          supportMultipleWindows: false,
                          allowFileAccessFromFileURLs: false,
                          allowUniversalAccessFromFileURLs: false),
                      shouldOverrideUrlLoading: (_, action) async =>
                          isAllowedPreviewNavigation(
                                  action.request.url?.toString() ?? '',
                                  viewerFileUrl:
                                      PreviewWebViewEnvironment.viewerFileUrl,
                                  isMainFrame: action.isForMainFrame != false)
                              ? NavigationActionPolicy.ALLOW
                              : NavigationActionPolicy.CANCEL,
                      onLoadStop: (controller, _) async {
                        if (!mounted ||
                            generation != _generation ||
                            _dispatched ||
                            _payload == null) {
                          return;
                        }
                        try {
                          _dispatched = true;
                          final result = await controller.callAsyncJavaScript(
                              functionBody:
                                  'return await window.previewFile(payload);',
                              arguments: {
                                'payload': jsonDecode(_payload!)
                              }).timeout(const Duration(seconds: 90));
                          if (result == null ||
                              result.error != null ||
                              result.value != 'ready') {
                            throw StateError('Preview script failed');
                          }
                          if (mounted && generation == _generation) {
                            _loadDeadline?.cancel();
                            debugPrint(
                                '[FilePreview] rendered format=${attachmentPreviewFormat(widget.target.name, widget.target.url, widget.target.mime)}');
                            setState(() => _rendering = false);
                          }
                        } catch (_) {
                          if (mounted && generation == _generation) {
                            _loadDeadline?.cancel();
                            setState(() {
                              _error = '文件渲染失败，请重试或下载查看';
                              _rendering = false;
                            });
                          }
                        }
                      },
                      onReceivedError: (_, req, error) {
                        if (req.isForMainFrame == true &&
                            mounted &&
                            generation == _generation) {
                          _loadDeadline?.cancel();
                          setState(() {
                            _error = '预览组件加载失败';
                            _rendering = false;
                          });
                        }
                      },
                    )),
                  if (_rendering)
                    Positioned.fill(
                        child: ColoredBox(
                            color: scheme.surface,
                            child: const Center(
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                  CupertinoActivityIndicator(),
                                  SizedBox(height: 12),
                                  Text('正在加载预览…')
                                ])))),
                ])),
    ]);
    final frameBuilder = widget.frameBuilder;
    if (frameBuilder != null) {
      return frameBuilder(body, _byteLength, _saving, _load, _download);
    }
    return Material(color: scheme.surface, child: body);
  }
}
