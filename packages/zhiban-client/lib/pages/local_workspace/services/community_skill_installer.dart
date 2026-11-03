import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'community_skill_catalog.dart';
import 'local_workspace_store.dart';

class CommunitySkillInstaller {
  CommunitySkillInstaller(this.store,
      {CommunitySkillCatalog? client, this.root})
      : client = client ?? CommunitySkillCatalog();
  final LocalWorkspaceStore store;
  final CommunitySkillCatalog client;
  final String? root;
  final Map<String, Future<void>> _pending = {};

  Future<void> install(String id, Map<String, dynamic> item) =>
      _pending.putIfAbsent(
          id,
          () => _install(id, item).whenComplete(() {
                _pending.remove(id);
              }));

  Future<void> _install(String id, Map<String, dynamic> item) async {
    final installed = await store.installedSkill(id);
    if (installed != null) {
      try {
        await verifiedFiles(installed);
        return;
      } on FileSystemException {
        // Recover missing files by downloading a fresh, verified package.
      } on StateError {
        // Keep the previous installation until replacement succeeds.
      }
    }
    final download = await client.downloadBundle(item['skill_uuid'] as String);
    final parsed = await compute(parseCommunitySkillBundle, <String, Object>{
      'bytes': download.bytes,
      'sha256': download.sha256,
      'code': item['code'] as String,
      'version': item['latest_version'] as String,
    });
    final base = root ??
        '${(await getApplicationSupportDirectory()).path}/community-skills';
    await Directory(base).create(recursive: true);
    final stage = Directory('$base/.install-${LocalWorkspaceStore.uuid.v4()}');
    final destination = '$base/${LocalWorkspaceStore.uuid.v4()}';
    try {
      await stage.create();
      final hashes = <String, String>{};
      for (final entry in (parsed['files'] as Map<String, Uint8List>).entries) {
        final file = File('${stage.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
        hashes[entry.key] = sha256.convert(entry.value).toString();
      }
      await stage.rename(destination);
      try {
        await store.recordInstalledSkill(
            id,
            {
              'root': await Directory(destination).resolveSymbolicLinks(),
              'code': item['code'],
              'version': item['latest_version'],
              'sha256': download.sha256,
              'files': hashes,
            },
            parsed['prompt'] as String);
      } catch (_) {
        await Directory(destination).delete(recursive: true);
        rethrow;
      }
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static Future<Map<String, Uint8List>> verifiedFiles(
      Map<String, dynamic> metadata) async {
    final root = metadata['root'] as String;
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('本地技能包缺失，请重新安装');
    }
    final canonical = await Directory(root).resolveSymbolicLinks();
    if (canonical != Directory(root).absolute.path) {
      throw StateError('技能目录不能包含链接');
    }
    final out = <String, Uint8List>{};
    final files = metadata['files'] as Map;
    if (files.isEmpty || files.length > 2000) {
      throw StateError('本地技能文件清单异常');
    }
    var total = 0;
    for (final entry in files.entries) {
      final name = entry.key as String;
      _safePath(name);
      final file = File('$root/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.resolveSymbolicLinks() != file.absolute.path ||
          await file.length() > 100 * 1024 * 1024 - total) {
        throw StateError('本地技能文件异常');
      }
      final bytes = await file.readAsBytes();
      total += bytes.length;
      if (sha256.convert(bytes).toString() != entry.value) {
        throw StateError('技能文件已变化，请重新安装后使用');
      }
      out[name] = bytes;
    }
    return out;
  }

  Future<String?> prepareForRun(
      String employee, String run, Iterable<String> ids) async {
    final packages = <Map<String, dynamic>>[];
    for (final id in ids) {
      final installed = await store.installedSkill(id);
      if (installed != null) packages.add(installed);
    }
    if (packages.isEmpty) return null;
    final support = await getApplicationSupportDirectory();
    final target =
        Directory('${support.path}/community-runtime/$employee/skills/$run');
    await target.create(recursive: true);
    try {
      for (final package in packages) {
        final code = package['code'] as String;
        _safeCode(code);
        for (final entry in (await verifiedFiles(package)).entries) {
          final file = File('${target.path}/$code/${entry.key}');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(entry.value);
        }
      }
      return target.resolveSymbolicLinks();
    } catch (_) {
      await target.delete(recursive: true);
      rethrow;
    }
  }
}

void _safeCode(String code) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').hasMatch(code)) {
    throw StateError('技能标识无效');
  }
}

void _safePath(String name) {
  if (name.isEmpty ||
      name.length > 1024 ||
      name.startsWith('/') ||
      name.contains(String.fromCharCode(92)) ||
      name.contains(':') ||
      name.contains(String.fromCharCode(0)) ||
      name.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
    throw StateError('技能包包含不安全路径');
  }
}

Map<String, Uint8List> _unzip(Uint8List bytes, int limit) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > 2000) throw StateError('技能文件数量过多');
  final files = <String, Uint8List>{};
  var total = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    if (header.generalPurposeBitFlag & 1 != 0) {
      throw StateError('技能包不能加密');
    }
    final name = header.filename;
    _safePath(name.endsWith('/') ? name.substring(0, name.length - 1) : name);
    final normalized = name.endsWith('/')
        ? name.substring(0, name.length - 1).toLowerCase()
        : name.toLowerCase();
    if (!names.add(normalized)) throw StateError('技能包存在重复路径');
    final mode = header.externalFileAttributes >> 16;
    final type = mode & 0xf000;
    if (type != 0 && type != 0x8000 && type != 0x4000) {
      throw StateError('技能包不能包含链接或特殊文件');
    }
    if (name.endsWith('/')) continue;
    if (header.uncompressedSize > limit - total) throw StateError('技能展开后过大');
    final part = header.file!;
    final raw = part.getStream(decompress: false).toUint8List();
    final sink = _LimitedSink(limit - total);
    if (header.compressionMethod == 8) {
      final decoder = ZLibCodec(raw: true).decoder.startChunkedConversion(sink);
      decoder.add(raw);
      decoder.close();
    } else if (header.compressionMethod == 0) {
      sink.add(raw);
    } else {
      throw StateError('不支持该技能压缩格式');
    }
    final body = sink.bytes.takeBytes();
    if (body.length != part.uncompressedSize || getCrc32(body) != part.crc32) {
      throw StateError('技能 ZIP 校验失败');
    }
    total += body.length;
    files[name] = body;
  }
  return files;
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) throw StateError('技能展开后过大');
    bytes.add(data);
  }

  @override
  void close() {}
}

Map<String, Object> parseCommunitySkillBundle(Map<String, Object> input) {
  final bytes = input['bytes'] as Uint8List;
  if (bytes.length > 200 * 1024 * 1024 ||
      input['sha256'] != sha256.convert(bytes).toString()) {
    throw StateError('技能下载摘要校验失败');
  }
  final code = input['code'] as String;
  _safeCode(code);
  final outer = _unzip(bytes, 200 * 1024 * 1024);
  final manifest = jsonDecode(utf8.decode(outer['manifest.json']!)) as Map;
  final entries = manifest['skills'] as List;
  if (manifest['format_version'] != 1 || entries.length != 1) {
    throw StateError('技能清单格式无效');
  }
  final entry = entries.single as Map;
  final version = entry['version'] as Map;
  if (entry['code'] != code || version['version'] != input['version']) {
    throw StateError('技能版本已更新，请刷新后重试');
  }
  final pkg = outer[version['package_path']];
  if (pkg == null ||
      pkg.length > 50 * 1024 * 1024 ||
      sha256.convert(pkg).toString() != version['package_sha256']) {
    throw StateError('技能包内容校验失败');
  }
  var files = _unzip(pkg, 100 * 1024 * 1024);
  if (!files.containsKey('SKILL.md')) {
    final roots = files.keys.where((p) => p.endsWith('/SKILL.md')).toList();
    if (roots.length != 1) throw StateError('技能缺少 SKILL.md');
    final prefix =
        roots.single.substring(0, roots.single.length - 'SKILL.md'.length);
    if (files.keys.any((p) => !p.startsWith(prefix))) {
      throw StateError('技能目录结构无效');
    }
    files = {
      for (final e in files.entries) e.key.substring(prefix.length): e.value
    };
  }
  final prompt = utf8.decode(files['SKILL.md']!);
  if (prompt.trim().isEmpty ||
      prompt.length > 200000 ||
      prompt.contains(String.fromCharCode(0))) {
    throw StateError('技能指令无效或过大');
  }
  return {'files': files, 'prompt': prompt};
}
