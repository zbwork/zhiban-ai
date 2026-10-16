import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_space_members_dialog.dart';

void main() {
  const members = <SpaceMember>[
    SpaceMember(accountUuid: 'owner-uuid', role: 'owner'),
    SpaceMember(accountUuid: 'manager-uuid', role: 'manager'),
    SpaceMember(accountUuid: 'editor-uuid', role: 'editor'),
  ];

  test('existing member ids include the real owner', () {
    expect(
      driveExistingMemberIds(members),
      {'owner-uuid', 'manager-uuid', 'editor-uuid'}
    );
  });

  test('only owner and manager can manage collaborators', () {
    expect(
      canManageDriveMembers(
        currentAccountUuid: 'owner-uuid',
        members: members
      ),
      isTrue,
    );
    expect(
      canManageDriveMembers(
        currentAccountUuid: 'manager-uuid',
        members: members,
      ),
      isTrue,
    );
    expect(
      canManageDriveMembers(
        currentAccountUuid: 'editor-uuid',
        members: members,
      ),
      isFalse,
    );
    expect(
      canManageDriveMembers(
        currentAccountUuid: '',
        members: members
      ),
      isFalse,
    );
  });
}
