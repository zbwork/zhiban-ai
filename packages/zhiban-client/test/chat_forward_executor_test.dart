import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_forward_executor.dart';

// F09 转发 v1 (2026-06 多目标增量): 转发执行器 + toast 文案纯函数。
// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.

ImMessage _txt(String t, {int seq = 1}) => ImMessage(
      messageId: 'm-$seq',
      clientMsgNo: 'c-$seq',
      fromUid: 'me',
      channelId: 'src',
      channelType: 2,
      timestamp: 1700000000 + seq,
      text: t,
      messageSeq: seq,
    );

ImMessage _mixed(List<ImMessageBlock> blocks, {int seq = 1}) => ImMessage(
      messageId: 'mixed-$seq',
      clientMsgNo: 'cm-$seq',
      fromUid: 'me',
      channelId: 'src',
      channelType: 2,
      timestamp: 1700000000 + seq,
      text: 'mixed summary',
      messageSeq: seq,
      blocks: blocks,
    );

ConversationItem _conv({
  required String id,
  required String title,
  String? channelId,
  int channelType = 1,
}) =>
    ConversationItem(
      conversationId: id,
      title: title,
      agentId: '',
      agentName: '',
      kind: 'human_direct',
      wukongChannelId: channelId ?? 'ch-$id',
      wukongChannelType: channelType,
    );

void main() {
  group('forwardMessagesToTargets', () {
    test('1 条消息 → 3 个目标 → 3 次成功 send', () async {
      final sentCalls = <List<dynamic>>[];
      final result = await forwardMessagesToTargets(
        messages: [_txt('hello')],
        targets: [
          _conv(id: 'a', title: 'A'),
          _conv(id: 'b', title: 'B'),
          _conv(id: 'c', title: 'C'),
        ],
        send: (ch, ct, t) async {
          sentCalls.add([ch, ct, t]);
        },
      );
      expect(sentCalls.length, 3);
      expect(result.sentSends, 3);
      expect(result.failedSends, 0);
      expect(result.targetsWithAnySuccess, 3);
      expect(result.targetsAllFailed, 0);
      expect(result.totalMessagesPerTarget, 1);
    });

    test('N 条消息 × M 目标 → 按目标 × 升序逐条发 (顺序不被目标穿插)', () async {
      final calls = <String>[]; // record "ch:text"
      final result = await forwardMessagesToTargets(
        messages: [_txt('m1', seq: 1), _txt('m2', seq: 2)],
        targets: [
          _conv(id: 'a', title: 'A'),
          _conv(id: 'b', title: 'B'),
        ],
        send: (ch, ct, t) async {
          calls.add('$ch:$t');
        },
      );
      expect(calls, ['ch-a:m1', 'ch-a:m2', 'ch-b:m1', 'ch-b:m2']);
      expect(result.sentSends, 4);
      expect(result.failedSends, 0);
      expect(result.totalTargets, 2);
      expect(result.totalMessagesPerTarget, 2);
    });

    test('target 无 wukongChannelId → 跳过, 计入 failedSends + targetsAllFailed',
        () async {
      final result = await forwardMessagesToTargets(
        messages: [_txt('m1', seq: 1), _txt('m2', seq: 2)],
        targets: [
          _conv(id: 'a', title: 'A'),
          _conv(id: 'broken', title: 'X', channelId: ''),
        ],
        send: (_, __, ___) async {},
      );
      expect(result.sentSends, 2);
      expect(result.failedSends, 2); // 2 条消息没法发到 broken
      expect(result.targetsWithAnySuccess, 1);
      expect(result.targetsAllFailed, 1);
    });

    test('部分 target 全失败 → 计入 targetsAllFailed', () async {
      final result = await forwardMessagesToTargets(
        messages: [_txt('m1')],
        targets: [
          _conv(id: 'ok', title: 'OK'),
          _conv(id: 'bad', title: 'BAD'),
        ],
        send: (ch, ct, t) async {
          if (ch == 'ch-bad') throw Exception('network');
        },
      );
      expect(result.sentSends, 1);
      expect(result.failedSends, 1);
      expect(result.targetsWithAnySuccess, 1);
      expect(result.targetsAllFailed, 1);
    });

    test('一条 send 失败不阻塞同 target 的其它消息', () async {
      final calls = <String>[];
      final result = await forwardMessagesToTargets(
        messages: [
          _txt('m1', seq: 1),
          _txt('m2', seq: 2),
          _txt('m3', seq: 3)
        ],
        targets: [_conv(id: 'a', title: 'A')],
        send: (ch, ct, t) async {
          calls.add(t);
          if (t == 'm2') throw Exception('boom');
        },
      );
      expect(calls, ['m1', 'm2', 'm3']);
      expect(result.sentSends, 2);
      expect(result.failedSends, 1);
      expect(result.targetsWithAnySuccess, 1);
    });

    test('messages 全部 fail-closed (不可转发) → 不发, 不调 send', () async {
      var called = false;
      final result = await forwardMessagesToTargets(
        messages: [
          // 抽出后空文本
          ImMessage(
            messageId: 'r',
            clientMsgNo: 'c',
            fromUid: 'me',
            channelId: 'src',
            channelType: 2,
            timestamp: 1700000000,
            text: '   ',
            messageSeq: 1,
          ),
        ],
        targets: [_conv(id: 'a', title: 'A')],
        send: (_, __, ___) async {
          called = true;
        },
      );
      expect(called, isFalse);
      expect(result.sentSends, 0);
      expect(result.failedSends, 0);
      expect(result.totalMessagesPerTarget, 0);
    });

    test('默认转发 mixed 图文消息仍 fail-closed, 不发媒体说明文字', () async {
      var called = false;
      final result = await forwardMessagesToTargets(
        messages: [
          _mixed([
            const ImMessageBlock(
              kind: ImMessageBlockKind.image,
              url: '/chat/media/ref/preview',
            ),
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一张图'),
          ]),
        ],
        targets: [_conv(id: 'a', title: 'A')],
        send: (_, __, ___) async {
          called = true;
        },
      );

      expect(called, isFalse);
      expect(result.totalMessagesPerTarget, 0);
    });

    test('批量转发 mixed 图文/文件消息时只抽 text/markdown 说明文字', () async {
      final sent = <String>[];
      final result = await forwardMessagesToTargets(
        messages: [
          _mixed([
            const ImMessageBlock(
              kind: ImMessageBlockKind.image,
              url: '/chat/media/img/preview',
            ),
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个图片'),
          ], seq: 1),
          _mixed([
            const ImMessageBlock(
              kind: ImMessageBlockKind.file,
              url: '/chat/media/file/download',
              name: '4月cursor.pdf',
            ),
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是一个文件'),
            const ImMessageBlock(
              kind: ImMessageBlockKind.image,
              url: '/chat/media/img2/preview',
            ),
            const ImMessageBlock(
                kind: ImMessageBlockKind.markdown, text: '**这是一个图片**'),
          ], seq: 2),
        ],
        targets: [_conv(id: 'a', title: 'A')],
        allowMixedMediaText: true,
        send: (_, __, t) async => sent.add(t),
      );

      expect(sent, ['这是一个图片', '这是一个文件\n**这是一个图片**']);
      expect(result.sentSends, 2);
      expect(result.totalMessagesPerTarget, 2);
    });

    test('批量转发 mixed 纯媒体无说明文字 → 跳过', () async {
      expect(
        canBatchForwardMessage(_mixed([
          const ImMessageBlock(
            kind: ImMessageBlockKind.image,
            url: '/chat/media/ref/preview',
          ),
        ])),
        isFalse,
      );
    });

    test('mentions 守卫: 调用方传给 send 的 text 不带 mentions metadata', () async {
      // 转发只送文本, mentions 由 send 层是否携带决定; 执行器只传 text 字符串。
      // 这里验证 send 函数收到的就是 chatForwardTextOf 抽出的纯文本, 不会被注入 mentions。
      String? captured;
      await forwardMessagesToTargets(
        messages: [_txt('@张三 hello')],
        targets: [_conv(id: 'a', title: 'A')],
        send: (_, __, t) async {
          captured = t;
        },
      );
      expect(captured, '@张三 hello');
      // text 是纯字符串, executor 完全不知道 mentions 概念 (调用方 _onForward 也故意不传)
    });
  });

  group('forwardRichMessagesToTargets', () {
    test('逐条转发 mixed 图文/文件 → 克隆媒体 ref 并发送 mixed payload', () async {
      final payloads = <ChatForwardPayload>[];
      final result = await forwardRichMessagesToTargets(
        messages: [
          _mixed([
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是文件'),
            const ImMessageBlock(
              kind: ImMessageBlockKind.file,
              fileUuid: 'drive-file',
              name: '4月cursor.pdf',
            ),
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '这是图片'),
            const ImMessageBlock(
              kind: ImMessageBlockKind.image,
              fileUuid: 'drive-img',
              name: 'p.png',
            ),
          ]),
        ],
        targets: [_conv(id: 'a', title: 'A')],
        mode: ChatForwardMode.separate,
        cloneMediaBlock: (conversationUuid, block) async => ImMessageBlock(
          kind: block.kind,
          url: block.isImage
              ? '/chat/media/${block.fileUuid}/preview'
              : '/chat/media/${block.fileUuid}/download',
          fileUuid: block.fileUuid,
          name: block.name,
        ),
        send: (_, __, payload) async => payloads.add(payload),
      );

      expect(result.sentSends, 1);
      expect(payloads, hasLength(1));
      expect(payloads.single.blocks.map((b) => b.kind), [
        ImMessageBlockKind.text,
        ImMessageBlockKind.file,
        ImMessageBlockKind.text,
        ImMessageBlockKind.image,
      ]);
      expect(payloads.single.blocks[1].url, '/chat/media/drive-file/download');
      expect(payloads.single.blocks[3].url, '/chat/media/drive-img/preview');
    });

    test('合并转发 → 发送单条 forward_record block', () async {
      final payloads = <ChatForwardPayload>[];
      final result = await forwardRichMessagesToTargets(
        messages: [
          _txt('第一条', seq: 1),
          _mixed([
            const ImMessageBlock(kind: ImMessageBlockKind.text, text: '第二条'),
            const ImMessageBlock(
              kind: ImMessageBlockKind.image,
              fileUuid: 'drive-img',
            ),
          ], seq: 2),
        ],
        targets: [_conv(id: 'a', title: 'A')],
        mode: ChatForwardMode.merged,
        senderNameOf: (message) => message.messageSeq == 1 ? '我' : '李强',
        mergeTitle: '李强的聊天记录',
        cloneMediaBlock: (conversationUuid, block) async => ImMessageBlock(
          kind: block.kind,
          url: '/chat/media/${block.fileUuid}/preview',
          fileUuid: block.fileUuid,
        ),
        send: (_, __, payload) async => payloads.add(payload),
      );

      expect(result.sentSends, 1);
      expect(result.totalMessagesPerTarget, 1);
      expect(payloads, hasLength(1));
      expect(payloads.single.blocks, hasLength(1));
      final card = payloads.single.blocks.single;
      expect(card.isForwardRecord, isTrue);
      expect(card.name, '李强的聊天记录');
      expect(card.text, contains('"entries"'));
      expect(card.text, contains('"sender":"我"'));
      expect(card.text, contains('"sender":"李强"'));
      expect(card.text, contains('"type":"image"'));
    });
  });

  group('chatForwardResultToast', () {
    ChatForwardResult res({
      int ok = 0,
      int fail = 0,
      int targetsOk = 0,
      int targetsFail = 0,
      int totalTargets = 1,
      int perTarget = 1,
    }) =>
        ChatForwardResult(
          sentSends: ok,
          failedSends: fail,
          targetsWithAnySuccess: targetsOk,
          targetsAllFailed: targetsFail,
          totalTargets: totalTargets,
          totalMessagesPerTarget: perTarget,
        );

    test('单条 + 单目标 + 全成功 → 「已转发到 X」', () {
      expect(
        chatForwardResultToast(
          result: res(ok: 1, targetsOk: 1, totalTargets: 1),
          isBatch: false,
          singleTargetName: '小红',
        ),
        '已转发到 小红',
      );
    });

    test('单条 + 多目标 + 全成功 → 「已转发到 K 个会话」', () {
      expect(
        chatForwardResultToast(
          result: res(ok: 3, targetsOk: 3, totalTargets: 3),
          isBatch: false,
        ),
        '已转发到 3 个会话',
      );
    });

    test('单条 + 多目标 + 部分失败 → 「已转发到 K 个会话, M 个失败」', () {
      expect(
        chatForwardResultToast(
          result: res(
              ok: 2, fail: 1, targetsOk: 2, targetsFail: 1, totalTargets: 3),
          isBatch: false,
        ),
        '已转发到 2 个会话, 1 个失败',
      );
    });

    test('批量 + 全成功 → 「已转发 N 条到 K 个会话」', () {
      expect(
        chatForwardResultToast(
          result: res(ok: 6, targetsOk: 3, totalTargets: 3, perTarget: 2),
          isBatch: true,
        ),
        '已转发 2 条到 3 个会话',
      );
    });

    test('批量 + 部分失败 → 包含失败数字', () {
      final s = chatForwardResultToast(
        result: res(
            ok: 4,
            fail: 2,
            targetsOk: 2,
            targetsFail: 1,
            totalTargets: 3,
            perTarget: 2),
        isBatch: true,
      );
      expect(s, contains('4 条'));
      expect(s, contains('2 条失败'));
    });

    test('全部失败 → 明确「全部转发失败」', () {
      expect(
        chatForwardResultToast(
          result: res(fail: 6, targetsFail: 3, totalTargets: 3, perTarget: 2),
          isBatch: true,
        ),
        '全部转发失败 (3 个目标)',
      );
    });

    test('未选目标 → 「未选择目标会话」', () {
      expect(
        chatForwardResultToast(
          result: res(totalTargets: 0),
          isBatch: false
        ),
        '未选择目标会话',
      );
    });
  });
}
