import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../../../services/local_agent_service.dart';
import '../../model_service/models/ai_endpoint_type.dart';
import '../../model_service/models/ai_provider_config.dart';
import 'local_model_client.dart';
import 'local_workspace_store.dart';
import 'local_attachment.dart';
import 'package:crypto/crypto.dart';

typedef CommunityApproval = Future<bool> Function(
    Map<String, dynamic> approval);

/// One supervised helper per in-flight turn. Credentials only cross anonymous stdin.
class CommunityRuntime {
  Future<Map<String, dynamic>> run({
    required AiProviderConfig provider,
    required AiEndpointType protocol,
    required String apiKey,
    required String model,
    required String employee,
    required String name,
    required String messageId,
    required String engine,
    String? workspace,
    String? skillsDir,
    List<LocalAttachment> attachments = const [],
    required String message,
    required String persona,
    required String history,
    required CancelToken cancelToken,
    required CommunityApproval approve,
    required void Function(Map<String, dynamic>) onEvent,
  }) async {
    final paths = LocalAgentService.instance.componentPaths;
    final entry = '${paths['package']}/dist/desktop/community.js';
    if (!File(entry).existsSync() || !File(paths['node']!).existsSync()) {
      throw const LocalModelException('本地运行组件缺失，请重新构建或更新客户端');
    }
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final process = await Process.start(paths['node']!, [entry],
        includeParentEnvironment: false,
        environment: {
          for (final key in [
            'HOME',
            'USERPROFILE',
            'SystemRoot',
            'WINDIR',
            'TEMP',
            'TMP',
            'LOCALAPPDATA'
          ])
            if (Platform.environment[key] != null)
              key: Platform.environment[key]!,
          'LANG': 'en_US.UTF-8',
        });
    final ready = Completer<void>();
    final result = Completer<Map<String, dynamic>>();
    unawaited(result.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    final runId = LocalWorkspaceStore.uuid.v4();
    final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 15)));
    var submitted = false;
    var closed = false;
    void write(Map<String, dynamic> input) =>
        process.stdin.writeln(jsonEncode(input));
    void fail(String message) {
      if (!ready.isCompleted) {
        ready.completeError(LocalModelException(message));
      } else if (!result.isCompleted) {
        result.completeError(LocalModelException(message));
      }
    }

    Future<void> cancel() async {
      if (closed) return;
      if (!ready.isCompleted) {
        ready.completeError(const LocalModelException('已停止生成'));
        await process.stdin.close();
        return;
      }
      if (submitted) {
        try {
          await dio
              .post<dynamic>('/app/runs/$runId/cancel', data: {'fence': 1});
        } catch (_) {}
      }
      if (!result.isCompleted) {
        result.completeError(const LocalModelException('已停止生成'));
      }
      process.stdin.close();
    }

    final subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final input = jsonDecode(line) as Map<String, dynamic>;
        switch (input['type']) {
          case 'ready':
            final uri = Uri.parse(input['url'] as String);
            if (uri.scheme != 'http' ||
                uri.host != '127.0.0.1' ||
                !uri.hasPort ||
                uri.userInfo.isNotEmpty ||
                !['', '/'].contains(uri.path)) {
              fail('本地连接组件地址无效');
              return;
            }
            dio.options.baseUrl = uri.origin;
            dio.options.headers['Authorization'] = 'Bearer ${input['key']}';
            if (!ready.isCompleted) ready.complete();
          case 'error':
            final code = input['code'];
            fail(code == 'local.isolation_unavailable'
                ? '本地执行隔离组件不可用，请检查运行组件'
                : code == 'local.model_protocol_mismatch'
                    ? '当前模型协议不支持所选引擎，Codex 需要支持 Responses 的服务商'
                    : '本地执行未能启动（$code）');
          case 'event':
            onEvent(input['frame'] as Map<String, dynamic>);
          case 'approval':
            unawaited(() async {
              var allowed = false;
              try {
                allowed = !cancelToken.isCancelled && await approve(input);
              } catch (_) {}
              if (cancelToken.isCancelled || result.isCompleted) return;
              try {
                await dio.post<dynamic>(
                    '/app/runs/$runId/approvals/${input['id']}',
                    data: {
                      'revision': input['revision'],
                      'approved': allowed,
                      'scope': 'once'
                    });
              } catch (_) {}
            }());
          case 'result':
            if (!result.isCompleted) result.complete(input);
        }
      } catch (_) {
        fail('本地运行组件返回数据异常');
      }
    }, onError: (_) => fail('本地运行组件连接中断'));
    // Never forward raw helper stderr, which may include upstream response details.
    final errors = process.stderr.listen((_) {});
    unawaited(process.exitCode.then((_) => fail('本地运行组件已退出，请重试')));
    unawaited(cancelToken.whenCancel.then((_) => cancel()));
    try {
      write({
        'type': 'initialize',
        'privateRoot': '${support.path}/community-runtime/$employee',
        'documentsRoot': documents.path
      });
      await ready.future.timeout(const Duration(seconds: 45));
      if (cancelToken.isCancelled) throw const LocalModelException('已停止生成');
      submitted = true;
      write({
        'type': 'submit',
        'id': runId,
        'employee': employee,
        'name': name,
        'messageId': messageId,
        'engine': engine,
        if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
        if (skillsDir != null) 'skillsDir': skillsDir,
        'attachments': [
          for (final file in attachments)
            {
              'name': file.name,
              'path': await File(file.path).resolveSymbolicLinks(),
              'size': file.size,
              'sha256': sha256
                  .convert(await File(file.path).readAsBytes())
                  .toString(),
            }
        ],
        'model': model,
        'message': message,
        'persona': persona,
        'history': history,
        'route': {
          'baseURL': provider.baseUrl,
          'apiKey': apiKey,
          'headers': provider.customHeaders,
          'protocol': protocol == AiEndpointType.anthropicMessages
              ? 'anthropic-messages'
              : 'openai-compatible'
        }
      });
      final value = await result.future.timeout(const Duration(minutes: 16));
      if (cancelToken.isCancelled) throw const LocalModelException('已停止生成');
      return value;
    } finally {
      closed = true;
      await process.stdin.close().catchError((_) {});
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } catch (_) {
        process.kill();
      }
      await subscription.cancel();
      await errors.cancel();
      dio.close(force: true);
    }
  }
}
