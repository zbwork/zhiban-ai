import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// User-selected plaintext persistence; never accesses the OS credential store.
class LocalApiKeyFileStore {
  const LocalApiKeyFileStore({this.root});
  final Directory? root;

  Future<Directory> _directory() async {
    final directory = root ??
        Directory(
            '${(await getApplicationSupportDirectory()).path}/community-credentials');
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FileSystemException('凭据目录无效');
    }
    directory.createSync(recursive: true);
    _restrict(directory.path, '700');
    return directory;
  }

  void _restrict(String path, String mode) {
    if (Platform.isMacOS || Platform.isLinux) {
      final result = Process.runSync('/bin/chmod', [mode, path]);
      if (result.exitCode != 0) {
        throw const FileSystemException('无法设置凭据文件权限');
      }
    }
  }

  Future<File> _file(String key) async => File(
      '${(await _directory()).path}/${sha256.convert(utf8.encode(key))}.key');

  Future<String?> read(String key) async {
    final file = await _file(key);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || file.lengthSync() > 32768) {
      throw const FileSystemException('凭据文件无效');
    }
    _restrict(file.path, '600');
    return file.readAsStringSync();
  }

  Future<void> write(String key, String value) async {
    if (utf8.encode(value).length > 32768) {
      throw const FileSystemException('密钥过长');
    }
    final file = await _file(key);
    final staging = Directory(file.parent.path).createTempSync('.key-');
    try {
      _restrict(staging.path, '700');
      final next = File('${staging.path}/value');
      next.writeAsStringSync(value, flush: true);
      _restrict(next.path, '600');
      next.renameSync(file.path);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }

  Future<void> delete(String key) async {
    final file = await _file(key);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('凭据文件无效');
    }
    file.deleteSync();
  }
}
