import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:zhiban_client/pages/chat/widgets/desktop_drop.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_page.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_host.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_history_panel.dart';
import 'package:zhiban_client/pages/skills/widgets/skills_tab_switcher.dart';
import 'package:zhiban_client/pages/skills/widgets/my_skills_view.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_detail_content.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_detail_dialog.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_install_agent_dialog.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_message_list.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:zhiban_client/pages/skills/widgets/skills_filters_bar.dart';
import 'package:zhiban_client/pages/chat/widgets/create_agent_dialog.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_picker_dialog.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

class RejectNetwork extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('Unexpected network');
  }
}

class PendingLocalModel extends LocalModelClient {
  Completer<String>? reply;
  @override
  Future<String> complete(
      {required AiProviderConfig provider,
      required AiEndpointType protocol,
      required String model,
      required String apiKey,
      required String system,
      required List<Map<String, String>> messages,
      required CancelToken cancelToken}) async {
    reply = Completer<String>();
    final text = await reply!.future;
    if (cancelToken.isCancelled) throw const LocalModelException('已停止回复');
    return text;
  }
}

void main() {
  testWidgets(
      'local routes reuse original UI; only marketplace attempts public catalog',
      (tester) async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final support = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('workspace-ui-')))!;
    const supportChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(supportChannel, (_) async => support.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(supportChannel, null);
      await support.delete(recursive: true);
    });
    await const ModelServiceStore().saveProviders([
      AiProviderConfig(
        id: 'p',
        name: '本地模型',
        enabled: true,
        models: [
          const AiModelConfig(id: 'm', modelId: 'chat', displayName: '对话'),
          const AiModelConfig(
              id: 'm2', modelId: 'other-chat', displayName: '第二模型'),
          const AiModelConfig(
              id: 'm3', modelId: 'text-embedding-3-small', displayName: '向量模型'),
        ],
      )
    ]);
    final store = (await tester.runAsync(() => LocalWorkspaceStore.open(
            factory: databaseFactoryFfi,
            path: inMemoryDatabasePath,
            skills: [
              {
                'id': 's',
                'name': '内容总结',
                'description': '总结文本',
                'prompt': '总结输入内容'
              },
              {
                'id': 'browser-tools',
                'name': '浏览器工具',
                'description': '浏览器技能目录',
                'prompt': '',
                'category_id': 2,
                'executable': 0,
              },
            ])))!;
    final model = PendingLocalModel();
    final controller = LocalWorkspaceController(store, modelClient: model);
    // The employee catalog transport is covered separately with deterministic fixtures.
    controller.employeeCatalogAttempted = true;
    await tester.runAsync(() => controller.saveEmployee({
          'id': 'e',
          'name': '本地助手',
          'prompt': '帮助用户',
          'provider_id': 'p',
          'model_id': 'chat',
          'skills': '["s"]',
          // SVG avoids network I/O in this projection regression; decoding is
          // checked separately against the deployed PNG/JPEG catalog.
          'metadata':
              jsonEncode({'avatar_url': 'https://catalog.example/avatar.svg'}),
          'created': 1,
        }));
    await tester.runAsync(() => store.addMessage('e', 'user', '已保存的问题'));
    await tester.runAsync(() => store.addMessage('e', 'assistant', '已保存的回复'));
    final catalog =
        (await tester.runAsync(() => const ModelCatalogLoader().load()))!;
    final attachmentDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('community-ui-file-')))!;
    final attachmentFile = (await tester.runAsync(
        () => File('${attachmentDir.path}/测试.txt').writeAsString('附件中的测试内容')))!;
    addTearDown(() => attachmentDir.delete(recursive: true));
    final network = RejectNetwork();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.binding.setSurfaceSize(const Size(1200, 820));
      await tester.pumpWidget(ProviderScope(overrides: [
        localWorkspaceProvider.overrideWith((ref) async => controller),
        localAttachmentPickerProvider
            .overrideWithValue(() async => [attachmentFile.path]),
        modelCatalogProvider.overrideWith((ref) async => catalog),
      ], child: const LocalWorkspaceApp()));
      await tester.pump();
      // SQLite FFI uses a real worker, outside testWidgets' fake clock.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(ChatSessionView), findsOneWidget);
      expect(find.byType(PromptInput), findsOneWidget);
      expect(find.byType(AttachmentPreviewHost), findsOneWidget);
      expect(
          tester
              .widget<ConversationListPanel>(find.byType(ConversationListPanel))
              .conversations
              .single
              .agentAvatarUrl,
          'https://catalog.example/avatar.svg');
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .agentAvatarUrl,
          'https://catalog.example/avatar.svg');
      expect(
          tester
              .widget<ChatMessageList>(find.byType(ChatMessageList))
              .agentAvatarUrl,
          'https://catalog.example/avatar.svg');
      await tester.runAsync(() => controller.saveEmployee({
            ...controller.employees.single,
            'metadata': '{}',
          }));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ConversationListPanel>(find.byType(ConversationListPanel))
              .conversations
              .single
              .agentAvatarUrl,
          isNull);
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .agentAvatarUrl,
          isNull);
      expect(
          tester
              .widget<ChatMessageList>(find.byType(ChatMessageList))
              .agentAvatarUrl,
          isNull);
      final originalInputState = tester.state(find.byType(PromptInput));
      final attachmentSession =
          tester.widget<ChatSessionView>(find.byType(ChatSessionView));
      expect(attachmentSession.sentTextHistory, ['已保存的问题']);
      expect(attachmentSession.autoScrollOnMessageUpdate, isFalse);
      expect(
          tester
              .widget<ChatMessageList>(find.byType(ChatMessageList))
              .autoScrollOnMessageUpdate,
          isFalse);
      expect(
          tester.widget<PromptInput>(find.byType(PromptInput)).sentTextHistory,
          ['已保存的问题']);
      await tester.runAsync(() async {
        attachmentSession.onPickAttachment!(ChatAttachmentPickKind.files);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      final composer = tester
          .widget<ChatSessionView>(find.byType(ChatSessionView))
          .controller!;
      expect(
          identical(tester.state(find.byType(PromptInput)), originalInputState),
          isTrue);
      expect(find.text('该数字员工已删除，无法继续发送消息'), findsNothing);
      expect(composer.attachments.single.fileName, '测试.txt');
      expect(find.text('测试.txt'), findsWidgets);
      tester.widget<ChatSessionView>(find.byType(ChatSessionView)).sendGuard!();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(composer.attachments, hasLength(1));
      composer.removeAttachment(composer.attachments.single.id);
      await tester.pumpAndSettle();
      expect(composer.attachments, isEmpty);
      await tester.runAsync(() async {
        tester
            .widget<DesktopDrop>(find.byType(DesktopDrop))
            .onDropFiles([XFile(attachmentFile.path)]);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(composer.attachments.single.fileName, '测试.txt');
      expect(
          identical(tester.state(find.byType(PromptInput)), originalInputState),
          isTrue);
      composer.removeAttachment(composer.attachments.single.id);
      await tester.pumpAndSettle();
      await const ModelServiceStore().setApiKey('p', 'test-only-key');
      Future<void>? sending;
      await tester.runAsync(() async {
        sending = controller.send(controller.employees.first, '测试处理中状态');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      final busySession =
          tester.widget<ChatSessionView>(find.byType(ChatSessionView));
      expect(busySession.composerEnabled, isTrue);
      expect(busySession.state.isSending, isTrue);
      expect(busySession.state.messages.last.streamStartedAt, isNotNull);
      expect(find.text('该数字员工已删除，无法继续发送消息'), findsNothing);
      expect(find.byIcon(CupertinoIcons.stop_fill), findsOneWidget);
      expect(
          identical(tester.state(find.byType(PromptInput)), originalInputState),
          isTrue);
      // A new DB Future retains old pending rows until its completion. Removing
      // the runtime overlay must not make the displayed answer disappear.
      final pendingId = busySession.state.messages.last.localId;
      final messageListState = tester.state(find.byType(ChatMessageList));
      controller.liveText[pendingId] = '正在回复的正文，刷新时必须保留';
      controller.timelines[pendingId] = [
        ChatTimelineEntry(
            key: 'tool:refresh',
            kind: ChatTimelineKind.tool,
            title: '读取文件',
            startedAt: DateTime.now())
      ];
      await tester.runAsync(controller.refresh);
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .state
              .messages
              .last
              .content,
          '正在回复的正文，刷新时必须保留');
      await tester.runAsync(
          () => store.finishMessage(pendingId, '最终完成的回复正文', 'complete'));
      controller.liveText.remove(pendingId);
      controller.timelines.remove(pendingId);
      await tester.runAsync(controller.refresh);
      await tester.pump();
      final refreshing = tester
          .widget<ChatSessionView>(find.byType(ChatSessionView))
          .state
          .messages
          .last;
      expect(refreshing.content, isNotEmpty);
      expect(
          identical(
              tester.state(find.byType(ChatMessageList)), messageListState),
          isTrue);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .state
              .messages
              .last
              .content,
          '最终完成的回复正文');
      busySession.onStop();
      model.reply!.complete('忽略停止后的迟到回复');
      await tester.runAsync(() => sending!);
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .state
              .isSending,
          isFalse);
      expect(find.byIcon(CupertinoIcons.stop_fill), findsNothing);
      expect((await tester.runAsync(() => store.messages('e')))!.last['status'],
          'interrupted');
      await const ModelServiceStore().deleteApiKey('p');

      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ChatSessionView>(find.byType(ChatSessionView))
              .state
              .messages
              .map((m) => m.content),
          contains('已保存的问题'));
      await tester.tap(find.byTooltip('聊天历史'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryPanel), findsOneWidget);
      final router = GoRouter.of(tester.element(find.byType(ChatSessionView)));
      final search = find.descendant(
          of: find.byType(ConversationListHeader),
          matching: find.byType(EditableText));
      await tester.enterText(search, '无匹配员工');
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(ConversationListPanel));
      final emptyText = tester.getRect(find.text('暂无会话'));
      // Icon (120) + gap (16) + label: verify the entire empty group is centered.
      final groupCenter = (emptyText.top - 136 + emptyText.bottom) / 2;
      expect(groupCenter, closeTo(panel.center.dy, 2));
      router.go('/digital-employee');
      await tester.pumpAndSettle();
      expect(find.byType(AgentCard), findsOneWidget);
      for (final width in [900.0, 1200.0]) {
        await tester.binding.setSurfaceSize(Size(width, 820));
        await tester.pumpAndSettle();
        final card = tester.getRect(find.byType(AgentCard));
        final columns = ((width - 24 + 12) / (292 + 12)).floor();
        expect(card.left, closeTo(12, 0.1));
        expect(card.width,
            closeTo((width - 24 - 12 * (columns - 1)) / columns, 0.1));
        expect(tester.takeException(), isNull);
      }
      expect(find.text('添加更多'), findsOneWidget);
      await tester.tap(find.text('官方'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentCard), findsNothing);
      expect(find.text('添加更多'), findsOneWidget);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentCard), findsOneWidget);
      await tester.tap(find.text('新建数字员工'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateAgentDialog), findsOneWidget);
      expect(
          tester
              .widget<UiSelect<String>>(
                  find.byKey(const ValueKey('local-engine-select')))
              .enabled,
          isTrue);
      for (final label in [
        '数字员工名称',
        '主要职责',
        '人设（系统提示词）',
        '核心技能',
        '欢迎语',
        '标签',
        '运行位置',
        '本地引擎',
        '备注（可选）'
      ]) {
        expect(find.textContaining(label, findRichText: true), findsWidgets);
      }
      for (final label in ['应用', '知识库', '选择应用', '选择知识库', '云端']) {
        expect(find.text(label), findsNothing);
      }
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(find.text('请输入数字员工名称'), findsOneWidget);
      expect(find.text('请输入主要职责'), findsOneWidget);
      Future<void> fill(String hint, String value) async {
        final field = find.widgetWithText(UiInputField, hint);
        await tester.ensureVisible(field);
        await tester.enterText(
            find.descendant(of: field, matching: find.byType(EditableText)),
            value);
      }

      await fill('例如：招聘助手', '测试招聘员工');
      await fill('例如：帮助处理招聘流程与候选人答疑', '负责招聘答疑');
      await tester.ensureVisible(find.text('选择技能'));
      await tester.tap(find.text('选择技能'));
      await tester.pumpAndSettle();
      expect(find.byType(SkillPickerDialog), findsOneWidget);
      expect(find.text('内容总结'), findsWidgets);
      expect(find.text('浏览器工具'), findsNothing);
      await tester.tap(find.text('内容总结').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await fill('例如：你好，我是您的招聘助手，有任何问题都可以问我。', '欢迎咨询招聘');
      await fill('输入标签，按回车添加', '招聘，答疑');
      await fill('补充给团队成员或维护者看的配置说明，可选', '本地备注');
      expect(
          find.byKey(const ValueKey('local-agent-model-select')), findsNothing);
      await tester.tap(find.text('创建数字员工').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final created =
          controller.employees.firstWhere((e) => e['name'] == '测试招聘员工');
      expect(created['metadata'], contains('负责招聘答疑'));
      expect(created['metadata'], contains('欢迎咨询招聘'));
      expect(created['metadata'], contains('本地备注'));
      expect(created['prompt'], contains('负责招聘答疑'));
      expect(created['skills'], '["s"]');
      expect(created['provider_id'], isEmpty);
      expect(created['model_id'], isEmpty);
      final cards = find.byType(AgentCard);
      final firstCard = tester.getRect(cards.at(0));
      final secondCard = tester.getRect(cards.at(1));
      expect(firstCard.left, closeTo(12, 0.1));
      expect(secondCard.top, closeTo(firstCard.top, 0.1));
      expect(secondCard.left - firstCard.right, closeTo(12, 0.1));
      final createdCard = tester
          .widgetList<AgentCard>(find.byType(AgentCard))
          .firstWhere((card) => card.agent.name == '测试招聘员工');
      createdCard.onEdit();
      await tester.pumpAndSettle();
      expect(find.byType(CreateAgentDialog), findsOneWidget);
      final editor =
          tester.widget<CreateAgentEditor>(find.byType(CreateAgentEditor));
      expect(editor.initialDraft!.description, '负责招聘答疑');
      expect(editor.initialDraft!.welcomeMsg, '欢迎咨询招聘');
      expect(editor.initialDraft!.tags, ['招聘', '答疑']);
      expect(editor.initialDraft!.internalDescription, '本地备注');
      expect(editor.initialDraft!.systemPrompt, isEmpty);
      expect(editor.initialDraft!.localEngine, 'dsh');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(createdCard.sourceLabel, '我创建的');
      expect(find.byType(OpenClawDigitalEmployeeGallery), findsOneWidget);
      createdCard.onTap();
      await tester.pumpAndSettle();
      expect(find.byType(AgentDetailContent), findsOneWidget);
      await tester.tap(find.text('去聊天'));
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-chat-model-button')));
      await tester.pumpAndSettle();
      expect(find.text('向量模型'), findsNothing);
      await tester.tap(find.text('第二模型').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(
          controller.employees
              .firstWhere((e) => e['id'] == created['id'])['model_id'],
          'other-chat');
      expect(controller.employees.firstWhere((e) => e['id'] == 'e')['model_id'],
          'chat');
      expect(find.text('第二模型'), findsOneWidget);
      await tester
          .runAsync(() => controller.deleteEmployee(created['id'] as String));
      await tester.pumpAndSettle();
      expect(network.requests, 0);
      router.go('/inspire');
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(SkillCard), findsNothing);
      // Inject the current Bus projection for the original component checks.
      controller.marketSkillIds =
          controller.skills.map((s) => s['id'] as String).toSet();
      controller.catalogFromServer = true;
      controller.catalogError = null;
      await tester.runAsync(controller.refresh);
      await tester.pumpAndSettle();
      expect(find.byType(SkillCard), findsNWidgets(2));
      await tester.tap(find.text('浏览器工具').first);
      await tester.pumpAndSettle();
      expect(find.byType(SkillDetailDialog), findsOneWidget);
      expect(find.textContaining('添加时下载技能包'), findsOneWidget);
      Navigator.of(tester.element(find.textContaining('添加时下载技能包'))).pop();
      await tester.pumpAndSettle();
      tester
          .widget<SkillsFiltersBar>(find.byType(SkillsFiltersBar))
          .onCategoryChanged(2);
      await tester.pumpAndSettle();
      expect(find.byType(SkillCard), findsOneWidget);
      expect(tester.widget<SkillCard>(find.byType(SkillCard)).skill.slug,
          'browser-tools');
      tester
          .widget<SkillsFiltersBar>(find.byType(SkillsFiltersBar))
          .onCategoryChanged(null);
      await tester.pumpAndSettle();
      final skillSearch = find.descendant(
          of: find.byType(SkillsFiltersBar),
          matching: find.byType(EditableText));
      await tester.enterText(skillSearch, 'browser-tools');
      await tester.pumpAndSettle();
      expect(find.byType(SkillCard), findsOneWidget);
      await tester.enterText(skillSearch, '');
      await tester.pumpAndSettle();
      expect(find.byType(SkillsTabSwitcher), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      await tester.tap(find.text('我的技能'));
      await tester.pumpAndSettle();
      expect(find.byType(MySkillsView), findsOneWidget);
      expect(find.text('使用'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.text('还没有为数字员工添加技能'), findsOneWidget);
      await tester.tap(find.text('去技能广场看看'));
      await tester.pumpAndSettle();
      expect(find.byType(SkillCard), findsNWidgets(2));
      await tester.tap(find.descendant(
        of: find.ancestor(
            of: find.text('内容总结'), matching: find.byType(SkillCard)),
        matching: find.text('添加'),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(SkillInstallAgentDialog), findsOneWidget);
      await tester.tap(find.text('添加').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.text('使用'), findsOneWidget);
      await tester.tap(find.text('使用'));
      await tester.pumpAndSettle();
      expect(find.byType(SkillInstallAgentDialog), findsNothing);
      expect(find.byType(ChatSessionView), findsOneWidget);
      router.go('/task');
      await tester.pumpAndSettle();
      expect(find.text('当前入口未配置任务页面'), findsOneWidget);
      router.go('/drive');
      await tester.pumpAndSettle();
      expect(find.text('云盘需要登录后使用'), findsWidgets);
      router.go('/contacts');
      await tester.pumpAndSettle();
      expect(find.text('通讯录需要登录后使用'), findsWidgets);
      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('账号与安全'), findsNothing);
      expect(find.text('支持与服务'), findsNothing);
      expect(find.text('AI 与模型'), findsOneWidget);
      await tester.tap(find.text('模型服务'));
      await tester.pumpAndSettle();
      expect(find.text('API 密钥'), findsWidgets);
      // The public marketplace is the sole network exception; blocked network
      // shows no local fallback, without login/session requests.
      expect(network.requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    }, network);
    controller.dispose();
    await tester.runAsync(store.db.close);
  });
}
