import 'package:flutter/material.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

enum CreatorImportStage {
  saving,
  downloading,
  transcribing,
  analyzing,
  saved,
  published,
  failed,
}

typedef CreatorImportStatus = ({
  CreatorImportStage stage,
  String message,
  String? creatorId,
  int? workCount,
  String? mediaSummary,
});

class CreatorImportFeedback extends StatelessWidget {
  const CreatorImportFeedback({
    super.key,
    required this.status,
    required this.onOpenWorks,
  });

  final ValueNotifier<CreatorImportStatus> status;
  final ValueChanged<String> onOpenWorks;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: status,
        builder: (context, value, _) {
          final scheme = Theme.of(context).colorScheme;
          final running = switch (value.stage) {
            CreatorImportStage.saving ||
            CreatorImportStage.downloading ||
            CreatorImportStage.transcribing ||
            CreatorImportStage.analyzing => true,
            _ => false,
          };
          final failed = value.stage == CreatorImportStage.failed;
          final title = switch (value.stage) {
            CreatorImportStage.saving => '正在保存作品资料',
            CreatorImportStage.downloading => '正在下载作品媒体',
            CreatorImportStage.transcribing => '正在准备逐字稿',
            CreatorImportStage.analyzing => '正在分析作品',
            CreatorImportStage.saved => '作品资料已保存',
            CreatorImportStage.published => '已发布博主专家',
            CreatorImportStage.failed => '处理未完成',
          };
          void close() => Navigator.pop(context);
          return UiContentDialog(
            size: UiDialogSize.compact,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UiSheetHeader(title: title, onClose: close),
                  const Divider(height: 20),
                  if (value.workCount case final count?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('已保存 $count 条作品资料。'),
                    ),
                  if (failed)
                    Text(value.message, style: TextStyle(color: scheme.error))
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: .07),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(value.message),
                      ),
                    ),
                  if (value.mediaSummary case final summary?)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(summary),
                    ),
                  if (running) ...[
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                          width: 145, child: LinearProgressIndicator()),
                    ),
                  ],
                  const Divider(height: 20),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      if (!running && value.creatorId != null)
                        OutlinedButton(
                          onPressed: () {
                            close();
                            onOpenWorks(value.creatorId!);
                          },
                          child: const Text('查看作品'),
                        ),
                      FilledButton(
                        onPressed: close,
                        child: Text(running ? '后台处理' : '完成'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
}
