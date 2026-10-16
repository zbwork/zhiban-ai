import 'dart:async';
import 'dart:io' show Platform;

import 'package:bot_toast/bot_toast.dart';
import 'config/app_config.dart';
import 'services/env_override_service.dart';
import 'services/session_service.dart';
import 'services/session_runtime.dart';
import 'services/analytics_service.dart';
import 'services/desktop_update_service.dart';
import 'package:zhiban_ui/themes/app_theme.dart';
import 'package:zhiban_ui/widgets/ui_toast.dart';
import 'window/window_controller.dart';
import 'package:zhiban_client/pages/runtime_prewarm/widgets/prewarm_overlay.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';
import 'package:zhiban_client/rtc/widgets/rtc_call_overlay.dart';
import 'package:zhiban_client/widgets/environment_tag_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routes/route_paths.dart';
import 'package:go_router/go_router.dart';

Future<void> _initializeConsentBoundServices({required bool hasToken}) async {
  await AnalyticsService.instance.initialize();
  AnalyticsService.instance.installGlobalErrorHandlers();
  if (hasToken) {
    AnalyticsService.instance.trackActiveUnawaited('launch');
    unawaited(sessionPushLifecycle.start());
  }
}

Future<void> startApp({
  required GoRouter Function({required String initialLocation}) routerFactory ,
  Future<void> Function()? initializePlatform,
  Future<bool> Function()? requiresPrivacyConsent,
  Widget Function(GoRouter router, Widget child)? sessionWrapper,
  Widget Function(VoidCallback onAccepted, Widget child)? privacyGate,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows) {
    DesktopUpdateService.registerUpdateEventHandler();
    // Successful installation also clears its completed package on the login page.
    unawaited(DesktopUpdateService.getUpdateState());
  }
  // 必须在任何网络/Window 初始化之前应用环境覆盖，否则 baseUrl 会用错。
  await EnvOverrideService.applyAtBootstrap();
  // 桌面调试环境强改口：ZHIBAN_FORCE_ENV=dev|test|prod 启动一次即持久化。
  // 只能走 App 自己的 SharedPreferences 写路径——macOS 上 defaults/直改
  // plist 都碰不到真身存储（defaults CLI 会被路由到沙箱容器域，直改文件
  // 又会被 cfprefsd 内存态覆盖，2026-08-02 实锤）。
  if (kDebugMode && !kIsWeb) {
    final force = Platform.environment['ZHIBAN_FORCE_ENV'];
    final forced = AppEnv.values.where((e) => e.name == force).firstOrNull;
    if (forced != null) {
      await EnvOverrideService.save(forced);
      AppConfig.applyEnvOverride(forced);
      debugPrint('[BOOT] env override forced -> ${forced.name}');
    }
  }
  // 环境指向排查的固定锚点（2026-08-02：App 实连测试环境却被当客户端回归
  // 排查了三轮）。终端拉起时第一眼确认 env/baseUrl，禁删。
  debugPrint('[BOOT] env=${AppConfig.env.name} api=${AppConfig.apiUrl()}');
  if (!kIsWeb &&
      (Platform.isMacOS || Platform.isWindows) &&
      AppConfig.localCodingToolsEnabled) {
    configureSessionLogoutCleanup(
      LocalCodingToolsService().removeAuthorizationOnLogout,
    );
  }
  await initializePlatform?.call();
  const sessionService = SessionService();
  final hasToken = await sessionService.hasValidSession();
  final needsPrivacyConsent = await requiresPrivacyConsent?.call() ?? false;
  if (!needsPrivacyConsent) {
    await _initializeConsentBoundServices(hasToken: hasToken);
  }

  await WindowController.instance.init(hasToken: hasToken);

  var initialLocation = hasToken ? RoutePaths.chat : RoutePaths.login;
  // 桌面调试直达口:ZHIBAN_INITIAL_ROUTE=/settings/ai-coding-tools 之类,
  // 已登录时直接打开该页(截屏 / 联调用),release 构建不读。
  if (kDebugMode && !kIsWeb && hasToken) {
    final route = Platform.environment['ZHIBAN_INITIAL_ROUTE'];
    if (route != null && route.startsWith('/')) {
      initialLocation = route;
      debugPrint('[BOOT] initial route forced -> $route');
    }
  }
  runApp(
    MyApp(
      initialLocation: initialLocation,
      hasToken: hasToken,
      requiresPrivacyConsent: needsPrivacyConsent,
      routerFactory: routerFactory,
      sessionWrapper: sessionWrapper,
      privacyGate: privacyGate,
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    required this.initialLocation,
    required this.hasToken,
    this.requiresPrivacyConsent = false,
    required this.routerFactory ,
    this.sessionWrapper,
    this.privacyGate,
  });

  final String initialLocation;
  final bool hasToken;
  final bool requiresPrivacyConsent;
  final GoRouter Function({required String initialLocation}) routerFactory;
  final Widget Function(GoRouter, Widget)? sessionWrapper;
  final Widget Function(VoidCallback, Widget)? privacyGate;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final GoRouter _router = widget.routerFactory(
    initialLocation: widget.requiresPrivacyConsent
        ? RoutePaths.login
        : widget.initialLocation,
  );
  late bool _privacyAccepted = !widget.requiresPrivacyConsent;

  void _acceptPrivacy() {
    if (!mounted || _privacyAccepted) return;
    setState(() => _privacyAccepted = true);
    if (widget.initialLocation != RoutePaths.login) {
      _router.go(widget.initialLocation);
    }
    unawaited(_initializeConsentBoundServices(hasToken: widget.hasToken));
  }

  Widget _wrapSession(Widget child) =>
      widget.sessionWrapper?.call(_router, child) ?? child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      locale: const Locale('zh', 'CN'), // 设置为中文
      supportedLocales: const [
        Locale('zh', 'CN'), // 中文
        Locale('en', 'US'), // 英文
      ],
      title: '知办AI',
      themeMode: ThemeMode.light,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: _router,
      builder: (context, child) {
        configureUiTextToast(context);
        final botToastBuilder = BotToastInit();
        final app = botToastBuilder(
          context,
          AppTheme.cupertinoThemeBuilder(
            context,
            ValueListenableBuilder<int>(
              valueListenable: sessionScopeKey,
              builder: (context, epoch, _) {
                return ProviderScope(
                  key: ValueKey(epoch),
                  child: _wrapSession(_RootOverlayStack(
                    router: _router,
                    child: child ?? const SizedBox.shrink(),
                  )),
                );
              },
            ),
          ),
        );
        if (_privacyAccepted) return app;
        return widget.privacyGate!(_acceptPrivacy, app);
      },
    );
  }
}

class _RootOverlayStack extends StatelessWidget {
  const _RootOverlayStack({
    required this.router,
    required this.child
  });

  final GoRouter router;
  final Widget child;

  bool get _showRtcOverlay {
    final path = router.routerDelegate.currentConfiguration.uri.path;
    return path != RoutePaths.login &&
        path != RoutePaths.tenantPicker &&
        path != RoutePaths.scan;
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (_) => AnimatedBuilder(
            animation: router.routerDelegate,
            builder: (context, _) {
              return Stack(
                children: [
                  child,
                  const PrewarmOverlay(),
                  if (_showRtcOverlay)
                    const RtcCallOverlayHost(desktopContentLeftInset: 416),
                  // 登录页也要显示，所以不跟 _showRtcOverlay 一起挡。
                  const EnvironmentTagOverlay(),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
