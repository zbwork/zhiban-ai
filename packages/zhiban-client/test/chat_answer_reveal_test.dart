import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/providers/chat_answer_reveal.dart';

void main() {
  group('ChatAnswerRevealBuffer', () {
    test('keeps a low backlog visually fine grained', () {
      final buffer = ChatAnswerRevealBuffer();

      buffer.add('你好');

      expect(buffer.takeForFrame(), '你好');
      expect(buffer.isEmpty, isTrue);
    });

    test('drains a large burst fine grained first then in one final take', () {
      final buffer = ChatAnswerRevealBuffer();
      final answer = List.filled(4096, '长').join();
      buffer.add(answer);

      final visible = StringBuffer();
      var frames = 0;
      while (!buffer.isEmpty &&
          frames < ChatAnswerRevealBuffer.catchUpFrameBudget) {
        final chunk = buffer.takeForFrame();
        expect(chunk, isNotEmpty,
            reason: '快速铺出模式不得空转持有（会看起来卡住）');
        visible.write(chunk);
        frames += 1;
      }

      // 预算耗尽的那一帧直接吐出全部积压，早于 16 帧追赶周期完成。
      expect(visible.toString(), answer);
      expect(buffer.isEmpty, isTrue);
      expect(frames, lessThan(ChatAnswerRevealBuffer.catchUpFrameBudget));
    });

    test('increases the current frame size when more text arrives', () {
      final buffer = ChatAnswerRevealBuffer();
      buffer.add(List.filled(32, '甲').join());

      final first = buffer.takeForFrame();
      buffer.add(List.filled(300, '乙').join());
      final second = buffer.takeForFrame();

      expect(first.runes.length, 2);
      expect(second.runes.length, greaterThan(first.runes.length));
    });

    test('never splits a unicode rune and flush clears pending text', () {
      final buffer = ChatAnswerRevealBuffer();
      buffer.add('😀中文');

      final first = buffer.takeForFrame();
      final rest = buffer.flush();

      expect(first, '😀中');
      expect(rest, '文');
      expect(buffer.isEmpty, isTrue);
    });

    test('clear drops pending text and resets the catch-up cycle', () {
      final buffer = ChatAnswerRevealBuffer();
      buffer.add(List.filled(100, '旧').join());

      buffer.clear();
      buffer.add('新');

      expect(buffer.takeForFrame(), '新');
      expect(buffer.isEmpty, isTrue);
    });

    test('returns everything pending at once after the budget is spent', () {
      final buffer = ChatAnswerRevealBuffer();
      buffer.add(
        List.filled(ChatAnswerRevealBuffer.fineGrainedRuneBudget, '头').join(),
      );
      while (!buffer.isEmpty) {
        buffer.takeForFrame();
      }
      expect(buffer.isFineGrained, isFalse);

      final tail = List.filled(2000, '尾').join();
      buffer.add(tail);

      // 快速铺出：已到内容一次性返回，不持有等终态。
      expect(buffer.takeForFrame(), tail);
      expect(buffer.isEmpty, isTrue);
    });

    test('flush counts toward the fine grained budget', () {
      final buffer = ChatAnswerRevealBuffer();
      buffer.add(
        List.filled(ChatAnswerRevealBuffer.fineGrainedRuneBudget + 1, '整').join(),
      );

      buffer.flush();

      expect(buffer.isFineGrained, isFalse);
    });

    test('a fresh buffer starts fine grained regardless of other streams', () {
      final exhausted = ChatAnswerRevealBuffer()
        ..add(
          List.filled(ChatAnswerRevealBuffer.fineGrainedRuneBudget, '甲').join(),
        )
        ..flush();
      expect(exhausted.isFineGrained, isFalse);

      final fresh = ChatAnswerRevealBuffer();
      fresh.add(List.filled(64, '乙').join());
      expect(fresh.isFineGrained, isTrue);
      expect(fresh.takeForFrame().runes.length, lessThan(64));
    });
  });
}
