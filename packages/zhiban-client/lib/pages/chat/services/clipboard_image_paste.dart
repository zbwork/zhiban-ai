import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

const _imageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'heic',
  'bmp',
};

bool isClipboardImagePath(String path) {
  final clean = path.trim();
  if (clean.isEmpty) return false;
  final dot = clean.lastIndexOf('.');
  if (dot < 0 || dot == clean.length - 1) return false;
  return _imageExtensions.contains(clean.substring(dot + 1).toLowerCase());
}

List<String> clipboardFilePaths(Iterable<String> paths) {
  return paths
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .toList();
}

bool clipboardContainsFilePaths(Iterable<String> paths) {
  return clipboardFilePaths(paths).isNotEmpty;
}

String? clipboardFirstImagePath(Iterable<String> paths) {
  for (final path in clipboardFilePaths(paths)) {
    if (isClipboardImagePath(path)) return path;
  }
  return null;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

/// Reads file attachments or image data from the system clipboard.
///
/// File paths take precedence over bitmap data because desktop platforms may
/// expose a preview image for copied PDFs or office documents.
Future<List<XFile>> readClipboardAttachmentsAsXFiles() async {
  final paths = await Pasteboard.files();
  final filePaths = clipboardFilePaths(paths);
  if (filePaths.isNotEmpty) {
    final files = <XFile>[];
    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      files.add(XFile(path, name: _basename(path)));
    }
    return files;
  }

  final bytes = await Pasteboard.image;
  if (bytes != null && bytes.isNotEmpty) {
    final dir = await getTemporaryDirectory();
    final name = 'clipboard-image-${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return [XFile(file.path, name: name, mimeType: 'image/png')];
  }
  return const [];
}

/// Reads an image from the system clipboard and returns it as an [XFile].
///
/// Supports both copied bitmap data (screenshots/web images) and copied image
/// files from desktop file managers. Returns null when the clipboard has no
/// image, allowing the platform's normal text paste to continue.
Future<XFile?> readClipboardImageAsXFile() async {
  final files = await readClipboardAttachmentsAsXFiles();
  for (final file in files) {
    if (isClipboardImagePath(file.name) || isClipboardImagePath(file.path)) {
      return file;
    }
  }
  return null;
}
