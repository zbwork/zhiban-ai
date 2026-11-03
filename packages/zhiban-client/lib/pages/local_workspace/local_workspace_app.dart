import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

import '../../routes/route_paths.dart';
import '../../window/window_controller.dart';
import '../model_service/model_service_page.dart';
import 'local_workspace_page.dart';

/// No session validation, analytics or runtime prewarm. The skill marketplace
/// fetches its anonymous public catalog only when opened.
Future<void> startLocalWorkspace(
    {Widget Function(Widget child)? shellBuilder,
    WidgetBuilder? localCodingToolsBuilder}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowController.instance.init(hasToken: true);
  runApp(ProviderScope(
      child: LocalWorkspaceApp(
          shellBuilder: shellBuilder,
          localCodingToolsBuilder: localCodingToolsBuilder)));
}

class LocalWorkspaceApp extends StatefulWidget {
  const LocalWorkspaceApp(
      {super.key, this.shellBuilder, this.localCodingToolsBuilder});
  final Widget Function(Widget child)? shellBuilder;
  final WidgetBuilder? localCodingToolsBuilder;
  @override
  State<LocalWorkspaceApp> createState() => _LocalWorkspaceAppState();
}

class _LocalWorkspaceAppState extends State<LocalWorkspaceApp> {
  late final _router = GoRouter(initialLocation: RoutePaths.chat, routes: [
    ShellRoute(
        builder: (context, state, child) {
          final content = Material(
              child: LocalWorkspacePage(
            section: state.uri.path,
            child: [RoutePaths.modelService, RoutePaths.localCodingTools]
                    .contains(state.uri.path)
                ? child
                : null,
          ));
          return widget.shellBuilder?.call(content) ?? content;
        },
        routes: [
          if (widget.localCodingToolsBuilder != null)
            GoRoute(
                path: RoutePaths.localCodingTools,
                pageBuilder: (context, state) => NoTransitionPage(
                    child: widget.localCodingToolsBuilder!(context))),
          for (final path in [
            RoutePaths.chat,
            RoutePaths.digitalEmployee,
            RoutePaths.inspire,
            RoutePaths.task,
            RoutePaths.drive,
            RoutePaths.contacts,
            RoutePaths.settings,
          ])
            GoRoute(
                path: path,
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SizedBox.shrink())),
          GoRoute(
              path: RoutePaths.modelService,
              pageBuilder: (context, state) =>
                  const NoTransitionPage(child: ModelServicePage())),
        ]),
  ]);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: '知办AI · 社区版',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: _router,
        builder: (context, child) => BotToastInit()(
            context,
            AppTheme.cupertinoThemeBuilder(
                context, child ?? const SizedBox.shrink())),
      );
}
