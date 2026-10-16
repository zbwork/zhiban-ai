import 'chat_history_repository.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_models.dart';
import 'package:zhiban_client/services/message_files_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';

/// OpenClawChatService —— 数字员工单聊客户端服务。
///
/// doc-13 Objective A（2026-06-01）：**数字员工单聊链路已迁到 agent-bus `/api/agent-bus/v1/chat/*`**，
/// 开发期**不兼容 legacy** `/app/openclaw-agent/*`（ai-office 时代路径，agent-bus 不实现 → 404，
/// 曾是"点击数字员工卡片进对话报 404"的根因）。契约见
/// `docs/contracts/agent-bus-client-contract.md` §3.0 + `docs/pitfalls/client-chat-legacy-openclaw-agent-404.md`。
///
/// 仍走 legacy `/app/openclaw-agent/*` 的方法（`bootstrapInstance` / `getInstanceStatus`）
/// **不在本次单聊迁移范围**，为后续单独迁移项（见 doc-13 §A 改动范围备注）。
/// 本地附件上传已迁到 Bus `/message-files/*`，避免回退 legacy `/app/openclaw-agent/files` 404。
class OpenClawChatService {
  OpenClawChatService({MessageFilesService? messageFiles})
      : _messageFiles = messageFiles ?? MessageFilesService();

  final MessageFilesService _messageFiles;
  late final ChatHistoryRepository _history =
      ChatHistoryRepository(dio: request);

  Future<List<ChatMessage>> getCachedHistory(String conversationId,
          {String? clearedAt}) async =>
      (await _history.cached(conversationId, clearedAt: clearedAt))
          .map(ChatMessage.fromAgentBusJson)
          .toList();

  Future<List<ChatMessage>> synchronizeHistory(String conversationId) async {
    if (await _history.scope() == null) {
      return getHistory(conversationId: conversationId);
    }
    return (await _history.latest(conversationId, incremental: true))
        .map(ChatMessage.fromAgentBusJson)
        .toList();
  }

  Future<void> evictHistory(String conversationId) =>
      _history.remove(conversationId);

  // ── agent-bus 数字员工单聊契约（doc-13 §A，权威）──────────────────────────
  static const String _chatSend = '/chat/send';
  static const String _chatStream = '/chat/stream';
  static const String _chatRespond = '/chat/respond';
  static const String _a2aApprovals = '/a2a/approvals';
  static const String _chatConversations = '/chat/conversations';
  static const String _messageStop = '/messages/{messageId}/stop';
  // ADR-0026 agent-direct 双通道(prepare → WuKong 直发 → attach)。
  static const String _agentDirectPrepare = '/chat/agent-direct/prepare-wukong';
  static const String _agentDirectAttach = '/chat/agent-direct/attach-stream';
  static const String _runtimeEnvironments = '/runtime-environments';
  static const String _llmModels = '/llm-models';

  // ── 仍为 legacy 的非单聊端点（后续单独迁移；不在 doc-13 §A 范围）──────────
  static const String _openClawBasePath = '/app/openclaw-agent';
  static const String _bootstrap = '$_openClawBasePath/bootstrap';
  static const String _instanceStatus = '$_openClawBasePath/instance/status';
  static const String _agents = '/agents';
  static const String _positions = '/agents/positions';

  Future<OpenClawInstanceState> bootstrapInstance() async {
    final response = await request.post(_bootstrap, data: const {});
    return OpenClawInstanceState.fromJson(responseAsMap(response));
  }

  Future<OpenClawInstanceState> getInstanceStatus() async {
    final response = await request.get(_instanceStatus);
    return OpenClawInstanceState.fromJson(responseAsMap(response));
  }

  Future<List<AgentItem>> listAgents() async {
    final response = await request.get(
      _agents,
      queryParameters: {'limit': 200, 'mine': 1},
    );
    final map = responseAsMap(response);
    final raw =
        map['items'] is List ? map['items'] as List : responseAsList(response);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(AgentItem.fromJson)
        .toList();
  }

  Future<AgentItem> getAgent(String agentId) async {
    final response =
        await request.get('$_agents/${Uri.encodeComponent(agentId)}');
    return _agentFromDetailResponse(responseAsMap(response));
  }

  Future<List<PositionOption>> listPositions() async {
    final raw = responseAsList(await request.get(_positions));
    return raw
        .whereType<Map<String, dynamic>>()
        .map(PositionOption.fromJson)
        .where((item) => item.code.isNotEmpty)
        .toList(growable: false);
  }

  /// 当前成员的模型目录，顺序由服务端决定。所有托管引擎共用成员目录；
  /// BYOK 员工只用绑定模型，不从此目录替换身份。
  Future<List<LlmModelOption>> listLlmModels({
    String? runtimeEnvironmentUuid,
  }) async {
    final uuid = runtimeEnvironmentUuid?.trim() ?? '';
    final response = await request.get(
      _llmModels,
      queryParameters: uuid.isEmpty ? null : {'runtime_environment_uuid': uuid},
    );
    final map = responseAsMap(response);
    final raw = map['items'];
    if (raw is! List) return const <LlmModelOption>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(LlmModelOption.fromJson)
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<RuntimeEnvironmentOption>> listRuntimeEnvironments() async {
    final response = await request.get(_runtimeEnvironments);
    final map = responseAsMap(response);
    final raw = map['tenant_enabled'] ??
        map['tenantEnabled'] ??
        map['TenantEnabled'] ??
        const [];
    if (raw is! List) return const <RuntimeEnvironmentOption>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(RuntimeEnvironmentOption.fromJson)
        .where((item) => item.isUsable)
        .toList(growable: false);
  }

  Future<AgentItem> createAgent({
    required String name,
    String? description,
    String? internalDescription,
    String? welcomeMsg,
    String? systemPrompt,
    List<String>? tags,
    String? modelPrimary,
    // ADR-0037 BYOK（契约 §12.3）：modelSource='byok' 时忽略 modelPrimary，
    // 改用下面四个字段直连用户自己配置的模型服务；modelSource 为空/
    // 'platform_whitelist' 是服务端管理蜂桥成员凭证的内部标记，模型按成员可用列表校验。
    String? modelSource,
    String? modelServiceEndpointType,
    String? modelServiceBaseUrl,
    String? modelServiceModelId,
    String? modelServiceApiKey,
    String? visibility,
    String? status,
    String? runtimeEnvironmentUuid,
    String executionLocus = 'cloud',
    String localEngine = 'dsh',
    String? agentKey,
    bool allowInternetAccess = true,
    bool contactEnabled = true,
    bool allowInviteToGroup = true,
    String? avatarUrl,
    String? position,
    String? positionLabel,
    List<String>? skillSlugs,
    List<String>? appUuids,
    Map<String, String>? appLabels,
    List<String>? knowledgeBaseUuids,
    Map<String, String>? knowledgeBaseLabels,
  }) async {
    final cleanTags = _cleanStringList(tags);
    final cleanAppUuids = _cleanStringList(appUuids);
    final cleanKnowledgeBaseUuids = _cleanStringList(knowledgeBaseUuids);
    final isByok = modelSource?.trim() == 'byok';
    final response = await request.post(
      _agents,
      data: {
        'name': name,
        'source': 'personal',
        'execution_locus': executionLocus,
        if (executionLocus == 'local') 'local_engine': localEngine,
        'visibility': 'private',
        'status': _nonEmpty(status) ?? 'published',
        'contact_enabled': true,
        'allow_invite_to_group': true,
        'supports_group_chat': true,
        if (description != null && description.trim().isNotEmpty)
          'intro': description.trim(),
        if (internalDescription != null &&
            internalDescription.trim().isNotEmpty)
          'description': internalDescription.trim(),
        if (welcomeMsg != null && welcomeMsg.trim().isNotEmpty)
          'welcome_msg': welcomeMsg.trim(),
        if (cleanTags.isNotEmpty) ...{
          'tags': cleanTags,
          'badges': cleanTags
        },
        if (isByok) ...{
          'model_source': 'byok',
          'model_service_config': {
            'endpoint_type': (modelServiceEndpointType ?? '').trim(),
            'base_url': (modelServiceBaseUrl ?? '').trim(),
            'model_id': (modelServiceModelId ?? '').trim(),
          },
          if (modelServiceApiKey != null &&
              modelServiceApiKey.trim().isNotEmpty)
            'model_service_api_key': modelServiceApiKey.trim(),
        } else if (modelPrimary != null && modelPrimary.trim().isNotEmpty)
          'model_primary': modelPrimary.trim(),
        if (runtimeEnvironmentUuid != null &&
            runtimeEnvironmentUuid.trim().isNotEmpty)
          'runtime_environment_uuid': runtimeEnvironmentUuid.trim(),
        'metadata': {
          if (agentKey != null && agentKey.trim().isNotEmpty)
            'agent_key': agentKey.trim(),
          if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
            'system_prompt': systemPrompt.trim(),
          'allow_internet_access': allowInternetAccess,
          if (appUuids != null) 'selected_app_uuids': cleanAppUuids,
          if (appLabels != null)
            'selected_app_labels': _cleanStringMap(appLabels),
          if (knowledgeBaseUuids != null)
            'selected_knowledge_base_uuids': cleanKnowledgeBaseUuids,
          if (knowledgeBaseLabels != null)
            'selected_knowledge_base_labels':
                _cleanStringMap(knowledgeBaseLabels),
        },
        if (avatarUrl != null && avatarUrl.trim().isNotEmpty)
          'avatarUrl': avatarUrl.trim(),
        if (position != null && position.trim().isNotEmpty)
          'position': position.trim(),
        if (positionLabel != null && positionLabel.trim().isNotEmpty)
          'positionLabel': positionLabel.trim(),
      },
    );
    return AgentItem.fromJson(responseAsMap(response));
  }

  Future<AgentItem> updateAgent({
    required String agentId,
    String? name,
    String? description,
    String? internalDescription,
    String? welcomeMsg,
    String? systemPrompt,
    List<String>? tags,
    String? modelPrimary,
    // ADR-0037 BYOK（契约 §12.3）。跟 createAgent 同款语义，唯一区别：
    // modelSource 只要非空就一定下发（哪怕值仍是 'platform_whitelist'），
    // 这是从 byok 切回白名单时让服务端自动清空遗留 api_key 的必要信号——
    // 不能像 modelPrimary 那样"空就不传"，那样服务端会以为这次编辑压根没碰
    // 模型来源字段。modelServiceApiKey 是三态字段：不传=不动已存的 key，
    // 传空字符串=显式清空，传非空=写入/轮转。
    String? modelSource,
    String? modelServiceEndpointType,
    String? modelServiceBaseUrl,
    String? modelServiceModelId,
    String? modelServiceApiKey,
    String? visibility,
    String? status,
    String? runtimeEnvironmentUuid,
    String? executionLocus,
    String? localEngine,
    String? agentKey,
    bool? allowInternetAccess,
    bool? contactEnabled,
    bool? allowInviteToGroup,
    String? avatarUrl,
    String? position,
    String? positionLabel,
    List<String>? skillSlugs,
    List<String>? appUuids,
    Map<String, String>? appLabels,
    List<String>? knowledgeBaseUuids,
    Map<String, String>? knowledgeBaseLabels,
  }) async {
    final cleanTags = _cleanStringList(tags);
    final cleanAppUuids = _cleanStringList(appUuids);
    final cleanKnowledgeBaseUuids = _cleanStringList(knowledgeBaseUuids);
    final hasCapabilityMetadata = systemPrompt != null ||
        appUuids != null ||
        appLabels != null ||
        knowledgeBaseUuids != null ||
        knowledgeBaseLabels != null;
    final isByok = modelSource?.trim() == 'byok';
    final response = await request.put(
      '$_agents/${Uri.encodeComponent(agentId)}',
      data: {
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (executionLocus != null) 'execution_locus': executionLocus,
        if (executionLocus == 'local' && localEngine != null)
          'local_engine': localEngine,
        if (description != null) 'intro': description.trim(),
        if (internalDescription != null)
          'description': internalDescription.trim(),
        if (welcomeMsg != null) 'welcome_msg': welcomeMsg.trim(),
        if (tags != null) ...{
          'tags': cleanTags,
          'badges': cleanTags
        },
        if (modelSource != null) 'model_source': modelSource.trim(),
        if (isByok) ...{
          'model_service_config': {
            'endpoint_type': (modelServiceEndpointType ?? '').trim(),
            'base_url': (modelServiceBaseUrl ?? '').trim(),
            'model_id': (modelServiceModelId ?? '').trim(),
          },
          if (modelServiceApiKey != null)
            'model_service_api_key': modelServiceApiKey.trim(),
        } else if (modelPrimary != null && modelPrimary.trim().isNotEmpty)
          'model_primary': modelPrimary.trim(),
        'visibility': 'private',
        if (status != null && status.trim().isNotEmpty) 'status': status.trim(),
        if (runtimeEnvironmentUuid != null &&
            runtimeEnvironmentUuid.trim().isNotEmpty)
          'runtime_environment_uuid': runtimeEnvironmentUuid.trim(),
        if ((agentKey != null && agentKey.trim().isNotEmpty) ||
            allowInternetAccess != null ||
            hasCapabilityMetadata)
          'metadata': {
            if (agentKey != null && agentKey.trim().isNotEmpty)
              'agent_key': agentKey.trim(),
            if (allowInternetAccess != null)
              'allow_internet_access': allowInternetAccess,
            // 空串 = 清空人设，Bus 合并写入后按名称/职责渲染兜底人设。
            if (systemPrompt != null) 'system_prompt': systemPrompt.trim(),
            if (appUuids != null) 'selected_app_uuids': cleanAppUuids,
            if (appLabels != null)
              'selected_app_labels': _cleanStringMap(appLabels),
            if (knowledgeBaseUuids != null)
              'selected_knowledge_base_uuids': cleanKnowledgeBaseUuids,
            if (knowledgeBaseLabels != null)
              'selected_knowledge_base_labels':
                  _cleanStringMap(knowledgeBaseLabels),
          },
        'contact_enabled': true,
        'allow_invite_to_group': true,
        'supports_group_chat': true,
        if (avatarUrl != null) 'avatarUrl': avatarUrl.trim(),
        if (position != null && position.trim().isNotEmpty)
          'position': position.trim(),
        if (positionLabel != null) 'positionLabel': positionLabel.trim(),
      },
    );
    return AgentItem.fromJson(responseAsMap(response));
  }

  Future<void> replaceAgentSkillBindings({
    required String agentId,
    required List<String> skillSlugs,
  }) async {
    await request.put(
      '$_agents/${Uri.encodeComponent(agentId)}/skill-bindings',
      data: {
        'skill_slugs': _cleanStringList(skillSlugs)
      },
    );
  }

  /// 替换数字员工的应用绑定。此前应用只存 metadata label、从未真绑定到
  /// agent_app_bindings(运行时拿不到)；本接口走与技能同款的 replace 流真落库。
  Future<void> replaceAgentAppBindings({
    required String agentId,
    required List<String> appUuids,
  }) async {
    await request.put(
      '$_agents/${Uri.encodeComponent(agentId)}/app-bindings',
      data: {
        'app_uuids': _cleanStringList(appUuids)
      },
    );
  }

  /// 替换数字员工的知识库绑定（同上，真落库 agent_kb_bindings；运行时 Recall 据此校验）。
  Future<void> replaceAgentKnowledgeBaseBindings({
    required String agentId,
    required List<String> knowledgeBaseUuids,
  }) async {
    await request.put(
      '$_agents/${Uri.encodeComponent(agentId)}/kb-bindings',
      data: {
        'kb_uuids': _cleanStringList(knowledgeBaseUuids)
      },
    );
  }

  static String? _nonEmpty(String? value) {
    final v = value?.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  static List<String> _cleanStringList(List<String>? values) {
    if (values == null) return const <String>[];
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      final v = value.trim();
      if (v.isEmpty || !seen.add(v)) continue;
      out.add(v);
    }
    return out;
  }

  static Map<String, String> _cleanStringMap(Map<String, String>? values) {
    if (values == null) return const <String, String>{};
    final out = <String, String>{};
    for (final entry in values.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty) continue;
      out[key] = value.isEmpty ? key : value;
    }
    return out;
  }

  static AgentItem _agentFromDetailResponse(Map<String, dynamic> json) {
    final rawAgent = json['agent'] ?? json['Agent'];
    if (rawAgent is Map) {
      final agent = Map<String, dynamic>.from(rawAgent);
      final rawSkills = json['skills'] ?? json['Skills'];
      if (rawSkills is List && agent['skills'] is! List) {
        agent['skills'] = rawSkills;
      }
      return AgentItem.fromJson(agent);
    }
    return AgentItem.fromJson(json);
  }

  Future<AgentItem> setDefaultAgent(String agentId) async {
    final response = await request.post(
      '$_agents/${Uri.encodeComponent(agentId)}/set-default',
      data: const {},
    );
    return AgentItem.fromJson(responseAsMap(response));
  }

  Future<void> deleteAgent(String agentId) async {
    await request.delete('$_agents/${Uri.encodeComponent(agentId)}');
  }

  Future<List<ConversationItem>?> getCachedConversations() async {
    try {
      return (await _history.cachedConversationList())
          ?.map(ConversationItem.fromJson)
          .toList();
    } catch (e) {
      debugPrint('[conversation-cache] invalid snapshot (${e.runtimeType})');
      return null;
    }
  }

  /// 统一会话列表 agent-bus `/chat/conversations`（返回 `{items,total}`）。
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async {
    final offset = (page - 1) * pageSize;
    final query = <String, dynamic>{
      'limit': pageSize,
      'offset': offset < 0 ? 0 : offset,
    };
    if (includeHidden) {
      query['include_hidden'] = 1;
    }
    final items = await _history.conversationList(query,
        cacheDefaultPage: page == 1 && pageSize == 40 && !includeHidden);
    return items.map(ConversationItem.fromJson).toList();
  }

  /// doc-13 §A：agent-bus **无独立"创建会话"端点**。数字员工单聊会话由首条
  /// [sendMessage]（`POST /chat/send`，带 `agent_uuid`）在服务端按 `(account, agent)`
  /// resolve-或-create。卡片点击应进入"绑定 agent 的空会话"，首条发送即建会话。
  @Deprecated(
      'agent-bus 无创建会话端点；单聊会话由首条 sendMessage(/chat/send) 创建。见 contract §3.0')
  Future<ConversationItem> createConversation({
    required String agentId,
    String? alias,
  }) async {
    throw UnsupportedError(
      'agent-bus 无创建会话端点；数字员工单聊会话由首条 /chat/send 创建（contract §3.0）',
    );
  }

  Future<void> deleteConversation(String conversationId) =>
      _history.deleteConversation(conversationId);

  /// 恢复本账号隐藏过的会话。用于从通讯录/搜索重新打开「不显示」后的 direct conversation。
  Future<void> showConversation(String conversationId) async {
    await request.post(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/show',
      data: const {},
    );
  }

  /// 把指定会话 `unread_count` 清零 → agent-bus `POST /chat/conversations/{uuid}/read`。
  /// v2: 后端会同步清 `marked_unread_at`(若有),客户端无需额外动作。
  ///
  /// F09 P1 已读回执 v1: 可选上报 `last_read_message_seq` (WuKong message_seq) 作为
  /// per-account 已读水位; 服务端取较大者写入, 用于消息级回执聚合。`<=0` 时不上报。
  Future<void> markConversationRead(
    String conversationId, {
    int lastReadMessageSeq = 0,
  }) async {
    // 真实 conversation 落库前, 客户端本地用 "pending:<agent_uuid>" 占位符寻址 (还没有
    // 服务端会话可标记已读)。服务端已经对非法 UUID 做了 400 兜底(不再裸 500), 但这里
    // 本就不该发这个请求——发出去只会弹一个对用户没有意义的 "uuid malformed" 提示。
    if (conversationId.startsWith('pending:')) return;
    await request.post(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/read',
      options: Options(
          receiveTimeout: const Duration(seconds: 5), extra: {'silent': true}),
      data: lastReadMessageSeq > 0
          ? {'last_read_message_seq': lastReadMessageSeq}
          : const {},
    );
  }

  /// F09 P1 已读回执 v1: 批量拉取消息级回执。
  /// `GET /chat/conversations/{uuid}/read-receipts?message_seq=1,2,3`
  /// 返回的是 envelope.data 中的 items。底层不可用时调用方应捕获并隐藏 indicator。
  Future<List<Map<String, dynamic>>> getReadReceipts({
    required String conversationId,
    required List<int> messageSeqs,
  }) async {
    final filtered = messageSeqs.where((s) => s > 0).toSet().toList();
    if (filtered.isEmpty) return const <Map<String, dynamic>>[];
    final response = await request.get(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/read-receipts',
      queryParameters: {'message_seq': filtered.join(',')},
      options: Options(
          extra: {'silent': true}, receiveTimeout: const Duration(seconds: 5)),
    );
    final map = responseAsMap(response);
    final raw = map['items'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  /// 账号级 SSE: `GET /conversations/stream`。
  ///
  /// 预留给后续账号级事件。消息级已读回执实时通知不走这里,而是走 WuKong
  /// no_persist content_type=1002 信号;本方法只保留 SSE data JSON 解析能力。
  Stream<Map<String, dynamic>> streamAccountEvents() async* {
    final lineStream = apiSseLines('/conversations/stream', silent: true);
    final buffer = StringBuffer();

    Map<String, dynamic>? takeCurrent() {
      if (buffer.isEmpty) return null;
      final payload = buffer.toString().trim();
      buffer.clear();
      if (payload.isEmpty) return null;
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return null;
    }

    await for (final line in lineStream) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) {
        final event = takeCurrent();
        if (event != null) yield event;
        continue;
      }
      if (trimmed.startsWith(':')) {
        continue;
      }
      if (trimmed.startsWith('data:')) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(trimmed.substring(5).trimLeft());
      }
    }
    final event = takeCurrent();
    if (event != null) yield event;
  }

  /// F09 P2 「会话列表操作菜单 v2」: 置顶 / 取消置顶。
  /// `POST /chat/conversations/{uuid}/pin body{pinned}` → Bus per-account `pinned_at`。
  Future<void> setConversationPinned(String conversationId, bool pinned) async {
    await request.post(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/pin',
      data: {'pinned': pinned},
    );
  }

  /// F09 P2 v2: 免打扰 / 取消免打扰 (只影响红点 + 通知,不影响消息接收)。
  Future<void> setConversationMuted(String conversationId, bool muted) async {
    await request.post(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/mute',
      data: {'muted': muted},
    );
  }

  /// F09 P2 v2: 人工标为未读 (与 unread_count 独立; markRead / 新消息自动清)。
  Future<void> markConversationUnread(String conversationId) async {
    await request.post(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/unread',
      data: const {},
    );
  }

  /// F09 P2 v2: 群改名 (仅 group, 仅 creator)。
  /// `PATCH /rooms/{room_uuid} body{title}` → Bus 更新 `rooms.title`,下一次
  /// `/chat/conversations` 聚合即新 title。失败时调用方应回滚乐观 UI。
  Future<void> renameGroupRoom(String roomUuid, String title) async {
    await request.patch(
      '/rooms/${Uri.encodeComponent(roomUuid)}',
      data: {'title': title},
      options: Options(extra: const {'silent': true}),
    );
  }

  /// F09 P1: 撤回自己发送的 WuKong 时间线消息(human_direct + group)。
  /// `POST /chat/messages/revoke` body {conversation_uuid, message_id, message_seq?, client_msg_no?}.
  /// 服务端校验 caller 是消息原发送者后广播 type=98 撤回通知;失败时上游 toast「撤回失败」+回滚乐观。
  Future<void> revokeMessage({
    required String conversationUuid,
    required String messageId,
    int messageSeq = 0,
    String clientMsgNo = '',
  }) async {
    await request.post(
      '/chat/messages/revoke',
      options: Options(extra: const {'silent': true}),
      data: {
        'conversation_uuid': conversationUuid,
        if (messageId.isNotEmpty) 'message_id': messageId,
        if (messageSeq > 0) 'message_seq': messageSeq,
        if (clientMsgNo.isNotEmpty) 'client_msg_no': clientMsgNo,
      },
    );
  }

  /// 锚定 [messageUuid] ± [windowSize] 居中取一窗消息，用于自动任务卡片
  /// 「在对话中查看」深跳定位。后端：
  /// `GET /chat/conversations/{uuid}/messages/around?anchor_message_uuid&before&after`
  /// 返回 `{items:[...]}`（created_at ASC，含锚点），item DTO 与 [getHistory] 同款。
  Future<ChatHistoryAroundData> getHistoryAround({
    required String conversationId,
    required String messageUuid,
    int windowSize = 20,
  }) async {
    final response = await request.get(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/messages/around',
      queryParameters: {
        'anchor_message_uuid': messageUuid,
        'before': windowSize,
        'after': windowSize,
      },
    );
    final map = responseAsMap(response);
    final raw = map['items'] is List ? map['items'] as List : const [];
    final items = raw
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromAgentBusJson)
        .toList();
    // 后端把 id<=anchor 与 id>anchor 两段并起来按时间正序返回，锚点在前半段末尾。
    var anchorIndex = items.indexWhere((m) => m.uuid == messageUuid);
    if (anchorIndex < 0) anchorIndex = items.isEmpty ? 0 : items.length - 1;
    // 某一侧拉满窗口上限 → 该方向大概率还有更多（后端不返 has_more，按条数推断）。
    final beforeCount = anchorIndex + 1; // 含锚点
    final afterCount = items.length - beforeCount;
    return ChatHistoryAroundData(
      items: items,
      hasMoreUp: beforeCount >= windowSize,
      hasMoreDown: afterCount >= windowSize,
      anchorIndex: anchorIndex,
    );
  }

  /// 取 [afterMessageUuid] 之后更新的消息（向下分页 / 深跳后向下加载）。后端：
  /// `GET /chat/conversations/{uuid}/messages/newer?since_message_uuid&limit`
  /// 返回 `{items:[...]}`（id>since 时间正序），item DTO 与 [getHistory] 同款。
  Future<List<ChatMessage>> getHistoryNewer({
    required String conversationId,
    required String afterMessageUuid,
    int pageSize = 20,
  }) async {
    final response = await request.get(
      '$_chatConversations/${Uri.encodeComponent(conversationId)}/messages/newer',
      queryParameters: {
        if (afterMessageUuid.isNotEmpty) 'since_message_uuid': afterMessageUuid,
        'limit': pageSize,
      },
    );
    final map = responseAsMap(response);
    final raw = map['items'] is List ? map['items'] as List : const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromAgentBusJson)
        .toList();
  }

  /// 拉历史消息 → agent-bus `GET /chat/conversations/{uuid}/messages`（返回 `{items:[...]}`）。
  /// 客户端只认 agent-bus 当前契约字段（snake_case + EMP blocks），不兼容旧 shape。
  Future<List<ChatMessage>> getHistory({
    required String conversationId,
    int page = 1,
    int pageSize = 50,
    String? before,
  }) async {
    if ((before == null || before.isEmpty) && page > 1) {
      throw StateError('加载更早消息需要服务端消息游标');
    }
    return (await _history.latest(conversationId,
            limit: pageSize, before: before))
        .map(ChatMessage.fromAgentBusJson)
        .toList();
  }

  /// 发送数字员工单聊消息 → agent-bus `POST /chat/send`。
  ///
  /// doc-13 §A create-on-first-send：[conversationId] 为空时由后端按 `(account, agent)`
  /// 建/取单聊会话；[agentUuid] 必填（agent-bus `SendReq.agent_uuid` 必填）。
  /// 返回 `{conversation_uuid, stream_id, user_message_uuid, agent_message_uuid}`。
  ///
  /// [blocks] 仅透传 text/markdown/skill；附件继续用 [files] 的 `file_uuids`
  /// 绑定，避免服务端再次 append attachment block。这样 WuKong 直发与降级路径
  /// 都以同一份 skill block 作为展示和运行时真相。
  Future<SendMessageResponse> sendMessage({
    String? conversationId,
    String? agentUuid,
    String? localDeviceId,
    String? localContextId,
    String? modelHint,
    required String prompt,
    List<ChatFileItem> files = const [],
    List<String> skillSlugs = const [],
    List<ImMessageBlock> blocks = const [],
  }) async {
    final fileUuids = files
        .map((f) => f.driveFileUuid ?? f.uuid)
        .whereType<String>()
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
    final requestBlocks = _fallbackChatBlocks(
      prompt: prompt,
      skillSlugs: skillSlugs,
      blocks: blocks,
    );
    final response = await request.post(
      _chatSend,
      options: Options(extra: const {'silent': true}),
      data: {
        if (agentUuid != null && agentUuid.isNotEmpty) 'agent_uuid': agentUuid,
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_uuid': conversationId,
        'text': prompt,
        if (localDeviceId != null) 'local_device_id': localDeviceId,
        if (localContextId != null) 'local_context_id': localContextId,
        if (modelHint != null && modelHint.isNotEmpty) 'model_hint': modelHint,
        if (requestBlocks.isNotEmpty) 'blocks': requestBlocks,
        if (fileUuids.isNotEmpty) 'file_uuids': fileUuids,
      },
    );
    return SendMessageResponse.fromJson(responseAsMap(response));
  }

  List<Map<String, dynamic>> _fallbackChatBlocks({
    required String prompt,
    required List<String> skillSlugs,
    required List<ImMessageBlock> blocks,
  }) {
    final out = <Map<String, dynamic>>[];
    final seenSkills = <String>{};
    var hasText = false;
    for (final block in blocks) {
      if (block.isSkill) {
        final slug = block.skillSlug.trim();
        if (slug.isEmpty || !seenSkills.add(slug)) continue;
        out.add(block.toJson());
      } else if (block.isText || block.isMarkdown) {
        if (block.text.trim().isEmpty) continue;
        hasText = true;
        out.add(block.toJson());
      }
    }
    for (final raw in skillSlugs) {
      final slug = raw.trim();
      if (slug.isEmpty || !seenSkills.add(slug)) continue;
      out.add({'type': 'skill', 'slug': slug});
    }
    if (!hasText && prompt.trim().isNotEmpty) {
      out.add({'type': 'plain', 'text': prompt.trim()});
    }
    return out;
  }

  /// 发送 room-backed agent-direct 附件消息 → `POST /rooms/{room_uuid}/messages`。
  ///
  /// 普通群聊仍走 WuKong SDK；这里只用于既有 `agent_direct + room_uuid` 会话在
  /// mixed 附件双通道不稳定时绑定 `file_uuids` 并启动同一 room 的 agent run。
  Future<SendMessageResponse> sendRoomMessage({
    String? modelHint,
    List<ImMessageBlock> blocks = const [],
    required String roomUuid,
    required String prompt,
    List<ChatFileItem> files = const [],
  }) async {
    final fileUuids = files
        .map((f) => f.driveFileUuid ?? f.uuid)
        .whereType<String>()
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
    final response = await request.post(
      '/rooms/${Uri.encodeComponent(roomUuid)}/messages',
      options: Options(extra: const {'silent': true}),
      data: {
        'text': prompt,
        if (blocks.isNotEmpty)
          'blocks': blocks
              .where((b) => b.isText || b.isMarkdown || b.isSkill)
              .map((b) => b.toJson())
              .toList(),
        if (modelHint != null && modelHint.isNotEmpty) 'model_hint': modelHint,
        if (fileUuids.isNotEmpty) 'file_uuids': fileUuids,
      },
    );
    return SendMessageResponse.fromRoomJson(responseAsMap(response));
  }

  /// ADR-0026 agent-direct 双通道:发消息**前**确保 WuKong channel + canonical 会话。
  /// 后端 flag=false / 未接线 → 404 → 抛 [AgentDirectDisabledException](调用方 fallback 旧 `/chat/send`)。
  Future<AgentDirectPrepareResult> prepareAgentDirectWuKong(
      String agentUuid) async {
    final response = await request.post(
      _agentDirectPrepare,
      options: Options(extra: const {'silent': true}),
      data: {'agent_uuid': agentUuid},
    );
    if (response.statusCode == 404) {
      throw const AgentDirectDisabledException();
    }
    return AgentDirectPrepareResult.fromJson(responseAsMap(response));
  }

  /// ADR-0026 agent-direct 双通道:发完 WuKong user message 后据 `wukong_message_id` 拿 run 的 stream。
  /// **只读**:后端不触发 run、不写 shadow。404 → [AgentDirectDisabledException]。
  Future<AgentDirectAttachResult> attachAgentDirectStream({
    required String conversationUuid,
    required String wukongChannelId,
    required String wukongMessageId,
    String? clientMsgNo,
  }) async {
    final response = await request.post(
      _agentDirectAttach,
      options: Options(extra: const {'silent': true}),
      data: {
        'conversation_uuid': conversationUuid,
        'wukong_channel_id': wukongChannelId,
        'wukong_message_id': wukongMessageId,
        if (clientMsgNo != null && clientMsgNo.isNotEmpty)
          'client_msg_no': clientMsgNo,
      },
    );
    if (response.statusCode == 404) {
      throw const AgentDirectDisabledException();
    }
    return AgentDirectAttachResult.fromJson(responseAsMap(response));
  }

  /// ADR-0028 §4.6 / Plan 16 §J — HITL `/chat/respond` 提交。
  ///
  /// 业务场景: ZAP runtime 透出 `message.awaiting_user` 后, 客户端在 EmpBlocksView
  /// 富组件里点击同意/拒绝/提交表单/执行 action; 通过本方法把 typed reply 提交
  /// 给后端, 后端经原子 claim 旧 awaiting_user message + 起新 stream → 客户端用
  /// 返回的**新** `stream_id` 重新订阅 `/chat/stream` 承接 runtime 下一轮输出。
  ///
  /// [responseKind] ∈ `approval` / `confirm` / `form` / `action`。
  /// [responsePayload] shape (Plan §J.3, 与后端 `buildRespondReplyBlock` 对齐):
  ///   - approval: `{decision: 'approve'|'reject', reason?: string}`
  ///   - confirm:  `{confirmed: bool}`
  ///   - form:     `{fields: {...}}`
  ///   - action:   `{action_id: string, params?: object}`
  ///
  /// 返回 `RespondToAgentMessageResponse`, 含 **新** stream_id + **新** agent
  /// message uuid (与原 awaiting_user 那条不同, 不复用旧 stream)。
  ///
  /// 错误码语义 (ADR §4.8):
  /// - 400 InvalidParams: 字段缺 / UUID 格式错 / kind 非法 — 客户端应不重试
  /// - 404 NotFound: 任一资源不属于 caller (msg 不是 awaiting_user / 已被claim / room conv 等)
  ///   统一不暴露子原因; 客户端按 "已被处理过 / 找不到" toast
  /// - 409 + `chat.session_expired_for_respond`: zap_session 过期; 客户端引导重开会话
  /// - 5xx: 装配错 / runtime 抖动 — 客户端可重试
  ///
  /// Bus 把 raw runtime error 已 sanitize 成固定文案; 客户端不暴露 raw 字符串。
  Future<RespondToAgentMessageResponse> respondToAgentMessage({
    required String conversationUuid,
    required String agentMessageUuid,
    required String responseKind,
    required Map<String, dynamic> responsePayload,
  }) async {
    final response = await request.post(
      _chatRespond,
      data: {
        'conversation_uuid': conversationUuid,
        'agent_message_uuid': agentMessageUuid,
        'response_kind': responseKind,
        'response_payload': responsePayload,
      },
    );
    return RespondToAgentMessageResponse.fromJson(responseAsMap(response));
  }

  Future<void> decideA2AApproval({
    required String approvalRequestId,
    required String decision,
    String? reason,
    Map<String, dynamic>? formResult,
  }) async {
    final body = <String, dynamic>{
      'decision': decision,
      'form_result': formResult ?? const <String, dynamic>{},
    };
    final trimmedReason = reason?.trim();
    if (trimmedReason != null && trimmedReason.isNotEmpty) {
      body['reason'] = trimmedReason;
    }
    await request.post(
      '$_a2aApprovals/${Uri.encodeComponent(approvalRequestId)}/decide',
      data: body,
    );
  }

  /// 中止数字员工单聊 → agent-bus `POST /messages/{agent_message_uuid}/stop`。
  /// [messageId] 必须是 **agent 消息 uuid**（send 回传的 `agent_message_uuid`）。
  Future<void> stopMessage({required String messageId}) async {
    final response = await request.post(
      _messageStop.replaceAll('{messageId}', Uri.encodeComponent(messageId)),
      data: const {},
      options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5)),
    );
    if ((response.statusCode ?? 500) >= 400 ||
        (response.data is Map && response.data['success'] == false)) {
      throw StateError('停止请求未确认');
    }
  }

  Future<({String url, String? uuid, String? driveFileUuid})> uploadFile(
      ChatFileItem item) async {
    if (item.filePath == null || item.filePath!.isEmpty) {
      throw Exception('文件路径为空');
    }

    final fileUuid = await _messageFiles.uploadFile(
      filePath: item.filePath!,
      fileName: item.fileName,
      mimeType: _mimeTypeForChatFile(item),
    );
    return (
      url: _messageFileUrl(fileUuid, item.fileType),
      uuid: fileUuid,
      driveFileUuid: fileUuid,
    );
  }

  /// 数字员工头像是租户内共享展示资产，不复用受会话权限约束的 message-files。
  Future<AgentAvatarUploadResult> uploadAgentAvatar({
    required String filePath,
    required String fileName,
  }) async {
    if (filePath.trim().isEmpty) throw Exception('文件路径为空');
    final response = await uploadApiFile(
      '/agents/avatar/upload',
      file: ApiUploadFile(path: filePath, fileName: fileName),
    );
    return AgentAvatarUploadResult.fromJson(responseAsMap(response));
  }

  static String _messageFileUrl(String fileUuid, ChatFileType type) {
    final encoded = Uri.encodeComponent(fileUuid);
    if (type == ChatFileType.image || type == ChatFileType.video) {
      return '/message-files/$encoded/preview';
    }
    return '/message-files/$encoded/download';
  }

  static String _mimeTypeForChatFile(ChatFileItem item) {
    final name = item.fileName.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last : '';
    if (item.fileType == ChatFileType.image) {
      switch (ext) {
        case 'png':
          return 'image/png';
        case 'gif':
          return 'image/gif';
        case 'webp':
          return 'image/webp';
        case 'bmp':
          return 'image/bmp';
        case 'jpg':
        case 'jpeg':
          return 'image/jpeg';
        default:
          return 'image/png';
      }
    }
    if (item.fileType == ChatFileType.video) {
      switch (ext) {
        case 'mov':
          return 'video/quicktime';
        case 'webm':
          return 'video/webm';
        case 'm4v':
          return 'video/x-m4v';
        default:
          return 'video/mp4';
      }
    }
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'csv':
        return 'text/csv';
      case 'txt':
        return 'text/plain';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  /// 订阅数字员工单聊流 → agent-bus `GET /chat/stream?stream_id=`（SSE）。
  ///
  /// doc-13 §A SSE 适配：agent-bus 事件 envelope 为 `{kind, message_uuid, role, blocks,
  /// text(累计快照), usage, error_code, error_message, final}`。本方法把它**翻译**成 ChatNotifier
  /// 既有事件词表（`message`/`usage`/`error`/`stopped` + `finished`），并把后端**累计** `text`
  /// 转成**增量 delta**（客户端 `_applyMessageEvent` 按 delta 追加）。事件名映射：
  ///   - `message.block.delta` → `{eventType:'message', content:<delta>, finished:false}`
  ///   - `message.tool_call`   → `{eventType:'tool_call', toolCallId, toolName, toolStatus, toolArgs/Delta}`
  ///   - `message.tool_result` → `{eventType:'tool_result', toolCallId, toolStatus, toolResult/Delta}`
  ///   - `message.reasoning`   → `{eventType:'reasoning', reasoning:<delta>}`
  ///   - `message.stage`       → `{eventType:'stage', stageId, stageText}`
  ///   - `message.stage_done`  → `{eventType:'stage_done'}`
  ///   - `message.completed`   → `{eventType:'usage',...}` + `{eventType:'message', content:<final>, finished:true}` + onDone
  ///   - `message.failed`      → `{eventType:'error', error:<msg>}` + onDone
  ///   - `message.cancelled`   → `{eventType:'stopped'}` + onDone
  ///   - `message.awaiting_user` → `{eventType:'awaiting_user', message_uuid, awaiting_block_id?, blocks, finished:true}` + onDone (ADR-0028 §4.2 HITL pause)
  ///   - `message.created`     → 忽略（agent_message_uuid 已由 send 回传）
  Future<void> streamMessage({
    required String streamId,
    required Future<void> Function(Map<String, dynamic> json) onEvent,
    required Future<void> Function() onDone,
    ChatStreamCancelHandle? cancelHandle,
  }) async {
    final lineStream = apiSseLines(
      '$_chatStream?stream_id=${Uri.encodeQueryComponent(streamId)}',
    );

    final buffer = StringBuffer();
    var accumulated = '';
    var done = false;

    // 契约 §3.0f defense-in-depth：把 envelope 里的身份字段透传给上层
    // （字段可能为空——如 message.cancelled 的 conversation_uuid 反查失败为空；
    // 上层「非空才校验」，缺失时仍按 runtime target 处理）。
    Map<String, dynamic> identityOf(Map<String, dynamic> ev) => {
          'conversation_uuid': (ev['conversation_uuid'] ?? '').toString(),
          'message_uuid': (ev['message_uuid'] ?? '').toString(),
          'stream_id': (ev['stream_id'] ?? '').toString(),
        };

    Future<void> emitCurrent() async {
      if (buffer.isEmpty) return;
      final payload = buffer.toString().trim();
      buffer.clear();
      if (payload.isEmpty) return;
      final ev = jsonDecode(payload) as Map<String, dynamic>;
      final identity = identityOf(ev);
      Future<void> emit(Map<String, dynamic> json) =>
          onEvent({...identity, ...json});
      final kind = (ev['kind'] ?? '').toString();
      switch (kind) {
        case 'message.block.delta':
          if (ev['local_artifacts'] == true) {
            await emit({
              'eventType': 'local_artifacts',
              'blocks': ev['blocks'] ?? <dynamic>[]
            });
          }
          final full = (ev['text'] ?? '').toString();
          String delta;
          if (full.startsWith(accumulated)) {
            delta = full.substring(accumulated.length);
          } else {
            delta = full; // 累计串被重写（少见）→ 整段覆盖
          }
          accumulated = full;
          if (delta.isNotEmpty) {
            await emit(
                {'eventType': 'message', 'content': delta, 'finished': false});
          }
          break;
        case 'message.tool_call':
          await emit({
            'eventType': 'tool_call',
            'toolCallId': (ev['tool_call_id'] ?? '').toString(),
            'toolName': (ev['tool_name'] ?? '').toString(),
            'toolStatus': (ev['tool_status'] ?? '').toString(),
            'toolArgs': (ev['tool_args'] ?? '').toString(),
            'toolArgsDelta': (ev['tool_args_delta'] ?? '').toString(),
          });
          break;
        case 'message.tool_result':
          await emit({
            'eventType': 'tool_result',
            'toolCallId': (ev['tool_call_id'] ?? '').toString(),
            'toolName': (ev['tool_name'] ?? '').toString(),
            'toolStatus': (ev['tool_status'] ?? '').toString(),
            'toolResult': (ev['tool_result'] ?? '').toString(),
            'toolResultDelta': (ev['tool_result_delta'] ?? '').toString(),
          });
          break;
        case 'message.a2a_approval':
          final rawBlocks = ev['blocks'];
          await emit({
            'eventType': 'a2a_approval',
            'message_uuid': (ev['message_uuid'] ?? '').toString(),
            if (rawBlocks is List) 'blocks': rawBlocks,
          });
          break;
        case 'message.reasoning':
          await emit({
            'eventType': 'reasoning',
            'reasoning': (ev['reasoning'] ?? '').toString(),
          });
          break;
        case 'message.stage':
          await emit({
            'eventType': 'stage',
            'stageId': (ev['stage_id'] ?? '').toString(),
            'stageText': (ev['stage_text'] ?? '').toString(),
          });
          break;
        case 'message.stage_done':
          await emit({'eventType': 'stage_done'});
          break;
        case 'message.completed':
          final usage = ev['usage'];
          if (usage is Map) {
            await emit({
              'eventType': 'usage',
              ...usage.map((k, v) => MapEntry(k.toString(), v)),
            });
          }
          final finalText = _blocksToText(ev['blocks']);
          // Batch 1: 终态把 raw EMP blocks 透给 ChatNotifier (在 'finished:true'
          // 同一帧附带 'blocks' 字段)。形态尽量贴 List<Map<String,dynamic>>; 解析
          // 失败 / 字段坏 → 由 ChatNotifier 侧 best-effort 退化, 走 content fallback。
          final rawBlocks = ev['blocks'];
          await emit({
            'eventType': 'message',
            'content': finalText.isNotEmpty ? finalText : accumulated,
            'finished': true,
            if (rawBlocks is List) 'blocks': rawBlocks,
          });
          done = true;
          await onDone();
          break;
        case 'message.failed':
          final errorCode = (ev['error_code'] ?? '').toString();
          final errorMessage = (ev['error_message'] ?? '').toString();
          final rawBlocks = ev['blocks'];
          await emit({
            'eventType': 'error',
            'error': formatBackendErrorPayload(
              errorCode: errorCode,
              errorMessage: errorMessage,
              fallback: '生成失败',
            ),
            'error_message': errorMessage,
            'error_code': errorCode,
            if (rawBlocks is List) 'blocks': rawBlocks,
          });
          done = true;
          await onDone();
          break;
        case 'message.cancelled':
          await emit({
            'eventType': 'stopped',
            if (ev['blocks'] is List) 'blocks': ev['blocks'],
          });
          done = true;
          await onDone();
          break;
        case 'message.awaiting_user':
          // ADR-0028 / Plan 16 §J — HITL pause. 后端 awaitFinalize 已:
          //   - messages.status='awaiting_user' + final=true 落库
          //   - SSE payload 形态: {kind:'message.awaiting_user', message_uuid, blocks, final:true}
          //     (可选 awaiting_block_id, 未来扩展)
          // 客户端: 透出 raw blocks + awaitingBlockId; ChatNotifier 据此把对应 assistant
          // message 切到 raw status='awaiting_user', 触发 EmpBlocksView 富组件 enable。
          final rawBlocks = ev['blocks'];
          final awaitingBlockId = ev['awaiting_block_id']?.toString();
          await emit({
            'eventType': 'awaiting_user',
            'message_uuid': (ev['message_uuid'] ?? '').toString(),
            'awaiting_block_id': awaitingBlockId,
            if (rawBlocks is List) 'blocks': rawBlocks,
            'finished': true,
          });
          done = true;
          await onDone();
          break;
        case 'message.created':
        default:
          break;
      }
    }

    // 契约 §3.0f C12：用 StreamIterator 而非 await-for，让 cancelHandle 能真正
    // 中断底层订阅（cancel 时 pending 的 moveNext 以 false 完成，HTTP 连接关闭）。
    final iterator = StreamIterator<String>(lineStream);
    cancelHandle?.attach(() {
      unawaited(iterator.cancel());
    });
    try {
      while (await iterator.moveNext()) {
        if (cancelHandle?.isCancelled ?? false) break;
        final line = iterator.current;
        final trimmed = line.trimRight();
        if (trimmed.isEmpty) {
          await emitCurrent();
          if (done) return;
          continue;
        }
        if (trimmed.startsWith('data:')) {
          if (buffer.isNotEmpty) {
            buffer.write('\n');
          }
          buffer.write(trimmed.substring(5).trimLeft());
        }
      }
    } finally {
      cancelHandle?.detach();
    }
    if (cancelHandle?.isCancelled ?? false) {
      // 客户端主动取消（stop / logout / 删除会话 / dispose）：不再回调 onDone，
      // 终态由取消方收口，避免把「取消」误当「自然完成」。
      return;
    }
    await emitCurrent();
    if (!done) {
      // 流自然结束但未见终态事件 → 兜底收口。
      await onDone();
    }
  }
}

/// 契约 §3.0f C12：`/chat/stream` 订阅的真取消句柄。
/// [cancel] 会中断 [OpenClawChatService.streamMessage] 内部的底层订阅；
/// 订阅尚未建立时先记 cancelled，attach 后立即生效。
class ChatStreamCancelHandle {
  bool _cancelled = false;
  void Function()? _abort;

  bool get isCancelled => _cancelled;

  void attach(void Function() abort) {
    _abort = abort;
    if (_cancelled) {
      final a = _abort;
      _abort = null;
      a?.call();
    }
  }

  void detach() {
    _abort = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final a = _abort;
    _abort = null;
    a?.call();
  }
}

String chatRevokeFailureMessage(Object error) {
  final detail = formatError(error, fallback: '撤回失败');
  if (detail.contains('chat.revoke.not_owner')) {
    return '只能撤回自己发送的消息';
  }
  if (detail.contains('chat.revoke.message_not_found') ||
      detail.contains('message not found')) {
    return '撤回失败:消息同步中，请稍后再试';
  }
  if (detail.contains('conversation has no WuKong channel')) {
    return '该会话暂不支持撤回';
  }
  if (detail.contains('upstream_failed') || detail.contains('revoke lookup')) {
    return '撤回失败:服务同步中，请稍后再试';
  }
  if (detail.isNotEmpty && detail != '撤回失败') {
    return '撤回失败:$detail';
  }
  return '撤回失败';
}

/// 从 EMP blocks 提取纯文本（plain / markdown / text 块的 text/markdown 字段拼接）。
/// 与 agent-bus 服务端 finalize 的 blocks 形态对齐；用于历史与终态消息正文。
///
/// Completed messages carry structured EMP blocks alongside the body. Only plain
/// blocks belong in content; readable card summaries are for list previews and
/// would otherwise leak placeholders such as [file] into the rendered answer.
String _blocksToText(dynamic blocks) =>
    plainBlocksText(ChatMessage.withoutA2ATimelineBlocks(blocks));
