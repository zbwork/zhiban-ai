import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/agent_skills_sheet.dart';

void main() {
  test('绑定接口成功后才启动摘要刷新和 runtime ensure，且不等待后台任务', () async {
    final save = Completer<void>();
    final refresh = Completer<void>();
    final ensure = Completer<void>();
    var refreshCalls = 0;
    var ensureCalls = 0;

    var completed = false;
    final submission = submitAgentSkillBindingUpdate(
      saveBindings: () => save.future,
      refreshAgentSummary: () {
        refreshCalls++;
        return refresh.future;
      },
      ensureRuntime: () {
        ensureCalls++;
        return ensure.future;
      },
    ).then((_) => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(refreshCalls, 0);
    expect(ensureCalls, 0);
    expect(completed, isFalse);

    save.complete();
    await submission;
    expect(refreshCalls, 1);
    expect(ensureCalls, 1);
    expect(completed, isTrue);

    refresh.complete();
    ensure.complete();
  });

  test('绑定接口失败时不刷新摘要，也不触发 runtime ensure', () async {
    var refreshCalls = 0;
    var ensureCalls = 0;

    await expectLater(
      submitAgentSkillBindingUpdate(
        saveBindings: () => Future<void>.error(StateError('save failed')),
        refreshAgentSummary: () async => refreshCalls++,
        ensureRuntime: () async => ensureCalls++,
      ),
      throwsStateError,
    );

    expect(refreshCalls, 0);
    expect(ensureCalls, 0);
  });
}
