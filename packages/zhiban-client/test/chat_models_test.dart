import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';

void main() {
  test(
      'local engine survives catalog parsing and edit copies; legacy defaults to DSH',
      () {
    final codex = AgentItem.fromJson({
      'uuid': 'local-codex',
      'name': 'Codex',
      'execution_locus': 'local',
      'local_engine': 'codex_app_server'
    });
    expect(codex.localEngine, 'codex_app_server');
    expect(codex.copyWith(name: 'Renamed').localEngine, 'codex_app_server');
    expect(
        CreateAgentDraft.fromAgentItem(codex).localEngine, 'codex_app_server');
    expect(
        AgentItem.fromJson({'uuid': 'old', 'execution_locus': 'local'})
            .localEngine,
        'dsh');
  });
  group('AgentItem skill management capabilities', () {
    test('parses Bus semantic fields for creator-managed skills', () {
      final agent = AgentItem.fromJson(const {
        'uuid': 'agent-1',
        'name': '行政助手',
        'supports_skill_bindings': true,
        'can_manage_skills': true,
      });

      expect(agent.supportsSkillBindings, isTrue);
      expect(agent.canManageSkills, isTrue);
    });

    test('defaults safely when an older Bus omits semantic fields', () {
      final agent = AgentItem.fromJson(const {
        'uuid': 'agent-1',
        'name': '行政助手',
      });

      expect(agent.supportsSkillBindings, isTrue);
      expect(agent.canManageSkills, isFalse);
    });
  });

  group('ChatTokenUsage', () {
    test('兼容 message.completed 摊平 usage 并按 F11 默认费率估算积分', () {
      final usage = ChatTokenUsage.tryParse(const {
        'eventType': 'usage',
        'input_tokens': 1000,
        'output_tokens': 500,
        'total_tokens': 1500,
        'model': 'openai/gpt-5.4',
      });

      expect(usage, isNotNull);
      expect(usage!.inputTokens, 1000);
      expect(usage.outputTokens, 500);
      expect(usage.totalTokens, 1500);
      expect(usage.model, 'openai/gpt-5.4');
      // ceil(1000*43200/1M)=44; ceil(500*259200/1M)=130。
      expect(usage.estimatedCredits, 174);
    });

    test('兼容 nested usage、字符串 token 与 total fallback', () {
      final usage = ChatTokenUsage.tryParse(const {
        'usage': {
          'prompt_tokens': '10',
          'completion_tokens': '20'
        },
      });

      expect(usage, isNotNull);
      expect(usage!.inputTokens, 10);
      expect(usage.outputTokens, 20);
      expect(usage.totalTokens, 30);
      expect(usage.estimatedCredits, 7);
    });

    test('只有 total 无 input/output 时保留 token 事实但不伪造可计费拆分', () {
      final usage = ChatTokenUsage.tryParse(const {'total_tokens': 30});

      expect(usage, isNotNull);
      expect(usage!.hasBillableBreakdown, isFalse);
      expect(usage.estimatedCredits, 0);
    });
  });

  // doc-13 Objective A: 数字员工单聊客户端只认 agent-bus /chat/* 当前契约字段(snake_case + EMP blocks),
  // 开发期不兼容 legacy PascalCase / camelCase。这些 model 单测锁住解析口径。
  group('SendMessageResponse.fromJson (agent-bus /chat/send)', () {
    test('parses snake_case fields; messageId = agent_message_uuid', () {
      final resp = SendMessageResponse.fromJson(const {
        'conversation_uuid': 'conv-1',
        'stream_id': 'stream-1',
        'user_message_uuid': 'umsg-1',
        'agent_message_uuid': 'amsg-1',
      });
      expect(resp.conversationId, 'conv-1');
      expect(resp.streamId, 'stream-1');
      expect(resp.userMessageUuid, 'umsg-1');
      // stop 走 /messages/{agent_message_uuid}/stop → messageId 必为 agent 消息 uuid。
      expect(resp.messageId, 'amsg-1');
    });

    test('does NOT read legacy camelCase shape', () {
      final resp = SendMessageResponse.fromJson(const {
        'conversationId': 'legacy-conv',
        'streamId': 'legacy-stream',
        'messageId': 'legacy-msg',
      });
      expect(resp.conversationId, '');
      expect(resp.streamId, '');
      expect(resp.messageId, '');
    });
  });

  group('SendMessageResponse.fromRoomJson (agent-bus /rooms messages)', () {
    test('parses first stream_ids item', () {
      final resp = SendMessageResponse.fromRoomJson(const {
        'conversation_uuid': 'conv-room',
        'user_message_uuid': 'umsg-room',
        'stream_ids': ['stream-room'],
      });

      expect(resp.conversationId, 'conv-room');
      expect(resp.streamId, 'stream-room');
      expect(resp.userMessageUuid, 'umsg-room');
      expect(resp.messageId, '');
    });
  });

  group('ChatMessage.fromAgentBusJson (history clean DTO)', () {
    test(
        'streaming history stays loading; terminal and awaiting_user do not resume',
        () {
      for (final state in [
        'streaming',
        'final',
        'failed',
        'cancelled',
        'awaiting_user'
      ]) {
        final message = ChatMessage.fromAgentBusJson({
          'uuid': 'history',
          'role': 'agent',
          'status': state,
          'stream_id': 'existing-stream',
          'blocks': <dynamic>[],
        });
        expect(message.isLoading, state == 'streaming', reason: state);
        expect(message.status == BubbleStatus.error, state == 'failed',
            reason: state);
      }
    });

    test('user message → question role, blocks → content', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-user',
        'role': 'user',
        'status': 'final',
        'blocks': [
          {'type': 'plain', 'text': '你好'},
        ],
        'created_at': '2026-06-01T10:00:00Z',
      });
      expect(m.role, ChatRole.question);
      expect(m.content, '你好');
      expect(m.uuid, 'm-user');
      expect(m.status, BubbleStatus.success);
      expect(m.createdAt, isNotNull);
    });

    test('user skill blocks → read-only skill labels, not message content', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-user-skill',
        'role': 'user',
        'status': 'final',
        'blocks': [
          {'type': 'skill', 'slug': 'forge-persona', 'name': '蒸馏.skill'},
          {'type': 'plain', 'text': '这是什么技能'},
          {'type': 'skill', 'slug': 'forge-persona', 'name': '重复标签'},
        ],
      });

      expect(m.content, '这是什么技能');
      expect(m.selectedSkillLabels, const ['蒸馏.skill']);
      expect(m.selectedSkillTags.single.slug, 'forge-persona');
    });

    test('created_at RFC3339 UTC is normalized to device local time', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-local-time',
        'role': 'user',
        'status': 'final',
        'blocks': [
          {'type': 'plain', 'text': '测试本地时间'},
        ],
        'created_at': '2026-07-22T03:18:00Z',
      });

      final expected = DateTime.parse('2026-07-22T03:18:00Z').toLocal();
      expect(m.createdAt, expected);
      expect(m.createdAt!.isUtc, isFalse);
    });

    test('user mixed media blocks → text content + file attachments', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-user-media',
        'role': 'user',
        'status': 'final',
        'blocks': [
          {'type': 'plain', 'text': '这是什么'},
          {
            'type': 'image',
            'url': '/chat/media/ref-img/preview',
            'ref_uuid': 'ref-img',
            'file_id': 'drive-img',
            'name': 'cat.png',
            'size': 123,
          },
          {
            'type': 'file',
            'url': '/chat/media/ref-doc/download',
            'ref_uuid': 'ref-doc',
            'file_id': 'drive-doc',
            'name': '合同.pdf',
            'size': 456,
          },
        ],
      });

      expect(m.role, ChatRole.question);
      expect(m.content, '这是什么');
      expect(m.files, hasLength(2));
      expect(m.files[0].fileType, ChatFileType.image);
      expect(m.files[0].fileName, 'cat.png');
      expect(m.files[0].fileLink, '/chat/media/ref-img/preview');
      expect(m.files[0].uuid, 'ref-img');
      expect(m.files[0].driveFileUuid, 'drive-img');
      expect(m.files[0].sizeBytes, 123);
      expect(m.files[1].fileType, ChatFileType.file);
      expect(m.files[1].fileName, '合同.pdf');
      expect(m.files[1].fileLink, '/chat/media/ref-doc/download');
      expect(m.files[1].uuid, 'ref-doc');
      expect(m.files[1].driveFileUuid, 'drive-doc');
      expect(m.files[1].sizeBytes, 456);
    });

    test('agent message → answer role; messageId = own uuid; multi-block join',
        () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-agent',
        'role': 'agent',
        'status': 'final',
        'stream_id': 's-1',
        'blocks': [
          {'type': 'markdown', 'markdown': '第一段'},
          {'type': 'plain', 'text': '第二段'},
        ],
      });
      expect(m.role, ChatRole.answer);
      expect(m.messageId, 'm-agent'); // agent 消息以自身 uuid 作 stop/retry id
      expect(m.streamId, 's-1');
      expect(m.content, '第一段\n第二段');
    });

    test('failed status → error bubble', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-fail',
        'role': 'agent',
        'status': 'failed',
        'blocks': [],
      });
      expect(m.status, BubbleStatus.error);
      expect(m.content, '');
    });

    test('failed status with empty blocks uses error_message fallback', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-fail-reason',
        'role': 'agent',
        'status': 'failed',
        'blocks': [],
        'error_code': 'chat.runtime_control_plane_not_ready',
        'error_message': 'zap dispatch: agent_key not synced to runtime',
      });
      expect(m.status, BubbleStatus.error);
      expect(
        m.content,
        '数字员工运行环境未就绪：Agent Key 尚未同步到运行时。请联系管理员到管理后台「数字员工」中重新保存/发布该数字员工，并确认自定义运行环境已开启 Agent 管理能力。',
      );
    });

    test('failed ZAP session history uses actionable Chinese message', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-zap-session-fail',
        'role': 'agent',
        'status': 'failed',
        'blocks': [],
        'error_code': 'chat.runtime_protocol_unsupported',
        'error_message': 'zap_session_create_failed',
      });
      expect(m.status, BubbleStatus.error);
      expect(
        m.content,
        '数字员工暂时无法连接，请稍后重试。若持续失败，请联系管理员检查该数字员工的运行环境配置。'
      );
    });

    // 正文与富组件独立渲染；原始字段及顺序只在各自的内容子集中保留。
    test('empBlocks: 历史 markdown 进入正文，typed blocks 原样保留', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-mix',
        'role': 'agent',
        'status': 'final',
        'blocks': [
          {'type': 'markdown', 'markdown': '## 报告'},
          {
            'type': 'chart',
            'chart_kind': 'bar',
            'title': '月度数据',
            'data': [1, 2, 3],
          },
          {'type': 'approval', 'title': '差旅 3500'},
        ],
      });
      expect(m.content, '## 报告');
      expect(m.empBlocks, const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '月度数据',
          'data': [1, 2, 3],
        },
        {'type': 'approval', 'title': '差旅 3500'},
      ]);
    });

    test('empBlocks: 非 list / null / 含非 Map 元素 → best-effort 跳过, 不抛', () {
      // null / 字符串 / 数字 → 空 list
      final none = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm1',
        'role': 'agent',
        'status': 'final',
        'blocks': null,
      });
      expect(none.empBlocks, isEmpty);

      final str = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm2',
        'role': 'agent',
        'status': 'final',
        'blocks': 'not-a-list',
      });
      expect(str.empBlocks, isEmpty);

      // 非 Map 元素跳过，普通文本与 typed 富组件分别保留。
      final mixed = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm3',
        'role': 'agent',
        'status': 'final',
        'blocks': [
          {'type': 'markdown', 'text': 'a'},
          'not-a-map',
          42,
          {'type': 'chart', 'title': 'b'},
        ],
      });
      expect(mixed.content, 'a');
      expect(mixed.empBlocks, const [
        {'type': 'chart', 'title': 'b'},
      ]);
    });

    test('empBlocks: copyWith 覆盖语义正确', () {
      final base = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-cw',
        'role': 'agent',
        'status': 'final',
        'blocks': [
          {'type': 'markdown', 'text': 'old'},
          {'type': 'chart', 'title': '原图表'},
        ],
      });
      expect(base.empBlocks.length, 1);
      // copyWith 不传 empBlocks → 保留原值
      final keep = base.copyWith(content: 'updated');
      expect(keep.content, 'updated');
      expect(keep.empBlocks, base.empBlocks);
      expect(base.content, 'old');
      // copyWith 传新 blocks → 覆盖
      final replaced = base.copyWith(empBlocks: const [
        {'type': 'chart', 'title': '新图表'},
        {'type': 'form', 'title': '请假'},
      ]);
      expect(replaced.empBlocks.length, 2);
      expect(replaced.empBlocks[0]['title'], '新图表');
      expect(replaced.empBlocks[1]['type'], 'form');
      expect(base.empBlocks.single['title'], '原图表');
      expect(base.copyWith(empBlocks: const []).empBlocks, isEmpty);
    });

    test('A2A timeline blocks are restored as timeline and hidden from content',
        () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-a2a',
        'role': 'agent',
        'status': 'final',
        'created_at': '2026-07-08T08:00:00Z',
        'blocks': [
          {
            'type': 'tool_call',
            'x_source': 'a2a_timeline',
            'tool_call_id': 'a2a:edge-1',
            'tool': 'a2a.consult',
            'name': '法务顾问',
            'input': {'edge_id': 'edge-1'},
            'status': 'completed',
          },
          {
            'type': 'tool_result',
            'x_source': 'a2a_timeline',
            'tool_call_id': 'a2a:edge-1',
            'tool': '法务顾问',
            'result': '法务顾问已完成协作。',
            'status': 'completed',
          },
          {'type': 'markdown', 'text': '最终汇总'},
        ],
      });

      expect(m.content, '最终汇总');
      expect(m.empBlocks, isEmpty);
      expect(m.timelineEntries.length, 1);
      expect(m.timelineEntries.first.toolName, '法务顾问');
      expect(m.timelineEntries.first.toolResult, '法务顾问已完成协作。');
    });
  });

  group('ConversationItem.fromJson', () {
    test('parses server-computed group rename capability', () {
      final owner = ConversationItem.fromJson(const {
        'uuid': 'conv-group-owner',
        'title': '项目群',
        'kind': 'group',
        'can_rename_group': true,
      });
      final member = ConversationItem.fromJson(const {
        'uuid': 'conv-group-member',
        'title': '项目群',
        'kind': 'group',
      });

      expect(owner.canRenameGroup, isTrue);
      expect(member.canRenameGroup, isFalse);
    });

    test('parses single digital employee fields from agent-bus DTO', () {
      final item = ConversationItem.fromJson(const {
        'uuid': 'conv-1',
        'title': '许文博',
        'kind': 'single',
        'agent_id': 'agent-1',
        'agent_name': '许文博',
        'agent_avatar_url': '/api/agent-bus/v1/assets/agent-avatars/x.png',
        'agent_position_label': '知识库问答顾问',
        'agent_department_name': '产品部',
        'agent_deleted': true,
        'last_message': {'text': '你好啊', 'ts': '2026-06-02T13:46:00Z'},
      });

      expect(item.title, '许文博');
      expect(item.agentId, 'agent-1');
      expect(item.agentName, '许文博');
      expect(
          item.agentAvatarUrl, '/api/agent-bus/v1/assets/agent-avatars/x.png');
      expect(item.convAvatar, '/api/agent-bus/v1/assets/agent-avatars/x.png');
      expect(item.agentPositionLabel, '知识库问答顾问');
      expect(item.agentDepartmentName, '产品部');
      expect(item.agentDeleted, isTrue);
      expect(item.lastMessage, '你好啊');
    });

    test('agent_direct falls back to agent participant department', () {
      final item = ConversationItem.fromJson(const {
        'uuid': 'conv-agent-direct',
        'title': '周芷涵',
        'kind': 'agent_direct',
        'participants': [
          {
            'kind': 'human',
            'account_uuid': 'acc-1',
            'display_name': '李娜',
            'department_name': '科技中心',
          },
          {
            'kind': 'agent',
            'agent_uuid': 'agent-zhou',
            'display_name': '周芷涵',
            'avatar': 'zhou.png',
            'department_name': '主管',
          },
        ],
      });

      expect(item.agentId, 'agent-zhou');
      expect(item.agentName, '周芷涵');
      expect(item.agentAvatarUrl, 'zhou.png');
      expect(item.agentDepartmentName, '主管');
    });

    test('does not let unresolved conversation avatar override agent avatar',
        () {
      final item = ConversationItem.fromJson(const {
        'uuid': 'conv-agent',
        'title': '林知行',
        'kind': 'agent_direct',
        'avatar': 'oss://agent-avatars/raw.jpg',
        'agent_avatar_url': '/api/agent-bus/v1/assets/agent-avatars/lin.jpg',
      });

      expect(item.agentAvatarUrl,
          '/api/agent-bus/v1/assets/agent-avatars/lin.jpg');
      expect(item.convAvatar, '/api/agent-bus/v1/assets/agent-avatars/lin.jpg');
    });
  });

  // 正文不得被富组件吞掉；没有可读富组件时仍保留正文。
  group('ChatAssistantMessageViewData.fromMessage · 正文与富组件', () {
    test('历史 markdown + chart + form → 正文与富组件各显示一次', () {
      const rawBlocks = [
        {'type': 'markdown', 'text': '## 月度报告'},
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '月度数据',
          'data': [1, 2, 3],
        },
        {'type': 'form', 'title': '请假申请'},
      ];
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'm-report',
        'role': 'agent',
        'status': 'final',
        'blocks': rawBlocks,
      });
      final view = ChatAssistantMessageViewData.fromMessage(m);
      expect(view.blocks.length, 2);
      expect(view.blocks.first, isA<ChatAssistantTextBlock>());
      expect((view.blocks.first as ChatAssistantTextBlock).content, '## 月度报告');
      expect(view.blocks.last, isA<ChatAssistantEmpBlocksBlock>());
      final emp = view.blocks.last as ChatAssistantEmpBlocksBlock;
      expect(emp.blocks, rawBlocks.skip(1).toList());

      // 富组件可读摘要不混入正文，仍可单独供复制/预览使用。
      final copyText = empBlocksToReadableText(rawBlocks);
      expect(copyText.isNotEmpty, isTrue, reason: '含 empBlocks 的消息复制文本不能为空');
      expect(copyText, contains('月度报告'), reason: 'markdown 应原样出现在复制文本');
      expect(copyText, contains('[图表]'),
          reason: 'chart 应渲染 readable 占位 [图表] ...');
      expect(copyText, contains('月度数据'));
      expect(copyText, contains('[表单]'),
          reason: 'form 应渲染 readable 占位 [表单] ...');
      expect(copyText, contains('请假申请'));
    });

    test('empBlocks 不可读 (只有空 markdown) + content 非空 → 回退 TextBlock(content)',
        () {
      const emptyEmpBlocks = [
        {'type': 'markdown', 'text': ''},
        {'type': 'plain', 'text': '   '},
      ];
      final m = ChatMessage(
        role: ChatRole.answer,
        content: 'fallback final text',
        empBlocks: emptyEmpBlocks,
      );
      final view = ChatAssistantMessageViewData.fromMessage(m);
      // 不应该挂 EmpBlocksBlock (会产生空气泡); 应该挂 TextBlock(content)
      expect(view.blocks.length, 1);
      expect(view.blocks.first, isA<ChatAssistantTextBlock>());
      final txt = view.blocks.first as ChatAssistantTextBlock;
      expect(txt.content, 'fallback final text');
    });

    test('empBlocks 完全空 + content 非空 → TextBlock(content) (旧路径)', () {
      final m = ChatMessage(
        role: ChatRole.answer,
        content: 'plain content'
      );
      final view = ChatAssistantMessageViewData.fromMessage(m);
      expect(view.blocks.length, 1);
      expect(view.blocks.first, isA<ChatAssistantTextBlock>());
    });

    test('reasoningContent 只进入 timeline，不追加正文 ReasoningBlock', () {
      final m = ChatMessage(
        role: ChatRole.answer,
        content: '最终结论',
        reasoningContent: '先检查制度，再调用工具',
        timelineEntries: [
          ChatTimelineEntry(
            key: 'reasoning',
            kind: ChatTimelineKind.reasoning,
            title: '思考过程',
            startedAt: DateTime.utc(2026, 7, 9),
            snippet: '先检查制度，再调用工具',
            status: ChatTimelineStatus.done,
          ),
        ],
      );
      final view = ChatAssistantMessageViewData.fromMessage(m);

      expect(view.timelineEntries, isNotEmpty);
      expect(view.reasoningContent, '先检查制度，再调用工具');
      expect(view.blocks.whereType<ChatAssistantReasoningBlock>(), isEmpty);
      expect(view.blocks.length, 1);
      expect(view.blocks.first, isA<ChatAssistantTextBlock>());
    });

    test('未知 EMP 块仍有可读 fallback，同时保留正文', () {
      // empBlocksToReadableText 对 unknown / typed block 仍能产出 "[xxx]" 兜底;
      // 所以这种情况下 hasReadableEmpBlocks 仍是 true, 走 EmpBlocksBlock。
      // 关键是 EmpBlocksView 自己内部对每个 block 都有 try/catch, 即使
      // 单 block 抛异常也不影响其它 block (由 emp_blocks_view_test 覆盖)。
      const malformed = [
        {'type': 'unknown_type', 'title': '未知组件'},
      ];
      final m = ChatMessage(
        role: ChatRole.answer,
        content: 'final content backup',
        empBlocks: malformed,
      );
      final view = ChatAssistantMessageViewData.fromMessage(m);
      expect(view.blocks.length, 2);
      expect(view.blocks.first, isA<ChatAssistantTextBlock>());
      expect((view.blocks.first as ChatAssistantTextBlock).content,
          'final content backup');
      expect(view.blocks.last, isA<ChatAssistantEmpBlocksBlock>());
      expect(
          (view.blocks.last as ChatAssistantEmpBlocksBlock).blocks, malformed);
      expect(empBlocksToReadableText(malformed), contains('未知组件'));
    });
  });

  // ADR-0028 §4.9 / Plan 16 §J — HITL raw agentMessageStatus 解析。
  // 后端 message.awaiting_user / history fetch 都会带 raw status; 客户端必须
  // 把它单独保留 (与气泡 BubbleStatus 解耦), 让 EmpBlocksView 4 条件 enable 通过。
  group('ChatMessage.agentMessageStatus (HITL)', () {
    test('fromAgentBusJson status=awaiting_user → agentMessageStatus 字段保留', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'amsg-await',
        'role': 'agent',
        'status': 'awaiting_user',
        'blocks': [
          {'type': 'approval', 'title': '请审批'},
        ],
      });
      expect(m.agentMessageStatus, 'awaiting_user');
      // BubbleStatus 不能因为 raw 状态非 failed 就变 error; awaiting_user 走 success 气泡视觉。
      expect(m.status, BubbleStatus.success);
      // empBlocks 仍按结构化保留, 供 EmpBlocksView 渲染。
      expect(m.empBlocks.length, 1);
      expect(m.empBlocks.first['type'], 'approval');
    });

    test('fromAgentBusJson status=final → agentMessageStatus="final"', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'amsg-final',
        'role': 'agent',
        'status': 'final',
      });
      expect(m.agentMessageStatus, 'final');
    });

    test('fromAgentBusJson status=失败值 → BubbleStatus.error + raw 透传', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'amsg-fail',
        'role': 'agent',
        'status': 'failed',
      });
      expect(m.status, BubbleStatus.error);
      expect(m.agentMessageStatus, 'failed');
    });

    test('fromAgentBusJson 脏 status 不污染 agentMessageStatus', () {
      final m = ChatMessage.fromAgentBusJson(const {
        'uuid': 'amsg-x',
        'role': 'agent',
        'status': 'something_unknown',
      });
      // 不假装识别未知值; 留 null 让 EmpBlocksView fail-out 4 条件 (默认 disabled)。
      expect(m.agentMessageStatus, isNull);
    });

    test('copyWith 默认保留原 agentMessageStatus; 显式传 null 清空', () {
      final m = ChatMessage(
        role: ChatRole.answer,
        content: 'x',
        agentMessageStatus: 'awaiting_user',
      );
      final keptDefault = m.copyWith(content: 'y');
      expect(keptDefault.agentMessageStatus, 'awaiting_user');
      final cleared = m.copyWith(agentMessageStatus: null);
      expect(cleared.agentMessageStatus, isNull);
      // 显式覆盖
      final reset = m.copyWith(agentMessageStatus: 'final');
      expect(reset.agentMessageStatus, 'final');
    });

    test(
        'ChatAssistantMessageViewData.fromMessage 透传 agentMessageStatus + empBlocks',
        () {
      final m = ChatMessage(
        role: ChatRole.answer,
        content: '',
        agentMessageStatus: 'awaiting_user',
        empBlocks: const [
          {'type': 'approval', 'title': 'ok'},
        ],
      );
      final view = ChatAssistantMessageViewData.fromMessage(m);
      expect(view.agentMessageStatus, 'awaiting_user');
      expect(view.empBlocks.length, 1);
      expect(view.empBlocks.first['type'], 'approval');
    });
  });

  // ADR-0028 §4.6 — `POST /chat/respond` 响应解析。
  group('RespondToAgentMessageResponse.fromJson', () {
    test('snake_case 字段全部解出', () {
      final r = RespondToAgentMessageResponse.fromJson(const {
        'stream_id': 'new-stream-xyz',
        'conversation_uuid': 'conv-1',
        'new_agent_message_uuid': 'new-amsg-abc',
      });
      expect(r.streamId, 'new-stream-xyz');
      expect(r.conversationUuid, 'conv-1');
      expect(r.newAgentMessageUuid, 'new-amsg-abc');
    });

    test('字段缺失 → 空串; 不抛异常', () {
      final r = RespondToAgentMessageResponse.fromJson(const {});
      expect(r.streamId, '');
      expect(r.conversationUuid, '');
      expect(r.newAgentMessageUuid, '');
    });
  });
}
