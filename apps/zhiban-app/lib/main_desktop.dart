import 'layout/main_layout.dart';
import 'pages/task/task_page.dart';
import 'pages/local_coding_tools/local_coding_tools_page.dart';
import 'package:zhiban_client/app_bootstrap.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'routes/app_router.dart';

Future<void> main() => AppConfig.communityEdition
    ? startLocalWorkspace(
        localTaskBuilder: (agents, openRun, changes) => TaskPage(
            localAgents: agents,
            onOpenLocalRun: openRun,
            localChanges: changes),
        localCodingToolsBuilder: (_) => const LocalCodingToolsPage(),
        shellBuilder: (child) => MainLayout(localWorkspace: true, child: child))
    : startApp(routerFactory: createAppRouter);
