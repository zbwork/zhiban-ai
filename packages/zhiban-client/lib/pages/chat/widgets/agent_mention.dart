import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'messages/components/chat_avatar.dart';

/// WuKong 群聊 @ 输入与渲染辅助(ADR-0026 / F09 P3-3)。
///
/// mention 是**结构化实体**(type+id+name),不只靠名字正则:
///   - 客户端发送时在 content 保留可读 `@名字` 文本, 同时附 payload.mentions 元数据;
///   - 后端 metadata 优先(只 type=agent 触发)、文本 parser 兜底;
///   - @所有人 仅群内 active human 提醒/展示语义, 不触发任何 Agent。

enum MentionType { all, human, agent }

/// 群内一个可 @ 的实体(所有人 / 员工 / 数字员工)。
class MentionCandidate {
  const MentionCandidate({
    required this.type,
    required this.id, // all="all"; human=account_uuid; agent=agent_uuid
    required this.displayName,
    this.avatar,
  });

  final MentionType type;
  final String id;
  final String displayName;
  final String? avatar;

  /// 类型标签(右侧小字)。
  String get subtitle {
    switch (type) {
      case MentionType.all:
        return '所有人';
      case MentionType.human:
        return '员工';
      case MentionType.agent:
        return '数字员工';
    }
  }

  String get typeString {
    switch (type) {
      case MentionType.all:
        return 'all';
      case MentionType.human:
        return 'human';
      case MentionType.agent:
        return 'agent';
    }
  }

  Map<String, dynamic> toPayload() =>
      {'type': typeString, 'id': id, 'name': displayName};
}

/// @ 候选面板用的固定"所有人"项。
const MentionCandidate kMentionAll =
    MentionCandidate(type: MentionType.all, id: 'all', displayName: '所有人');

bool messageMentionsMe(
  List<Map<String, dynamic>> mentions,
  String selfAccountUuid,
) {
  if (mentions.isEmpty || selfAccountUuid.isEmpty) return false;
  for (final m in mentions) {
    final type = (m['type'] ?? '').toString();
    if (type == 'all') return true;
    if (type == 'human' && (m['id'] ?? '').toString() == selfAccountUuid) {
      return true;
    }
  }
  return false;
}

/// 解析 Agent 群回复(type=111)的 human mentions，并用当前群成员名覆盖 payload 快照名。
/// ID 权威；不在当前 active 成员映射中的 ID 不展示，避免旧/伪造 mention 泄露名称。
List<String> groupReplyHumanMentionNames(
  List<Map<String, dynamic>> mentions,
  Map<String, String> activeHumanNamesById,
) {
  final out = <String>[];
  final seen = <String>{};
  for (final mention in mentions) {
    if ((mention['type'] ?? '').toString() != 'human') continue;
    final id = (mention['id'] ?? '').toString().trim();
    if (id.isEmpty || !seen.add(id)) continue;
    final name = activeHumanNamesById[id]?.trim() ?? '';
    if (name.isNotEmpty) out.add(name);
  }
  return out;
}

String groupReplyMentionPrefix(List<String> names) =>
    names.map((name) => '@$name').join(' ');

/// Agent 群回复首块是可见文本 / Markdown 时，mention 与正文共用首行；
/// 表单、表格等独立富组件仍保持块级布局。
bool groupReplyMentionCanShareFirstLine(
  List<Map<String, dynamic>> blocks
) {
  if (blocks.isEmpty) return false;
  final first = blocks.first;
  final type = (first['type'] ?? '').toString().trim().toLowerCase();
  if (type.isNotEmpty &&
      type != 'markdown' &&
      type != 'plain' &&
      type != 'text') {
    return false;
  }
  final content = (first['text'] ?? first['markdown'] ?? '').toString().trim();
  return content.isNotEmpty;
}

/// 光标前未完成的 @mention token(start=`@` 下标,query=`@` 与光标间文本)。
class MentionQuery {
  const MentionQuery(this.start, this.query);
  final int start;
  final String query;
}

/// 检测光标前是否存在未完成的 `@mention`:
///   - 从光标往前找最近的 `@`;
///   - `@` 是输入框里的显式候选入口,不要求前置空格;
///   - `@` 与光标之间不含空白 / 换行 / 第二个 `@`。
///
/// email / 未知 token 的防误触不由候选开关承担:发送时只把候选选中实体或
/// 精确命中当前群成员名的 token 编码到 mentions,后端文本兜底仍保留 email-safe 边界。
MentionQuery? detectMention(String text, int caret) {
  if (caret < 0 || caret > text.length) caret = text.length;
  final before = text.substring(0, caret);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  final token = before.substring(at + 1);
  for (final ch in token.split('')) {
    if (' \n\t，,。.；;@'.contains(ch)) return null;
  }
  return MentionQuery(at, token);
}

/// 按 query 过滤候选(query 空 → 全部;否则按名字包含,忽略大小写)。@所有人 永远命中空 query
/// 且当 query 是"所"/"所有人"等前缀时命中。
List<MentionCandidate> filterCandidates(
    List<MentionCandidate> all, String query) {
  final q = query.trim().toLowerCase();
  final out = <MentionCandidate>[];
  for (final c in all) {
    if (c.displayName.trim().isEmpty) continue;
    if (q.isEmpty || c.displayName.toLowerCase().contains(q)) out.add(c);
  }
  return out;
}

/// 候选排序:@所有人 置顶, 再员工, 再数字员工(飞书式)。
List<MentionCandidate> sortMentionCandidates(List<MentionCandidate> in_) {
  int rank(MentionType t) =>
      t == MentionType.all ? 0 : (t == MentionType.human ? 1 : 2);
  final out = [...in_];
  out.sort((a, b) => rank(a.type).compareTo(rank(b.type)));
  return out;
}

class MentionInsert {
  const MentionInsert(this.text, this.caret);
  final String text;
  final int caret;
}

const TextStyle kMentionInputTextStyle = TextStyle(
  fontSize: 15,
  height: 1.45,
  color: Color(0xFF111827),
);

/// 计算 `@token` 在输入框文本区内的位置。用于把候选浮层锚到当前 `@` 上方,
/// 而不是固定在输入框左侧。
Offset measureMentionTokenOffset({
  required String text,
  required int textOffset,
  required double maxWidth,
  TextStyle style = kMentionInputTextStyle,
}) {
  final safeOffset = textOffset.clamp(0, text.length);
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: maxWidth < 0 ? 0 : maxWidth);
  return painter.getOffsetForCaret(
    TextPosition(offset: safeOffset),
    Rect.fromLTWH(0, 0, 1, style.fontSize ?? 15),
  );
}

/// 把光标前的 `@token` 替换为 `@名字 `(末尾补空格)。
MentionInsert applyMention(
    String text, int caret, MentionQuery q, String displayName) {
  if (caret < 0 || caret > text.length) caret = text.length;
  final insert = '@$displayName ';
  final newText = text.substring(0, q.start) + insert + text.substring(caret);
  return MentionInsert(newText, q.start + insert.length);
}

/// 用户经候选面板**选中**的 mention 实体(保留点选时的真实身份 type+id,而非发送时按名字重算)。
/// 绑定到**本次插入的具体 occurrence**(start..end 区间 + token),发送时校验该区间文本仍是
/// 原 token 才生效——避免"删除后重新手打同名 @名字"复活旧 picked 的错误身份。
class PickedMention {
  const PickedMention({
    required this.candidate,
    required this.token,
    required this.start,
    required this.end,
  });
  final MentionCandidate candidate;
  final String token; // 形如 "@陈启航"(不含尾随空格)
  final int start; // 插入时 `@` 在文本中的下标
  final int end; // start + token.length

  /// 该 picked 在当前文本里是否仍原位有效(区间合法且子串恰为原 token)。
  bool isLiveIn(String text) {
    if (start < 0 || end > text.length || start >= end) return false;
    return text.substring(start, end) == token;
  }

  /// 区间整体平移 delta(token 前发生编辑时,跟随文本移动)。
  PickedMention shifted(int delta) => PickedMention(
        candidate: candidate,
        token: token,
        start: start + delta,
        end: end + delta,
      );
}

class MentionDeletionExpansion {
  const MentionDeletionExpansion({required this.text, required this.caret});
  final String text;
  final int caret;
}

MentionDeletionExpansion? expandPartialMentionDeletion(
  List<PickedMention> picked,
  String oldText,
  String newText,
) {
  if (picked.isEmpty || newText.length >= oldText.length) return null;
  final oldLen = oldText.length;
  final newLen = newText.length;
  final minLen = oldLen < newLen ? oldLen : newLen;
  var p = 0;
  while (p < minLen && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
    p++;
  }
  var s = 0;
  while (s < minLen - p &&
      oldText.codeUnitAt(oldLen - 1 - s) ==
          newText.codeUnitAt(newLen - 1 - s)) {
    s++;
  }
  var unionStart = p;
  var unionEnd = oldLen - s;
  if (unionStart >= unionEnd) return null;

  var matched = false;
  var changed = true;
  while (changed) {
    changed = false;
    for (final m in picked) {
      final effectiveEnd =
          m.end < oldLen && oldText[m.end] == ' ' ? m.end + 1 : m.end;
      final overlaps = unionStart < effectiveEnd && unionEnd > m.start;
      final fullyCovered = unionStart <= m.start && unionEnd >= effectiveEnd;
      if (!overlaps || fullyCovered) continue;
      matched = true;
      if (m.start < unionStart) {
        unionStart = m.start;
        changed = true;
      }
      if (effectiveEnd > unionEnd) {
        unionEnd = effectiveEnd;
        changed = true;
      }
    }
  }
  if (!matched) return null;

  return MentionDeletionExpansion(
    text: oldText.substring(0, unionStart) + oldText.substring(unionEnd),
    caret: unionStart,
  );
}

/// 输入文本变化时维护 picked mention 的 occurrence 区间(纯函数,便于单测)。
///
/// 用最小变更区间(commonPrefix / commonSuffix)对每个 picked:
///   - 编辑完全在 token 前(changedOldEnd <= start)→ 区间平移 delta;
///   - 编辑完全在 token 后(changedOldStart >= end)→ 区间不变;
///   - 编辑与 token 区间相交 → 该 picked 失效(丢弃,**不**复活)。
/// 末了再用 [PickedMention.isLiveIn] 对新文本做兜底校验。
List<PickedMention> reconcilePickedMentions(
  List<PickedMention> picked,
  String oldText,
  String newText,
) {
  if (picked.isEmpty || oldText == newText) return picked;
  final oldLen = oldText.length;
  final newLen = newText.length;
  final minLen = oldLen < newLen ? oldLen : newLen;
  var p = 0;
  while (p < minLen && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
    p++;
  }
  var s = 0;
  while (s < minLen - p &&
      oldText.codeUnitAt(oldLen - 1 - s) ==
          newText.codeUnitAt(newLen - 1 - s)) {
    s++;
  }
  final changedOldStart = p;
  final changedOldEnd = oldLen - s;
  final delta = newLen - oldLen;

  final out = <PickedMention>[];
  for (final m in picked) {
    PickedMention? next;
    if (changedOldEnd <= m.start) {
      next = m.shifted(delta); // 编辑在 token 前 → 平移
    } else if (changedOldStart >= m.end) {
      next = m; // 编辑在 token 后 → 不变
    } else {
      next = null; // 与 token 相交 → 失效
    }
    if (next != null && next.isLiveIn(newText)) out.add(next);
  }
  return out;
}

/// 可见文本中一个精确命中当前可 @ 名字的 occurrence。
///
/// 只要 `@` 后紧跟已知名字且名字后到达 token 边界就命中;不要求 `@` 前有空格。
/// 因为只扫描已知群成员名,普通 email / 未知 `@token` 不会产生 mention。
class _KnownMentionMatch {
  const _KnownMentionMatch({
    required this.name,
    required this.start,
    required this.end,
  });

  final String name;
  final int start;
  final int end;
}

bool _isMentionTokenEnd(String char) => ' \n\t，,。.；;@'.contains(char);

bool _looksLikeEmailAt(String text, int at) {
  if (at <= 0 || at >= text.length - 1) return false;
  final localChar = text[at - 1];
  if (!RegExp(r'[A-Za-z0-9._%+\-]').hasMatch(localChar)) return false;
  final domainMatch = RegExp(r'^[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
      .firstMatch(text.substring(at + 1));
  if (domainMatch == null) return false;
  final emailEnd = at + 1 + domainMatch.end;
  return emailEnd == text.length || _isMentionTokenEnd(text[emailEnd]);
}

List<_KnownMentionMatch> _knownMentionMatches(
  String text,
  Iterable<String> knownNames,
) {
  if (text.isEmpty) return const <_KnownMentionMatch>[];
  final names = knownNames
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (names.isEmpty) return const <_KnownMentionMatch>[];

  final lowerText = text.toLowerCase();
  final out = <_KnownMentionMatch>[];
  var searchFrom = 0;
  while (searchFrom < text.length) {
    final at = text.indexOf('@', searchFrom);
    if (at < 0) break;
    if (_looksLikeEmailAt(text, at)) {
      searchFrom = at + 1;
      continue;
    }
    _KnownMentionMatch? hit;
    for (final name in names) {
      final nameStart = at + 1;
      final end = nameStart + name.length;
      if (end > text.length ||
          !lowerText.startsWith(name.toLowerCase(), nameStart)) {
        continue;
      }
      if (end < text.length && !_isMentionTokenEnd(text[end])) continue;
      hit = _KnownMentionMatch(name: name, start: at, end: end);
      break;
    }
    if (hit == null) {
      searchFrom = at + 1;
      continue;
    }
    out.add(hit);
    searchFrom = hit.end;
  }
  return out;
}

/// 发送时生成结构化 mentions:**picked 优先**(保留用户点选的真实实体身份,解决 human/agent
/// 同名时被名字正则误判的问题),再用文本 `@名字` 兜底手打项。
///
/// 规则:
///  1. picked 仅当其**原插入区间**在当前文本里仍是原 token(`isLiveIn`)才保留;用户删除/改动
///     该 occurrence → 失效(**不**回退按 `@名字` 全文 contains,避免复活已删除的旧身份)。
///  2. 被存活 picked 占用的 @名字不再走文本兜底(避免同名实体重复 / 误判成另一类型)。
///  3. 其余手打 `@名字` 用 [mentionsFromText] 同款名字匹配补齐。
///  4. 按 `type:id` 去重,picked 优先,保留出现顺序。
List<MentionCandidate> mentionsForSend(
  String text,
  List<PickedMention> picked,
  List<MentionCandidate> candidates,
) {
  final out = <MentionCandidate>[];
  final seenKey = <String>{};
  final claimedNames = <String>{}; // 被存活 picked 占用的 @名字(同名不再走文本兜底)
  final candidateByName = <String, MentionCandidate>{};
  for (final candidate in candidates) {
    candidateByName.putIfAbsent(
      candidate.displayName.trim().toLowerCase(),
      () => candidate,
    );
  }
  String keyOf(MentionCandidate c) => '${c.typeString}:${c.id}';

  for (final p in picked) {
    if (!p.isLiveIn(text)) continue; // 原 occurrence 已删除/漂移 → 失效, 不复活
    claimedNames.add(p.candidate.displayName.toLowerCase());
    if (seenKey.add(keyOf(p.candidate))) out.add(p.candidate);
  }
  for (final match in _knownMentionMatches(text, candidateByName.keys)) {
    final normalizedName = match.name.toLowerCase();
    if (claimedNames.contains(normalizedName)) continue; // picked 已占用该名字
    final hit = candidateByName[normalizedName];
    if (hit == null) continue;
    if (seenKey.add(keyOf(hit))) out.add(hit);
  }
  return out;
}

/// 从最终文本解析 @token, 与候选名字匹配, 产出结构化 mentions 元数据(去重保留顺序)。
/// 纯手打兜底用;经候选选中的实体走 [mentionsForSend] 以保留真实身份。"所有人" → all。
List<MentionCandidate> mentionsFromText(
    String text, List<MentionCandidate> candidates) {
  final out = <MentionCandidate>[];
  final seen = <String>{};
  final candidateByName = <String, MentionCandidate>{};
  for (final candidate in candidates) {
    candidateByName.putIfAbsent(
      candidate.displayName.trim().toLowerCase(),
      () => candidate,
    );
  }
  for (final match in _knownMentionMatches(text, candidateByName.keys)) {
    final hit = candidateByName[match.name.toLowerCase()];
    if (hit == null) continue;
    final key = '${hit.typeString}:${hit.id}';
    if (seen.add(key)) out.add(hit);
  }
  return out;
}

/// 富文本渲染:把文本中命中候选名字的 `@token` 高亮成蓝色 span(其余普通)。
/// mention 实体集合用名字匹配(含"所有人");rendering 不依赖 incoming metadata, 兜底稳健。
List<TextSpan> mentionHighlightSpans(
  String text,
  Set<String> mentionNames, {
  TextStyle? base,
  TextStyle? highlight,
}) {
  final baseStyle = base ??
      const TextStyle(fontSize: 14, color: Color(0xFF1D2129), height: 1.5);
  final hi = highlight ??
      const TextStyle(
          fontSize: 14,
          color: Color(0xFF2563EB),
          height: 1.5,
          fontWeight: FontWeight.w500);
  final spans = <TextSpan>[];
  var last = 0;
  for (final match in _knownMentionMatches(text, mentionNames)) {
    if (match.start > last) {
      spans.add(
          TextSpan(text: text.substring(last, match.start), style: baseStyle));
    }
    spans
        .add(TextSpan(text: text.substring(match.start, match.end), style: hi));
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: baseStyle));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: baseStyle));
  return spans;
}

/// 候选栏:候选为空时渲染空(无可 @ 实体 → 不显示)。
enum MentionCandidateTab { all, human, agent }

MentionCandidateTab nextMentionCandidateTab(
  MentionCandidateTab current, {
  bool reverse = false,
}) {
  const tabs = MentionCandidateTab.values;
  final currentIndex = tabs.indexOf(current);
  final nextIndex = reverse
      ? (currentIndex - 1 + tabs.length) % tabs.length
      : (currentIndex + 1) % tabs.length;
  return tabs[nextIndex];
}

List<MentionCandidate> visibleMentionCandidates(
  List<MentionCandidate> candidates,
  MentionCandidateTab tab,
) {
  return switch (tab) {
    MentionCandidateTab.all => candidates,
    MentionCandidateTab.human =>
      candidates.where((c) => c.type == MentionType.human).toList(),
    MentionCandidateTab.agent =>
      candidates.where((c) => c.type == MentionType.agent).toList(),
  };
}

/// 计算 @ 候选浮层横向位置:
/// - 常规情况下左边贴当前 @ 光标;
/// - 靠右时只在输入框边界内收,不跑到右侧群成员栏/页面外;
/// - 输入框太窄时保底贴左边界。
double resolveMentionPopupLeft({
  required double desiredLeft,
  required double popupWidth,
  required double boundaryLeft,
  required double boundaryRight,
  double margin = 8,
}) {
  final minLeft = boundaryLeft + margin;
  final maxLeft = boundaryRight - popupWidth - margin;
  if (maxLeft < minLeft) return minLeft;
  return desiredLeft.clamp(minLeft, maxLeft).toDouble();
}

class MentionBar extends StatefulWidget {
  const MentionBar({
    super.key,
    required this.candidates,
    required this.onPick,
    this.activeTab,
    this.onTabChange,
    this.selected,
    this.onHoverCandidate,
  });

  final List<MentionCandidate> candidates;
  final ValueChanged<MentionCandidate> onPick;
  final MentionCandidateTab? activeTab;
  final ValueChanged<MentionCandidateTab>? onTabChange;
  final MentionCandidate? selected;
  final ValueChanged<MentionCandidate>? onHoverCandidate;

  @override
  State<MentionBar> createState() => _MentionBarState();
}

class _MentionBarState extends State<MentionBar> {
  MentionCandidateTab _tab = MentionCandidateTab.all;

  MentionCandidateTab get _effectiveTab => widget.activeTab ?? _tab;

  List<MentionCandidate> get _visibleCandidates {
    return visibleMentionCandidates(widget.candidates, _effectiveTab);
  }

  bool _isSelected(MentionCandidate c) {
    final s = widget.selected;
    return s != null && s.type == c.type && s.id == c.id;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.candidates.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        key: const ValueKey('mention-popup-surface'),
        constraints: const BoxConstraints(
          minWidth: 320,
          maxWidth: 400,
          maxHeight: 260,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE1E7F0)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.14),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _tabBar(),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                    itemCount: _visibleCandidates.length,
                    itemBuilder: (context, i) {
                      final c = _visibleCandidates[i];
                      final selected = _isSelected(c);
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => widget.onHoverCandidate?.call(c),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.onPick(c),
                          child: Container(
                            key: selected
                                ? const ValueKey('mention-selected-row')
                                : null,
                            height: 36,
                            margin: const EdgeInsets.only(bottom: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFF408CFF)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                _avatar(c),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    c.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.25,
                                      color: selected
                                          ? Colors.white
                                          : const Color(0xFF1D2129),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Text(
                                  c.subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.2,
                                    color: selected
                                        ? Colors.white
                                        : (c.type == MentionType.agent
                                            ? const Color(0xFF2563EB)
                                            : const Color(0xFF86909C)),
                                    fontWeight: c.type == MentionType.agent
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabBar() {
    final humanCount =
        widget.candidates.where((c) => c.type == MentionType.human).length;
    final agentCount =
        widget.candidates.where((c) => c.type == MentionType.agent).length;
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEFF1F5))),
      ),
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            _tabItem(MentionCandidateTab.all, '全部 ${widget.candidates.length}'),
            _tabItem(MentionCandidateTab.human, '成员 $humanCount'),
            _tabItem(MentionCandidateTab.agent, '数字员工 $agentCount'),
          ],
        ),
      ),
    );
  }

  Widget _tabItem(MentionCandidateTab tab, String label) {
    final selected = _effectiveTab == tab;
    return Expanded(
      child: InkWell(
        onTap: () {
          if (widget.activeTab == null) {
            setState(() => _tab = tab);
          }
          widget.onTabChange?.call(tab);
        },
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  color: selected
                      ? const Color(0xFF0F72FF)
                      : const Color(0xFF86909C),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              const Positioned(
                left: 16,
                right: 16,
                bottom: 0,
                child: SizedBox(
                  height: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xFF0F72FF)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(MentionCandidate c) {
    // @所有人 用通用 icon, 不用普通头像。
    if (c.type == MentionType.all) {
      return Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: Color(0xFFEAF2FF),
          shape: BoxShape.circle,
        ),
        child: const Icon(CupertinoIcons.person_2_fill,
            size: 14, color: Color(0xFF2563EB)),
      );
    }
    return ChatAvatar(
      url: (c.avatar ?? '').isEmpty ? null : c.avatar,
      fallbackText: c.displayName,
      kind: c.type == MentionType.agent
          ? ChatAvatarKind.agent
          : ChatAvatarKind.user,
      size: 24,
    );
  }
}
