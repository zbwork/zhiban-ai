import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/contacts/contacts_directory_store.dart';

class FailingContacts extends ContactsService {
  bool fail = true;
  @override
  Future<List<ContactDepartment>> tree() async {
    if (fail) throw StateError('offline');
    return [];
  }

  @override
  Future<List<ContactPerson>> members(
          {String? departmentId,
          String kind = 'all',
          String keyword = ''}) async =>
      [];
}

void main() {
  test('failed refresh propagates once, clears in-flight and can recover',
      () async {
    final service = FailingContacts();
    final store = ContactsDirectoryStore.forService(service);
    await expectLater(store.refresh(), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    service.fail = false;
    final snapshot = await store.refresh();
    expect(store.current, same(snapshot));
    service.fail = true;
    expect(await store.ensureLoaded(), same(snapshot));
    store.refreshInBackground();
    await Future<void>.delayed(Duration.zero);
    expect(store.current, same(snapshot));
  });
}
