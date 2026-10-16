import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/widgets.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';

const accountDeletionConfirmationTitle = '确认注销账号？';
const accountDeletionConfirmationDescription = '''注销账号是高风险操作，请仔细阅读：

• 您的账号及全部个人信息将被永久删除；
• 服务器上的账号资料、聊天记录及其他相关数据将一并删除；
• 删除后无法恢复，您将无法继续使用当前账号。''';
const accountDeletionToastMessage = '账号注销操作已确认';

/// 执行纯前端的注销账号占位流程。
///
/// 本函数不调用注销 API；确认后仅通知调用方执行既有的本地退出登录流程。
Future<bool> requestFrontendAccountDeletion(
  BuildContext context, {
  required Future<void> Function() onConfirmed,
  void Function(String message)? showToast,
}) async {
  final confirmed = await showUiConfirmDialog(
    context,
    title: accountDeletionConfirmationTitle,
    description: accountDeletionConfirmationDescription,
    confirmLabel: '确认注销',
    cancelLabel: '取消',
    danger: true,
  );
  if (!confirmed || !context.mounted) return false;

  final notify = showToast ??
      (message) => BotToast.showText(
            text: message,
            duration: const Duration(seconds: 3),
          );
  notify(accountDeletionToastMessage);
  await Future.delayed(const Duration(seconds: 1));
  await onConfirmed();
  return true;
}
