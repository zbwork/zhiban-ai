import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';

class NewEmployeeService extends OpenClawChatService {
  int managementDetailRequests = 0;
  bool failList = false;

  @override
  Future<List<AgentItem>> listAgents() async {
    if (failList) throw StateError('temporary list failure');
    return [];
  }

  @override
  Future<AgentItem> getAgent(String id) async {
    managementDetailRequests++;
    throw StateError('management detail must not hydrate conversations');
  }
}

class VisibleEmployeeService extends ContactsService {
  final response = Completer<AgentItem>();
  int requests = 0;
  bool failSynchronously = false;
  bool? lastSilent;

  @override
  Future<ContactAgent> agent(String id, {bool silent = false}) async {
    requests++;
    lastSilent = silent;
    if (failSynchronously) throw StateError('temporary detail failure');
    final item = await response.future;
    return ContactAgent.fromAgentItem(item);
  }
}

void main() {
  test('visible employee restores local controls after initial list failure',
      () async {
    final managementService = NewEmployeeService()..failList = true;
    final service = VisibleEmployeeService();
    final container = ProviderContainer(overrides: [
      chatServiceProvider.overrideWithValue(managementService),
      contactsServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    await expectLater(container.read(agentsProvider.future), throwsStateError);
    expect(container.read(agentsProvider).hasError, isTrue);
    service.response.complete(AgentItem.fromJson({
      'uuid': 'new-local',
      'name': '本地秘书',
      'execution_locus': 'local',
      'local_engine': 'codex_app_server',
    }));
    await container.read(agentsProvider.notifier).ensureAgent('new-local');
    final employee = container.read(agentsProvider).requireValue.single;
    expect(employee.executionLocus, 'local');
    expect(employee.localEngine, 'codex_app_server');
    expect(employee.hasConversationModels, isTrue);
    expect(managementService.managementDetailRequests, 0);
  });

  test('failed employee hydration can retry after a synchronous error',
      () async {
    final managementService = NewEmployeeService();
    final service = VisibleEmployeeService()..failSynchronously = true;
    final container = ProviderContainer(
      overrides: [
        chatServiceProvider.overrideWithValue(managementService),
        contactsServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await container.read(agentsProvider.future);
    final notifier = container.read(agentsProvider.notifier);
    await notifier.ensureAgent('new-local');
    service.failSynchronously = false;
    service.response.complete(AgentItem.fromJson(
        {'uuid': 'new-local', 'name': '本地秘书', 'execution_locus': 'local'}));
    await notifier.ensureAgent('new-local');
    expect(service.requests, 2);
    expect(service.lastSilent, isTrue);
    expect(managementService.managementDetailRequests, 0);
    expect(container.read(agentsProvider).requireValue.single.executionLocus,
        'local');
  });
  test('new cross-device employee hydrates local capabilities with one request',
      () async {
    final managementService = NewEmployeeService();
    final service = VisibleEmployeeService();
    final container = ProviderContainer(
      overrides: [
        chatServiceProvider.overrideWithValue(managementService),
        contactsServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await container.read(agentsProvider.future);
    final notifier = container.read(agentsProvider.notifier);
    final first = notifier.ensureAgent('new-local');
    final second = notifier.ensureAgent('new-local');
    expect(service.requests, 1);
    service.response.complete(AgentItem.fromJson({
      'uuid': 'new-local',
      'name': '本地秘书',
      'execution_locus': 'local',
      'supports_model_selection': true
    }));
    await Future.wait([first, second]);
    final employee = container.read(agentsProvider).requireValue.single;
    expect(employee.executionLocus, 'local');
    expect(employee.supportsModelSelection, isTrue);
    expect(service.lastSilent, isTrue);
    expect(managementService.managementDetailRequests, 0);
    await notifier.ensureAgent('new-local');
    expect(service.requests, 1);
    expect(container.read(selectedAgentProvider).asData?.value, isNull);
  });
}
