import 'dart:convert';

import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:zhiban_core/utils/error_utils.dart';

class CreateAgentDraft {
  const CreateAgentDraft({
    required this.name,
    required this.description,
    required this.avatarUrl,
    this.avatarDisplayUrl = '',
    this.internalDescription = '',
    this.welcomeMsg = '',
    this.systemPrompt = '',
    this.tags = const [],
    this.modelPrimary = '',
    this.modelSource = 'platform_whitelist',
    this.modelServiceEndpointType = '',
    this.modelServiceBaseUrl = '',
    this.modelServiceModelId = '',
    this.modelServiceApiKey,
    this.visibility = 'tenant',
    this.status = 'published',
    this.runtimeEnvironmentUuid = '',
    this.executionLocus = 'cloud',
    this.localEngine = 'dsh',
    this.agentKey = 'default',
    this.allowInternetAccess = true,
    this.contactEnabled = true,
    this.allowInviteToGroup = true,
    this.position = '',
    this.positionLabel = '',
    this.skillSlugs = const [],
    this.skillLabels = const {},
    this.appUuids = const [],
    this.appLabels = const {},
    this.knowledgeBaseUuids = const [],
    this.knowledgeBaseLabels = const {},
    this.deleteRequested = false,
  });

  final String name;
  final String description;

  /// 提交给 Bus 持久化的头像引用。新上传头像使用 `oss://agent-avatars/*`。
  final String avatarUrl;

  /// 仅供本次创建 / 编辑完成后的客户端即时展示，不提交给 Bus。
  /// 新上传头像使用上传响应里的短期 `signed_url`。
  final String avatarDisplayUrl;
  final String internalDescription;
  final String welcomeMsg;

  /// 人设（系统提示词），对应 Bus metadata.system_prompt；空 = 由 Bus 按名称/职责渲染兜底人设。
  final String systemPrompt;
  final List<String> tags;
  final String modelPrimary;

  /// ADR-0037 BYOK（契约 §12.3）。'platform_whitelist'（默认）走 [modelPrimary]；
  /// 'byok' 时下面三个字段 + [modelServiceApiKey] 生效。
  final String modelSource;
  final String modelServiceEndpointType;
  final String modelServiceBaseUrl;
  final String modelServiceModelId;

  /// modelSource='byok' 时，弹框提交前直接从本地 `ModelServiceStore`
  /// 读出所选模型服务当前配置的明文 key——不在这个
  /// 表单里重新收集一遍（key 已经在「模型服务」页配置过了）。null=非 BYOK
  /// 模式，或 BYOK 但未能解出 key（此时不应该提交，见 [CreateAgentDraft]
  /// 构造前的校验）。提交后立即被服务端加密落库，客户端这份引用用完即弃，
  /// 不做任何额外的本地持久化。
  final String? modelServiceApiKey;
  final String visibility;
  final String status;
  final String runtimeEnvironmentUuid;
  final String executionLocus;
  final String localEngine;
  final String agentKey;
  final bool allowInternetAccess;
  final bool contactEnabled;
  final bool allowInviteToGroup;
  final String position;
  final String positionLabel;
  final List<String> skillSlugs;
  final Map<String, String> skillLabels;
  final List<String> appUuids;
  final Map<String, String> appLabels;
  final List<String> knowledgeBaseUuids;
  final Map<String, String> knowledgeBaseLabels;
  final bool deleteRequested;

  const CreateAgentDraft.deleteRequest()
      : name = '',
        description = '',
        avatarUrl = '',
        avatarDisplayUrl = '',
        internalDescription = '',
        welcomeMsg = '',
        systemPrompt = '',
        tags = const [],
        modelPrimary = 'openai/gpt-5.4',
        modelSource = 'platform_whitelist',
        modelServiceEndpointType = '',
        modelServiceBaseUrl = '',
        modelServiceModelId = '',
        modelServiceApiKey = null,
        visibility = 'tenant',
        status = 'draft',
        runtimeEnvironmentUuid = '',
        executionLocus = 'cloud',
        localEngine = 'dsh',
        agentKey = '',
        allowInternetAccess = false,
        contactEnabled = false,
        allowInviteToGroup = false,
        position = '',
        positionLabel = '',
        skillSlugs = const [],
        skillLabels = const {},
        appUuids = const [],
        appLabels = const {},
        knowledgeBaseUuids = const [],
        knowledgeBaseLabels = const {},
        deleteRequested = true;

  /// 编辑弹框初始表单的唯一构造入口。契约（agent-bus-client-contract「编辑数字员工」）
  /// 要求编辑前先 `GET /agents/{uuid}` 回读完整详情；本工厂只接受回读后的
  /// [AgentItem]，不接受 `/contacts/agents` 卡片 DTO——卡片不含欢迎语 / 可见性 /
  /// 运行环境 / 知识库等编辑字段，直接当数据源会把它们覆盖成默认值。
  factory CreateAgentDraft.fromAgentItem(AgentItem agent) {
    return CreateAgentDraft(
      name: agent.name,
      description: agent.description,
      internalDescription: agent.internalDescription,
      welcomeMsg: agent.welcomeMsg,
      systemPrompt: agent.systemPrompt,
      tags: agent.tags,
      modelPrimary: agent.modelPrimary,
      modelSource: agent.modelSource,
      modelServiceEndpointType: agent.modelServiceEndpointType,
      modelServiceBaseUrl: agent.modelServiceBaseUrl,
      modelServiceModelId: agent.modelServiceModelId,
      // 编辑态默认 null（不改动已存的 key）；用户在弹框里重新输入才会覆盖。
      visibility: agent.visibility,
      status: agent.status.isEmpty ? 'published' : agent.status,
      runtimeEnvironmentUuid: agent.runtimeEnvironmentUuid,
      executionLocus: agent.executionLocus,
      localEngine: agent.localEngine,
      agentKey: agent.agentKey.isEmpty ? 'default' : agent.agentKey,
      contactEnabled: agent.contactEnabled,
      allowInviteToGroup: agent.allowInviteToGroup,
      avatarUrl: agent.avatarUrl,
      avatarDisplayUrl: agent.avatarUrl,
      position: agent.position,
      positionLabel: agent.positionLabel,
      skillSlugs: agent.skills
          .map((item) => item.slug)
          .where((slug) => slug.isNotEmpty)
          .toList(growable: false),
      skillLabels: {
        for (final skill in agent.skills)
          if (skill.slug.isNotEmpty)
            skill.slug:
                skill.skillName.isNotEmpty ? skill.skillName : skill.slug,
      },
      appUuids: {
        for (final app in agent.apps)
          if (app.id.isNotEmpty) app.id,
        ...agent.configuredAppLabels.keys,
      }.toList(growable: false),
      appLabels: {
        for (final app in agent.apps)
          if (app.id.isNotEmpty)
            app.id: app.name.isNotEmpty ? app.name : app.id,
        ...agent.configuredAppLabels,
      },
      knowledgeBaseUuids:
          agent.configuredKnowledgeBaseLabels.keys.toList(growable: false),
      knowledgeBaseLabels: agent.configuredKnowledgeBaseLabels,
    );
  }
}

class AgentAvatarUploadResult {
  const AgentAvatarUploadResult({
    required this.storageUri,
    required this.displayUrl,
  });

  /// 稳定持久化引用，只能写入数字员工配置。
  final String storageUri;

  /// 短期可加载地址，只能用于当前客户端展示。
  final String displayUrl;

  factory AgentAvatarUploadResult.fromJson(Map<String, dynamic> json) {
    final storageUri = (json['storage_uri'] ?? '').toString().trim();
    final displayUrl = (json['signed_url'] ?? '').toString().trim();
    if (!storageUri.startsWith('oss://agent-avatars/')) {
      throw Exception('头像上传结果无效');
    }
    if (displayUrl.isEmpty || displayUrl.startsWith('oss://')) {
      throw Exception('头像上传结果缺少可用预览地址');
    }
    return AgentAvatarUploadResult(
      storageUri: storageUri,
      displayUrl: displayUrl,
    );
  }
}

/// 从上传即时预览、draft、接口回读和旧列表数据中选择第一个可加载头像。
/// 未签名 `oss://` 是持久化引用，绝不能进入图片组件。
String selectAgentAvatarForDisplay({
  String draftDisplayUrl = '',
  String draftAvatarUrl = '',
  String agentAvatarUrl = '',
  String fallbackAvatarUrl = '',
}) {
  for (final candidate in [
    draftDisplayUrl,
    draftAvatarUrl,
    agentAvatarUrl,
    fallbackAvatarUrl,
  ]) {
    final value = candidate.trim();
    if (value.isNotEmpty && !value.startsWith('oss://')) return value;
  }
  return '';
}

Map<String, String> _readStringMap(dynamic raw) {
  if (raw is! Map) return const <String, String>{};
  final out = <String, String>{};
  raw.forEach((key, value) {
    final k = key.toString().trim();
    final v = value.toString().trim();
    if (k.isEmpty) return;
    out[k] = v.isEmpty ? k : v;
  });
  return out;
}

/// 把后端 hydrate 的 `[{uuid,name}]` 列表 (真实 app/kb 绑定) 解析成 {uuid: name}。
/// 用于卡片显示 + 编辑回显, 优先于历史 metadata label (那是从未真绑定的伪缓存)。
Map<String, String> _readUuidNameMap(dynamic raw) {
  if (raw is! List) return const <String, String>{};
  final out = <String, String>{};
  for (final item in raw) {
    if (item is! Map) continue;
    final uuid = (item['uuid'] ?? item['id'] ?? '').toString().trim();
    final name = (item['name'] ?? '').toString().trim();
    if (uuid.isEmpty) continue;
    out[uuid] = name.isEmpty ? uuid : name;
  }
  return out;
}

/// ADR-0037 BYOK（契约 §12.3）：`model_service_config` 在 Bus 响应里可能是已解析
/// 的 Map，也可能是一个包着 JSON 文本的 String（`DigitalEmployee.ModelServiceConfigJSON`
/// 在 Go 侧没有自定义 MarshalJSON，普通 string 字段会被当成字符串二次转义）。
/// 两种形态都兼容，解析失败一律按空 map 处理（非 BYOK 数字员工的常态）。
Map<String, dynamic> _modelServiceConfig(Map<String, dynamic> json) {
  final raw = json['model_service_config'] ??
      json['modelServiceConfig'] ??
      json['ModelServiceConfigJSON'];
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      // 忽略解析失败，回落空 map。
    }
  }
  return const <String, dynamic>{};
}

enum ChatRole { question, answer, system, systemPrompt }

enum BubbleStatus { idle, loading, success, error }

enum FeedbackType { none, like, dislike }

/// 聊天附件类型。
/// [image] 图片;[video] 视频(单列以便在「聊天历史 - 图片与视频」tab 与图片同列);
/// [file] 其它文档/压缩包/未知类型。
/// 判定逻辑见 [ChatFileItem._fileTypeFromNameAndApi]——优先看 api 显式标记,
/// 否则按扩展名归类。
enum ChatFileType { image, video, file }

enum ChatAttachmentPickKind { files, images, camera }

/// SSE 事件落到时间线上后呈现的"步骤类型"。各类型对应一种 icon + 渲染规则：
///
/// - [lifecycle] OpenClaw 生命周期事件（已连接 / 模型）。
/// - [thinking] "思考中…"预留（即将被 reasoning / message / tool 替换）。
/// - [reasoning] 模型思考链（reasoning delta）。
/// - [generating] 模型在输出最终回答的字符增量。
/// - [tool] 单次工具调用（包含参数和结果）。
/// - [usage] 用量统计（tokens）。
/// - [done] 流正常结束。
/// - [error] 流出错。
/// - [stopped] 用户主动停止。
/// - [idleHint] 长时间无事件时给的提示（"执行中… 正在调用工具"）。
enum ChatTimelineKind {
  lifecycle,
  thinking,
  reasoning,
  generating,
  tool,
  // OpenClaw prep stages（model-resolution / auth / core-plugin-tools /
  // bundle-tools / system-prompt / stream-setup）静默期预留，由后端
  // EventType=stage 推送，stage_done 收到时全部 finalize。**不参与**
  // header"已调用 N 个工具"计数，渲染样式与 tool 行区分（灰色文字）。
  stage,
  usage,
  done,
  error,
  stopped,
  idleHint,
}

enum ChatTimelineStatus { running, done, error, stopped }

/// 单条执行过程时间线条目。运行中的条目会以 [startedAt] 配合 UI 计时器
/// 展示"· 1.6s"式的活计时；结束后切到 [ChatTimelineStatus.done]/error/stopped
/// 并以 [endedAt] - [startedAt] 渲染最终用时。
class ChatTimelineEntry {
  const ChatTimelineEntry({
    required this.key,
    required this.kind,
    required this.title,
    required this.startedAt,
    this.snippet,
    this.status = ChatTimelineStatus.running,
    this.endedAt,
    this.toolName,
    this.toolArgs,
    this.toolResult,
  });

  /// 时间线条目的稳定 id；同一类事件多次更新时按此 key 合并：
  ///   lifecycle / thinking / reasoning / generating / usage / done / error / stopped /
  ///   tool:{toolCallId} / hint:idle
  final String key;
  final ChatTimelineKind kind;

  /// 主标题（如 "已连接 OpenClaw" / "思考中" / "调用工具 file_writer"）。
  final String title;

  /// 可选副本（如思考链片段、生成回答字数统计）。
  final String? snippet;

  final ChatTimelineStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;

  // 工具调用专用字段
  final String? toolName;
  final String? toolArgs;
  final String? toolResult;

  bool get isRunning => status == ChatTimelineStatus.running;

  ChatTimelineEntry copyWith({
    ChatTimelineKind? kind,
    String? title,
    String? snippet,
    ChatTimelineStatus? status,
    DateTime? endedAt,
    String? toolName,
    String? toolArgs,
    String? toolResult,
  }) {
    return ChatTimelineEntry(
      key: key,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      snippet: snippet ?? this.snippet,
      status: status ?? this.status,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      toolName: toolName ?? this.toolName,
      toolArgs: toolArgs ?? this.toolArgs,
      toolResult: toolResult ?? this.toolResult,
    );
  }
}

/// F09 §5.7 / 契约 §3.0f C4：客户端本地唯一 id 发生器。
/// workspace/process 级单调递增，跨 session 可比较、全程稳定；
/// 供 [ChatMessage.localId] 与 [ChatFileItem.localUploadId] 使用。
class ChatLocalIds {
  ChatLocalIds._();
  static int _seq = 0;
  static String next(String prefix) => '$prefix-${++_seq}';
}

/// F09 §5.7.4：composer draft 合并仲裁用的 workspace 级单调递增序号。
/// 不得每 session 独立从 1 开始（跨 session 比较大小）。
class ChatDraftRevisions {
  ChatDraftRevisions._();
  static int _rev = 0;
  static int next() => ++_rev;
}

/// 契约 §3.0f C7：某一会话的 composer 草稿快照（整体保存/恢复，不做字段级拼接）。
///
/// [composer] 是富输入控制器（RichPromptController）导出的不透明 payload
/// （widgets 层类型，models 不感知具体形态）；[text] / [hasContent] 冗余存一份
/// 供合并仲裁与诊断使用。[revision] 为 workspace 级单调递增序号（见
/// [ChatDraftRevisions]），是 pending→real 合并时 c) 档的唯一仲裁依据。
class ChatComposerDraft {
  const ChatComposerDraft({
    required this.revision,
    this.text = '',
    this.hasContent = false,
    this.selectedSkills = const [],
    this.composer,
  });

  static const ChatComposerDraft empty = ChatComposerDraft(revision: 0);

  final int revision;
  final String text;
  final bool hasContent;
  final List<({String slug, String name})> selectedSkills;
  final Object? composer;

  bool get isEmpty => !hasContent && selectedSkills.isEmpty;
}

/// 契约 §3.0f C1：单个会话（canonical conversation_uuid 或 `pending:<agentUuid>`）
/// 的全部会话内状态。messages / draft / pendingFiles / isSending / 分页态 /
/// error / 运行中 run 索引全部按会话分区，互不干扰。
class ChatSessionState {
  const ChatSessionState({
    required this.conversationId,
    this.messages = const [],
    this.draft = ChatComposerDraft.empty,
    this.pendingFiles = const [],
    this.isSending = false,
    this.hasMoreHistory = false,
    this.isLoadingHistory = false,
    this.isLoadingMessages = false,
    this.errorMessage,
    this.highlightMessageUuid,
    this.highlightToken = 0,
    this.hasMoreNewer = false,
    this.isLoadingNewer = false,
    this.activeStreamId,
    this.activeAgentMessageUuid,
    this.activeLocalPlaceholderId,
  });

  final String conversationId;
  final List<ChatMessage> messages;
  final ChatComposerDraft draft;
  final List<ChatFileItem> pendingFiles;
  final bool isSending;
  final bool hasMoreHistory;
  final bool isLoadingHistory;
  final bool isLoadingMessages;
  final String? errorMessage;
  final String? highlightMessageUuid;
  final int highlightToken;
  final bool hasMoreNewer;
  final bool isLoadingNewer;

  /// 该会话当前运行中的 stream / agent message 索引（辅助索引；事件归属仍以
  /// runtime 闭包绑定为准，见 chat_stream_runtime.dart）。
  final String? activeStreamId;
  final String? activeAgentMessageUuid;

  /// 运行中 assistant placeholder 的 [ChatMessage.localId]；send 响应尚未返回
  /// （activeAgentMessageUuid 还没有）时 stop/收口按它定位，禁止回退"最后一条"。
  final String? activeLocalPlaceholderId;

  /// 契约 C2：同会话单 active run 闸口。
  bool get hasActiveRun =>
      isSending || (activeStreamId != null && activeStreamId!.isNotEmpty);

  ChatSessionState copyWith({
    List<ChatMessage>? messages,
    ChatComposerDraft? draft,
    List<ChatFileItem>? pendingFiles,
    bool? isSending,
    bool? hasMoreHistory,
    bool? isLoadingHistory,
    bool? isLoadingMessages,
    String? errorMessage,
    bool clearError = false,
    String? highlightMessageUuid,
    int? highlightToken,
    bool clearHighlight = false,
    bool? hasMoreNewer,
    bool? isLoadingNewer,
    String? activeStreamId,
    String? activeAgentMessageUuid,
    String? activeLocalPlaceholderId,
    bool clearActiveStream = false,
  }) {
    return ChatSessionState(
      conversationId: conversationId,
      messages: messages ?? this.messages,
      draft: draft ?? this.draft,
      pendingFiles: pendingFiles ?? this.pendingFiles,
      isSending: isSending ?? this.isSending,
      hasMoreHistory: hasMoreHistory ?? this.hasMoreHistory,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isLoadingMessages: isLoadingMessages ?? this.isLoadingMessages,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      highlightMessageUuid: clearHighlight
          ? null
          : (highlightMessageUuid ?? this.highlightMessageUuid),
      highlightToken: clearHighlight
          ? this.highlightToken
          : (highlightToken ?? this.highlightToken),
      hasMoreNewer: hasMoreNewer ?? this.hasMoreNewer,
      isLoadingNewer: isLoadingNewer ?? this.isLoadingNewer,
      activeStreamId:
          clearActiveStream ? null : (activeStreamId ?? this.activeStreamId),
      activeAgentMessageUuid: clearActiveStream
          ? null
          : (activeAgentMessageUuid ?? this.activeAgentMessageUuid),
      activeLocalPlaceholderId: clearActiveStream
          ? null
          : (activeLocalPlaceholderId ?? this.activeLocalPlaceholderId),
    );
  }

  /// 拿到一个"conversationId 换成 [newId]、其余字段原样"的副本（rekey 用）。
  ChatSessionState withConversationId(String newId) {
    return ChatSessionState(
      conversationId: newId,
      messages: messages,
      draft: draft,
      pendingFiles: pendingFiles,
      isSending: isSending,
      hasMoreHistory: hasMoreHistory,
      isLoadingHistory: isLoadingHistory,
      isLoadingMessages: isLoadingMessages,
      errorMessage: errorMessage,
      highlightMessageUuid: highlightMessageUuid,
      highlightToken: highlightToken,
      hasMoreNewer: hasMoreNewer,
      isLoadingNewer: isLoadingNewer,
      activeStreamId: activeStreamId,
      activeAgentMessageUuid: activeAgentMessageUuid,
      activeLocalPlaceholderId: activeLocalPlaceholderId,
    );
  }
}

/// 契约 §3.0f C1：chatProvider 的**唯一可写状态源**。
///
/// - [activeConversationId] 只表达「当前显示哪个会话」；
/// - [sessions] 按 canonical key（conversation_uuid / `pending:<agentUuid>`）分区；
/// - [aliases] 记录 pending→real 的 rekey 映射，所有读写入口先经
///   [canonicalKey] 解析（契约 C6）；生命周期：canonical session 删除或
///   workspace 整体清理（logout / 切租户 / dispose）时一并清掉。
///
/// 下方 flat getter 是**只读**兼容层（旧 UI 直接读 `state.messages` 等），
/// 全部委托 active session；不提供任何 flat 写路径（copyWith 只接受
/// workspace 级字段）。
class ChatWorkspaceState {
  const ChatWorkspaceState({
    this.activeConversationId,
    this.sessions = const {},
    this.aliases = const {},
  });

  /// 统一初始态：未选中会话、无 session。
  const ChatWorkspaceState.initial()
      : activeConversationId = null,
        sessions = const {},
        aliases = const {};

  final String? activeConversationId;
  final Map<String, ChatSessionState> sessions;
  final Map<String, String> aliases;

  /// 契约 C6：alias 解析。pending key 被 adopt 后旧 key 仍可解析到 canonical。
  String canonicalKey(String id) {
    var key = id;
    var hops = 0;
    while (aliases.containsKey(key) && hops < 4) {
      key = aliases[key]!;
      hops += 1;
    }
    return key;
  }

  ChatSessionState? sessionOf(String? id) =>
      id == null ? null : sessions[canonicalKey(id)];

  ChatSessionState? get activeSession => sessionOf(activeConversationId);

  // ---- 只读 flat 兼容 getter（委托 active session）----
  List<ChatMessage> get messages => activeSession?.messages ?? const [];
  List<ChatFileItem> get pendingFiles =>
      activeSession?.pendingFiles ?? const [];
  bool get isSending => activeSession?.isSending ?? false;
  bool get hasMoreHistory => activeSession?.hasMoreHistory ?? false;
  bool get isLoadingHistory => activeSession?.isLoadingHistory ?? false;
  bool get isLoadingMessages => activeSession?.isLoadingMessages ?? false;
  String? get errorMessage => activeSession?.errorMessage;
  String? get highlightMessageUuid => activeSession?.highlightMessageUuid;
  int get highlightToken => activeSession?.highlightToken ?? 0;
  bool get hasMoreNewer => activeSession?.hasMoreNewer ?? false;
  bool get isLoadingNewer => activeSession?.isLoadingNewer ?? false;
  ChatComposerDraft get draft =>
      activeSession?.draft ?? ChatComposerDraft.empty;

  ChatWorkspaceState copyWith({
    String? activeConversationId,
    bool clearActiveConversation = false,
    Map<String, ChatSessionState>? sessions,
    Map<String, String>? aliases,
  }) {
    return ChatWorkspaceState(
      activeConversationId: clearActiveConversation
          ? null
          : (activeConversationId ?? this.activeConversationId),
      sessions: sessions ?? this.sessions,
      aliases: aliases ?? this.aliases,
    );
  }
}

/// 兼容别名：大量既有 UI / 测试签名使用 `ChatState`；真实类型已是
/// [ChatWorkspaceState]（契约 C1 单一状态源）。
typedef ChatState = ChatWorkspaceState;

class ChatFileItem {
  ChatFileItem({
    required this.fileName,
    required this.fileType,
    this.filePath,
    this.fileLink,
    this.uuid,
    this.driveFileUuid,
    this.cmfId,
    this.uploading = false,
    this.sizeBytes = 0,
    String? localUploadId,
  }) : localUploadId = (localUploadId == null || localUploadId.isEmpty)
            ? ChatLocalIds.next('upl')
            : localUploadId;

  /// 契约 §3.0f C7：入池即生成、workspace/process 级全局唯一，上传完成 /
  /// copyWith / rekey / session merge 全程不变；pending→real 合并按它去重。
  final String localUploadId;

  final String fileName;
  final ChatFileType fileType;
  final String? filePath;
  final String? fileLink;
  final String? uuid;

  /// 文件字节数。GetMessages 接口返回时由后端从 drive_files.size_bytes 回填,
  /// 老链路 / 上传中 / 未关联 drive 文件时为 0。
  /// UI 拿到 0 表示未知,展示空字符串而非"0B"。
  final int sizeBytes;
  // driveFileUuid 是 drive_files.uuid。chat 上传时后端额外写一行 scope=chat 的
  // drive_files,把 uuid 一并返回;SendMessage 回传后,后端把它解析成 id 写入
  // conversation_message_files.drive_file_id,后续 importFromChat / 云盘可见
  // 等下游能力都靠它解锁。
  final String? driveFileUuid;
  // cmfId 是后端 conversation_message_files.id,GetMessages 接口返回。
  // 长按附件"保存到云盘"时,把它传给 importFromChat 让后端按 cmf 行
  // 反查 drive_file 做 server-side copy。
  final int? cmfId;
  final bool uploading;

  bool get isReadyToSend =>
      !uploading && (fileLink != null && fileLink!.trim().isNotEmpty);

  static ChatFileType _fileTypeFromNameAndApi(String name, String apiType) {
    final t = apiType.toLowerCase();
    if (t == 'imagine' || t == 'image') {
      return ChatFileType.image;
    }
    if (t == 'video') {
      return ChatFileType.video;
    }
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext)) {
      return ChatFileType.image;
    }
    if (const {'mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'}.contains(ext)) {
      return ChatFileType.video;
    }
    return ChatFileType.file;
  }

  factory ChatFileItem.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? json['fileName'] ?? '').toString();
    final type = (json['type'] ?? json['fileType'] ?? '').toString();
    final rawSize = json['size'] ?? json['sizeBytes'];
    final link = (json['download_url'] ??
            json['downloadUrl'] ??
            json['url'] ??
            json['fileLink'] ??
            json['preview_url'] ??
            json['previewUrl'])
        ?.toString();
    final driveUuid = (json['file_id'] ??
            json['driveFileId'] ??
            json['drive_file_uuid'] ??
            json['driveFileUuid'] ??
            json['file_uuid'] ??
            json['fileUuid'])
        ?.toString();
    return ChatFileItem(
      fileName: name,
      fileType: _fileTypeFromNameAndApi(name, type),
      filePath: json['filePath']?.toString(),
      fileLink: link,
      uuid: (json['file_id'] ?? json['fileId'] ?? json['uuid'])?.toString(),
      driveFileUuid: driveUuid,
      cmfId: (json['cmfId'] is num) ? (json['cmfId'] as num).toInt() : null,
      uploading: false,
      sizeBytes: rawSize is num ? rawSize.toInt() : 0,
    );
  }

  Map<String, dynamic> toApiJson() {
    return {
      'url': fileLink,
      'type': fileType == ChatFileType.image
          ? 'image'
          : (fileType == ChatFileType.video ? 'video' : 'document'),
      'name': fileName,
      'mimeType': _guessMimeType(fileName, fileType),
      if (driveFileUuid != null && driveFileUuid!.isNotEmpty)
        'driveFileId': driveFileUuid,
    };
  }

  static String _guessMimeType(String name, ChatFileType type) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (type == ChatFileType.image) {
      switch (ext) {
        case 'png':
          return 'image/png';
        case 'gif':
          return 'image/gif';
        case 'webp':
          return 'image/webp';
        case 'bmp':
          return 'image/bmp';
        default:
          return 'image/jpeg';
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
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  ChatFileItem copyWith({
    String? fileName,
    ChatFileType? fileType,
    String? filePath,
    String? fileLink,
    String? uuid,
    String? driveFileUuid,
    int? cmfId,
    bool? uploading,
    int? sizeBytes,
  }) {
    return ChatFileItem(
      fileName: fileName ?? this.fileName,
      fileType: fileType ?? this.fileType,
      filePath: filePath ?? this.filePath,
      fileLink: fileLink ?? this.fileLink,
      uuid: uuid ?? this.uuid,
      driveFileUuid: driveFileUuid ?? this.driveFileUuid,
      cmfId: cmfId ?? this.cmfId,
      uploading: uploading ?? this.uploading,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      // C7: localUploadId 全程不变。
      localUploadId: localUploadId,
    );
  }
}

/// 会话成员(P2.1;来自后端 room_participants 聚合)。
class ConversationParticipant {
  const ConversationParticipant({
    required this.kind,
    required this.accountUuid,
    required this.agentUuid,
    required this.displayName,
    required this.avatar,
    this.departmentName = '',
    this.email = '',
    this.companyName = '',
  });

  final String kind; // human / agent
  final String accountUuid;
  final String agentUuid;
  final String displayName;
  final String avatar;
  final String email;
  final String companyName;

  /// 客户端聊天顶栏副标题展示。
  /// 后端 (P2.1 conversations.list participants 聚合)在人参与者时按
  /// tenant_memberships.department_id → departments.name 解析,
  /// agent 参与者时按 digital_employees.workspace_id → departments.name 解析。
  final String departmentName;

  factory ConversationParticipant.fromJson(Map<String, dynamic> j) =>
      ConversationParticipant(
        kind: (j['kind'] ?? '').toString(),
        accountUuid: (j['account_uuid'] ?? '').toString(),
        agentUuid: (j['agent_uuid'] ?? '').toString(),
        displayName: (j['display_name'] ?? '').toString(),
        avatar: (j['avatar'] ?? '').toString(),
        departmentName: (j['department_name'] ?? '').toString(),
        email: (j['email'] ?? '').toString(),
        companyName: (j['company_name'] ?? j['companyName'] ?? '').toString(),
      );
}

class ConversationItem {
  const ConversationItem({
    required this.conversationId,
    required this.title,
    required this.agentId,
    required this.agentName,
    this.agentAvatarUrl,
    this.agentPositionLabel = '',
    this.agentDepartmentName = '',
    this.agentDeleted = false,
    this.lastMessage,
    this.isDoing = false,
    this.unreadCount = 0,
    this.createdAt,
    this.updatedAt,
    this.lastMessageAt,
    this.kind = 'single',
    this.roomUuid,
    this.wukongChannelId,
    this.wukongChannelType,
    this.participants = const [],
    this.convAvatar,
    this.pinned = false,
    this.muted = false,
    this.markedUnread = false,
    this.hidden = false,
    this.clearedAt,
    this.canRenameGroup = false,
  });

  final String conversationId;
  final String title;
  final String agentId;
  final String agentName;
  final String? agentAvatarUrl;
  final String agentPositionLabel;
  final String agentDepartmentName;
  final bool agentDeleted;
  final String? lastMessage;
  final bool isDoing;

  /// P2.1 统一会话索引:human_direct / agent_direct / group / single(legacy)。
  final String kind;
  final String? roomUuid;
  final String? wukongChannelId;
  final int? wukongChannelType;
  final List<ConversationParticipant> participants;

  /// 会话展示头像(后端 P2.1:direct=对端头像 / agent_direct=agent 头像;group 暂空)。
  final String? convAvatar;

  /// F09 P2 「会话列表操作菜单 v2」 per-account 视图态。
  /// 权威字段由 Bus `conversation_account_state` 持久化, `/chat/conversations` 聚合下发。
  /// 客户端只读 / 显示, 状态切换走 ChatService.setConversationPinned/setConversationMuted/markConversationUnread。
  final bool pinned;
  final bool muted;

  /// 「人工标为未读」(独立于 unread_count, 任一为真即显示红点)。
  final bool markedUnread;
  final bool hidden;
  final String? clearedAt;

  /// Bus 按当前 caller 计算的群改名 capability；客户端只负责收窄入口。
  final bool canRenameGroup;

  /// UI 真红点 = 后端未读 > 0 或 人工标未读。
  bool get hasUnreadDot => unreadCount > 0 || markedUnread;

  bool get isHumanDirect => kind == 'human_direct';
  bool get isDirect => kind == 'human_direct' || kind == 'agent_direct';
  bool get isGroup => kind == 'group';

  /// 后端 `unreadCount` 字段：当前会话未读消息数。前端用于侧边栏红点徽标，
  /// 用户点开会话后应通过 `markConversationRead` 清零。
  final int unreadCount;
  final String? createdAt;
  final String? updatedAt;

  /// 后端 `lastMessageAt` 字段：用于侧边栏右上角显示的"最近消息时间"，
  /// 比 `updatedAt` 更接近真实最后一条消息时间。
  final String? lastMessageAt;

  /// doc-13 §A: create-on-first-send 的**临时会话栏** item。会话尚未在服务端创建,
  /// conversationId 用 pending 哨兵 (`pending:<agentUuid>`); 点击/选中走数字员工单聊 (kind='single')。
  /// title/头像取该数字员工, 不留空。首条发送 adopt 真实 conversation_uuid 后被替换。
  factory ConversationItem.pendingAgent({
    required String conversationId,
    required String agentUuid,
    required String name,
    String? avatarUrl,
  }) {
    final display = name.trim().isEmpty ? '数字员工' : name.trim();
    return ConversationItem(
      conversationId: conversationId,
      title: display,
      agentId: agentUuid,
      agentName: display,
      agentAvatarUrl: avatarUrl,
      convAvatar: avatarUrl,
      kind: 'single',
    );
  }

  /// 用于排序/展示的最近活动时间，优先取 [lastMessageAt]，回退 [updatedAt]。
  String? get displayTimeRaw =>
      (lastMessageAt != null && lastMessageAt!.isNotEmpty)
          ? lastMessageAt
          : updatedAt;

  /// 兼容两套 DTO:
  ///  - agent-bus `/chat/conversations`(P2.1):`uuid` / `title` / `kind` / `unread_count` /
  ///    `last_message_at` / `wukong_channel_id` / `participants` …
  ///  - legacy ai-office:`conversationId` / `alias` / `conversationTitle` / `unreadCount` …
  factory ConversationItem.fromJson(Map<String, dynamic> json) {
    // 标题:agent-bus 直接给 title;legacy 用 alias/conversationTitle。
    final agentBusTitle = (json['title'] as String?)?.trim();
    final alias = (json['alias'] as String?)?.trim();
    final fallbackTitle = (agentBusTitle?.isNotEmpty == true)
        ? agentBusTitle!
        : (alias?.isNotEmpty == true
            ? alias!
            : ((json['conversationTitle'] as String?)?.trim().isNotEmpty == true
                ? json['conversationTitle'] as String
                : '未命名会话'));
    // last_message:agent-bus P2.1b 返回 {text, from_uid, ts} 对象;legacy 是字符串。
    String? lastMessage;
    final lm = json['last_message'] ?? json['lastMessage'];
    if (lm is Map) {
      final t = (lm['text'] ?? '').toString();
      lastMessage = t.isEmpty ? null : t;
    } else if (lm is String) {
      lastMessage = lm.isEmpty ? null : lm;
    }
    final rawUnread = json['unread_count'] ?? json['unreadCount'];
    int unread = 0;
    if (rawUnread is num) {
      unread = rawUnread.toInt();
    } else if (rawUnread is String) {
      unread = int.tryParse(rawUnread) ?? 0;
    }
    if (unread < 0) unread = 0;

    final parts = <ConversationParticipant>[];
    final rawParts = json['participants'];
    if (rawParts is List) {
      for (final p in rawParts) {
        if (p is Map<String, dynamic>) {
          parts.add(ConversationParticipant.fromJson(p));
        }
      }
    }
    // agent 头像/名:agent_direct 时取 agent participant;否则回退 legacy 字段。
    String agentId =
        (json['agent_id'] ?? json['agent_uuid'] ?? json['agentId'] ?? '')
            .toString();
    String agentName =
        (json['agent_name'] ?? json['agentName'] ?? '').toString();
    String? agentAvatar = (json['agentAvatarUrl'] ??
            json['agent_avatar_url'] ??
            json['agentAvatar'] ??
            json['agent_avatar'])
        ?.toString();
    var agentPositionLabel = (json['agent_position_label'] ??
            json['agentPositionLabel'] ??
            json['positionLabel'] ??
            '')
        .toString();
    var agentDepartmentName = (json['agent_department_name'] ??
            json['agentDepartmentName'] ??
            json['departmentName'] ??
            '')
        .toString();
    for (final p in parts) {
      if (p.kind == 'agent') {
        if (agentId.isEmpty) agentId = p.agentUuid;
        if (agentName.isEmpty) agentName = p.displayName;
        agentAvatar ??= p.avatar.isNotEmpty ? p.avatar : null;
        if (agentDepartmentName.isEmpty && p.departmentName.isNotEmpty) {
          agentDepartmentName = p.departmentName;
        }
        break;
      }
    }

    final rawConvAvatar = (json['avatar'] as String?)?.trim();
    final kind = (json['kind'] ?? 'single').toString();
    final convAvatar = (kind == 'agent_direct' || kind == 'single')
        ? pickAgentAvatarUrl(rawConvAvatar, agentAvatar)
        : pickAgentAvatarUrl(rawConvAvatar);
    final wkType = json['wukong_channel_type'];
    return ConversationItem(
      conversationId: (json['uuid'] ?? json['conversationId'] ?? '').toString(),
      title: fallbackTitle,
      agentId: agentId,
      agentName: agentName,
      agentAvatarUrl: agentAvatar,
      agentPositionLabel: agentPositionLabel,
      agentDepartmentName: agentDepartmentName,
      agentDeleted: json['agent_deleted'] == true,
      lastMessage: lastMessage,
      isDoing: json['isDoing'] == true,
      unreadCount: unread,
      createdAt:
          json['createdAt']?.toString() ?? json['created_at']?.toString(),
      updatedAt:
          json['updatedAt']?.toString() ?? json['updated_at']?.toString(),
      lastMessageAt: json['lastMessageAt']?.toString() ??
          json['last_message_at']?.toString(),
      kind: kind,
      roomUuid: json['room_uuid']?.toString(),
      wukongChannelId: json['wukong_channel_id']?.toString(),
      wukongChannelType: wkType is num ? wkType.toInt() : null,
      participants: parts,
      convAvatar: convAvatar,
      pinned: json['pinned'] == true,
      muted: json['muted'] == true,
      markedUnread: json['marked_unread'] == true,
      hidden: json['hidden'] == true,
      clearedAt:
          json['clearedAt']?.toString() ?? json['cleared_at']?.toString(),
      canRenameGroup: json['can_rename_group'] == true,
    );
  }

  factory ConversationItem.fromCreateResponseJson(Map<String, dynamic> json) {
    final agentAvatar = (json['agentAvatarUrl'] ??
            json['agent_avatar_url'] ??
            json['agentAvatar'] ??
            json['agent_avatar'])
        ?.toString();
    return ConversationItem(
      conversationId: (json['conversationId'] ?? '').toString(),
      title: (json['alias'] ?? '未命名会话').toString(),
      agentId: (json['agentId'] ?? '').toString(),
      agentName: (json['agentName'] ?? '').toString(),
      agentAvatarUrl: agentAvatar,
      agentPositionLabel:
          (json['agent_position_label'] ?? json['agentPositionLabel'] ?? '')
              .toString(),
      agentDepartmentName:
          (json['agent_department_name'] ?? json['agentDepartmentName'] ?? '')
              .toString(),
      convAvatar: agentAvatar,
      lastMessage: null,
      unreadCount: 0,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      lastMessageAt: null,
    );
  }

  ConversationItem copyWith({
    String? conversationId,
    String? title,
    String? agentId,
    String? agentName,
    String? agentAvatarUrl,
    String? agentPositionLabel,
    String? agentDepartmentName,
    bool? agentDeleted,
    String? lastMessage,
    bool? isDoing,
    int? unreadCount,
    String? createdAt,
    String? updatedAt,
    String? lastMessageAt,
    String? kind,
    String? roomUuid,
    String? wukongChannelId,
    int? wukongChannelType,
    List<ConversationParticipant>? participants,
    String? convAvatar,
    bool? pinned,
    bool? muted,
    bool? markedUnread,
    bool? hidden,
    String? clearedAt,
    bool? canRenameGroup,
  }) {
    return ConversationItem(
      conversationId: conversationId ?? this.conversationId,
      title: title ?? this.title,
      agentId: agentId ?? this.agentId,
      agentName: agentName ?? this.agentName,
      agentAvatarUrl: agentAvatarUrl ?? this.agentAvatarUrl,
      agentPositionLabel: agentPositionLabel ?? this.agentPositionLabel,
      agentDepartmentName: agentDepartmentName ?? this.agentDepartmentName,
      agentDeleted: agentDeleted ?? this.agentDeleted,
      lastMessage: lastMessage ?? this.lastMessage,
      isDoing: isDoing ?? this.isDoing,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      kind: kind ?? this.kind,
      roomUuid: roomUuid ?? this.roomUuid,
      wukongChannelId: wukongChannelId ?? this.wukongChannelId,
      wukongChannelType: wukongChannelType ?? this.wukongChannelType,
      participants: participants ?? this.participants,
      convAvatar: convAvatar ?? this.convAvatar,
      pinned: pinned ?? this.pinned,
      muted: muted ?? this.muted,
      markedUnread: markedUnread ?? this.markedUnread,
      hidden: hidden ?? this.hidden,
      clearedAt: clearedAt ?? this.clearedAt,
      canRenameGroup: canRenameGroup ?? this.canRenameGroup,
    );
  }
}

bool isUsableAgentAvatarUrl(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return false;
  final lower = value.toLowerCase();
  if (lower.startsWith('oss://')) return false;
  if (lower.contains('/portrait/default/')) return false;
  return true;
}

String? pickAgentAvatarUrl(String? primary, [String? fallback]) {
  final first = (primary ?? '').trim();
  if (isUsableAgentAvatarUrl(first)) return first;
  final second = (fallback ?? '').trim();
  if (isUsableAgentAvatarUrl(second)) return second;
  return null;
}

class ConversationListData {
  const ConversationListData({required this.items});

  final List<ConversationItem> items;

  factory ConversationListData.fromJson(Map<String, dynamic> json) {
    // 兼容 agent-bus `items`(P2.1)与 legacy `list`。
    final list =
        (json['items'] ?? json['list'] ?? const <dynamic>[]) as List<dynamic>;
    return ConversationListData(
      items: list
          .map(
            (item) => ConversationItem.fromJson(item as Map<String, dynamic>),
          )
          .where((item) => item.conversationId.isNotEmpty)
          .toList(),
    );
  }
}

class ChatHistoryData {
  const ChatHistoryData({required this.items});

  final List<ChatMessage> items;

  factory ChatHistoryData.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List<dynamic>;
    return ChatHistoryData(
      items: list
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 「围绕一条消息」加载的上下文窗口结果，专给 cron 跳转链路用。
/// items 已经按时间正序，[hasMoreUp] 决定切换会话后用户继续上滚是否还能拉更早历史。
class ChatHistoryAroundData {
  const ChatHistoryAroundData({
    required this.items,
    required this.hasMoreUp,
    required this.hasMoreDown,
    required this.anchorIndex,
  });

  final List<ChatMessage> items;
  final bool hasMoreUp;
  final bool hasMoreDown;
  final int anchorIndex;

  factory ChatHistoryAroundData.fromJson(Map<String, dynamic> json) {
    final list = (json['list'] as List<dynamic>? ?? const []);
    return ChatHistoryAroundData(
      items: list
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .toList(),
      hasMoreUp: json['hasMoreUp'] == true,
      hasMoreDown: json['hasMoreDown'] == true,
      anchorIndex: (json['anchorIndex'] as num?)?.toInt() ?? 0,
    );
  }
}

class OpenClawInstanceState {
  const OpenClawInstanceState({
    required this.instanceStatus,
    required this.message,
    required this.defaultAgentReady,
    required this.gatewayReady,
  });

  final String instanceStatus;
  final String? message;

  /// 默认数字员工（"私人助理"）已经在 ai-office DB 落了 active 行 + OpenClaw
  /// workspace 文件就绪。仅 [isRunning] 时才有意义；前端在 isRunning 之后还要
  /// 等这个标志为 true 才能放用户进对话页，否则会出现「OpenClaw 起来了但
  /// 数字员工列表空白、对话页加载一会才补出私人助理」的体感问题。
  final bool defaultAgentReady;

  /// OpenClaw gateway 已经能接受真实的 WebSocket 连接（ai-office 后端用
  /// gatewaywsclient.Probe 实测了一次 dial + connect 握手）。k8s pod Running
  /// 不代表 :18789 已经 listen 完毕，更不代表内部 control-server 准备好处理
  /// connect 帧；仅靠 [isRunning] + [defaultAgentReady] 放行会让首条 chat.send
  /// 撞上 ws dial: i/o timeout。
  final bool gatewayReady;

  bool get isIdle => instanceStatus.isEmpty || instanceStatus == 'idle';
  bool get isRunning => instanceStatus == 'running';
  bool get isCreating => instanceStatus == 'creating';
  bool get isPending => instanceStatus == 'pending';
  bool get isError => instanceStatus == 'error' || instanceStatus == 'failed';

  /// 完整就绪 = 实例 running + 默认 agent 已建好 + gateway 真实可握手。
  /// UI 用这个判断 loading 是否结束、是否可以放用户进对话页。
  bool get isReady => isRunning && defaultAgentReady && gatewayReady;

  factory OpenClawInstanceState.fromJson(Map<String, dynamic> json) {
    return OpenClawInstanceState(
      instanceStatus: (json['instanceStatus'] ?? '').toString(),
      message: (json['message'] as String?)?.trim(),
      defaultAgentReady: json['defaultAgentReady'] == true,
      gatewayReady: json['gatewayReady'] == true,
    );
  }
}

class AgentItem {
  const AgentItem({
    required this.agentId,
    required this.name,
    required this.description,
    required this.avatarUrl,
    this.position = '',
    this.positionLabel = '',
    this.departmentName = '',
    this.internalDescription = '',
    this.welcomeMsg = '',
    this.systemPrompt = '',
    this.tags = const [],
    this.modelPrimary = '',
    this.modelSource = 'platform_whitelist',
    this.modelServiceEndpointType = '',
    this.modelServiceBaseUrl = '',
    this.modelServiceModelId = '',
    this.modelServiceApiKeyPrefix = '',
    this.visibility = 'tenant',
    this.runtimeEnvironmentUuid = '',
    this.executionLocus = 'cloud',
    this.localEngine = 'dsh',
    this.agentKey = '',
    this.contactEnabled = true,
    this.allowInviteToGroup = true,
    this.supportsSkillBindings = true,
    this.supportsModelSelection = false,
    this.canManageSkills = false,
    this.skills = const [],
    this.apps = const [],
    this.configuredAppLabels = const {},
    this.configuredKnowledgeBaseLabels = const {},
    required this.status,
    required this.isDefault,
    required this.syncStatus,
    required this.lastSyncedAt,
  });

  final String agentId;
  final String name;
  final String description;
  final String avatarUrl;
  final String position;
  final String positionLabel;
  final String internalDescription;
  final String welcomeMsg;

  /// 人设（metadata.system_prompt）；空 = Bus 兜底人设。
  final String systemPrompt;
  final List<String> tags;
  final String modelPrimary;

  /// ADR-0037 BYOK（契约 §12.3）：'platform_whitelist'（默认）走原有 [modelPrimary]
  /// 白名单；'byok' 时下面四个字段生效，[modelPrimary] 不再有意义。
  final String modelSource;
  final String modelServiceEndpointType;
  final String modelServiceBaseUrl;
  final String modelServiceModelId;

  /// 服务端回显的 api_key 前缀（脱敏，用于"已配置 sk-***abcd"这类展示），
  /// 绝不是明文 key——明文只在用户重新输入时才会被提交，服务端也从不回显明文。
  final String modelServiceApiKeyPrefix;
  final String visibility;
  final String runtimeEnvironmentUuid;
  final String executionLocus;
  final String localEngine;
  final String agentKey;
  final bool contactEnabled;
  final bool allowInviteToGroup;
  final bool supportsSkillBindings;
  final bool supportsModelSelection;
  bool get hasConversationModels =>
      executionLocus == 'local' || supportsModelSelection;
  final bool canManageSkills;

  /// 数字员工归属部门名称。后端 `/agents` 经 workspace_id → departments.name LEFT JOIN
  /// 解析后返回 `department_name`(snake) / `DepartmentName`(Pascal, 无 JSON tag 时);
  /// 客户端聊天顶栏副标题展示「部门 · 职位」。
  final String departmentName;
  final List<AgentSkillItem> skills;
  final List<AgentAppItem> apps;
  final Map<String, String> configuredAppLabels;
  final Map<String, String> configuredKnowledgeBaseLabels;
  final String status;
  final bool isDefault;
  final String syncStatus;
  final String? lastSyncedAt;

  factory AgentItem.fromJson(Map<String, dynamic> json) {
    final rawSkills = json['skills'];
    final skills = rawSkills is List
        ? rawSkills
            .whereType<Map<String, dynamic>>()
            .map(AgentSkillItem.fromJson)
            .toList(growable: false)
        : const <AgentSkillItem>[];
    final rawApps = json['apps'];
    final apps = rawApps is List
        ? rawApps
            .whereType<Map<String, dynamic>>()
            .map(AgentAppItem.fromJson)
            .toList(growable: false)
        : const <AgentAppItem>[];
    final rawTags =
        json['tags'] ?? json['Tags'] ?? json['badges'] ?? json['Badges'];
    final tags = rawTags is List
        ? rawTags
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final rawMetadata = json['metadata'] ?? json['Metadata'];
    final metadata =
        rawMetadata is Map ? rawMetadata : const <dynamic, dynamic>{};
    final agentKey =
        (metadata['agent_key'] ?? metadata['agentKey'] ?? '').toString().trim();
    return AgentItem(
      agentId: (json['agentId'] ??
              json['uuid'] ??
              json['UUID'] ??
              json['id'] ??
              json['ID'] ??
              '')
          .toString(),
      name: (json['name'] ?? json['Name'] ?? json['displayName'] ?? '')
          .toString(),
      description: (json['intro'] ??
              json['Intro'] ??
              json['description'] ??
              json['Description'] ??
              json['subtitle'] ??
              '')
          .toString(),
      avatarUrl:
          (json['avatarUrl'] ?? json['AvatarURL'] ?? json['avatar_url'] ?? '')
              .toString(),
      position: (json['position'] ?? json['Position'] ?? '').toString(),
      positionLabel:
          (json['positionLabel'] ?? json['PositionLabel'] ?? '').toString(),
      internalDescription:
          (json['description'] ?? json['Description'] ?? '').toString(),
      welcomeMsg: (json['welcome_msg'] ??
              json['welcomeMsg'] ??
              json['WelcomeMsg'] ??
              '')
          .toString(),
      supportsModelSelection: json['supports_model_selection'] == true,
      tags: tags,
      modelPrimary: (json['model_primary'] ??
              json['modelPrimary'] ??
              json['ModelPrimary'] ??
              'openai/gpt-5.4')
          .toString(),
      modelSource: (json['model_source'] ??
              json['modelSource'] ??
              json['ModelSource'] ??
              'platform_whitelist')
          .toString(),
      modelServiceEndpointType:
          (_modelServiceConfig(json)['endpoint_type'] ?? '').toString(),
      modelServiceBaseUrl:
          (_modelServiceConfig(json)['base_url'] ?? '').toString(),
      modelServiceModelId:
          (_modelServiceConfig(json)['model_id'] ?? '').toString(),
      modelServiceApiKeyPrefix: (json['model_service_api_key_prefix'] ??
              json['modelServiceApiKeyPrefix'] ??
              // Bus DigitalEmployee 无 json tag 时按 Go 字段名原样序列化。
              json['ModelServiceAPIKeyPrefix'] ??
              '')
          .toString(),
      visibility:
          (json['visibility'] ?? json['Visibility'] ?? 'tenant').toString(),
      localEngine:
          (json['local_engine'] ?? json['LocalEngine'] ?? 'dsh').toString(),
      executionLocus: (json['execution_locus'] ??
              json['executionLocus'] ??
              json['ExecutionLocus'] ??
              'cloud')
          .toString(),
      runtimeEnvironmentUuid: (json['runtime_environment_uuid'] ??
              json['runtimeEnvironmentUuid'] ??
              json['RuntimeEnvironmentUUID'] ??
              '')
          .toString(),
      agentKey: agentKey,
      systemPrompt:
          (metadata['system_prompt'] ?? metadata['systemPrompt'] ?? '')
              .toString(),
      contactEnabled:
          json['contact_enabled'] != false && json['ContactEnabled'] != false,
      allowInviteToGroup: json.containsKey('allow_invite_to_group') ||
              json.containsKey('AllowInviteToGroup') ||
              json.containsKey('canInviteToRoom')
          ? (json['allow_invite_to_group'] == true ||
              json['AllowInviteToGroup'] == true ||
              json['canInviteToRoom'] == true)
          : true,
      supportsSkillBindings: json['supports_skill_bindings'] != false &&
          json['supportsSkillBindings'] != false,
      canManageSkills:
          json['can_manage_skills'] == true || json['canManageSkills'] == true,
      departmentName: (json['departmentName'] ??
              json['DepartmentName'] ??
              json['department_name'] ??
              '')
          .toString(),
      skills: skills,
      apps: apps,
      // 真实绑定 (后端 hydrate 的 apps/knowledge_bases) 优先; 无则回退历史 metadata label。
      configuredAppLabels: () {
        final real = _readUuidNameMap(json['apps']);
        return real.isNotEmpty
            ? real
            : _readStringMap(metadata['selected_app_labels']);
      }(),
      configuredKnowledgeBaseLabels: () {
        final real = _readUuidNameMap(json['knowledge_bases']);
        return real.isNotEmpty
            ? real
            : _readStringMap(metadata['selected_knowledge_base_labels']);
      }(),
      status: (json['status'] ?? json['Status'] ?? '').toString(),
      isDefault:
          json['isDefault'] == true || json['IsDefaultForCreator'] == true,
      syncStatus: (json['syncStatus'] ?? '').toString(),
      lastSyncedAt: (json['lastSyncedAt'] ?? json['UpdatedAt'])?.toString(),
    );
  }

  String get displayName => name.isNotEmpty ? name : agentId;

  AgentItem copyWith({
    String? agentId,
    String? name,
    String? description,
    String? avatarUrl,
    String? position,
    String? positionLabel,
    String? departmentName,
    String? internalDescription,
    String? welcomeMsg,
    String? systemPrompt,
    List<String>? tags,
    String? modelPrimary,
    String? modelSource,
    String? modelServiceEndpointType,
    String? modelServiceBaseUrl,
    String? modelServiceModelId,
    String? modelServiceApiKeyPrefix,
    String? visibility,
    String? runtimeEnvironmentUuid,
    String? executionLocus,
    String? localEngine,
    String? agentKey,
    bool? contactEnabled,
    bool? allowInviteToGroup,
    bool? supportsSkillBindings,
    bool? supportsModelSelection,
    bool? canManageSkills,
    List<AgentSkillItem>? skills,
    List<AgentAppItem>? apps,
    Map<String, String>? configuredAppLabels,
    Map<String, String>? configuredKnowledgeBaseLabels,
    String? status,
    bool? isDefault,
    String? syncStatus,
    String? lastSyncedAt,
  }) {
    return AgentItem(
      agentId: agentId ?? this.agentId,
      name: name ?? this.name,
      description: description ?? this.description,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      position: position ?? this.position,
      positionLabel: positionLabel ?? this.positionLabel,
      departmentName: departmentName ?? this.departmentName,
      internalDescription: internalDescription ?? this.internalDescription,
      welcomeMsg: welcomeMsg ?? this.welcomeMsg,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      tags: tags ?? this.tags,
      modelPrimary: modelPrimary ?? this.modelPrimary,
      modelSource: modelSource ?? this.modelSource,
      modelServiceEndpointType:
          modelServiceEndpointType ?? this.modelServiceEndpointType,
      modelServiceBaseUrl: modelServiceBaseUrl ?? this.modelServiceBaseUrl,
      modelServiceModelId: modelServiceModelId ?? this.modelServiceModelId,
      modelServiceApiKeyPrefix:
          modelServiceApiKeyPrefix ?? this.modelServiceApiKeyPrefix,
      visibility: visibility ?? this.visibility,
      runtimeEnvironmentUuid:
          runtimeEnvironmentUuid ?? this.runtimeEnvironmentUuid,
      executionLocus: executionLocus ?? this.executionLocus,
      localEngine: localEngine ?? this.localEngine,
      agentKey: agentKey ?? this.agentKey,
      contactEnabled: contactEnabled ?? this.contactEnabled,
      allowInviteToGroup: allowInviteToGroup ?? this.allowInviteToGroup,
      supportsModelSelection:
          supportsModelSelection ?? this.supportsModelSelection,
      supportsSkillBindings:
          supportsSkillBindings ?? this.supportsSkillBindings,
      canManageSkills: canManageSkills ?? this.canManageSkills,
      skills: skills ?? this.skills,
      apps: apps ?? this.apps,
      configuredAppLabels: configuredAppLabels ?? this.configuredAppLabels,
      configuredKnowledgeBaseLabels:
          configuredKnowledgeBaseLabels ?? this.configuredKnowledgeBaseLabels,
      status: status ?? this.status,
      isDefault: isDefault ?? this.isDefault,
      syncStatus: syncStatus ?? this.syncStatus,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }
}

class AgentAppItem {
  const AgentAppItem({
    required this.id,
    required this.name,
    this.slug = '',
    this.iconUrl = '',
  });

  final String id;
  final String name;
  final String slug;
  final String iconUrl;

  factory AgentAppItem.fromJson(Map<String, dynamic> json) {
    return AgentAppItem(
      id: (json['id'] ?? json['uuid'] ?? '').toString(),
      name: (json['name'] ?? json['displayName'] ?? '').toString(),
      slug: (json['slug'] ?? json['code'] ?? '').toString(),
      iconUrl: (json['iconUrl'] ?? json['icon_url'] ?? '').toString(),
    );
  }
}

class PositionOption {
  const PositionOption({required this.code, required this.label});

  final String code;
  final String label;

  factory PositionOption.fromJson(Map<String, dynamic> json) {
    return PositionOption(
      code: (json['code'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
    );
  }
}

class RuntimeEnvironmentOption {
  const RuntimeEnvironmentOption({
    required this.uuid,
    required this.name,
    required this.framework,
    required this.hostingKind,
    required this.status,
    required this.enabled,
    this.isDefault = false,
    this.vendor = '',
    this.agentLabel = '',
    this.agentDescription = '',
  });

  final String vendor;
  final String agentLabel;
  final String agentDescription;

  final String uuid;
  final String name;
  final String framework;
  final String hostingKind;
  final String status;
  final bool enabled;

  /// 是否当前租户的默认环境（Bus 字段 IsDefaultForCaller）；创建态预选它。
  final bool isDefault;

  factory RuntimeEnvironmentOption.fromJson(Map<String, dynamic> json) {
    final rawMetadata = json['metadata'] ?? json['Metadata'];
    final metadata = rawMetadata is Map ? rawMetadata : const {};
    final rawCard = metadata['runtime_card'];
    final card = rawCard is Map ? rawCard : const {};
    return RuntimeEnvironmentOption(
      vendor: (metadata['vendor'] ?? card['vendor'] ?? '').toString(),
      agentLabel: (metadata['agent_label'] ?? '').toString(),
      agentDescription: (metadata['agent_description'] ?? '').toString(),
      uuid: (json['uuid'] ?? json['UUID'] ?? '').toString(),
      name: (json['name'] ?? json['Name'] ?? '').toString(),
      framework: (json['framework'] ?? json['Framework'] ?? '').toString(),
      hostingKind: (json['hosting_kind'] ??
              json['hostingKind'] ??
              json['HostingKind'] ??
              '')
          .toString(),
      status: (json['status'] ?? json['Status'] ?? '').toString(),
      enabled: json['enabled'] == true || json['Enabled'] == true,
      isDefault: json['IsDefaultForCaller'] == true ||
          json['is_default_for_caller'] == true ||
          json['is_default'] == true,
    );
  }

  // Product rule: every ZAP environment is a professional template.
  bool get isProfessional => framework.trim().toLowerCase() == 'zap';

  String get agentGroup => isProfessional ? '职业模板' : '通用智能体';

  String get agentTypeLabel {
    if (agentLabel.trim().isNotEmpty) return agentLabel.trim();
    if (isProfessional) return name;
    if (vendor.toLowerCase() == 'zhiban/dsh') return 'DSH';
    return switch (framework.toLowerCase()) {
      'openclaw' => 'OpenClaw',
      'hermes' => 'Hermes',
      'dsh' => 'DSH',
      _ => name.trim().isEmpty ? displayName : name.trim(),
    };
  }

  String get displayName {
    final parts = <String>[
      if (name.trim().isNotEmpty) name.trim(),
      if (framework.trim().isNotEmpty) framework.trim(),
    ];
    return parts.isEmpty ? uuid : parts.join(' · ');
  }

  bool get isUsable =>
      uuid.trim().isNotEmpty &&
      enabled &&
      (status.trim().isEmpty || status.trim() == 'active');
}

/// GET /llm-models 的单个可选主模型(服务端配置白名单, [isDefault] 为推荐默认)。
class LlmModelOption {
  const LlmModelOption({
    required this.id,
    required this.label,
    this.isDefault = false,
    this.modelId = '',
    this.providerId = '',
    this.providerName = '',
    this.providerIconAssetPath,
  });

  final String id;
  final String label;
  final bool isDefault;
  final String modelId;
  final String providerId;
  final String providerName;
  final String? providerIconAssetPath;

  factory LlmModelOption.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString().trim();
    final label = (json['label'] ?? '').toString().trim();
    return LlmModelOption(
      id: id,
      label: label.isEmpty ? id : label,
      isDefault: json['default'] == true,
      modelId: (json['model_id'] ?? id).toString(),
      providerId: (json['provider_id'] ?? '').toString(),
      providerName: (json['provider_name'] ?? '').toString(),
      providerIconAssetPath: json['provider_id'] == 'beebridge'
          ? 'assets/icons/providers/beebridge.svg'
          : null,
    );
  }
}

class AgentSkillItem {
  const AgentSkillItem({
    required this.slug,
    required this.skillName,
    required this.status,
    required this.isInstalled,
    this.iconUrl = '',
    this.billingType = 'free',
    this.pricingMode = 'per_skill',
  });

  final String slug;
  final String skillName;
  final String status;
  final bool isInstalled;
  final String iconUrl;
  final String billingType;
  final String pricingMode;

  bool get isPaid => billingType == 'paid';

  factory AgentSkillItem.fromJson(Map<String, dynamic> json) {
    final bt = (json['billing_type'] ?? json['billingType'] ?? '').toString();
    final pm = (json['pricing_mode'] ?? json['pricingMode'] ?? '').toString();
    final installed = json['isInstalled'] ?? json['is_installed'];
    return AgentSkillItem(
      slug: (json['slug'] ?? '').toString(),
      skillName:
          (json['skillName'] ?? json['name'] ?? json['displayName'] ?? '')
              .toString(),
      status: (json['status'] ?? '').toString(),
      // AgentSkillItem 只解析数字员工 skills[]；数组中的条目来自正式绑定。
      // 旧版 /contacts/agents 轻量摘要没带安装态，缺失时必须按已安装兼容，
      // 否则技能选择器会用空初始集 replace 掉既有绑定。
      isInstalled: installed is bool ? installed : true,
      iconUrl: (json['iconUrl'] ?? json['icon_url'] ?? '').toString(),
      billingType: bt.isEmpty ? 'free' : bt,
      pricingMode: pm.isEmpty ? 'per_skill' : pm,
    );
  }
}

extension AgentItemListX on List<AgentItem> {
  AgentItem? get defaultOrFirstAgent {
    for (final agent in this) {
      if (agent.isDefault) return agent;
    }
    return isNotEmpty ? first : null;
  }
}

/// 单次 Agent 回复的模型 token 用量事实。
///
/// SSE 只提供 token，不提供 Agent Bus 最终账务 ledger；客户端可用当前默认费率
/// 做临时估算，但不得把 [estimatedCredits] 当成真实扣费结果持久化或入账。
class ChatTokenUsage {
  const ChatTokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.model = '',
  });

  static const int estimatedInputCreditsPerMillion = 43200;
  static const int estimatedOutputCreditsPerMillion = 259200;

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final String model;

  bool get hasBillableBreakdown => inputTokens > 0 || outputTokens > 0;

  int get estimatedCredits =>
      _estimateDirection(inputTokens, estimatedInputCreditsPerMillion) +
      _estimateDirection(outputTokens, estimatedOutputCreditsPerMillion);

  static int _estimateDirection(int tokens, int ratePerMillion) {
    if (tokens <= 0 || ratePerMillion <= 0) return 0;
    return (tokens * ratePerMillion + 999999) ~/ 1000000;
  }

  /// 同时兼容 `{usage:{...}, model}` 与 SSE 已摊平的
  /// `{input_tokens, output_tokens, ...}` 两种事件形态。
  static ChatTokenUsage? tryParse(dynamic raw, {String model = ''}) {
    if (raw is! Map) return null;
    final nested = raw['usage'];
    final usage = nested is Map ? nested : raw;
    final input = _tokenCount(
      usage['input_tokens'] ?? usage['prompt_tokens'],
    );
    final output = _tokenCount(
      usage['output_tokens'] ?? usage['completion_tokens'],
    );
    final explicitTotal = _tokenCount(usage['total_tokens']);
    final total = explicitTotal > 0 ? explicitTotal : input + output;
    if (input == 0 && output == 0 && total == 0) return null;
    final resolvedModel = model.trim().isNotEmpty
        ? model.trim()
        : (raw['model'] ?? usage['model'] ?? '').toString().trim();
    return ChatTokenUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      model: resolvedModel,
    );
  }

  static int _tokenCount(dynamic raw) {
    final value = switch (raw) {
      num n => n.toInt(),
      String s => int.tryParse(s) ?? 0,
      _ => 0,
    };
    return value < 0 ? 0 : value;
  }
}

class ChatMessage {
  ChatMessage({
    this.id,
    this.messageId,
    this.streamId,
    this.uuid,
    required this.role,
    required this.content,
    this.failureMessage,
    this.failureCode,
    this.status = BubbleStatus.idle,
    this.feedback = FeedbackType.none,
    this.files = const [],
    this.timelineEntries = const [],
    this.reasoningContent = '',
    this.usageSummary,
    this.tokenUsage,
    this.streamStartedAt,
    this.streamEndedAt,
    this.createdAt,
    this.outputFiles = const [],
    this.metadata,
    this.empBlocks = const <Map<String, dynamic>>[],
    this.agentMessageStatus,
    String? localId,
  }) : localId = (localId == null || localId.isEmpty)
            ? ChatLocalIds.next('msg')
            : localId;

  /// 契约 §3.0f C4：客户端生成、workspace/process 级全局唯一的本地 id。
  /// optimistic 创建后 rekey/copyWith/session merge 全程不变；服务端 UUID
  /// 返回前按它定位 placeholder。去重以 server messageId 第一优先，localId
  /// 仅用于尚未绑定服务端 UUID 的消息。
  final String localId;

  final int? id;
  final String? messageId;
  final String? streamId;
  final String? uuid;
  final ChatRole role;
  final String content;

  /// Safe terminal failure reason, independent of answer text and file blocks.
  final String? failureMessage;
  final String? failureCode;
  final BubbleStatus status;
  final FeedbackType feedback;
  final List<ChatFileItem> files;

  /// Plan 16 §J / ADR-0028 Backend Phase 1 (2026-06-08): 后端 agent message
  /// 原始 status 字符串 (`streaming` / `final` / `failed` / `cancelled` /
  /// `awaiting_user`)。与气泡视觉层 [status] 解耦 — UI 气泡仍按 BubbleStatus
  /// (idle / loading / success / error) 渲染颜色 / loading icon, 原始 status
  /// 专供 HITL 富组件 (approval / form / action) 判断是否 enable:
  /// 必须 `agentMessageStatus == 'awaiting_user'` 才允许 EmpBlocksView 启用回调。
  ///
  /// 不显式映射成 enum: 后端可能加新值, 客户端按字符串比较安全可降级。
  /// 历史接口 / SSE awaiting_user 事件均写入; 流式 streaming 期间通常不带,
  /// 由调用方 copyWith 显式覆盖。
  final String? agentMessageStatus;

  /// Plan 16 Batch 1 (2026-06-08) · 保留 agent-bus `message.completed.blocks`
  /// (或历史 `GET /chat/conversations/.../messages` 返回的 EMP blocks) 原样,
  /// 供后续 Batch 2 widget 真渲染消费。**当前**: 仅在终态 (`message.completed` /
  /// history 接口) 写入; `block.delta` 流式累计期间**不**更新 (避免半结构 UI
  /// 抖动); 客户端继续靠 [content] 渲染 markdown/plain 流式文本。
  ///
  /// 形态: `List<Map<String, dynamic>>`, 每个 element 是 EMP block 形态
  /// (含 `type` + per-type 字段, 例 `{type: 'markdown', text: '...'}` /
  /// `{type: 'chart', chart_kind: 'bar', data: ...}`). 解析失败 / 字段类型
  /// 不规范 → 走 [empBlocksToReadableText] 的 fallback (见 lib/emp/blocks)。
  ///
  /// **不参与** SSE delta merge: chat_providers `_applyMessageEvent` finished
  /// 分支用 [copyWith] 一次性赋值; 流式中间态保持空 list。
  final List<Map<String, dynamic>> empBlocks;

  /// 数字员工本轮产出的附件 (后端 `outputFiles` 字段)。
  /// 故意跟 [files] 拆开:气泡正文 markdown 已经会把图片/文件 chip 渲染一次,
  /// 合并到 files 会双倍展示。「聊天历史 - 文件/图片与视频」面板需要这批文件,
  /// 在那里手动 `[...files, ...outputFiles]` 合并使用。
  final List<ChatFileItem> outputFiles;

  /// 服务器侧消息创建时间。GetMessages 接口返回带时区的 ISO8601 字符串，
  /// fromAgentBusJson 解析后转为设备本地时间。用于「聊天历史」面板按本地日期
  /// 分组与展示 HH:mm。SSE 新建的消息没这个字段，调用方可用 [streamStartedAt]
  /// 作为兜底。
  final DateTime? createdAt;

  /// 流式过程中累积的执行过程时间线，用于"思考中 / 已连接 / 调用工具…"折叠面板。
  /// 仅 SSE 在线时累积；history 加载的消息暂不展开（后端历史里没存）。
  final List<ChatTimelineEntry> timelineEntries;

  /// 模型 reasoning delta 累积的纯文本，可被气泡里的"思考"折叠块展开查看。
  final String reasoningContent;

  /// 兼容旧流的用量摘要文本；新 UI 使用结构化 [tokenUsage]，不再常驻气泡正文。
  final String? usageSummary;

  /// `message.completed.usage` 的结构化 token 用量；完成态元信息据此做临时积分估算。
  final ChatTokenUsage? tokenUsage;

  /// 流开始时间（assistant 预留 bubble 初始化）和结束时间（done/error/stopped）。
  /// 用于完成消息 hover/focus 后的总耗时显示。
  final DateTime? streamStartedAt;
  final DateTime? streamEndedAt;

  /// F08 §8.2 #11 · 后端 messages 行携带的扩展 metadata (含 cron trigger / failure
  /// notice 等场景); 客户端按 metadata.triggered_by / metadata.kind 决定是否叠加
  /// cron chip 等业务标识 (详 [CronMessageMetadata]).
  /// 不参与 copy / SSE merge; 仅由 fromJson / fromAgentBusJson 在历史加载时一次性
  /// 解析进来.
  final Map<String, dynamic>? metadata;

  /// 用户本轮选择的技能标签。保留稳定 slug，供气泡从当前数字员工能力摘要解析图标。
  /// `skill` block 是结构化执行参数，不并入正文、复制文本或会话预览。
  List<({String slug, String label})> get selectedSkillTags {
    if (!isQuestion || empBlocks.isEmpty) {
      return const <({String slug, String label})>[];
    }
    final tags = <({String slug, String label})>[];
    final seen = <String>{};
    for (final block in empBlocks) {
      if ((block['type'] ?? '').toString().toLowerCase() != 'skill') continue;
      final slug =
          (block['slug'] ?? block['skill_slug'] ?? '').toString().trim();
      final name = (block['name'] ?? '').toString().trim();
      final label = name.isNotEmpty ? name : slug;
      final key = slug.isNotEmpty ? slug : label;
      if (label.isEmpty || !seen.add(key)) continue;
      tags.add((slug: slug, label: label));
    }
    return tags;
  }

  List<String> get selectedSkillLabels =>
      selectedSkillTags.map((tag) => tag.label).toList(growable: false);

  bool get isAnswer => role == ChatRole.answer;
  bool get isQuestion => role == ChatRole.question;
  bool get isSystem => role == ChatRole.system;
  bool get isSystemPrompt => role == ChatRole.systemPrompt;
  bool get isLoading => status == BubbleStatus.loading;
  bool get isError => status == BubbleStatus.error;

  /// The execution remains failed; only verified delivery evidence changes its presentation.
  String? get deliveryNotice {
    final stopped =
        agentMessageStatus == 'cancelled' || agentMessageStatus == 'stopped';
    if (!isError && !stopped) return null;
    final files = empBlocks.where((b) => b['local_artifact'] is Map).length;
    if (files == 0) return null;
    final summaries =
        empBlocks.where((b) => b['type'] == 'local_delivery').toList();
    if (summaries.length != 1 || summaries.single['verified_count'] != files) {
      return null;
    }
    final summary = summaries.single;
    if (stopped) return '已停止，停止前生成的文件已保留';
    if (summary['status'] == 'complete' &&
        (failureCode == 'zap.local_model_unavailable' ||
            (failureCode?.startsWith('model.') ?? false)) &&
        summary['required_count'] is num &&
        (summary['required_count'] as num) > 0 &&
        (summary['required_count'] as num) <= files) {
      return '文件已生成，后续模型处理失败';
    }
    return '部分文件已生成，任务未完成';
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final roleValue =
        ((json['role'] ?? json['msgType'] ?? '').toString()).toLowerCase();
    final role = switch (roleValue) {
      'user' || 'question' => ChatRole.question,
      'system' || 'system_message' => ChatRole.system,
      'system_prompt' || 'systemprompt' || 'prompt' => ChatRole.systemPrompt,
      _ => ChatRole.answer,
    };
    final status = (json['status'] ?? '').toString();
    final dynamic rawFiles = json['files'];
    List<ChatFileItem> files = const [];
    if (rawFiles is List) {
      files = rawFiles
          .whereType<Map<String, dynamic>>()
          .map(ChatFileItem.fromJson)
          .toList();
    } else if (rawFiles is String && rawFiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawFiles) as List<dynamic>;
        files = decoded
            .whereType<Map<String, dynamic>>()
            .map(ChatFileItem.fromJson)
            .toList();
      } catch (_) {
        files = const [];
      }
    }
    DateTime? createdAt;
    final ts = json['createdAt'];
    if (ts != null) {
      try {
        createdAt = DateTime.parse(ts.toString());
      } catch (_) {}
    }
    // outputFiles: 数字员工产出的附件,仅 assistant 消息可能有。
    final dynamic rawOutputFiles = json['outputFiles'];
    List<ChatFileItem> outputFiles = const [];
    if (rawOutputFiles is List) {
      outputFiles = rawOutputFiles
          .whereType<Map<String, dynamic>>()
          .map(ChatFileItem.fromJson)
          .toList();
    }
    return ChatMessage(
      id: json['id'] as int?,
      messageId: json['messageId']?.toString(),
      streamId: json['streamId']?.toString(),
      uuid: json['uuid']?.toString(),
      role: role,
      content: (json['content'] ?? '').toString(),
      status: _bubbleStatusFromApi(status),
      feedback: FeedbackType.none,
      files: files,
      outputFiles: outputFiles,
      createdAt: createdAt,
      metadata: _readMetadata(json['metadata']),
      tokenUsage: ChatTokenUsage.tryParse(json['usage']),
      empBlocks: _readEmpBlocks(json['blocks']),
      agentMessageStatus: _readAgentMessageStatus(status),
    );
  }

  /// 把后端 raw `status` 字符串规整到 [agentMessageStatus]。仅保留 awaiting_user
  /// / final / failed / cancelled / streaming 这些**与气泡视觉无关**的业务态;
  /// 其它脏字符串返 null (不假装有这层状态)。
  static String? _readAgentMessageStatus(String raw) {
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return null;
    switch (v) {
      case 'awaiting_user':
      case 'streaming':
      case 'final':
      case 'failed':
      case 'cancelled':
        return v;
      default:
        return null;
    }
  }

  /// 把 dynamic 强制成 `List<Map<String, dynamic>>`。任何 element 不合法 (非 Map)
  /// 直接跳过, 不抛异常 (与 `empBlocksToReadableText` 的 best-effort 策略保持一致)。
  ///
  /// 只保留**真正的 EMP 富内容块**(chart/form/table/tool_result 等 typed block)；
  /// 没 type / type=markdown/plain/text 的普通文本块一律不算——口径跟
  /// lib/emp/blocks/emp_block_readable_text.dart 的 _renderOneBlock、
  /// lib/emp/blocks/emp_blocks_view.dart:381、
  /// lib/im/wukong/wukong_im_client.dart 的 _readRawEmpBlocks 保持一致。之前这里
  /// 不分类型把整个 blocks 数组塞进 empBlocks，导致普通 markdown 回复的最终态
  /// (REST 历史 / 流式 finished 收口读到的持久化版本) 被误判成"带 EMP 富内容"，
  /// ChatAssistantMessageView 走 EMP 专用的 ConstrainedBox 分支把气泡撑成近乎整行
  /// 宽——流式过程中气泡是对的，只有转成终态、走到这个函数时才会变宽。
  static List<Map<String, dynamic>> _readEmpBlocks(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    const plainTypes = {'', 'markdown', 'plain', 'text'};
    final out = <Map<String, dynamic>>[];
    for (final b in raw) {
      Map<String, dynamic>? block;
      if (b is Map<String, dynamic>) {
        block = b;
      } else if (b is Map) {
        // 老路径偶有 Map<dynamic, dynamic>; 一次拷贝。
        block = b.map((k, v) => MapEntry(k.toString(), v));
      }
      if (block == null) continue;
      final type = (block['type'] ?? '').toString().trim().toLowerCase();
      if (plainTypes.contains(type)) continue;
      out.add(block);
    }
    return out;
  }

  /// 兼容 metadata 是 jsonb 直出 Map 或后端按字符串透传两种形态.
  static Map<String, dynamic>? _readMetadata(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw.isEmpty ? null : raw;
    }
    if (raw is Map) {
      // 防御性: 老路径偶有 Map<dynamic, dynamic>.
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      return m.isEmpty ? null : m;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return decoded.isEmpty ? null : decoded;
        }
      } catch (_) {}
    }
    return null;
  }

  /// doc-13 §A：从 agent-bus `GET /chat/conversations/{uuid}/messages` 的清洁 DTO 构造。
  /// 字段 `{uuid, role, blocks, status, final, stream_id, error_code, error_message, created_at}`（snake_case + EMP blocks）。
  /// **开发期不兼容**旧 PascalCase / `content` 直出 shape。
  factory ChatMessage.fromAgentBusJson(Map<String, dynamic> json) {
    final roleValue = (json['role'] ?? '').toString().toLowerCase();
    final role = switch (roleValue) {
      'user' => ChatRole.question,
      'system' => ChatRole.system,
      _ => ChatRole.answer,
    };
    final status = (json['status'] ?? '').toString();
    DateTime? createdAt;
    final ts = json['created_at'];
    if (ts != null) {
      try {
        // Bus 返回带时区的 RFC3339 时间点（通常为 UTC）。聊天历史面板会直接
        // 读取 hour/day 做 HH:mm、今天/昨天分组和日期筛选，因此在模型入口统一
        // 转为设备本地时间，避免 UTC 被当成本地时间显示（北京时间会少 8 小时）。
        createdAt = DateTime.parse(ts.toString()).toLocal();
      } catch (_) {}
    }
    final rawBlocks = json['blocks'];
    final visibleBlocks = _withoutA2ATimelineBlocks(rawBlocks);
    // assistant/answer 的 content 只取纯文本部分(plainBlocksText),不再用
    // empBlocksToReadableText 把 typed EMP block 的兜底摘要("[操作栏] xxx")也拼
    // 进去——那份摘要文本本该只在"没有富组件渲染能力"时当兜底用(如 WuKong 通知
    // 正文),这里正文和 empBlocks(下面 _readEmpBlocks)会分别独立渲染,content
    // 里混进摘要会导致 ChatAssistantMessageViewData.fromMessage 判定"EMP 有可读
    // 内容"而把 content 整段丢弃、纯文本介绍语句消失，只剩 EMP 卡片
    // (2026-08-08 复现)。
    final content = role == ChatRole.question
        ? _agentBusUserBlocksToText(visibleBlocks)
        : plainBlocksText(visibleBlocks);
    final errorCode = (json['error_code'] ?? '').toString().trim();
    final errorMessage = (json['error_message'] ?? '').toString().trim();
    return ChatMessage(
      uuid: json['uuid']?.toString(),
      // agent 消息以自身 uuid 作为 stop/retry 的 message id。
      messageId: json['uuid']?.toString(),
      streamId: json['stream_id']?.toString(),
      role: role,
      content: content.trim().isNotEmpty
          ? content
          : status == 'failed' &&
                  (errorCode.isNotEmpty || errorMessage.isNotEmpty)
              ? formatBackendErrorPayload(
                  errorCode: errorCode,
                  errorMessage: errorMessage,
                  fallback: '生成失败',
                )
              : content,
      failureCode: errorCode,
      failureMessage: status == 'failed'
          ? formatBackendErrorPayload(
              errorCode: errorCode,
              errorMessage: errorMessage,
              fallback: '生成失败',
            )
          : null,
      status: _bubbleStatusFromApi(status),
      createdAt: createdAt,
      files: role == ChatRole.question
          ? _agentBusBlocksToFiles(visibleBlocks)
          : const <ChatFileItem>[],
      metadata: _readMetadata(json['metadata']),
      // Batch 1: 历史接口的 EMP blocks 同样保留, 让 Batch 2 widget 渲染历史消息也走真组件。
      empBlocks: _readEmpBlocks(visibleBlocks),
      // 2026-06-12: 历史消息从落库的 tool_call 块重建「已调用 N 个工具 / 执行了命令…」
      // 过程行 (此前历史里只剩信息量为零的「工具结果」卡片)。
      timelineEntries: timelineFromBlocks(rawBlocks, createdAt),
      // Plan 16 §J / ADR-0028: 历史接口透传 raw status (awaiting_user 等), 让客户端
      // 在 history fetch 后能识别 HITL pause 状态; 进入会话即可看到可交互富组件。
      agentMessageStatus: _readAgentMessageStatus(status),
    );
  }

  /// 历史消息没有流式 timeline; 按落库顺序把 tool_call 块还原成与实时一致的
  /// 「调用工具 X · 完成/失败」过程行, tool_result 块按 tool_call_id 回填输出摘要。
  static List<ChatTimelineEntry> timelineFromBlocks(
    dynamic raw,
    DateTime? createdAt,
  ) {
    if (raw is! List) return const <ChatTimelineEntry>[];
    final at = createdAt ?? DateTime.now();
    // tool_result 输出按 tool_call_id 建索引。
    final results = <String, String>{};
    for (final b in raw) {
      if (b is! Map) continue;
      if ((b['type'] ?? '').toString() != 'tool_result') continue;
      final id = (b['tool_call_id'] ?? '').toString();
      final res = (b['result'] ?? b['text'] ?? '').toString().trim();
      if (id.isNotEmpty && res.isNotEmpty) results[id] = res;
    }
    final out = <ChatTimelineEntry>[];
    var i = 0;
    for (final b in raw) {
      if (b is! Map) continue;
      if ((b['type'] ?? '').toString() != 'tool_call') continue;
      // `tool` is the machine identifier (for example a2a.consult), while
      // `name` is the human-facing tool/agent label.
      final name = (b['name'] ?? b['tool'] ?? '').toString();
      final displayName = name.isEmpty ? '工具' : name;
      final id = (b['tool_call_id'] ?? '').toString();
      final input = b['input'];
      final statusRaw = (b['status'] ?? '').toString();
      final failed = statusRaw == 'failed';
      final stopped = statusRaw == 'stopped' || statusRaw == 'cancelled';
      out.add(ChatTimelineEntry(
        key: 'hist-tool-${id.isNotEmpty ? id : i}',
        kind: ChatTimelineKind.tool,
        title: failed
            ? '调用工具 $displayName · 失败'
            : stopped
                ? '调用工具 $displayName · 已停止'
                : '调用工具 $displayName · 完成',
        startedAt: at,
        endedAt: at,
        status: failed
            ? ChatTimelineStatus.error
            : stopped
                ? ChatTimelineStatus.stopped
                : ChatTimelineStatus.done,
        toolName: displayName,
        toolArgs: input == null ? null : jsonEncode(input),
        toolResult: results[id],
      ));
      i++;
    }
    return out;
  }

  static dynamic withoutA2ATimelineBlocks(dynamic raw) {
    if (raw is! List) return raw;
    return raw.where((b) {
      if (b is! Map) return true;
      return (b['x_source'] ?? '').toString() != 'a2a_timeline';
    }).toList(growable: false);
  }

  static dynamic _withoutA2ATimelineBlocks(dynamic raw) =>
      withoutA2ATimelineBlocks(raw);

  static BubbleStatus _bubbleStatusFromApi(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pending':
      case 'processing':
      case 'doing':
      case 'streaming':
        return BubbleStatus.loading;
      case 'error':
      case 'failed':
        return BubbleStatus.error;
      default:
        return BubbleStatus.success;
    }
  }

  ChatMessage copyWith({
    int? id,
    String? messageId,
    String? streamId,
    String? uuid,
    ChatRole? role,
    String? content,
    String? failureMessage,
    String? failureCode,
    BubbleStatus? status,
    FeedbackType? feedback,
    List<ChatFileItem>? files,
    List<ChatTimelineEntry>? timelineEntries,
    String? reasoningContent,
    String? usageSummary,
    ChatTokenUsage? tokenUsage,
    DateTime? streamStartedAt,
    DateTime? streamEndedAt,
    DateTime? createdAt,
    List<ChatFileItem>? outputFiles,
    Map<String, dynamic>? metadata,
    List<Map<String, dynamic>>? empBlocks,
    // `agentMessageStatus` 需要支持显式置空 (例: 用户 /chat/respond 之后旧 message
    // 已 final, 新 message 还没 awaiting_user) — 用 wrapper 区分 "传 null" 与 "不传"。
    Object? agentMessageStatus = _unset,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      streamId: streamId ?? this.streamId,
      uuid: uuid ?? this.uuid,
      role: role ?? this.role,
      content: content ?? this.content,
      failureMessage: failureMessage ?? this.failureMessage,
      failureCode: failureCode ?? this.failureCode,
      status: status ?? this.status,
      feedback: feedback ?? this.feedback,
      files: files ?? this.files,
      timelineEntries: timelineEntries ?? this.timelineEntries,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      usageSummary: usageSummary ?? this.usageSummary,
      tokenUsage: tokenUsage ?? this.tokenUsage,
      streamStartedAt: streamStartedAt ?? this.streamStartedAt,
      streamEndedAt: streamEndedAt ?? this.streamEndedAt,
      createdAt: createdAt ?? this.createdAt,
      outputFiles: outputFiles ?? this.outputFiles,
      metadata: metadata ?? this.metadata,
      empBlocks: empBlocks ?? this.empBlocks,
      agentMessageStatus: identical(agentMessageStatus, _unset)
          ? this.agentMessageStatus
          : agentMessageStatus as String?,
      // C4: localId 全程不变。
      localId: localId,
    );
  }
}

/// 用于 [ChatMessage.copyWith] 区分 "未传参数" 与 "显式传 null" 的哨兵。
const _unset = Object();

class SendMessageResponse {
  const SendMessageResponse({
    required this.messageId,
    required this.streamId,
    required this.conversationId,
    required this.status,
    required this.agentId,
    this.userMessageUuid = '',
  });

  /// agent 预建消息 uuid（= agent-bus `agent_message_uuid`）；assistant 气泡 id，stop 用。
  final String messageId;
  final String streamId;
  final String conversationId;
  final String status;
  final String agentId;

  /// 本轮 user 消息 uuid（= agent-bus `user_message_uuid`）。
  final String userMessageUuid;

  /// doc-13 §A：解析 agent-bus `POST /chat/send` 响应
  /// `{conversation_uuid, stream_id, user_message_uuid, agent_message_uuid}`（snake_case）。
  /// `messageId` 取 **agent_message_uuid**（assistant 预建消息 id，供 stop 用）；
  /// `userMessageUuid` 单列保留。**开发期不兼容**旧 camelCase shape。
  factory SendMessageResponse.fromJson(Map<String, dynamic> json) {
    return SendMessageResponse(
      messageId: (json['agent_message_uuid'] ?? '').toString(),
      streamId: (json['stream_id'] ?? '').toString(),
      conversationId: (json['conversation_uuid'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      agentId: (json['agent_id'] ?? '').toString(),
      userMessageUuid: (json['user_message_uuid'] ?? '').toString(),
    );
  }

  /// 解析 `POST /rooms/{room_uuid}/messages` 响应。
  ///
  /// room API 返回 `stream_ids` 数组，不返回 assistant 预建消息 uuid；agent-direct
  /// 附件 fallback 只取第一条 stream 接既有 SSE，stop 需要等后续 SSE message id。
  factory SendMessageResponse.fromRoomJson(Map<String, dynamic> json) {
    final rawStreams = json['stream_ids'];
    final streamIds = rawStreams is List ? rawStreams : const [];
    final firstStreamId = streamIds
        .map((item) => item?.toString() ?? '')
        .firstWhere((item) => item.isNotEmpty, orElse: () => '');
    return SendMessageResponse(
      messageId: '',
      streamId: firstStreamId,
      conversationId: (json['conversation_uuid'] ?? '').toString(),
      status: '',
      agentId: '',
      userMessageUuid: (json['user_message_uuid'] ?? '').toString(),
    );
  }
}

/// ADR-0028 §4.6 — `POST /api/agent-bus/v1/chat/respond` 响应。
///
/// Bus 在单 PG transaction 内 claim 旧 awaiting_user message + 创建新
/// stream/新 agent message; 这里返**新** stream_id + **新** agent_message_uuid,
/// 客户端按 send 同款流程订阅 new stream 承接后续 ZAP 输出。
class RespondToAgentMessageResponse {
  const RespondToAgentMessageResponse({
    required this.streamId,
    required this.conversationUuid,
    required this.newAgentMessageUuid,
  });

  /// 新 stream_id (不是原 awaiting_user 那条的 stream_id)。
  final String streamId;
  final String conversationUuid;

  /// 新 agent 预留消息 uuid; 客户端 SSE 收到的 message_uuid 应该匹配它。
  final String newAgentMessageUuid;

  factory RespondToAgentMessageResponse.fromJson(Map<String, dynamic> json) {
    return RespondToAgentMessageResponse(
      streamId: (json['stream_id'] ?? '').toString(),
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      newAgentMessageUuid: (json['new_agent_message_uuid'] ?? '').toString(),
    );
  }
}

String _agentBusUserBlocksToText(dynamic blocks) {
  if (blocks is! List) return '';
  final parts = <String>[];
  for (final raw in blocks) {
    if (raw is! Map) continue;
    final type = (raw['type'] ?? '').toString().toLowerCase();
    if (type.isEmpty || type == 'plain' || type == 'text') {
      final text = (raw['text'] ?? '').toString().trim();
      if (text.isNotEmpty) parts.add(text);
    } else if (type == 'markdown') {
      final markdown = (raw['markdown'] ?? raw['text'] ?? '').toString().trim();
      if (markdown.isNotEmpty) parts.add(markdown);
    }
  }
  return parts.join('\n');
}

List<ChatFileItem> _agentBusBlocksToFiles(dynamic blocks) {
  if (blocks is! List) return const <ChatFileItem>[];
  final files = <ChatFileItem>[];
  for (final raw in blocks) {
    if (raw is! Map) continue;
    final type = (raw['type'] ?? '').toString().toLowerCase();
    if (type != 'image' &&
        type != 'file' &&
        type != 'document' &&
        type != 'video') {
      continue;
    }
    final rawSize = raw['size'] ?? raw['size_bytes'] ?? raw['sizeBytes'];
    final linkKeys = type == 'image'
        ? const [
            'preview_url',
            'previewUrl',
            'thumbnail_url',
            'thumbnailUrl',
            'url',
            'src',
            'download_url',
            'downloadUrl',
          ]
        : const [
            'download_url',
            'downloadUrl',
            'url',
            'fileLink',
            'src',
            'preview_url',
            'previewUrl',
          ];
    files.add(ChatFileItem.fromJson({
      'name': _firstBlockString(raw, const [
        'name',
        'file_name',
        'filename',
        'title',
      ]),
      'type': type == 'document' ? 'file' : type,
      'url': _firstBlockString(raw, linkKeys),
      'fileId': _firstBlockString(raw, const [
        'ref_uuid',
        'refUuid',
        'uuid',
        'fileId',
      ]),
      'driveFileId': _firstBlockString(raw, const [
        'file_id',
      ]),
      if (rawSize is num) 'size': rawSize,
    }));
  }
  return files.toList(growable: false);
}

String _firstBlockString(Map raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

class ChatMessagePair {
  const ChatMessagePair({this.question, this.answer});

  final ChatMessage? question;
  final ChatMessage? answer;
}

List<ChatMessagePair> buildChatMessagePairs(List<ChatMessage> messages) {
  final pairs = <ChatMessagePair>[];
  for (var i = 0; i < messages.length; i++) {
    final current = messages[i];
    if (current.isQuestion) {
      ChatMessage? answer;
      if (i + 1 < messages.length && messages[i + 1].isAnswer) {
        answer = messages[i + 1];
        i += 1;
      }
      pairs.add(ChatMessagePair(question: current, answer: answer));
    } else {
      pairs.add(ChatMessagePair(question: null, answer: current));
    }
  }
  return pairs;
}
