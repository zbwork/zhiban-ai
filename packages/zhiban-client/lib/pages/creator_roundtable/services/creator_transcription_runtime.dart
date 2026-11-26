import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'creator_expert_workflow.dart';

class CreatorTranscriptionRuntime {
  CreatorTranscriptionRuntime({Directory? supportDirectory})
      : _supportDirectory = supportDirectory;

  final Directory? _supportDirectory;
  static final Map<String, Future<String>> _inFlight = {};

  Future<String> ffmpeg(void Function(String) progress) {
    const wheelBase = 'https://files.pythonhosted.org/packages/';
    final (path, digest, platformName) = switch (Abi.current()) {
      Abi.macosArm64 => (
          '40/5c/f3d8a657d362cc93b81aab8feda487317da5b5d31c0e1fdfd5e986e55d17/imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl',
          'b1ae3173414b5fc5f538a726c4e48ea97edc0d2cdc11f103afee655c463fa742',
          'macos-aarch64-v7.1',
        ),
      Abi.macosX64 => (
          'da/58/87ef68ac83f4c7690961bce288fd8e382bc5f1513860fc7f90a9c1c1c6bf/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl',
          '9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61',
          'macos-x86_64-v7.1',
        ),
      Abi.windowsX64 => (
          '2c/c6/fa760e12a2483469e2bf5058c5faff664acf66cadb4df2ad6205b016a73d/imageio_ffmpeg-0.6.0-py3-none-win_amd64.whl',
          '02fa47c83703c37df6bfe4896aab339013f62bf02c5ebf2dce6da56af04ffc0a',
          'win-x86_64-v7.1.exe',
        ),
      _ => throw _unsupportedPlatform,
    };
    return _prepare(
      label: '媒体处理组件',
      url: '$wheelBase$path',
      digest: digest,
      output: Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
      archiveEntry: 'imageio_ffmpeg/binaries/ffmpeg-$platformName',
      progress: progress,
    );
  }

  Future<String> whisper(void Function(String) progress) {
    const macBase =
        'https://github.com/derektu/whisper-cpp-macos-bin/releases/download/v1.8.2';
    final (url, digest) = switch (Abi.current()) {
      Abi.macosArm64 => (
          '$macBase/whisper-cpp-v1.8.2-macos-arm64-metal.zip',
          'a13ab869ae25c8d1c30c52c5581d3f441bc9000520303bab9e58349ee28b466c',
        ),
      Abi.macosX64 => (
          '$macBase/whisper-cpp-v1.8.2-macos-x86_64-accelerate.zip',
          '97876fa94571324da6afdb30897caa3a739e4f7f0bd8744dfdb9f4edc911446f',
        ),
      Abi.windowsX64 => (
          'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip',
          '49dcc16de826f20bd53d44f947a1ae49dfa81f86cad67a64d80820cb192d674a',
        ),
      _ => throw _unsupportedPlatform,
    };
    final executable = Platform.isWindows ? 'whisper-cli.exe' : 'whisper-cli';
    return _prepare(
      label: '语音识别组件',
      url: url,
      digest: digest,
      output: executable,
      archiveEntry: Platform.isWindows ? 'Release/$executable' : executable,
      windowsWhisperLibraries: Platform.isWindows,
      progress: progress,
    );
  }

  Future<String> model(void Function(String) progress) => _prepare(
        label: '本机多语种模型',
        url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
            '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin',
        digest:
            '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
        output: 'ggml-base.bin',
        progress: progress,
      );

  static const _unsupportedPlatform =
      CreatorWorkflowException('当前系统暂不支持本机语音转写，可导入字幕。');

  Future<String> _prepare({
    required String label,
    required String url,
    required String digest,
    required String output,
    required void Function(String) progress,
    String? archiveEntry,
    bool windowsWhisperLibraries = false,
  }) async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    final root = Directory('${support.path}/creator-transcription');
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
