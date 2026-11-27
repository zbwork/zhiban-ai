import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'creator_expert_workflow.dart';

class CreatorComponentInstaller {
  CreatorComponentInstaller(this._storagePath, {Directory? supportDirectory})
      : _supportDirectory = supportDirectory;

  final String _storagePath;
  final Directory? _supportDirectory;
  static final Map<String, Future<String>> _inFlight = {};

  Future<String> prepare({
    required String label,
    required String url,
    required String digest,
    required String output,
    required void Function(String) progress,
    String? fallbackUrl,
    String? archiveEntry,
    bool windowsWhisperLibraries = false,
  }) async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    final root = Directory('${support.path}/$_storagePath');
    final destination = Directory('${root.path}/$digest');
    final installed = File('${destination.path}/$output');
    if (await installed.exists()) return installed.path;
    final active = _inFlight[destination.path];
    if (active != null) {
      progress('正在准备$label…');
      return active;
    }
    final job = _install(
      root: root,
      destination: destination,
      installed: installed,
      label: label,
      sources: [
        Uri.parse(url),
        if (fallbackUrl != null) Uri.parse(fallbackUrl)
      ],
      digest: digest,
      output: output,
      archiveEntry: archiveEntry,
      windowsWhisperLibraries: windowsWhisperLibraries,
      progress: progress,
    );
    _inFlight[destination.path] = job;
    try {
      return await job;
    } finally {
      _inFlight.remove(destination.path);
    }
  }

  Future<String> _install({
    required Directory root,
    required Directory destination,
    required File installed,
    required String label,
    required List<Uri> sources,
    required String digest,
    required String output,
    required String? archiveEntry,
    required bool windowsWhisperLibraries,
    required void Function(String) progress,
  }) async {
    Directory? staging;
    try {
      await root.create(recursive: true);
      staging = await root.createTemp('download-');
      final download = File('${staging.path}/download');
      for (final (index, source) in sources.indexed) {
        if (index > 0) progress('正在切换$label下载源…');
        try {
          await _download(source, download, label, progress);
          progress('正在校验$label…');
          if ((await sha256.bind(download.openRead()).first).toString() !=
              digest) {
            throw CreatorWorkflowException('$label校验失败，请重试。');
          }
          break;
        } on CreatorWorkflowException {
          if (index == sources.length - 1) rethrow;
        }
      }
      final payload = await Directory('${staging.path}/payload').create();
      final artifact = File('${payload.path}/$output');
      if (archiveEntry == null) {
        await download.rename(artifact.path);
      } else {
        await Isolate.run(() => _extract(
            download, payload, artifact, archiveEntry,
            windowsWhisperLibraries: windowsWhisperLibraries));
        if (!Platform.isWindows) {
          final chmod = await Process.run('/bin/chmod', ['700', artifact.path]);
          if (chmod.exitCode != 0) throw FileSystemException('chmod');
        }
      }
      try {
        await payload.rename(destination.path);
      } on FileSystemException {
        if (!await installed.exists()) rethrow;
      }
      return installed.path;
    } on CreatorWorkflowException {
      rethrow;
    } on FileSystemException {
      throw CreatorWorkflowException('无法保存$label，请检查磁盘空间和权限。');
    } on Exception {
      throw CreatorWorkflowException('准备$label失败，请重试。');
    } finally {
      if (staging != null) await staging.delete(recursive: true);
    }
  }

  Future<void> _download(
      Uri uri, File file, String label, void Function(String) progress) async {
    const maxBytes = 160 * 1024 * 1024;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final timer = Stopwatch()..start();
    try {
      progress('正在下载$label…');
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw CreatorWorkflowException(
            '$label下载服务暂不可用（HTTP ${response.statusCode}），请重试。');
      }
      if (response.contentLength > maxBytes) {
        throw CreatorWorkflowException('$label超过下载体积上限，请重试。');
      }
      final sink = file.openWrite();
      var received = 0;
      var lastPercent = -1;
      try {
        await sink.addStream(
          response.timeout(const Duration(seconds: 30)).map((bytes) {
            received += bytes.length;
            if (received > maxBytes) {
              throw CreatorWorkflowException('$label超过下载体积上限，请重试。');
            }
            if (timer.elapsed > const Duration(minutes: 10)) {
              throw CreatorWorkflowException('$label下载超时，请重试。');
            }
            final total = response.contentLength;
            if (total > 0) {
              final percent = (received * 100 ~/ total).clamp(0, 100);
              if (percent != lastPercent) {
                lastPercent = percent;
                progress('正在下载$label · $percent%');
              }
            }
            return bytes;
          }),
        );
      } finally {
        await sink.close();
      }
    } on TimeoutException {
      throw CreatorWorkflowException('$label下载超时，请检查网络后重试。');
    } on SocketException {
      throw CreatorWorkflowException('$label下载连接失败，请检查网络后重试。');
    } on HttpException {
      throw CreatorWorkflowException('$label下载中断，请检查网络后重试。');
    } on HandshakeException {
      throw CreatorWorkflowException('$label无法建立安全连接，请检查网络后重试。');
    } finally {
      client.close(force: true);
    }
  }

  static void _extract(
      File download, Directory payload, File artifact, String archiveEntry,
      {required bool windowsWhisperLibraries}) {
    final input = InputFileStream(download.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final entry in archive.files.where((entry) => entry.isFile)) {
        final name = entry.name;
        final isLibrary = windowsWhisperLibraries &&
            RegExp(r'^Release/(?:ggml[-\w]*|whisper|SDL2)\.dll$')
                .hasMatch(name);
        if (name != archiveEntry && !isLibrary) continue;
        final path = isLibrary
            ? '${payload.path}/${name.substring('Release/'.length)}'
            : artifact.path;
        final output = OutputFileStream(path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
      if (!artifact.existsSync()) {
        throw FileSystemException('missing archive entry');
      }
    } finally {
      input.closeSync();
    }
  }
}
