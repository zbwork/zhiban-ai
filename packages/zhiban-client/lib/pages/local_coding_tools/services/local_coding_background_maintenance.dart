import 'dart:async';

import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

/// App 启动后的本地开发工具后台维护(2026-09-15)。
///
/// 知办原本只在用户打开「本地开发工具」页面时才检测、补配置;Codex / Claude 桌面端
/// 自动更新后出的问题,用户不会想到来开知办。这里在 App 启动后静默做一次,**只修复、
/// 不切换**(不把"已安装但没切换"的形态切到知办,那是页面上的行为):
///
/// 1. 已切换且未被改动、但 Bridge 报 `global_upgrade_available`(本机程序变了,
///    例如 Codex 模型目录需要按新版本重做):静默重写一遍知办配置,不发真实请求。
///    Codex 命令行与桌面端共用一份配置,只做一次。
/// 2. Claude 桌面端已切换为知办、运行组件缺失或过期(桌面端自动更新后钉了新宿主
///    版本,国内无代理连 Chat 都用不了):按版本补上组件。
/// 3. 托管 = 已接入(F31 §3.2.1,2026-09-17;取代 09-16 的「版本管理」开关):
///    已切换到知办的形态,目录里有更高版本时直接升级到目录版本——本地失败的一半
///    是版本太老,而用户既不知道自己版本老、也不知道该怎么升。只作用于装在发行方
///    标准位置的那份(`update_available`,不降级由 Bridge 保证);**接管安装
///    (adopt)永远不在后台做**:它会改用户的 shell 配置,必须用户确认。恢复官方
///    配置后不再自动升级,装好的版本留在原位。
///
/// 任何一步失败都静默放弃,留给用户进页面时看到"需要处理"。
class LocalCodingBackgroundMaintenance {
  LocalCodingBackgroundMaintenance(
    this._service, {
    this.pollInterval = const Duration(seconds: 2),
    this.componentTimeout = const Duration(minutes: 20),
  });

  final LocalCodingToolsOperations _service;
  final Duration pollInterval;
  final Duration componentTimeout;

  Future<void> run() async {
    // 登录后 3 秒那次自动重新接入可能赶上网络还没好,这里再试一次(已接入时立即返回)。
    await _service.reconnectIfSameIdentity();
    final LocalCodingToolsSnapshot snapshot;
    try {
      snapshot = await _service.inspect();
    } catch (_) {
      return;
    }
    if (!snapshot.registrationAvailable || !snapshot.authorizationConnected) {
      return;
    }
    await _refreshConfigurations(snapshot);
    await _provisionClaudeDesktopComponent(snapshot);
    if (!await _upgradeManaged(snapshot)) return;
    // 升级可能改变 Codex 核心或 Claude 钉住的宿主，必须按新安装收尾。
    // 只补配置/组件，不再进入升级循环；检测失败不能继续用旧快照。
    final LocalCodingToolsSnapshot refreshed;
    try {
      refreshed = await _service.inspect();
    } catch (_) {
      return;
    }
    if (!refreshed.registrationAvailable || !refreshed.authorizationConnected) {
      return;
    }
    await _refreshConfigurations(refreshed);
    await _provisionClaudeDesktopComponent(refreshed);
  }

  /// 托管的自动升级:已切换到知办的形态,目录有更高版本就装上。一次只升一个
  /// 形态,失败就算了(页面版本行仍有「升级到 x.y.z」文字链);走官方服务的不碰。
  /// 桌面端正在运行时 Bridge 在计划阶段就报占用,不会白下载。
  Future<bool> _upgradeManaged(LocalCodingToolsSnapshot snapshot) async {
    if (!snapshot.canInstall) return false;
    var upgraded = false;
    for (final target in LocalCodingTarget.values) {
      final tool = snapshot.tools[target];
      final config = snapshot.configurations[target];
      if (tool == null || config == null) continue;
      if (!config.switchedToZhiban || !tool.canUpgrade) continue;
      try {
        final succeeded = await _awaitInstall(await _service.startInstall(
          target,
          mode: LocalCodingInstallMode.upgrade,
        ));
        upgraded = succeeded || upgraded;
      } catch (_) {
        // 正在运行(TARGET_IN_USE)、下载失败、状态变了:都留给页面。
      }
    }
    return upgraded;
  }

  Future<bool> _awaitInstall(LocalCodingOperation started) async {
    var operation = started;
    final deadline = DateTime.now().add(componentTimeout);
    while (!operation.isTerminal && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      operation = await _service.pollOperation(operation.operationId);
    }
    return operation.isSucceeded;
  }

  Future<void> _refreshConfigurations(LocalCodingToolsSnapshot snapshot) async {
    var codexDone = false;
    for (final target in LocalCodingTarget.values) {
      if (!snapshot.configRefreshEligible(target)) continue;
      if (target.vendor == LocalCodingVendor.codex) {
        if (codexDone) continue;
        codexDone = true;
      }
      try {
        await _service.switchToZhiban(target);
      } catch (_) {
        // 留给页面:卡片会显示需要处理或待检测。
      }
    }
  }

  Future<void> _provisionClaudeDesktopComponent(
      LocalCodingToolsSnapshot snapshot) async {
    const target = LocalCodingTarget.claudeDesktop;
    final tool = snapshot.tools[target];
    final config = snapshot.configurations[target];
    if (tool == null || config == null) return;
    if (!snapshot.canInstall ||
        !config.switchedToZhiban ||
        !tool.componentNeedsProvisioning) {
      return;
    }
    try {
      var operation = await _service.startInstall(
        target,
        component: LocalCodingComponent.claudeCodeHost,
      );
      final deadline = DateTime.now().add(componentTimeout);
      while (!operation.isTerminal && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        operation = await _service.pollOperation(operation.operationId);
      }
    } catch (_) {
      // 已装好(ALREADY_INSTALLED)、正在运行(TARGET_IN_USE)或下载失败:都留给页面。
    }
  }
}
