import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/pages/local_coding_tools/local_coding_tools_page.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/providers/local_coding_tools_provider.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

void main() {
  testWidgets('桌面安装授权前置：等待时无百分比，取消不显示安装冲突', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        desktopUiState: LocalCodingToolUiState.notInstalled,
        supportedMethods: const {
          'requirements.get',
          'install.plan',
          'install.execute',
          'operation.get',
          'operation.cancel'
        },
      ),
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'authorizing',
      cancellable: true,
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.failed,
      stage: 'authorizing',
      errorCode: 'LCT-CODEX_DESKTOP-INSTALL-AUTHORIZATION_CANCELLED',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装桌面端').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();
    expect(find.text('等待 Windows 管理员授权，请在系统提示中选择“是”'), findsOneWidget);
    expect(find.text('管理员授权'), findsOneWidget);
    expect(find.text('80%'), findsNothing);
    expect(find.text('正在下载安装包...'), findsNothing);
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(find.text('已取消授权，尚未安装'), findsOneWidget);
    expect(find.text('安装失败'), findsNothing);
    expect(find.textContaining('检测到冲突'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });


  testWidgets(
      '首次进入先显示卡片骨架与检测进度,检测完每个厂商一张卡(CLI + 桌面端 汇总)',
      (tester) async {
    final completer = Completer<LocalCodingToolsSnapshot>();
    final service = _FakeOperations(inspect: () => completer.future);
    await _pumpPage(tester, service);

    // 2026-09-15 · 不再整页转圈:两张卡立刻出现,角标「检测中」,检测进度浮在顶部。
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('正在检测'), findsOneWidget);
    expect(find.text('安装、检测并配置本机 AI 编程工具'), findsOneWidget);
    expect(find.text('检测中'), findsWidgets);
    expect(find.text('打开'), findsNothing);

    completer.complete(_snapshot(authorized: true));
    await tester.pumpAndSettle();
    // 浮动进度原地换成"检测完成"。
    expect(find.text('正在检测'), findsNothing);
    expect(find.text('检测完成'), findsOneWidget);

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    // 不再按 CLI / 桌面端 分行,target 名称只出现在弹框和 toast 里。
    expect(find.text('命令行 (CLI)'), findsNothing);
    expect(find.text('桌面端 (App)'), findsNothing);
    expect(find.text('Codex CLI'), findsNothing);
    expect(find.text('Codex 桌面端'), findsNothing);
    // 软件状态一行汇总两种形态。
    expect(find.text('已安装（命令行 + 桌面端）'), findsNWidgets(2));
    expect(find.text('已安装'), findsNWidgets(2));
    expect(find.text('官方服务'), findsNWidgets(2));
    expect(find.text('运行正常'), findsNothing);
    // 只有「打开」是下拉;菜单未展开时不出现具体形态。
    expect(find.text('打开'), findsNWidgets(2));
    expect(find.text('打开 CLI'), findsNothing);
    expect(find.text('打开桌面端'), findsNothing);
    expect(find.text('一键接入知办'), findsNWidgets(2));
    expect(find.text('重新检测'), findsNWidgets(2));
    // 卡头 ⓘ 解释一起装了什么。
    expect(find.byType(Tooltip), findsNWidgets(2));
  });

  testWidgets('检测过程可视化 · 重新检测时卡片保留,已读完的卡填新结果,正在查的卡行尾显示检测中', (tester) async {
    final service = _FakeOperations(inspect: () async => _snapshot(authorized: true));
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalCodingToolsPage)));

    // Codex 已读完安装与配置、还差网络检查;当前在查 Claude 命令行。
    container.read(localCodingInspectProgressProvider.notifier).state =
        LocalCodingInspectProgress(
      steps: LocalCodingInspectStep.plan(network: true),
      completed: 4,
      snapshot: _snapshot(authorized: true),
    );
    await tester.pump();

    // 进度浮在顶部(滚到哪张卡都看得到),说明行保持固定文字。
    expect(find.text('正在检测'), findsOneWidget);
    expect(find.textContaining('Claude 检查命令行 5/8'), findsOneWidget);
    expect(find.text('安装、检测并配置本机 AI 编程工具'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('已安装（命令行 + 桌面端）'), findsNWidgets(2));
    // 两张卡角标 + Claude 四行行尾。
    expect(find.text('检测中'), findsNWidgets(6));
    // 没轮到的卡不解释(2026-09-20 用户反馈:Codex 卡写"等待 Claude 检测完成…",
    // 读起来像 Codex 依赖 Claude / 卡住了;这种状态一闪而过,"稍后…"同样多余)。
    expect(find.text('检测中…'), findsOneWidget);
    expect(find.textContaining('等待'), findsNothing);
    expect(find.textContaining('稍后'), findsNothing);
    expect(find.text('正在检查命令行…'), findsOneWidget);

    // 还没轮到的卡:Codex 在查命令行,Claude 一步没做。
    container.read(localCodingInspectProgressProvider.notifier).state =
        LocalCodingInspectProgress(
      steps: LocalCodingInspectStep.plan(network: true),
      completed: 1,
      snapshot: _snapshot(authorized: true),
    );
    await tester.pump();
    expect(find.text('检测中…'), findsOneWidget);
    expect(find.textContaining('等待'), findsNothing);
    expect(find.textContaining('稍后'), findsNothing);

    // 最后的网络与代理检查两个工具都用得上,顶部不再写成"Codex 检查网络与代理"。
    container.read(localCodingInspectProgressProvider.notifier).state =
        LocalCodingInspectProgress(
      steps: LocalCodingInspectStep.plan(network: true),
      completed: 7,
      snapshot: _snapshot(authorized: true),
    );
    await tester.pump();
    expect(find.textContaining('检查网络与代理 8/8'), findsOneWidget);
    expect(find.textContaining('Codex 检查网络与代理'), findsNothing);
    expect(find.text('正在检查网络与代理…'), findsOneWidget);

    container.read(localCodingInspectProgressProvider.notifier).state =
        LocalCodingInspectProgress(
      steps: LocalCodingInspectStep.plan(network: true),
      completed: 4,
      snapshot: _snapshot(authorized: true),
    );
    await tester.pump();
    // 检测中不给操作:底部按钮换成检测步骤,行尾链接隐藏。
    expect(find.text('一键接入知办'), findsNothing);
    expect(find.text('重新检测'), findsNothing);

    container.read(localCodingInspectProgressProvider.notifier).state = null;
    await tester.pumpAndSettle();
    expect(find.text('正在检测'), findsNothing);
    expect(find.text('检测完成'), findsOneWidget);
    expect(find.text('安装、检测并配置本机 AI 编程工具'), findsOneWidget);
    expect(find.text('检测中'), findsNothing);
    expect(find.text('一键接入知办'), findsNWidgets(2));
    expect(find.text('重新检测'), findsNWidgets(2));

    // 全部完成 3 秒后淡出。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('检测完成'), findsNothing);
  });

  testWidgets('missing profiles disables 一键接入知办 but keeps 打开', (tester) async {
    final service = _FakeOperations(
      inspect: () async =>
          _snapshot(authorized: false, registrationAvailable: false),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 2026-09-15 · 不再是页面顶部横幅:两张卡灰掉的切换按钮旁各有一句说明。
    expect(find.text('当前环境暂未开放知办模型 API，可先安装并使用官方服务'), findsNWidgets(2));
    final switchButton = tester.widget<FilledButton>(find.ancestor(
      of: find.text('一键接入知办').first,
      matching: find.byType(FilledButton),
    ));
    expect(switchButton.onPressed, isNull);
    final open = tester.widget<OutlinedButton>(find.ancestor(
      of: find.text('打开').first,
      matching: find.byType(OutlinedButton),
    ));
    expect(open.onPressed, isNotNull);
  });

  for (final missingDesktop in [false, true]) {
    testWidgets(
        'unsafe configuration keeps cards and blocks writes (missing desktop: $missingDesktop)',
        (tester) async {
      final base = _snapshot(
        authorized: true,
        desktopUiState: missingDesktop
            ? LocalCodingToolUiState.notInstalled
            : LocalCodingToolUiState.installedUnmanaged,
      );
      final snapshot = LocalCodingToolsSnapshot(
        deviceId: base.deviceId,
        environment: base.environment,
        credentialStatus: base.credentialStatus,
        tools: base.tools,
        configurations: {
          ...base.configurations,
          for (final target in LocalCodingVendor.codex.targets)
            target: LocalCodingConfigurationStatus.fromJson({
              'target_id': target.id,
              'state': 'conflict',
              'verification_level': 'l0',
              'current_service': 'unknown',
              'error_code': 'LCT-${target.id.toUpperCase()}-CONFIG-UNSAFE_PATH',
              'next_actions': ['inspect'],
            }),
        },
        expectedProfileVersions: base.expectedProfileVersions,
        registrationAvailable: base.registrationAvailable,
        supportedMethods: base.supportedMethods,
      );
      final service = _FakeOperations(inspect: () async => snapshot);
      await _pumpPage(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('配置不可访问'), findsOneWidget);
      expect(find.text('无法判断'), findsOneWidget);
      expect(find.text('自定义配置'), findsNothing);
      expect(find.textContaining('配置目录权限或链接不满足安全要求'), findsOneWidget);
      expect(
        find.text(missingDesktop
            ? '已安装（命令行）· 桌面端未安装'
            : '已安装（命令行 + 桌面端）'),
        missingDesktop ? findsOneWidget : findsNWidgets(2),
      );
      expect(find.text('安装桌面端'), missingDesktop ? findsOneWidget : findsNothing);
      expect(find.text('一键接入知办'), findsOneWidget);
      expect(find.text('修复并重试'), findsNothing);
      expect(service.switchCalls, 0);
      expect(service.enableCalls, 0);
      await tester.tap(find.text('重新检测').first);
      await tester.pumpAndSettle();
      expect(service.inspectCalls, greaterThan(1));
      expect(service.switchCalls, 0);
    });
  }

  testWidgets('inspection error provides a visible retry action',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => throw const LocalCodingToolsException(
        'LCT-BRIDGE-INSPECT_FAILED',
        '检测失败，请重试',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('检测失败，请重试'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);
    expect(service.inspectCalls, 1);
  });

  testWidgets('整页检测失败显示本地连接组件给出的原因,不再统一成"检测失败，请重试"',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => throw const LocalCodingBridgeException(
        'rpc_timeout',
        '本地连接组件响应超时，请重试',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('本地连接组件响应超时，请重试'), findsOneWidget);
    expect(find.text('检测失败，请重试'), findsNothing);
    expect(find.text('重新检测'), findsOneWidget);
  });

  testWidgets('契约 §2.7 · 某个形态的检测结果读不懂:只有这张卡显示检测异常,另一张卡照常',
      (tester) async {
    final base = _snapshot(authorized: false);
    final snapshot = LocalCodingToolsSnapshot(
      deviceId: base.deviceId,
      environment: base.environment,
      credentialStatus: base.credentialStatus,
      tools: {
        ...base.tools,
        for (final target in LocalCodingVendor.codex.targets)
          target: LocalCodingToolState.unreadable(target),
      },
      configurations: base.configurations,
      expectedProfileVersions: base.expectedProfileVersions,
      registrationAvailable: base.registrationAvailable,
      supportedMethods: base.supportedMethods,
    );
    final service = _FakeOperations(inspect: () async => snapshot);
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // Codex 卡:角标与软件状态都是"检测异常",不给打开 / 切换。
    expect(find.text('检测异常'), findsNWidgets(2));
    expect(find.text('暂不支持'), findsNothing);
    expect(find.textContaining('知办没能读懂这一项的检测结果'), findsOneWidget);
    // Claude 卡照常显示并可打开。
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);

    await tester.tap(find.text('查看原因'));
    await tester.pumpAndSettle();
    expect(find.text('Codex CLI 检测异常'), findsOneWidget);
    expect(find.textContaining('知办与本地连接组件版本不一致'), findsOneWidget);
    expect(find.text('错误码：LCT-CODEX_CLI-DETECT-RESULT_UNREADABLE'),
        findsOneWidget);
  });

  testWidgets('「打开」下拉选 CLI 走系统终端,选桌面端由 Bridge open -a;都不选项目', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(authorized: false),
      openApp: (target) async => LocalCodingLaunchResult(
        target: target,
        state: 'launched',
        projectName: target.isDesktop ? '' : '~',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开').first);
    await tester.pumpAndSettle();
    expect(find.text('打开 CLI'), findsOneWidget);
    expect(find.text('打开桌面端'), findsOneWidget);
    await tester.tap(find.text('打开 CLI'));
    await tester.pumpAndSettle();
    expect(service.openAppCalls, 1);
    expect(service.openedTarget, LocalCodingTarget.codexCli);
    expect(find.text('已在系统终端打开 Codex CLI'), findsOneWidget);

    await tester.tap(find.text('打开').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开桌面端'));
    await tester.pumpAndSettle();
    expect(service.openAppCalls, 2);
    expect(service.openedTarget, LocalCodingTarget.codexDesktop);
    expect(find.text('已打开 Codex 桌面端'), findsOneWidget);
    // 「打开」不走 launch(不选项目、不改配置)。
    expect(service.launchCalls, 0);
  });

  testWidgets('一键接入知办(已装 · 官方服务): 一次确认 → CLI 与桌面端依次写配置 + 验证 → 卡角标运行正常',
      (tester) async {
    // 共用配置:切了命令行之后桌面端仍按官方报告(没有它自己的切换记录),链会
    // 再为桌面端写一次;两个都切了才是完整的知办态。
    final switchedTargets = <LocalCodingTarget>{};
    LocalCodingToolsSnapshot current() =>
        switchedTargets.contains(LocalCodingTarget.codexDesktop)
            ? _snapshot(
                authorized: true,
                currentService: LocalCodingCurrentService.zhiban,
                globalVerificationLevel: 'l3',
                desktopGlobalVerificationLevel: 'l2',
                supportedMethods: const {'verify.execute'},
              )
            : switchedTargets.contains(LocalCodingTarget.codexCli)
                ? _snapshot(
                    authorized: true,
                    currentService: LocalCodingCurrentService.zhiban,
                    desktopCurrentService: LocalCodingCurrentService.official,
                    globalVerificationLevel: 'l3',
                    supportedMethods: const {'verify.execute'},
                  )
                : _snapshot(authorized: false);
    final service = _FakeOperations(
      inspect: () async => current(),
      switchToZhiban: (target) async {
        switchedTargets.add(target);
        return current();
      },
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.succeeded,
      stage: 'l3',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('接入知办模型 API 后无需官方账号即可使用'), findsNWidgets(2));
    await tester.tap(find.text('一键接入知办').first);
    await tester.pumpAndSettle();

    // F31 §3.2.1 · 一次确认:程序不用动,只列备份 / 写入 / 检测三步与本次涉及的两个形态。
    expect(find.text('先把程序准备好：'), findsNothing);
    expect(find.text('备份原有官方配置'), findsOneWidget);
    expect(find.text('写入知办模型 API 配置'), findsOneWidget);
    expect(find.text('检测服务连接是否正常'), findsOneWidget);
    expect(find.text('本次接入：Codex CLI、Codex 桌面端'), findsOneWidget);
    expect(find.text('之后可随时恢复官方配置'), findsOneWidget);
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();

    // 先切 CLI:进度弹框按形态分块,CLI 进入「检测服务连接」,桌面端等待中;
    // 程序不用动,步骤里没有安装那四步。
    expect(service.switchCalls, 1);
    expect(service.switchedTargets, [LocalCodingTarget.codexCli]);
    expect(find.text('正在接入 Codex'), findsOneWidget);
    expect(find.text('命令行'), findsOneWidget);
    expect(find.text('桌面端'), findsOneWidget);
    expect(find.text('写入知办配置'), findsNWidgets(2));
    expect(find.text('检测服务连接'), findsOneWidget);
    expect(find.text('校验配置与凭证'), findsOneWidget);
    expect(find.text('下载安装包'), findsNothing);
    expect(find.text('等待中...'), findsOneWidget);
    expect(service.lastVerifyScope, LocalCodingVerifyScope.global);

    // CLI 验证轮询到 succeeded → 切桌面端 → 桌面端验证 → 全部完成。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(service.switchCalls, 2);
    expect(service.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('正在接入 Codex'), findsNothing);
    expect(find.text('接入完成，Codex 已可以使用知办模型 API'), findsOneWidget);
    // 配置只在进程启动时读:提示第二行说清已打开的会话要重开(2026-09-17)。
    expect(find.text('已打开的终端和桌面端要重新打开才生效'), findsOneWidget);
    // 2026-09-15 · 完成提示是顶部浮动通知:成功 3 秒后自动淡出并从页面状态清掉。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('接入完成，Codex 已可以使用知办模型 API'), findsNothing);
    // CLI L3 + 桌面端 L2 → 卡角标「运行正常」,当前服务「知办模型 API」。
    expect(find.text('运行正常'), findsNWidgets(2));
    expect(find.text('知办模型 API'), findsNWidgets(2));
    expect(find.text('恢复官方配置'), findsNWidgets(2));
    // 2026-09-14 卡片改版:恢复官方配置是「当前服务」行尾的文字链接,不再是按钮。
    expect(find.widgetWithText(TextButton, '恢复官方配置'), findsNWidgets(2));
    expect(find.text('一键接入知办'), findsNothing);
    expect(service.startVerifyCalls, 2);
  });

  testWidgets('已切换卡片可卡级恢复官方配置(两形态一起),进度弹框按形态显示后自动关闭',
      (tester) async {
    var restored = false;
    // 第一个形态的恢复卡在这里,好观察进度弹框;放行后两个形态依次完成。
    final gate = Completer<void>();
    final service = _FakeOperations(
      inspect: () async => restored
          ? _snapshot(authorized: true)
          : _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              globalVerificationLevel: 'l3',
              desktopGlobalVerificationLevel: 'l2',
            ),
      restoreOfficial: (_) async {
        await gate.future;
        restored = true;
        return _snapshot(authorized: true);
      },
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('运行正常'), findsNWidgets(2));
    expect(find.text('原配置已安全备份，随时可以恢复官方配置'), findsNWidgets(2));

    await tester.tap(find.text('恢复官方配置').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('知办不再自动更新版本，已安装的版本保留'), findsOneWidget);
    expect(find.textContaining('将按切换时的备份恢复 Codex CLI、Codex 桌面端 原有配置'),
        findsOneWidget);
    await tester.tap(find.text('恢复'));
    await tester.pump();
    await tester.pump();

    // 2026-09-11 · 恢复也走进度弹框:CLI 先恢复,桌面端等待;步骤条两步。
    expect(find.text('正在恢复 Codex 官方配置'), findsOneWidget);
    expect(find.text('正在恢复原有配置...'), findsOneWidget);
    expect(find.text('等待中...'), findsOneWidget);
    expect(find.text('恢复原有配置'), findsNWidgets(2));
    expect(find.text('检测软件状态'), findsNWidgets(2));

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在恢复 Codex 官方配置'), findsNothing);

    expect(service.restoreCalls, 2);
    expect(service.restoredTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(find.text('已恢复 Codex 官方配置'), findsOneWidget);
    expect(find.text('已打开的终端和桌面端要重新打开才生效'), findsOneWidget);
    expect(find.text('官方服务'), findsNWidgets(2));
  });

  testWidgets(
      '12900 真机 · 命令行验证失败后恢复官方配置:遗留的失败记录不再让卡片「需要处理」,主按钮不得是「修复并重试」',
      (tester) async {
    // Codex 命令行 L3 真实请求失败、桌面端 L2 通过。当时「恢复官方配置」只作用在
    // 桌面端上,共用配置还原后命令行那条失败记录没人清;现在需要处理的命令行也一起恢复。
    var restored = false;
    final service = _FakeOperations(
      inspect: () async => restored
          ? _snapshot(authorized: true)
          : _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              globalVerificationLevel: 'l3',
              desktopGlobalVerificationLevel: 'l2',
              supportedMethods: const {'verify.execute'},
            ),
      restoreOfficial: (_) async {
        restored = true;
        return _snapshot(authorized: true);
      },
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.failed,
            stage: 'l3',
            errorCode: 'LCT-CODEX_CLI-GATEWAY-UNREACHABLE',
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
    expect(service.verifiedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(find.text('需要处理'), findsOneWidget);
    expect(find.text('修复并重试'), findsOneWidget);

    await tester.tap(find.text('恢复官方配置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(service.restoredTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(find.text('已恢复 Codex 官方配置'), findsOneWidget);
    expect(find.text('官方服务'), findsNWidgets(2));
    expect(find.text('需要处理'), findsNothing);
    expect(find.text('修复并重试'), findsNothing);
    expect(service.switchCalls, 0);
  });

  testWidgets('陷阱 §41 · 配置在别处回到官方后,遗留的验证失败记录不再算「需要处理」',
      (tester) async {
    // 用户在知办之外把配置改回官方(或另一形态的恢复把共用配置带回官方):
    // 没有任何恢复批处理来清这条失败记录,状态判定必须自己看配置还指不指向知办。
    var official = false;
    final service = _FakeOperations(
      inspect: () async => official
          ? _snapshot(authorized: true)
          : _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              globalVerificationLevel: 'l3',
              desktopGlobalVerificationLevel: 'l2',
              supportedMethods: const {'verify.execute'},
            ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.failed,
            stage: 'l3',
            errorCode: 'LCT-CODEX_CLI-GATEWAY-UNREACHABLE',
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
    expect(find.text('需要处理'), findsOneWidget);

    official = true;
    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    expect(service.restoreCalls, 0);
    expect(find.text('官方服务'), findsNWidgets(2));
    expect(find.text('需要处理'), findsNothing);
    expect(find.text('修复并重试'), findsNothing);
  });

  testWidgets(
      '2026-09-18 · 需要处理的形态也能恢复官方配置:Claude 命令行连不上知办,恢复时与桌面端一起还原',
      (tester) async {
    // Claude 两形态的配置是分开的:只恢复状态正常的桌面端,命令行会一直指向知办。
    var restored = false;
    final service = _FakeOperations(
      inspect: () async => restored
          ? _snapshot(authorized: true)
          : _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              globalVerificationLevel: 'l3',
              desktopGlobalVerificationLevel: 'l2',
              supportedMethods: const {'verify.execute'},
            ),
      restoreOfficial: (_) async {
        restored = true;
        return _snapshot(authorized: true);
      },
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.failed,
            stage: 'l3',
            errorCode: 'LCT-CLAUDE_CLI-GATEWAY-UNREACHABLE',
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 第二张卡是 Claude。
    await tester.tap(find.text('重新检测').last);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
    expect(service.verifiedTargets,
        [LocalCodingTarget.claudeCli, LocalCodingTarget.claudeDesktop]);
    expect(find.text('需要处理'), findsOneWidget);
    // 主按钮仍是修复并重试;恢复官方配置是多出来的一条退路。
    expect(find.text('修复并重试'), findsOneWidget);

    await tester.tap(find.text('恢复官方配置').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('将按切换时的备份恢复 Claude Code、Claude 桌面端 原有配置'),
        findsOneWidget);
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(service.restoredTargets,
        [LocalCodingTarget.claudeCli, LocalCodingTarget.claudeDesktop]);
    expect(find.text('已恢复 Claude 官方配置'), findsOneWidget);
    expect(find.text('需要处理'), findsNothing);
    expect(find.text('修复并重试'), findsNothing);
    expect(service.switchCalls, 0);
  });

  testWidgets('只装了桌面端:角标最高「已配置」,不得显示「运行正常」;可直接打开桌面端并补装命令行', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        toolUiState: LocalCodingToolUiState.notInstalled,
        currentService: LocalCodingCurrentService.zhiban,
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'install.execute', 'verify.execute'},
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('已配置'), findsNWidgets(2));
    expect(find.text('运行正常'), findsNothing);
    expect(find.text('已配置知办模型 API'), findsNWidgets(2));
    expect(find.text('已安装（桌面端）· 命令行未安装'), findsNWidgets(2));
    expect(find.text('未安装'), findsNothing);
    // 只装了一种形态 → 「打开」不下拉,直接写明形态。
    expect(find.text('打开桌面端'), findsNWidgets(2));
    expect(find.text('打开 CLI'), findsNothing);
    expect(find.text('打开'), findsNothing);
    expect(find.text('恢复官方配置'), findsNWidgets(2));
    // 已装一种形态时点名补装哪一种(2026-09-14:「下载安装」让人以为要重装已有的)。
    expect(find.text('安装命令行'), findsNWidgets(2));
    expect(find.text('下载安装'), findsNothing);
    expect(find.text('查看系统要求'), findsNWidgets(2));
  });

  testWidgets('未安装卡:「一键接入知办」一次确认后依次装命令行 + 桌面端,再写配置、检测;进度弹框按形态分块', (tester) async {
    var installed = false;
    // 每个形态切过才按知办报告(共用配置也要各自的切换记录)。
    final switchedTargets = <LocalCodingTarget>{};
    LocalCodingToolsSnapshot current() => _snapshot(
          authorized: switchedTargets.isNotEmpty,
          toolUiState: installed
              ? LocalCodingToolUiState.installedUnmanaged
              : LocalCodingToolUiState.notInstalled,
          desktopUiState: installed
              ? LocalCodingToolUiState.installedUnmanaged
              : LocalCodingToolUiState.notInstalled,
          currentService: switchedTargets.contains(LocalCodingTarget.codexCli)
              ? LocalCodingCurrentService.zhiban
              : LocalCodingCurrentService.official,
          desktopCurrentService:
              switchedTargets.contains(LocalCodingTarget.codexDesktop)
                  ? LocalCodingCurrentService.zhiban
                  : LocalCodingCurrentService.official,
          globalVerificationLevel:
              switchedTargets.contains(LocalCodingTarget.codexCli) ? 'l3' : '',
          desktopGlobalVerificationLevel:
              switchedTargets.contains(LocalCodingTarget.codexDesktop)
                  ? 'l2'
                  : '',
          supportedMethods: const {
            'requirements.get',
            'install.plan',
            'install.execute',
            'operation.get',
            'operation.cancel',
            'verify.execute',
          },
        );
    final service = _FakeOperations(
      inspect: () async => current(),
      switchToZhiban: (target) async {
        switchedTargets.add(target);
        return current();
      },
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'downloading',
      progressKind: LocalCodingProgressKind.determinate,
      progressValue: 40,
      cancellable: true,
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.succeeded,
      stage: 'detecting',
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 角标 + 软件状态行各一处 × 两张卡。
    expect(find.text('未安装'), findsNWidgets(4));
    expect(find.text('下载安装'), findsNothing);
    expect(find.text('查看系统要求'), findsNWidgets(2));
    expect(find.textContaining('安装后自动接入知办模型 API，无需官方账号即可使用 Codex'),
        findsOneWidget);
    expect(find.textContaining('命令行版与桌面版会一起安装'), findsNWidgets(2));

    // 卡级「一键接入知办」→ 一次确认框列出要装的两个形态,再开始;先装 CLI。
    await tester.tap(find.widgetWithText(FilledButton, '一键接入知办').first);
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('· 安装 Codex CLI'), findsOneWidget);
    expect(find.text('· 安装 Codex 桌面端'), findsOneWidget);
    expect(find.text('本次接入：Codex CLI、Codex 桌面端'), findsOneWidget);
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();
    expect(service.installedTargets, [LocalCodingTarget.codexCli]);

    // 进度弹框两块:命令行下载中,桌面端等待中;每块都是 安装四步 + 写配置 + 检测。
    expect(find.text('正在接入 Codex'), findsOneWidget);
    expect(find.text('命令行'), findsOneWidget);
    expect(find.text('桌面端'), findsOneWidget);
    expect(find.text('正在下载安装包...'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('等待中...'), findsOneWidget);
    for (final step in ['下载安装包', '验证安装包', '安装应用', '检测软件状态', '写入知办配置']) {
      expect(find.text(step), findsNWidgets(2));
    }
    expect(find.text('检测服务连接'), findsOneWidget);
    expect(find.text('校验配置与凭证'), findsOneWidget);
    expect(find.text('要下载新版本时通常需要 1–3 分钟，否则半分钟内完成'), findsOneWidget);

    // CLI 装好 → 写配置 → 检测 → 桌面端同样三步 → 完成后自动关闭。
    installed = true;
    // 逐个 operation 轮询到终态;完成横幅 3 秒后会淡出,所以只推进到第二次验证发起。
    for (var i = 0; i < 12 && service.startVerifyCalls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(service.installedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(service.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(service.startVerifyCalls, 2);
    expect(find.text('正在接入 Codex'), findsNothing);
    expect(find.text('接入完成，Codex 已可以使用知办模型 API'), findsOneWidget);
    expect(find.text('已安装（命令行 + 桌面端）'), findsNWidgets(2));
    expect(find.text('运行正常'), findsNWidgets(2));
    expect(find.text('一键接入知办'), findsNothing);
    expect(find.text('需要处理'), findsNothing);
  });

  testWidgets('F31 v3.11 · 接入进度弹框可关闭:后台继续,卡片「查看进度」可重开,完成后横幅', (tester) async {
    var installed = false;
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: false,
        // 环境未开放:接入链只做第①步(安装),装完即停,好只盯弹框的开合。
        registrationAvailable: false,
        toolUiState: installed
            ? LocalCodingToolUiState.installedUnmanaged
            : LocalCodingToolUiState.notInstalled,
        desktopUiState: installed
            ? LocalCodingToolUiState.installedUnmanaged
            : LocalCodingToolUiState.notInstalled,
        supportedMethods: const {
          'requirements.get',
          'install.plan',
          'install.execute',
          'operation.get',
          'operation.cancel',
          'verify.execute',
        },
      ),
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'downloading',
      progressKind: LocalCodingProgressKind.determinate,
      progressValue: 40,
      cancellable: true,
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.succeeded,
      stage: 'detecting',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '一键接入知办').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在接入 Codex'), findsOneWidget);
    expect(find.text('关闭此窗口不会中断接入，可随时在卡片上点「查看进度」'),
        findsOneWidget);

    // 右上角 × 关闭:弹框消失,安装没被取消,卡片进入进行中并给「查看进度」。
    await tester.tap(find.byKey(const ValueKey('batch-progress-close')));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在接入 Codex'), findsNothing);
    expect(service.cancelledOperations, isEmpty);
    expect(find.text('查看进度'), findsOneWidget);

    // 「查看进度」重新打开同一弹框,Esc 也能关。
    await tester.tap(find.text('查看进度'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在接入 Codex'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.text('正在接入 Codex'), findsNothing);

    // 后台继续:CLI 完成 → 装桌面端 → 完成后横幅,弹框不再出现。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(service.installedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    installed = true;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('正在接入 Codex'), findsNothing);
    expect(find.text('安装完成，Codex 已可以在本机使用'), findsOneWidget);
    expect(find.text('查看进度'), findsNothing);
    expect(find.text('已安装（命令行 + 桌面端）'), findsNWidgets(2));
  });

  testWidgets('命令行安装损坏:卡显示需要处理,修复并重试 / 诊断详情为卡级,桌面端仍可打开', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: false,
        toolUiState: LocalCodingToolUiState.repairable,
        supportedMethods: const {'diagnostics.get_latest', 'install.execute'},
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('需要处理'), findsNWidgets(2));
    expect(find.text('无法连接'), findsNWidgets(2));
    expect(find.text('安装已损坏（命令行）'), findsNWidgets(2));
    expect(find.text('Codex CLI 安装已损坏，点「修复并重试」按锁定版本重新安装'), findsOneWidget);
    expect(find.text('修复并重试'), findsNWidgets(2));
    expect(find.text('诊断详情'), findsNWidgets(2));
    expect(find.text('打开'), findsNWidgets(2));
  });

  testWidgets(
      '契约 §2.7.2 · global_drifted 卡显示需要处理并提供修复并重试;2026-09-18 起也能恢复官方配置',
      (tester) async {
    var restored = false;
    final service = _FakeOperations(
      inspect: () async => restored
          ? _snapshot(authorized: true)
          : _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              globalDrifted: true,
              supportedMethods: const {
                'diagnostics.get_latest',
                'verify.execute'
              },
            ),
      restoreOfficial: (_) async {
        restored = true;
        return _snapshot(authorized: true);
      },
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('需要处理'), findsNWidgets(2));
    expect(find.text('配置已改动'), findsNWidgets(2));
    expect(find.textContaining('知办模型 API 配置被修改，点「修复并重试」重写知办线路'), findsNWidgets(2));
    expect(find.text('修复并重试'), findsNWidgets(2));
    expect(find.text('运行正常'), findsNothing);

    // 两个形态都需要处理时也留着退回官方的路(此前没有任何形态状态正常就没有入口)。
    expect(find.text('恢复官方配置'), findsNWidgets(2));
    await tester.tap(find.text('恢复官方配置').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('将按切换时的备份恢复 Codex CLI、Codex 桌面端 原有配置'),
        findsOneWidget);
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(service.restoredTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(find.text('已恢复 Codex 官方配置'), findsOneWidget);
  });

  testWidgets('已切换但本机设备授权没了(退出过知办 / 切过环境 / 重装):需要处理,修复并重试重新接入', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: false,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'diagnostics.get_latest', 'verify.execute'},
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('运行正常'), findsNothing);
    expect(find.text('需要处理'), findsNWidgets(2));
    expect(find.text('授权已失效'), findsNWidgets(2));
    expect(find.textContaining('设备授权已失效（可能退出过知办、切换过环境或重装过），点「修复并重试」重新接入'),
        findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, '修复并重试'), findsNWidgets(2));
  });

  testWidgets('契约 §2.7 B3 · 知办配置缺少本机切换记录:需要处理,说明原因,修复并重试走重新切换', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalDrifted: true,
        globalSwitched: false,
        supportedMethods: const {'diagnostics.get_latest', 'verify.execute'},
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('需要处理'), findsNWidgets(2));
    expect(find.text('缺少切换记录'), findsNWidgets(2));
    expect(find.text('配置已改动'), findsNothing);
    expect(find.textContaining('缺少本机切换记录（可能重装或清理过知办），点「修复并重试」重新接入'),
        findsNWidgets(2));
    expect(find.text('修复并重试'), findsNWidgets(2));
  });

  testWidgets('v1.7 §2.2 · 命令行 unsupported:软件状态点名,主按钮「查看原因」翻译 DETECT-* 码',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: false,
        toolUiState: LocalCodingToolUiState.unsupported,
        toolErrorCode: 'LCT-CODEX_CLI-DETECT-UNTRUSTED_PATH',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('已安装（桌面端）· 命令行暂不支持'), findsNWidgets(2));
    expect(find.text('查看原因'), findsNWidgets(2));
    // 来源不明的命令行 Bridge 不执行:只给桌面端的打开,不给点了必失败的按钮。
    expect(find.text('打开桌面端'), findsNWidgets(2));
    expect(find.text('打开'), findsNothing);
    expect(find.text('打开 CLI'), findsNothing);
    expect(find.textContaining('不影响你在终端或应用里照常使用'), findsNWidgets(2));
    expect(find.text('重新检测'), findsWidgets);

    await tester.tap(find.text('查看原因').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法通过来源校验'), findsOneWidget);
    expect(
        find.text('错误码：LCT-CODEX_CLI-DETECT-UNTRUSTED_PATH'), findsOneWidget);
  });

  testWidgets('v1.7 §7.3 · policy_conflict 解释企业 managed-settings,卡级切换只作用桌面端',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        policyConflictTarget: LocalCodingTarget.claudeCli,
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('已安装（桌面端）· 命令行暂不支持'), findsOneWidget);
    expect(find.text('查看原因'), findsOneWidget);
    await tester.ensureVisible(find.text('查看原因'));
    await tester.tap(find.text('查看原因'));
    await tester.pumpAndSettle();
    expect(find.textContaining('企业'), findsOneWidget);
    expect(find.textContaining('managed-settings'), findsOneWidget);
    expect(
        find.text('错误码：LCT-CLAUDE_CLI-CONFIG-POLICY_CONFLICT'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(find.text('一键接入知办'), findsNWidgets(2));
    expect(find.text('修复并重试'), findsNothing);
    await tester.tap(find.text('一键接入知办').last);
    await tester.pumpAndSettle();
    expect(find.text('本次接入：Claude 桌面端'), findsOneWidget);
  });

  testWidgets('已切换待检测 + 另一形态暂不支持:主按钮是重新检测,「查看原因」不抢主按钮', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        desktopCurrentService: LocalCodingCurrentService.official,
        desktopUiState: LocalCodingToolUiState.unsupported,
        desktopErrorCode: 'LCT-CODEX_DESKTOP-DETECT-UNTRUSTED_PATH',
        supportedMethods: const {'verify.execute'},
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('已切换为知办模型 API，尚未检测服务连接'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, '重新检测'), findsNWidgets(2));
    expect(find.text('查看原因'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, '查看原因'), findsNothing);
  });

  testWidgets('2026-09-17 · 进页面只检测:已装未接入的形态不自动切换,主按钮「一键接入知办」', (tester) async {
    final service = _FakeOperations(
      inspect: () async =>
          _snapshot(authorized: true, supportedMethods: const {'verify.execute'}),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    expect(service.switchCalls, 0);
    expect(find.text('官方服务'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, '一键接入知办'), findsNWidgets(2));
    expect(find.text('开始接入'), findsNothing);
    expect(find.text('正在接入 Codex'), findsNothing);
    expect(find.text('版本管理'), findsNothing);
  });

  testWidgets('2026-09-15 · 已切换卡片重新检测:不弹进度弹框,验证服务连接显示在卡片里,结果用浮动通知',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'verify.execute'},
      ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.succeeded,
      stage: 'l3',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 读完本机状态后接着验证:进度在 Codex 卡底部,没有全屏进度弹框。
    expect(find.text('正在检测 Codex'), findsNothing);
    expect(find.text('正在验证服务连接…'), findsOneWidget);
    expect(find.text('正在检测'), findsOneWidget);

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
    expect(service.verifiedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(service.lastVerifyScope, LocalCodingVerifyScope.global);
    expect(find.text('正在检测'), findsNothing);
    // 检测的是整台机器:标题"检测完成",第二行才是这张卡的连接结果。
    expect(find.text('检测完成'), findsOneWidget);
    expect(find.text('Codex 服务连接正常'), findsOneWidget);
  });

  for (final verified in [false, true]) {
    testWidgets('代理配置未覆盖不覆盖真实验证状态: verified=$verified', (tester) async {
      final service = _FakeOperations(
        inspect: () async => _snapshot(
          authorized: true,
          currentService: LocalCodingCurrentService.zhiban,
          globalVerificationLevel: verified ? 'l3' : '',
          desktopGlobalVerificationLevel: verified ? 'l2' : '',
          proxyStatus: _uncoveredProxy(),
        ),
      );
      await _pumpPage(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('需要处理'), findsNothing);
      expect(find.text('被系统代理拦截'), findsNothing);
      expect(find.textContaining('可能受'), findsNothing);
      expect(find.text('修复并重试'), findsNothing);
      if (verified) {
        expect(find.text('运行正常'), findsNWidgets(2));
      } else {
        expect(find.text('运行正常'), findsNothing);
        expect(find.text('待检测'), findsWidgets);
      }
      expect(service.proxyFixCalls, 0);
    });
  }

  testWidgets('首次接入保留代理设置,不预先设直连例外', (tester) async {
    var switched = false;
    LocalCodingToolsSnapshot snapshot() => _snapshot(
          authorized: true,
          currentService: switched
              ? LocalCodingCurrentService.zhiban
              : LocalCodingCurrentService.official,
          proxyStatus: _uncoveredProxy(),
        );
    final service = _FakeOperations(
      inspect: () async => snapshot(),
      switchToZhiban: (_) async {
        switched = true;
        return snapshot();
      },
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '一键接入知办').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('会被它拦截'), findsNothing);
    expect(find.textContaining('代理例外'), findsNothing);
    await tester.tap(find.text('开始接入'));
    await tester.pumpAndSettle();
    expect(service.switchCalls, greaterThan(0));
    expect(service.proxyFixCalls, 0);
  });

  for (final failure in ['PROXY_INTERFERENCE', 'QUOTA_EXHAUSTED']) {
    testWidgets('真实请求失败才诊断,代理线索不覆盖其它错误:$failure', (tester) async {
      final service = _FakeOperations(
        inspect: () async => _snapshot(
          authorized: true,
          currentService: LocalCodingCurrentService.zhiban,
          globalVerificationLevel: 'l3',
          desktopGlobalVerificationLevel: 'l2',
          proxyStatus: _uncoveredProxy(),
          supportedMethods: const {'verify.execute'},
        ),
      );
      service.startVerifyResponse = _operation(
        kind: LocalCodingOperationKind.verify,
        state: LocalCodingOperationState.running,
        stage: 'l1',
      );
      var fail = true;
      service.pollHandler = () => fail && service.verifiedTargets.length == 1
          ? _operation(
              kind: LocalCodingOperationKind.verify,
              state: LocalCodingOperationState.failed,
              stage: 'l3',
              errorCode: 'LCT-CODEX_CLI-GATEWAY-$failure',
              errorDetail: failure == 'QUOTA_EXHAUSTED'
                  ? 'HTTP 429 · quota exceeded'
                  : '连接超时')
          : _operation(
              kind: LocalCodingOperationKind.verify,
              state: LocalCodingOperationState.succeeded,
              stage: 'l2');
      await _pumpPage(tester, service);
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新检测').first);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.pumpAndSettle();
      if (failure == 'PROXY_INTERFERENCE') {
        expect(find.text('连接失败，可能受代理影响'), findsOneWidget);
        expect(find.text('修复并重试'), findsOneWidget);
      } else {
        expect(find.text('中转站拒绝请求'), findsOneWidget);
        expect(find.textContaining('可能受'), findsNothing);
      }
      expect(service.proxyFixCalls, 0);
      fail = false;
      await tester.tap(find.text('重新检测').first);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.pumpAndSettle();
      expect(find.text('连接失败，可能受代理影响'), findsNothing);
      expect(find.text('需要处理'), findsNothing);
      expect(service.proxyFixCalls, 0);
    });
  }

  testWidgets('2026-09-18 · 被代理软件转走:卡片说清原因,不引导修复并重试,主按钮是重新检测', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'verify.execute'},
      ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.failed,
            stage: 'l3',
            errorCode: 'LCT-CODEX_CLI-GATEWAY-PROXY_DIVERTED',
            errorDetail: '探测超时（90 秒内没有任何回答）',
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    expect(find.text('连接失败，可能受代理影响'), findsWidgets);
    expect(find.textContaining('把 airick.cn 设为直连'), findsWidgets);
    expect(find.textContaining('直连规则见「诊断详情」'), findsWidgets);
    expect(find.text('无法连接'), findsNothing);
    // 知办修不了用户的代理软件:不给「修复并重试」,主按钮是重新检测。
    expect(find.text('修复并重试'), findsNothing);
    expect(find.widgetWithText(FilledButton, '重新检测'), findsOneWidget);
  });

  testWidgets(
      '2026-09-20 · 积分用完:卡片直说积分用完和去哪充值,不报授权失效,不给修复并重试',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'verify.execute'},
      ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.failed,
            stage: 'l2',
            errorCode: 'LCT-CODEX_CLI-AUTH-INSUFFICIENT_CREDIT',
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    expect(find.text('积分已用完'), findsWidgets);
    expect(find.textContaining('套餐与积分'), findsWidgets);
    expect(find.text('授权已失效'), findsNothing);
    expect(find.text('无法连接'), findsNothing);
    expect(find.textContaining('中转站原话'), findsNothing);
    // 重新接入换不回一把被停发的 Key:不给「修复并重试」,充值到账后重新检测即可。
    expect(find.text('修复并重试'), findsNothing);
    expect(find.widgetWithText(FilledButton, '重新检测'), findsOneWidget);
  });

  testWidgets(
      '2026-09-20 · 备用模型通过:卡片仍是运行正常,提示当前配置的模型线路不可用、可换模型',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'verify.execute'},
      ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollHandler = () => service.verifiedTargets.length <= 1
        ? _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l3',
            result: const {
              'verification_level': 'l3',
              'verified_at': '2026-09-20T10:00:00Z',
              'model_warning': {
                'error_code': 'LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE',
                'error_detail': 'HTTP 502 · Upstream request failed',
                'working_model': 'gpt-5.6-terra',
              },
            },
          )
        : _operation(
            kind: LocalCodingOperationKind.verify,
            state: LocalCodingOperationState.succeeded,
            stage: 'l2',
          );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    // 服务是通的:不判失败、不给修复并重试;但要说清换个模型就能用。
    expect(find.text('运行正常'), findsWidgets);
    expect(find.text('修复并重试'), findsNothing);
    expect(find.text('无法连接'), findsNothing);
    expect(find.textContaining('当前配置的模型线路暂时不可用（HTTP 502）'), findsWidgets);
    expect(find.textContaining('gpt-5.6-terra'), findsWidgets);
  });

  testWidgets('2026-09-15 · 中转站 503:卡片说清是中转站的问题,不引导修复并重试,诊断详情给中转站原话',
      (tester) async {
    const detail =
        'HTTP 503 · auth_unavailable: no auth available (providers=codex, model=gpt-5.6-luna)';
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        supportedMethods: const {'verify.execute', 'diagnostics.get_latest'},
      ),
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.failed,
      stage: 'l3',
      errorCode: 'LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE',
      errorDetail: detail,
    );
    service.diagnosticsResponse = LocalCodingDiagnostics(
      target: LocalCodingTarget.codexCli,
      bridgeVersion: '0.5.0',
      kind: 'verify',
      stage: 'l3',
      errorCode: 'LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE',
      errorDetail: detail,
      occurredAt: '2026-09-15T12:00:00Z',
      suggestions: const ['知办中转站暂时不可用，不是本机问题，稍后点「重新检测」'],
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新检测').first);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();

    expect(find.text('Codex：知办中转站暂时不可用（HTTP 503），不是本机问题，稍后再检测'),
        findsOneWidget);
    expect(find.text('中转站暂时不可用'), findsWidgets);
    expect(find.textContaining('中转站原话见「诊断详情」'), findsWidgets);
    expect(find.text('无法连接'), findsNothing);
    // 修复并重试修不好中转站:主按钮是重新检测。
    expect(find.text('修复并重试'), findsNothing);
    expect(find.widgetWithText(FilledButton, '重新检测'), findsOneWidget);

    await tester.tap(find.text('诊断详情').first);
    await tester.pumpAndSettle();
    expect(find.text('中转站返回'), findsOneWidget);
    expect(find.text(detail), findsOneWidget);
  });

  testWidgets('2026-09-15 · 服务连接行显示上次验证连通的时间,读本机状态不算检测', (tester) async {
    final verifiedAt = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 2, minutes: 5))
        .toIso8601String();
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        currentService: LocalCodingCurrentService.zhiban,
        globalVerificationLevel: 'l3',
        desktopGlobalVerificationLevel: 'l2',
        globalLastVerifiedAt: verifiedAt,
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 刚检测完本机状态,但连接是 2 小时前验证的:不显示"刚刚检测"。
    expect(find.text('· 2 小时前检测'), findsNWidgets(2));
    expect(find.text('· 刚刚检测'), findsNothing);
  });

  testWidgets('2026-09-15 · 走官方服务的卡片不显示检测时间', (tester) async {
    final service =
        _FakeOperations(inspect: () async => _snapshot(authorized: true));
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('官方服务'), findsNWidgets(2));
    expect(find.textContaining('前检测'), findsNothing);
    expect(find.text('· 刚刚检测'), findsNothing);
  });

  testWidgets('2026-09-15 · Codex 命令行低于最低版本且没有接管路径:Codex 卡不给接入,说明怎么升级,仍可打开', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(authorized: true, codexCliTooOld: true),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // Codex 卡:命令行过旧、目录也接管不了,共用配置的桌面端也接不了;Claude 卡照常可接入。
    expect(find.text('一键接入知办'), findsOneWidget);
    expect(
        find.textContaining('版本（0.130.0）过旧，升级到 0.137.0 或更高版本后才能切换为知办模型 API'),
        findsOneWidget);
    expect(find.textContaining('npm i -g @openai/codex@latest'), findsOneWidget);
    expect(find.text('打开'), findsNWidgets(2));
  });

  testWidgets('2026-09-15 · Claude 桌面端太老不支持第三方模型配置且目录没给新版:说明需更新,接入只作用命令行', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        claudeDesktopErrorCode: 'LCT-CLAUDE_DESKTOP-DETECT-THIRD_PARTY_UNSUPPORTED',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.textContaining('版本（1.46388.4）过旧，还不支持第三方模型配置'), findsOneWidget);
    expect(find.text('一键接入知办'), findsNWidgets(2));
    await tester.tap(find.text('一键接入知办').last);
    await tester.pumpAndSettle();
    expect(find.text('本次接入：Claude Code'), findsOneWidget);
  });

  testWidgets('契约 §2.7.3 · 桌面端 supports_enable=false:卡内说明,接入只作用 CLI',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        desktopSupportsEnable: false,
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.textContaining('桌面端 暂不支持知办模型 API'), findsNWidgets(2));
    expect(find.text('打开'), findsNWidgets(2));
    expect(find.text('已安装'), findsNWidgets(2));

    await tester.tap(find.text('一键接入知办').first);
    await tester.pumpAndSettle();
    expect(find.text('本次接入：Codex CLI'), findsOneWidget);
  });

  testWidgets('接入部分失败:桌面端块停在弹框显示错误码,关闭后卡显示部分接入并可再接入', (tester) async {
    var switched = false;
    final service = _FakeOperations(
      inspect: () async => switched
          ? _snapshot(
              authorized: true,
              currentService: LocalCodingCurrentService.zhiban,
              desktopCurrentService: LocalCodingCurrentService.official,
              globalVerificationLevel: 'l3',
              supportedMethods: const {'verify.execute'},
            )
          : _snapshot(authorized: false),
      switchToZhiban: (target) async {
        if (target.isDesktop) {
          throw const LocalCodingToolsException(
              'LCT-CODEX_DESKTOP-CONFIG-WRITE_FAILED', '桌面端切换失败');
        }
        switched = true;
        return _snapshot(
          authorized: true,
          currentService: LocalCodingCurrentService.zhiban,
          desktopCurrentService: LocalCodingCurrentService.official,
          supportedMethods: const {'verify.execute'},
        );
      },
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.succeeded,
      stage: 'l3',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.text('一键接入知办').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // 桌面端失败 → 弹框停留,写明停在写配置这步并显示错误码;不出现"接入完成"横幅。
    expect(find.text('正在接入 Codex'), findsOneWidget);
    expect(find.text('写入配置未完成'), findsOneWidget);
    expect(
        find.text('错误码 LCT-CODEX_DESKTOP-CONFIG-WRITE_FAILED'), findsOneWidget);
    expect(find.text('接入完成，Codex 已可以使用知办模型 API'), findsNothing);
    expect(service.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(service.startVerifyCalls, 1);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('正在接入 Codex'), findsNothing);

    // CLI 已切且 L3、桌面端仍官方 → 当前服务「知办模型 API（部分）」,
    // 可再接入桌面端,也可恢复 CLI。
    expect(find.text('知办模型 API（部分）'), findsNWidgets(2));
    expect(find.text('一键接入知办'), findsNWidgets(2));
    expect(find.text('恢复官方配置'), findsNWidgets(2));
    expect(find.text('打开'), findsNWidgets(2));
  });

  testWidgets('契约 §2.7.4 · 目录有更高版本:版本行标签提示可升级,「升级到 x」确认后走升级批处理',
      (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        supportedMethods: const {
          'install.plan',
          'install.execute',
          'operation.get',
          'verify.execute',
          'catalog.apply',
        },
        availableVersion: '0.154.0',
      ),
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'downloading',
      progressKind: LocalCodingProgressKind.determinate,
      progressValue: 30,
      cancellable: true,
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.succeeded,
      stage: 'detecting',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 只有 Codex 命令行可升级(桌面端与 Claude 没有目录条目):版本行在命令行版本后
    // 带「新版本」标签,「升级到 x」在版本行尾;软件状态不再重复提示(2026-09-14 卡片改版)。
    expect(find.text('已安装（命令行 + 桌面端）· 有新版本'), findsNothing);
    expect(find.text('新版本 0.154.0'), findsOneWidget);
    expect(find.text('升级到 0.154.0'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
    // 页脚不再有单独的升级按钮:主按钮是一键接入知办,旁注说明会先升级。
    expect(find.widgetWithText(FilledButton, '升级到 0.154.0'), findsNothing);
    expect(find.textContaining('接入时会先把命令行升级到 0.154.0'), findsOneWidget);

    await tester.tap(find.text('升级到 0.154.0'));
    await tester.pumpAndSettle();
    expect(find.text('升级 Codex'), findsOneWidget);
    expect(find.textContaining('Codex CLI 0.153.4 → 0.154.0'), findsOneWidget);
    expect(find.textContaining('会直接修改本机现有的这份安装（包括你自己用官方安装器装的）'), findsOneWidget);
    expect(find.textContaining('发行方自带的自动更新之后可能会再次改变版本'), findsOneWidget);
    await tester.tap(find.text('升级'));
    await tester.pump();
    await tester.pump();
    expect(service.installedTargets, [LocalCodingTarget.codexCli]);
    expect(service.installModes, [LocalCodingInstallMode.upgrade]);
    expect(find.text('正在升级 Codex'), findsOneWidget);
    expect(find.text('正在下载新版本...'), findsOneWidget);
    for (final step in ['下载安装包', '验证安装包', '安装新版本', '检测软件状态']) {
      expect(find.text(step), findsOneWidget);
    }
    // 官方服务态不追加验证步。
    expect(find.text('检测服务连接'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(service.startVerifyCalls, 0);
    expect(find.text('升级完成，Codex CLI 0.154.0 已可以使用'), findsOneWidget);
  });

  testWidgets('2026-09-16 · npm 装的旧版本:「一键接入知办」先由知办接管到目录版本,再写配置、检测', (tester) async {
    // 升级只作用于发行方标准位置,npm 装的那份既升不了也装不了,以前这类用户
    // 卡在旧版本上没有任何可点的东西(测试用户 Codex 0.130.0)。
    var adopted = false;
    final switchedTargets = <LocalCodingTarget>{};
    const methods = {
      'install.plan',
      'install.execute',
      'operation.get',
      'verify.execute',
      'catalog.apply',
    };
    LocalCodingToolsSnapshot current() => adopted
        ? _snapshot(
            authorized: switchedTargets.isNotEmpty,
            currentService: switchedTargets.contains(LocalCodingTarget.codexCli)
                ? LocalCodingCurrentService.zhiban
                : LocalCodingCurrentService.official,
            desktopCurrentService:
                switchedTargets.contains(LocalCodingTarget.codexDesktop)
                    ? LocalCodingCurrentService.zhiban
                    : LocalCodingCurrentService.official,
            globalVerificationLevel:
                switchedTargets.contains(LocalCodingTarget.codexCli) ? 'l3' : '',
            desktopGlobalVerificationLevel:
                switchedTargets.contains(LocalCodingTarget.codexDesktop)
                    ? 'l2'
                    : '',
            supportedMethods: methods,
          )
        : _snapshot(
            authorized: false,
            supportedMethods: methods,
            codexCliTooOld: true,
            adoptVersion: '0.154.0',
          );
    final service = _FakeOperations(
      inspect: () async => current(),
      switchToZhiban: (target) async {
        switchedTargets.add(target);
        return current();
      },
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'downloading',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.succeeded,
      stage: 'detecting',
    );
    service.startVerifyResponse = _operation(
      kind: LocalCodingOperationKind.verify,
      state: LocalCodingOperationState.running,
      stage: 'l1',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    // 没有单独的升级 / 接管按钮:主按钮就是一键接入知办,旁注说明会先升级。
    expect(find.text('升级到 0.154.0'), findsNothing);
    expect(find.text('交给知办管理'), findsNothing);
    expect(find.text('版本管理'), findsNothing);
    expect(find.textContaining('接入时会先把命令行升级到 0.154.0'), findsOneWidget);
    await tester.tap(find.text('一键接入知办').first);
    await tester.pumpAndSettle();
    // 话术只讲用户关心的:升到哪、原来的留着、以后自动更新;不提 PATH 与安装位置。
    expect(find.textContaining('Codex CLI 0.130.0 → 0.154.0（由知办接管，你原来的版本会保留）'),
        findsOneWidget);
    expect(find.textContaining('以后有新版知办会自动更新'), findsOneWidget);
    expect(find.text('本次接入：Codex CLI、Codex 桌面端'), findsOneWidget);
    expect(find.textContaining('PATH'), findsNothing);
    await tester.tap(find.text('开始接入'));
    await tester.pump();
    await tester.pump();
    expect(service.installModes, [LocalCodingInstallMode.adopt]);
    expect(find.text('正在接入 Codex'), findsOneWidget);
    expect(find.text('安装新版本'), findsOneWidget);
    expect(find.text('正在下载安装包...'), findsOneWidget);

    adopted = true;
    // 逐个 operation 轮询到终态;完成横幅 3 秒后会淡出,所以只推进到第二次验证发起。
    for (var i = 0; i < 12 && service.startVerifyCalls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(service.installModes, [LocalCodingInstallMode.adopt]);
    expect(service.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(find.text('接入完成，Codex 已可以使用知办模型 API'), findsOneWidget);
  });

  testWidgets('2026-09-16 · 升级失败:弹框除了错误码还要给一句能照做的下一步', (tester) async {
    // 异步 operation 失败不抛异常,批处理项以前只带 errorCode,弹框里就只剩
    // 一行 LCT-…-TARGET_IN_USE,用户不知道要先退出桌面端。
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        supportedMethods: const {
          'install.plan',
          'install.execute',
          'operation.get',
          'verify.execute',
          'catalog.apply',
        },
        availableVersion: '0.154.0',
      ),
    );
    service.startInstallResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.running,
      stage: 'downloading',
    );
    service.pollResponse = _operation(
      kind: LocalCodingOperationKind.install,
      state: LocalCodingOperationState.failed,
      stage: 'installing',
      errorCode: 'LCT-CODEX_DESKTOP-INSTALL-TARGET_IN_USE',
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    await tester.tap(find.text('升级到 0.154.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('升级'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('升级失败'), findsOneWidget);
    expect(
        find.text('错误码 LCT-CODEX_DESKTOP-INSTALL-TARGET_IN_USE'), findsOneWidget);
    expect(find.text('请先完全退出 Codex 桌面端再升级（新版应用名是 ChatGPT，退出后再点一次）'),
        findsWidgets);
  });

  testWidgets('2026-09-15 · 只做升级不做回退:目录给了可回退版本,卡片也不出现回退', (tester) async {
    final service = _FakeOperations(
      inspect: () async => _snapshot(
        authorized: true,
        supportedMethods: const {
          'install.plan',
          'install.execute',
          'operation.get',
          'catalog.apply',
        },
        rollbackVersion: '0.152.0',
      ),
    );
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.textContaining('回退'), findsNothing);
    expect(find.text('更多'), findsNothing);
  });

}

Future<void> _pumpPage(
  WidgetTester tester,
  LocalCodingToolsOperations service,
) async {
  // 两张卡各两行比原型高;放大测试视口,让所有按钮都在可点击范围内。
  tester.view.physicalSize = const Size(1280, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localCodingToolsServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        builder: BotToastInit(),
        navigatorObservers: [BotToastNavigatorObserver()],
        home: const LocalCodingToolsPage(),
      ),
    ),
  );
  await tester.pump();
}

LocalCodingToolsSnapshot _snapshot({
  required bool authorized,
  bool registrationAvailable = true,
  LocalCodingTarget? policyConflictTarget,
  LocalCodingToolUiState toolUiState =
      LocalCodingToolUiState.installedUnmanaged,
  LocalCodingToolUiState desktopUiState =
      LocalCodingToolUiState.installedUnmanaged,
  Set<String> supportedMethods = const {},
  String toolErrorCode = '',
  LocalCodingCurrentService currentService = LocalCodingCurrentService.official,
  LocalCodingCurrentService? desktopCurrentService,
  String globalVerificationLevel = '',
  String desktopGlobalVerificationLevel = '',
  bool globalDrifted = false,
  bool desktopSupportsEnable = true,
  // 契约 §2.7.4 · 只落在 Codex 命令行上的目录字段。
  String availableVersion = '',
  // 2026-09-16 · 接管安装:Codex 命令行是 npm 装的,知办可以接管到这个版本。
  String adoptVersion = '',
  String rollbackVersion = '',
  String desktopErrorCode = '',
  // 契约 §2.7(B3):文件指向知办但没有切换记录时 global_switched 为 false。
  bool? globalSwitched,
  // 2026-09-15 · Codex 命令行是 npm 装的 0.130.0,低于最低可切换版本 0.137.0。
  bool codexCliTooOld = false,
  // 2026-09-15 · 只作用在 Claude 桌面端上的检测错误码(如不支持第三方模型配置)。
  String claudeDesktopErrorCode = '',
  // 2026-09-15 · 上次验证连通的时间(ISO 8601),服务连接行显示它。
  String globalLastVerifiedAt = '',
  // 契约 §2.7 network.* · 系统代理状态(老 Bridge 不回时为 null)。
  LocalCodingProxyStatus? proxyStatus,
}) {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  String versionFor(LocalCodingTarget target) => switch (target) {
        LocalCodingTarget.codexCli => codexCliTooOld ? '0.130.0' : '0.153.4',
        LocalCodingTarget.claudeCli => '2.1.263',
        LocalCodingTarget.codexDesktop => '26.623.141536',
        LocalCodingTarget.claudeDesktop => '1.46388.4',
      };
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: authorized,
      deviceId: deviceId,
      environment: authorized ? 'prod' : '',
      targets: authorized
          ? const {
              LocalCodingTarget.codexCli,
              LocalCodingTarget.claudeCli,
            }
          : const {},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: target.isDesktop ? desktopUiState : toolUiState,
          installedVersion: (target.isDesktop ? desktopUiState : toolUiState) ==
                  LocalCodingToolUiState.notInstalled
              ? ''
              : versionFor(target),
          installSource: codexCliTooOld && target == LocalCodingTarget.codexCli
              ? 'npm'
              : 'official',
          verificationLevel: 'l0',
          errorCode: switch (target) {
            LocalCodingTarget.codexCli => codexCliTooOld
                ? 'LCT-CODEX_CLI-DETECT-VERSION_TOO_OLD'
                : toolErrorCode,
            LocalCodingTarget.codexDesktop => desktopErrorCode,
            LocalCodingTarget.claudeDesktop => claudeDesktopErrorCode,
            _ => '',
          },
          nextActions: const ['detect'],
          supportsEnable: target.isDesktop
              ? desktopSupportsEnable &&
                  !(target == LocalCodingTarget.claudeDesktop &&
                      claudeDesktopErrorCode.isNotEmpty)
              : !(codexCliTooOld && target == LocalCodingTarget.codexCli),
          minimumVersion: codexCliTooOld && target == LocalCodingTarget.codexCli
              ? '0.137.0'
              : '',
          adoptVersion:
              target == LocalCodingTarget.codexCli ? adoptVersion : '',
          availableVersion:
              target == LocalCodingTarget.codexCli ? availableVersion : '',
          updateAvailable: target == LocalCodingTarget.codexCli &&
              availableVersion.isNotEmpty,
          rollbackVersion:
              target == LocalCodingTarget.codexCli ? rollbackVersion : '',
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['switch_global'],
          policyConflict: target == policyConflictTarget,
          errorCode: target == policyConflictTarget
              ? 'LCT-CLAUDE_CLI-CONFIG-POLICY_CONFLICT'
              : '',
          currentService: target.isDesktop
              ? (desktopCurrentService ?? currentService)
              : currentService,
          globalSwitched: globalSwitched ??
              (target.isDesktop
                      ? (desktopCurrentService ?? currentService)
                      : currentService) ==
                  LocalCodingCurrentService.zhiban,
          globalBackupAvailable: (target.isDesktop
                  ? (desktopCurrentService ?? currentService)
                  : currentService) ==
              LocalCodingCurrentService.zhiban,
          globalDrifted: globalDrifted,
          globalVerificationLevel: target.isDesktop
              ? desktopGlobalVerificationLevel
              : globalVerificationLevel,
          globalLastVerifiedAt: globalLastVerifiedAt,
        ),
    },
    expectedProfileVersions: {
      for (final target in LocalCodingTarget.values)
        target: '${target.scopeTarget.id}-v1',
    },
    registrationAvailable: registrationAvailable,
    supportedMethods: supportedMethods,
    proxyStatus: proxyStatus,
  );
}

class _FakeOperations implements LocalCodingToolsOperations {
  _FakeOperations({
    required Future<LocalCodingToolsSnapshot> Function() inspect,
    Future<LocalCodingToolsSnapshot> Function()? register,
    Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)? enable,
    Future<LocalCodingLaunchResult?> Function(LocalCodingTarget)? launch,
    Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)?
        switchToZhiban,
    Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)?
        restoreOfficial,
    Future<LocalCodingLaunchResult> Function(LocalCodingTarget)? openApp,
  })  : _inspect = inspect,
        _register = register,
        _enable = enable,
        _launch = launch,
        _switchToZhiban = switchToZhiban,
        _restoreOfficial = restoreOfficial,
        _openApp = openApp;

  final Future<LocalCodingToolsSnapshot> Function() _inspect;
  final Future<LocalCodingToolsSnapshot> Function()? _register;
  final Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)? _enable;
  final Future<LocalCodingLaunchResult?> Function(LocalCodingTarget)? _launch;
  final Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)?
      _switchToZhiban;
  final Future<LocalCodingToolsSnapshot> Function(LocalCodingTarget)?
      _restoreOfficial;
  final Future<LocalCodingLaunchResult> Function(LocalCodingTarget)? _openApp;
  int inspectCalls = 0;
  int registerCalls = 0;
  int enableCalls = 0;
  LocalCodingTarget? enabledTarget;
  int launchCalls = 0;
  LocalCodingTarget? launchedTarget;
  LocalCodingLaunchMode? launchedMode;

  @override
  Future<LocalCodingToolsSnapshot> inspect({
    void Function(LocalCodingInspectProgress progress)? onProgress,
  }) {
    inspectCalls++;
    return _inspect();
  }

  @override
  Future<LocalCodingToolsSnapshot> registerOrRotate() {
    registerCalls++;
    return (_register ?? _inspect)();
  }

  @override
  Future<LocalCodingToolsSnapshot> enable(LocalCodingTarget target) {
    enableCalls++;
    enabledTarget = target;
    return (_enable ?? (_) => _inspect())(target);
  }

  @override
  Future<LocalCodingLaunchResult?> launch(
    LocalCodingTarget target, {
    LocalCodingLaunchMode mode = LocalCodingLaunchMode.managed,
  }) {
    launchCalls++;
    launchedTarget = target;
    launchedMode = mode;
    return (_launch ?? (_) async => null)(target);
  }

  @override
  Future<void> removeAuthorization() async {}

  int reconnectCalls = 0;

  @override
  Future<bool> reconnectIfSameIdentity() async {
    reconnectCalls++;
    return false;
  }

  @override
  Future<LocalCodingRequirements> requirements(
          LocalCodingTarget target) async =>
      throw UnimplementedError();

  LocalCodingOperation? startInstallResponse;
  final List<LocalCodingTarget> installedTargets = [];

  @override
  Future<LocalCodingOperation> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    if (component != null) {
      installedComponents.add('${target.id}:$component');
      final error = componentInstallError;
      if (error != null) throw error;
      return startInstallResponse ?? (throw UnimplementedError());
    }
    installedTargets.add(target);
    installModes.add(mode);
    return startInstallResponse ?? (throw UnimplementedError());
  }

  final List<LocalCodingInstallMode> installModes = [];
  final List<String> installedComponents = [];
  Object? componentInstallError;

  @override
  Future<LocalCodingOperation> startVerify(
    LocalCodingTarget target, {
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    startVerifyCalls++;
    lastVerifyScope = scope;
    verifiedTargets.add(target);
    return startVerifyResponse ?? (throw UnimplementedError());
  }

  int startVerifyCalls = 0;
  LocalCodingVerifyScope? lastVerifyScope;
  LocalCodingOperation? startVerifyResponse;
  final List<LocalCodingTarget> verifiedTargets = [];

  @override
  Future<LocalCodingToolsSnapshot> switchToZhiban(
      LocalCodingTarget target) async {
    switchCalls++;
    switchedTargets.add(target);
    final handler = _switchToZhiban;
    if (handler == null) throw UnimplementedError();
    return handler(target);
  }

  int switchCalls = 0;
  final List<LocalCodingTarget> switchedTargets = [];

  @override
  Future<LocalCodingToolsSnapshot> restoreOfficial(
      LocalCodingTarget target) async {
    restoreCalls++;
    restoredTargets.add(target);
    final handler = _restoreOfficial;
    if (handler == null) throw UnimplementedError();
    return handler(target);
  }

  int restoreCalls = 0;
  final List<LocalCodingTarget> restoredTargets = [];

  @override
  Future<LocalCodingLaunchResult> openApp(LocalCodingTarget target) async {
    openAppCalls++;
    openedTarget = target;
    final handler = _openApp;
    if (handler == null) throw UnimplementedError();
    return handler(target);
  }

  int openAppCalls = 0;
  LocalCodingTarget? openedTarget;

  @override
  Future<LocalCodingToolsSnapshot> applyProxyFix() async {
    proxyFixCalls++;
    return await _inspect();
  }

  int proxyFixCalls = 0;

  LocalCodingOperation? pollResponse;

  /// 需要按形态给不同轮询结果时用(优先于 [pollResponse]);配合 [verifiedTargets]。
  LocalCodingOperation Function()? pollHandler;

  @override
  Future<LocalCodingOperation> pollOperation(String operationId) async =>
      pollHandler?.call() ?? pollResponse ?? (throw UnimplementedError());

  /// v3.11 · 关闭进度弹框绝不能触发取消,这里记账供断言。
  final List<String> cancelledOperations = [];

  @override
  Future<LocalCodingOperation> cancelOperation(String operationId) async {
    cancelledOperations.add(operationId);
    throw UnimplementedError();
  }

  @override
  Future<LocalCodingToolsSnapshot> removeConfiguration(
    LocalCodingTarget target,
  ) async =>
      throw UnimplementedError();

  @override
  Future<LocalCodingToolsSnapshot> repairConfiguration(
    LocalCodingTarget target,
  ) async =>
      throw UnimplementedError();


  @override
  Future<LocalCodingDiagnostics> diagnostics(LocalCodingTarget target) async =>
      diagnosticsResponse ?? (throw UnimplementedError());

  Map<String, dynamic>? reportedClientInfo;
  String? reportReference = 'feedback-uuid-0001';

  @override
  Future<String?> reportDiagnostics({
    required String title,
    required String description,
    required Map<String, dynamic> clientInfo,
  }) async {
    reportedClientInfo = clientInfo;
    return reportReference;
  }

  LocalCodingDiagnostics? diagnosticsResponse;
}

LocalCodingOperation _operation({
  required LocalCodingOperationKind kind,
  required LocalCodingOperationState state,
  required String stage,
  LocalCodingProgressKind progressKind = LocalCodingProgressKind.indeterminate,
  int? progressValue,
  bool cancellable = false,
  String errorCode = '',
  String errorDetail = '',
  Map<String, dynamic>? result,
}) {
  return LocalCodingOperation(
    operationId: 'op-1',
    target: LocalCodingTarget.codexCli,
    kind: kind,
    state: state,
    stage: stage,
    progressKind: progressKind,
    progressValue: progressValue,
    cancellable: cancellable,
    nextActions: const [],
    errorCode: errorCode,
    errorDetail: errorDetail,
    result: result,
  );
}

LocalCodingProxyStatus _uncoveredProxy() => LocalCodingProxyStatus.fromJson({
      'supported': true,
      'system_proxy': {'enabled': true, 'endpoint': '127.0.0.1:1088'},
      'covered': {'user_env': false, 'system_bypass': false},
      'direct_reachable': true,
      'needs_fix': true,
      'env_needs_fix': true,
    });
