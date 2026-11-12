import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:nexwork/pages/login/login_page.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_page.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/server_connection/workspace_connection_scope.dart';
import 'package:zhiban_client/services/server_connection.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_core/network/request_interceptor.dart';

void main() {
  testWidgets(
      'local → server login → local → different server isolates state and preserves local data',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      ServerConnection.addressKey:
          'https://remembered.example/api/agent-bus/v1',
      AppConfig.storageTokenKey: 'old-token',
      AppConfig.storageRefreshTokenKey: 'old-refresh',
      'model_service.providers.v1.community-local': '[]',
    });
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final support = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('server-workspace-test-')))!;
    final messenger = tester.binding.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const windowChannel = MethodChannel('window_manager');
    const screenChannel =
        MethodChannel('dev.leanflutter.plugins/screen_retriever');
    const secureChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => support.path);
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'getBounds') {
        return {'x': 0.0, 'y': 0.0, 'width': 1080.0, 'height': 820.0};
      }
      if (call.method == 'getSize') return {'width': 1080.0, 'height': 820.0};
      if (call.method == 'getPosition') return {'x': 0.0, 'y': 0.0};
      return null;
    });
    messenger.setMockMethodCallHandler(
        screenChannel,
        (_) async => {
              'id': 'test-display',
              'size': {'width': 1440.0, 'height': 900.0},
              'visiblePosition': {'dx': 0.0, 'dy': 0.0},
              'visibleSize': {'width': 1440.0, 'height': 900.0},
            });
    messenger.setMockMethodCallHandler(secureChannel, (_) async => null);
    final rtcChannels = [
      const MethodChannel('easyo/rtc/incoming_panel/events'),
      const MethodChannel('easyo/rtc/meeting/events'),
      const MethodChannel('easyo/rtc/incoming_panel'),
      const MethodChannel('easyo/rtc/meeting'),
    ];
    for (final channel in rtcChannels) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    debugRealtimeLogoutOverride = () async {};
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(screenChannel, null);
      messenger.setMockMethodCallHandler(secureChannel, null);
      for (final channel in rtcChannels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      databaseFactory = null;
      debugRealtimeLogoutOverride = null;
      AppConfig.serverApiUrl = null;
      AppConfig.connectionChanging = false;
      Request.resetForConnection();
      RequestInterceptor.clearTokenCache();
      await support.delete(recursive: true);
      await tester.binding.setSurfaceSize(null);
    });
    final store = (await tester.runAsync(() => LocalWorkspaceStore.open(
          factory: databaseFactoryFfi,
          path: '${support.path}/community_workspace_v1.db',
        )))!;
    await tester.runAsync(() => store.db.insert('employees', {
          'id': 'local-employee',
          'name': '保留的本地员工',
          'prompt': 'local-only',
          'provider_id': '',
          'model_id': '',
          'skills': '[]',
          'created': 1,
        }));
    await tester.binding.setSurfaceSize(const Size(1080, 820));
    await tester.pumpWidget(const CommunityWorkspaceApp());
    Future<void> settle() async {
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
      }
    }

    await settle();
    expect(find.text('连接服务器'), findsNothing);
    await tester.tap(find.byType(SidebarUserMini));
    await tester.pumpAndSettle();
    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.text('接入指南'), findsOneWidget);
    await tester.tap(find.text('连接服务器'));
    await tester.pumpAndSettle();
    expect(find.text('检测并连接'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);
    expect(AppConfig.serverWorkspace, isFalse);
    LocalWorkspaceController controller() => ProviderScope.containerOf(
            tester.element(find.byType(LocalWorkspacePage)),
            listen: false)
        .read(localWorkspaceProvider)
        .requireValue;
    final initialController = controller();

    Future<void> connect(String address) async {
      final connection = tester.widget<WorkspaceConnectionScope>(
          find.byType(WorkspaceConnectionScope));
      final pending = connection.connect(address);
      await settle();
      await pending;
      await settle();
    }

    await connect('https://a.example');
    expect(find.text('工作区切换失败，请返回本地后重试'), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('服务器 · a.example'), findsOneWidget);
    // Disposing the old controller closes its execution owner.
    expect(find.byType(LocalWorkspacePage), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(prefs.getString(AppConfig.storageRefreshTokenKey), isNull);
    // Simulate a session; returning must clear credentials without touching local content.
    await prefs.setString(AppConfig.storageTokenKey, 'server-a-token');
    RequestInterceptor.primeToken('server-a-token');
    await tester.tap(find.text('返回本地'));
    await settle();
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('连接服务器'), findsNothing);
    expect(find.byType(SidebarUserMini), findsOneWidget);
    expect(identical(controller(), initialController), isFalse);
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(RequestInterceptor.cachedToken, isNull);
    expect(prefs.getString('model_service.providers.v1.community-local'), '[]');
    final employees = await tester.runAsync(() => store.db.query('employees'));
    expect(employees!.single['name'], '保留的本地员工');
    await connect('https://b.example');
    expect(find.text('服务器 · b.example'), findsOneWidget);
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(store.db.close);
  });
}
