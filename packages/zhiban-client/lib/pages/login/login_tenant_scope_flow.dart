import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/login/login_navigation.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/pages/login/tenant_picker_page.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

export 'package:zhiban_client/pages/login/login_navigation.dart';

Future<void> enterHomeWithTenantScope(
  BuildContext context,
  List<ScopeOption> tenantScopes,
) async {
  if (tenantScopes.length >= 2) {
    if (PlatformUtils.isDesktop) {
      final picked = await showTenantPickerDialog(context, tenantScopes);
      if (picked == null || !context.mounted) return;
      try {
        await switchToTenantApi(picked.tenantId);
      } catch (e) {
        if (context.mounted) BotToast.showText(text: formatError(e));
        return;
      }
      if (!context.mounted) return;
      enterHomeAfterLogin(context, resetScope: true);
    } else {
      context.push(RoutePaths.tenantPicker, extra: tenantScopes);
    }
    return;
  }
  if (tenantScopes.length == 1) {
    try {
      await switchToTenantApi(tenantScopes.first.tenantId);
    } catch (error) {
      if (context.mounted) {
        BotToast.showText(text: formatError(error));
      }
      return;
    }
    if (!context.mounted) return;
    enterHomeAfterLogin(context, resetScope: true);
    return;
  }
  enterHomeAfterLogin(context);
}
