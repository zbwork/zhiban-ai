import 'package:zhiban_client/pages/contacts/contact_detail_pages.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_host.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/pages/chat/direct_chat_with_human_page.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/login/tenant_picker_page.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart' show ScopeOption;
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/pages/settings/settings_page.dart';
import 'package:zhiban_client/pages/settings/account_security_page.dart';
import 'package:zhiban_client/pages/settings/edit_profile_page.dart';
import 'package:zhiban_client/pages/settings/share_invite_page.dart';
import 'package:zhiban_client/pages/settings/usage_page.dart';
import 'package:zhiban_client/pages/browser/browser_page.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

GoRouter createSessionRouter({
  required String initialLocation,
  required List<RouteBase> shellRoutes,
  required List<RouteBase> platformRoutes,
  required Widget Function(Widget) shellBuilder,
  Set<String> publicPaths = const {},
}) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    observers: [BotToastNavigatorObserver()],
    redirect: (context, state) async {
      final path = state.uri.path;
      final isPublic = path == RoutePaths.login ||
          path == RoutePaths.tenantPicker ||
          publicPaths.contains(path);
      if (isPublic) return null;
      final hasSession = await const SessionService().hasValidSession();
      if (hasSession) return null;
      await WindowController.instance.showLoginWindow();
      return RoutePaths.login;
    },
    routes: [
      ShellRoute(
          pageBuilder: (context, state, child) => NoTransitionPage(
              child: LocalApprovalHost(child: shellBuilder(child))),
          routes: shellRoutes),
      ...platformRoutes,
      GoRoute(
        path: RoutePaths.tenantPicker,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final scopes = (state.extra as List<ScopeOption>?) ?? const [];
          return MaterialPage(
            child: TenantPickerPage(tenantScopes: scopes)
          );
        },
      ),
      GoRoute(
        path: RoutePaths.directChatWithHuman,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final peerAccountUuid =
              state.uri.queryParameters['peer_account_uuid'] ?? '';
          final title = state.uri.queryParameters['title'];
          return MaterialPage(
            child: DirectChatWithHumanPage(
              peerAccountUuid: peerAccountUuid,
              title: title,
            ),
          );
        },
      ),
      GoRoute(
        path: RoutePaths.editProfile,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: EditProfilePage()),
      ),
      GoRoute(
        path: RoutePaths.about,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => const MaterialPage(child: AboutPage()),
      ),
      GoRoute(
        path: RoutePaths.envSwitch,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: EnvSwitchPage()),
      ),
      GoRoute(
        path: RoutePaths.profileDetails,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final info = state.extra as AccountInfo?;
          return MaterialPage(child: ProfileDetailsPage(info: info));
        },
      ),
      GoRoute(
        path: RoutePaths.loginStatus,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: LoginStatusPage()),
      ),
      GoRoute(
        path: RoutePaths.accountSecurity,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: AccountSecurityPage()),
      ),
      GoRoute(
        path: RoutePaths.walletTransactions,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: WalletTransactionsPage()),
      ),
      GoRoute(
        path: RoutePaths.usageConsumption,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: UsageConsumptionPage()),
      ),
      GoRoute(
        path: RoutePaths.shareInvite,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: ShareInvitePage()),
      ),
      GoRoute(
        path: RoutePaths.contactsPersonDetail,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final extra = state.extra;
          final page = extra is ContactPerson
              ? ContactsPersonDetailPage(person: extra)
              : ContactsPersonDetailPage.byId(accountUuid: extra as String);
          return MaterialPage(child: page);
        },
      ),
      GoRoute(
        path: RoutePaths.contactsAgentDetail,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final extra = state.extra;
          final page = extra is ContactAgent
              ? ContactsAgentDetailPage(agent: extra)
              : ContactsAgentDetailPage.byId(agentUuid: extra as String);
          return MaterialPage(child: page);
        },
      ),
      GoRoute(
        path: RoutePaths.browser,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          final title = (extra['title'] as String?) ?? '';
          final urlStr = (extra['url'] as String?) ?? '';
          final url = Uri.tryParse(urlStr) ?? Uri.parse('about:blank');
          return MaterialPage(
            child: BrowserPage(title: title, url: url),
          );
        },
      ),
    ],
  );
}
