import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import 'app_update_service.dart';

bool _isAllowedUpdateUri(Uri? uri) =>
    uri != null &&
    uri.host.isNotEmpty &&
    (uri.scheme == 'https' ||
        (kDebugMode &&
            uri.scheme == 'http' &&
            const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)));

typedef DesktopDownloadProgressCallback = void Function(
  int receivedBytes,
  int totalBytes, {
  required String packageType,
});

class CachedDesktopUpdate {
  const CachedDesktopUpdate({
    required this.directory,
    required this.buildNumber,
    required this.version,
    required this.platform,
    required this.size,
    required this.digest,
    required this.appcast,
    this.packageType = 'full',
    this.deltaFromBuild,
  });

  final Directory directory;
  final String buildNumber;
  final String version;
  final String platform;
  final int size;
  final String digest;
  final String appcast;
  final String packageType;
  final String? deltaFromBuild;

  String get filename => packageType == 'delta'
      ? 'installer.delta'
      : platform == 'macos'
          ? 'installer.dmg'
          : 'installer.exe';
  File get archive => File.fromUri(directory.uri.resolve(filename));
}

/// Keeps completed packages outside updater temporary folders. The native
/// updater still verifies the original EdDSA signature before installation.
class DesktopUpdateCache {
  DesktopUpdateCache({
    required this.platform,
    required Future<Directory> Function() directory,
    required Future<String> Function() installedBuild,
    Dio? dio,
  })  : _directory = directory,
        _installedBuild = installedBuild,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
            ));

  factory DesktopUpdateCache.local() => DesktopUpdateCache(
        platform: Platform.operatingSystem,
        directory: () async => Directory.fromUri(
            (await getApplicationSupportDirectory())
                .uri
                .resolve('desktop-updates/')),
        installedBuild: () async =>
            (await PackageInfo.fromPlatform()).buildNumber,
      );

  final String platform;
  final Future<Directory> Function() _directory;
  final Future<String> Function() _installedBuild;
  final Dio _dio;
  Future<CachedDesktopUpdate>? _download;
  Future<Uri>? _startingFeed;
  HttpServer? _server;
  String? _serverBuild;
  Uri? _feedUri;
  final _reportedDeltaSourceMismatches = <String>{};

  bool get isDownloading => _download != null;

  /// [latestBuild] 是服务端当前最新版本的构建号。缓存里的包可能已被新版本取代、
  /// 甚至已被下线(装不上),只按"比已装版本新"复用会让用户永远卡在旧包上——
  /// 2026-09-16 两台机器都卡在 9/13 缓存的 12100,升级反复失败。传了就必须一致,
  /// 不一致直接删掉重下;取不到服务端信息(离线)时不加这个约束。
  Future<CachedDesktopUpdate?> restore({String latestBuild = ''}) async {
    final root = await _directory();
    if (!await root.exists()) return null;
    final expected = latestBuild.trim();
    final installedBuild = await _installedBuild();
    final installed = BigInt.tryParse(installedBuild);
    CachedDesktopUpdate? pending;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
              .hasMatch(
                  entity.uri.pathSegments.where((p) => p.isNotEmpty).last)) {
        continue;
      }
      final manifest = File.fromUri(entity.uri.resolve('manifest.json'));
      if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue; // A .part is never ready.
      }
      dynamic json;
      try {
        json = jsonDecode(await manifest.readAsString());
      } on FormatException {
        stderr.writeln(
            '[Update] source=cache cache manifest invalid; error_type=FormatException');
        continue;
      }
      if (json is! Map<String, dynamic> ||
          json['schema'] != 1 ||
          json['platform'] != platform ||
          json['build'] is! String ||
          json['version'] is! String ||
          json['size'] is! int ||
          json['size'] <= 0 ||
          json['sha256'] is! String ||
          json['appcast'] is! String) {
        continue;
      }
      final build = json['build'] as String;
      final target = BigInt.tryParse(build);
      if (target == null || target <= BigInt.zero) continue;
      if (expected.isNotEmpty && build != expected) {
        await entity.delete(recursive: true);
        continue;
      }
      if (installed != null && installed >= target) {
        // Only an installed build confirms success, never an installer launch.
        await entity.delete(recursive: true);
        continue;
      }
      // A valid Delta file still cannot update a different source build.
      // Preserve it as evidence, but do not expose it as install-ready or reuse
      // it instead of selecting an applicable package on the next download.
      if (json['package_type'] == 'delta' &&
          (installedBuild.isEmpty ||
              json['delta_from_build'] != installedBuild)) {
        final source = json['delta_from_build'] is String
            ? json['delta_from_build'] as String
            : 'missing';
        final message = 'cache ignored; reason=delta_source_mismatch '
            'current_build=$installedBuild delta_from_build=$source '
            'target_build=$build cache_package=delta';
        if (_reportedDeltaSourceMismatches.add(message)) {
          stderr.writeln('[Update] source=cache $message');
        }
        continue;
      }
      final update = CachedDesktopUpdate(
        directory: entity,
        buildNumber: build,
        version: json['version'] as String,
        platform: platform,
        size: json['size'] as int,
        digest: json['sha256'] as String,
        appcast: json['appcast'] as String,
        packageType: json['package_type'] == 'delta' ? 'delta' : 'full',
        deltaFromBuild: json['delta_from_build'] as String?,
      );
      if (await FileSystemEntity.type(update.archive.path,
              followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      if (await update.archive.length() != update.size ||
          (await sha256.bind(update.archive.openRead()).first).toString() !=
              update.digest) {
        continue; // Keep evidence; a retry writes a new isolated record.
      }
      if (pending == null || target > BigInt.parse(pending.buildNumber)) {
        pending = update;
      }
    }
    return pending;
  }

  Future<CachedDesktopUpdate> download(AppUpdateInfo info, Uri feedUrl,
      {DesktopDownloadProgressCallback? onProgress}) {
    return _download ??= _downloadUpdate(info, feedUrl, onProgress: onProgress)
        .whenComplete(() => _download = null);
  }

  Future<CachedDesktopUpdate> _downloadUpdate(AppUpdateInfo info, Uri feedUrl,
      {DesktopDownloadProgressCallback? onProgress}) async {
    final requestedBuild = BigInt.tryParse(info.latestBuildNumber);
    if (requestedBuild == null || requestedBuild <= BigInt.zero) {
      throw const FormatException('更新描述缺少有效构建号');
    }
    // 只复用"正是服务端要装的那一版"的缓存:构建号更高的缓存同样不算数,它多半
    // 是已被取代或下线的包(2026-09-16)。
    final existing = await restore(latestBuild: info.latestBuildNumber);
    if (existing != null && existing.buildNumber == info.latestBuildNumber) {
      return existing;
    }
    if (!{'macos', 'windows'}.contains(platform) ||
        !_isAllowedUpdateUri(feedUrl)) {
      throw const FormatException('桌面更新地址必须使用 HTTPS');
    }
    final response = await _dio.get<String>(feedUrl.toString(),
        options: Options(responseType: ResponseType.plain));
    final appcast = XmlDocument.parse(response.data ?? '');
    final channel = appcast.rootElement.getElement('channel');
    final items = channel?.findElements('item').toList() ?? [];
    String buildOf(XmlElement item) {
      final values =
          item.childElements.where((node) => node.name.local == 'version');
      return values.isEmpty
          ? item
                  .getElement('enclosure')
                  ?.attributes
                  .where((attr) => attr.name.local == 'version')
                  .firstOrNull
                  ?.value ??
              ''
          : values.first.innerText.trim();
    }

    final selected = items
        .where((item) => buildOf(item) == info.latestBuildNumber)
        .firstOrNull;
    final enclosure = selected?.getElement('enclosure');
    final installedBuild = await _installedBuild();
    final delta = platform == 'macos'
        ? selected
            ?.findAllElements('deltas',
                namespace:
                    'http://www.andymatuschak.org/xml-namespaces/sparkle')
            .expand((deltas) => deltas.findElements('enclosure'))
            .where((node) =>
                node.getAttribute('deltaFrom',
                    namespace:
                        'http://www.andymatuschak.org/xml-namespaces/sparkle') ==
                installedBuild)
            .firstOrNull
        : null;
    if (selected == null ||
        enclosure == null ||
        requestedBuild <= BigInt.zero) {
      throw const FormatException('更新描述缺少匹配的版本、大小或 EdDSA 签名');
    }
    for (final item in items) {
      if (item != selected) channel!.children.remove(item);
    }
    // Keep Sparkle's signed delta descriptors. Cache the matching delta first;
    // a download failure falls back to the full package in this same release.
    final root = await _directory();
    final folder = Directory.fromUri(root.uri.resolve('${const Uuid().v4()}/'));
    await folder.create(recursive: true);
    final candidates = <({XmlElement enclosure, String type})>[
      if (delta != null) (enclosure: delta, type: 'delta'),
      (enclosure: enclosure, type: 'full'),
    ];
    Object? lastError;
    StackTrace? lastStackTrace;
    for (final candidate in candidates) {
      final activeEnclosure = candidate.enclosure;
      final url = Uri.tryParse(activeEnclosure.getAttribute('url') ?? '');
      final length =
          int.tryParse(activeEnclosure.getAttribute('length') ?? '0');
      final signature = activeEnclosure.attributes
          .where((attr) => attr.name.local == 'edSignature')
          .firstOrNull
          ?.value;
      var signatureValid = false;
      try {
        signatureValid =
            signature != null && base64Decode(signature).length == 64;
      } on FormatException {
        // Treat malformed Delta metadata like a missing signature so the full
        // package remains available. Native Sparkle verifies authenticity.
      }
      if (!_isAllowedUpdateUri(url) ||
          length == null ||
          length < 0 ||
          !signatureValid) {
        if (candidate.type == 'delta') continue;
        throw const FormatException('更新描述缺少匹配的版本、大小或 EdDSA 签名');
      }
      final selectedUpdate = CachedDesktopUpdate(
        directory: folder,
        buildNumber: info.latestBuildNumber,
        version: info.latestVersion,
        platform: platform,
        size: length,
        digest: '',
        appcast: appcast.toXmlString(),
        packageType: candidate.type,
        deltaFromBuild: candidate.type == 'delta' ? installedBuild : null,
      );
      final partial = File('${selectedUpdate.archive.path}.part');
      try {
        stderr.writeln(
            '[Update] source=cache cache candidate selected; package_type=${candidate.type} '
            'current_build=$installedBuild target_build=${info.latestBuildNumber}');
        onProgress?.call(0, length > 0 ? length : 0,
            packageType: candidate.type);
        await _dio.download(url.toString(), partial.path,
            onReceiveProgress: (received, total) {
          onProgress?.call(received, length > 0 ? length : total,
              packageType: candidate.type);
        });
        final actualSize = await partial.length();
        if (actualSize <= 0 || (length > 0 && actualSize != length)) {
          throw const FormatException('安装包大小与更新描述不符，请重试下载');
        }
        activeEnclosure.setAttribute('length', actualSize.toString());
        final completedAppcast = appcast.toXmlString();
        final digest = (await sha256.bind(partial.openRead()).first).toString();
        await partial.rename(selectedUpdate.archive.path);
        final manifest = File.fromUri(folder.uri.resolve('manifest.json.part'));
        await manifest.writeAsString(
            jsonEncode({
              'schema': 1,
              'platform': platform,
              'build': info.latestBuildNumber,
              'version': info.latestVersion,
              'size': actualSize,
              'package_type': candidate.type,
              if (candidate.type == 'delta') 'delta_from_build': installedBuild,
              'sha256': digest,
              'appcast': completedAppcast,
            }),
            flush: true);
        await manifest
            .rename(File.fromUri(folder.uri.resolve('manifest.json')).path);
        final completed = CachedDesktopUpdate(
            directory: folder,
            buildNumber: info.latestBuildNumber,
            version: info.latestVersion,
            platform: platform,
            size: actualSize,
            digest: digest,
            appcast: completedAppcast,
            packageType: candidate.type,
            deltaFromBuild: candidate.type == 'delta' ? installedBuild : null);
        if (existing != null) {
          await _discard(existing);
        }
        return completed;
      } catch (error, stackTrace) {
        if (await partial.exists()) {
          await partial.delete();
        }
        lastError = error;
        lastStackTrace = stackTrace;
        stderr.writeln(
            '[Update] source=cache cache candidate failed; package_type=${candidate.type} '
            'target_build=${info.latestBuildNumber} '
            'error_type=${error.runtimeType} '
            'status=${error is DioException ? error.response?.statusCode ?? 0 : 0}');
        if (candidate.type == 'full') {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> _discard(CachedDesktopUpdate update) async {
    await close();
    if (await update.directory.exists()) {
      stderr.writeln(
          '[Update] source=cache cache discarded; reason=superseded build=${update.buildNumber}');
      await update.directory.delete(recursive: true);
    }
  }

  /// Only serves the selected cache entry. No filesystem path comes from HTTP.
  Future<Uri> installationFeed(CachedDesktopUpdate update) => _startingFeed ??=
      _startInstallationFeed(update).whenComplete(() => _startingFeed = null);

  Future<Uri> _startInstallationFeed(CachedDesktopUpdate update) async {
    if (_server != null && _serverBuild == update.directory.path) {
      return _feedUri!;
    }
    await close();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _serverBuild = update.directory.path;
    final token = const Uuid().v4();
    final base = Uri.parse('http://127.0.0.1:${server.port}/$token/');
    final feedUri = base.resolve('appcast.xml');
    _feedUri = feedUri;
    final xml = XmlDocument.parse(update.appcast);
    final item = xml.findAllElements('item').single;
    final delta = update.packageType == 'delta'
        ? item
            .findAllElements('deltas',
                namespace:
                    'http://www.andymatuschak.org/xml-namespaces/sparkle')
            .expand((deltas) => deltas.findElements('enclosure'))
            .where((node) =>
                node.getAttribute('deltaFrom',
                    namespace:
                        'http://www.andymatuschak.org/xml-namespaces/sparkle') ==
                update.deltaFromBuild)
            .firstOrNull
        : null;
    if (update.packageType == 'delta' && delta == null) {
      throw StateError('缓存的 Delta 更新与 appcast 不匹配');
    }
    (delta ?? item.getElement('enclosure'))!
        .setAttribute('url', base.resolve(update.filename).toString());
    final feed = utf8.encode(xml.toXmlString());
    server.listen((request) async {
      try {
        if (!{'GET', 'HEAD'}.contains(request.method)) {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        } else if (request.uri.path == feedUri.path) {
          request.response.headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8');
          request.response.contentLength = feed.length;
          if (request.method == 'GET') request.response.add(feed);
        } else if (request.uri.path == base.resolve(update.filename).path) {
          var start = 0;
          var end = update.size - 1;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
            if (match == null) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              await request.response.close();
              return;
            }
            start = int.parse(match[1]!);
            end = match[2]!.isEmpty ? end : int.parse(match[2]!);
            if (start > end || end >= update.size) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              await request.response.close();
              return;
            }
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(HttpHeaders.contentRangeHeader,
                'bytes $start-$end/${update.size}');
          }
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.headers.set('content-disposition',
              'attachment; filename="${update.filename}"');
          request.response.contentLength = end - start + 1;
          if (request.method == 'GET') {
            await request.response
                .addStream(update.archive.openRead(start, end + 1));
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (_) {
        // A native updater may disconnect when its user cancels. Keep the cache.
        request.response.close().ignore();
      }
    });
    return _feedUri!;
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _feedUri = null;
    _serverBuild = null;
    await server?.close(force: true);
  }
}
