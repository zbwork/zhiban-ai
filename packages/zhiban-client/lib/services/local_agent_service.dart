import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_loader.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'local_runtime_api.dart';
import 'local_workspace_error.dart';
import 'dart:async';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_client/services/local_installation_store.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;
import 'dart:typed_data';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/drive/services/drive_bytes_upload.dart';

/// Owns the local helper. Credentials travel through its parent pipe, never argv,
/// model prompts, workspace files or the app's HTTP logger.
class LocalAgentService extends ChangeNotifier {
  LocalAgentService._();
  static final instance = LocalAgentService._();
  final _resultsSaved = StreamController<String>.broadcast();
  Stream<String> get resultsSaved => _resultsSaved.stream;
  static const _power = MethodChannel('nexwork/local_agent_lifecycle');
  static const _computer = MethodChannel('nexwork/local_agent_computer');
  static const _nodeOverride = String.fromEnvironment('LOCAL_AGENT_NODE');
  static const _packageOverride = String.fromEnvironment('LOCAL_AGENT_PACKAGE');

  Process? _process;
  Future<void>? _starting;
  Timer? _supervisor;
  int _retryAttempt = 0;
  DateTime? _nextRetryAt;

  /// Auto-recovery gave up; only an explicit user action retries from here.
  bool needsManualReconnect = false;

  /// 5s→300s backoff. The helper reconnects its own channel; this only covers a dead helper process.
  static Duration supervisionBackoff(int attempt) =>
      Duration(seconds: attempt <= 0 ? 5 : (5 << (attempt - 1)).clamp(5, 300));

  /// After this many failed restarts we stop and tell the user, rather than respawning forever.
  static const supervisionAttemptLimit = 6;
  Dio? _ipc;
  String? _scope;
  String? _storageScope;
  final Map<String, String> _contexts = {};
  int _generation = 0;
  int get lifecycleGeneration => _generation;
  final Set<CancelToken> _uploads = {};
  String deviceId = '';
  Map<String, String> availableEngines = const {};
  bool supportsEngine(String engine) => availableEngines.containsKey(engine);
  String status = 'offline';
  String errorMessage = '';
  final Map<String, Map<String, dynamic>> approvals = {};
  final Map<String, String> activeRuns = {};
  bool get online => status == 'online' && _ipc != null;
  bool get supported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  static Map<String, dynamic>? identity(String token) {
    try {
      final claims = (jsonDecode(utf8.decode(
                  base64Url.decode(base64Url.normalize(token.split('.')[1]))))
              as Map)
          .cast<String, dynamic>();
      final scope = '${claims['act_scope'] ?? ''}';
      final tenantId = claims['act_tid'];
      final tenant = scope == 'tenant' && tenantId is int && tenantId > 0
          ? 'id:$tenantId'
          : scope.startsWith('tenant:') && scope.length > 7
              ? scope.substring(7)
              : '';
      if (tenant.isEmpty || claims['sub'] == null || claims['sid'] == null) {
        return null;
      }
      return {
        'account': claims['sub'],
        'tenant': tenant,
        'loginSession': claims['sid']
      };
    } catch (_) {
      return null;
    }
  }

  String _identityKey(Map<String, dynamic> value) =>
      '${value['tenant']}:${value['account']}:${value['loginSession']}';

  Future<void> beforeIdentityChange(String? nextToken) async {
    ConversationModels.instance.clear();
    final next = nextToken == null ? null : identity(nextToken);
    if (next == null || _scope != _identityKey(next)) {
      await stop();
      // Logout / account switch is the one case where auto-recovery must not fire again.
      _supervisor?.cancel();
      _supervisor = null;
      _scope = null;
      _retryAttempt = 0;
      _nextRetryAt = null;
      needsManualReconnect = false;
    }
  }

  Future<void> ensureReady() {
    // An explicit user action always retries now and re-arms auto-recovery.
    _retryAttempt = 0;
    _nextRetryAt = null;
    needsManualReconnect = false;
    if (online) return Future.value();
    if (_starting == null && _process != null) {
      return Future.error(StateError('本机运行组件正在重新连接，请稍候'));
    }
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// Keeps the helper alive without the user having to touch anything (I-08 / decision Q4).
  void _armSupervision() {
    _supervisor ??=
        Timer.periodic(const Duration(seconds: 10), (_) => _superviseTick());
  }

  void _superviseTick() {
    if (_scope == null ||
        _process != null ||
        online ||
        _starting != null ||
        needsManualReconnect) {
      return;
    }
    final now = DateTime.now();
    final due = _nextRetryAt;
    if (due != null && now.isBefore(due)) return;
    if (_retryAttempt >= supervisionAttemptLimit) {
      needsManualReconnect = true;
      errorMessage = '本机运行组件多次启动失败，请在设置中手动重连';
      notifyListeners();
      return;
    }
    _retryAttempt += 1;
    _nextRetryAt = now.add(supervisionBackoff(_retryAttempt));
    _starting ??= _start().whenComplete(() => _starting = null).catchError((_) {
      // Failure already recorded on the service; the next tick applies the backoff.
    });
  }

  Map<String, String> get componentPaths {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final bundleRoot = Platform.isMacOS
        ? '${executableDir.parent.path}/Resources/local-agent'
        : '${executableDir.path}/local-agent';
    final architecture = Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64';
    // v2 Mac bundles keep native Node/npm dependencies separate for each ABI.
    // The legacy flat layout remains readable during development/upgrade.
    final bundle =
        Platform.isMacOS && Directory('$bundleRoot/$architecture').existsSync()
            ? '$bundleRoot/$architecture'
            : bundleRoot;
    return {
      'package': !kReleaseMode && _packageOverride.isNotEmpty
          ? _packageOverride
          : '$bundle/dsh-runtime',
      'node': !kReleaseMode && _nodeOverride.isNotEmpty
          ? _nodeOverride
          : '$bundle/node/${Platform.isWindows ? 'node.exe' : 'bin/node'}',
    };
  }

  static Map<String, String> _hostEnvironment() => {
        for (final name in [
          'HOME',
          'USERPROFILE',
          'SystemRoot',
          'WINDIR',
          'TEMP',
          'TMP',
          'ProgramFiles',
          'ProgramFiles(x86)',
          'LOCALAPPDATA'
        ])
          if (Platform.environment[name] != null)
            name: Platform.environment[name]!,
        'LANG': 'en_US.UTF-8',
      };

  Future<Map<String, bool>> checkComponents() async {
    final paths = componentPaths;
    final missing = <String, bool>{
      'node': false,
      'engine': false,
      'office': false,
      'browser': false,
      'isolation': false
    };
    if (!await File(paths['node']!).exists()) return missing;
    try {
      final result = await Process.run(paths['node']!,
              ['${paths['package']}/dist/desktop/main.js', '--self-check'],
              environment: _hostEnvironment(), includeParentEnvironment: false)
          .timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) return missing;
      final checks =
          (jsonDecode(result.stdout as String) as Map)['checks'] as Map;
      return {for (final key in missing.keys) key: checks[key] == true};
    } catch (_) {
      return missing;
    }
  }

  Future<void> _start() async {
    if (!supported) throw StateError('请在电脑端使用本机数字员工');
    final generation = ++_generation;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
    final who = identity(token);
    if (who == null) {
      errorMessage = '请登录企业后使用本机数字员工';
      throw StateError(errorMessage);
    }
    _scope = _identityKey(who);
    _storageScope = '${who['tenant']}:${who['account']}';
    _armSupervision();
    status = 'starting';
    errorMessage = '';
    notifyListeners();
    void checkCurrent() {
      if (_generation != generation) throw StateError('本机运行登录已变化');
    }

    try {
      if (Platform.isMacOS) {
        final version =
            await Process.run('/usr/bin/sw_vers', ['-productVersion']);
        final parts =
            '${version.stdout}'.trim().split('.').map(int.tryParse).toList();
        if (version.exitCode != 0 ||
            parts.length < 2 ||
            parts[0] == null ||
            parts[1] == null) {
          throw StateError('无法确认系统版本，请检查本机运行组件');
        }
        if (parts[0]! < 13 || (parts[0] == 13 && parts[1]! < 5)) {
          throw StateError('本机运行需要 macOS 13.5 或更新版本；当前系统可使用云端员工');
        }
        checkCurrent();
      }
      final paths = componentPaths;
      final package = paths['package']!;
      final node = paths['node']!;
      final entry = '$package/dist/desktop/main.js';
      if (!await File(node).exists() || !await File(entry).exists()) {
        throw StateError('本机运行组件尚未安装，请安装包含本机运行组件的桌面版本');
      }
      final environment = _hostEnvironment();
      final installationId =
          await LocalInstallationStore.loadOrCreate(AppConfig.apiUrl());
      checkCurrent();
      final support = await getApplicationSupportDirectory();
      final documents = await getApplicationDocumentsDirectory();
      checkCurrent();
      final process = await Process.start(node, [entry],
          environment: environment, includeParentEnvironment: false);
      if (_generation != generation) {
        process.kill();
        throw StateError('本机运行登录已变化');
      }
      _process = process;
      final ready = Completer<void>();
      process.stderr.drain<
          void>(); // Helper/engine stderr is never copied into diagnostics with secrets or file paths.
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (_process != process) return;
        try {
          final event = (jsonDecode(line) as Map).cast<String, dynamic>();
          switch (event['type']) {
            case 'computer_request':
              unawaited(_handleComputer(process, event));
            case 'computer_cancel':
              if (Platform.isMacOS) {
                unawaited(_computer.invokeMethod<void>('cancel', {
                  'id': event['id'],
                  'session': '${process.pid}',
                }).catchError((_) {}));
              }
            case 'ready':
              final uri = Uri.parse('${event['url']}');
              if (uri.scheme != 'http' ||
                  uri.host != '127.0.0.1' ||
                  !uri.hasPort ||
                  uri.userInfo.isNotEmpty) {
                throw const FormatException();
              }
              _ipc = Dio(BaseOptions(
                  baseUrl: uri.toString(),
                  headers: {'Authorization': 'Bearer ${event['key']}'},
                  connectTimeout: const Duration(seconds: 5),
                  receiveTimeout: const Duration(seconds: 10),
                  followRedirects: false));
              deviceId = '${event['device']}';
              availableEngines = event['engines'] is Map
                  ? Map<String, String>.from(event['engines'] as Map)
                  : const {'dsh': 'legacy'};
              status = 'online';
              errorMessage = '';
              if (!ready.isCompleted) ready.complete();
            case 'approval':
              approvals['${event['id']}'] = event;
            case 'results_saved':
              final conversation = '${event['conversation'] ?? ''}';
              if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(conversation)) {
                _resultsSaved.add(conversation);
              }
            case 'run':
              final run = '${event['run']}';
              final kind = '${event['event']}';
              if (['message.completed', 'message.failed', 'message.cancelled']
                  .contains(kind)) {
                activeRuns.remove(run);
                approvals.removeWhere((_, value) => value['run'] == run);
              } else {
                activeRuns[run] = '${event['conversation']}';
              }
            case 'error':
              final code = '${event['code']}';
              if (kDebugMode &&
                  RegExp(r'^local\.[a-z_]{1,80}$').hasMatch(code)) {
                debugPrint('[LocalAgent] helper code=$code');
              }
              errorMessage = '本机运行组件未就绪，请检查版本、登录和系统授权后重试';
              if (!ready.isCompleted) {
                ready.completeError(StateError(errorMessage));
              }
            case 'status':
              status = '${event['status']}';
          }
          notifyListeners();
        } catch (_) {
          if (!ready.isCompleted) {
            ready.completeError(StateError('本机运行组件返回无效状态'));
          }
        }
      }, onError: (_) {
        if (!ready.isCompleted) ready.completeError(StateError('本机运行组件连接中断'));
      });
      unawaited(process.exitCode.then((_) {
        _cancelComputer(process);
        if (!ready.isCompleted) ready.completeError(StateError('本机运行组件已退出'));
        if (_process == process) {
          _process = null;
          _ipc?.close(force: true);
          _ipc = null;
          status = 'offline';
          deviceId = '';
          availableEngines = const {};
          approvals.clear();
          activeRuns.clear();
          notifyListeners();
        }
      }));
      _power.setMethodCallHandler((call) async {
        if (call.method == 'willSleep') await stop();
      });
      process.stdin.writeln(jsonEncode({
        'type': 'initialize',
        'baseURL':
            AppConfig.apiUrl().replaceFirst('://localhost:', '://127.0.0.1:'),
        'accessToken': token,
        'installationId': installationId,
        ...who,
        'privateRoot': '${support.path}/local-agent',
        'documentsRoot': documents.path
      }));
      await process.stdin.flush();
      await ready.future
          .timeout(Duration(seconds: Platform.isWindows ? 90 : 30));
      checkCurrent();
      _retryAttempt = 0;
      _nextRetryAt = null;
      needsManualReconnect = false;
      _armSupervision();
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
            '[LocalAgent] startup failure type=${error.runtimeType}${error is PlatformException ? ' code=${error.code} status=${error.details is int ? error.details : 'unknown'}' : ''}');
      }
      if (_generation == generation) {
        await stop();
        errorMessage = error is StateError
            ? error.message.toString()
            : '本机运行组件启动失败，请检查系统授权和登录状态';
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> control(
      String path, Map<String, dynamic> body) async {
    if (!online || _ipc == null) throw StateError('这台电脑的运行组件未连接');
    final response = await _ipc!.post<dynamic>(path, data: body);
    return (response.data as Map).cast<String, dynamic>();
  }

  Future<String?> saveArtifact(LocalArtifactSource source,
      {String name = '本地产物'}) async {
    final target = await getSaveLocation(suggestedName: name);
    if (target == null) return null;
    final loader = AttachmentPreviewLoader();
    try {
      final bytes = await loader.read(
          AttachmentPreviewTarget(url: source.url, name: name), 'file',
          maxBytes: 128 * 1024 * 1024);
      await XFile.fromData(bytes, name: name).saveTo(target.path);
    } finally {
      loader.dispose();
    }
    return target.path;
  }

  Future<void> uploadArtifact(LocalArtifactSource source,
      {required String name,
      required String mime,
      required int generation,
      required CancelToken cancel}) async {
    void check() {
      if (generation != _generation || !online || cancel.isCancelled) {
        throw StateError('登录或文件已变化，请重新确认上传');
      }
    }

    check();
    _uploads.add(cancel);
    Dio? api;
    Dio? storage;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
      check();
      final who = identity(token);
      if (who == null || _identityKey(who) != _scope) {
        throw StateError('登录已变化，请重新确认上传');
      }
      // No global interceptor can replace this upload's account or environment.
      api = Dio(BaseOptions(
          baseUrl: AppConfig.apiUrl(),
          headers: {'Authorization': 'Bearer $token', 'X-API-Version': '2.0'},
          followRedirects: false,
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(minutes: 3)));
      storage = Dio(BaseOptions(
          followRedirects: false,
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(minutes: 3)));
      final bytes = await readArtifact(source, 128 * 1024 * 1024, cancel);
      check();
      await DriveBytesUpload(api: api, storage: storage).toPersonal(
          bytes: bytes,
          name: name,
          mime: mime.isEmpty ? 'application/octet-stream' : mime,
          cancel: cancel);
      check();
    } finally {
      _uploads.remove(cancel);
      api?.close(force: true);
      storage?.close(force: true);
    }
  }

  Future<void> openDirectory(String path) async {
    if (!await Directory(path).exists()) throw StateError('目录不存在');
    final result = await Process.run(
        Platform.isMacOS ? '/usr/bin/open' : 'explorer.exe', [path]);
    if (result.exitCode != 0) throw StateError('无法打开目录');
  }

  Future<void> revealArtifact(LocalArtifactSource source) async {
    await ensureReady();
    final original =
        await control('/app/artifacts/original', source.toRequest());
    final path = original['path'] as String;
    final result = await Process.run(
        Platform.isMacOS ? '/usr/bin/open' : 'explorer.exe',
        Platform.isMacOS ? ['-R', path] : ['/select,', path]);
    if (result.exitCode != 0) throw StateError('原文件不可用，请另存后查看');
  }

  Future<Uint8List> readArtifact(
      LocalArtifactSource source, int limit, CancelToken cancel) async {
    await ensureReady();
    if (cancel.isCancelled || _ipc == null) throw StateError('预览已取消');
    final response = await _ipc!.post<ResponseBody>('/app/artifacts/read',
        data: source.toRequest(),
        cancelToken: cancel,
        options: Options(responseType: ResponseType.stream));
    final body = response.data!;
    final length = int.tryParse(body.headers['content-length']?.first ?? '');
    if (length != null && length > limit) {
      await body.stream.listen((_) {}).cancel();
      throw StateError('文件超过预览大小限制，请另存后打开');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final part in body.stream) {
      if (cancel.isCancelled || bytes.length + part.length > limit) {
        throw StateError('预览已取消或文件超过大小限制');
      }
      bytes.add(part);
    }
    final result = bytes.takeBytes();
    verifyArtifactHash(result, source.sha256);
    return result;
  }

  Future<String> contextId(String conversation) async {
    final prefs = await SharedPreferences.getInstance();
    final who = identity(prefs.getString(AppConfig.storageTokenKey) ?? '');
    if (who == null) throw StateError('请重新登录');
    _storageScope = '${AppConfig.apiUrl()}:${who['tenant']}:${who['account']}';
    final key = 'local_context:$_storageScope:$conversation';
    final remote = await LocalRuntimeApi().conversation(conversation);
    final canonical = '${remote['context_id'] ?? ''}';
    if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(canonical)) {
      _contexts[key] = canonical;
      await prefs.setString(key, canonical);
      return canonical;
    }
    final cached = _contexts[key];
    if (cached != null) return cached;
    final old = prefs.getString(key);
    if (old != null) return _contexts.putIfAbsent(key, () => old);
    final value = _contexts.putIfAbsent(key, () => const Uuid().v4());
    await prefs.setString(key, value);
    return value;
  }

  Future<Map<String, dynamic>> workspace(
      String employee, String conversation, String name) async {
    await ensureReady();
    final generation = _generation;
    String context;
    try {
      context = await contextId(conversation);
    } catch (error) {
      throw LocalWorkspaceError.from(error);
    }
    if (_generation != generation) throw StateError('本机运行登录已变化');
    try {
      return await control('/app/workspaces/default',
          {'employee': employee, 'conversation': context, 'name': name});
    } catch (error) {
      throw LocalWorkspaceError.from(error, contextId: context);
    }
  }

  Future<String> modelForConversation(String conversation) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('local_model:$_storageScope:$conversation') ?? '';
  }

  Future<void> setModel(String conversation, String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('local_model:$_storageScope:$conversation', model);
    notifyListeners();
  }

  Future<void> adoptConversation(String previous, String next) async {
    if (previous == next) return;
    final prefs = await SharedPreferences.getInstance();
    final context = await contextId(previous);
    final key = 'local_context:$_storageScope:$next';
    _contexts[key] = context;
    await prefs.setString(key, context);
    await setModel(next, await modelForConversation(previous));
  }

  Future<void> _handleComputer(
      Process process, Map<String, dynamic> event) async {
    if (_process != process) return;
    final id = event['id'];
    if (id is! String || !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) return;
    final response = <String, dynamic>{'type': 'computer_result', 'id': id};
    try {
      if (!Platform.isMacOS) {
        throw PlatformException(code: 'local.computer_unsupported');
      }
      response['result'] = await _computer.invokeMethod<Object?>('execute', {
        ...event,
        'session': '${process.pid}',
      });
    } on PlatformException catch (error) {
      response['error'] = RegExp(r'^local\.[a-z_]{1,80}$').hasMatch(error.code)
          ? error.code
          : 'local.computer_failed';
    } catch (_) {
      response['error'] = 'local.computer_unavailable';
    }
    if (_process == process) {
      try {
        process.stdin.writeln(jsonEncode(response));
      } catch (_) {/* Parent is closing. */}
    }
  }

  void _cancelComputer(Process? process) {
    if (process != null && Platform.isMacOS) {
      unawaited(_computer.invokeMethod<void>('cancelSession', {
        'session': '${process.pid}'
      }).catchError((_) {}));
    }
  }

  Future<void> answerApproval(Map<String, dynamic> approval, bool approved,
      {String scope = 'once'}) async {
    await control('/app/runs/${approval['run']}/approvals/${approval['id']}', {
      'revision': approval['revision'],
      'approved': approved,
      'scope': scope
    });
    approvals.remove('${approval['id']}');
    notifyListeners();
  }

  Future<void> stop() async {
    ++_generation;
    for (final upload in _uploads) {
      upload.cancel('本机运行已停止');
    }
    final process = _process;
    _cancelComputer(process);
    _process = null;
    _ipc?.close(force: true);
    _ipc = null;
    status = 'offline';
    deviceId = '';
    availableEngines = const {};
    approvals.clear();
    activeRuns.clear();
    if (process != null) {
      try {
        process.stdin.writeln('{"type":"stop"}');
        await process.stdin.flush();
        await process.stdin.close();
      } catch (_) {
        process.kill();
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    }
    notifyListeners();
  }
}
