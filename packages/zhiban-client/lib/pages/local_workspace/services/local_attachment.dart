import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'local_workspace_store.dart';

class LocalAttachment {
  const LocalAttachment(
      {required this.name,
      required this.path,
      required this.size,
      required this.text,
      this.digest});
  final String name, path, text;
  final String? digest;
  final int size;
  Map<String, Object?> toJson() => {
        'name': name,
        'path': path,
        'size': size,
        'text': text,
        'digest': digest
      };
  factory LocalAttachment.fromJson(Map<String, dynamic> j) => LocalAttachment(
      name: j['name'] as String,
      path: j['path'] as String,
      size: j['size'] as int,
      text: j['text'] as String,
      digest: j['digest'] as String?);
  ChatFileItem get file => ChatFileItem.fromJson({
        'name': name,
        'filePath': path,
        'fileLink': Uri.file(path).toString(),
        'size': size,
      });
  static List<LocalAttachment> decode(Object? json) => (jsonDecode(
          json as String? ?? '[]') as List)
      .map((e) => LocalAttachment.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
}

class LocalAttachmentService {
  static const maxBytes = 10 * 1024 * 1024, maxText = 60000;
  static const extensions = [
    'txt',
    'md',
    'csv',
    'json',
    'log',
    'yaml',
    'yml',
    'xml',
    'dart',
    'py',
    'js',
    'ts',
    'html',
    'css',
    'sql',
    'docx',
    'xlsx',
    'pdf'
  ];
  static const _pdf = MethodChannel('cn.qkfintech.zhiban/local-documents');
  Future<LocalAttachment> read(String path) async {
    final file = File(path);
    final name = file.uri.pathSegments.last;
    final ext = name.split('.').last.toLowerCase();
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('请选择普通文件');
    }
    final bytes = await _boundedRead(file);
    final text = await _tryExtract(bytes, ext);
    return LocalAttachment(
        name: name,
        path: path,
        size: bytes.length,
        text: text,
        digest: sha256.convert(bytes).toString());
  }

  // Importing an original file does not imply a text decoder can read it.
  static Future<String> _tryExtract(Uint8List bytes, String ext) async {
    if (!extensions.contains(ext)) return '';
    try {
      final text = await _extract(bytes, ext);
      validateText(text);
      return text;
    } catch (_) {
      return '';
    }
  }

  static Future<String> _extract(Uint8List bytes, String ext) async {
    if (ext == 'pdf') {
      if (!Platform.isMacOS) throw StateError('当前系统暂不支持 PDF 解析，请转换为文本');
      try {
        return await _pdf
                .invokeMethod<String>('extractPdf', {'bytes': bytes}) ??
            '';
      } on PlatformException catch (e) {
        throw StateError(e.message ?? 'PDF 读取失败');
      }
    }
    try {
      return await compute(
          extractDocumentText, {'bytes': bytes, 'extension': ext});
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('文件无法解析，请确认格式正确且未加密；文本请使用 UTF-8 编码');
    }
  }

  static Future<Uint8List> _boundedRead(File file) async {
    if (await file.length() > maxBytes) throw StateError('单个文件不能超过 10 MiB');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > maxBytes) {
        throw StateError('单个文件不能超过 10 MiB');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static void validateText(String text) {
    if (text.trim().isEmpty) throw StateError('没有读取到文字；扫描件请先转为可选中文字的文档');
    if (text.length > maxText) throw StateError('文件文字超过 60,000 字符，请拆分后发送');
  }

  Future<List<LocalAttachment>> persist(
      String employee, List<LocalAttachment> files) async {
    if (files.isEmpty) return [];
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(employee)) {
      throw StateError('员工标识无效');
    }
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/community_attachments/$employee');
    final saved = <LocalAttachment>[];
    try {
      for (final item in files) {
        if (await FileSystemEntity.type(item.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('请选择普通文件');
        }
        final bytes = await _boundedRead(File(item.path));
        final ext = item.name.split('.').last.toLowerCase();
        final digest = sha256.convert(bytes).toString();
        final text = await _tryExtract(bytes, ext);
        if ((item.digest != null && digest != item.digest) ||
            text != item.text ||
            bytes.length != item.size) {
          throw StateError('文件已变化，请重新添加附件');
        }
        await dir.create(recursive: true);
        final suffix = RegExp(r'^[a-z0-9]{1,16}$').hasMatch(ext) ? '.$ext' : '';
        final target =
            File('${dir.path}/${LocalWorkspaceStore.uuid.v4()}$suffix');
        saved.add(LocalAttachment(
            name: item.name,
            path: target.path,
            size: bytes.length,
            text: text,
            digest: digest));
        await target.writeAsBytes(bytes, flush: true);
      }
      return saved;
    } catch (_) {
      for (final item in saved) {
        if (await File(item.path).exists()) await File(item.path).delete();
      }
      rethrow;
    }
  }

  Future<void> deleteEmployeeFiles(String employee) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(employee)) return;
    final root = await getApplicationSupportDirectory();
    for (final folder in ['community_attachments', 'community-runtime']) {
      final dir = Directory('${root.path}/$folder/$employee');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// OOXML parts are read in memory; nothing is extracted or executed.
String extractDocumentText(Map<String, Object> input) {
  final bytes = input['bytes'] as Uint8List;
  final ext = input['extension'] as String;
  if (ext != 'docx' && ext != 'xlsx') {
    final text = utf8.decode(bytes);
    if (text.contains('\u0000')) throw StateError('文件不是 UTF-8 文本');
    LocalAttachmentService.validateText(text);
    return text;
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  final archive = directory.fileHeaders;
  if (archive.length > 2000 ||
      archive.fold<int>(0, (n, f) => n + f.uncompressedSize) >
          32 * 1024 * 1024) {
    throw StateError('文档展开后过大，请拆分后发送');
  }
  var expandedBytes = 0;
  XmlDocument xml(String name) {
    final part = archive.where((f) => f.filename == name).firstOrNull;
    if (part == null) throw StateError('文档缺少必要内容');
    if ((part.generalPurposeBitFlag & 1) != 0) throw StateError('请先解密文档');
    final raw = part.file!.getStream(decompress: false).toUint8List();
    final sink = _BoundedDocumentSink(32 * 1024 * 1024 - expandedBytes);
    if (part.compressionMethod == 8) {
      final decoder = ZLibCodec(raw: true).decoder.startChunkedConversion(sink);
      decoder.add(raw);
      decoder.close();
    } else if (part.compressionMethod == 0) {
      sink.add(raw);
    } else {
      throw StateError('不支持该文档压缩格式');
    }
    final content = sink.bytes.takeBytes();
    expandedBytes += content.length;
    if (content.length != part.uncompressedSize ||
        getCrc32(content) != part.crc32) {
      throw StateError('文档内容校验失败');
    }
    final text = utf8.decode(content);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw StateError('不支持含外部实体的文档');
    }
    return XmlDocument.parse(text);
  }

  Iterable<XmlElement> elements(XmlNode root, String name) => root.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == name);
  String result;
  if (ext == 'docx') {
    result = elements(xml('word/document.xml'), 'p')
        .map((p) => elements(p, 't').map((t) => t.innerText).join())
        .join('\n');
  } else {
    final strings = !archive.any((f) => f.filename == 'xl/sharedStrings.xml')
        ? <String>[]
        : elements(xml('xl/sharedStrings.xml'), 'si')
            .map((e) => elements(e, 't').map((t) => t.innerText).join())
            .toList();
    final output = StringBuffer();
    var cellCount = 0;
    final sheets = archive
        .where((f) =>
            RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.filename))
        .toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));
    if (sheets.isEmpty) throw StateError('表格没有可读取的工作表');
    for (final sheet in sheets) {
      output.writeln('[${sheet.filename.split('/').last}]');
      for (final row in elements(xml(sheet.filename), 'row')) {
        final cells = elements(row, 'c').map((cell) {
          cellCount++;
          final type = cell.getAttribute('t');
          final value = elements(cell, 'v').firstOrNull?.innerText ?? '';
          final text = type == 's'
              ? strings[int.parse(value)]
              : type == 'inlineStr'
                  ? elements(cell, 't').map((t) => t.innerText).join()
                  : value;
          return '${cell.getAttribute('r') ?? ''}: $text';
        }).join('\t');
        output.writeln(cells);
        if (output.length > LocalAttachmentService.maxText) {
          throw StateError('表格文字超过 60,000 字符，请拆分后发送');
        }
      }
    }
    if (cellCount == 0) throw StateError('表格没有可读取的单元格');
    result = output.toString();
  }
  LocalAttachmentService.validateText(result);
  return result;
}

/// Enforces actual decompressed bytes, including dishonest ZIP size headers.
class _BoundedDocumentSink implements Sink<List<int>> {
  _BoundedDocumentSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw StateError('文档展开后过大，请拆分后发送');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
