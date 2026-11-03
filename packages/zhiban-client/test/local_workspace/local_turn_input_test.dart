import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_turn_input.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';

void main() {
  test('message and persona limits fail before acceptance', () {
    LocalTurnInput.validate('a' * 120100, 'persona');
    expect(() => LocalTurnInput.validate('a' * 150001, ''),
        throwsA(isA<LocalModelException>()));
    expect(() => LocalTurnInput.validate('a', 'p' * 200001),
        throwsA(isA<LocalModelException>()));
  });
  test('history keeps latest complete messages within encoded budget', () {
    final messages = [
      for (var i = 0; i < 100; i++)
        {'role': i.isEven ? 'user' : 'assistant', 'content': '$i${'\n' * 5000}'}
    ];
    final kept = LocalTurnInput.history(messages);
    expect(
        jsonEncode(kept).length, lessThanOrEqualTo(LocalTurnInput.maxHistory));
    expect(kept.length, lessThan(messages.length));
    expect(kept.last, messages.last);
    expect(kept.first['role'], 'user');
  });
}
