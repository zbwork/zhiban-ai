import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/app_bootstrap.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/server_connection/workspace_connection_scope.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/server_connection.dart';
import 'package:zhiban_client/services/session_runtime.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

import 'layout/main_layout.dart';
import 'pages/local_coding_tools/local_coding_tools_page.dart';
import 'pages/task/task_page.dart';
import 'routes/app_router.dart';

Future<void> startCommunityWorkspace() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowController.instance.init(hasToken: true);
  runApp(const CommunityWorkspaceApp());
}

class CommunityWorkspaceApp extends StatefulWidget {
  const CommunityWorkspaceApp({super.key});

  @override
  State<CommunityWorkspaceApp> createState() => _CommunityWorkspaceAppState();
}

class _CommunityWorkspaceAppState extends State<CommunityWorkspaceApp> {
  bool _switching = false;
  bool _server = false;
  int _generation = 0;
  String? _error;

  Future<void> _switch(String? input) async {
    if (_switching) return;
    final address = input == null ? null : ServerConnection.normalize(input);
    setState(() {
      _switching = true;
      _error = null;
    });
    // Unmount routes, tasks and providers before changing any destination.
    AppConfig.connectionChanging = true;
    AppConfig.connectionEpoch++;
    await WidgetsBinding.instance.endOfFrame;
    try {
      Request.resetForConnection();
      await drainConnectionCredentials();
      await const SessionService().clearSessionStorage(connectionTransition: true);
      Request.resetForConnection();
      AppConfig.serverApiUrl = address;
      if (address == null) {
        await WindowController.instance.showHomeWindow();
      } else {
        await WindowController.instance.showLoginWindow();
      }
      _server = address != null;
    } catch (error, stack) {
      debugPrint('[workspace] switch failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      _error = '工作区切换失败，请返回本地后重试';
    } finally {
      AppConfig.connectionChanging = false;
      if (mounted) {
        setState(() {
          _switching = false;
          _generation++;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceConnectionScope(
        connect: (address) => _switch(address),
        returnToLocal: () => _switch(null),
        child: _switching || _error != null
            ? MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.light(),
                home: Scaffold(
                  body: Center(
                    child: _switching
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                                CupertinoActivityIndicator(),
                                SizedBox(height: 16),
                                Text('正在切换工作区'),
                              ])
                        : Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error!),
                            const SizedBox(height: 16),
                            FilledButton(
                                onPressed: () => _switch(null),
                                child: const Text('返回本地工作区')),
                          ]),
                  ),
                ),
              )
            : _server
                ? MyApp(
                    key: ValueKey('server-$_generation'),
                    initialLocation: RoutePaths.login,
                    hasToken: false,
                    routerFactory: createAppRouter,
                  )
                : ProviderScope(
                    key: ValueKey('local-$_generation'),
                    child: LocalWorkspaceApp(
                      localTaskBuilder: (agents, openRun, changes) => TaskPage(
                          localAgents: agents,
                          onOpenLocalRun: openRun,
                          localChanges: changes),
                      localCodingToolsBuilder: (_) =>
                          const LocalCodingToolsPage(),
                      shellBuilder: (child) =>
                          MainLayout(localWorkspace: true, child: child),
                    ),
                  ),
      );
}
