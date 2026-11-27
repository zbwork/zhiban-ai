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
      url: url,
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
    required String url,
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
      await _download(Uri.parse(url), download, label, progress);
      progress('正在校验$label…');
      if ((await sha256.bind(download.openRead()).first).toString() != digest) {
        throw CreatorWorkflowException('$label校验失败，请重试。');
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
    } on Exception {
      throw CreatorWorkflowException('准备$label失败，请检查网络和磁盘空间后重试。');
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
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxBytes) {
        throw CreatorWorkflowException('下载$label失败，请稍后重试。');
      }
      final sink = file.openWrite();
      var received = 0;
      var lastPercent = -1;
      try {
        await sink.addStream(
          response.timeout(const Duration(seconds: 30)).map((bytes) {
            received += bytes.length;
            if (received > maxBytes ||
                timer.elapsed > const Duration(minutes: 10)) {
              throw CreatorWorkflowException('下载$label超时或文件过大，请重试。');
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
