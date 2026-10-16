import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/widgets/group_grid_avatar.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('group avatar resolves protected message-file avatars with auth',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppConfig.storageTokenKey: 'token-1',
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: GroupGridAvatar(
          members: [
            GroupAvatarMember(
              avatarUrl: '/message-files/avatar-1/preview',
              name: '销售专员',
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final image = tester.widget<UiNetworkImage>(find.byType(UiNetworkImage));
    expect(
      Uri.parse(image.imageUrl).path,
      '/api/agent-bus/v1/message-files/avatar-1/preview',
    );

    final cached =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(cached.httpHeaders, {'Authorization': 'Bearer token-1'});
  });
}
