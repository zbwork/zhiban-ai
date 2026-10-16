import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/group_agent_final_content.dart';

void main() {
  test('ImMessageBlock supports markdown as structured agent final block', () {
    const block = ImMessageBlock(
      kind: ImMessageBlockKind.markdown,
      text: '**合同风险**\n- 第 1 条',
    );

    expect(block.isMarkdown, isTrue);
    expect(block.toJson(), {
      'type': 'markdown',
      'text': '**合同风险**\n- 第 1 条'
    });

    final decoded = ImMessageBlock.fromJson(block.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.kind, ImMessageBlockKind.markdown);
    expect(decoded.text, block.text);
  });

  test('ImMessageBlock supports skill block as structured execution hint', () {
    const block = ImMessageBlock(
      kind: ImMessageBlockKind.skill,
      skillSlug: 'contract-risk',
      name: '合同风险检查',
    );

    expect(block.isSkill, isTrue);
    expect(block.toJson(), {
      'type': 'skill',
      'slug': 'contract-risk',
      'name': '合同风险检查',
    });

    final decoded = ImMessageBlock.fromJson(block.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.kind, ImMessageBlockKind.skill);
    expect(decoded.skillSlug, 'contract-risk');
    expect(decoded.name, '合同风险检查');
  });

  test('WkAgentFinalContent preserves markdown content and original blocks',
      () {
    final content = WkAgentFinalContent().decodeJson({
      'version': 1,
      'format': 'markdown',
      'content': '**最终答复**',
      'summary': '最终答复',
      'stream_id': 'stream-1',
      'agent_message_uuid': 'am-1',
      'agent_message_status': 'awaiting_user',
      'mentions': [
        {'type': 'human', 'id': 'account-1', 'name': '李强'}
      ],
      'blocks': [
        {'type': 'markdown', 'text': '**最终答复**'}
      ],
    }) as WkAgentFinalContent;

    expect(content.contentType, WukongImClient.agentFinalContentType);
    expect(content.format, 'markdown');
    expect(content.markdownContent, '**最终答复**');
    expect(content.summary, '最终答复');
    expect(content.streamId, 'stream-1');
    expect(content.agentMessageUuid, 'am-1');
    expect(content.agentMessageStatus, 'awaiting_user');
    expect(content.mentions, [
      {'type': 'human', 'id': 'account-1', 'name': '李强'}
    ]);
    expect(content.blocks, hasLength(1));
    expect(content.blocks.single.kind, ImMessageBlockKind.markdown);
    expect(content.displayText(), '最终答复');
    expect(content.encodeJson()['type'], WukongImClient.agentFinalContentType);
    expect(content.encodeJson()['agent_message_status'], 'awaiting_user');
    expect(content.encodeJson()['mentions'], content.mentions);
  });

  test('WkAgentFinalContent falls back to content for summary/search text', () {
    final content = WkAgentFinalContent().decodeJson({
      'content': '没有单独 summary 的 markdown',
      'blocks': const [],
    }) as WkAgentFinalContent;

    expect(content.displayText(), '没有单独 summary 的 markdown');
    expect(content.searchableWord(), '没有单独 summary 的 markdown');
  });

  test('WkAgentFinalContent preserves raw EMP code blocks', () {
    final content = WkAgentFinalContent().decodeJson({
      'version': 1,
      'format': 'markdown',
      'blocks': [
        {
          'type': 'code',
          'language': 'python',
          'source': "print('hello')",
          'filename': 'demo.py',
        }
      ],
    }) as WkAgentFinalContent;

    expect(content.blocks, isEmpty,
        reason: 'EMP code 不是普通 IM mixed block，不能强转后丢失语义');
    expect(content.empBlocks, hasLength(1));
    expect(content.empBlocks.single['type'], 'code');
    expect(content.empBlocks.single['source'], "print('hello')");
    expect(content.displayText(), contains("print('hello')"));

    final encoded = content.encodeJson();
    final encodedBlocks = encoded['blocks'] as List;
    expect(encodedBlocks.single, containsPair('type', 'code'));
    expect(encodedBlocks.single, containsPair('source', "print('hello')"));
  });

  test('WkAgentFinalContent preserves mixed markdown and EMP code blocks', () {
    final content = WkAgentFinalContent().decodeJson({
      'version': 1,
      'format': 'markdown',
      'blocks': [
        {'type': 'markdown', 'text': '分析结果'},
        {'type': 'code', 'language': 'sql', 'source': 'SELECT 1'},
      ],
    }) as WkAgentFinalContent;

    expect(content.blocks, hasLength(1));
    expect(content.blocks.single.kind, ImMessageBlockKind.markdown);
    expect(content.blocks.single.text, '分析结果');
    expect(content.empBlocks, hasLength(1));
    expect(content.empBlocks.single['type'], 'code');
    expect(content.empBlocks.single['source'], 'SELECT 1');
  });

  test('group Agent final keeps full markdown beside source block', () {
    final content = WkAgentFinalContent().decodeJson({
      'version': 1,
      'format': 'markdown',
      'summary': '摘要不能替代完整正文',
      'blocks': [
        {
          'type': 'markdown',
          'text': '这是完整回答。\n\n第二段也必须显示。'
        },
        {
          'type': 'source',
          'items': [
            {'title': '知办操作手册.pdf'}
          ],
        },
      ],
    }) as WkAgentFinalContent;

    expect(content.blocks, hasLength(1));
    expect(content.empBlocks, hasLength(1));
    expect(content.empBlocks.single['type'], 'source');

    final textBlocks = groupAgentFinalTextBlocks(content.blocks);
    expect(textBlocks, hasLength(1));
    expect(textBlocks.single.kind, ImMessageBlockKind.markdown);
    expect(textBlocks.single.text, contains('第二段也必须显示'));
  });
}
