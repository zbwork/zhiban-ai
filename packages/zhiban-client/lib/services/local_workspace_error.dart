import 'package:dio/dio.dart';

/// Only fixed categories cross into UI; never echo IPC bodies, paths or tokens.
class LocalWorkspaceError implements Exception {
  const LocalWorkspaceError(this.code, this.message, {this.contextId = ''});
  final String code, message, contextId;
  bool get canChooseDirectory =>
      contextId.isNotEmpty &&
      const {
        'local.workspace_path_conflict',
        'local.workspace_permission_denied',
        'local.workspace_io_failed',
        'local.invalid_workspace',
        'local.workspace_overlaps_private_state',
      }.contains(code);

  factory LocalWorkspaceError.from(Object error, {String contextId = ''}) {
    final response = error is DioException ? error.response : null;
    final status = response?.statusCode;
    if (contextId.isEmpty) {
      return LocalWorkspaceError(
          'local.conversation_load_failed',
          status == 403 || status == 404
              ? '当前会话不可访问，请检查数字员工与会话的访问权限（HTTP $status）'
              : '本地会话信息读取失败${status == null ? '' : '（HTTP $status）'}，请重试');
    }
    const messages = {
      'local.workspace_identity_mismatch': '当前会话的工作目录配置与数字员工不匹配，请联系管理员核查',
      'local.workspace_path_conflict': '默认工作目录被同名文件占用或路径不是文件夹，请选择其他工作目录',
      'local.workspace_permission_denied': '无法读写默认工作目录，请检查系统文件权限或选择其他工作目录',
      'local.workspace_io_failed': '默认工作目录创建失败，请检查磁盘和目录权限或选择其他工作目录',
      'local.invalid_workspace': '工作目录不可用，请选择其他工作目录',
      'local.workspace_overlaps_private_state': '该目录与运行组件内部目录重叠，请选择其他工作目录',
    };
    final data = response?.data;
    final detail = data is Map ? data['error'] : null;
    final code = detail is Map ? detail['code'] : null;
    final message = messages[code];
    return LocalWorkspaceError(
        message == null
            ? 'local.workspace_initialization_failed'
            : code as String,
        message ?? '工作目录初始化失败${status == null ? '' : '（HTTP $status）'}，请重试',
        contextId: contextId);
  }

  @override
  String toString() => message;
}
