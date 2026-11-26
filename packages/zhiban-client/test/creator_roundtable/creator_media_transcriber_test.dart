import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_media_transcriber.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_transcription_runtime.dart';

import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  final ffmpeg = Platform.environment['ROUNDTABLE_TEST_FFMPEG'];
  final model = Platform.environment['ROUNDTABLE_TEST_WHISPER_MODEL'];
  final speech = Platform.environment['ROUNDTABLE_TEST_SPEECH'];
  final whisper = Platform.environment['ROUNDTABLE_TEST_WHISPER_CLI'];
  CreatorMediaTranscriber transcriber({bool failModel = false}) =>
      CreatorMediaTranscriber(
        runtime: _FixtureRuntime(ffmpeg!, whisper, failModel ? null : model),
      );
  test('空缓存自动下载组件和模型，转写后再次使用缓存', () async {
    final directory =
        await Directory.systemTemp.createTemp('roundtable-asr-install-');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = CreatorTranscriptionRuntime(supportDirectory: directory);
    final service = CreatorMediaTranscriber(runtime: runtime);
    addTearDown(service.dispose);
    final progress = <String>[];
    final result =
        await service.transcribe(media: speech!, progress: progress.add);
    expect(result.source, 'local_asr');
    expect(result.cues.map((cue) => cue.text).join(' ').toLowerCase(),
        contains('country'));
    expect(
        progress.where((message) => message.startsWith('正在校验')), hasLength(3));
    progress.clear();
    await runtime.ffmpeg(progress.add);
    await runtime.whisper(progress.add);
    await runtime.model(progress.add);
    expect(progress, isEmpty);
  },
      timeout: const Timeout(Duration(minutes: 12)),
      skip: Platform.environment['ROUNDTABLE_TEST_MANAGED_RUNTIME'] != '1' ||
              speech == null
          ? 'Enable the real runtime downloads and provide the JFK sample'
          : false);

  test('无字幕语音使用真实 whisper.cpp 转写并保留时标', () async {
    final service = transcriber();
    addTearDown(service.dispose);
    final result = await service.transcribe(media: speech!, progress: (_) {});
    expect(result.source, 'local_asr');
    expect(result.cues.every((cue) => cue.endMs > cue.startMs), isTrue);
    final content = result.cues.map((cue) => cue.text).join(' ').toLowerCase();
    expect(content, contains('country'));
  },
      skip: ffmpeg == null || whisper == null || model == null || speech == null
          ? 'Provide the official whisper.cpp test model and JFK sample'
          : false);
  test('自动转写归档音频，逐字稿绑定当前归档文件且重复执行跳过', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final root = await Directory.systemTemp.createTemp('roundtable-local-asr-');
    addTearDown(() => root.delete(recursive: true));
    const id = '1234567890123456789';
    const name = '01010101-0101-0101-0101-010101010101.m4a';
    final media = Directory('${root.path}/media');
    await media.create();
    final generated = await Process.run(ffmpeg!, [
      '-nostdin',
      '-loglevel',
      'error',
      '-i',
      speech!,
      '-c:a',
      'aac',
      '${media.path}/$name',
    ]);
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    final creator = await store.importCreatorWorks(
      {'id': 'test'},
      [
        {'id': id, 'title': '带语音的归档'}
      ],
    );
    Future<LocalRow> row() async =>
        (await store.creatorWorks(creator.creatorId)).single;
    final work = await row();
    await store.saveCreatorMedia(
      workId: work['id'] as String,
      sourceVersion: work['source_version'] as int,
      fileName: name,
      digest: 'sample',
    );
    final service = transcriber();
    addTearDown(service.dispose);
    Future<({int saved, int failed, String? failureReason})> transcribe(
            CreatorMediaTranscriber transcriber) =>
        transcriber.transcribeArchivedWorks(
          store: store,
          creatorId: creator.creatorId,
          workIds: {id},
          root: root,
          progress: (_) {},
        );
    final unavailable = transcriber(failModel: true);
    addTearDown(unavailable.dispose);
    final missing = await transcribe(unavailable);
    expect(missing.failed, 1);
    expect(missing.saved, 0);
    expect(missing.failureReason, '测试模型不可用。');
    expect((await row())['transcript'], isEmpty);
    expect(await File('${media.path}/$name').exists(), isTrue);
    expect(
        await transcribe(service), (saved: 1, failed: 0, failureReason: null));
    final after = await row();
    expect((after['transcript'] as String).toLowerCase(), contains('country'));
    final metadata = jsonDecode(after['metadata'] as String) as Map;
    expect(metadata['transcript_source'], 'local_asr');
    expect(metadata['transcript_media_file'], name);
    expect(metadata['transcript_cues'], isNotEmpty);
    expect(
        await transcribe(service), (saved: 0, failed: 0, failureReason: null));
    expect(await row(), after);
  },
      skip: ffmpeg == null || whisper == null || model == null || speech == null
          ? 'Provide FFmpeg, the official whisper.cpp test model and JFK sample'
          : false);

  test('从真实视频容器提取内嵌字幕，保留时间码', () async {
    final directory =
        await Directory.systemTemp.createTemp('roundtable-media-test-');
    addTearDown(() => directory.delete(recursive: true));
    final subtitle = File('${directory.path}/test.srt');
    await subtitle.writeAsString('1\n00:00:00,200 --> 00:00:01,500\n先核对已有支出\n');
    final video = '${directory.path}/test.mkv';
    final generated = await Process.run(ffmpeg!, [
      '-nostdin',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=s=40x40:d=2',
      '-i',
      subtitle.path,
      '-c:v',
      'mpeg4',
      '-c:s',
      'srt',
      video,
    ]);
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    final service = transcriber();
    addTearDown(service.dispose);
    final result = await service.transcribe(
      media: video,
      progress: (_) {},
    );
    expect(result.source, 'embedded_subtitle');
    expect(result.cues.single, (startMs: 200, endMs: 1500, text: '先核对已有支出'));
  },
      skip: ffmpeg == null
          ? 'Set ROUNDTABLE_TEST_FFMPEG to enable native FFmpeg test'
          : false);
}

class _FixtureRuntime extends CreatorTranscriptionRuntime {
  _FixtureRuntime(this.ffmpegPath, this.whisperPath, this.modelPath);

  final String ffmpegPath;
  final String? whisperPath;
  final String? modelPath;

  @override
  Future<String> ffmpeg(void Function(String) progress) async => ffmpegPath;

  @override
  Future<String> whisper(void Function(String) progress) async => whisperPath!;

  @override
  Future<String> model(void Function(String) progress) async =>
      modelPath ?? (throw const CreatorWorkflowException('测试模型不可用。'));
}
