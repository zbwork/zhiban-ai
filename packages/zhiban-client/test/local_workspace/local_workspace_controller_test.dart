import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_attachment.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';

class RecordingClient extends LocalModelClient {
  String? systemPrompt;
  List<Map<String, String>>? contextMessages;
  bool fail = false;
  String? selectedModel;
  String? selectedProvider;
  @override
  Future<String> complete(
      {required AiProviderConfig provider,
      required AiEndpointType protocol,
      required String model,
      required String apiKey,
      required String system,
      required List<Map<String, String>> messages,
      required CancelToken cancelToken}) async {
    systemPrompt = system;
    selectedModel = model;
    selectedProvider = provider.id;
    contextMessages = messages;
    if (fail) throw const LocalModelException('模型请求失败');
    return '真实测试回复';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(ModelServiceStore.clearApiKeyMemoryCache);
  tearDown(ModelServiceStore.clearApiKeyMemoryCache);
  setUp(() async {
    final root = await Directory.systemTemp.createTemp('controller-key-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
      await root.delete(recursive: true);
    });
  });
  test('permissions persist per employee while full access resets on restart',
      () async {
    sqfliteFfiInit();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath, skills: []);
    final c = LocalWorkspaceController(store, modelClient: RecordingClient());
    final first = <String, Object?>{
      'id': 'first',
      'name': '甲',
      'prompt': '',
      'provider_id': '',
      'model_id': '',
      'skills': '[]',
      'created': 1
    };
    final second = {...first, 'id': 'second'};
    await c.saveEmployee(first);
    await c.saveEmployee(second);
    expect(c.permissionMode(first), 'assist');
    await c.setPermission(first, 'ask');
    final saved = c.employees.firstWhere((e) => e['id'] == 'first');
    expect(c.permissionMode(saved), 'ask');
    expect(c.permissionMode(second), 'assist');
    final restarted =
        LocalWorkspaceController(store, modelClient: RecordingClient());
    expect(restarted.permissionMode(saved), 'ask');
    await c.setPermission(saved, 'full');
    final full = c.employees.firstWhere((e) => e['id'] == 'first');
    expect(c.permissionMode(full), 'full');
    expect(jsonDecode(full['metadata'] as String)['permission_mode'], 'assist');
    expect(restarted.permissionMode(full), 'assist');
    await c.saveEmployee({
      ...full,
      'metadata': jsonEncode({
        ...jsonDecode(full['metadata'] as String) as Map,
        'workspace': '/tmp/work'
      })
    });
    expect(c.permissionMode(c.employees.firstWhere((e) => e['id'] == 'first')),
        'full');
    await c.setPermission(full, 'assist');
    expect(c.permissionMode(full), 'assist');
    await expectLater(c.setPermission(first, 'invalid'), throwsArgumentError);
    c.dispose();
    restarted.dispose();
    await store.db.close();
  });
  test(
      'employee skills and history reach chosen model; failures persist without entering context',
      () async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const configs = ModelServiceStore();
    await configs.saveProviders([
      const AiProviderConfig(
          id: 'p',
          name: '测试',
          enabled: true,
          baseUrl: 'https://example.com/v1',
          models: [AiModelConfig(id: 'm', modelId: 'chat', displayName: '聊天')])
    ]);
    await configs.setApiKey('p', 'key');
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
        skills: [
          {'id': 's', 'name': '总结', 'description': '总结', 'prompt': '绑定技能内容'},
        ]);
    final model = RecordingClient();
    final controller = LocalWorkspaceController(store, modelClient: model);
    final employee = <String, Object?>{
      'id': 'e',
      'name': '助手',
      'prompt': '员工角色',
      'provider_id': 'p',
      'model_id': 'chat',
      'skills': '["s"]',
      'created': 1
    };
    await controller.saveEmployee(employee);
    model.fail = true;
    await controller.send(employee, '第一问');
    expect((await store.messages('e')).last['status'], 'failed');
    model.fail = false;
    await store.addMessage('e', 'user', '',
        attachments: jsonEncode([
          {
            'name': '报价.txt',
            'path': '/private/local-only/报价.txt',
            'size': 12,
            'text': '合同报价 200 元'
          }
        ]));
    await controller.send(employee, '第二问');
    expect(model.systemPrompt, allOf(contains('员工角色'), contains('绑定技能内容')));
    expect(model.contextMessages!.first['content'], '第一问');
    expect(model.contextMessages![1]['content'], contains('合同报价 200 元'));
    expect(model.contextMessages.toString(),
        isNot(contains('/private/local-only')));
    expect(model.contextMessages!.last['content'], '第二问');
    expect(model.selectedModel, 'chat');
    expect(model.selectedProvider, 'p');
    expect((await store.messages('e')).last['content'], '真实测试回复');
    expect(controller.busy('e'), isFalse);
    // A scheduled run must use the very same employee model/persona/skills path.
    final beforeTask = (await store.messages('e')).length;
    final job = await controller.tasks.createJob(CronJobDraft(
        name: '定时总结',
        description: '',
        agentId: 'e',
        conversationUuid: 'direct-agent:e',
        enabled: true,
        scheduleType: 'cron',
        interval: 1,
        intervalUnit: 'minute',
        schedule: '* * * * *',
        sessionTarget: 'isolated',
        payloadKind: 'agentTurn',
        message: '定时任务内容',
        wakeMode: 'now',
        timeout: null,
        deliveryMode: 'none',
        deliveryChannel: '',
        deliveryRecipient: ''));
    Future<LocalRow?>? competingChat;
    void raceChat() {
      if (controller.busy('e') && competingChat == null) {
        competingChat = controller.send(employee, '不应抢占的聊天');
      }
    }

    controller.addListener(raceChat);
    await controller.tasks.runJobNow(job.id);
    expect(competingChat, isNotNull);
    expect(await competingChat!, isNull);
    controller.removeListener(raceChat);
    for (var i = 0; i < 100; i++) {
      final runs = await controller.tasks.listRecentRuns();
      if (runs.isNotEmpty && runs.first.status == 'ok') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await controller.tasks.listRecentRuns()).single.status, 'ok');
    expect((await store.messages('e')).length, beforeTask + 2);
    expect(model.contextMessages!.last['content'], '定时任务内容');
    expect(model.systemPrompt, allOf(contains('员工角色'), contains('绑定技能内容')));
    expect(model.selectedModel, 'chat');

    final dir = await Directory.systemTemp.createTemp('community-send-file-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => dir.path);
    try {
      final source =
          await File('${dir.path}/input.txt').writeAsString('附件独立发送内容');
      final attachment = await LocalAttachmentService().read(source.path);
      var accepted = false;
      await controller.send(employee, '',
          attachments: [attachment], onAccepted: () => accepted = true);
      expect(accepted, isTrue);
      expect(model.contextMessages!.last['content'], contains('附件独立发送内容'));
      final rows = await store.messages('e');
      final stored =
          LocalAttachment.decode(rows[rows.length - 2]['attachments']).single;
      await source.delete();
      expect(await File(stored.path).readAsString(), '附件独立发送内容');
      expect(model.contextMessages.toString(), isNot(contains(dir.path)));
      final private = await Directory('${dir.path}/community-runtime/e/outputs')
          .create(recursive: true);
      await File('${private.path}/result.txt').writeAsString('private result');
      final other =
          await File('${dir.path}/other-employee.txt').writeAsString('keep');
      var overflowAccepted = false;
      final beforeOverflow = (await store.messages('e')).length;
      await expectLater(
          controller.send(employee, 'x' * 150001,
              onAccepted: () => overflowAccepted = true),
          throwsA(isA<LocalModelException>()));
      expect(overflowAccepted, isFalse);
      expect((await store.messages('e')).length, beforeOverflow);
      await controller.deleteEmployee('e');
      expect(await File(stored.path).exists(), isFalse);
      expect(await private.exists(), isFalse);
      expect(await other.readAsString(), 'keep');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      await dir.delete(recursive: true);
    }
    controller.dispose();
    await store.db.close();
  });
}
