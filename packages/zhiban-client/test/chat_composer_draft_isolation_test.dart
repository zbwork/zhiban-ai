// F09 §5.7 / 契约 §3.0f C7：composer 草稿按会话 snapshot/restore。
//
// 覆盖验收矩阵：
//   V5  A、B 文本/光标/skills 草稿互不污染、各自恢复
//   V9  pending→real rekey 期间草稿不丢（widget 不把 rekey 当用户切会话）
//
// 另含 RichPromptController snapshotDraft/restoreDraft 的单元回归。

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';

ChatWorkspaceState _workspace(
  String active, {
  Map<String, ChatComposerDraft> drafts = const {},
  Map<String, String> aliases = const {},
}) {
  final sessions = <String, ChatSessionState>{
    for (final e in drafts.entries)
      e.key: ChatSessionState(conversationId: e.key, draft: e.value),
  };
  sessions.putIfAbsent(active, () => ChatSessionState(conversationId: active));
  return ChatWorkspaceState(
      activeConversationId: active, sessions: sessions, aliases: aliases);
}

class _Harness extends StatefulWidget {
  const _Harness(
      {super.key, required this.initial, required this.onDraftChanged});

  final ChatWorkspaceState initial;
  final void Function(String conversationId, ChatComposerDraft draft)
      onDraftChanged;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late ChatWorkspaceState workspace = widget.initial;

  void setWorkspace(ChatWorkspaceState ws) => setState(() => workspace = ws);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 640,
          child: ChatSessionView(
            state: workspace,
            onDraftChanged: widget.onDraftChanged,
            onPickFiles: () {},
            onPickImages: () {},
            onPickFromDrive: () {},
            onRemoveFile: (_) {},
            onSend: (_, __) {},
            onStop: () {},
            onLoadMoreHistory: () {},
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('V5: 切会话保存 A 草稿并恢复 B 草稿，各自互不污染', (tester) async {
    final drafts = <String, ChatComposerDraft>{};
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(
      key: key,
      initial: _workspace('conv-a'),
      onDraftChanged: (id, d) {
        // 回归钉死（2026-07-14 真机事故）：onDraftChanged 会写 provider，
        // 绝不能在 build 阶段（didUpdateWidget/deactivate）同步触发——
        // Riverpod 会抛 "Tried to modify a provider while the widget tree
        // was building"，把 ChatSessionView 子树的更新打断，消息面板与
        // 停止按钮从此冻结在上一个会话。必须推迟到帧后。
        expect(
          SchedulerBinding.instance.schedulerPhase,
          isNot(SchedulerPhase.persistentCallbacks),
          reason: 'onDraftChanged 不得在 build 阶段同步触发',
        );
        drafts[id] = d;
      },
    ));
    await tester.pump();

    // A 输入草稿。
    await tester.enterText(find.byType(TextField).first, '偏 UI 设计');
    await tester.pump();

    // 切到 B（B 无草稿）→ A 草稿被保存，输入框为空。
    key.currentState!
        .setWorkspace(_workspace('conv-b', drafts: Map.of(drafts)));
    await tester.pump();
    expect(drafts['conv-a']?.text, '偏 UI 设计');
    expect(
        (tester.widget(find.byType(TextField).first) as TextField)
            .controller!
            .text,
        isEmpty,
        reason: 'B 不得显示 A 的草稿（V1/V5）');

    // B 输入自己的草稿，再切回 A。
    await tester.enterText(find.byType(TextField).first, '海报文案');
    await tester.pump();
    key.currentState!
        .setWorkspace(_workspace('conv-a', drafts: Map.of(drafts)));
    await tester.pump();
    expect(drafts['conv-b']?.text, '海报文案');
    expect(
        (tester.widget(find.byType(TextField).first) as TextField)
            .controller!
            .text,
        '偏 UI 设计',
        reason: '切回 A 恢复 A 的草稿');

    // 再切到 B：恢复 B 草稿。
    key.currentState!
        .setWorkspace(_workspace('conv-b', drafts: Map.of(drafts)));
    await tester.pump();
    expect(
        (tester.widget(find.byType(TextField).first) as TextField)
            .controller!
            .text,
        '海报文案');
  });

  testWidgets('V9: pending→real rekey 不触发 snapshot/restore，草稿不丢',
      (tester) async {
    final saved = <String>[];
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(
      key: key,
      initial: _workspace('pending:agent-x'),
      onDraftChanged: (id, _) => saved.add(id),
    ));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '正在输入的半句话');
    await tester.pump();
    saved.clear();

    // rekey：active 从 pending:agent-x 变为 conv-real，alias 标记同一 session。
    key.currentState!.setWorkspace(_workspace(
      'conv-real',
      aliases: const {'pending:agent-x': 'conv-real'}),
    );
    await tester.pump();

    expect(saved, isEmpty, reason: 'rekey 不得被当成用户切会话（V9）');
    expect(
        (tester.widget(find.byType(TextField).first) as TextField)
            .controller!
            .text,
        '正在输入的半句话',
        reason: 'rekey 期间正在输入的草稿不得丢失（V9）');
  });

  group('RichPromptController snapshot/restore', () {
    test('文本 + 附件 + 光标整体往返', () {
      final a = RichPromptController();
      addTearDown(a.dispose);
      a.text = '前后';
      a.selection = const TextSelection.collapsed(offset: 1);
      a.insertAttachment(const RichPromptAttachment(
        id: 'att-1',
        fileName: 'x.png',
        fileType: ChatFileType.image,
        status: RichAttachmentStatus.ready,
        block: ImMessageBlock(kind: ImMessageBlockKind.image, url: '/x.png'),
      ));
      final snap = a.snapshotDraft();
      expect(snap.hasContent, isTrue);

      final b = RichPromptController();
      addTearDown(b.dispose);
      b.text = '别的会话内容';
      b.restoreDraft(snap);
      expect(b.attachments.single.id, 'att-1');
      expect(b.textWithoutAttachmentTokens, '前\n后');
      expect(b.draftBlocks.where((blk) => blk.isAttachment), hasLength(1));

      // restore(null) 恢复为空（新会话无草稿）。
      b.restoreDraft(null);
      expect(b.hasRichContent, isFalse);
      expect(b.text, isEmpty);
    });
  });
}
