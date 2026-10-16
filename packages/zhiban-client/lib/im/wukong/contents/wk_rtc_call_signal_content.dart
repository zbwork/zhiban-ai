// F16 RTC 通话控制信令 WuKong 自定义消息内容 (type=1001)。
//
// 与 F16 spec v0.6.4 §6.2.6 + TDD §4.6 对齐:
//   payload JSON 形如 {"type":1001, "event":"invite", "data":{...}}
//
// 客户端通过 WuKong custom content 协议传输, 服务端通过 wukongwh.MuxSink
// 把 contentType=1001 的消息路由到 CallSignalSink, **不**触发 @Agent 链路。
//
// 客户端侧:
//   - encode/decode 这个类
//   - WukongImClient.init() 把它注册到 WKIM.shared.messageManager.registerMsgContent(1001, ...)
//   - WukongImClient._toImMessage() 不把它作为聊天文本/媒体渲染, 而是另起旁路
//     stream (RtcCallSignalEvent) 暴露给 lib/rtc/signaling_listener.dart 消费。
//
// 安全闸门 (spec §6.2.6):
//   - **服务端**: CallSignalSink 只写 call_event 审计, 不推 call_session.state。
//   - **客户端**: 信令仅供 UI 唤醒 (来电浮窗 / Dock 反弹 / 全局热键); 真正的状态推进
//     仍走 POST /api/agent-bus/v1/calls/* HTTP + 权限闸口。

import 'dart:convert';

import 'package:wukongimfluttersdk/model/wk_message_content.dart';

/// F16 RTC 信令 WuKong content type. **不**是 WuKong channel type;
/// WuKong channel type 仍是 1=person / 2=group, 1001 写在 payload JSON 内部。
const int kRtcCallSignalContentType = 1001;

/// 信令动词集合 (F16 spec v0.6.4 §6.2.6 + TDD §4.6 SignalingTransport)。
enum RtcCallSignalEvent {
  invite,
  cancel,
  accept,
  reject,
  end,
  ringing,
  unknown,
}

/// 把 enum 写成 wire 字符串 (与 payload.event 字段一致)。
String rtcCallSignalEventName(RtcCallSignalEvent e) {
  switch (e) {
    case RtcCallSignalEvent.invite:
      return 'invite';
    case RtcCallSignalEvent.cancel:
      return 'cancel';
    case RtcCallSignalEvent.accept:
      return 'accept';
    case RtcCallSignalEvent.reject:
      return 'reject';
    case RtcCallSignalEvent.end:
      return 'end';
    case RtcCallSignalEvent.ringing:
      return 'ringing';
    case RtcCallSignalEvent.unknown:
      return 'unknown';
  }
}

/// 解析 wire 字符串 → enum。未识别动词回到 [RtcCallSignalEvent.unknown];
/// 大小写不敏感, 容忍首尾空白。
RtcCallSignalEvent rtcCallSignalEventFromName(String? raw) {
  final v = (raw ?? '').trim().toLowerCase();
  switch (v) {
    case 'invite':
      return RtcCallSignalEvent.invite;
    case 'cancel':
      return RtcCallSignalEvent.cancel;
    case 'accept':
      return RtcCallSignalEvent.accept;
    case 'reject':
      return RtcCallSignalEvent.reject;
    case 'end':
      return RtcCallSignalEvent.end;
    case 'ringing':
      return RtcCallSignalEvent.ringing;
    default:
      return RtcCallSignalEvent.unknown;
  }
}

/// F16 RTC 信令自定义消息内容。
///
/// payload schema:
///   {
///     "type": 1001,
///     "event": "invite" | "cancel" | "accept" | "reject" | "end" | "ringing",
///     "data": { ... call-specific biz fields ... }
///   }
///
/// `data` 允许任意 JSON 对象, 由 CallService / 客户端约定具体字段
/// (建议至少含 call_uuid; invite 时含 host / kind / room_uuid)。
class WkRtcCallSignalContent extends WKMessageContent {
  RtcCallSignalEvent event = RtcCallSignalEvent.unknown;
  Map<String, dynamic> data = const <String, dynamic>{};

  WkRtcCallSignalContent() {
    contentType = kRtcCallSignalContentType;
  }

  @override
  Map<String, dynamic> encodeJson() {
    return {
      'type': kRtcCallSignalContentType,
      'event': rtcCallSignalEventName(event),
      if (data.isNotEmpty) 'data': data,
    };
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    event = rtcCallSignalEventFromName(json['event'] as String?);
    final rawData = json['data'];
    if (rawData is Map) {
      data = rawData.cast<String, dynamic>();
    } else {
      data = const <String, dynamic>{};
    }
    return this;
  }

  /// 控制信令**不应**作为聊天文本渲染 (见 spec §6.2.6 安全闸门 + UX)。
  /// 返回空串让 _toImMessage 走旁路, UI 不会显示气泡。
  @override
  String displayText() => '';

  @override
  String searchableWord() => '';
}

/// 从 WuKong SDK 的消息字段中解析 RTC 信令。
///
/// 正常路径下 SDK 会按 registerMsgContent(1001, ...) 把 messageContent 解成
/// [WkRtcCallSignalContent]。本函数保留 raw content fallback, 防止本地缓存/历史同步/SDK
/// 版本差异导致 custom content 没有按预期实例化时, 1001 信令被当普通空消息吞掉。
WkRtcCallSignalContent? rtcSignalContentFromWukongFields({
  required int contentType,
  required String content,
  Object? messageContent,
}) {
  if (messageContent is WkRtcCallSignalContent) {
    return messageContent;
  }
  if (contentType != kRtcCallSignalContentType) {
    return null;
  }
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map) return null;
    return WkRtcCallSignalContent().decodeJson(decoded.cast<String, dynamic>())
        as WkRtcCallSignalContent;
  } catch (_) {
    return null;
  }
}
