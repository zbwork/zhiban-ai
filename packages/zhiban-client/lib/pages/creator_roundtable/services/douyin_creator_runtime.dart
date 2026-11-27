import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'creator_component_installer.dart';
import 'creator_expert_workflow.dart';

typedef DouyinRuntimePaths = ({String python, String runner, String directory});

class DouyinCreatorRuntime {
  DouyinCreatorRuntime({Directory? supportDirectory})
      : _supportDirectory = supportDirectory;

  static const sourceCommit = 'f6be8c0ffba9a127075bbeafe4838716650b6325';
  static const _sourceDigest =
      'aa670401de6960824db69e70c17292d9bd3124afa579ec2f16cd974943115ab2';
  static const _uvVersion = '0.9.26';
  static const _pythonVersion = '3.12.12';
  static final _installing = <String, Future<void>>{};

  final Directory? _supportDirectory;

  Future<DouyinRuntimePaths> prepare(
      String adapter, void Function(String) progress) async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    final root = Directory('${support.path}/community-douyin');
    final tools = Directory(
        '${root.path}/managed-uv$_uvVersion-py$_pythonVersion-$sourceCommit');
    final python = Platform.isWindows
        ? '${tools.path}/env/Scripts/python.exe'
        : '${tools.path}/env/bin/python';
    final marker = File('${tools.path}/ready');
    var setup = _installing[tools.path];
    if (setup == null) {
      setup = _ensureInstalled(support, tools, python, marker, progress);
      _installing[tools.path] = setup;
      try {
        await setup;
      } finally {
        _installing.remove(tools.path);
      }
    } else {
      progress('正在准备抖音解析组件…');
      await setup;
    }
    final digest = sha256.convert(utf8.encode(adapter));
    final runner = File('${tools.path}/douyin_creator-$digest.py');
    if (!await runner.exists()) {
      final staging = await tools.createTemp('adapter-');
      try {
        final file = File('${staging.path}/adapter.py');
        await file.writeAsString(adapter, flush: true);
        try {
          await file.rename(runner.path);
        } on FileSystemException {
          if (!await runner.exists()) rethrow;
        }
      } finally {
        await staging.delete(recursive: true);
      }
    }
    return (python: python, runner: runner.path, directory: tools.path);
  }

  Future<void> _ensureInstalled(Directory support, Directory tools,
      String python, File marker, void Function(String) progress) async {
    if (await marker.exists() && await File(python).exists()) return;
    if (await marker.exists()) await marker.delete();
    final uv = await _uv(support, progress);
    await tools.create(recursive: true);
    final environment = {
      'UV_PYTHON_INSTALL_DIR': '${tools.path}/python',
      'UV_CACHE_DIR': '${tools.path}/cache',
      'UV_PYTHON_DOWNLOADS': 'automatic',
      'UV_NO_MODIFY_PATH': '1',
    };
    progress('正在准备抖音解析运行环境…');
    await _configure(
        uv,
        [
          '--no-config',
          'venv',
          '--no-project',
          '--clear',
          '--managed-python',
          '--python',
          _pythonVersion,
          '${tools.path}/env',
        ],
        tools,
        environment,
        const Duration(minutes: 4));
    progress('正在安装抖音解析依赖…');
    await _configure(
        uv,
        [
          '--no-config',
          'pip',
          'install',
          '--python',
          python,
          '--default-index',
          'https://pypi.org/simple',
          'f2 @ https://github.com/Johnserf-Seed/f2/archive/$sourceCommit.zip'
              '#sha256=$_sourceDigest',
        ],
        tools,
        environment,
        const Duration(minutes: 4));
    progress('正在验证抖音解析组件…');
    await _configure(
        python,
        [
          '-I',
          '-X',
          'utf8',
          '-c',
          'from f2.apps.douyin.handler import DouyinHandler; '
              'from f2.apps.douyin.utils import AwemeIdFetcher',
        ],
        tools,
        environment,
        const Duration(seconds: 30));
    await marker.writeAsString(sourceCommit, flush: true);
  }

  Future<String> _uv(Directory support, void Function(String) progress) {
    final (path, digest, platform) = switch (Abi.current()) {
      Abi.macosArm64 => (
          '0d/a2/664a338aefe009f6e38e47455ee2f64a21da7ad431dbcaf8b45d8b1a2b7a',
          '1b012e6c4dfe767f818cbb6f47d02c207c9b0c82fee69a5de6d26ffb26a3ef3c',
          'macosx_11_0_arm64',
        ),
      Abi.macosX64 => (
          'a5/8b/68ac5825a615a8697e324f52ac0b92feb47a0ec36a63759c5f2931f0c3a0',
          'b815e3b26eeed00e00f831343daba7a9d99c1506883c189453bb4d215f54faac',
          'macosx_10_12_x86_64',
        ),
      Abi.windowsX64 => (
          '07/5d/eb80c6eff2a9f7d5cf35ec84fda323b74aa0054145db28baf72d35a7a301',
          '0315fc321f5644b12118f9928086513363ed9b29d74d99f1539fda1b6b5478ab',
          'win_amd64',
        ),
      _ => throw const CreatorWorkflowException('当前系统暂不支持抖音作品解析。'),
    };
    final executable = Platform.isWindows ? 'uv.exe' : 'uv';
    return CreatorComponentInstaller('community-douyin/components',
            supportDirectory: support)
        .prepare(
      label: '抖音解析组件',
      url: 'https://files.pythonhosted.org/packages/$path/'
          'uv-$_uvVersion-py3-none-$platform.whl',
      digest: digest,
      output: executable,
      archiveEntry: 'uv-$_uvVersion.data/scripts/$executable',
      progress: progress,
    );
  }

  Future<void> _configure(
    String executable,
    List<String> arguments,
    Directory tools,
    Map<String, String> environment,
    Duration timeout,
  ) async {
    final Process process;
    try {
      process = await Process.start(executable, arguments,
          workingDirectory: tools.path, environment: environment);
    } on ProcessException {
      throw const CreatorWorkflowException('抖音解析组件无法启动，请检查本机权限后重试。');
    }
    try {
      final stdout = process.stdout.drain<void>();
      final stderr = process.stderr.drain<void>();
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(timeout);
      await Future.wait([stdout, stderr]);
      if (exitCode != 0) {
        throw const CreatorWorkflowException('抖音解析组件准备失败，请检查网络和磁盘空间后重试。');
      }
    } on TimeoutException {
      process.kill();
      throw const CreatorWorkflowException('抖音解析组件准备超时，请重试。');
    }
  }
}
