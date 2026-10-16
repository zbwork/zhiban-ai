import 'dart:io' show File;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/github.dart' as highlight_github;
import 'package:flutter_highlighter/themes/vs2015.dart' as highlight_vs2015;
import 'package:flutter_smooth_markdown/flutter_smooth_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/widgets/copy_widget.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

// 把 markdown 链接 / 图片当作"可下载文件"识别用的扩展名清单。
// 命中 → 链接渲染成文件卡片（[文件名](url)），点击触发下载/系统打开；
//      → 图片语法（![](url)）也会回退成卡片，不再当成图片去 raster 解码。
// 与 OpenClaw 已有 FileAttachmentIcon / fileAttachmentIconAsset 共用。
const Set<String> _kDocFileExtensions = <String>{
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'csv',
  'ppt',
  'pptx',
  'txt',
  'md',
  'rtf',
  // html/htm: agent 生成 minesweeper.html 这类页面时,_MarkdownFileChip 出卡片;
  // _MarkdownFileChip._open 看到 html/htm 走 InAppWebView 内嵌预览弹框,
  // 不再走系统浏览器(macOS 对 /app/openclaw-drive/... 相对路径会报 -50)。
  'html',
  'htm',
  'zip',
  'rar',
  '7z',
  'tar',
  'gz',
  'json',
  'xml',
  'yaml',
  'yml',
  'mp3',
  'wav',
  'm4a',
  'ogg',
  'mp4',
  'mov',
  'avi',
  'mkv',
  'webm',
};

// 提取 url 路径里的扩展名，统一小写，去掉 query/hash。
String _extOfUrl(String url) {
  final cleaned = _cleanMarkdownUrlToken(url);
  if (cleaned.isEmpty) return '';
  final s = cleaned.split('?').first.split('#').first;
  final dot = s.lastIndexOf('.');
  final slash = s.lastIndexOf('/');
  if (dot <= slash) return '';
  return _cleanMarkdownFileLabel(s.substring(dot + 1)).toLowerCase();
}

bool _isSvgUrl(String url) => _extOfUrl(url) == 'svg';

bool _isDocUrl(String url) => _kDocFileExtensions.contains(_extOfUrl(url));

// 从 url 路径反推一个友好的文件名（最后一段），找不到就用 alt/fallback。
String _fileNameFromUrl(String url, {String? fallback}) {
  final cleaned = _cleanMarkdownUrlToken(url);
  if (cleaned.isNotEmpty) {
    final s = cleaned.split('?').first.split('#').first;
    final slash = s.lastIndexOf('/');
    if (slash >= 0 && slash < s.length - 1) {
      final tail = s.substring(slash + 1);
      if (tail.isNotEmpty) {
        return _cleanMarkdownFileLabel(safeDecodeComponent(tail));
      }
    }
  }
  return (fallback != null && fallback.trim().isNotEmpty)
      ? _cleanMarkdownFileLabel(fallback)
      : '未知文件';
}

String _cleanMarkdownUrlToken(String value) {
  var s = value.trim();
  while (s.startsWith('<')) {
    s = s.substring(1).trimLeft();
  }
  while (s.endsWith('>')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}

String _cleanMarkdownFileLabel(String value) {
  var s = value.trim();
  while (s.startsWith('<')) {
    s = s.substring(1).trimLeft();
  }
  while (s.endsWith('>')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}

class ChatMarkdownWidget extends StatelessWidget {
  const ChatMarkdownWidget({
    super.key,
    required this.content,
    this.linkTapBehavior = ChatMarkdownLinkTapBehavior.confirm,
    this.brightness,
    this.compact = false,
    this.selectable = true,
  });

  final String content;
  final ChatMarkdownLinkTapBehavior linkTapBehavior;
  final Brightness? brightness;
  // 紧凑模式：标题/正文字号统一收敛，间距更小，用于侧边面板、详情弹框等
  // 非主聊天区的 markdown 渲染，避免 h1/h2 视觉过重。
  final bool compact;

  /// 是否自建一层 [SelectionArea]。技能详情 / EMP 摘要等独立展示场景保持默认
  /// true,自带选中能力(系统工具条正常弹出,不受消息气泡菜单影响)。
  ///
  /// 嵌套在消息气泡外层唯一的 `ChatSelectableSurface`(`message_bubble.dart` /
  /// `chat_assistant_message_view.dart` / `chat_mixed_message_bubble.dart`)
  /// 里时传 false —— Flutter 不支持嵌套 `SelectableRegion`,渲染出的
  /// `Text.rich` 节点会自动加入外层已有的选区(ambient selection),不需要
  /// (也不能)自己再建一层。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return _ChatMarkdownBody(
      data: content,
      linkTapBehavior: linkTapBehavior,
      brightness: brightness ?? Theme.of(context).brightness,
      compact: compact,
      selectable: selectable,
    );
  }
}

enum ChatMarkdownLinkTapBehavior { confirm, direct }

class _ChatMarkdownBody extends StatelessWidget {
  const _ChatMarkdownBody({
    required this.data,
    this.linkTapBehavior = ChatMarkdownLinkTapBehavior.confirm,
    required this.brightness,
    this.compact = false,
    this.selectable = true,
  });

  final String data;
  final ChatMarkdownLinkTapBehavior linkTapBehavior;
  final Brightness brightness;
  final bool compact;
  final bool selectable;

  static ParserPluginRegistry _buildPlugins() {
    return ParserPluginRegistry()..register(const MermaidPlugin());
  }

  // 紧凑模式样式表：统一字号、降低标题层级感，行高与正文一致；
  // 用于详情弹框等需要"看起来还是一段文字"的渲染场景。
  static MarkdownStyleSheet _applyCompactStyle(MarkdownStyleSheet base) {
    const bodyColor = Color(0xFF475467);
    const headerColor = Color(0xFF101828);
    const bodyStyle = TextStyle(
      fontSize: 15,
      height: 1.7,
      color: bodyColor
    );
    return base.copyWith(
      textStyle: bodyStyle,
      paragraphStyle: bodyStyle,
      h1Style: bodyStyle.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      h2Style: bodyStyle.copyWith(
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      h3Style: bodyStyle.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      h4Style: bodyStyle.copyWith(
        fontSize: 15.5,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      h5Style: bodyStyle.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      h6Style: bodyStyle.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      boldStyle: bodyStyle.copyWith(
        fontWeight: FontWeight.w700,
        color: headerColor,
      ),
      italicStyle: bodyStyle.copyWith(fontStyle: FontStyle.italic),
      linkStyle: bodyStyle.copyWith(
        color: const Color(0xFF3B6FE5),
        decoration: TextDecoration.underline,
        decorationColor: const Color(0xFF3B6FE5),
      ),
      inlineCodeStyle: bodyStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: const Color(0xFFF2F4F7),
      ),
      blockquoteStyle: bodyStyle,
      tableHeaderStyle: bodyStyle.copyWith(fontWeight: FontWeight.w700),
      listBulletStyle: bodyStyle.copyWith(
        fontSize: 13,
        color: const Color(0xFF98A2B3),
      ),
      listIndent: 20,
    );
  }

  // 规范化换行：把 \r\n 和裸 \r 都收敛成 \n。
  // 背景：flutter_smooth_markdown 0.7.2 的 BlockParser 在按 \n split 后，
  // 行尾若残留 \r，header 捕获正则 ^(#{1,6})\s+(.+)$ 会因 Dart/ECMAScript
  // 语义下 $ 不放过 \r 而失败，抛 FormatException("Invalid header format")，
  // 直接打挂技能详情等使用 ChatMarkdownWidget 的页面。
  static String _normalizeLineEndings(String source) {
    if (!source.contains('\r')) return source;
    return source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  // 把"紧跟在文字后面的文档链接"提到独立段落,让 _MarkdownFileChip 卡片单独成行。
  // 模型常写成 `开始生成文件。[报告.pptx](url) 共 10 页…`,链接夹在句子中间会被
  // 当行内 widget 渲染成"上半截突兀的卡片",视觉很糟。命中扩展名的链接前后都补
  // `\n\n` 强制段落断开。链接已经在行首/段首的不重复加空行。
  static final RegExp _kDocLinkInlinePattern = RegExp(
    r'(\[[^\]]*\.(?:pdf|docx?|xlsx?|pptx?|csv|tsv|txt|md|json|xml|yaml|yml|html?|zip|rar|7z|tar|gz|mp3|wav|m4a|ogg|mp4|mov|avi|mkv|webm)[^\]]*\]\([^\s)]+\))',
    caseSensitive: false,
  );

  static String _isolateDocLinks(String source) {
    if (!source.contains('](')) return source;
    return source.replaceAllMapped(_kDocLinkInlinePattern, (m) {
      final start = m.start;
      final end = m.end;
      final before = start == 0 ? '' : source[start - 1];
      final after = end >= source.length ? '' : source[end];
      final link = m.group(0)!;
      // 决定前缀:已经在行首/段首就不加;前一个字符不是 \n 就加 \n\n。
      final leading = (before == '' || before == '\n') ? '' : '\n\n';
      final trailing = (after == '' || after == '\n') ? '' : '\n\n';
      return '$leading$link$trailing';
    });
  }

  static String _normalizeLatexFences(String source) {
    var normalized = source;

    final blockFencePattern = RegExp(
      r'(^|\n)```(?:latex|tex|math)\s*\n([\s\S]*?)\n```(?=\n|$)',
      multiLine: true,
    );
    normalized = normalized.replaceAllMapped(blockFencePattern, (match) {
      final prefix = match.group(1) ?? '';
      final body = match.group(2)?.trimRight() ?? '';
      return '$prefix\$\$\n$body\n\$\$';
    });

    final inlineFencePattern = RegExp(
      r'(^|\n)```(?:latex|tex|math)\s+([\s\S]*?)```(?=\n|$)',
      multiLine: true,
    );
    normalized = normalized.replaceAllMapped(inlineFencePattern, (match) {
      final prefix = match.group(1) ?? '';
      final body = match.group(2)?.trim() ?? '';
      return '$prefix\$\$$body\$\$';
    });

    return normalized;
  }

  Future<void> _openUrl(String rawUrl) async {
    final uri = Uri.tryParse(safeDecodeFull(rawUrl));
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  MarkdownRenderer _buildRenderer(BuildContext context) {
    var styleSheet = MarkdownStyleSheet.github(
      brightness: brightness
    ).copyWith(
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ),
    );
    if (compact) {
      styleSheet = _applyCompactStyle(styleSheet);
    }

    final renderer = MarkdownRenderer(styleSheet: styleSheet);
    renderer
      ..registerBuilder('blockquote', const EnhancedBlockquoteBuilder())
      ..registerBuilder('code_block', _CodeBlockBuilder(brightness))
      ..registerBuilder('header', const _CursorHeaderBuilder())
      ..registerBuilder('link', const _CursorLinkBuilder())
      ..registerBuilder('mermaid', const MermaidBuilder());
    return renderer;
  }

  Widget _buildMarkdown(BuildContext context) {
    final renderer = _buildRenderer(context);
    final nodes = MarkdownParser(
      plugins: _buildPlugins()
    ).parse(
        _isolateDocLinks(_normalizeLatexFences(_normalizeLineEndings(data))));
    final widget = renderer.render(
      nodes,
      context: MarkdownRenderContext(
        selectable: true,
        onTapLink: (url) async {
          if (linkTapBehavior == ChatMarkdownLinkTapBehavior.direct) {
            await _openUrl(url);
            return;
          }
          await _showLinkConfirm(context, url);
        },
        onTapImage: (url, alt, title) async {
          if (tryOpenChatImagePreview(context,
              rawUrl: url, displayName: alt ?? title ?? '')) {
            return;
          }
          await _openUrl(url);
        },
        imageBuilder: (url, alt, title) =>
            _MarkdownImage(imageUrl: url, alt: alt, title: title),
      ),
    );

    final themed = Theme(
      data: Theme.of(context).copyWith(brightness: brightness),
      child: widget,
    );
    // selectable=false:已经嵌在消息气泡外层唯一的 ChatSelectableSurface 里,
    // 不需要(也不能,Flutter 不支持嵌套 SelectableRegion)再自建一层。
    return selectable ? SelectionArea(child: themed) : themed;
  }

  Future<void> _showLinkConfirm(BuildContext context, String url) async {
    final decodedUrl = safeDecodeFull(url);
    final confirmed = await showUiConfirmDialog(
      context,
      title: '是否打开此链接？',
      description: decodedUrl,
    );
    if (confirmed) await _openUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return _buildMarkdown(context);
  }
}

/// 安全 URI 解码:正常返回解码结果,遇到非法 percent encoding(模型偶尔会写出
/// `%` 后面跟非 hex 字符的 url)就退回原字符串,不抛 unhandled exception。
/// 历史:之前任何一条历史消息含坏 URL 都会让整个聊天列表 rebuild 反复抛
/// "Invalid argument(s): Illegal percent encoding in URI",日志被刷屏。
@visibleForTesting
String safeDecodeFull(String s) {
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s;
  }
}

@visibleForTesting
String safeDecodeComponent(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

class _MarkdownImage extends StatefulWidget {
  const _MarkdownImage({required this.imageUrl, this.alt, this.title});

  final String imageUrl;
  final String? alt;
  final String? title;

  @override
  State<_MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<_MarkdownImage> {
  static const double _imageWidth = 270;
  static const double _placeholderHeight = 340;

  /// 把 headers future 缓存到 state,避免 build 里直接 `_load...()` 每次都新建 future
  /// 导致 FutureBuilder 反复 waiting → done → waiting,聊天区一帧一帧闪。
  ///
  /// 必须用 var(不能 late final),因为流式期间 markdown 解析器会先用半成品 URL
  /// (比如 `attachment://foo` 没替换之前 / `/data/...` 还没 rewrite 的瞬间)
  /// 构建一次 _MarkdownImage,这种 URL 不以 `/app/` 开头 → headers 是空 map →
  /// 没 Bearer token → 后续 URL 补全成 `/app/...preview` 时 State 复用,空 header
  /// future 还卡着,请求 401 → errorWidget,只有切换会话/重建子树才能恢复。
  /// 这里在 didUpdateWidget 里看到 URL 变了就重新算一次 headers,跟流式更新对齐。
  late Future<Map<String, String>> _headersFuture =
      apiImageLoadHeaders(widget.imageUrl);

  @override
  void didUpdateWidget(covariant _MarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _headersFuture = apiImageLoadHeaders(widget.imageUrl);
    }
  }

  String get imageUrl => widget.imageUrl;
  String? get alt => widget.alt;
  String? get title => widget.title;

  Widget _buildPlaceholder() {
    return Container(
      width: _imageWidth,
      height: _placeholderHeight,
      color: const Color.fromARGB(51, 190, 190, 190),
      child: const Center(
        child: Icon(size: 36, CupertinoIcons.photo, color: Colors.grey),
      ),
    );
  }

  Widget _buildImage() {
    final decoded = safeDecodeFull(imageUrl);
    final localPath = decoded.trim();

    // SVG 用 flutter_svg 矢量渲染。`CachedNetworkImage` 底层是 raster 解码器，
    // 只能处理 PNG/JPEG/WebP/GIF/BMP；遇到 SVG 直接走 errorWidget 显示空白
    // 预留符（详见 v1.0.5 之前 bug：S3 上传 svg 后前端只剩灰图标）。
    if (_isSvgUrl(imageUrl)) {
      return SvgPicture.network(
        imageUrl,
        width: _imageWidth,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => _buildPlaceholder(),
      );
    }

    if (localPath.startsWith('file://')) {
      final path = Uri.parse(localPath).toFilePath();
      if (File(path).existsSync()) {
        return Image.file(File(path), width: _imageWidth, fit: BoxFit.contain);
      }
    }

    if (File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        width: _imageWidth,
        fit: BoxFit.contain,
      );
    }

    final absoluteUrl = apiImageResolveUrl(imageUrl);

    return FutureBuilder<Map<String, String>>(
      future: _headersFuture,
      builder: (context, snap) {
        // headers 还在 load 时先预留,避免拿空 header 去请求被 401。
        if (snap.connectionState != ConnectionState.done) {
          return _buildPlaceholder();
        }
        return UiNetworkImage(
          imageUrl: absoluteUrl,
          httpHeaders: snap.data,
          // cacheKey 不带 token,确保不同账号 / token 刷新后仍命中同一文件 cache。
          cacheKey: absoluteUrl,
          clip: false,
          imageBuilder: (context, imageProvider) {
            return Image(
              width: _imageWidth,
              image: imageProvider,
              fit: BoxFit.contain,
            );
          },
          placeholderBuilder: (_, __) => _buildPlaceholder(),
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 万一 agent 用 ![](url) 把 PPT/Word/PDF 等文档当图片塞过来（实际发生过），
    // 直接拦下来按"文件下载卡片"渲染，避免出现一格灰色预留符欺骗用户。
    if (_isDocUrl(imageUrl)) {
      return _MarkdownFileChip(
        url: imageUrl,
        displayName: (alt != null && alt!.trim().isNotEmpty)
            ? alt!.trim()
            : _fileNameFromUrl(imageUrl),
      );
    }

    final decoded = safeDecodeFull(imageUrl).trim();
    String? previewFilePath;
    String? previewFileUrl;
    if (decoded.startsWith('file://')) {
      previewFilePath = Uri.parse(decoded).toFilePath();
    } else if (File(decoded).existsSync()) {
      previewFilePath = decoded;
    } else {
      // 大图预览跟列表里小图共用同一套 URL+token 规则:
      // 相对路径补 baseURL,加 Bearer header,让 dialog 也能拉到 ai-office 的 preview。
      previewFileUrl = apiImageResolveUrl(imageUrl);
    }

    return UiImageHero(
        builder: (context, heroTag) => GestureDetector(
              onTap: () async {
                if (tryOpenChatImagePreview(context,
                    rawUrl: previewFilePath != null
                        ? Uri.file(previewFilePath).toString()
                        : imageUrl,
                    displayName: alt ?? title ?? '')) {
                  return;
                }
                final headers = await _headersFuture;
                if (!context.mounted) return;
                showImagePreviewRoute<void>(
                  context: context,
                  useSafeArea:
                      Theme.of(context).platform != TargetPlatform.iOS &&
                          Theme.of(context).platform != TargetPlatform.android,
                  builder: (_) => UiImagePreviewDialog(
                    heroTag: heroTag,
                    filePath: previewFilePath,
                    fileUrl: previewFileUrl,
                    httpHeaders: headers.isEmpty ? null : headers,
                  ),
                );
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildImage(),
              ),
            ));
  }
}

/// 聊天消息里渲染"可下载文件"卡片。
///
/// 触发场景：
///   * markdown 链接 `[文件名](url)`，url 后缀命中 [_kDocFileExtensions]
///   * markdown 图片 `![alt](url)`，但 url 其实是文档（agent 偶尔会写错）
class _MarkdownFileChip extends StatelessWidget {
  const _MarkdownFileChip({
    required this.url,
    required this.displayName
  });

  final String url;
  final String displayName;

  static const double _height = 56;
  static const double _maxWidth = 280;
  static const double _corner = 8;
  static const Color _nameColor = Color(0xFF0F172A);
  static const Color _subtitleColor = Color(0xFF64748B);

  Future<void> _open(BuildContext context) async {
    final trimmed = _cleanMarkdownUrlToken(url);
    if (trimmed.isEmpty) return;
    final safeDisplayName = _cleanMarkdownFileLabel(displayName);

    await showAttachmentPreviewDialog(
      context,
      rawUrl: trimmed,
      displayName:
          safeDisplayName.isEmpty ? _fileNameFromUrl(trimmed) : safeDisplayName,
    );
  }

  /// 取扩展名:优先看 url(老链路 url 形如 `xxx.pptx`,扩展名稳定),取不到再看
  /// displayName(新链路 url 是 `/app/openclaw-drive/files/<uuid>/preview` 没扩展名,
  /// 但 displayName 来源于 link text,agent 写出来一定带文件名,例如 `报告.pptx`)。
  String _resolveExt() {
    final fromUrl = _extOfUrl(_cleanMarkdownUrlToken(url));
    if (fromUrl.isNotEmpty) return fromUrl;
    return _extOfUrl(_cleanMarkdownFileLabel(displayName));
  }

  @override
  Widget build(BuildContext context) {
    final ext = _resolveExt();
    final safeDisplayName = _cleanMarkdownFileLabel(displayName);
    final radius = BorderRadius.circular(_corner);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Material(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: radius,
            onTap: () => _open(context),
            highlightColor: Colors.black.withValues(alpha: 0.04),
            hoverColor: Colors.black.withValues(alpha: 0.03),
            mouseCursor: SystemMouseCursors.click,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: radius,
                border: Border.all(
                  color: ChatTheme.border.withValues(alpha: 0.6),
                ),
              ),
              child: SizedBox(
                height: _height,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      FileAttachmentIcon(
                        // 老链路 url 自带 .pptx 等真扩展名,优先用;新链路 url 是
                        // `/app/.../preview` 没扩展名,改从 displayName 取
                        // (agent 写 `[报告.pptx](url)` 时 displayName 就是文件名)。
                        // 万一两边都拿不到,fallback 'bin' → 通用文档图标。
                        fileName: 'attachment.${ext.isEmpty ? 'bin' : ext}',
                        size: FileAttachmentIconSize.lg,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              safeDisplayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                                color: _nameColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              ext.isEmpty
                                  ? '点击下载'
                                  : '${ext.toUpperCase()} · 点击下载',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.2,
                                color: _subtitleColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.download_rounded,
                        size: 18,
                        color: _subtitleColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CursorLinkBuilder extends MarkdownWidgetBuilder {
  const _CursorLinkBuilder();

  @override
  bool canBuild(MarkdownNode node) => node is LinkNode;

  @override
  Widget build(
    MarkdownNode node,
    MarkdownStyleSheet styleSheet,
    MarkdownRenderContext context,
  ) {
    final linkNode = node as LinkNode;
    final inlineRenderer = context.inlineRenderer;
    final linkText = linkNode.children
        .whereType<TextNode>()
        .map((n) => n.content)
        .join()
        .trim();

    // 文档类链接（pdf/docx/xlsx/pptx/zip/...）渲染成下载卡片。
    // 与 _MarkdownImage 里的 doc 兜底路径共用 [_MarkdownFileChip]，
    // 这样 agent 写 `[报告.pptx](url)` 就有视觉识别度，不用再让用户去
    // "猜哪个链接是文件"。普通超链接保留原有「文字 + open_in_new」样式。
    //
    // 探测扩展名时同时看 URL 和 link text:新链路 URL 是
    // `/app/openclaw-drive/files/<uuid>/preview`(末尾 preview 无扩展名),
    // 但 agent 写出来的 link text 几乎一定带扩展名(`报告.pptx`),
    // 否则会被当成普通超链接,点击走系统 openUrl → macOS -50 打不开。
    if (_isDocUrl(linkNode.url) || _isDocUrl(linkText)) {
      return _MarkdownFileChip(
        url: linkNode.url,
        displayName:
            linkText.isNotEmpty ? linkText : _fileNameFromUrl(linkNode.url),
      );
    }

    // Builder 让链接 widget 在实际 BuildContext 里构建，从而能读到正确的
    // DefaultTextStyle（WidgetSpan 子节点不会继承外层 Text.rich 的 span 样式）。
    // 用 DefaultTextStyle.of(ctx).style 的 fontSize 加上 linkStyle 的颜色/装饰，
    // 确保链接字号与周围文字（段落 / 列表项）视觉一致。
    return Builder(
      builder: (ctx) {
        final ambient = DefaultTextStyle.of(ctx).style;
        final effectiveLinkStyle =
            (styleSheet.linkStyle ?? const TextStyle()).copyWith(
          fontSize: ambient.fontSize
        );

        final linkWidget = inlineRenderer != null
            ? inlineRenderer(linkNode.children, effectiveLinkStyle)
            : Text(linkText, style: effectiveLinkStyle);

        // SelectionContainer.disabled 把链接从 SelectionArea 的 hover 层排除，
        // 否则 SelectionArea 在其上层注册文本光标，会覆盖 MouseRegion 的 click 光标。
        return SelectionContainer.disabled(
          child: Semantics(
            link: true,
            label: linkNode.title ?? linkNode.url,
            child: GestureDetector(
              onTap: () => context.onTapLink?.call(linkNode.url),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 3,
                  children: [
                    linkWidget,
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 14,
                      color: effectiveLinkStyle.color,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CursorHeaderBuilder extends MarkdownWidgetBuilder {
  const _CursorHeaderBuilder();

  @override
  bool canBuild(MarkdownNode node) => node is HeaderNode;

  @override
  Widget build(
    MarkdownNode node,
    MarkdownStyleSheet styleSheet,
    MarkdownRenderContext context,
  ) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: EnhancedHeaderBuilder().build(node, styleSheet, context),
    );
  }
}

class _CodeBlockBuilder extends MarkdownWidgetBuilder {
  const _CodeBlockBuilder(this.brightness);

  final Brightness brightness;

  @override
  bool canBuild(MarkdownNode node) => node is CodeBlockNode;

  @override
  Widget build(
    MarkdownNode node,
    MarkdownStyleSheet styleSheet,
    MarkdownRenderContext context,
  ) {
    final codeNode = node as CodeBlockNode;
    final textContent = codeNode.code.endsWith('\n')
        ? codeNode.code.substring(0, codeNode.code.length - 1)
        : codeNode.code;
    final language = codeNode.language ?? '';
    final highlightLanguage = language.isEmpty ? 'plaintext' : language;

    return Builder(
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: brightness == Brightness.dark
              ? const Color(0xFF1E1E1E)
              : const Color(0xFFF5F7FA),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.all(
            color: brightness == Brightness.dark
                ? const Color(0xFF344054)
                : const Color(0xFFE4E7EC),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.max,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: Text(
                      language,
                      style:
                          CupertinoTheme.of(ctx).textTheme.textStyle.copyWith(
                                fontWeight: FontWeight.bold,
                                color: brightness == Brightness.dark
                                    ? const Color(0xFFD0D5DD)
                                    : const Color(0xFF344054),
                              ),
                    ),
                  ),
                  CopyWidget(content: textContent),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: HighlightView(
                  textContent,
                  language: highlightLanguage,
                  theme: _buildHighlightTheme(ctx),
                  padding: const EdgeInsets.all(8),
                  textStyle: GoogleFonts.robotoMono(
                    fontSize:
                        CupertinoTheme.of(ctx).textTheme.textStyle.fontSize! -
                            2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, TextStyle> _buildHighlightTheme(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final theme = brightness == Brightness.dark
        ? highlight_vs2015.vs2015Theme
        : highlight_github.githubTheme;
    final rootBackground = brightness == Brightness.dark
        ? const Color(0xFF1E1E1E)
        : const Color(0xFFF5F7FA);
    return {
      ...theme,
      'root': (theme['root'] ?? const TextStyle()).copyWith(
        backgroundColor: rootBackground,
      ),
    };
  }
}
