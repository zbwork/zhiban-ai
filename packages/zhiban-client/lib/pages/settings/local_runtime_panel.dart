import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart'
    show localWarningColor;

const localComponentLabels = {
  'node': '运行组件',
  'engine': '任务运行组件',
  'office': 'Office 文件处理',
  'browser': 'Chrome 浏览器（可选）',
  'isolation': '文件访问隔离实测'
};

class LocalRuntimePanel extends ConsumerStatefulWidget {
  const LocalRuntimePanel({super.key});
  @override
  ConsumerState<LocalRuntimePanel> createState() => _LocalRuntimePanelState();
}

class _LocalRuntimePanelState extends ConsumerState<LocalRuntimePanel> {
  final local = LocalAgentService.instance;
  Map<String, bool> checks = {};
  bool checking = true, connecting = false, submitting = false;
  String message = '';
  @override
  void initState() {
    super.initState();
    local.addListener(changed);
    unawaited(check());
  }

  @override
  void dispose() {
    local.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> check() async {
    setState(() => checking = true);
    final result = await local.checkComponents();
    if (mounted) {
      setState(() {
        checks = result;
        checking = false;
      });
    }
  }

  Future<void> reconnect() async {
    setState(() {
      connecting = true;
      message = '';
    });
    try {
      await local.ensureReady();
    } catch (_) {
      if (mounted) {
        setState(() => message = local.errorMessage.isEmpty
            ? '连接未恢复，请检查登录、网络和运行组件。'
            : local.errorMessage);
      }
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> diagnostics() async {
    if (checking || submitting) return;
    final generation = local.lifecycleGeneration;
    final base = AppConfig.apiUrl();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
    final report = <String, dynamic>{
      'schema': 1,
      'platform': Platform.isMacOS
          ? 'macos'
          : Platform.isWindows
              ? 'windows'
              : 'unsupported',
      'connected': local.online,
      'active_tasks': local.activeRuns.length,
      'pending_approvals': local.approvals.length,
      'components': {
        for (final key in localComponentLabels.keys) key: checks[key] == true
      }
    };
    final text = const JsonEncoder.withIndent('  ').convert(report);
    if (!mounted) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => UiDialogShell(
            size: UiDialogSize.compact,
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UiSheetHeader(
                          title: '提交本地运行诊断',
                          onClose: () => Navigator.pop(context, false)),
                      const SizedBox(height: 14),
                      const Text('仅提交下方组件状态与计数，不含聊天内容、文件、目录或密钥。'),
                      const SizedBox(height: 12),
                      Flexible(
                          child: SingleChildScrollView(
                              child: SelectableText(text,
                                  style: const TextStyle(fontSize: 12)))),
                      const SizedBox(height: 20),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消')),
                        const SizedBox(width: 8),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('确认提交'),),
                    ]),
            ],
          )),
      ),
    );
    if (accepted != true || !mounted) return;
    if (local.lifecycleGeneration != generation ||
        AppConfig.apiUrl() != base ||
        prefs.getString(AppConfig.storageTokenKey) != token) {
      setState(() => message = '登录或运行状态已变化，请重新检查后提交。');
      return;
    }
    setState(() => submitting = true);
    final api = Dio(BaseOptions(
        baseUrl: base,
        headers: {'Authorization': 'Bearer $token'},
        followRedirects: false,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20)));
    try {
      final result = await api.post('/api/agent-bus/v1/support-feedback',
          data: {
            'category': 'bug',
            'title': '本地运行诊断',
            'description': text,
            'client_info': report
          });
      if (result.statusCode == null ||
          result.statusCode! >= 300 ||
          result.data is! Map ||
          (result.data as Map)['success'] != true) {
        throw StateError('提交失败');
      }
      if (mounted) setState(() => message = '诊断已提交。');
    } catch (_) {
      if (mounted) setState(() => message = '未确认提交成功，请稍后查看反馈记录，避免重复提交。');
    } finally {
      api.close(force: true);
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref.watch(agentsProvider).asData?.value ?? [];
    final names = agents
        .where((a) => a.executionLocus == 'local')
        .map((a) => a.displayName)
        .toList();
    return UiDialogShell(
        size: UiDialogSize.standard,
        child: SizedBox(
            width: 480,
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UiSheetHeader(
                          title: '本地运行',
                          subtitle: '管理这台电脑上的数字员工运行环境。',
                          onClose: () => Navigator.pop(context)),
                      const SizedBox(height: 22),
                      Flexible(
                          child: SingleChildScrollView(
                              child: LocalRuntimeStatusView(
                                  online: local.online,
                                  checking: checking,
                                  checks: checks,
                                  affected: names.isEmpty
                                      ? '暂无本机数字员工'
                                      : names.join('、'),
                                  activeTasks: local.activeRuns.length,
                                  pendingApprovals: local.approvals.length))),
                      if (message.isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(message,
                                style: const TextStyle(fontSize: 12))),
                      const SizedBox(height: 20),
                      Row(children: [
                        Expanded(
                            child: FilledButton(
                                onPressed: connecting || local.online
                                    ? null
                                    : reconnect,
                                child: connecting
                                    ? const CupertinoActivityIndicator(
                                        radius: 8)
                                    : Text(local.online ? '已连接' : '重新连接'))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: OutlinedButton(
                                onPressed: checking ? null : check,
                                child: const Text('重新检测'))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: OutlinedButton(
                                onPressed:
                                    checking || submitting ? null : diagnostics,
                                child: Text(submitting ? '提交中…' : '提交诊断'))),
                      ]),
                      const SizedBox(height: 14),
                      Text('已记录脱敏错误摘要。诊断详情经你确认后上传，不包含 API Key 或文件正文。',
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ]))));
  }
}

class LocalRuntimeStatusView extends StatelessWidget {
  const LocalRuntimeStatusView(
      {super.key,
      required this.online,
      required this.checking,
      required this.checks,
      required this.affected,
      required this.activeTasks,
      required this.pendingApprovals});
  final bool online, checking;
  final Map<String, bool> checks;
  final String affected;
  final int activeTasks, pendingApprovals;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = online ? scheme.primary : localWarningColor(context);
    Widget detail(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Text(label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(width: 18),
          Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)))
        ]));
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .05),
                  border: Border.all(color: statusColor.withValues(alpha: .22)),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(
                    online
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.exclamationmark_circle_fill,
                    color: statusColor,
                    size: 30),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(online ? '本地运行已就绪' : '本地运行已中断',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: statusColor)),
                      const SizedBox(height: 4),
                      Text(online ? '本地任务将在这台电脑上执行。' : '本地任务已暂停，不会自动转到云端。',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),),
              ]),
              ),
            ],
          ),
        ),
          const SizedBox(height: 14),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                  border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: .7)),
                  borderRadius: BorderRadius.circular(8)),
              child: Column(children: [
                detail('当前设备', Platform.isMacOS ? '这台 Mac' : '这台电脑'),
                Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: .4)),
                detail(online ? '本地员工' : '受影响员工', affected),
                Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: .4)),
                detail(
                    '任务状态',
                    !online
                        ? '等待恢复'
                        : pendingApprovals > 0
                            ? '$pendingApprovals 个任务等待批准'
                            : activeTasks > 0
                                ? '$activeTasks 个任务运行中'
                                : '暂无运行中的任务'),
              ])),
          const SizedBox(height: 12),
          Text('聊天记录已保留，恢复后可返回会话确认是否继续。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(checking ? '正在检查运行组件…' : '组件检查详情',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              children: [
                for (final item in localComponentLabels.entries)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(
                            child: Text(item.value,
                                style: const TextStyle(fontSize: 12))),
                        if (checking)
                          const CupertinoActivityIndicator(radius: 7)
                        else
                          Text(checks[item.key] == true ? '通过' : '不可用',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: checks[item.key] == true
                                      ? scheme.primary
                                      : scheme.error),),
              ],
                ),
              ),
        ],
        ),
      ],
    );
  }
}
