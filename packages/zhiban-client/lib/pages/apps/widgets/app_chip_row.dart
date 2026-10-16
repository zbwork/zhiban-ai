import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/apps/models/app_models.dart';
import 'package:zhiban_client/pages/apps/providers/apps_providers.dart';
import 'package:zhiban_client/pages/apps/services/apps_service.dart';
import 'package:zhiban_client/pages/apps/widgets/app_webview_container.dart';

/// composer 输入框上方/下方的 "应用" chip 行 (F04 §5.1)。
///
/// 用法 (调用方在 composer 旁边挂):
///
/// ```dart
/// AppChipRow(conversationUuid: convUuid)
/// ```
///
/// 自动加载该 conversation 的用户入口应用; 列表为空时不渲染任何东西 (不占空间)。
class AppChipRow extends ConsumerWidget {
  const AppChipRow({super.key, required this.conversationUuid});

  final String conversationUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (conversationUuid.isEmpty) return const SizedBox.shrink();
    final appsAsync = ref.watch(conversationAppsProvider(conversationUuid));
    return appsAsync.when(
      data: (apps) {
        final userEntryApps =
            apps.where((app) => app.bindingKind == 'universal').toList();
        if (userEntryApps.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: userEntryApps.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (ctx, i) => _AppChip(
              app: userEntryApps[i],
              conversationUuid: conversationUuid,
            ),
          ),
        );
      },
      loading: () => const SizedBox(height: 40),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _AppChip extends ConsumerWidget {
  const _AppChip({required this.app, required this.conversationUuid});

  final ConversationAppItem app;
  final String conversationUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color color =
        _parseColor(app.color) ?? Theme.of(context).colorScheme.primary;
    return Material(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _launch(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (app.iconUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    app.iconUrl,
                    width: 18,
                    height: 18,
                    errorBuilder: (_, __, ___) => _fallbackIcon(color),
                  ),
                )
              else
                _fallbackIcon(color),
              const SizedBox(width: 6),
              Text(
                app.name,
                style: TextStyle(
                    fontSize: 13, color: color, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallbackIcon(Color color) =>
      Icon(Icons.apps_rounded, size: 16, color: color);

  Future<void> _launch(BuildContext context, WidgetRef ref) async {
    final svc = ref.read(appsBusServiceProvider);
    final state = generateCsrfState();
    final nonce = generateNonce();
    try {
      final result = await svc.launch(
        appUuid: app.uuid,
        conversationUuid: conversationUuid,
        state: state,
        nonce: nonce,
      );
      if (!context.mounted) return;
      await openAppWebView(
        context,
        launchUrl: result.launchUrl,
        displayMode: result.displayMode,
        title: app.name,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('应用启动失败: $e'))
      );
    }
  }

  /// 解析 "#RRGGBB" 或 "#AARRGGBB" 形式的颜色; 失败返 null。
  Color? _parseColor(String s) {
    if (s.isEmpty) return null;
    var hex = s.startsWith('#') ? s.substring(1) : s;
    if (hex.length == 6) hex = 'FF$hex';
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(v);
  }
}
