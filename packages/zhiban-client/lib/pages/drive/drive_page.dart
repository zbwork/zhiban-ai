import 'package:zhiban_client/network/user_refresh.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_desktop_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DrivePage extends ConsumerStatefulWidget {
  const DrivePage({super.key});

  @override
  ConsumerState<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends ConsumerState<DrivePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(driveTreeProvider);
      if (current.hasError) {
        ref.invalidate(driveTreeProvider);
        return;
      }
      final cached = current.value;
      if (cached?.bootstrap != null) {
        unawaited(ref.read(driveTreeProvider.notifier).refreshSilently());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncTree = ref.watch(driveTreeProvider);

    return asyncTree.when(
      loading: () => Scaffold(
        backgroundColor: ColorConfig.pageBackground,
        body: const DriveInitialSkeleton(),
      ),
      error: (error, stack) =>
          isTransientNetworkError(error) || error is TimeoutException
              ? const DriveDesktopLayout(showUnavailableState: true)
              : Scaffold(
                  backgroundColor: ColorConfig.pageBackground,
                  body: DriveErrorBlock(
                    message: '云盘加载失败，请稍后重试',
                    onRetry: () => UserRefresh.run(
                        () => ref.refresh(driveTreeProvider.future)).ignore(),
                  ),
                ),
      data: (_) => const DriveDesktopLayout(),
    );
  }
}

class DriveErrorBlock extends StatelessWidget {
  const DriveErrorBlock(
      {super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Color(0xFF595959))),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 公共工具:把消息以 toast 形式显示。
/// error=true 用红底白字的错误样式，与成功/提示(默认深色)明显区分，避免用户把
/// 失败误认成成功；成功态保持原有默认风格，不改全局 toast 系统。
void showDriveToast(String message, {bool error = false}) {
  if (error) {
    BotToast.showText(
      text: message,
      contentColor: const Color(0xFFE53935),
      textStyle: const TextStyle(fontSize: 14, color: Colors.white),
    );
    return;
  }
  BotToast.showText(text: message);
}
