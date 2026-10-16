import 'package:nexwork/layout/main_layout.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:nexwork/pages/chat/chat_page.dart';
import 'package:nexwork/pages/contacts/contacts_page.dart';
import 'package:nexwork/pages/digital_employee/digital_employee_page.dart';
import 'package:nexwork/pages/login/login_page.dart';
import 'package:nexwork/pages/local_coding_tools/local_coding_tools_page.dart';
import 'package:zhiban_client/pages/settings/settings_page.dart';
import 'package:zhiban_client/pages/model_service/model_service_page.dart';
import 'package:nexwork/pages/settings/billing_page.dart';
import 'package:nexwork/pages/skills/skills_page.dart';
import 'package:nexwork/pages/task/task_page.dart';
import 'package:zhiban_client/pages/workbench/workbench_page.dart';
import 'package:zhiban_client/pages/drive/drive_page.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:zhiban_client/routes/session_router.dart';

GoRouter createAppRouter({required String initialLocation}) =>
    createSessionRouter(
      initialLocation: initialLocation,
      shellBuilder: (child) => MainLayout(child: child),
      shellRoutes: [
        GoRoute(
          path: RoutePaths.settings,
          pageBuilder: (context, state) => const NoTransitionPage(
            child: SettingsPage(),
          ),
        ),
        GoRoute(
          path: RoutePaths.billing,
          pageBuilder: (context, state) => const NoTransitionPage(
            child: BillingOverviewPage(),
          ),
        ),
        GoRoute(
          path: RoutePaths.modelService,
          pageBuilder: (context, state) => const NoTransitionPage(
            child: ModelServicePage(),
          ),
        ),
        if ((PlatformUtils.isMacOS || PlatformUtils.isWindows) &&
            AppConfig.localCodingToolsEnabled)
          GoRoute(
            path: RoutePaths.localCodingTools,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: LocalCodingToolsPage(),
            ),
          ),
        GoRoute(
          path: RoutePaths.chat,
          pageBuilder: (context, state) {
            final params = state.uri.queryParameters;
            final Widget page = ChatPage(
              triggerCreateSkill: params['create_skill'] == 'true',
              targetAgentId: params['agentId'],
              directKind: params['direct'],
              peerAccountUuid: params['peer_account_uuid'],
              directTitle: params['title'],
            );
            return NoTransitionPage(child: page);
          },
        ),
        GoRoute(
          path: RoutePaths.contacts,
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: ContactsPage()),
        ),
        GoRoute(
          path: RoutePaths.digitalEmployee,
          pageBuilder: (context, state) => NoTransitionPage(
            child: const DigitalEmployeePage(),
          ),
        ),
        GoRoute(
          path: RoutePaths.inspire,
          pageBuilder: (context, state) => NoTransitionPage(
            child: const SkillsPage(),
          ),
        ),
        GoRoute(
          path: RoutePaths.task,
          pageBuilder: (context, state) => NoTransitionPage(
            child: const TaskPage(),
          ),
        ),
        GoRoute(
          path: RoutePaths.workbench,
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: WorkbenchPage()),
        ),
        GoRoute(
          path: RoutePaths.drive,
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: DrivePage()),
        )
      ],
      platformRoutes: [
        GoRoute(
          path: RoutePaths.login,
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) {
            return NoTransitionPage(
              child: const LoginPage(),
            );
          },
        )
      ],
    );
