import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zhiban_client/config/client_assets.dart';

class DouyinCreatorException implements Exception {
  const DouyinCreatorException(this.message, {this.code});
  final String message;
  final String? code;

  bool get requiresLogin => code == 'auth_required' || code == 'auth_expired';
  @override
  String toString() => message;
}

Future<({Map<String, dynamic> author, List<Map<String, dynamic>> works})>
    collectDouyinWorks({
  required String authorId,
  required Future<Map<String, dynamic>> Function(int cursor, int count) fetch,
  int? latest,
  Map<String, dynamic>? checkpoint,
  Map<String, dynamic>? archivedAuthor,
  Future<void> Function(Map<String, Object?>)? onPage,
  Future<Map<String, dynamic>> Function(String workId)? restoreWork,
}) async {
  if (checkpoint != null &&
      (checkpoint['author_id'] != authorId ||
          restoreWork == null ||
          archivedAuthor?['id'] != authorId)) {
    throw const DouyinCreatorException('同步进度与当前博主不匹配。');
  }
  final restored = {
    for (final (id, time) in ((checkpoint?['works'] as Map?) ?? const {})
        .entries
        .map((entry) => (entry.key as String, entry.value as num)))
      id: <String, dynamic>{'id': id, 'published_at': time},
  };
  final works = {...restored};
  final cursors =
      ((checkpoint?['cursors'] as List?) ?? const []).cast<int>().toSet();
  Map<String, dynamic>? author;
  int? cursor = checkpoint == null ? 0 : checkpoint['next_cursor'] as int?;
  final pinned =
      ((checkpoint?['pinned_ids'] as List?) ?? const []).cast<String>().toSet();
  int remaining() =>
      latest == null ? 20 : latest - (works.length - pinned.length);

  while (cursor != null && remaining() > 0) {
    if (!cursors.add(cursor)) {
      throw const DouyinCreatorException('抖音返回重复游标，未保存本次同步。');
    }
    final page = await fetch(cursor, remaining().clamp(1, 20));
    final profile = page['author'];
    final posts = page['posts'];
    final next = page['next_cursor'];
    if (profile is! Map<String, dynamic> ||
        profile['id'] != authorId ||
        posts is! List ||
        (next != null && (next is! int || next < 0))) {
      throw const DouyinCreatorException('抖音返回的作者或分页数据有误，未保存本次同步。');
    }
    if (profile['profile_complete'] != false) {
      author ??= profile;
    } else if (cursor == 0 ||
        posts.isEmpty ||
        (author == null && archivedAuthor == null)) {
      throw const DouyinCreatorException('抖音分页缺少可核对的作者资料，未保存本次同步。');
    }
    for (final post in posts) {
      if (post is! Map<String, dynamic> ||
          post['id'] is! String ||
          post['published_at'] is! num) {
        throw const DouyinCreatorException('抖音作品数据不完整，未保存本次同步。');
      }
      final id = post['id'] as String;
      if (post['pinned'] == true) {
        if (latest != null && !works.containsKey(id)) pinned.add(id);
      } else {
        pinned.remove(id);
      }
      works.putIfAbsent(id, () => post);
    }
    if (cursors.contains(next)) {
      throw const DouyinCreatorException('抖音返回重复游标，未保存本次同步。');
    }
    cursor = remaining() <= 0 ? null : next as int?;
    if (onPage != null) {
      await onPage({
        'author_id': authorId,
        'next_cursor': cursor,
        'cursors': cursors.toList(),
        if (pinned.isNotEmpty) 'pinned_ids': pinned.toList(),
        'works': {
          for (final work in works.values)
            work['id'] as String: work['published_at'] as num,
        },
      });
    }
  }
  final ordered = works.values.toList()
    ..sort((a, b) {
      final time =
          (b['published_at'] as num).compareTo(a['published_at'] as num);
      return time == 0
          ? (b['id'] as String).compareTo(a['id'] as String)
          : time;
    });
  final selected = <Map<String, dynamic>>[];
  for (final work in latest == null ? ordered : ordered.take(latest)) {
    final id = work['id'] as String;
    if (restored.containsKey(id)) {
      final current = await restoreWork!(id);
      if (current['id'] != id) {
        throw const DouyinCreatorException('重新读取的抖音作品标识不符。');
      }
      selected.add(current);
    } else {
      selected.add(work);
    }
  }
  return (author: author ?? archivedAuthor!, works: selected);
}

/// Thin channel adapter. Cookies are accepted only through stdin and never
/// become command arguments, environment variables, database rows or logs.
class DouyinCreatorService {
  static const sourceCommit = 'f6be8c0ffba9a127075bbeafe4838716650b6325';
  static const userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  Process? _process;
  bool _closed = false;

  static String normalizeLink(String text) {
    // Some share paths escape URL punctuation as Markdown or JSON.
    final decoded = text.replaceAllMapped(
      RegExp(r'(https?)\\?:\\?/\\?/'),
      (match) => '${match[1]}://',
    );
    final matches = RegExp(r'https?://[^\s<>"\u3000]+').allMatches(decoded);
    if (matches.length != 1) {
      throw const DouyinCreatorException('请粘贴一条抖音作品链接或分享文本。');
    }
    final link =
        matches.single.group(0)!.replaceAll(RegExp(r'[，。；！）》」】)]+$'), '');
    final uri = Uri.tryParse(link);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !{'v.douyin.com', 'www.douyin.com', 'www.iesdouyin.com'}
            .contains(uri.host) ||
        (uri.host == 'www.douyin.com' &&
            !RegExp(r'^/(?:(?:video|note)/\d+|user/[A-Za-z0-9_.=-]{1,256})/?$')
                .hasMatch(uri.path))) {
      throw const DouyinCreatorException('请使用抖音的 HTTPS 作品链接或分享短链。');
    }
    return uri.toString();
  }

  void close() {
    _closed = true;
    _process?.kill();
  }

  Future<Map<String, dynamic>> read({
    required String cookie,
    required String link,
    required void Function(String) onStatus,
  }) {
    final normalized = normalizeLink(link);
    final uri = Uri.parse(normalized);
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (uri.host == 'www.douyin.com' &&
        parts.length == 2 &&
        parts.first == 'user') {
      return readAuthorPage(
          cookie: cookie, authorId: parts.last, cursor: 0, onStatus: onStatus);
    }
    return _read(cookie, {'url': normalized}, onStatus);
  }

  Future<Map<String, dynamic>> readSyncedWork({
    required String cookie,
    required String authorId,
    required String workId,
    required void Function(String) onStatus,
  }) =>
      _read(cookie, {'author_id': authorId, 'work_id': workId}, onStatus);

  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) =>
      _read(
          cookie,
          {
            'author_id': authorId,
            'cursor': cursor,
            'count': count,
          },
          onStatus);

  Future<Map<String, dynamic>> _read(String cookie, Map<String, Object> source,
      void Function(String) onStatus) async {
    final support = await getApplicationSupportDirectory();
    final tools = Directory('${support.path}/community-douyin/$sourceCommit');
    await tools.create(recursive: true);
    final python = Platform.isWindows
        ? '${tools.path}/env/Scripts/python.exe'
        : '${tools.path}/env/bin/python';
    final marker = File('${tools.path}/ready');
    if (!await marker.exists() || !await File(python).exists()) {
      final uv = await _findUv();
      onStatus('首次准备抖音解析组件，正在下载依赖…');
      if (!await File(python).exists()) {
        await _run(
            uv,
            [
              'venv',
              '--python',
              '>=3.11',
              '--no-python-downloads',
              '${tools.path}/env',
            ],
            workingDirectory: tools.path,
            timeout: const Duration(minutes: 2));
      }
      await _run(
          uv,
          [
            'pip',
            'install',
            '--python',
            python,
            '--index-url',
            'https://pypi.org/simple',
            'f2 @ https://github.com/Johnserf-Seed/f2/archive/$sourceCommit.zip',
          ],
          workingDirectory: tools.path,
          timeout: const Duration(minutes: 4));
      _checkOpen();
      await marker.writeAsString(sourceCommit, flush: true);
    }
    _checkOpen();
    final runner = File('${tools.path}/douyin_creator.py');
    await runner.writeAsString(
        await rootBundle
            .loadString(ClientAssets.path('assets/tools/douyin_creator.py')),
        flush: true);
    final cursor = source['cursor'];
    onStatus(cursor is int && cursor > 0 ? '正在读取公开作品…' : '正在读取作品、博主和其他公开作品…');
    final output = await _run(python, ['-I', runner.path],
        workingDirectory: tools.path,
        timeout: const Duration(seconds: 60),
        input: {
          ...source,
          'cookie': cookie,
          'user_agent': userAgent,
        });
    final Map<String, dynamic> response;
    try {
      response = jsonDecode(output) as Map<String, dynamic>;
    } on FormatException {
      throw const DouyinCreatorException('解析组件返回了无效数据。');
    }
    if (response['ok'] != true) {
      debugPrint('[creator-roundtable] ${jsonEncode({
            'code': response['code'],
            'kind': response['kind'],
            'status': response['status'],
            'stage': response['stage'],
          })}');
      const messages = {
        'auth_required': '请先在窗口内登录抖音。',
        'invalid_link': '无法从这条链接识别作品，请重新复制分享链接。',
        'author_mismatch': '抖音返回的作者不匹配，已停止导入。',
        'forbidden': '抖音拒绝了请求（403），请确认登录有效后重试。',
        'rate_limited': '抖音暂时限制了请求频率（429），请稍后重试。',
        'timeout': '抖音数据读取超时，请稍后重试。',
        'connection_failed': '连接抖音失败，请检查网络。',
        'not_found': '作品不存在、已删除或当前账号不可见。',
        'auth_expired': '抖音登录状态已失效，请重新登录。',
        'parse_failed': '抖音返回的数据格式发生变化，解析组件需要适配。',
        'empty_response': '抖音没有返回可用的作品数据。',
        'upstream_unavailable': '抖音服务暂不可用，请稍后重试。',
      };
      final stage = response['stage'];
      final prefix = stage is String && stage.isNotEmpty ? '$stage失败。' : '';
      final code = response['code'];
      throw DouyinCreatorException('$prefix${messages[code] ?? '抖音读取失败，请重试。'}',
          code: code is String ? code : null);
    }
    return Map<String, dynamic>.from(response['data'] as Map);
  }

  void _checkOpen() {
    if (_closed) throw const DouyinCreatorException('已停止读取。');
  }

  Future<String> _findUv() async {
    final directories = [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (Platform.environment['HOME'] case final String home)
        '$home/.local/bin',
      ...?Platform.environment['PATH']?.split(Platform.isWindows ? ';' : ':'),
    ];
    for (final directory in directories) {
      final file = File('$directory/${Platform.isWindows ? 'uv.exe' : 'uv'}');
      if (await file.exists()) return file.absolute.path;
    }
    throw const DouyinCreatorException('首次使用需要本机安装 uv，并准备 Python 3.11 或更高版本。');
  }

  Future<String> _run(String executable, List<String> arguments,
      {required String workingDirectory,
      required Duration timeout,
      Map<String, dynamic>? input}) async {
    _checkOpen();
    final Process process;
    try {
      process = await Process.start(executable, arguments,
          workingDirectory: workingDirectory,
          environment: const {'PYTHONDONTWRITEBYTECODE': '1'},
          runInShell: false);
    } on ProcessException {
      throw const DouyinCreatorException('本机解析组件启动失败，请检查系统权限。');
    }
    _process = process;
    if (_closed) process.kill();
    final bytes = <int>[];
    var tooLarge = false;
    final outputDone = process.stdout.forEach((chunk) {
      if (bytes.length + chunk.length <= 2 * 1024 * 1024) {
        bytes.addAll(chunk);
      } else {
        tooLarge = true;
        process.kill();
      }
    });
    final errorsDone = process.stderr.drain<void>();
    try {
      if (input != null) process.stdin.write(jsonEncode(input));
      await process.stdin.close();
      final exit = await process.exitCode.timeout(timeout);
      await Future.wait([outputDone, errorsDone]);
      _checkOpen();
      if (tooLarge) throw const DouyinCreatorException('作品数据过大，已停止读取。');
      if (exit != 0) {
        throw DouyinCreatorException(input == null
            ? '解析组件准备失败，请检查 GitHub/PyPI 网络后重试。'
            : '解析组件运行失败，请重试。');
      }
      return utf8.decode(bytes);
    } on TimeoutException {
      process.kill();
      throw const DouyinCreatorException('本机解析超时，已停止本次请求。');
    } finally {
      process.kill();
      if (identical(_process, process)) _process = null;
    }
  }
}
