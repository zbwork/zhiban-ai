import 'package:flutter/material.dart';
import 'package:zhiban_client/config/app_config.dart';

/// 非正式环境（dev/test）常驻角标；正式环境不显示。
///
/// 挂在应用全局 Overlay（见 main.dart `_RootOverlayStack`），跨路由常驻，
/// 不接收任何点击（IgnorePointer 包裹），不遮挡业务操作。
class EnvironmentTagOverlay extends StatelessWidget {
  const EnvironmentTagOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final env = AppConfig.env;
    if (env == AppEnv.prod) return const SizedBox.shrink();

    final String label;
    final Color color;
    switch (env) {
      case AppEnv.dev:
        label = '开发环境';
        color = const Color(0xFFFF8A3D);
        break;
      case AppEnv.test:
        label = '测试环境';
        color = const Color(0xFF2F80ED);
        break;
      case AppEnv.prod:
        return const SizedBox.shrink();
    }

    final topInset = MediaQuery.of(context).viewPadding.top;
    return Positioned(
      top: topInset + 6,
      right: 6,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
