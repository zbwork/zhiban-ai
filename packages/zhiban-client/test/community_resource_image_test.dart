import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/community_resources.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

void main() {
  for (final legacy in [false, true]) {
    testWidgets('official image strips explicit credentials; legacy=$legacy',
        (tester) async {
      final hash = 'a' * 64;
      final expected =
          '${CommunityResources.agentsBaseUrl}assets/agents/$hash.png';
      await tester.pumpWidget(MaterialApp(
          home: UiNetworkImage(
        imageUrl: legacy
            ? 'https://old.example/api/public/v1/agents/id/avatar/$hash.png'
            : expected,
        httpHeaders: const {
          'Authorization': 'test-only',
          'X-Private': 'test-only'
        },
      )));
      final image =
          tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(image.imageUrl, expected);
      expect(image.httpHeaders, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('private image retains explicit authorization', (tester) async {
    const url = 'https://private.example/message-files/ref/preview';
    await tester.pumpWidget(const MaterialApp(
        home: UiNetworkImage(
      imageUrl: url,
      httpHeaders: {'Authorization': 'test-only'},
    )));
    final image =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.imageUrl, url);
    expect(image.httpHeaders, {'Authorization': 'test-only'});
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
