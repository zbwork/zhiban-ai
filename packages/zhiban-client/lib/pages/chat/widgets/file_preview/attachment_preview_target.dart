import 'package:flutter/widgets.dart';

class AttachmentPreviewTarget {
  const AttachmentPreviewTarget(
      {required this.url,
      required this.name,
      this.mime = '',
      this.downloadUrl});
  final String url;
  final String name;
  final String mime;
  final String? downloadUrl;
}

/// Parses a preview address without allowing an accidental bare `%` in a
/// generated filename to crash the Flutter view. Existing percent escapes are
/// preserved; only a percent that is not followed by two hex digits is
/// encoded as `%25`.
Uri? tryParsePreviewUri(String value) {
  try {
    return Uri.parse(value);
  } on FormatException {
    final repaired =
        value.replaceAllMapped(RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    if (repaired == value) return null;
    try {
      return Uri.parse(repaired);
    } on FormatException {
      return null;
    }
  }
}

class AttachmentPreviewScope extends InheritedWidget {
  const AttachmentPreviewScope(
      {super.key, required this.open, this.selectedUrl, required super.child});
  final void Function(AttachmentPreviewTarget) open;
  final String? selectedUrl;
  static AttachmentPreviewScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AttachmentPreviewScope>();
  @override
  bool updateShouldNotify(AttachmentPreviewScope oldWidget) =>
      open != oldWidget.open || selectedUrl != oldWidget.selectedUrl;
}

/// Subframes may load only the viewer's in-memory documents. In particular,
/// an interactive HTML file cannot navigate its frame to an external website.
bool isAllowedPreviewNavigation(String url,
    {required bool isMainFrame, String? viewerFileUrl}) {
  // WKWebView also asks about its initial loadHTMLString navigation.
  if (isMainFrame) {
    return url == 'about:blank' ||
        url == 'https://preview.zhiban.invalid/' ||
        (viewerFileUrl != null &&
            Uri.tryParse(url) == Uri.tryParse(viewerFileUrl));
  }
  final uri = Uri.tryParse(url);
  return uri?.scheme == 'blob' || url == 'about:blank';
}

String attachmentPreviewFormat(String name, String url, [String mime = '']) {
  String extension(String value) {
    final path = Uri.tryParse(value)?.path ?? value;
    final last = path.split('/').last;
    return last.contains('.') ? last.split('.').last.toLowerCase() : '';
  }

  final ext = extension(name).isNotEmpty ? extension(name) : extension(url);
  if (['pptx', 'docx', 'xlsx', 'pdf'].contains(ext)) return ext;
  if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'avif', 'ico', 'svg']
      .contains(ext)) {
    return 'image';
  }
  if (['mp4', 'm4v', 'mov', 'webm', 'ogv'].contains(ext)) return 'video';
  if (['md', 'markdown', 'mdx'].contains(ext)) return 'markdown';
  if (['html', 'htm'].contains(ext)) return 'html';
  if ([
    'txt',
    'log',
    'csv',
    'json',
    'jsonc',
    'jsonl',
    'yaml',
    'yml',
    'xml',
    'toml',
    'ini',
    'conf',
    'config',
    'properties',
    'js',
    'jsx',
    'mjs',
    'cjs',
    'ts',
    'tsx',
    'css',
    'scss',
    'sass',
    'less',
    'py',
    'rb',
    'php',
    'java',
    'kt',
    'c',
    'cpp',
    'h',
    'cs',
    'go',
    'rs',
    'swift',
    'dart',
    'lua',
    'r',
    'sh',
    'bash',
    'zsh',
    'ps1',
    'sql',
    'graphql',
    'proto',
    'vue',
    'svelte',
    'diff',
    'patch'
  ].contains(ext)) {
    return 'text';
  }
  final type = mime.split(';').first.trim().toLowerCase();
  if (type == 'application/pdf') return 'pdf';
  if (type.contains('wordprocessingml')) return 'docx';
  if (type.contains('presentationml')) return 'pptx';
  if (type.contains('spreadsheetml')) return 'xlsx';
  if (type.startsWith('image/')) return 'image';
  if (type.startsWith('video/')) return 'video';
  if (type == 'text/html') return 'html';
  if (type == 'text/markdown') return 'markdown';
  if (type.startsWith('text/') || type == 'application/json') return 'text';
  return 'unsupported';
}

int attachmentPreviewLimit(String format) =>
    ['html', 'markdown', 'text'].contains(format)
        ? 2 * 1024 * 1024
        : 25 * 1024 * 1024;

/// Only explicit user clicks on public web links may leave the isolated viewer.
bool isAllowedPreviewLink(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}
