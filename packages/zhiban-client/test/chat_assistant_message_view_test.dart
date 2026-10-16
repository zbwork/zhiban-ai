import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_assistant_message_view.dart';

void main() {
  test(
      'split history text hides a duplicate sandbox link but keeps raw history',
      () {
    const raw = '已交付\n\n[下载文件](sandbox:/mnt/data/report.md)';
    final message = ChatMessage.fromAgentBusJson({
      'uuid': 'local-history',
      'role': 'agent',
      'status': 'final',
      'blocks': [
        {'type': 'markdown', 'text': raw},
        {
          'type': 'file',
          'name': 'report.md',
          'mime': 'text/markdown',
          'size': 21,
          'local_artifact': {
            'artifact_id': '33333333-3333-4333-8333-333333333333',
            'device_id': '44444444-4444-4444-8444-444444444444',
            'sha256': 'a' * 64,
          },
        },
      ],
    });
    final item = ChatAssistantMessageViewData.fromMessage(message);
    expect(
        item.blocks.whereType<ChatAssistantTextBlock>().single.content, '已交付');
    expect(message.content, raw);
    expect(item.blocks.whereType<ChatAssistantEmpBlocksBlock>(), hasLength(1));
  });
  Widget wrap(
    ChatAssistantMessageViewData item, {
    VoidCallback? onStop,
    double width = 720,
    double? maxWidth,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: ChatAssistantMessageView(
            item: item,
            onStop: onStop,
            maxWidth: maxWidth,
          ),
        ),
      ),
    );
  }

  for (final status in ['streaming', 'awaiting_user', 'final', 'cancelled']) {
    testWidgets('$status answer shows provenance only after generation ends',
        (tester) async {
      final message = ChatMessage.fromAgentBusJson({
        'uuid': 'answer',
        'role': 'agent',
        'status': status,
        'blocks': [
          {'type': 'markdown', 'text': '这是回答'},
        ],
      });
      final item = ChatAssistantMessageViewData.fromMessage(message);
      await tester.pumpWidget(wrap(item, width: 320, maxWidth: 280));
      final finished = status != 'streaming';
      expect(find.text('AI 生成'), finished ? findsOneWidget : findsNothing);
      if (finished) {
        expect(tester.getTopLeft(find.text('AI 生成')).dy,
            greaterThan(tester.getTopLeft(find.text('这是回答')).dy));
      }
      expect(assistantPlainText(item), '这是回答');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final status in ['complete', 'partial']) {
    testWidgets('verified $status files survive final model failure',
        (tester) async {
      final message = ChatMessage.fromAgentBusJson({
        'uuid': 'failed-with-delivery',
        'role': 'agent',
        'status': 'failed',
        'error_code': 'model.tools_invalid',
        'blocks': [
          {
            'type': 'file',
            'name': 'report.pptx',
            'local_artifact': {
              'artifact_id': 'a',
              'device_id': 'd',
              'sha256': 'a' * 64
            }
          },
          {
            'type': 'local_delivery',
            'status': status,
            'verified_count': 1,
            'required_count': 1
          },
        ],
      });
      await tester
          .pumpWidget(wrap(ChatAssistantMessageViewData.fromMessage(message)));
      await tester.pump();
      expect(find.text('已保留文件'), findsOneWidget);
      expect(find.text(status == 'complete' ? '文件已生成，后续模型处理失败' : '部分文件已生成，任务未完成'),
          findsOneWidget);
      expect(find.textContaining('report.pptx'), findsOneWidget);
      expect(find.text('AI 生成'), findsOneWidget);
      expect(find.textContaining('模型服务调用失败'), findsNothing);
      expect(message.isError, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'failed history keeps reason beside answer and existing file card',
      (tester) async {
    final message = ChatMessage.fromAgentBusJson({
      'uuid': 'failed-office',
      'role': 'agent',
      'status': 'failed',
      'error_code': 'chat.deliverable_content_mismatch',
      'error_message': 'sensitive-provider-body',
      'blocks': [
        {'type': 'markdown', 'text': '文件已生成，请查看'},
        {
          'type': 'file',
          'name': 'report.pptx',
          'mime':
              'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          'size': 1234,
          'url': 'https://example.com/report.pptx'
        },
      ],
    });
    expect(message.content, '文件已生成，请查看');
    expect(message.empBlocks.single['name'], 'report.pptx');
    expect(message.copyWith(content: message.content).failureMessage,
        message.failureMessage);
    await tester.pumpWidget(
        wrap(ChatAssistantMessageViewData.fromMessage(message), width: 390));
    await tester.pump();
    expect(find.textContaining('内容或大小未满足交付要求'), findsOneWidget);
    expect(find.textContaining('report.pptx'), findsOneWidget);
    expect(find.text('AI 生成'), findsOneWidget);
    expect(find.textContaining('sensitive-provider-body'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty answer failure is shown only once', (tester) async {
    final message = ChatMessage.fromAgentBusJson({
      'uuid': 'failed-empty',
      'role': 'agent',
      'status': 'failed',
      'error_code': 'chat.deliverable_missing',
      'blocks': [],
    });
    final item = ChatAssistantMessageViewData.fromMessage(message);
    expect(item.failureMessage, isNull);
    await tester.pumpWidget(wrap(item));
    await tester.pump();
    expect(find.textContaining('未生成全部要求的文件'), findsOneWidget);
    expect(find.text('AI 生成'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading 气泡不显示处理中和停止，直接展示执行进度', (tester) async {
    await tester.pumpWidget(wrap(
      ChatAssistantMessageViewData(
        messageId: 'loading-1',
        uuid: 'loading-1',
        status: BubbleStatus.loading,
        feedback: FeedbackType.none,
        files: const [],
        blocks: const [],
        streamStartedAt: DateTime.utc(2026, 7, 14, 10),
        timelineEntries: [
          ChatTimelineEntry(
            key: 'stage-1',
            kind: ChatTimelineKind.stage,
            title: '正在生成回复…',
            status: ChatTimelineStatus.running,
            startedAt: DateTime.utc(2026, 7, 14, 10),
          ),
        ],
      ),
      onStop: () {},
    ));

    expect(find.text('处理中…'), findsNothing);
    expect(find.text('AI 生成'), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(find.text('正在生成回复…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('归档期间折叠标题保留保存进度', (tester) async {
    await tester.pumpWidget(wrap(ChatAssistantMessageViewData(
      messageId: 'archive',
      uuid: 'archive',
      status: BubbleStatus.loading,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [],
      timelineEntries: [
        ChatTimelineEntry(
          key: 'stage:local-archive',
          kind: ChatTimelineKind.stage,
          title: '正在保存到云盘（已处理 1/3）',
          status: ChatTimelineStatus.running,
          startedAt: DateTime.now(),
        )
      ],
    )));
    expect(find.text('正在保存到云盘（已处理 1/3）'), findsWidgets);
    await tester.tap(find.text('正在保存到云盘（已处理 1/3）').first);
    await tester.pump();
    expect(find.text('正在保存到云盘（已处理 1/3）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('尚无进度帧时展示两阶段等待梯', (tester) async {
    final item = ChatAssistantMessageViewData(
      messageId: 'loading-waiting',
      uuid: 'loading-waiting',
      status: BubbleStatus.loading,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [],
      // 等待梯阶段按 streamStartedAt 真实经过时间推导(2026-07-18):
      // "从第一级开始"要求流刚开——固定过去时间戳会直接进第二级。
      streamStartedAt: DateTime.now(),
    );
    await tester.pumpWidget(wrap(item));

    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.text('等待模型响应…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1600));

    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('等待模型响应…'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-dot-0')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只有通用 thinking 占位时仍展示两阶段等待梯', (tester) async {
    await tester.pumpWidget(wrap(
      ChatAssistantMessageViewData(
        messageId: 'loading-generic-thinking',
        uuid: 'loading-generic-thinking',
        status: BubbleStatus.loading,
        feedback: FeedbackType.none,
        files: const [],
        blocks: const [],
        streamStartedAt: DateTime.now(),
        timelineEntries: [
          ChatTimelineEntry(
            key: 'thinking',
            kind: ChatTimelineKind.thinking,
            title: '思考中',
            status: ChatTimelineStatus.running,
            startedAt: DateTime.utc(2026, 7, 17, 15),
          ),
        ],
      ),
    ));

    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.text('思考中…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1600));

    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('等待模型响应…'), findsOneWidget);
    expect(find.text('思考中…'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('等待梯重建后按经过时间恢复到第二级，不回退重跑', (tester) async {
    // send 响应回填 agent_message_uuid 会让消息行 key 变化、等待梯被整体
    // 重建(2026-07-18 实锤:梯子跑到第二级后回退到"正在思考"重跑)。阶段按
    // streamStartedAt 推导后,重建即恢复到应处的级。
    final item = ChatAssistantMessageViewData(
      messageId: 'loading-remount',
      uuid: 'loading-remount',
      status: BubbleStatus.loading,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [],
      streamStartedAt: DateTime.now().subtract(const Duration(seconds: 3)),
    );
    await tester.pumpWidget(wrap(item));

    expect(find.text('正在思考…'), findsNothing);
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('等待模型响应…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('系统减少动画时仍展示可读等待文案', (tester) async {
    await tester.pumpWidget(wrap(
      ChatAssistantMessageViewData(
        messageId: 'loading-reduced-motion',
        uuid: 'loading-reduced-motion',
        status: BubbleStatus.loading,
        feedback: FeedbackType.none,
        files: const [],
        blocks: const [],
        streamStartedAt: DateTime.now(),
      ),
      disableAnimations: true,
    ));

    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-dot-0')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停止后的空回答气泡立即显示已停止，不再显示思考中', (tester) async {
    final now = DateTime.utc(2026, 7, 20, 11);
    await tester.pumpWidget(wrap(ChatAssistantMessageViewData(
      messageId: 'stopped-1',
      uuid: 'stopped-1',
      status: BubbleStatus.success,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [],
      agentMessageStatus: 'cancelled',
      streamStartedAt: now,
      streamEndedAt: now,
      timelineEntries: [
        ChatTimelineEntry(
          key: 'stopped',
          kind: ChatTimelineKind.stopped,
          title: '已停止',
          status: ChatTimelineStatus.stopped,
          startedAt: now,
          endedAt: now,
        ),
      ],
    )));

    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('思考中'), findsNothing);
    expect(find.byKey(const ValueKey('thinking-dot-0')), findsNothing);
  });

  testWidgets('执行过程中停止后折叠旧思考步骤，只显示已停止摘要', (tester) async {
    final now = DateTime.utc(2026, 7, 20, 11);
    await tester.pumpWidget(wrap(ChatAssistantMessageViewData(
      messageId: 'stopped-with-timeline',
      uuid: 'stopped-with-timeline',
      status: BubbleStatus.success,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [],
      agentMessageStatus: 'cancelled',
      timelineEntries: [
        ChatTimelineEntry(
          key: 'thinking',
          kind: ChatTimelineKind.thinking,
          title: '思考中',
          status: ChatTimelineStatus.stopped,
          startedAt: now,
          endedAt: now,
        ),
        ChatTimelineEntry(
          key: 'stopped',
          kind: ChatTimelineKind.stopped,
          title: '已停止',
          status: ChatTimelineStatus.stopped,
          startedAt: now,
          endedAt: now,
        ),
      ],
    )));

    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('思考中'), findsNothing);
  });

  testWidgets('完成气泡 hover 后显示耗时和估算积分，移出后隐藏', (tester) async {
    final start = DateTime.utc(2026, 7, 14, 10);
    await tester.pumpWidget(wrap(ChatAssistantMessageViewData(
      messageId: 'done-1',
      uuid: 'done-1',
      status: BubbleStatus.success,
      feedback: FeedbackType.none,
      files: const [],
      blocks: const [ChatAssistantTextBlock(content: '已完成')],
      streamStartedAt: start,
      streamEndedAt: start.add(const Duration(minutes: 1, seconds: 5)),
      tokenUsage: const ChatTokenUsage(
        inputTokens: 1000,
        outputTokens: 500,
        totalTokens: 1500,
      ),
    )));

    expect(find.text('1m 5s'), findsNothing);
    expect(find.text('约 174 积分'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(
      find.byKey(const ValueKey('assistant-message-hover-region')),
    ));
    await tester.pump();

    expect(find.text('1m 5s'), findsOneWidget);
    expect(find.text('约 174 积分'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('assistant-message-hover-region')),
        matching: find.byType(AnimatedSize),
      ),
      findsNothing,
    );
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey('assistant-message-bubble')),
    );
    final metaRect = tester.getRect(
      find.byKey(const ValueKey('assistant-completion-meta')),
    );
    expect(metaRect.right, closeTo(bubbleRect.right, 0.5));
    expect(metaRect.top, greaterThanOrEqualTo(bubbleRect.bottom));

    await mouse.moveTo(const Offset(790, 590));
    await tester.pump();

    expect(find.text('1m 5s'), findsNothing);
    expect(find.text('约 174 积分'), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('EMP 富内容气泡的完成元信息不超出气泡右边缘', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime.utc(2026, 7, 14, 10);
    await tester.pumpWidget(wrap(
      ChatAssistantMessageViewData(
        messageId: 'done-emp',
        uuid: 'done-emp',
        status: BubbleStatus.success,
        feedback: FeedbackType.none,
        files: const [],
        blocks: const [
          ChatAssistantEmpBlocksBlock(blocks: [
            {'type': 'markdown', 'text': '已完成 EMP 回复'},
          ]),
        ],
        streamStartedAt: start,
        streamEndedAt: start.add(const Duration(seconds: 16)),
        tokenUsage: const ChatTokenUsage(
          inputTokens: 100,
          outputTokens: 50,
          totalTokens: 150,
        ),
      ),
      width: 1200,
      maxWidth: 900,
    ));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(
      find.byKey(const ValueKey('assistant-message-hover-region')),
    ));
    await tester.pump();

    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey('assistant-message-bubble')),
    );
    final metaRect = tester.getRect(
      find.byKey(const ValueKey('assistant-completion-meta')),
    );
    expect(metaRect.right, closeTo(bubbleRect.right, 0.5));
    await mouse.removePointer();
  });

  test('耗时格式覆盖秒、分钟与小时', () {
    expect(formatAssistantElapsed(const Duration(milliseconds: 800)), '<1s');
    expect(formatAssistantElapsed(const Duration(seconds: 16)), '16s');
    expect(formatAssistantElapsed(const Duration(minutes: 7, seconds: 33)),
        '7m 33s');
    expect(
        formatAssistantElapsed(const Duration(hours: 2, minutes: 4)), '2h 4m');
  });
}
