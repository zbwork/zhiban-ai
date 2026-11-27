import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_runtime.dart';

void main() {
  test('首次使用自动准备抖音环境，并发请求和重开复用同一安装', () async {
    final directory = await Directory.systemTemp.createTemp('douyin-runtime-');
    addTearDown(() => directory.delete(recursive: true));
    final adapter = await File('assets/tools/douyin_creator.py').readAsString();
    final progress = <String>[];
    final results = await Future.wait([
      DouyinCreatorRuntime(supportDirectory: directory)
          .prepare(adapter, progress.add),
      DouyinCreatorRuntime(supportDirectory: directory)
          .prepare(adapter, progress.add),
    ]);
    final runtime = results.first;
    expect(results.last, runtime);
    expect(runtime.python, startsWith(directory.path));
    expect(progress.where((status) => status == '正在安装抖音解析依赖…'), hasLength(1));
    expect(progress.any((status) => status.startsWith('正在下载抖音解析组件')), isTrue);

    final process = await Process.start(
        runtime.python, ['-I', '-X', 'utf8', runtime.runner],
        workingDirectory: runtime.directory);
    final stdout = utf8.decoder.bind(process.stdout).join();
    final stderr = utf8.decoder.bind(process.stderr).join();
    process.stdin.write('{}');
    await process.stdin.close();
    expect(await process.exitCode, 0, reason: await stderr);
    expect(jsonDecode(await stdout), containsPair('code', 'auth_required'));

    progress.clear();
    final cached = await DouyinCreatorRuntime(supportDirectory: directory)
        .prepare(adapter, progress.add);
    expect(cached, runtime);
    expect(progress, isEmpty);
    final updated = await DouyinCreatorRuntime(supportDirectory: directory)
        .prepare('$adapter\n# Updated adapter\n', progress.add);
    expect(updated.python, runtime.python);
    expect(updated.runner, isNot(runtime.runner));
    expect(progress, isEmpty);
  },
      skip: Platform.environment['ROUNDTABLE_TEST_DOUYIN_RUNTIME'] != '1',
      timeout: const Timeout(Duration(minutes: 9)));
}
