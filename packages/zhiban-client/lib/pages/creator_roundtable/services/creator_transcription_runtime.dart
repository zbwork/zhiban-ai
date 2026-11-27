import 'dart:ffi';
import 'dart:io';

import 'creator_component_installer.dart';
import 'creator_expert_workflow.dart';

class CreatorTranscriptionRuntime {
  CreatorTranscriptionRuntime({Directory? supportDirectory})
      : _installer = CreatorComponentInstaller('creator-transcription',
            supportDirectory: supportDirectory);

  final CreatorComponentInstaller _installer;

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
    return _installer.prepare(
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
    return _installer.prepare(
      label: '语音识别组件',
      url: url,
      digest: digest,
      output: executable,
      archiveEntry: Platform.isWindows ? 'Release/$executable' : executable,
      windowsWhisperLibraries: Platform.isWindows,
      progress: progress,
    );
  }

  static const _modelPath = '/ggerganov/whisper.cpp/resolve/'
      '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin';

  Future<String> model(void Function(String) progress) => _installer.prepare(
        label: '本机多语种模型',
        url: 'https://hf-mirror.com$_modelPath',
        fallbackUrl: 'https://huggingface.co$_modelPath',
        digest:
            '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
        output: 'ggml-base.bin',
        progress: progress,
      );

  static const _unsupportedPlatform =
      CreatorWorkflowException('当前系统暂不支持本机语音转写，可导入字幕。');
}
