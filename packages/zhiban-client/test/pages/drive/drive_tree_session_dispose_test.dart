import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';

class _PendingBootstrapDriveService extends DriveService {
  _PendingBootstrapDriveService(this.completer);

  final Completer<DriveBootstrap> completer;

  @override
  Future<DriveBootstrap> bootstrap() => completer.future;
}

void main() {
  test('session disposal while drive bootstrap is pending does not reuse Ref',
      () async {
    final completer = Completer<DriveBootstrap>();
    final container = ProviderContainer(
      overrides: [
        driveServiceProvider.overrideWithValue(
          _PendingBootstrapDriveService(completer),
        ),
      ],
    );

    final pending = container.read(driveTreeProvider.future);
    container.dispose();
    completer.complete(const DriveBootstrap());

    await expectLater(pending, completion(isA<DriveTreeState>()));
  });
}
