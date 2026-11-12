import 'community_workspace_app.dart';
import 'package:zhiban_client/app_bootstrap.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'routes/app_router.dart';

Future<void> main() => AppConfig.communityEdition
    ? startCommunityWorkspace()
    : startApp(routerFactory: createAppRouter);
