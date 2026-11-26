import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../local_workspace/services/local_workspace_store.dart';
import 'creator_expert_workflow.dart';
import 'creator_remote_media.dart'
    show creatorArchivedMediaName, maxCreatorMediaBytes;
import 'creator_subtitles.dart';
import 'creator_transcription_runtime.dart';

class CreatorMediaTranscriber {
  CreatorMediaTranscriber({CreatorTranscriptionRuntime? runtime})
      : _runtime = runtime ?? CreatorTranscriptionRuntime();

  final CreatorTranscriptionRuntime _runtime;
  Process? _process;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _process?.kill();
  }

  Future<({int saved, int failed, String? failureReason})>
      transcribeArchivedWorks({
    required LocalWorkspaceStore store,
    required String creatorId,
    required Set<String> workIds,
    required Directory root,
    required void Function(String) progress,
  }) async {
    var saved = 0;
    var failed = 0;
    String? failureReason;
    for (final work in await store.creatorWorks(creatorId)) {
      if (_disposed) break;
      if (!workIds.contains(work['source_work_id']) ||
          (work['transcript'] as String?)?.isNotEmpty == true) {
        continue;
      }
      final metadata = jsonDecode(work['metadata'] as String) as Map;
      final fileName = creatorArchivedMediaName(metadata);
      if (fileName == null) continue;
      final media = File('${root.path}/media/$fileName');
      if (!await media.exists()) continue;
      try {
        final result = await transcribe(
          media: media.path,
          progress: progress,
        );
        if (_disposed) break;
        await store.saveCreatorTranscript(
          workId: work['id'] as String,
          sourceVersion: work['source_version'] as int,
          archivedMedia: fileName,
          source: result.source,
          transcript: result.cues.map((cue) => cue.text).join('\n'),
          cues: [
            for (final cue in result.cues)
              {'start_ms': cue.startMs, 'end_ms': cue.endMs, 'text': cue.text},
          ],
        );
        saved++;
      } on CreatorWorkflowException catch (error) {
        if (!_disposed) {
          failed++;
          failureReason ??= error.message;
        }
      } on Exception {
        if (!_disposed) failed++;
      } on StateError {
        if (!_disposed) failed++;
      }
    }
    return (saved: saved, failed: failed, failureReason: failureReason);
  }

  Future<({List<CreatorSubtitle> cues, String source})> transcribe({
    required String media,
    required void Function(String) progress,
  }) async {
    if (await File(media).length() > maxCreatorMediaBytes) {
      throw const CreatorWorkflowException('本地媒体不能超过 256 MB。');
    }
    final ffmpeg = await _runtime.ffmpeg(progress);
    final directory =
        await Directory.systemTemp.createTemp('creator-transcription-');
    try {
      final base = '${directory.path}/speech';
      final subtitles = File('$base.srt');
      final ffmpegInput = [
        '-nostdin',
        '-y',
        '-loglevel',
        'error',
        '-protocol_whitelist',
        'file',
        '-format_whitelist',
        'mov,matroska,webm,mp3,wav,flac,aac,ogg',
        '-i',
        File(media).absolute.path,
      ];
      progress('正在检查媒体中的字幕…');
      final embedded = await _run(
          ffmpeg,
          [...ffmpegInput, '-map', '0:s:0', '-c:s', 'srt', subtitles.path],
          const Duration(minutes: 2));
      if (embedded == 0 &&
          await subtitles.exists() &&
          await subtitles.length() > 0) {
        final cues = await _cues(subtitles);
        return (cues: cues, source: 'embedded_subtitle');
      }
      if (_disposed) throw const CreatorWorkflowException('已取消本机转写。');
      final whisper = await _runtime.whisper(progress);
      if (_disposed) throw const CreatorWorkflowException('已取消本机转写。');
      final model = await _runtime.model(progress);
      if (_disposed) {
        throw const CreatorWorkflowException('已取消本机转写。');
      }
      final audio = '${directory.path}/speech.wav';
      progress('正在提取音轨…');
      if (await _run(
              ffmpeg,
              [
                ...ffmpegInput,
                '-map',
                '0:a:0',
                '-vn',
                '-ar',
                '16000',
                '-ac',
                '1',
                '-c:a',
                'pcm_s16le',
                audio
              ],
              const Duration(minutes: 5)) !=
          0) {
        throw const CreatorWorkflowException('没有可读取的音轨，或本机无法解码此文件。');
      }
      progress('正在本机转写语音…');
      if (await _run(
                  whisper,
                  [
                    '-m',
                    File(model).absolute.path,
                    '-f',
                    audio,
                    '-l',
                    'auto',
                    '-osrt',
                    '-of',
                    base
                  ],
                  const Duration(minutes: 30)) !=
              0 ||
          !await subtitles.exists()) {
        throw const CreatorWorkflowException('本机语音转写失败，请检查模型文件及本机组件。');
      }
      return (cues: await _cues(subtitles), source: 'local_asr');
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<List<CreatorSubtitle>> _cues(File file) async {
    if (await file.length() > maxCreatorSubtitleBytes) {
      throw const CreatorWorkflowException('转出的字幕太长，请拆分媒体文件后再试。');
    }
    return parseCreatorSubtitles(await file.readAsString());
  }

  Future<int> _run(
      String executable, List<String> arguments, Duration timeout) async {
    if (_disposed) throw const CreatorWorkflowException('已取消本机转写。');
    final Process process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
    } on ProcessException {
      throw const CreatorWorkflowException('无法启动本机转写组件，可重试或导入字幕。');
    }
    _process = process;
    if (_disposed) process.kill();
    final drained = Future.wait(
        [process.stdout.drain<void>(), process.stderr.drain<void>()]);
    try {
      final status = await process.exitCode.timeout(timeout);
      await drained;
      if (_disposed) throw const CreatorWorkflowException('已取消本机转写。');
      return status;
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await drained;
      throw const CreatorWorkflowException('本机转写超时。');
    } finally {
      _process = null;
    }
  }
}
