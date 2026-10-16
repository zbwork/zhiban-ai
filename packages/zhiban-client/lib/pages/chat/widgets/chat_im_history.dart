import 'package:flutter/widgets.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';

/// 聊天历史抽屉(P2,仅客户端,人↔人 + 群聊共用)的 tab 与纯过滤逻辑。
/// 见 `docs/contracts/agent-bus-client-contract.md` §P2.1b「聊天历史抽屉接真实消息」。

enum ImHistoryTab { all, file, media }

enum ImHistoryFileType { all, pdf, word, excel, ppt, archive, video, other }

enum ImHistoryDateFilter { all, today, yesterday, last7Days, last30Days }

/// 纯函数:按 [tab] + [query] 过滤会话消息,**正序(旧→新)**返回。
///
/// - `all`:文本 + 媒体全部。
/// - `file`:`mediaKind == file`(含视频, 视频底层 wire 仍是 file)。
/// - `media`:**图片 + 视频** (`isImageMessage(m)` 或 `isVideoMessage(m)`);
///   视频识别按 mime/扩展 (mp4/mov/webm/m4v/avi/mkv 等), 与气泡分流口径一致。
///
/// [query]:大小写不敏感、**包含**匹配 `text` 或 `mediaName`;空白 = 当前 tab 全量。
/// [senderUid]、[fileType]、[dateFilter] 与关键词按 AND 组合;日期按设备本地自然日计算。
/// 纯客户端,不调后端。入参 [messages] 约定按 `messageSeq` 升序(controller 既有口径),
/// 故结果保持原顺序,由面板默认滚到末尾展示最新。
List<ImMessage> filterHistoryMessages(
  List<ImMessage> messages,
  ImHistoryTab tab,
  String query, {
  String senderUid = '',
  ImHistoryFileType fileType = ImHistoryFileType.all,
  ImHistoryDateFilter dateFilter = ImHistoryDateFilter.all,
  DateTime? now,
}) {
  final q = query.trim().toLowerCase();
  final dateRange = _historyDateRange(dateFilter, now ?? DateTime.now());
  final out = <ImMessage>[];
  for (final m in messages) {
    switch (tab) {
      case ImHistoryTab.all:
        break;
      case ImHistoryTab.file:
        if (m.mediaKind != ImMediaKind.file && !m.blocks.any((b) => b.isFile)) {
          continue;
        }
        break;
      case ImHistoryTab.media:
        // P2 (2026-06): 「图片与视频」tab 同时包含视频 (file wire + 视频 mime/扩展)。
        if (!isHistoryMediaMessage(m)) continue;
        break;
    }
    if (senderUid.isNotEmpty && m.fromUid != senderUid) continue;
    if (dateRange != null) {
      final sentAt = _historyMessageDateTime(m.timestamp);
      if (sentAt == null ||
          sentAt.isBefore(dateRange.$1) ||
          !sentAt.isBefore(dateRange.$2)) {
        continue;
      }
    }
    if (tab == ImHistoryTab.file &&
        fileType != ImHistoryFileType.all &&
        !_matchesHistoryFileType(m, fileType)) {
      continue;
    }
    if (q.isNotEmpty) {
      final blockHay = m.blocks
          .map((b) => '${b.text} ${b.name} ${b.mime}')
          .join(' ')
          .toLowerCase();
      final hay = '${m.text} ${m.mediaName} $blockHay'.toLowerCase();
      if (!hay.contains(q)) continue;
    }
    out.add(m);
  }
  return out;
}

bool _matchesHistoryFileType(ImMessage message, ImHistoryFileType wanted) {
  final candidates = <(String, String)>[];
  if (message.mediaKind == ImMediaKind.file) {
    candidates.add((
      message.mediaName.trim().isNotEmpty ? message.mediaName : message.text,
      message.mediaMime,
    ));
  }
  for (final block in message.blocks) {
    if (block.isFile) candidates.add((block.name, block.mime));
  }
  return candidates.any(
    (candidate) =>
        _resolveHistoryFileType(candidate.$1, candidate.$2) == wanted,
  );
}

ImHistoryFileType _resolveHistoryFileType(String name, String mime) {
  final normalizedMime = mime.trim().toLowerCase();
  final normalizedName = name.trim().toLowerCase();
  final dot = normalizedName.lastIndexOf('.');
  final ext = dot >= 0 && dot < normalizedName.length - 1
      ? normalizedName.substring(dot + 1)
      : '';

  if (isVideoMime(normalizedMime) || isVideoFileName(normalizedName)) {
    return ImHistoryFileType.video;
  }
  if (normalizedMime.contains('pdf') || ext == 'pdf') {
    return ImHistoryFileType.pdf;
  }
  if (normalizedMime.contains('word') ||
      normalizedMime.contains('wordprocessingml') ||
      const {'doc', 'docx'}.contains(ext)) {
    return ImHistoryFileType.word;
  }
  if (normalizedMime.contains('excel') ||
      normalizedMime.contains('spreadsheet') ||
      const {'xls', 'xlsx', 'csv'}.contains(ext)) {
    return ImHistoryFileType.excel;
  }
  if (normalizedMime.contains('powerpoint') ||
      normalizedMime.contains('presentation') ||
      const {'ppt', 'pptx'}.contains(ext)) {
    return ImHistoryFileType.ppt;
  }
  if (normalizedMime.contains('zip') ||
      normalizedMime.contains('compressed') ||
      normalizedMime.contains('archive') ||
      const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) {
    return ImHistoryFileType.archive;
  }
  return ImHistoryFileType.other;
}

(DateTime, DateTime)? _historyDateRange(
  ImHistoryDateFilter filter,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return switch (filter) {
    ImHistoryDateFilter.all => null,
    ImHistoryDateFilter.today => (today, tomorrow),
    ImHistoryDateFilter.yesterday => (
        DateTime(now.year, now.month, now.day - 1),
        today,
      ),
    ImHistoryDateFilter.last7Days => (
        DateTime(now.year, now.month, now.day - 6),
        tomorrow,
      ),
    ImHistoryDateFilter.last30Days => (
        DateTime(now.year, now.month, now.day - 29),
        tomorrow,
      ),
  };
}

DateTime? _historyMessageDateTime(int timestamp) {
  if (timestamp <= 0) return null;
  final milliseconds = timestamp > 1000000000000
      ? timestamp
      : timestamp > 1000000000
          ? timestamp * 1000
          : timestamp;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

/// 列表行摘要:文本原文 / 图片 `[图片]`(无名)或文件名 / 文件名。
String historyMessageSummary(ImMessage m) {
  if (m.blocks.isNotEmpty) {
    final parts = <String>[];
    for (final b in m.blocks) {
      if (b.isText && b.text.trim().isNotEmpty) {
        parts.add(b.text.trim());
      } else if (b.isImage) {
        parts.add('[图片]');
      } else if (b.isFile) {
        parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[文件]');
      } else if (b.isCallEvent) {
        // F16 通话卡片：摘要用卡片文案（"未接听"/"通话时长 01:23"），空则兜底"语音通话"。
        parts.add(b.text.trim().isNotEmpty ? b.text.trim() : '语音通话');
      }
    }
    final summary = parts.join(' ').trim();
    if (summary.isNotEmpty) return summary;
  }
  if (m.mediaKind == ImMediaKind.image) {
    return m.mediaName.trim().isNotEmpty ? m.mediaName : '[图片]';
  }
  if (m.mediaKind == ImMediaKind.file) {
    return m.mediaName.trim().isNotEmpty ? m.mediaName : '[文件]';
  }
  return m.text.trim().isNotEmpty ? m.text : '[非文本消息]';
}

/// 服务端 messageId(非空、非预留态 `0`、非本地临时 `local-`)。与 controller `_isServerId` 同口径。
bool _isServerMessageId(String id) =>
    id.isNotEmpty && id != '0' && !id.startsWith('local-');

/// 消息身份键(P2 定位):用于主聊天区 `GlobalKey` 映射。优先级与 controller 去重一致:
/// `clientMsgNo` 非空 > 服务端 `messageId` > 本地 `messageId`。同一条消息(含 pending→sent
/// 对账)`clientMsgNo` 不变 → 键稳定。
String imMessageIdentity(ImMessage m) {
  if (m.clientMsgNo.isNotEmpty) return 'cmn:${m.clientMsgNo}';
  if (_isServerMessageId(m.messageId)) return 'srv:${m.messageId}';
  return 'loc:${m.messageId}';
}

/// 在 [list] 中按与 controller 去重一致的回退链找 [target] 的下标;未命中 → -1。
/// 链:`clientMsgNo`(非空)> 服务端 `messageId` > 精确 `messageId`。
int findImMessageIndex(List<ImMessage> list, ImMessage target) {
  if (target.clientMsgNo.isNotEmpty) {
    final i = list.indexWhere(
        (e) => e.clientMsgNo.isNotEmpty && e.clientMsgNo == target.clientMsgNo);
    if (i >= 0) return i;
  }
  if (_isServerMessageId(target.messageId)) {
    final i = list.indexWhere((e) =>
        _isServerMessageId(e.messageId) && e.messageId == target.messageId);
    if (i >= 0) return i;
  }
  if (target.messageId.isNotEmpty) {
    final i = list.indexWhere((e) => e.messageId == target.messageId);
    if (i >= 0) return i;
  }
  return -1;
}

/// 离屏定位最多重试次数(P2)。`ListView.builder` 不 build 离屏 item,目标 `GlobalKey.currentContext`
/// 为 null。消息高度可变 → 单点比例估算可能偏差大,故每次 retry 用 [expandingProbeOffset]
/// 围绕估算点做 **± 扩张搜索**(estimated → ±½视口 → ±1视口 …),覆盖足够窗口;
/// 次数有限(`kLocateMaxAttempts`),用尽仍未 build 出目标 → no-op(**best-effort**,不保证任意可变高度都命中)。
const int kLocateMaxAttempts = 6;

/// 比例估算的中心偏移(P2 离屏定位,纯函数)。主聊天区为**正序** `ListView`(index0 在顶 / 最旧,
/// `maxScrollExtent` 在底 / 最新),故中心 ≈ `index/(itemCount-1) * maxScrollExtent`,clamp 到
/// `[0, maxScrollExtent]`。`itemCount<=1` 或 `maxScrollExtent<=0`(内容未溢出)→ 0。
double estimateHistoryScrollOffset({
  required int index,
  required int itemCount,
  required double maxScrollExtent,
}) {
  if (maxScrollExtent <= 0 || itemCount <= 1) return 0;
  final frac = index / (itemCount - 1);
  final off = frac * maxScrollExtent;
  if (off <= 0) return 0;
  if (off >= maxScrollExtent) return maxScrollExtent;
  return off;
}

/// 第 [attempt] 次尝试围绕 [estimated] 的探测偏移(**± 扩张搜索**,纯函数)。
/// 消息高度可变时单点估算可能 build 不出目标,故按视口步长向两侧扩张:
/// `attempt 0 → estimated`;`1 → +½视口`;`2 → -½视口`;`3 → +1视口`;`4 → -1视口`;`5 → +1½视口`…
/// 每次返回**不同**偏移(避免重复 jump 同一点),clamp 到 `[0, maxScrollExtent]`。
double expandingProbeOffset({
  required double estimated,
  required int attempt,
  required double viewport,
  required double maxScrollExtent,
}) {
  double delta;
  if (attempt <= 0) {
    delta = 0;
  } else {
    final ring = (attempt + 1) ~/ 2; // 1,1,2,2,3,3...
    final sign = attempt.isOdd ? 1.0 : -1.0; // 奇:+ 偶:-
    delta = sign * ring * (viewport / 2);
  }
  final off = estimated + delta;
  if (off <= 0) return 0;
  if (off >= maxScrollExtent) return maxScrollExtent;
  return off;
}

/// 单次离屏定位尝试(P2,纯逻辑,人↔人 / 群聊共用)。先 [probeContext] 探目标是否已 build:
/// 命中 → [onVisible](调用方做 `ensureVisible` + 高亮)并返回 `true`;未命中且未达 [maxAttempts]
/// → [onApproxScroll](近似滚动,调用方负责下一帧 retry)返回 `false`;已达上限 → 不再滚动、返回 `false`。
/// 调度(postFrame / delay)由调用方注入,便于 pane 用真实帧、测试同步连调。
bool runLocateAttempt({
  required int attempt,
  required bool Function() probeContext,
  required void Function() onVisible,
  required void Function() onApproxScroll,
  int maxAttempts = kLocateMaxAttempts,
}) {
  if (probeContext()) {
    onVisible();
    return true;
  }
  if (attempt >= maxAttempts) return false; // 用尽,放弃滚动
  onApproxScroll();
  return false;
}

/// `context.currentContext != null` 只能证明 Element 还在,不能证明它的
/// RenderObject 已 attach 到渲染树——虚拟化列表回收/重建的窗口期内两者会
/// 短暂不一致。调用 `Scrollable.ensureVisible` 前用这个再确认一遍,避免撞上
/// `ScrollPosition.ensureVisible` 内 `assert(object.attached)`。
bool isRenderObjectAttached(BuildContext? context) {
  if (context == null) return false;
  final renderObject = context.findRenderObject();
  return renderObject != null && renderObject.attached;
}
