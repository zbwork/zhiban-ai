import 'package:zhiban_client/config/color_config.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class TaskLoadError extends StatelessWidget {
  const TaskLoadError({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ColorConfig.pageBackground,
      child: Center(
        child: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle_fill,
                size: 38,
                color: Color(0xFFD92D20),
              ),
              const SizedBox(height: 14),
              const Text(
                '任务页面暂时不可用',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF162033),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: Color(0xFF667085),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onRetry,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
