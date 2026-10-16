import 'dart:math' as math;

/// 每条聊天 stream 独立持有的正文待显示队列。
///
/// 它不创建 Timer，也不感知 Flutter binding；调用方保证每个 UI frame 最多调用
/// 一次 [takeForFrame]。
///
/// 揭示分两阶段（docs/standards/chat-stream-rendering-standard.md 规则 6）：
/// - 前 [fineGrainedRuneBudget] 个 rune（首屏原地打字 + 越过折叠线后短暂
///   跟滚）：一次追赶周期固定为 16 帧（约 250ms @ 60Hz），每帧按当前积压 /
///   剩余帧数计算取量，因此大突发不会像固定字符打字机一样形成长尾。
///   消息列表以同一常量判定平滑跟随阶段。
/// - 预算耗尽后进入**快速铺出**模式：[takeForFrame] 直接返回全部积压，
///   已到内容立即整批上屏（消息列表同步停跟，增长发生在折叠线以下，
///   不构成可见打字机）。不得持有到终态再铺——那会让前端看起来直接卡住
///   （2026-07-30 第五轮实测被否）。
class ChatAnswerRevealBuffer {
  static const int catchUpFrameBudget = 16;
  static const int fineGrainedRuneBudget = 500;
  static const int _minimumRunesPerFrame = 2;

  final List<int> _runes = <int>[];
  int _readIndex = 0;
  int _framesRemaining = 0;
  int _revealedRuneCount = 0;

  bool get isEmpty => _readIndex >= _runes.length;

  int get pendingRuneCount => _runes.length - _readIndex;

  bool get isFineGrained => _revealedRuneCount < fineGrainedRuneBudget;

  void add(String text) {
    if (text.isEmpty) return;
    final wasEmpty = isEmpty;
    if (wasEmpty) {
      _compact(force: true);
      _framesRemaining = catchUpFrameBudget;
    }
    _runes.addAll(text.runes);
  }

  String takeForFrame() {
    final pending = pendingRuneCount;
    if (pending == 0) return '';
    // 快速铺出模式：已到内容一次性全部返回，不再逐帧播放。
    if (!isFineGrained) return flush();

    if (_framesRemaining <= 0) {
      _framesRemaining = catchUpFrameBudget;
    }
    final adaptive = (pending + _framesRemaining - 1) ~/ _framesRemaining;
    final takeCount =
        math.max(_minimumRunesPerFrame, adaptive).clamp(1, pending);
    final end = _readIndex + takeCount;
    final visible = String.fromCharCodes(_runes.getRange(_readIndex, end));
    _readIndex = end;
    _framesRemaining -= 1;
    _revealedRuneCount += takeCount;

    if (isEmpty) {
      clear();
    } else {
      _compact();
    }
    return visible;
  }

  String flush() {
    if (isEmpty) return '';
    final visible =
        String.fromCharCodes(_runes.getRange(_readIndex, _runes.length));
    _revealedRuneCount += _runes.length - _readIndex;
    clear();
    return visible;
  }

  void clear() {
    _runes.clear();
    _readIndex = 0;
    _framesRemaining = 0;
  }

  void _compact({bool force = false}) {
    if (_readIndex == 0) return;
    if (!force && _readIndex < 1024 && _readIndex * 2 < _runes.length) {
      return;
    }
    _runes.removeRange(0, _readIndex);
    _readIndex = 0;
  }
}
