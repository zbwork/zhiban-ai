/// emp_blocks_view.dart — Plan 16 §J / ADR-0028 · EMP block 渲染 + HITL 最小可交互。
///
/// 终态 `message.completed.blocks` (或 `message.awaiting_user` blocks) 进入
/// [EmpBlocksView] 后, 已 seed 富组件 (markdown / plain / chart / form / approval /
/// confirm / action / artifact / source / progress / app_card / plan / tool_result /
/// code / table / error / unknown) 都会**真渲染**结构化 UI, 而**不**是单行 fallback。
///
/// 设计纪律 (Plan 16 §C + ADR-0028 §4.9):
///   1. **默认只读** — 缺少任一 HITL 上下文 ([agentMessageStatus]='awaiting_user' /
///      [agentMessageUuid] 非空 / [conversationUuid] 非空 / [respondHandler] 装配) 时,
///      需要回调的控件保持只读或 disabled, 展示型 block 继续正常渲染;
///   2. **HITL 最小可交互** — 四条件全满足时 approval / confirm / form / action 开放:
///        - approval / approval_request → `onApproval(decision='approve'|'reject')`
///        - confirm → `onConfirm(confirmed:true|false)` (与 approval **不**共用 payload)
///        - form → `onForm(fields)`, 支持 text / textarea / number / select / radio /
///          multiselect / switch / checkbox / date / time / datetime; **file** 字段
///          通过容器层 message-files 上传后把文件引用写入 form payload;
///          date 提交 `YYYY-MM-DD`, time 提交 `HH:mm`, datetime 提交 `YYYY-MM-DDTHH:mm:00`
///          (Plan 17 round-5 固定; agent-example reference echo 路径同款解析)
///        - action → `onAction(actionId)`;
///      富 UI 仍是**最小交互**: chart 用 fl_chart 渲染常见图表; approval 不弹
///      reason 输入框 (传 null); 文件多选 / 上传进度增强留后续提案;
///   3. **best-effort** — 单 block 字段类型错 / 抛异常都不能影响相邻 block 渲染,
///      失败时退化到 [empBlocksToReadableText] 的单行文本占位;
///   4. **不重复内容** — 上层 `fromMessage` 已经把 markdown content 排除 (有
///      empBlocks 就不追加 ChatAssistantTextBlock); 本 widget 直接渲染 blocks
///      内的 markdown/plain 内容, 不会与气泡 content 双倍展示。
library;

import 'package:zhiban_core/emp/emp_attachment_links.dart';

import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_card.dart';
import 'dart:async';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart' as fl;
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

/// ADR-0028 §4.5 / Plan 16 §J — HITL 富组件提交回调集。
///
/// 调用方 (上层 `ChatNotifier`) 把这个对象注入到 [EmpBlocksView]; widget 自身**不**
/// 直接调网络, 也**不**自己组装 `/chat/respond` body — 只把"用户点了同意 + 可选 reason"
/// / "用户填了 fields" / "用户选择了表单附件" / "用户点了 action_id + params"
/// 这些**业务事件**透出去, 由 notifier / 容器层决定是否上传文件、是否调
/// `ChatService.respondToAgentMessage`、是否乐观更新、失败 toast。
///
/// 任一回调返回 `Future<bool>`:
///   - `true`  表示后端成功接收 (例: `/chat/respond` 200, 已订阅新 stream_id);
///     widget 进入"已提交"态 (本版本表现为按钮持续 disabled, 等新 SSE 终态);
///   - `false` 表示失败 (网络 / 4xx / 5xx / 装配错), widget 解除"提交中" lock,
///     允许用户重试 (上层应同时弹 toast — widget 不负责 toast)。
class EmpBlocksRespondHandler {
  const EmpBlocksRespondHandler({
    required this.onApproval,
    required this.onConfirm,
    required this.onForm,
    required this.onAction,
    this.onA2AApproval,
    this.onA2AForm,
    this.onFile,
    this.onSendText,
    this.onOpenPayment,
    this.onOpenEmployee,
  });

  /// approval / approval_request: `decision` ∈ {'approve', 'reject'} (后端
  /// `response_kind='approval'`); reason 第一版前端不暴露输入, 直接传 null。
  /// 后端 [buildRespondReplyBlock](services/agent-bus/internal/service/chat/respond.go)
  /// approval 分支只读 `decision` / `reason`, **不**读 `confirmed`。
  final Future<bool> Function({
    required String agentMessageUuid,
    required String decision,
    String? reason,
  }) onApproval;

  /// A2A 协作审批: block 携带 `approval_request_id` 时不走 `/chat/respond`,
  /// 直接由容器层提交到 `/a2a/approvals/{approval_request_id}/decide` 并恢复原 Agent B edge。
  final Future<bool> Function({
    required String approvalRequestId,
    required String decision,
    String? reason,
  })? onA2AApproval;

  /// confirm: `confirmed:true|false` (后端 `response_kind='confirm'`,
  /// payload 形如 `{confirmed: bool}`)。与 approval 完全不同语义 —
  /// 后端 confirm 分支只读 `confirmed`, **不**读 `decision`。如果客户端把
  /// confirm 错误映射成 approval, runtime 会拿到 `{decision: 'approve'}`,
  /// 而 confirm 业务需要的 `confirmed` 字段缺失 → 业务卡死。
  final Future<bool> Function({
    required String agentMessageUuid,
    required bool confirmed,
  }) onConfirm;

  /// form: fields 是 widget 收集到的字段 map; round-5 起支持 text / textarea / number /
  /// select / radio / multiselect / switch / checkbox / date / time / datetime;
  /// `file` 由 [onFile] 走外层上传链路后写入 fields, widget 自身不碰 picker / 网络。
  /// widget 在提交前做"必填项缺失"校验 (服务端 schema 校验由 runtime 负责)。
  final Future<bool> Function({
    required String agentMessageUuid,
    required Map<String, dynamic> fields,
  }) onForm;

  final Future<bool> Function({
    required String approvalRequestId,
    required Map<String, dynamic> fields,
  })? onA2AForm;

  /// form file 字段: 由容器层执行"选择本地文件 + message-files 上传", 成功返回
  /// `{file_id,name,size,mime_type,url}` 等字段; 返回 null 表示用户取消或上传失败。
  final Future<Map<String, dynamic>?> Function({
    required String fieldName,
    required String fieldLabel,
  })? onFile;

  /// action: action_id 来自 awaiting_user 那条 action 块的 `actions[*].id`;
  /// params 第一版不暴露用户输入, 透传空 map 即可 — runtime/agent 据 action_id 决策。
  final Future<bool> Function({
    required String agentMessageUuid,
    required String actionId,
    Map<String, dynamic>? params,
  }) onAction;

  /// suggestion chip（「猜你想问」追问引导）: 点击 = 把该问题作为一条**普通
  /// 用户消息**发送（气泡立即上屏 + 正常流式回复）, **不**走 `/chat/respond`
  /// 回灌 — 旧 action 回灌形态点击后按钮转圈干等整轮, 体验差 (2026-07-15
  /// 交互修订)。不受 awaiting_user 四条件门控: 历史消息上的 chip 永远可点。
  /// 未装配 (null) 时 suggestion 块退化为只读 chips。
  final Future<void> Function(String text)? onSendText;

  /// `open_payment:` 前缀 action 的本地动作（F24 代账服务费「去支付」,
  /// 2026-07-24 收款线上化）: 点击 = 客户端本地打开支付页/弹窗, **不**走
  /// `/chat/respond` 回灌。与 [onSendText] 同理豁免 awaiting_user 门控——
  /// 历史消息上的支付按钮持续可点, 是否可付由服务端订单/工单状态兜底
  /// （已签约再下单会被 409 拒）。未装配 (null) 时该按钮按普通 action 门控置灰。
  final Future<void> Function(String actionId)? onOpenPayment;

  /// `open_employee:` 前缀 action 的本地动作（F26 助手间衔接, 2026-07-24,
  /// 如创业助手代账建账完成通知的「找财税助手」）: 点击 = 按 action_id 携带的
  /// **数字员工显示名**在会话列表定位并切换到该员工聊天框, **不**走
  /// `/chat/respond` 回灌。与 [onOpenPayment] 同理豁免 awaiting_user 门控——
  /// 历史消息上的按钮持续可点; 找不到同名员工由容器层 toast 兜底。
  /// 未装配 (null) 时该按钮按普通 action 门控置灰。
  final Future<void> Function(String actionId)? onOpenEmployee;
}

/// 内部分类: `approval` 类卡片 (含 `approval` / `approval_request`) 与 `confirm`
/// 类卡片用不同的提交回调 (前者 decision='approve'|'reject', 后者 confirmed:true|false)。
enum _ApprovalKind { approval, confirm }

class EmpBlocksView extends StatelessWidget {
  const EmpBlocksView({
    super.key,
    required this.blocks,
    this.agentMessageStatus,
    this.agentMessageUuid,
    this.conversationUuid,
    this.respondHandler,
  });

  /// 终态 `message.completed.blocks` (或历史接口的 blocks)。
  final List<Map<String, dynamic>> blocks;

  /// ADR-0028 §4.9 — 后端 raw agent message status (例 'awaiting_user' / 'final')。
  /// 富组件 enable 必要条件之一; 缺失视为不可交互。
  final String? agentMessageStatus;

  /// 后端 agent message uuid (= ChatMessage.messageId)。回调时传给后端 `/chat/respond`。
  final String? agentMessageUuid;

  /// 当前 conversation uuid。本 widget 不直接 POST, 但上层可能用它做幂等键。
  final String? conversationUuid;

  /// HITL 提交回调集; null 时所有富组件保持只读 (B1+B2 旧行为)。
  final EmpBlocksRespondHandler? respondHandler;

  /// 4 条件 enable 守卫 (ADR §4.9): raw status='awaiting_user' + messageId 非空 +
  /// conversationUuid 非空 + respondHandler 非空。任一缺失 → 仍保持 disabled。
  bool get _interactiveAllowed =>
      agentMessageStatus == 'awaiting_user' &&
      (agentMessageUuid ?? '').isNotEmpty &&
      (conversationUuid ?? '').isNotEmpty &&
      respondHandler != null;

  @override
  Widget build(BuildContext context) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    final widgets = <Widget>[];
    final normalizedBlocks = _deduplicateLocalArtifacts(
        suppressDuplicateAttachmentLinks(blocks), conversationUuid ?? '');
    final pairs = <String, List<int>>{};
    for (var i = 0; i < normalizedBlocks.length; i++) {
      final card = _fileCard(normalizedBlocks[i]);
      if (card?.source == null) continue;
      final name = card!.target.name;
      final dot = name.lastIndexOf('.');
      if (dot <= 0 ||
          !['svg', 'png'].contains(name.substring(dot + 1).toLowerCase())) {
        continue;
      }
      final key = '${card.source!.deviceId}:${name.substring(0, dot)}';
      (pairs[key] ??= []).add(i);
    }
    final partners = <int, int>{};
    for (final indexes in pairs.values) {
      if (indexes.length != 2) continue;
      final a = indexes[0], b = indexes[1];
      if (_fileCard(normalizedBlocks[a])!
              .target
              .name
              .split('.')
              .last
              .toLowerCase() ==
          _fileCard(normalizedBlocks[b])!
              .target
              .name
              .split('.')
              .last
              .toLowerCase()) {
        continue;
      }
      partners[a] = b;
      partners[b] = a;
    }
    final consumed = <int>{};
    for (var i = 0; i < normalizedBlocks.length; i++) {
      if (consumed.contains(i)) continue;
      final b = normalizedBlocks[i];
      Widget? w;
      final card = _fileCard(b);
      if (card != null) {
        if (partners.containsKey(i)) {
          final partnerIndex = partners[i]!;
          consumed.add(partnerIndex);
          final other = _fileCard(normalizedBlocks[partnerIndex])!;
          final isPng = card.target.name.toLowerCase().endsWith('.png');
          w = ChatArtifactGroup(maxWidth: 340, cards: [
            isPng ? card : other,
            (isPng ? other : card)
                .inGroup(showArchiveStatus: true, compact: true),
          ]);
        } else if (card.format == 'image' || card.format == 'video') {
          w = card;
        } else {
          final cards = <ChatArtifactCard>[card];
          while (i + 1 < normalizedBlocks.length) {
            if (consumed.contains(i + 1) || partners.containsKey(i + 1)) break;
            final next = _fileCard(normalizedBlocks[i + 1]);
            if (next == null ||
                next.format == 'image' ||
                next.format == 'video') {
              break;
            }
            cards.add(next);
            i++;
          }
          w = ChatArtifactGroup(cards: cards);
        }
      } else {
        w = _buildOne(context, b);
      }
      if (w == null) continue;
      if (widgets.isNotEmpty) {
        // 12 → 16: 卡片跟上一块内容(常见是紧挨着的正文/编号列表)贴太近——
        // 2026-08-17 用户反馈。
        widgets.add(const SizedBox(height: 16));
      }
      widgets.add(w);
    }
    if (widgets.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  ChatArtifactCard? _fileCard(Map<String, dynamic> block) {
    final type = _asString(block['type']).toLowerCase();
    if (!['file', 'image', 'video'].contains(type) &&
        LocalArtifactSource.fromBlock(block, conversationUuid ?? '') == null) {
      return null;
    }
    return _MediaBlockView(
            block: block, kind: type, conversation: conversationUuid ?? '')
        .card();
  }

  /// 单 block 渲染; 任意异常都退化到 [_fallbackText] (readable single-line)。
  Widget? _buildOne(BuildContext context, Map<String, dynamic> b) {
    final type = _asString(b['type']).toLowerCase();
    try {
      switch (type) {
        case '':
        case 'markdown':
        case 'plain':
        case 'text':
          final text =
              _firstNonEmpty([_asString(b['text']), _asString(b['markdown'])]);
          if (text.isEmpty) return null;
          return ChatSelectableSurface(
            child: ChatMarkdownWidget(
                content: text, compact: true, selectable: false),
          );
        case 'code':
          return _CodeBlockView(block: b);
        case 'chart':
          return _ChartBlockView(block: b);
        case 'table':
          return _TableBlockView(block: b);
        case 'form':
          final approvalRequestId = _a2aApprovalRequestId(b);
          return _FormBlockView(
            block: b,
            interactive: approvalRequestId.isNotEmpty
                ? respondHandler?.onA2AForm != null
                : _interactiveAllowed,
            agentMessageUuid: agentMessageUuid ?? '',
            approvalRequestId: approvalRequestId,
            onSubmit: respondHandler?.onForm,
            onA2ASubmit: respondHandler?.onA2AForm,
            onFile: respondHandler?.onFile,
          );
        case 'approval':
        case 'approval_request':
          final approvalRequestId = _a2aApprovalRequestId(b);
          return _ApprovalBlockView(
            block: b,
            kind: _ApprovalKind.approval,
            interactive: approvalRequestId.isNotEmpty
                ? respondHandler?.onA2AApproval != null
                : _interactiveAllowed,
            agentMessageUuid: agentMessageUuid ?? '',
            approvalRequestId: approvalRequestId,
            onApproval: respondHandler?.onApproval,
            onA2AApproval: respondHandler?.onA2AApproval,
            onConfirm: null,
          );
        case 'confirm':
          // 后端语义: type='confirm' → response_kind='confirm', payload={confirmed: bool}。
          // 不能复用 approval 路径 (会让后端拿到 {decision:'approve'}, confirmed 字段缺失,
          // 业务卡死)。详 services/agent-bus/internal/service/chat/respond.go::buildRespondReplyBlock。
          return _ApprovalBlockView(
            block: b,
            kind: _ApprovalKind.confirm,
            interactive: _interactiveAllowed,
            agentMessageUuid: agentMessageUuid ?? '',
            approvalRequestId: '',
            onApproval: null,
            onA2AApproval: null,
            onConfirm: respondHandler?.onConfirm,
          );
        case 'action':
        case 'action_bar':
          return _ActionBlockView(
            block: b,
            interactive: _interactiveAllowed,
            agentMessageUuid: agentMessageUuid ?? '',
            onAction: respondHandler?.onAction,
            onOpenPayment: respondHandler?.onOpenPayment,
            onOpenEmployee: respondHandler?.onOpenEmployee,
          );
        case 'artifact':
          return _ArtifactBlockView(block: b);
        case 'source':
        case 'citation':
          return _SourceBlockView(block: b);
        case 'app_card':
          return _AppCardBlockView(block: b);
        case 'progress':
          return _ProgressBlockView(block: b);
        case 'tool_call':
        case 'tool_result':
        case 'local_delivery':
        case 'reasoning':
          // 过程块只进入消息气泡上方的执行时间线；正文 EMP 区不再渲染
          // "工具调用/工具结果/推理过程"卡片，避免终态历史消息重复展示过程。
          return null;
        case 'plan':
          return _PlanBlockView(block: b);
        case 'error':
          return _InlineErrorBlockView(block: b);
        case 'suggestion':
        case 'suggestions':
          // 点击=发消息（onSendText）; 不受 awaiting 四条件门控, 历史 chip 永远可点。
          return _SuggestionBlockView(
            block: b,
            onSendText: respondHandler?.onSendText,
          );
        case 'mermaid':
        case 'flowchart':
          return _DiagramSourceBlockView(block: b, kind: type);
        case 'video':
          // Every video uses the shared artifact player, including file MIME videos.
          return _MediaBlockView(block: b, kind: 'video');
        case 'audio':
          // round-8: audio 接真播放器 (audioplayers, 已有依赖); 失败退化 file-card。
          return _AudioPlayerView(block: b);
        case 'image':
        case 'file':
          // image / file 仍走文件卡 (image 自带 Image.network 预览); 不在本轮接入。
          return _MediaBlockView(
              block: b, kind: type, conversation: conversationUuid ?? '');
        default:
          // unknown type: 直接走 readable text fallback (单行 [type] 占位)。
          return _fallbackText(context, b);
      }
    } catch (_) {
      return _fallbackText(context, b);
    }
  }

  Widget? _fallbackText(BuildContext context, Map<String, dynamic> b) {
    final text = empBlocksToReadableText([b]);
    if (text.trim().isEmpty) return null;
    return Text(text,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: Colors.black54));
  }
}

// ---------------- safe coerce helpers (与 emp_block_readable_text.dart 同纪律) ----------------

String _asString(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return '';
}

/// Display deduplication only: a different name, device or content snapshot
/// stays visible. Retries can produce a new artifact id for the same bytes, so
/// the artifact id itself is deliberately not part of this display key.
List<Map<String, dynamic>> _deduplicateLocalArtifacts(
    List<Map<String, dynamic>> blocks, String conversation) {
  final seen = <String>{};
  return blocks.where((block) {
    final source = LocalArtifactSource.fromBlock(block, conversation);
    if (source == null) return true;
    final name = _firstNonEmpty([
      _asString(block['name']),
      _asString(block['filename']),
      _asString(block['file_name']),
      _asString(block['title'])
    ]);
    return seen
        .add('${source.deviceId}:${source.driveFileId}:${source.sha256}:$name');
  }).toList(growable: false);
}

String _deriveAttachmentPreviewUrl(String downloadUrl) {
  return normalizeAttachmentPreviewUrl(downloadUrl);
}

List<dynamic>? _asList(Object? v) {
  if (v is List) return v;
  return null;
}

Map<dynamic, dynamic>? _asMap(Object? v) {
  if (v is Map) return v;
  return null;
}

String _firstNonEmpty(List<String> candidates) {
  for (final c in candidates) {
    if (c.isNotEmpty) return c;
  }
  return '';
}

String _a2aApprovalRequestId(Map<String, dynamic> block) {
  if ((block['x_source'] ?? '').toString() != 'a2a_approval') return '';
  return _asString(block['approval_request_id']).trim();
}

// ---------------- shared card chrome ----------------

class _BlockCard extends StatelessWidget {
  const _BlockCard({
    required this.title,
    required this.child,
    this.titleIcon,
    this.titleColor,
  });

  final String title;
  final IconData? titleIcon;
  final Color? titleColor;
  final double titleIconSize = 16;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = titleColor ?? const Color(0xFF2563EB);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      // 2026-08-17 用户反馈:卡片整体 padding 偏大,上下各收紧一点。
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      margin: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (titleIcon != null) ...[
                Icon(titleIcon, size: titleIconSize, color: accent),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: accent
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _ReadOnlyHint extends StatelessWidget {
  const _ReadOnlyHint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
      ),
    );
  }
}

// ---------------- form field visual helpers ----------------

/// allowCustom select 的「其他（手动输入）」占位值：选中但未输入自定义值时
/// 字段的临时值，required 校验与提交都把它当"未填"（契约 §3.0a allowCustom）。
const String formOtherSentinel = '__form_other__';

const _formBorderColor = Color(0xFFD1D5DB);
const _formFocusedBorderColor = Color(0xFF2563EB);
const _formFillColor = Color(0xFFFFFFFF);
const _formDisabledFillColor = Color(0xFFF9FAFB);
const _formTextColor = Color(0xFF111827);
const _formMutedTextColor = Color(0xFF6B7280);

OutlineInputBorder _formInputBorder(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: color, width: width),
  );
}

InputDecoration _formInputDecoration({
  String? hintText,
  String? helperText,
  EdgeInsetsGeometry? contentPadding,
}) {
  return InputDecoration(
    hintText: hintText,
    helperText: helperText,
    hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
    helperStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
    isDense: true,
    filled: true,
    fillColor: _formFillColor,
    contentPadding: contentPadding ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    border: _formInputBorder(_formBorderColor),
    enabledBorder: _formInputBorder(_formBorderColor),
    focusedBorder: PlatformUtils.isMobile
        ? _formInputBorder(_formBorderColor)
        : _formInputBorder(_formFocusedBorderColor, width: 1.5),
    disabledBorder: _formInputBorder(const Color(0xFFE5E7EB)),
  );
}

class _FormFieldShell extends StatelessWidget {
  const _FormFieldShell({
    required this.child,
    required this.enabled,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  final Widget child;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: enabled ? _formFillColor : _formDisabledFillColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: enabled ? _formBorderColor : const Color(0xFFE5E7EB),
        ),
      ),
      child: child,
    );
  }
}

// ---------------- per-type views ----------------

class _CodeBlockView extends StatelessWidget {
  const _CodeBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final lang = _firstNonEmpty(
        [_asString(block['language']), _asString(block['lang'])]);
    final text = _firstNonEmpty([
      _asString(block['text']),
      _asString(block['source']),
      _asString(block['content']),
    ]);
    if (text.isEmpty) {
      return const Text('[代码]',
          style: TextStyle(color: Colors.black54, fontSize: 13));
    }
    // 复用现有 markdown 渲染的 code fence 高亮。
    return ChatSelectableSurface(
      child: ChatMarkdownWidget(
          content: '```$lang\n$text\n```', compact: true, selectable: false),
    );
  }
}

/// Inline Visualization 2.0 chart renderer (Plan 18 Phase 1+2).
///
/// 协议字段 (与 docs/contracts/agent-bus-client-contract.md §3.0a 同源):
///   - 必有: `type='chart'`, `chart_kind` (bar/line/area/pie/donut/scatter/radar/kpi/...)
///   - 数据: `data:[{label,value}]` 或 `series:[{name,data:[{label,value}]}]`
///   - 文本: `title` / `summary` (summary 走 markdown compact 渲染)
///   - **round-9 新增可选字段**:
///       * `insights: [string]` — header 下方轻量结论 chips, 最多展示前 3 个
///       * `unit: string` — y 轴 / KPI 数值单位 (例: "万元", "%", "DAU")
///       * `source: string` — footer 数据来源标签
///       * `updated_at: string` — footer 相对时间显示原样 (运行时已格式化好)
///       * `table: {headers:[], rows:[[]]}` — 优先级高于自动从 data 推断的"查看表格"内容
///
/// 已实装 widget: bar / line / area / pie / donut / scatter / radar / kpi
/// fallback (含未知 kind / mixed / heatmap / sankey / candlestick / map):
///   走 [_UnsupportedChart] 富 fallback — title + summary + insights + 原始数据预览,
///   **不**在聊天气泡内引入 WebView / ECharts (Plan 18 §H 硬约束)。
class _ChartBlockView extends StatelessWidget {
  const _ChartBlockView({required this.block});
  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    try {
      return _buildCard(context);
    } catch (_) {
      // 任何渲染异常 (字段类型奇葩 / fl_chart 内部断言失败) → 退化到 fallback 卡片,
      // **不**让相邻 block 跟着抽空。
      return _UnsupportedChart(
        kind: _asString(block['chart_kind']),
        title: _asString(block['title']),
        summary: _asString(block['summary']),
        insights: _extractInsights(block['insights']),
        entries: const [],
        tableHeaders: const [],
        tableRows: const [],
        reason: '渲染异常',
      );
    }
  }

  Widget _buildCard(BuildContext context) {
    final title = _asString(block['title']);
    final kind = _firstNonEmpty(
            [_asString(block['chart_kind']), _asString(block['kind'])])
        .toLowerCase();
    final summary = _asString(block['summary']);
    final unit = _asString(block['unit']);
    final source = _asString(block['source']);
    final updatedAt = _asString(block['updated_at']);
    final insights = _extractInsights(block['insights']);
    final tableInfo = _ChartTableInfo.extract(block);

    final rawData = _asList(block['data']);
    final entries = _BarEntry.extract(rawData);
    final barSeries = _BarSeries.extract(block);
    final hasSeriesData = barSeries.labels.isNotEmpty;
    final hasData = entries.isNotEmpty || hasSeriesData;
    final dataIsMalformed = !hasData && rawData != null && rawData.isNotEmpty;

    final knownKinds = const {
      '',
      'bar',
      'line',
      'area',
      'pie',
      'donut',
      'scatter',
      'radar',
      'kpi',
    };
    final isKnownKind = knownKinds.contains(kind);

    Widget body;
    if (!isKnownKind) {
      // 未知 chart_kind (mixed / heatmap / sankey / candlestick / map / 自造类型)
      // → 富 fallback (title / summary / insights / 原始数据预览), 不空白屏。
      body = _UnsupportedChart(
        kind: kind,
        title: title,
        summary: summary,
        insights: insights,
        entries: entries,
        tableHeaders: tableInfo.headers,
        tableRows: tableInfo.rows,
        reason: '暂不支持的图表类型',
      );
    } else if (!hasData) {
      // known kind 但数据空 / malformed → 也走富 fallback, 保留 summary + 原始数据预览。
      body = _UnsupportedChart(
        kind: kind,
        title: title,
        summary: summary,
        insights: insights,
        entries: entries,
        tableHeaders: tableInfo.headers,
        tableRows: tableInfo.rows,
        reason: dataIsMalformed ? '数据格式不合法' : '暂无可视化数据',
      );
    } else {
      switch (kind) {
        case 'bar':
        case '':
          body = _BarChart(
            series: hasSeriesData
                ? barSeries
                : _BarSeries.singleFromEntries(entries),
            unit: unit,
          );
          break;
        case 'line':
        case 'area':
          body = _LineChart(
            entries: entries,
            fillArea: kind == 'area',
            unit: unit,
          );
          break;
        case 'pie':
        case 'donut':
          body = _PieChart(entries: entries, isDonut: kind == 'donut');
          break;
        case 'scatter':
          body = _ScatterChart(entries: entries, unit: unit);
          break;
        case 'radar':
          body = _RadarChart(entries: entries);
          break;
        case 'kpi':
          body = _KpiCard(entries: entries, unit: unit);
          break;
        default:
          // unreachable (isKnownKind already filtered)
          body = _UnsupportedChart(
            kind: kind,
            title: title,
            summary: summary,
            insights: insights,
            entries: entries,
            tableHeaders: tableInfo.headers,
            tableRows: tableInfo.rows,
            reason: '暂不支持的图表类型',
          );
      }
    }

    // unsupported 卡片自带完整 chrome (含 title / summary / preview) — 直接渲染, 不再包外层 BlockCard,
    // 避免双层标题/重复。
    final isUnsupportedBody = body is _UnsupportedChart;
    if (isUnsupportedBody) return body;

    return _BlockCard(
      title: _composeCardTitle(title, kind),
      titleIcon: _iconForChartKind(kind),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header chip 行: kind / data points 数量, 一眼看清 chart 性质。
          _ChartHeaderMeta(
            kind: kind,
            entriesCount:
                hasSeriesData ? barSeries.labels.length : entries.length,
            unit: unit,
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            // markdown 渲染让 summary 可以带 **bold** / 链接, 不只是单行 Text。
            ChatSelectableSurface(
              child: ChatMarkdownWidget(
                  content: summary, compact: true, selectable: false),
            ),
          ],
          if (insights.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InsightChips(insights: insights),
          ],
          const SizedBox(height: 10),
          body,
          if (source.isNotEmpty ||
              updatedAt.isNotEmpty ||
              tableInfo.hasContent) ...[
            const SizedBox(height: 8),
            _ChartFooter(
              source: source,
              updatedAt: updatedAt
            ),
          ],
        ],
      ),
    );
  }

  static String _composeCardTitle(String title, String kind) {
    final t = title.isNotEmpty ? title : '图表';
    return kind.isNotEmpty ? '$t · $kind' : t;
  }

  static IconData _iconForChartKind(String kind) => switch (kind) {
        'line' || 'area' => Icons.show_chart_rounded,
        'pie' || 'donut' => Icons.donut_large_rounded,
        'kpi' => Icons.speed_rounded,
        'scatter' => Icons.scatter_plot_outlined,
        'radar' => Icons.radar_rounded,
        _ => Icons.bar_chart_rounded,
      };

  static List<String> _extractInsights(Object? raw) {
    final list = _asList(raw);
    if (list == null) return const [];
    final out = <String>[];
    for (final v in list) {
      final s = _asString(v);
      if (s.isNotEmpty) out.add(s);
      if (v is Map) {
        final m = v;
        final s2 = _firstNonEmpty([
          _asString(m['label']),
          _asString(m['text']),
          _asString(m['title']),
        ]);
        if (s2.isNotEmpty) out.add(s2);
      }
    }
    return out;
  }
}

/// Chart `table` 字段 (round-9): 优先用 block.table; 否则自动从 entries 推断为
/// "label / value" 两列预览。
class _ChartTableInfo {
  const _ChartTableInfo({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;

  static _ChartTableInfo empty() =>
      const _ChartTableInfo(headers: [], rows: []);

  bool get hasContent => rows.isNotEmpty;

  static _ChartTableInfo extract(Map<String, dynamic> block) {
    final rawTable = _asMap(block['table']);
    if (rawTable != null) {
      final headers = <String>[];
      for (final h in _asList(rawTable['headers']) ?? const []) {
        headers.add(_asString(h));
      }
      final rows = <List<String>>[];
      for (final r in _asList(rawTable['rows']) ?? const []) {
        if (r is List) {
          rows.add([for (final c in r) _asString(c)]);
        }
      }
      if (headers.isNotEmpty || rows.isNotEmpty) {
        return _ChartTableInfo(headers: headers, rows: rows);
      }
    }
    // 自动从 data / series 推断: label + value(s)
    final series = _BarSeries.extract(block);
    if (series.labels.isNotEmpty) {
      final headers = <String>[
        'label',
        for (final s in series.seriesList) s.name.isNotEmpty ? s.name : 'value',
      ];
      final rows = <List<String>>[];
      for (var i = 0; i < series.labels.length; i++) {
        final row = <String>[series.labels[i]];
        for (final s in series.seriesList) {
          final v = i < s.values.length ? s.values[i] : null;
          row.add(v == null ? '—' : _formatChartNum(v));
        }
        rows.add(row);
      }
      return _ChartTableInfo(headers: headers, rows: rows);
    }
    final entries = _BarEntry.extract(_asList(block['data']));
    if (entries.isNotEmpty) {
      return _ChartTableInfo(
        headers: const ['label', 'value'],
        rows: [
          for (final e in entries) [e.label, _formatChartNum(e.value)],
        ],
      );
    }
    return empty();
  }
}

/// Chart header 元数据行: kind chip / 数据点数量 / 可选单位。
class _ChartHeaderMeta extends StatelessWidget {
  const _ChartHeaderMeta({
    required this.kind,
    required this.entriesCount,
    required this.unit,
  });

  final String kind;
  final int entriesCount;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (entriesCount > 0) {
      chips.add(_metaChip('$entriesCount 个数据点'));
    }
    if (unit.isNotEmpty) {
      chips.add(_metaChip('单位 · $unit'));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips
    );
  }

  static Widget _metaChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFDBEAFE)),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF1D4ED8),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}

/// 轻量 insights chips — header 下方 1 行结论卡 (最多 3 个)。
class _InsightChips extends StatelessWidget {
  const _InsightChips({required this.insights});
  final List<String> insights;

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    // 截断到 3 个, 避免一长串 chips 撑爆 chart card。
    final shown = insights.take(3).toList();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final s in shown) _InsightChip(text: s),
        if (insights.length > shown.length)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '+${insights.length - shown.length}',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}

class _InsightChip extends StatelessWidget {
  const _InsightChip({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF0F9FF), Color(0xFFECFDF5)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBAE6FD)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFF065F46),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// chart footer: source · updated_at (轻字, 12px / 灰色)。
class _ChartFooter extends StatelessWidget {
  const _ChartFooter({required this.source, required this.updatedAt});
  final String source;
  final String updatedAt;
  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (source.isNotEmpty) parts.add('数据源: $source');
    if (updatedAt.isNotEmpty) parts.add('更新: $updatedAt');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.info_outline, size: 12, color: Color(0xFF9CA3AF)),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _BarEntry {
  const _BarEntry({required this.label, required this.value});
  final String label;
  final double value;

  /// 从 block.data 抽出 `(label, value)` 序列。
  ///
  /// 兼容:
  ///   - `List<num>` — label 用 `x<i>` 占位
  ///   - `List<{label/name/x, value/y/count}>` — label 跟 value 都解析
  ///
  /// fail-soft: 单元素 malformed (例 `"abc"`) 静默跳过, 不抛。
  static List<_BarEntry> extract(List<dynamic>? data) {
    if (data == null) return const [];
    final out = <_BarEntry>[];
    for (var i = 0; i < data.length; i++) {
      final d = data[i];
      if (d is num) {
        out.add(_BarEntry(label: 'x$i', value: d.toDouble()));
      } else if (d is Map) {
        final lab = _firstNonEmpty([
          _asString(d['label']),
          _asString(d['name']),
          _asString(d['x']),
          'x$i',
        ]);
        final val = d['value'] ?? d['y'] ?? d['count'];
        if (val is num) {
          out.add(_BarEntry(label: lab, value: val.toDouble()));
        }
      }
    }
    return out;
  }
}

/// 柱状图数据 (round-7 修补): 共享 X 轴 label 列表 + 多组 series 值。
///
/// 入口契约 (与 docs/contracts/agent-bus-client-contract.md §3.0a 同源):
///   - **单 series** (legacy): block.data = `[{label,value}, ...]` → 1 个匿名 series
///   - **多 series**: block.series = `[{name, data: [{label,value}, ...]}, ...]`
///     共享 label 顺序 = 第一个 series 的 label 顺序, 后续 series 按 label 对齐;
///     missing label 的值视为 `null` (柱状图不画)。
///
/// 渲染时:
///   - 单 series → 每个 label 一根柱子
///   - 多 series → 每个 label 一组并排柱子, 每个 series 一种颜色 + 顶部图例
///
/// fail-soft: malformed series / data 静默跳过, 不抛。
class _BarSeries {
  const _BarSeries({required this.labels, required this.seriesList});

  /// X 轴 label 顺序。
  final List<String> labels;

  /// 每个 series 一项; `name` 可能是空字符串 (单 series 匿名时)。
  /// `values.length == labels.length`; 没数据的 label 位置 = `null`。
  final List<_BarSeriesData> seriesList;

  static _BarSeries empty() => const _BarSeries(labels: [], seriesList: []);

  /// 从单 series `_BarEntry` 列表构造 (单 series fallback)。
  factory _BarSeries.singleFromEntries(List<_BarEntry> entries) {
    if (entries.isEmpty) return _BarSeries.empty();
    return _BarSeries(
      labels: [for (final e in entries) e.label],
      seriesList: [
        _BarSeriesData(name: '', values: [for (final e in entries) e.value]),
      ],
    );
  }

  /// 从原始 block dict 抽。优先 `block.series`; 失败 / 缺失时 fall back 单 series。
  factory _BarSeries.extract(Map<String, dynamic> block) {
    final rawSeries = _asList(block['series']);
    if (rawSeries == null || rawSeries.isEmpty) {
      return _BarSeries.empty(); // 调用方判断后再 fallback 走 `data`
    }
    final allEntries = <List<_BarEntry>>[];
    final names = <String>[];
    for (final s in rawSeries) {
      final sm = _asMap(s);
      if (sm == null) continue;
      final entries = _BarEntry.extract(_asList(sm['data']));
      if (entries.isEmpty) continue;
      allEntries.add(entries);
      names.add(_asString(sm['name']));
    }
    if (allEntries.isEmpty) return _BarSeries.empty();
    // labels 按首个非空 series 的顺序; 后续 series 按 label 对齐, 缺失 = null。
    final labels = [for (final e in allEntries.first) e.label];
    final seriesList = <_BarSeriesData>[];
    for (var i = 0; i < allEntries.length; i++) {
      final byLabel = <String, double>{};
      for (final e in allEntries[i]) {
        byLabel[e.label] = e.value;
      }
      final values = <double?>[for (final l in labels) byLabel[l]];
      seriesList.add(_BarSeriesData(name: names[i], values: values));
    }
    return _BarSeries(labels: labels, seriesList: seriesList);
  }

  bool get isMulti => seriesList.length >= 2;

  double get maxValue => _maxValue(
        seriesList.expand((s) => s.values)
      );
}

class _BarSeriesData {
  const _BarSeriesData({required this.name, required this.values});
  final String name;
  final List<double?> values;
}

const List<Color> _chartPalette = [
  Color(0xFF2563EB),
  Color(0xFF10B981),
  Color(0xFFF59E0B),
  Color(0xFFEF4444),
  Color(0xFF8B5CF6),
  Color(0xFF06B6D4),
  Color(0xFF14B8A6),
  Color(0xFFEC4899),
];

double _maxValue(Iterable<double?> values) {
  var max = 0.0;
  for (final v in values) {
    if (v != null && v > max) max = v;
  }
  return max <= 0 ? 1 : max;
}

double _minValue(Iterable<double> values) {
  var seen = false;
  var min = 0.0;
  for (final v in values) {
    if (!seen || v < min) {
      min = v;
      seen = true;
    }
  }
  return seen ? min : 0;
}

double _niceMax(double value) {
  if (value <= 0) return 1;
  return value * 1.18;
}

String _formatChartNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

String _shortAxisNum(double v) {
  final abs = v.abs();
  if (abs >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
  if (abs >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
  return _formatChartNum(v);
}

Widget _bottomTitle(List<String> labels, double value, fl.TitleMeta meta,
    {int skip = 1}) {
  final index = value.round();
  if (index < 0 || index >= labels.length || (value - index).abs() > 0.01) {
    return const SizedBox.shrink();
  }
  // round-9: skip 启发 (labels 太多时只画每 N 个), 防止 x 轴标签挤在一起。
  if (skip > 1 && index % skip != 0 && index != labels.length - 1) {
    return const SizedBox.shrink();
  }
  return fl.SideTitleWidget(
    meta: meta,
    space: 6,
    child: SizedBox(
      // 单 label 横向宽度上限, 长文本走 ellipsis 不堆叠。
      width: 60,
      child: Text(
        labels[index],
        maxLines: 1,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
      ),
    ),
  );
}

/// round-9: 接受可选 unit; 非空时 y 轴 left title 末尾追加单位 (短于 3 chars 才接)。
/// 也加 `skipFactor` 启发式 — labels 太多时跳着画, 避免挤在一起。
fl.FlTitlesData _cartesianTitles(List<String> labels, {String unit = ''}) {
  // labels.length > 8 → 每 2 个画一个; > 16 → 每 3 个; 兜底防挤压。
  final n = labels.length;
  final skip = n > 16 ? 3 : (n > 8 ? 2 : 1);
  return fl.FlTitlesData(
    topTitles: const fl.AxisTitles(),
    rightTitles: const fl.AxisTitles(),
    bottomTitles: fl.AxisTitles(
      sideTitles: fl.SideTitles(
        showTitles: true,
        interval: 1,
        reservedSize: 30,
        getTitlesWidget: (value, meta) =>
            _bottomTitle(labels, value, meta, skip: skip),
      ),
    ),
    leftTitles: fl.AxisTitles(
      sideTitles: fl.SideTitles(
        showTitles: true,
        reservedSize: 48,
        getTitlesWidget: (v, meta) => _leftTitleWithUnit(v, meta, unit),
      ),
    ),
  );
}

Widget _leftTitleWithUnit(double value, fl.TitleMeta meta, String unit) {
  return fl.SideTitleWidget(
    meta: meta,
    space: 4,
    child: Text(
      // 单位短 (例 "%", "万", "DAU") 才直接拼; 长单位放 footer, 不挤 axis。
      unit.isNotEmpty && unit.length <= 3
          ? '${_shortAxisNum(value)}$unit'
          : _shortAxisNum(value),
      style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
    ),
  );
}

/// round-9: legend chip 的文案 — 多 series 用 name; 单 series 没 name 时退化"数据" / unit。
String _legendLabel(String name, int idx,
    {required bool singleSeries, required String unit}) {
  if (name.isNotEmpty) return name;
  if (singleSeries) {
    return unit.isNotEmpty ? '数据 ($unit)' : '数据';
  }
  return 'series ${idx + 1}';
}

/// 响应式 chart 面板 (round-9 重构): 高度按可用宽度推导, 不再写死 220。
///
/// 计算: `height = (width / aspectRatio).clamp(minHeight, maxHeight)`.
///   - bar / line / area / scatter: aspectRatio=16/9, 200~340 之间 → 小屏窄一些, 大屏不拉得很矮
///   - pie / donut: aspectRatio=1.8 (legend 在右侧, 整块横向略扁), 200~260
///   - radar: aspectRatio=1.2 (近正方更协调), 220~320
///   - kpi: 不进 _ChartPanel
///
/// 参与"小屏不溢出"的关键: `LayoutBuilder.constraints.maxWidth.isFinite` 兜底,
/// 上层若给了无界宽度 (例 SingleChildScrollView 不应该), 退化到 320 默认宽。
class _ChartPanel extends StatelessWidget {
  const _ChartPanel({
    required this.child,
    this.aspectRatio = 16 / 9,
    this.minHeight = 200,
    this.maxHeight = 340,
  });

  final Widget child;
  final double aspectRatio;
  final double minHeight;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final width =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
      final raw = width / aspectRatio;
      final height = raw.clamp(minHeight, maxHeight);
      return Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFFFF), Color(0xFFF1F7FF)],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDCE7F8)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      );
    });
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.series, this.unit = ''});
  final _BarSeries series;

  /// y 轴数值单位 (例: "万元" / "DAU" / "%"). 空时不显示。
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (series.labels.isEmpty || series.seriesList.isEmpty) {
      return const Text('（柱状图数据为空）',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // round-9: 单 series 也显示 legend, 避免"一根孤独的柱子"没有说明。
        // 单 series 时 series name 可能为空 → 用 "数据" 兜底, 优先让 unit 出现在 chip 上。
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (var i = 0; i < series.seriesList.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _chartPalette[i % _chartPalette.length],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _legendLabel(series.seriesList[i].name, i,
                          singleSeries: !series.isMulti, unit: unit),
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF374151)),
                    ),
                  ],
                ),
            ],
          ),
        ),
        _ChartPanel(
          child: fl.BarChart(
            fl.BarChartData(
              minY: 0,
              maxY: _niceMax(series.maxValue),
              groupsSpace: series.isMulti ? 18 : 22,
              alignment: fl.BarChartAlignment.spaceAround,
              gridData: fl.FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => const fl.FlLine(
                  color: Color(0xFFE2E8F0),
                  strokeWidth: 1
                ),
              ),
              borderData: fl.FlBorderData(show: false),
              titlesData: _cartesianTitles(series.labels, unit: unit),
              barTouchData: fl.BarTouchData(
                touchTooltipData: fl.BarTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipColor: (_) => const Color(0xFF0F172A),
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    final seriesName = series.isMulti
                        ? series.seriesList[rodIndex].name
                        : series.labels[group.x];
                    return fl.BarTooltipItem(
                      '${seriesName.isEmpty ? series.labels[group.x] : seriesName}\n${_formatChartNum(rod.toY)}',
                      const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ),
              ),
              barGroups: [
                for (var li = 0; li < series.labels.length; li++)
                  fl.BarChartGroupData(
                    x: li,
                    barsSpace: 4,
                    barRods: [
                      for (var si = 0; si < series.seriesList.length; si++)
                        if (series.seriesList[si].values[li] != null)
                          fl.BarChartRodData(
                            toY: series.seriesList[si].values[li]!,
                            width: series.isMulti ? 9 : 18,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                _chartPalette[si % _chartPalette.length],
                                _chartPalette[si % _chartPalette.length]
                                    .withValues(alpha: 0.72),
                              ],
                            ),
                          ),
                    ],
                  ),
              ],
            ),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          ),
        ),
      ],
    );
  }
}

class _LineChart extends StatelessWidget {
  const _LineChart({
    required this.entries,
    required this.fillArea,
    this.unit = '',
  });
  final List<_BarEntry> entries;
  final bool fillArea;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final values = [for (final e in entries) e.value];
    final minY = _minValue(values);
    final maxY = _niceMax(_maxValue(values));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // round-9: 单 series 也显示 legend chip (颜色 + 单位), 与 bar 保持一致。
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _chartPalette.first,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _legendLabel('', 0, singleSeries: true, unit: unit),
                style: const TextStyle(fontSize: 11, color: Color(0xFF374151)),
              ),
            ],
          ),
        ),
        _ChartPanel(
          child: fl.LineChart(
            fl.LineChartData(
              minX: 0,
              maxX: entries.length <= 1 ? 1 : (entries.length - 1).toDouble(),
              minY: minY > 0 ? 0 : minY,
              maxY: maxY,
              gridData: fl.FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => const fl.FlLine(
                  color: Color(0xFFE2E8F0),
                  strokeWidth: 1
                ),
              ),
              borderData: fl.FlBorderData(show: false),
              titlesData: _cartesianTitles([for (final e in entries) e.label],
                  unit: unit),
              lineTouchData: fl.LineTouchData(
                touchTooltipData: fl.LineTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipColor: (_) => const Color(0xFF0F172A),
                ),
              ),
              lineBarsData: [
                fl.LineChartBarData(
                  spots: [
                    for (var i = 0; i < entries.length; i++)
                      fl.FlSpot(i.toDouble(), entries[i].value),
                  ],
                  isCurved: true,
                  curveSmoothness: 0.28,
                  preventCurveOverShooting: true,
                  barWidth: 3,
                  isStrokeCapRound: true,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2563EB), Color(0xFF06B6D4)],
                  ),
                  dotData: fl.FlDotData(
                    getDotPainter: (spot, percent, bar, index) =>
                        fl.FlDotCirclePainter(
                      radius: 3,
                      color: Colors.white,
                      strokeWidth: 2,
                      strokeColor: const Color(0xFF2563EB),
                    ),
                  ),
                  belowBarData: fl.BarAreaData(
                    show: fillArea,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF2563EB).withValues(alpha: 0.24),
                        const Color(0xFF2563EB).withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          ),
        ),
      ],
    );
  }
}

class _PieChart extends StatelessWidget {
  const _PieChart({required this.entries, required this.isDonut});
  final List<_BarEntry> entries;
  final bool isDonut;

  @override
  Widget build(BuildContext context) {
    final total = entries.fold<double>(0, (a, e) => a + e.value);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 150,
          height: 150,
          child: fl.PieChart(
            fl.PieChartData(
              sectionsSpace: 3,
              centerSpaceRadius: isDonut ? 42 : 0,
              startDegreeOffset: -90,
              pieTouchData: fl.PieTouchData(enabled: true),
              sections: [
                for (var i = 0; i < entries.length; i++)
                  fl.PieChartSectionData(
                    value: entries[i].value,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _chartPalette[i % _chartPalette.length],
                        _chartPalette[i % _chartPalette.length]
                            .withValues(alpha: 0.72),
                      ],
                    ),
                    radius: isDonut ? 30 : 54,
                    title: total > 0 && entries[i].value / total >= 0.08
                        ? '${(entries[i].value / total * 100).round()}%'
                        : '',
                    titleStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                    cornerRadius: 5,
                  ),
              ],
            ),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < entries.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _chartPalette[i % _chartPalette.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entries[i].label,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF374151)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        total > 0
                            ? '${(entries[i].value / total * 100).toStringAsFixed(1)}%'
                            : '-',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF111827)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScatterChart extends StatelessWidget {
  const _ScatterChart({required this.entries, this.unit = ''});
  final List<_BarEntry> entries;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final labels = [for (final e in entries) e.label];
    final maxY = _niceMax(_maxValue(entries.map((e) => e.value)));
    return _ChartPanel(
      child: fl.ScatterChart(
        fl.ScatterChartData(
          minX: 0,
          maxX: entries.length <= 1 ? 1 : (entries.length - 1).toDouble(),
          minY: 0,
          maxY: maxY,
          gridData: fl.FlGridData(
            show: true,
            drawVerticalLine: true,
            getDrawingHorizontalLine: (_) => const fl.FlLine(
              color: Color(0xFFE2E8F0),
              strokeWidth: 1
            ),
            getDrawingVerticalLine: (_) => const fl.FlLine(
              color: Color(0xFFEFF6FF),
              strokeWidth: 1
            ),
          ),
          borderData: fl.FlBorderData(show: false),
          titlesData: _cartesianTitles(labels, unit: unit),
          scatterSpots: [
            for (var i = 0; i < entries.length; i++)
              fl.ScatterSpot(
                i.toDouble(),
                entries[i].value,
                dotPainter: fl.FlDotCirclePainter(
                  radius: 6,
                  color: _chartPalette[i % _chartPalette.length],
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                ),
              ),
          ],
        ),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      ),
    );
  }
}

class _RadarChart extends StatelessWidget {
  const _RadarChart({required this.entries});
  final List<_BarEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.length < 3) {
      return const Text('（雷达图至少需要 3 个维度）',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)));
    }
    final max = _maxValue(entries.map((e) => e.value));
    final normalized = [
      for (final e in entries) fl.RadarEntry(value: e.value / max * 100),
    ];
    return _ChartPanel(
      // round-9: 雷达近正方形最舒展; 220~320 clamp。
      aspectRatio: 1.2,
      minHeight: 220,
      maxHeight: 320,
      child: fl.RadarChart(
        fl.RadarChartData(
          radarShape: fl.RadarShape.polygon,
          tickCount: 4,
          titlePositionPercentageOffset: 0.22,
          titleTextStyle:
              const TextStyle(fontSize: 10, color: Color(0xFF475569)),
          ticksTextStyle:
              const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
          gridBorderData: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          tickBorderData: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          radarBorderData: const BorderSide(color: Color(0xFFCBD5E1), width: 1),
          getTitle: (index, angle) => fl.RadarChartTitle(
            text: index >= 0 && index < entries.length
                ? entries[index].label
                : '',
            angle: 0,
          ),
          dataSets: [
            fl.RadarDataSet(
              dataEntries: normalized,
              borderColor: const Color(0xFF2563EB),
              borderWidth: 2,
              fillColor: const Color(0xFF2563EB).withValues(alpha: 0.20),
              entryRadius: 3,
            ),
          ],
        ),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      ),
    );
  }
}

/// round-9 富 fallback 卡:
///   - 自带 `_BlockCard` 外壳 + 标题 + summary (markdown) + 原始数据 5x4 预览
///   - 用于 4 种情形:
///       1. unknown chart_kind (mixed / heatmap / sankey / candlestick / map / 自造)
///       2. data 字段空但 known kind
///       3. data 字段 malformed (运行时 catch 后退化)
///       4. chart 渲染抛异常 (顶层 try/catch 后)
///   - 永远显示 title + summary, 让用户至少读到 Agent 的结论;
///   - 有原始数据时给出最多 5 行 × 4 列预览 (轻量自绘 table, 不引 DataTable 重布局)。
class _UnsupportedChart extends StatelessWidget {
  const _UnsupportedChart({
    required this.kind,
    required this.title,
    required this.summary,
    required this.insights,
    required this.entries,
    required this.tableHeaders,
    required this.tableRows,
    required this.reason,
  });

  final String kind;
  final String title;
  final String summary;
  final List<String> insights;
  final List<_BarEntry> entries;
  final List<String> tableHeaders;
  final List<List<String>> tableRows;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final friendlyKind = kind.isNotEmpty ? kind : '未声明';
    // 优先使用 block.table; 否则 fallback 用 entries 推断的"label/value" 两列。
    List<String> headers;
    List<List<String>> rows;
    if (tableRows.isNotEmpty) {
      headers = tableHeaders;
      rows = tableRows;
    } else if (entries.isNotEmpty) {
      headers = const ['label', 'value'];
      rows = [
        for (final e in entries) [e.label, _formatChartNum(e.value)],
      ];
    } else {
      headers = const [];
      rows = const [];
    }

    return _BlockCard(
      title: _ChartBlockView._composeCardTitle(title, kind),
      titleIcon: _ChartBlockView._iconForChartKind(kind),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FallbackBanner(
            reason: reason,
            kindLabel: friendlyKind
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            ChatSelectableSurface(
              child: ChatMarkdownWidget(
                  content: summary, compact: true, selectable: false),
            ),
          ],
          if (insights.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InsightChips(insights: insights),
          ],
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            _DataPreviewTable(
              headers: headers,
              rows: rows,
              maxRows: 5,
              maxCols: 4,
            ),
          ],
        ],
      ),
    );
  }
}

/// fallback 卡顶部 banner — 用面向用户的语义文案 (不暴露 Dart 异常)。
class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner({required this.reason, required this.kindLabel});
  final String reason;
  final String kindLabel;

  @override
  Widget build(BuildContext context) {
    final isCapabilityFallback = reason == '暂不支持的图表类型';
    final backgroundColor = isCapabilityFallback
        ? const Color(0xFFEFF6FF)
        : const Color(0xFFFFFBEB);
    final borderColor = isCapabilityFallback
        ? const Color(0xFFBFDBFE)
        : const Color(0xFFFCD34D);
    final foregroundColor = isCapabilityFallback
        ? const Color(0xFF1D4ED8)
        : const Color(0xFF92400E);
    final iconColor = isCapabilityFallback
        ? const Color(0xFF2563EB)
        : const Color(0xFFB45309);
    final message = isCapabilityFallback
        ? '复杂图表已按可读数据预览展示 (chart_kind=$kindLabel)'
        : '$reason · 已退化为可读视图 (chart_kind=$kindLabel)';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: foregroundColor,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 轻量自绘 5x4 数据预览表 (round-9).
/// 选用 DataTable 之外的纯 Container 方案: 更可控的列宽 / 行高, 不依赖 InheritedWidget,
/// 也不在 chat 气泡内引 horizontal scroll (列截断 + ellipsis 即可)。
class _DataPreviewTable extends StatelessWidget {
  const _DataPreviewTable({
    required this.headers,
    required this.rows,
    this.maxRows = 5,
    this.maxCols = 4,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final int maxRows;
  final int maxCols;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final shownRows = rows.take(maxRows).toList();
    final colCount = headers.isNotEmpty
        ? headers.length
        : (rows.first.isEmpty ? 0 : rows.first.length);
    final shownCols = colCount > maxCols ? maxCols : colCount;
    if (shownCols == 0) return const SizedBox.shrink();
    final hiddenRows = rows.length > shownRows.length;
    final hiddenCols = colCount > shownCols;
    final shownHeaders = headers.isNotEmpty
        ? headers.take(shownCols).toList()
        : List<String>.generate(shownCols, (i) => '列 ${i + 1}');

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _previewHeaderRow(shownHeaders),
          for (final r in shownRows) _previewBodyRow(r, shownCols),
          if (hiddenRows || hiddenCols)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                [
                  if (hiddenRows) '另有 ${rows.length - shownRows.length} 行未展示',
                  if (hiddenCols) '另有 ${colCount - shownCols} 列未展示',
                ].join(' · '),
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _previewHeaderRow(List<String> shownHeaders) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFEFF6FF),
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB))
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          for (final h in shownHeaders)
            Expanded(
              child: Text(
                h,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1D4ED8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _previewBodyRow(List<String> r, int shownCols) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < shownCols; i++)
            Expanded(
              child: Text(
                i < r.length ? r[i] : '—',
                style: const TextStyle(fontSize: 11, color: Color(0xFF374151)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

/// KPI 卡 — 把第一个 entry 当主指标; 剩余 entries 当对比 / 趋势小数字。
class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.entries, this.unit = ''});
  final List<_BarEntry> entries;
  final String unit;
  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final main = entries.first;
    final secondaries = entries.length > 1 ? entries.sublist(1) : <_BarEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              _formatChartNum(main.value),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
            // round-9: 主指标后追加单位 (例 "万元" / "%"), 不挤标题。
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                unit,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                main.label,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (secondaries.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final s in secondaries)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.label,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF9CA3AF)),
                    ),
                    Text(
                      _formatChartNum(s.value),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 通用媒体卡 — image / video / audio / file 用一套外观。
///
/// - image 且有 url / preview_url → 带鉴权缩略图 + 点击大图预览
/// - file → 文件类型图标 + 文件名 + size + mime + 预览/下载入口
class _MediaBlockView extends StatelessWidget {
  const _MediaBlockView(
      {required this.block, required this.kind, this.conversation = ''});
  final String conversation;
  final Map<String, dynamic> block;
  final String kind;

  @override
  Widget build(BuildContext context) => card();

  ChatArtifactCard card() {
    final name = _firstNonEmpty([
      _asString(block['name']),
      _asString(block['title']),
      _asString(block['filename']),
      _asString(block['file_name']),
      _asString(block['fileName']),
    ]);
    final local = LocalArtifactSource.fromBlock(block, conversation);
    // Stored object-storage signatures expire; a Bus file ID is the durable
    // identity. Keep local snapshot reads ahead of this cloud-only fallback.
    final fileId = _asString(block['file_id']).trim();
    final cloudFile = local == null &&
            RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                .hasMatch(fileId)
        ? '/api/agent-bus/v1/drive/files/$fileId'
        : '';
    final declaredPreviewUrl = _firstNonEmpty([
      local?.url ?? '',
      if (cloudFile.isNotEmpty) '$cloudFile/preview',
      _asString(block['preview_url']),
      _asString(block['previewUrl']),
      _asString(block['thumbnail_url']),
      _asString(block['thumbnailUrl']),
    ]);
    final downloadUrl = _firstNonEmpty([
      local?.url ?? '',
      if (cloudFile.isNotEmpty) '$cloudFile/download',
      _asString(block['download_url']),
      _asString(block['downloadUrl']),
      _asString(block['url']),
      _asString(block['src']),
      declaredPreviewUrl,
    ]);
    final previewUrl = declaredPreviewUrl.isNotEmpty
        ? declaredPreviewUrl
        : _deriveAttachmentPreviewUrl(downloadUrl);
    final mime = _firstNonEmpty([
      _asString(block['mime_type']),
      _asString(block['mimeType']),
      _asString(block['mime']),
    ]);
    final summary = _asString(block['summary']);
    final size = block['size'];
    final sizeText = size is num ? _humanSize(size.toInt()) : '';

    final mediaPreviewUrl = kind == 'video' ? downloadUrl : previewUrl;
    return ChatArtifactCard(
      key: ValueKey('artifact:${local?.url ?? mediaPreviewUrl}:$name'),
      target: AttachmentPreviewTarget(
          url: apiImageNeedsAuth(mediaPreviewUrl)
              ? mediaPreviewUrl
              : _resolveEmpMediaUrl(mediaPreviewUrl),
          name: name,
          mime: mime,
          downloadUrl: apiImageNeedsAuth(downloadUrl)
              ? downloadUrl
              : _resolveEmpMediaUrl(downloadUrl)),
      source: local,
      sizeText: sizeText,
      summary: summary,
      kind: kind,
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

String _resolveEmpMediaUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.startsWith('oss://')) return '';
  if (apiImageNeedsAuth(value)) return apiImageResolveUrl(value);
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) return value;
  if (value.startsWith('/')) {
    final base = Uri.parse(AppConfig.apiUrl());
    return '${base.origin}$value';
  }
  return value;
}

/// Round-8: audio block 真播放器, 复用项目已有 audioplayers 依赖。
///
/// 设计:
/// - 没有 URL → 退化 file-card。
/// - 有 URL → 显示一行: ▶️ / ⏸ 按钮 + 进度条 + 当前/总时长。
/// - 不自动播放; 错误 (platform channel 缺失 / URL 不可达) 时静默退化 file-card。
class _AudioPlayerView extends StatefulWidget {
  const _AudioPlayerView({required this.block});
  final Map<String, dynamic> block;

  @override
  State<_AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends State<_AudioPlayerView> {
  AudioPlayer? _player;
  bool _failed = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;

  String get _url => _firstNonEmpty([
        _asString(widget.block['url']),
        _asString(widget.block['src']),
      ]);

  @override
  void initState() {
    super.initState();
    if (_url.isEmpty) {
      _failed = true;
      return;
    }
    try {
      final p = AudioPlayer();
      _player = p;
      _posSub = p.onPositionChanged.listen((d) {
        if (mounted) setState(() => _position = d);
      });
      _durSub = p.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _stateSub = p.onPlayerStateChanged.listen((s) {
        if (mounted) {
          setState(() => _playing = s == PlayerState.playing);
        }
      });
    } catch (_) {
      _failed = true;
      _player = null;
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    try {
      if (_playing) {
        await p.pause();
      } else {
        await p.play(UrlSource(_url));
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return _MediaBlockView(block: widget.block, kind: 'audio');
    }
    final name = _firstNonEmpty([
      _asString(widget.block['name']),
      _asString(widget.block['title']),
      _asString(widget.block['filename']),
    ]);
    final pos = _position.inMilliseconds.toDouble();
    final dur = _duration.inMilliseconds.toDouble();
    final progressMax = dur > 0 ? dur : 1.0;
    return _BlockCard(
      title: name.isNotEmpty ? '音频 · $name' : '音频',
      titleIcon: Icons.audiotrack_outlined,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            IconButton(
              iconSize: 36,
              icon: Icon(
                _playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill_rounded,
                color: const Color(0xFF2563EB),
              ),
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _togglePlay,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: pos.clamp(0, progressMax),
                    min: 0,
                    max: progressMax,
                    activeColor: const Color(0xFF2563EB),
                    onChanged: dur > 0
                        ? (v) {
                            final p = _player;
                            if (p == null) return;
                            p.seek(Duration(milliseconds: v.toInt()));
                          }
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(_position),
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF6B7280))),
                        Text(_fmt(_duration),
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF6B7280))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TableBlockView extends StatelessWidget {
  const _TableBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final title = _asString(block['title']);
    final headers = _asList(block['headers']) ?? _asList(block['columns']);
    final rows = _asList(block['rows']);
    final rowMaps = <List<String>>[];
    if (rows != null) {
      for (final r in rows) {
        if (r is List) {
          rowMaps.add(r.map(_asString).toList());
        } else if (r is Map) {
          final hdrs = headers ?? r.keys.toList();
          rowMaps.add(hdrs.map((h) => _asString(r[h])).toList());
        }
      }
    }
    final cols = headers?.map(_asString).toList() ??
        (rowMaps.isNotEmpty
            ? List<String>.generate(rowMaps.first.length, (i) => 'col${i + 1}')
            : const <String>[]);

    return _BlockCard(
      title: title.isNotEmpty ? title : '表格 · ${rowMaps.length} 行',
      titleIcon: Icons.table_chart_outlined,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              columnSpacing: 18,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 36,
              headingRowHeight: 32,
              columns: [
                for (final c in cols)
                  DataColumn(
                    label: Text(c,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF374151))),
                  ),
              ],
              rows: [
                for (final r in rowMaps)
                  DataRow(
                    cells: [
                      for (var i = 0; i < cols.length; i++)
                        DataCell(Text(
                          i < r.length ? r[i] : '',
                          style: const TextStyle(fontSize: 12),
                        )),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FormBlockView extends StatefulWidget {
  const _FormBlockView({
    required this.block,
    required this.interactive,
    required this.agentMessageUuid,
    required this.approvalRequestId,
    required this.onSubmit,
    required this.onA2ASubmit,
    this.onFile,
  });
  final Map<String, dynamic> block;
  final bool interactive;
  final String agentMessageUuid;
  final String approvalRequestId;
  final Future<bool> Function({
    required String agentMessageUuid,
    required Map<String, dynamic> fields,
  })? onSubmit;
  final Future<bool> Function({
    required String approvalRequestId,
    required Map<String, dynamic> fields,
  })? onA2ASubmit;
  final Future<Map<String, dynamic>?> Function({
    required String fieldName,
    required String fieldLabel,
  })? onFile;
  @override
  State<_FormBlockView> createState() => _FormBlockViewState();
}

class _FormBlockViewState extends State<_FormBlockView> {
  /// 字段值缓存; key = field name (fallback `name`/`id`/`label`)。
  final Map<String, dynamic> _values = <String, dynamic>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // 契约 §3.0a: 字段可选 `value` = 服务端回填的初始值 (草稿续填/「再改改」
    // 整卡修改场景, 用户在已填内容上改而不是从空白重填)。只 seed 一次,
    // 之后以用户输入为准。
    final fields = _effectiveFields();
    for (var i = 0; i < fields.length; i++) {
      final f = _asMap(fields[i]);
      if (f == null) continue;
      final v = f['value'];
      if (v == null) continue;
      _values.putIfAbsent(_fieldKey(f, i), () => v);
    }
  }

  String _fieldKey(Map f, int i) {
    final raw = _firstNonEmpty([
      _asString(f['name']),
      _asString(f['id']),
      _asString(f['label']),
    ]);
    return raw.isEmpty ? 'field_$i' : raw;
  }

  /// 契约 §3.0a 字段 pattern (2026-07-20): text/textarea/number 的非空值做
  /// 全串匹配; 不匹配返回 "label：patternHint" 列表。空值只归 required 管;
  /// 非法正则 fail-soft 跳过 (回落服务端提交时校验, 不因坏 pattern 卡死表单)。
  List<String> _patternViolations(List<dynamic> fields, {int offset = 0}) {
    const patternTypes = {'text', 'textarea', 'number'};
    final errors = <String>[];
    for (var i = 0; i < fields.length; i++) {
      final f = _asMap(fields[i]);
      if (f == null) continue;
      final type = _asString(f['type']);
      if (!patternTypes.contains(type.isEmpty ? 'text' : type)) continue;
      final pattern = _asString(f['pattern']);
      if (pattern.isEmpty) continue;
      final v = _values[_fieldKey(f, offset + i)];
      final raw = v == null ? '' : v.toString().trim();
      if (raw.isEmpty || raw == formOtherSentinel) continue;
      final RegExp re;
      try {
        re = RegExp('^(?:$pattern)\$');
      } catch (_) {
        continue;
      }
      if (re.hasMatch(raw)) continue;
      final label = _firstNonEmpty([
        _asString(f['label']),
        _asString(f['name']),
        _fieldKey(f, offset + i)
      ]);
      final hint = _firstNonEmpty(
          [_asString(f['patternHint']), _asString(f['pattern_hint'])]);
      errors.add('$label：${hint.isEmpty ? '格式不正确，请检查后重新填写' : hint}');
    }
    return errors;
  }

  /// Plan 17 round-5: 必填校验 — 提交前列出"required:true 且当前值缺失"的字段名。
  /// 缺失定义按类型: 字符串空 / null / 空 list / 数字 null。bool 字段 (switch/checkbox)
  /// false 不算"缺失" (false 也是有效用户选择, 与 `必须勾确认` 类规则由 runtime 校验)。
  /// `offset` = 向导模式下该 fields 片段在全量拍平列表里的起始下标 (保持 key 稳定)。
  List<String> _missingRequiredFields(List<dynamic> fields, {int offset = 0}) {
    final missing = <String>[];
    for (var i = 0; i < fields.length; i++) {
      final f = _asMap(fields[i]);
      if (f == null) continue;
      if (f['required'] != true) continue;
      final key = _fieldKey(f, offset + i);
      final v = _values[key];
      // 选了「其他」但没输入自定义值（哨兵）= 未填。
      final empty = v == null ||
          (v is String && (v.isEmpty || v == formOtherSentinel)) ||
          (v is List && v.isEmpty);
      if (empty) {
        missing.add(_firstNonEmpty([
          _asString(f['label']),
          _asString(f['name']),
          key
        ]));
      }
    }
    return missing;
  }

  String _submitLabel() {
    final raw = _firstNonEmpty([
      _asString(widget.block['submit_label']),
      _asString(widget.block['submitLabel']),
    ]).trim();
    final label = raw.isEmpty ? '提交' : raw;
    const maxRunes = 14;
    final runes = label.runes.toList();
    if (runes.length <= maxRunes) return label;
    return '${String.fromCharCodes(runes.take(maxRunes))}…';
  }

  // ---- form 多步 (steps) 向导, 契约 §3.0a: steps 合法才向导渲染, 否则 fail-soft 退化单页 ----

  int _stepIndex = 0;

  List<Map>? _wizardSteps() {
    final raw = _asList(widget.block['steps']);
    if (raw == null || raw.isEmpty) return null;
    final steps = <Map>[];
    for (final s in raw) {
      final m = _asMap(s);
      if (m == null) return null;
      final fs = _asList(m['fields']);
      if (fs == null || fs.isEmpty) return null;
      steps.add(m);
    }
    return steps;
  }

  List<dynamic> _stepFields(Map step) => _asList(step['fields']) ?? const [];

  int _stepFieldOffset(List<Map> steps, int idx) {
    var off = 0;
    for (var i = 0; i < idx && i < steps.length; i++) {
      off += _stepFields(steps[i]).length;
    }
    return off;
  }

  /// steps 为准的全量字段 (提交/终校验用); 无 steps 时用顶层 fields。
  List<dynamic> _effectiveFields() {
    final steps = _wizardSteps();
    if (steps == null) return _asList(widget.block['fields']) ?? const [];
    return [for (final s in steps) ..._stepFields(s)];
  }

  void _handleNextStep(List<Map> steps) {
    if (_submitting || _stepIndex >= steps.length) return;
    // 未进入可交互态时允许翻页浏览 (字段本就 disabled), 不做必填/格式拦截。
    if (widget.interactive) {
      final stepFields = _stepFields(steps[_stepIndex]);
      final offset = _stepFieldOffset(steps, _stepIndex);
      final missing = _missingRequiredFields(stepFields, offset: offset);
      if (missing.isNotEmpty) {
        setState(() {
          _missingRequired = missing;
          _patternErrors = const [];
        });
        return;
      }
      // 契约 §3.0a: pattern 与 required 同一闸, 步内即时拦截格式错
      final violations = _patternViolations(stepFields, offset: offset);
      if (violations.isNotEmpty) {
        setState(() {
          _missingRequired = const [];
          _patternErrors = violations;
        });
        return;
      }
    }
    setState(() {
      _missingRequired = const [];
      _patternErrors = const [];
      if (_stepIndex < steps.length - 1) _stepIndex++;
    });
  }

  void _handlePrevStep() {
    if (_submitting || _stepIndex == 0) return;
    setState(() {
      _missingRequired = const [];
      _patternErrors = const [];
      _stepIndex--;
    });
  }

  Future<void> _handleSubmit() async {
    final isA2A = widget.approvalRequestId.isNotEmpty;
    if (!widget.interactive || _submitting) return;
    if (isA2A && widget.onA2ASubmit == null) return;
    if (!isA2A && widget.onSubmit == null) return;
    final fields = _effectiveFields();
    final missing = _missingRequiredFields(fields);
    if (missing.isNotEmpty) {
      // 行内轻量提示 (不引 BotToast 依赖, 由 _missingRequired 渲染列出)
      setState(() {
        _missingRequired = missing;
        _patternErrors = const [];
      });
      return;
    }
    final violations = _patternViolations(fields);
    if (violations.isNotEmpty) {
      setState(() {
        _missingRequired = const [];
        _patternErrors = violations;
      });
      return;
    }
    setState(() {
      _missingRequired = const [];
      _patternErrors = const [];
      _submitting = true;
    });
    try {
      // 剔掉 allowCustom 选了「其他」但没输入的哨兵值（required 已拦必填项，
      // 这里兜非必填的自定义字段，避免哨兵混进 payload）。
      final values = <String, dynamic>{
        for (final e in _values.entries)
          if (e.value != formOtherSentinel) e.key: e.value,
      };
      final ok = isA2A
          ? await widget.onA2ASubmit!(
              approvalRequestId: widget.approvalRequestId,
              fields: values,
            )
          : await widget.onSubmit!(
              agentMessageUuid: widget.agentMessageUuid,
              fields: values,
            );
      // success → 保持 disabled (等新 SSE 终态收口); 失败 → 解锁让用户重试。
      if (mounted && !ok) {
        setState(() => _submitting = false);
      }
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  List<String> _missingRequired = const [];
  List<String> _patternErrors = const [];

  /// 字段渲染行 (单页与向导共用); `offset` 保证向导模式 key 与拍平列表对齐。
  List<Widget> _fieldRows(List<dynamic> fields, {int offset = 0}) {
    final enabled = widget.interactive && !_submitting;
    return [
      for (var i = 0; i < fields.length; i++)
        if (_asMap(fields[i]) != null)
          _FormFieldRow(
            // 向导切步时同位置会换成另一个逻辑字段——不带 key 的话 Flutter 复用
            // TextField 状态，上一步的输入会残留显示在新字段里（golden 实锤）。
            key: ValueKey(
                'form-field-${_fieldKey(fields[i] as Map, offset + i)}'),
            field: fields[i] as Map,
            enabled: enabled,
            currentValue: _values[_fieldKey(fields[i] as Map, offset + i)],
            onChanged: (v) {
              setState(() {
                _values[_fieldKey(fields[i] as Map, offset + i)] = v;
                if (_missingRequired.isNotEmpty || _patternErrors.isNotEmpty) {
                  // 用户开始改, 清掉旧错误提示, 避免视觉死盯
                  _missingRequired = const [];
                  _patternErrors = const [];
                }
              });
            },
            onUploadFile: widget.onFile,
          ),
    ];
  }

  Widget _missingRequiredNote() => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          '请先填写必填字段: ${_missingRequired.join('、')}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFB91C1C)
          ),
        ),
      );

  Widget _patternErrorNote() => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          _patternErrors.join('\n'),
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFB91C1C)
          ),
        ),
      );

  Widget _notInteractiveNote() => const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          '当前客户端版本暂不支持填写此表单，请升级后重试',
          style: TextStyle(
            fontSize: 12,
            color: Color(0xFF6B7280)
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final title = _asString(widget.block['title']);
    final desc = _asString(widget.block['description']);
    final enabled = widget.interactive && !_submitting;
    final steps = _wizardSteps();
    final submitLabel = _submitLabel();

    if (steps != null) {
      // ---- 多步向导 (契约 §3.0a form 多步): 分步渲染, 最后一步统一提交 ----
      final stepIdx =
          _stepIndex >= steps.length ? steps.length - 1 : _stepIndex;
      final step = steps[stepIdx];
      final stepTitle = _asString(step['title']);
      final stepDesc = _asString(step['description']);
      final isLast = stepIdx == steps.length - 1;
      return _BlockCard(
        title: title.isNotEmpty ? '表单 · $title' : '表单',
        titleIcon: Icons.description_outlined,
        titleColor: const Color(0xFF7C3AED),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '第 ${stepIdx + 1}/${steps.length} 步'
                '${stepTitle.isNotEmpty ? ' · $stepTitle' : ''}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7C3AED),
                ),
              ),
            ),
            if (stepDesc.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(stepDesc,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF374151))),
              ),
            ..._fieldRows(_stepFields(step),
                offset: _stepFieldOffset(steps, stepIdx)),
            if (_missingRequired.isNotEmpty) _missingRequiredNote(),
            if (_patternErrors.isNotEmpty) _patternErrorNote(),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  if (stepIdx > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _submitting ? null : _handlePrevStep,
                        child: const Text('上一步'),
                      ),
                    ),
                  if (stepIdx > 0) const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: isLast
                          ? (enabled ? _handleSubmit : null)
                          : (_submitting ? null : () => _handleNextStep(steps)),
                      style: ElevatedButton.styleFrom(
                        disabledBackgroundColor: const Color(0xFFE5E7EB),
                        disabledForegroundColor: const Color(0xFF6B7280),
                      ),
                      child: Text(
                        isLast ? (_submitting ? '提交中…' : submitLabel) : '下一步',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.interactive && !_submitting && widget.onSubmit == null)
              _notInteractiveNote(),
          ],
        ),
      );
    }

    final fields = _asList(widget.block['fields']) ?? const [];
    return _BlockCard(
      title: title.isNotEmpty ? '表单 · $title' : '表单',
      titleIcon: Icons.description_outlined,
      titleColor: const Color(0xFF7C3AED),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(desc,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF374151))),
            ),
          ..._fieldRows(fields),
          if (_missingRequired.isNotEmpty) _missingRequiredNote(),
          if (_patternErrors.isNotEmpty) _patternErrorNote(),
          // 提交按钮文案由 runtime 定义, 客户端兜底为"提交"; 是否可点由 HITL 状态守卫决定。
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: enabled ? _handleSubmit : null,
                style: ElevatedButton.styleFrom(
                  disabledBackgroundColor: const Color(0xFFE5E7EB),
                  disabledForegroundColor: const Color(0xFF6B7280),
                ),
                child: Text(
                  _submitting ? '提交中…' : submitLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (!widget.interactive && !_submitting && widget.onSubmit == null)
            _notInteractiveNote(),
        ],
      ),
    );
  }
}

class _FormFieldRow extends StatelessWidget {
  const _FormFieldRow({
    super.key,
    required this.field,
    this.enabled = false,
    this.currentValue,
    this.onChanged,
    this.onUploadFile,
  });
  final Map field;
  final bool enabled;
  final Object? currentValue;
  final ValueChanged<Object?>? onChanged;
  final Future<Map<String, dynamic>?> Function({
    required String fieldName,
    required String fieldLabel,
  })? onUploadFile;

  @override
  Widget build(BuildContext context) {
    final label = _firstNonEmpty([
      _asString(field['label']),
      _asString(field['name']),
      _asString(field['title']),
    ]);
    final hint = _asString(field['placeholder']);
    final tooltip = _asString(field['tooltip']); // 契约 §3.0a 字段 tooltip
    final type = _asString(field['type']).toLowerCase();
    final body = _buildField(type, hint);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF374151),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 专业名词问号提示：hover（桌面）/ 长按（移动端）弹解释。
                  if (tooltip.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: tooltip,
                      triggerMode: TooltipTriggerMode.tap,
                      showDuration: const Duration(seconds: 6),
                      preferBelow: true,
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.all(10),
                      textStyle: const TextStyle(
                          fontSize: 12, height: 1.5, color: Colors.white),
                      decoration: BoxDecoration(
                        color: const Color(0xFF374151),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.help_outline,
                        size: 15,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          body,
        ],
      ),
    );
  }

  Widget _buildField(String type, String hint) {
    switch (type) {
      case 'textarea':
        return _textInput(hint, maxLines: 3);
      case 'number':
        return _textInput(hint, keyboardType: TextInputType.number,
            transformer: (raw) {
          if (raw.isEmpty) return null;
          return num.tryParse(raw) ?? raw;
        });
      case 'checkbox':
        return _checkboxRow(); // 提交 bool
      case 'switch':
        return _switchRow(); // 提交 bool (与 checkbox 视觉不同, payload 同形)
      case 'select':
        return _selectField(hint);
      case 'radio':
        return _radioGroup();
      case 'multiselect':
        return _multiSelectChips();
      case 'date':
        return _dateField(hint); // 提交 'YYYY-MM-DD'
      case 'time':
        return _timeField(hint); // 提交 'HH:mm'
      case 'datetime':
        return _datetimeField(hint); // 提交 'YYYY-MM-DDTHH:mm:00'
      case 'file':
        return _fileUploadField(hint, _fieldLabel());
      case 'text':
      case '':
        return _textInput(hint);
      default:
        // 真未知类型 — 保持 disabled 占位行 (与旧行为一致)。
        return _disabledPlaceholder(hint, label: '[$type]');
    }
  }

  String _fieldLabel() {
    return _firstNonEmpty([
      _asString(field['label']),
      _asString(field['name']),
      _asString(field['title']),
    ]);
  }

  Widget _disabledPlaceholder(String hint, {required String label}) {
    return AbsorbPointer(
      absorbing: true,
      child: TextField(
        enabled: false,
        style: const TextStyle(fontSize: 14, color: _formMutedTextColor),
        decoration: _formInputDecoration(
          hintText: hint.isNotEmpty ? hint : label,
          helperText: '本版本暂不支持此类型',
        ),
      ),
    );
  }

  Widget _fileUploadField(String hint, String label) {
    final fieldName = _firstNonEmpty([
      _asString(field['name']),
      _asString(field['id']),
      label,
    ]);
    return _FileUploadField(
      key: ValueKey('file-field-$fieldName'),
      fieldName: fieldName,
      label: label,
      hint: hint,
      enabled: enabled,
      currentValue: currentValue,
      onChanged: onChanged,
      onUploadFile: onUploadFile,
    );
  }

  Widget _textInput(
    String hint, {
    int maxLines = 1,
    TextInputType? keyboardType,
    Object? Function(String)? transformer,
  }) {
    return UiInputField(
      enabled: enabled,
      maxLines: maxLines,
      keyboardType: keyboardType,
      initialValue: currentValue is String ? currentValue as String : null,
      textStyle: const TextStyle(
        fontSize: 15,
        color: _formTextColor,
        height: 1.35,
      ),
      hintText: hint,
      borderRadius: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: _formFillColor,
      onChanged: (raw) {
        if (onChanged == null) return;
        onChanged!(transformer == null ? raw : transformer(raw));
      },
    );
  }

  Widget _checkboxRow() {
    final v = currentValue is bool ? currentValue as bool : false;
    final hint = _asString(field['placeholder']);
    return _FormFieldShell(
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: v,
            visualDensity: VisualDensity.compact,
            onChanged: enabled
                ? (nv) {
                    onChanged?.call(nv ?? false);
                  }
                : null,
          ),
          if (hint.isNotEmpty)
            Flexible(
              child: Text(
                hint,
                style: const TextStyle(
                  fontSize: 14,
                  color: _formMutedTextColor,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _selectField(String hint) {
    final parsed = _parsedOptions(); // [(value,label)]
    final optionValues = parsed.map((e) => e.$1).toSet();
    final allowCustom = field['allowCustom'] == true;
    final current = currentValue is String ? currentValue as String : null;

    // 自定义态：选了「其他」（哨兵 formOtherSentinel）或当前值不在预设选项里
    // （runtime 回灌的自定义值）。两者都在下方展开输入框。
    final inCustom = allowCustom &&
        current != null &&
        current.isNotEmpty &&
        (current == formOtherSentinel || !optionValues.contains(current));

    final entries = <DropdownMenuItem<String>>[
      for (final (val, lab) in parsed)
        DropdownMenuItem<String>(value: val, child: Text(lab)),
      if (allowCustom)
        const DropdownMenuItem<String>(
          value: formOtherSentinel,
          child: Text('其他（手动输入）'),
        ),
    ];
    // 下拉选中值：自定义态高亮「其他」，否则用当前值（不在选项里则不选）。
    final selectValue = inCustom
        ? formOtherSentinel
        : (optionValues.contains(current) ? current : null);

    final dropdown = InputDecorator(
      decoration: _formInputDecoration(
        hintText: hint.isNotEmpty ? hint : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selectValue,
          hint: Text(
            hint.isNotEmpty ? hint : '请选择',
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
          ),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          style: const TextStyle(fontSize: 15, color: _formTextColor),
          items: entries,
          onChanged: enabled ? (v) => onChanged?.call(v) : null,
        ),
      ),
    );

    if (!inCustom) return dropdown;
    // 自定义输入框：哨兵态初值为空，真实自定义值回填。用户输入即作为字段实际值。
    final customInit = current == formOtherSentinel ? '' : current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        dropdown,
        const SizedBox(height: 8),
        TextFormField(
          // key 绑到"是否自定义态"，从哨兵切到真实值时不重置光标。
          key: const ValueKey('form-custom-input'),
          enabled: enabled,
          initialValue: customInit,
          style: const TextStyle(
              fontSize: 15, color: _formTextColor, height: 1.35),
          decoration: _formInputDecoration(hintText: '请输入'),
          onChanged: (raw) => onChanged?.call(raw.trim()),
        ),
      ],
    );
  }

  // ---------------- Plan 17 round-5: 扩展字段控件 ----------------

  /// 解析 ``field['options']`` 为 ``[(value, label)]``。
  ///
  /// 兼容两种形式 (与 agent-example demo 同 contract):
  ///   - 字符串数组: ``["A","B"]`` → ``[("A","A"), ("B","B")]``
  ///   - 对象数组:   ``[{"label":"高","value":"high"}, ...]``
  /// malformed (单个元素既不是 String 又不是 Map / value 空) 静默跳过, 不抛异常。
  List<(String, String)> _parsedOptions() {
    final raw = _asList(field['options']);
    if (raw == null) return const [];
    final out = <(String, String)>[];
    for (final opt in raw) {
      String? val;
      String? lab;
      if (opt is Map) {
        val = _asString(opt['value']);
        lab = _firstNonEmpty([_asString(opt['label']), val]);
      } else if (opt is String) {
        val = opt;
        lab = opt;
      } else if (opt is num || opt is bool) {
        // 数字/bool 类型 option — 转字符串当 value+label, 不崩
        val = _asString(opt);
        lab = val;
      }
      if (val == null || val.isEmpty) continue;
      out.add((val, lab ?? val));
    }
    return out;
  }

  /// switch — 提交 bool。视觉是 Material Switch; payload 与 checkbox 同形。
  Widget _switchRow() {
    final v = currentValue is bool ? currentValue as bool : false;
    final hint = _asString(field['placeholder']);
    return _FormFieldShell(
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 42,
            height: 28,
            child: Transform.scale(
              scale: 0.76,
              alignment: Alignment.centerLeft,
              child: Switch(
                value: v,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: enabled ? (nv) => onChanged?.call(nv) : null,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              hint.isNotEmpty ? hint : (v ? '已开启' : '未开启'),
              style: const TextStyle(fontSize: 14, color: _formMutedTextColor),
            ),
          ),
        ],
      ),
    );
  }

  /// radio — 单选, 提交 selected option 的 ``value`` 字符串。
  Widget _radioGroup() {
    final options = _parsedOptions();
    if (options.isEmpty) {
      return _disabledPlaceholder('', label: '(radio 选项缺失)');
    }
    final current = currentValue is String ? currentValue as String : null;
    return _FormFieldShell(
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (val, lab) in options)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: enabled ? () => onChanged?.call(val) : null,
              child: Row(
                children: [
                  // Material Radio.groupValue / onChanged 在 3.32 标 deprecated, 推荐
                  // 上层包 RadioGroup。本表单 widget 是嵌在卡片内的轻量交互, 不引入
                  // RadioGroup 重构成本 — 暂用 deprecated API + ignore 注释; 待 RadioGroup
                  // 在我们当前 Flutter SDK 稳定后整体迁移。
                  // ignore: deprecated_member_use
                  Radio<String>(
                    value: val,
                    visualDensity: VisualDensity.compact,
                    // ignore: deprecated_member_use
                    groupValue: current,
                    // ignore: deprecated_member_use
                    onChanged: enabled ? (nv) => onChanged?.call(nv) : null,
                  ),
                  Flexible(
                    child: Text(
                      lab,
                      style: const TextStyle(
                        fontSize: 14,
                        color: _formTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// multiselect — 多选, 提交 ``List<String>`` of selected values。
  Widget _multiSelectChips() {
    final options = _parsedOptions();
    if (options.isEmpty) {
      return _disabledPlaceholder('', label: '(multiselect 选项缺失)');
    }
    final selected = currentValue is List
        ? (currentValue as List).map((e) => _asString(e)).toSet()
        : <String>{};
    return _FormFieldShell(
      enabled: enabled,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (val, lab) in options)
            FilterChip(
              label: Text(lab),
              selected: selected.contains(val),
              selectedColor: const Color(0xFFDBEAFE),
              checkmarkColor: _formFocusedBorderColor,
              side: BorderSide(
                color: selected.contains(val)
                    ? const Color(0xFF93C5FD)
                    : _formBorderColor,
              ),
              backgroundColor: Colors.white,
              labelStyle: TextStyle(
                fontSize: 14,
                color: selected.contains(val)
                    ? const Color(0xFF1D4ED8)
                    : _formTextColor,
              ),
              onSelected: enabled
                  ? (sel) {
                      final next = {...selected};
                      if (sel) {
                        next.add(val);
                      } else {
                        next.remove(val);
                      }
                      // 提交 List<String> 顺序按 options 顺序, 而不是用户点击顺序,
                      // 让 echo / runtime 看到的字段稳定可重放。
                      final ordered = [
                        for (final (v, _) in options)
                          if (next.contains(v)) v
                      ];
                      onChanged?.call(ordered);
                    }
                  : null,
            ),
        ],
      ),
    );
  }

  /// date — 提交 'YYYY-MM-DD'。
  Widget _dateField(String hint) {
    final v = currentValue is String ? currentValue as String : '';
    return _PickerButton(
      enabled: enabled,
      label: v.isNotEmpty ? v : (hint.isNotEmpty ? hint : '选择日期'),
      icon: Icons.calendar_today_outlined,
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: _PickerButton.contextOf(),
          initialDate: now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 5),
        );
        if (picked == null) return;
        // 严格 YYYY-MM-DD (Plan 17 round-5)
        final s = '${picked.year.toString().padLeft(4, '0')}-'
            '${picked.month.toString().padLeft(2, '0')}-'
            '${picked.day.toString().padLeft(2, '0')}';
        onChanged?.call(s);
      },
    );
  }

  /// time — 提交 'HH:mm' (24h)。
  Widget _timeField(String hint) {
    final v = currentValue is String ? currentValue as String : '';
    return _PickerButton(
      enabled: enabled,
      label: v.isNotEmpty ? v : (hint.isNotEmpty ? hint : '选择时间'),
      icon: Icons.access_time_outlined,
      onTap: () async {
        final picked = await showTimePicker(
          context: _PickerButton.contextOf(),
          initialTime: TimeOfDay.now(),
        );
        if (picked == null) return;
        final s = '${picked.hour.toString().padLeft(2, '0')}:'
            '${picked.minute.toString().padLeft(2, '0')}';
        onChanged?.call(s);
      },
    );
  }

  /// datetime — 提交 'YYYY-MM-DDTHH:mm:00' (Plan 17 round-5 固定格式; runtime echo
  /// 校对一致, 测试钉死)。秒位置 = `00` (用户不可见, 但保证可解析).
  Widget _datetimeField(String hint) {
    final v = currentValue is String ? currentValue as String : '';
    return _PickerButton(
      enabled: enabled,
      label: v.isNotEmpty ? v : (hint.isNotEmpty ? hint : '选择日期+时间'),
      icon: Icons.event_outlined,
      onTap: () async {
        final ctx = _PickerButton.contextOf();
        final now = DateTime.now();
        final d = await showDatePicker(
          context: ctx,
          initialDate: now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 5),
        );
        if (d == null) return;
        if (!ctx.mounted) return; // dialog 关闭后再用 ctx 取 time picker
        final t = await showTimePicker(
          context: ctx,
          initialTime: TimeOfDay.now(),
        );
        if (t == null) return;
        final s = '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}T'
            '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:00';
        onChanged?.call(s);
      },
    );
  }
}

/// Round-8: form `file` 字段的多附件 + 上传进度 + 失败重试 widget。
///
/// 设计要点 (与 round-5/6/7 单文件 widget 的差异):
/// - 支持多附件: 每点一次"添加附件"按钮就走一次 `onUploadFile` 链路, 上层 picker
///   单次只选一份, 因此"多文件"由"多次单选"组合而来 — 复用现有 message-files
///   上传链路, **不**新造批量上传 API。
/// - 每个 slot 自带 `_FileSlotStatus` (uploading|uploaded|failed); failed 状态
///   可重试 (同 slot 再走一次 picker→upload), 也可移除 (从 list 拿掉)。
/// - 提交 payload: `_values[fieldName]` 是 `List<Map<String,dynamic>>`, 每份
///   含 `{file_id, name, size, mime_type?, url?, field_name, field_label}` —
///   runtime 已能识别"list of file refs"; 若 list 为空, 我们 emit `null` 让
///   `_missingRequiredFields` 的 `v == null` 分支命中 (与旧单文件行为一致)。
/// - 向后兼容: 历史 currentValue 若是 single Map (旧单文件存储), 进 widget 时
///   还原成 1 个 uploaded slot; widget 重新 emit 后会写回 list 形态。
class _FileUploadField extends StatefulWidget {
  const _FileUploadField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.currentValue,
    required this.onChanged,
    required this.onUploadFile,
  });

  final String fieldName;
  final String label;
  final String hint;
  final bool enabled;
  final Object? currentValue;
  final ValueChanged<Object?>? onChanged;
  final Future<Map<String, dynamic>?> Function({
    required String fieldName,
    required String fieldLabel,
  })? onUploadFile;

  @override
  State<_FileUploadField> createState() => _FileUploadFieldState();
}

enum _FileSlotStatus { uploading, uploaded, failed }

class _FileSlot {
  _FileSlot({required this.id, required this.status, this.ref});
  final String id;
  _FileSlotStatus status;
  Map<String, dynamic>? ref;
  String? error;
}

class _FileUploadFieldState extends State<_FileUploadField> {
  late List<_FileSlot> _slots;
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _slots = _restoreFromValue(widget.currentValue);
  }

  String _nextId() {
    _idSeq += 1;
    return 'slot-$_idSeq';
  }

  List<_FileSlot> _restoreFromValue(Object? v) {
    if (v is List) {
      final out = <_FileSlot>[];
      for (final e in v) {
        if (e is Map) {
          out.add(_FileSlot(
            id: _nextId(),
            status: _FileSlotStatus.uploaded,
            ref: Map<String, dynamic>.from(e),
          ));
        }
      }
      return out;
    }
    if (v is Map && v.isNotEmpty) {
      return [
        _FileSlot(
          id: _nextId(),
          status: _FileSlotStatus.uploaded,
          ref: Map<String, dynamic>.from(v),
        ),
      ];
    }
    return [];
  }

  bool get _canUpload => widget.enabled && widget.onUploadFile != null;

  void _emit() {
    final uploaded = _slots
        .where((s) => s.status == _FileSlotStatus.uploaded && s.ref != null)
        .map((s) => s.ref!)
        .toList(growable: false);
    // 与旧单文件行为对齐: 没有任何 uploaded 文件 → 视为"未填写", emit null
    // 让必填校验能够命中; 否则 emit list 形态。
    widget.onChanged?.call(uploaded.isEmpty ? null : uploaded);
  }

  Future<void> _pickAndUpload() async {
    if (!_canUpload) return;
    final slot = _FileSlot(id: _nextId(), status: _FileSlotStatus.uploading);
    setState(() => _slots.add(slot));
    await _runUpload(slot);
  }

  Future<void> _runUpload(_FileSlot slot) async {
    if (!_canUpload) return;
    setState(() {
      slot.status = _FileSlotStatus.uploading;
      slot.error = null;
    });
    try {
      final uploaded = await widget.onUploadFile!(
        fieldName: widget.fieldName,
        fieldLabel: widget.label,
      );
      if (!mounted) return;
      if (uploaded == null) {
        // null = picker cancel 或 picker 失败. 若是新加的 slot (从未成功上传),
        // 直接从 list 删除避免遗留空壳; 若是重试的 slot, 保留为 failed 让用户决定。
        setState(() {
          if (slot.ref == null) {
            _slots.remove(slot);
          } else {
            slot.status = _FileSlotStatus.uploaded; // 重试取消 → 回到原 uploaded 态
          }
        });
        return;
      }
      setState(() {
        slot.status = _FileSlotStatus.uploaded;
        slot.ref = Map<String, dynamic>.from(uploaded);
        slot.error = null;
      });
      _emit();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        slot.status = _FileSlotStatus.failed;
        slot.error = '上传失败';
      });
      _emit();
    }
  }

  void _remove(_FileSlot slot) {
    setState(() => _slots.remove(slot));
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return _FormFieldShell(
      enabled: _canUpload,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final slot in _slots) _slotTile(slot),
          if (_slots.isNotEmpty) const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('file-upload-add'),
              onPressed: _canUpload ? _pickAndUpload : null,
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: Text(_slots.isEmpty
                  ? (widget.hint.isNotEmpty ? widget.hint : '选择附件上传')
                  : '继续添加附件'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          if (!_canUpload && widget.onUploadFile == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '当前状态暂不可上传',
                style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _slotTile(_FileSlot slot) {
    final name = _firstNonEmpty([
      _asString(slot.ref?['name']),
      _asString(slot.ref?['file_name']),
      _asString(slot.ref?['fileName']),
    ]);
    final sizeVal = slot.ref?['size'];
    final sizeText = sizeVal is num ? _humanFileSize(sizeVal.toInt()) : '';
    final mime = _asString(slot.ref?['mime_type']);
    final displayName = name.isNotEmpty
        ? name
        : (slot.status == _FileSlotStatus.uploading ? '上传中…' : '未命名文件');
    return Padding(
      key: ValueKey('file-slot-${slot.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(_slotIcon(slot), size: 18, color: _slotColor(slot)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: _formTextColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (sizeText.isNotEmpty || mime.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _firstNonEmpty([
                        if (sizeText.isNotEmpty && mime.isNotEmpty)
                          '$sizeText · $mime'
                        else
                          (sizeText.isNotEmpty ? sizeText : mime),
                      ]),
                      style: const TextStyle(
                        fontSize: 11,
                        color: _formMutedTextColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _statusChip(slot),
          if (slot.status == _FileSlotStatus.failed)
            TextButton(
              key: ValueKey('file-slot-retry-${slot.id}'),
              onPressed: _canUpload ? () => _runUpload(slot) : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('重试'),
            ),
          IconButton(
            key: ValueKey('file-slot-remove-${slot.id}'),
            tooltip: '移除',
            icon: const Icon(Icons.close, size: 16),
            onPressed: _canUpload && slot.status != _FileSlotStatus.uploading
                ? () => _remove(slot)
                : null,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  IconData _slotIcon(_FileSlot slot) {
    switch (slot.status) {
      case _FileSlotStatus.uploaded:
        return Icons.insert_drive_file_rounded;
      case _FileSlotStatus.failed:
        return Icons.error_outline;
      case _FileSlotStatus.uploading:
        return Icons.cloud_upload_outlined;
    }
  }

  Color _slotColor(_FileSlot slot) {
    switch (slot.status) {
      case _FileSlotStatus.uploaded:
        return _formFocusedBorderColor;
      case _FileSlotStatus.failed:
        return const Color(0xFFB91C1C);
      case _FileSlotStatus.uploading:
        return _formMutedTextColor;
    }
  }

  Widget _statusChip(_FileSlot slot) {
    String label;
    Color fg;
    Color bg;
    Widget? leading;
    switch (slot.status) {
      case _FileSlotStatus.uploading:
        label = '上传中';
        fg = const Color(0xFF1D4ED8);
        bg = const Color(0xFFDBEAFE);
        leading = const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.4),
        );
        break;
      case _FileSlotStatus.uploaded:
        label = '已上传';
        fg = const Color(0xFF047857);
        bg = const Color(0xFFD1FAE5);
        leading = const Icon(Icons.check, size: 10, color: Color(0xFF047857));
        break;
      case _FileSlotStatus.failed:
        label = '失败';
        fg = const Color(0xFFB91C1C);
        bg = const Color(0xFFFEE2E2);
        leading =
            const Icon(Icons.error_outline, size: 10, color: Color(0xFFB91C1C));
        break;
    }
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 4),
          Text(
            label,
            style:
                TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

String _humanFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

/// 用于 date/time/datetime 字段的统一外观: 圆角描边按钮 + 图标 + 文字。
class _PickerButton extends StatelessWidget {
  const _PickerButton({
    required this.enabled,
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final bool enabled;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  // pickers 需要 BuildContext; _FormFieldRow 是 Stateless, 我们用 Builder 拿到子树 context,
  // 这里的 `contextOf()` 由内层 Builder 在 build 阶段写入。
  static late BuildContext _ctx;
  static BuildContext contextOf() => _ctx;

  @override
  Widget build(BuildContext context) {
    _ctx = context;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 16),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          backgroundColor: enabled ? _formFillColor : _formDisabledFillColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: BorderSide(
            color: enabled ? _formBorderColor : const Color(0xFFE5E7EB),
          ),
          foregroundColor: enabled ? _formTextColor : const Color(0xFF9CA3AF),
        ),
      ),
    );
  }
}

class _ApprovalBlockView extends StatefulWidget {
  const _ApprovalBlockView({
    required this.block,
    required this.kind,
    required this.interactive,
    required this.agentMessageUuid,
    required this.approvalRequestId,
    required this.onApproval,
    required this.onA2AApproval,
    required this.onConfirm,
  });
  final Map<String, dynamic> block;

  /// 区分 `approval` / `approval_request` (走 `onApproval` + decision='approve|reject')
  /// 与 `confirm` (走 `onConfirm` + confirmed:true|false)。两条路径**后端语义不同**,
  /// 不能合流; 详 services/agent-bus/internal/service/chat/respond.go::buildRespondReplyBlock。
  final _ApprovalKind kind;

  final bool interactive;
  final String agentMessageUuid;
  final String approvalRequestId;

  /// 仅 `kind == approval` 时使用; confirm 时为 null。
  final Future<bool> Function({
    required String agentMessageUuid,
    required String decision,
    String? reason,
  })? onApproval;

  final Future<bool> Function({
    required String approvalRequestId,
    required String decision,
    String? reason,
  })? onA2AApproval;

  /// 仅 `kind == confirm` 时使用; approval 时为 null。
  final Future<bool> Function({
    required String agentMessageUuid,
    required bool confirmed,
  })? onConfirm;

  @override
  State<_ApprovalBlockView> createState() => _ApprovalBlockViewState();
}

class _ApprovalBlockViewState extends State<_ApprovalBlockView> {
  bool _submitting = false;
  // Plan 17 round-8: approval reject 切到"两阶段提交": 第一次点拒绝 → 展开 reason
  // 输入框 + "确认拒绝" / "取消" 二段按钮; 第二次点确认拒绝 → 真发 reject(reason)。
  // 这样 reject 永远带上下文 (即便用户留空, 也是显式确认过)。confirm 类卡片不走这条路。
  bool _showRejectReason = false;
  final TextEditingController _rejectReasonCtrl = TextEditingController();

  bool get _isConfirm => widget.kind == _ApprovalKind.confirm;

  /// 当前 kind 对应的提交回调非空 → 才允许 enable (即便 interactive=true, 也要避免
  /// 装配 mismatch 时按钮可点但提交炸)。
  bool get _hasCallback => _isConfirm
      ? widget.onConfirm != null
      : (widget.approvalRequestId.isNotEmpty
          ? widget.onA2AApproval != null
          : widget.onApproval != null);

  @override
  void dispose() {
    _rejectReasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _handlePositive() {
    return _isConfirm ? _submitConfirm(true) : _submitApproval('approve');
  }

  Future<void> _handleNegative() {
    if (_isConfirm) return _submitConfirm(false);
    // approval: reject 走两阶段 — 先展开 reason 输入框, 再确认提交。
    if (!_showRejectReason) {
      setState(() => _showRejectReason = true);
      return Future.value();
    }
    return _submitApproval('reject',
        reason: _rejectReasonCtrl.text.trim().isNotEmpty
            ? _rejectReasonCtrl.text.trim()
            : null);
  }

  void _cancelRejectReason() {
    setState(() {
      _showRejectReason = false;
      _rejectReasonCtrl.clear();
    });
  }

  Future<void> _submitApproval(String decision, {String? reason}) async {
    final isA2A = widget.approvalRequestId.isNotEmpty;
    if (!widget.interactive || _submitting) return;
    if (isA2A && widget.onA2AApproval == null) return;
    if (!isA2A && widget.onApproval == null) return;
    setState(() => _submitting = true);
    try {
      final ok = isA2A
          ? await widget.onA2AApproval!(
              approvalRequestId: widget.approvalRequestId,
              decision: decision,
              reason: reason,
            )
          : await widget.onApproval!(
              agentMessageUuid: widget.agentMessageUuid,
              decision: decision,
              reason: reason,
            );
      if (mounted && !ok) {
        // 失败 → 解锁让用户重试; reason 输入框保持展开, 别人没必要重新点拒绝
        setState(() => _submitting = false);
      }
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitConfirm(bool confirmed) async {
    final cb = widget.onConfirm;
    if (cb == null || !widget.interactive || _submitting) return;
    setState(() => _submitting = true);
    try {
      final ok = await cb(
        agentMessageUuid: widget.agentMessageUuid,
        confirmed: confirmed,
      );
      if (mounted && !ok) {
        setState(() => _submitting = false);
      }
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _firstNonEmpty(
        [_asString(widget.block['title']), _asString(widget.block['prompt'])]);
    final summary = _asString(widget.block['summary']);
    final interactive = widget.interactive && _hasCallback;
    final enabled = interactive && !_submitting;
    final isConfirm = _isConfirm;
    final titleLabel = isConfirm
        ? (title.isNotEmpty ? '确认 · $title' : '确认')
        : (title.isNotEmpty ? '审批 · $title' : '审批');
    // confirm 卡允许 agent 自定义两颗按钮文案 (confirm_label / cancel_label),
    // 避免 "取消申请" 这类场景下 "确认/取消" 双重否定绕人 (2026-07-15 用户反馈)。
    final customConfirm = _asString(widget.block['confirm_label']);
    final customCancel = _asString(widget.block['cancel_label']);
    final positiveLabel = _submitting
        ? '处理中…'
        : (isConfirm
            ? (customConfirm.isNotEmpty ? customConfirm : '确认')
            : '同意');
    // approval: 第一阶段 "拒绝"; 第二阶段 "确认拒绝" (展开 reason 输入框后)
    final negativeLabel = _submitting
        ? '处理中…'
        : (isConfirm
            ? (customCancel.isNotEmpty ? customCancel : '取消')
            : (_showRejectReason ? '确认拒绝' : '拒绝'));
    final readOnlyHint =
        isConfirm ? '当前客户端版本暂不支持在此确认，请升级后重试' : '当前客户端版本暂不支持在此审批，请升级后重试';
    return _BlockCard(
      title: titleLabel,
      titleIcon: Icons.fact_check_outlined,
      titleColor: const Color(0xFFB45309),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (summary.isNotEmpty)
            Text(summary,
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
          // round-8: approval reject 第二阶段 — reason 输入框
          if (!isConfirm && _showRejectReason) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _rejectReasonCtrl,
              enabled: enabled,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: '请填写拒绝原因 (可选)',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'reason 可以留空; 留空表示拒绝但不附加说明。',
              style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: enabled
                      ? (_showRejectReason && !_submitting
                          ? () {
                              // 第二阶段, 主按钮是 "取消" (回到第一阶段)
                              _cancelRejectReason();
                            }
                          : _handleNegative)
                      : null,
                  style: OutlinedButton.styleFrom(
                    disabledForegroundColor: const Color(0xFF6B7280),
                    side: const BorderSide(color: Color(0xFFE5E7EB)),
                  ),
                  child: Text(
                      _showRejectReason && !_isConfirm ? '取消' : negativeLabel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: enabled
                      ? (_showRejectReason && !_isConfirm
                          ? _handleNegative // round-8 第二阶段 — 真发 reject
                          : _handlePositive)
                      : null,
                  style: ElevatedButton.styleFrom(
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    disabledForegroundColor: const Color(0xFF6B7280),
                  ),
                  child: Text(_showRejectReason && !_isConfirm
                      ? negativeLabel // "确认拒绝"
                      : positiveLabel),
                ),
              ),
            ],
          ),
          // 仅能力缺失(回调未接入)才提示升级; 历史轮/已回应只置灰不加文案。
          if (!_hasCallback) _ReadOnlyHint(text: readOnlyHint),
        ],
      ),
    );
  }
}

class _ActionBlockView extends StatefulWidget {
  const _ActionBlockView({
    required this.block,
    required this.interactive,
    required this.agentMessageUuid,
    required this.onAction,
    this.onOpenPayment,
    this.onOpenEmployee,
  });
  final Map<String, dynamic> block;
  final bool interactive;
  final String agentMessageUuid;
  final Future<bool> Function({
    required String agentMessageUuid,
    required String actionId,
    Map<String, dynamic>? params,
  })? onAction;
  final Future<void> Function(String actionId)? onOpenPayment;
  final Future<void> Function(String actionId)? onOpenEmployee;
  @override
  State<_ActionBlockView> createState() => _ActionBlockViewState();
}

/// `open_payment:` 前缀 = 客户端本地动作（打开支付页），不走 respond 回灌。
bool _isLocalPaymentAction(String actionId) =>
    actionId.startsWith('open_payment:');

/// `open_employee:` 前缀 = 客户端本地动作（切到指定数字员工聊天框），
/// 不走 respond 回灌（F26 助手间衔接, 2026-07-24）。
bool _isLocalEmployeeAction(String actionId) =>
    actionId.startsWith('open_employee:');

class _ActionBlockViewState extends State<_ActionBlockView> {
  String? _submittingId;

  Future<void> _submit(String actionId) async {
    final cb = widget.onAction;
    if (cb == null || !widget.interactive || _submittingId != null) return;
    setState(() => _submittingId = actionId);
    try {
      final ok = await cb(
        agentMessageUuid: widget.agentMessageUuid,
        actionId: actionId,
        params: null,
      );
      if (mounted && !ok) {
        setState(() => _submittingId = null);
      }
    } catch (_) {
      if (mounted) setState(() => _submittingId = null);
    }
  }

  /// 本地动作（支付/切员工会话）：豁免 awaiting_user 门控（历史消息按钮
  /// 持续可点），完成后解锁按钮（结果由目标页内闭环，不回灌会话）。
  Future<void> _openLocal(
      String actionId, Future<void> Function(String)? cb) async {
    if (cb == null || _submittingId != null) return;
    setState(() => _submittingId = actionId);
    try {
      await cb(actionId);
    } finally {
      if (mounted) setState(() => _submittingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _asString(widget.block['title']);
    final actions = _asList(widget.block['actions']) ??
        _asList(widget.block['buttons']) ??
        _asList(widget.block['items']) ??
        const [];
    // 收集 (id, label) 对; id 缺失退回 label, 仍可作为 fallback。
    final items = <({String id, String label})>[];
    for (final a in actions) {
      final am = _asMap(a);
      if (am == null) continue;
      final lab = _firstNonEmpty([
        _asString(am['label']),
        _asString(am['title']),
        _asString(am['text']),
      ]);
      final id = _firstNonEmpty([_asString(am['id']), lab]);
      if (lab.isEmpty || id.isEmpty) continue;
      items.add((id: id, label: lab));
    }
    final enabled = widget.interactive && _submittingId == null;
    // 本地动作（open_payment: / open_employee:）豁免 awaiting_user 门控，
    // 装配了对应回调即可点。
    VoidCallback? pressFor(({String id, String label}) it) {
      if (_isLocalPaymentAction(it.id)) {
        return (widget.onOpenPayment != null && _submittingId == null)
            ? () => _openLocal(it.id, widget.onOpenPayment)
            : null;
      }
      if (_isLocalEmployeeAction(it.id)) {
        return (widget.onOpenEmployee != null && _submittingId == null)
            ? () => _openLocal(it.id, widget.onOpenEmployee)
            : null;
      }
      return enabled ? () => _submit(it.id) : null;
    }

    // ≤2 个动作 = 药丸横排 (确认/继续这类轻操作); >2 个 = 竖排选项列表
    // (菜单类, 序号徽标 + 全宽行, 避免长 label 药丸换行参差 — 2026-07-15 用户实锤)。
    final Widget actionsWidget;
    if (items.length > 2) {
      actionsWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _ActionOptionRow(
              index: i + 1,
              label: items[i].label,
              submitting: _submittingId == items[i].id,
              onPressed: pressFor(items[i]),
            ),
          ],
        ],
      );
    } else {
      actionsWidget = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final it in items)
            _ActionPill(
              label: it.label,
              submitting: _submittingId == it.id,
              onPressed: pressFor(it),
              emphasized: _isLocalPaymentAction(it.id),
            ),
        ],
      );
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (items.isEmpty)
          const Text('（无可执行选项）',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))
        else
          actionsWidget,
        // 仅"客户端真没接入交互能力(onAction==null)"才提示升级; 历史轮/已回应
        // (onAction 非空但消息非 awaiting_user) 只需按钮置灰, 不显示误导文案。
        if (!widget.interactive && widget.onAction == null)
          const _ReadOnlyHint(text: '当前客户端版本暂不支持此操作，请升级后重试'),
      ],
    );
    // 无标题（如首屏菜单）不套「操作」卡壳，选项组直接贴在正文下方更轻。
    if (title.isEmpty) return body;
    return _BlockCard(
      title: '操作 · $title',
      titleIcon: Icons.touch_app_outlined,
      titleColor: const Color(0xFF0F766E),
      child: body,
    );
  }
}

/// 选项列表行 (>2 个动作的菜单类 action 块): 序号徽标 + 文案 + chevron，
/// 白底全宽、浅蓝描边，对齐后端"回复序号也可以"的 chat-first 语义。
class _ActionOptionRow extends StatelessWidget {
  const _ActionOptionRow({
    required this.index,
    required this.label,
    required this.submitting,
    required this.onPressed,
  });

  final int index;
  final String label;
  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFFAFAFA),
        foregroundColor: const Color(0xFF1F2937),
        disabledForegroundColor: const Color(0xFF9CA3AF),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        alignment: Alignment.centerLeft,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: enabled ? const Color(0xFFDBEAFE) : const Color(0xFFE5E7EB),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  enabled ? const Color(0xFFEFF6FF) : const Color(0xFFF3F4F6),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color:
                    enabled ? const Color(0xFF2563EB) : const Color(0xFF9CA3AF),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (submitting)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: Color(0xFF2563EB),
              ),
            )
          else
            Icon(Icons.chevron_right,
                size: 16,
                color: enabled
                    ? const Color(0xFF93C5FD)
                    : const Color(0xFFD1D5DB)),
        ],
      ),
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.submitting,
    required this.onPressed,
    this.emphasized = false,
  });

  final String label;
  final bool submitting;
  final VoidCallback? onPressed;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final scheme = Theme.of(context).colorScheme;
    // 配色对齐 App 品牌蓝 #2563EB（_BlockCard accent 同源）；形态对齐设计原型的药丸选项。
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: enabled
            ? (emphasized ? scheme.primary : const Color(0xFFEFF6FF))
            : const Color(0xFFF3F4F6),
        foregroundColor:
            emphasized ? scheme.onPrimary : const Color(0xFF2563EB),
        disabledForegroundColor: const Color(0xFF9CA3AF),
        padding: emphasized
            ? const EdgeInsets.symmetric(horizontal: 24, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        minimumSize: emphasized ? const Size(120, 44) : Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: TextStyle(
          fontSize: emphasized ? 15 : 13,
          fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
        ),
        shape: StadiumBorder(
          side: BorderSide(
            color: enabled
                ? (emphasized ? scheme.primary : const Color(0xFFBFDBFE))
                : const Color(0xFFE5E7EB),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (submitting) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: Color(0xFF2563EB),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _ArtifactBlockView extends StatelessWidget {
  const _ArtifactBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final kind = _firstNonEmpty(
        [_asString(block['artifact_kind']), _asString(block['kind'])]);
    final name = _firstNonEmpty([
      _asString(block['name']),
      _asString(block['title']),
      _asString(block['filename']),
    ]);
    // 内嵌全文的文档卡 (如协议): 点击本地弹框阅读, 零网络往返。
    final text =
        _firstNonEmpty([_asString(block['text']), _asString(block['content'])]);
    if (text.isNotEmpty) {
      final title = name.isNotEmpty ? name : '文档';
      return Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showInlineDocDialog(context, title, text),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.description_outlined,
                    size: 16, color: Color(0xFF2563EB)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text('查看全文',
                    style: TextStyle(fontSize: 12, color: Color(0xFF2563EB))),
                const Icon(Icons.chevron_right,
                    size: 16, color: Color(0xFF2563EB)),
              ],
            ),
          ),
        ),
      );
    }
    return _BlockCard(
      title: kind.isNotEmpty ? '附件 · $kind' : '附件',
      titleIcon: Icons.attachment_outlined,
      child: Text(
        name.isNotEmpty ? name : '(未命名附件)',
        style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
      ),
    );
  }
}

/// 文档全文弹框 (协议等 artifact 内嵌文本): 标题 + 可滚动 markdown 正文。
void _showInlineDocDialog(BuildContext context, String title, String text) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: const Color(0xFF6B7280),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: ChatSelectableSurface(
                  child: ChatMarkdownWidget(
                      content: text, compact: true, selectable: false),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SourceBlockView extends StatelessWidget {
  const _SourceBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final title =
        _firstNonEmpty([_asString(block['title']), _asString(block['name'])]);
    final url = _asString(block['url']);
    final items = _asList(block['items']) ?? _asList(block['sources']);
    final list = <_SourceItem>[];
    if (items != null) {
      for (final it in items) {
        final im = _asMap(it);
        if (im == null) continue;
        list.add(_SourceItem(
          title:
              _firstNonEmpty([_asString(im['title']), _asString(im['name'])]),
          url: _asString(im['url']),
          snippet: _asString(im['snippet']),
        ));
      }
    } else if (title.isNotEmpty || url.isNotEmpty) {
      list.add(_SourceItem(title: title, url: url, snippet: ''));
    }
    return _BlockCard(
      title: '来源',
      titleIcon: Icons.link_rounded,
      titleColor: const Color(0xFF0EA5E9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (list.isEmpty)
            const Text('(无来源)',
                style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))
          else
            for (final s in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.title.isNotEmpty)
                      Text(s.title,
                          style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF111827),
                              fontWeight: FontWeight.w500)),
                    if (s.url.isNotEmpty)
                      Text(s.url,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF6B7280))),
                    if (s.snippet.isNotEmpty)
                      Text(s.snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF374151))),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _SourceItem {
  const _SourceItem(
      {required this.title, required this.url, required this.snippet});
  final String title;
  final String url;
  final String snippet;
}

class _AppCardBlockView extends StatelessWidget {
  const _AppCardBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final title =
        _firstNonEmpty([_asString(block['title']), _asString(block['name'])]);
    final summary = _firstNonEmpty(
        [_asString(block['summary']), _asString(block['description'])]);
    return _BlockCard(
      title: title.isNotEmpty ? title : '应用卡片',
      titleIcon: Icons.apps_rounded,
      child: summary.isNotEmpty
          ? Text(summary,
              style: const TextStyle(fontSize: 13, color: Color(0xFF374151)))
          : const SizedBox.shrink(),
    );
  }
}

class _ProgressBlockView extends StatelessWidget {
  const _ProgressBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final percent = block['percent'] ?? block['progress'];
    final label =
        _firstNonEmpty([_asString(block['label']), _asString(block['title'])]);
    double? p;
    if (percent is num) {
      p = (percent / 100).clamp(0.0, 1.0).toDouble();
    }
    return _BlockCard(
      title: label.isNotEmpty ? '进度 · $label' : '进度',
      titleIcon: Icons.timelapse_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: p,
            backgroundColor: const Color(0xFFF1F5F9),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF2563EB)),
            minHeight: 6,
          ),
          if (percent is num)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${percent.toStringAsFixed(0)}%',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF374151))),
            ),
        ],
      ),
    );
  }
}

class _SuggestionBlockView extends StatefulWidget {
  const _SuggestionBlockView({required this.block, this.onSendText});
  final Map<String, dynamic> block;

  /// 点击 chip = 把该问题作为普通用户消息发送（2026-07-15 交互修订：原
  /// action 回灌形态点击后转圈等整轮，改为发消息即时上屏 + 正常流式）。
  /// null（如群聊面板未装配 / 老容器）→ 退化为只读 chips，不误导可点。
  final Future<void> Function(String text)? onSendText;

  @override
  State<_SuggestionBlockView> createState() => _SuggestionBlockViewState();
}

class _SuggestionBlockViewState extends State<_SuggestionBlockView> {
  // 防双击连发；发送动作本身即时返回（消息上屏），不做 per-chip 转圈。
  bool _sending = false;

  Future<void> _send(String text) async {
    final cb = widget.onSendText;
    if (cb == null || _sending) return;
    setState(() => _sending = true);
    try {
      await cb(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _firstNonEmpty(
        [_asString(widget.block['title']), _asString(widget.block['name'])]);
    final suggestions = _extractSuggestions(widget.block);
    final clickable = widget.onSendText != null;
    final chips = suggestions.isEmpty
        ? const Text(
            '(无建议)',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          )
        : Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in suggestions)
                _SuggestionChip(
                  label: s,
                  onPressed: clickable && !_sending ? () => _send(s) : null,
                  readOnly: !clickable,
                ),
            ],
          );
    // 「猜你想问」场景（无 title）不套卡壳、不加引导语（用户拍板）——
    // pill 行直接贴正文下方，样式本身要传达"可点的追问"。
    if (title.isEmpty) {
      return Padding(padding: const EdgeInsets.only(top: 12), child: chips);
    }
    return _BlockCard(
      title: '建议 · $title',
      titleIcon: Icons.lightbulb_outline_rounded,
      titleColor: const Color(0xFFD97706),
      child: chips,
    );
  }

  List<String> _extractSuggestions(Map<String, dynamic> block) {
    final out = <String>[];
    final items = _asList(block['suggestions']) ??
        _asList(block['items']) ??
        _asList(block['options']);
    if (items != null) {
      for (final item in items) {
        if (item is String && item.trim().isNotEmpty) {
          out.add(item.trim());
          continue;
        }
        final m = _asMap(item);
        if (m == null) continue;
        final label = _firstNonEmpty([
          _asString(m['label']),
          _asString(m['text']),
          _asString(m['title']),
          _asString(m['value']),
        ]);
        if (label.trim().isNotEmpty) out.add(label.trim());
      }
    }
    final inline = _firstNonEmpty([
      _asString(block['text']),
      _asString(block['summary']),
      _asString(block['description']),
    ]);
    if (out.isEmpty && inline.trim().isNotEmpty) out.add(inline.trim());
    return out;
  }
}

/// 追问引导 pill：可点时浅蓝品牌样式（对齐 _ActionPill / 设计原型「猜你想问」），
/// 只读（未装配 onSendText）时保持原琥珀色静态样式。
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({
    required this.label,
    required this.onPressed,
    required this.readOnly,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    if (readOnly) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF92400E),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    // 追问 pill（2026-07-15 二次重做）：白底 + 淡蓝描边 + 微投影的干净胶囊，
    // 14px 舒展热区；纯色浅蓝底显得廉价、12px 显示过小均为用户实锤。
    return Material(
      color: Colors.white,
      shape: const StadiumBorder(side: BorderSide(color: Color(0xFFD0DEF7))),
      shadowColor: const Color(0x1F2563EB),
      elevation: 1.2,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        hoverColor: const Color(0xFFF3F7FF),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9.5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: onPressed != null
                  ? const Color(0xFF2563EB)
                  : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagramSourceBlockView extends StatelessWidget {
  const _DiagramSourceBlockView({required this.block, required this.kind});
  final Map<String, dynamic> block;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final title =
        _firstNonEmpty([_asString(block['title']), _asString(block['name'])]);
    final source = _firstNonEmpty([
      _asString(block['source']),
      _asString(block['code']),
      _asString(block['text']),
      _asString(block['content']),
      _asString(block['diagram']),
      _asString(block['mermaid']),
    ]);
    return _BlockCard(
      title: title.isNotEmpty ? '图表源码 · $title' : '图表源码 · $kind',
      titleIcon: Icons.account_tree_outlined,
      titleColor: const Color(0xFF0F766E),
      child: source.isEmpty
          ? const Text(
              '(无图表源码)',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            )
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  source,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFF334155),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
    );
  }
}

class _PlanBlockView extends StatelessWidget {
  const _PlanBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final title = _asString(block['title']);
    final steps =
        _asList(block['steps']) ?? _asList(block['items']) ?? const [];
    return _BlockCard(
      title: title.isNotEmpty ? '计划 · $title' : '计划',
      titleIcon: Icons.checklist_rounded,
      child: steps.isEmpty
          ? const Text('(空)',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text('${i + 1}.',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF6B7280))),
                        ),
                        Expanded(
                          child: Text(
                            _planStepLabel(steps[i]),
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF111827)),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  String _planStepLabel(dynamic step) {
    if (step is String) return step;
    final sm = _asMap(step);
    if (sm == null) return step?.toString() ?? '';
    return _firstNonEmpty([
      _asString(sm['title']),
      _asString(sm['name']),
      _asString(sm['text']),
      _asString(sm['description']),
    ]);
  }
}

class _InlineErrorBlockView extends StatelessWidget {
  const _InlineErrorBlockView({required this.block});
  final Map<String, dynamic> block;
  @override
  Widget build(BuildContext context) {
    final msg =
        _firstNonEmpty([_asString(block['message']), _asString(block['text'])]);
    return _BlockCard(
      title: '错误',
      titleIcon: Icons.error_outline_rounded,
      titleColor: const Color(0xFFDC2626),
      child: Text(
        msg.isNotEmpty ? msg : '(无详细信息)',
        style: const TextStyle(fontSize: 13, color: Color(0xFF7F1D1D)),
      ),
    );
  }
}
