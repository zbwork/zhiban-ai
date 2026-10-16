import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('ChatAvatar loads protected message-file avatars with auth',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppConfig.storageTokenKey: 'token-1',
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ChatAvatar(url: '/message-files/avatar-1/preview'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final image = tester.widget<UiNetworkImage>(find.byType(UiNetworkImage));
    expect(image.imageUrl, contains('/message-files/avatar-1/preview'));
    expect(image.httpHeaders, {'Authorization': 'Bearer token-1'});
  });
}
