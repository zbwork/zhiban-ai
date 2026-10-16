import 'dart:async';

import 'package:dio/dio.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_models.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

export 'package:zhiban_client/pages/chat/services/agent_direct_models.dart';

/// ADR-0026 agent-direct 双通道客户端切换。
///
/// 把「人↔数字员工单聊」的**触发入口**从旧 `/chat/send` 换成「prepare-wukong → WuKong SDK 直发 +
/// 等服务端 message_id → attach-stream → 既有 `/chat/stream?stream_id=`」。聊天 pane 仍渲染 agent-bus
/// 消息 + SSE,不重建。本文件为**纯编排**,SDK 细节经注入的 [WukongMessageSender] 隔离,便于单测。
/// DTO / disabled 异常见 `agent_direct_models.dart`。契约见 docs §P2.1b「Flutter cutover」。

/// 发结构化消息到 WuKong channel 并返回**服务端 message_id**(供 attach 用)的抽象。
/// 生产实现 = [sendAgentDirectBlocksAwaitingServerId];测试注入 fake 返回固定 id / 抛错。
typedef WukongMessageSender = Future<String> Function(
  String channelId,
  int channelType,
  List<ImMessageBlock> blocks,
  String summary,
);

/// 发 agent-direct 结构化消息到 WuKong channel,并等 SDK ack 把 `clientMsgNo` 对应的服务端 `message_id` 回填。
///
/// WuKong SDK `sendMessage` 不返回 message_id:本端插入(insert)先经消息流给 `clientMsgNo`(messageId 空);
/// 服务端 ack 后经 refresh 用**同一 `clientMsgNo`** 填上真实 `messageId`。这里订阅 broadcast 消息流对账:
/// 只认自己(`connectedUid`)发到目标 channel 的消息,insert 记 `clientMsgNo` → refresh 取 `messageId`。
/// `sendStatus=failed` → 抛错;超时 [ackTimeout] → 抛 [TimeoutException]。调用方据异常 fallback / 失败提示。
///
/// 约束:agent-direct 发送由 `isSending` 串行化(同一时刻仅一条在途),故按 channel + fromSelf 对账安全。
Future<String> sendAgentDirectBlocksAwaitingServerId(
  ImClient im,
  String channelId,
  int channelType, {
  required List<ImMessageBlock> blocks,
  required String summary,
  Duration ackTimeout = const Duration(seconds: 8),
}) async {
  final me = im.connectedUid;
  final completer = Completer<String>();
  String? myClientMsgNo;

  final sub = im.listenMessages().listen((m) {
    if (m.channelId != channelId) return;
    if (me != null && me.isNotEmpty && m.fromUid != me) return; // 只认自己发出的
    // insert(非 refresh)先到 → 记下我的 clientMsgNo。
    if (myClientMsgNo == null && !m.isRefresh && m.clientMsgNo.isNotEmpty) {
      myClientMsgNo = m.clientMsgNo;
    }
    if (myClientMsgNo == null || m.clientMsgNo != myClientMsgNo) return;
    if (m.sendStatus == ImSendStatus.failed) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('wukong send failed: ${m.errorMessage}'),
        );
      }
      return;
    }
    if (m.messageId.isNotEmpty && m.messageId != '0') {
      if (!completer.isCompleted) completer.complete(m.messageId);
    }
  });

  try {
    final cleanSummary = summary.trim();
    if (_isSingleText(blocks, cleanSummary)) {
      await im.sendTextMessage(channelId, channelType, blocks.single.text);
    } else {
      await im.sendMixedMessage(
        channelId,
        channelType,
        blocks: blocks,
        summary: cleanSummary,
      );
    }
    return await completer.future.timeout(ackTimeout);
  } finally {
    await sub.cancel();
  }
}

bool _isSingleText(List<ImMessageBlock> blocks, String summary) {
  if (blocks.length != 1 || !blocks.single.isText) return false;
  final text = blocks.single.text.trim();
  return text.isNotEmpty && (summary.isEmpty || summary == text);
}

Future<String> sendAgentDirectTextAwaitingServerId(
  ImClient im,
  String channelId,
  int channelType,
  String text, {
  Duration ackTimeout = const Duration(seconds: 8),
}) {
  return sendAgentDirectBlocksAwaitingServerId(
    im,
    channelId,
    channelType,
    blocks: [ImMessageBlock(kind: ImMessageBlockKind.text, text: text)],
    summary: text,
    ackTimeout: ackTimeout,
  );
}

/// 编排结果种类。
enum AgentDirectSendKind {
  /// run 已就绪 → 用 [AgentDirectSendOutcome.streamId] 接既有 SSE。
  streamReady,

  /// 走旧 `/chat/send` + `/chat/stream` 现有路径(disabled / WuKong 未连 / prepare 失败)。
  fallback,

  /// 发送 / 执行失败 → 失败提示,**不 fake success、不回退**(WuKong 已发,回退会双跑)。
  failed,
}

class AgentDirectSendOutcome {
  const AgentDirectSendOutcome._({
    required this.kind,
    this.streamId = '',
    this.agentMessageUuid = '',
    this.conversationUuid = '',
    this.roomUuid = '',
    this.wukongChannelId = '',
    this.wukongChannelType = 0,
    this.errorMessage = '',
    this.disabled = false,
    this.insufficientCredits = false,
  });

  final AgentDirectSendKind kind;
  final String streamId;
  final String agentMessageUuid;
  final String conversationUuid;
  final String roomUuid;
  final String wukongChannelId;
  final int wukongChannelType;
  final String errorMessage;

  /// fallback 是否因后端 disabled(404)触发(调用方可缓存,避免后续重复 prepare)。
  final bool disabled;

  /// failed 是否为「积分不足」前置检查拒绝(调用方据此触发钱包余额刷新)。
  final bool insufficientCredits;

  factory AgentDirectSendOutcome.streamReady({
    required String streamId,
    required String agentMessageUuid,
    required String conversationUuid,
    String roomUuid = '',
    String wukongChannelId = '',
    int wukongChannelType = 0,
  }) =>
      AgentDirectSendOutcome._(
        kind: AgentDirectSendKind.streamReady,
        streamId: streamId,
        agentMessageUuid: agentMessageUuid,
        conversationUuid: conversationUuid,
        roomUuid: roomUuid,
        wukongChannelId: wukongChannelId,
        wukongChannelType: wukongChannelType,
      );

  factory AgentDirectSendOutcome.fallback({bool disabled = false}) =>
      AgentDirectSendOutcome._(
        kind: AgentDirectSendKind.fallback,
        disabled: disabled,
      );

  factory AgentDirectSendOutcome.failed(
    String message, {
    bool insufficientCredits = false,
  }) =>
      AgentDirectSendOutcome._(
        kind: AgentDirectSendKind.failed,
        errorMessage: message,
        insufficientCredits: insufficientCredits,
      );
}

/// attach-stream 拒绝是否为「积分不足」前置检查命中。判断口径与 error_utils.dart 的
/// isInsufficientCreditsError 保持一致(ResponseInterceptor 把业务错误 message 放在
/// DioException.error 字段，见该文件顶部注释)；本文件不直接 import error_utils，避免
/// 给这个「纯编排,无 UI 依赖」的文件引入展示层工具函数。
bool _isInsufficientCreditsError(Object error) {
  String raw;
  if (error is DioException) {
    final e = error.error;
    if (e is String && e.isNotEmpty) {
      raw = e;
    } else if (error.message != null && error.message!.isNotEmpty) {
      raw = error.message!;
    } else {
      return false;
    }
  } else {
    raw = error.toString();
  }
  return raw.toLowerCase().contains('billing.insufficient_credits');
}

/// agent-direct 双通道发送编排器(纯逻辑,无 UI / Riverpod 依赖)。
///
/// 流程:门控(WuKong 已连)→ prepare → WuKong 直发取服务端 message_id → attach 有限轮询 →
/// started/attached 返回 streamReady;pending 按 `retry_after_ms`(clamp)重试至上限;failed/超时 → failed。
/// 任一 disabled(404)/ prepare 失败 / WuKong 未连 → fallback(调用方走旧 `/chat/send`)。
class AgentDirectDualChannelSender {
  AgentDirectDualChannelSender({
    required this.service,
    required this.wukongSend,
    required this.isWukongConnected,
    Future<void> Function(Duration)? sleep,
    this.maxAttachAttempts = 70,
    this.maxTotalWait = const Duration(seconds: 100),
    this.defaultRetryAfterMs = 500,
    this.minRetryAfterMs = 200,
    this.maxRetryAfterMs = 2000,
  }) : sleep = sleep ?? Future.delayed;

  final OpenClawChatService service;
  final WukongMessageSender wukongSend;
  final bool Function() isWukongConnected;
  final Future<void> Function(Duration) sleep;
  final int maxAttachAttempts;
  final Duration maxTotalWait;
  final int defaultRetryAfterMs;
  final int minRetryAfterMs;
  final int maxRetryAfterMs;

  Future<AgentDirectSendOutcome> send({
    required String agentUuid,
    required List<ImMessageBlock> blocks,
    required String summary,
  }) async {
    final cleanSummary = summary.trim();
    if (blocks.isEmpty || cleanSummary.isEmpty) {
      return AgentDirectSendOutcome.fallback();
    }
    if (!isWukongConnected()) {
      return AgentDirectSendOutcome.fallback();
    }

    final AgentDirectPrepareResult prep;
    try {
      prep = await service.prepareAgentDirectWuKong(agentUuid);
    } on AgentDirectDisabledException {
      return AgentDirectSendOutcome.fallback(disabled: true);
    } catch (_) {
      // prepare 失败(网络/异常)→ 开发期回退旧路径,不炸。
      return AgentDirectSendOutcome.fallback();
    }
    if (prep.wukongChannelId.isEmpty || prep.conversationUuid.isEmpty) {
      return AgentDirectSendOutcome.fallback();
    }

    final String messageId;
    try {
      messageId = await wukongSend(
        prep.wukongChannelId,
        prep.wukongChannelType,
        blocks,
        cleanSummary,
      );
    } catch (_) {
      // WuKong 直发失败(可能已部分发出)→ **不回退**(避免双发),失败提示。
      return AgentDirectSendOutcome.failed('发送失败，请稍后重试');
    }
    if (messageId.isEmpty) {
      return AgentDirectSendOutcome.failed('发送失败，请稍后重试');
    }

    // attach 有限轮询。
    var elapsed = Duration.zero;
    for (var attempt = 0; attempt < maxAttachAttempts; attempt++) {
      final AgentDirectAttachResult res;
      try {
        res = await service.attachAgentDirectStream(
          conversationUuid: prep.conversationUuid,
          wukongChannelId: prep.wukongChannelId,
          wukongMessageId: messageId,
        );
      } on AgentDirectDisabledException {
        // prepare 成功但 attach disabled(罕见竞态)→ 已 WuKong 发出,不回退,失败提示。
        return AgentDirectSendOutcome.failed('服务暂不可用，请稍后重试');
      } catch (e) {
        if (_isInsufficientCreditsError(e)) {
          return AgentDirectSendOutcome.failed('积分不足，请先购买积分包或升级套餐',
              insufficientCredits: true);
        }
        return AgentDirectSendOutcome.failed('发送失败，请稍后重试');
      }

      if (res.isReady) {
        return AgentDirectSendOutcome.streamReady(
          streamId: res.streamId,
          agentMessageUuid: res.agentMessageUuid,
          conversationUuid: res.conversationUuid.isNotEmpty
              ? res.conversationUuid
              : prep.conversationUuid,
          roomUuid: prep.roomUuid,
          wukongChannelId: prep.wukongChannelId,
          wukongChannelType: prep.wukongChannelType,
        );
      }
      if (res.isFailed) {
        return AgentDirectSendOutcome.failed('数字员工执行失败，请重试');
      }

      // pending → 按 retry_after_ms(clamp)等待重试,受总时长上限约束。
      final waitMs =
          (res.retryAfterMs > 0 ? res.retryAfterMs : defaultRetryAfterMs)
              .clamp(minRetryAfterMs, maxRetryAfterMs);
      final wait = Duration(milliseconds: waitMs);
      if (elapsed + wait > maxTotalWait) break;
      await sleep(wait);
      elapsed += wait;
    }
    return AgentDirectSendOutcome.failed('数字员工响应超时，请稍后重试');
  }
}
