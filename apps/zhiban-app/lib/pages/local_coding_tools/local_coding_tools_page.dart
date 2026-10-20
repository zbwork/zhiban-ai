import 'package:zhiban_client/config/app_config.dart';
import 'local_coding_api_settings_dialog.dart';
import 'package:zhiban_client/network/user_refresh.dart';

import 'package:zhiban_client/config/client_assets.dart';
import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/providers/local_coding_tools_provider.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_dropdown_menu.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

/// F31 §3.1（2026-09-09 晚简化）· 页面按厂商两张卡（Codex / Claude）。普通用户
/// 不需要知道"命令行"和"桌面端"的区别：一张卡对应该厂商的两个 target，软件状态
/// 一行汇总，"下载安装"一次装全部缺失形态，"查看系统要求"合成一个弹框，切换 /
/// 恢复 / 修复 / 重新检测都是卡级；只有"打开"是一个下拉（打开 CLI / 打开桌面端）。
///
/// 每个 target 内部仍各算一个 [_RowState]，卡片角标与按钮由这些状态汇总得出。
enum _RowState {
  notInstalled, // 未安装
  installedOfficial, // 已安装 · 官方服务
  switched, // CLI:已切换且真实请求验证通过(运行正常,L3)
  configured, // 桌面端:已切换且 L2 通过(已配置自定义模型 API;桌面端无自动 L3)
  switchedUnverified, // 已切换但尚未检测
  needsAttention, // 需要处理(切换后无法连接 / 安装损坏 / 切换未完成 / 配置被改动)
  componentMissing, // 需要处理 · 缺少运行组件(M3 Task 8:Claude 桌面端的 Claude Code 宿主包)
  unsupported, // 暂不支持(§7.3 policy_conflict / §2.2 untrusted / version unknown)
  enableUnsupported, // 桌面端暂不支持自定义模型 API(supports_enable=false)
  processing, // 处理中(有 running 操作 / compound 未结束 / 批处理项进行中)
}

// 卡片视觉(浅色):悬浮阴影与冷灰分隔线,取自浏览器样机「本地开发工具卡片排版」。
const List<BoxShadow> _floatingCardShadow = [
  BoxShadow(color: Color(0x0A0F172A), offset: Offset(0, 1), blurRadius: 2),
  BoxShadow(color: Color(0x0F0F172A), offset: Offset(0, 6), blurRadius: 20),
];
const Color _cardHeadDividerColor = Color(0xFFE3E8F1);
const Color _cardRowDividerColor = Color(0xFFEEF2F7);

class LocalCodingToolsPage extends ConsumerStatefulWidget {
  const LocalCodingToolsPage({super.key});

  @override
  ConsumerState<LocalCodingToolsPage> createState() =>
      _LocalCodingToolsPageState();
}

class _LocalCodingToolsPageState extends ConsumerState<LocalCodingToolsPage> {
  @override
  void initState() {
    super.initState();
    // v1.7 §12 · 页面挂载后触发一次静默刷新;keepAlive 已在,provider 里保留
    // 的上一份快照会先显示,后台 inspect 完成后无缝切到最新数据。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(localCodingToolsProvider.notifier).refreshQuiet();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localCodingToolsProvider);
    final progress = ref.watch(localCodingInspectProgressProvider);
    final Widget body;
    if (state.hasError && !state.isLoading) {
      body = _ErrorState(
        message: _userMessage(state.error!),
        onRetry: () => UserRefresh.run(() => ref.read(localCodingToolsProvider.notifier).reload()),
      );
    } else if (!state.hasValue) {
      // 首次进入还没有数据:卡片骨架 + 检测进度,不再整页转圈(2026-09-15)。
      body = _ToolsContent(
        data: null,
        progress: progress ?? LocalCodingInspectProgress.starting(),
      );
    } else if (state.isLoading && progress == null) {
      // 授权等其它整页操作仍用整页转圈。
      body = const Center(child: CupertinoActivityIndicator());
    } else {
      body = _ToolsContent(data: state.value!, progress: progress);
    }
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '本地开发工具',
        backgroundColor: ColorConfig.pageBackground,
        // 一级页面(左侧导航直达),没有可返回的上一页,返回箭头点了没反应。
        showBackButton: false,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: body),
            // 操作完成提示浮在内容上方,不推动卡片(2026-09-15)。
            const Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _ResultToast(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolsContent extends ConsumerWidget {
  const _ToolsContent({required this.data, this.progress});

  /// 首次进入、检测还没结束时为 null(卡片显示骨架)。
  final LocalCodingToolsPageData? data;
  final LocalCodingInspectProgress? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = this.data;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 20, top: 4),
                child: const _PageSubtitle(),
              ),
              // 2026-09-15 · 不再有页面顶部的持续横幅:「环境未开放」写在卡片上灰掉的
              // 切换按钮旁;「服务端撤销待重试」是自动完成的后台事,不打扰用户。
              for (final vendor in LocalCodingVendor.values) ...[
                _VendorCard(vendor: vendor, data: data, progress: progress),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// 配置线索不能代替失败证据;新成功 operation 优先于之前批次的失败。
({String code, String detail})? _verificationFailure(
    LocalCodingOperation? op, LocalCodingBatchItem? batchItem) {
  if (op != null && op.kind == LocalCodingOperationKind.verify) {
    if (op.isSucceeded) return null;
    if (op.isFailed) return (code: op.errorCode, detail: op.errorDetail);
  }
  if (batchItem != null &&
      batchItem.status == LocalCodingBatchItemStatus.failed) {
    return (code: batchItem.errorCode, detail: batchItem.errorDetail);
  }
  return null;
}

/// 一个 target 的全部输入与推导结果(卡内部使用,不再单独成行展示)。
class _RowView {
  const _RowView({
    required this.target,
    required this.tool,
    required this.config,
    required this.op,
    required this.compound,
    required this.batchItem,
    required this.state,
    this.authorizationLost = false,
    this.proxyRepairSuggested = false,
    this.proxyEndpoint = '',
    this.sharedConfigTooOld = false,
  });

  final LocalCodingTarget target;
  final LocalCodingToolState tool;
  final LocalCodingConfigurationStatus config;
  final LocalCodingOperation? op;
  final LocalCodingCompound? compound;
  final LocalCodingBatchItem? batchItem;
  final _RowState state;

  /// 配置仍指向知办,但本环境的设备授权没了(退出过知办 / 切过环境 / 重装):
  /// 换票必然失败,修复并重试会先重新接入。
  final bool authorizationLost;

  /// 真实验证失败且诊断提示代理可能有影响,才提供用户主动设置例外的入口。
  final bool proxyRepairSuggested;
  final String proxyEndpoint;

  /// Codex 桌面端与命令行共用 ~/.codex/config.toml:命令行版本过旧读不懂知办写的
  /// 配置,桌面端也不能切换(2026-09-15 最低版本门槛)。
  final bool sharedConfigTooOld;

  bool get installed => state != _RowState.notInstalled;

  /// 能被「打开」的形态:装了且 Bridge 认得出来源。来源不明 / 版本不明的安装
  /// Bridge 按契约不执行(fail closed),不给一个点了必失败的按钮;企业策略冲突
  /// 的安装本身可信,仍可按官方设置打开。
  bool get openable =>
      installed && tool.uiState != LocalCodingToolUiState.unsupported;

  /// 已切换且状态正常的形态。
  bool get switchedToZhiban =>
      config.switchedToZhiban &&
      (state == _RowState.switched ||
          state == _RowState.configured ||
          state == _RowState.switchedUnverified);

  bool get needsRepair =>
      state == _RowState.needsAttention || state == _RowState.componentMissing;

  /// 卡级「恢复官方配置」可作用的形态:配置仍指向知办的,需要处理的也算
  /// (2026-09-18)。知办线路出问题时用户最想退回官方;只恢复状态正常的形态,
  /// Claude 命令行(配置与桌面端分开)会一直指向知办,只装了一个形态时连入口都没有。
  bool get restorable =>
      config.switchedToZhiban && (switchedToZhiban || needsRepair);

  /// 最近一次失败的检测(单项 operation 或批处理项)的错误码与中转站原话。
  ({String code, String detail})? get _verifyFailure {
    return _verificationFailure(op, batchItem);
  }

  /// 需要处理的原因是你配置的模型服务自己拒绝了检测请求(503 过载、429 等,
  /// 2026-09-15):修复并重试修不好,卡片说清原因、主按钮给「重新检测」。
  /// 本机问题(安装损坏、授权失效、代理拦截、配置被改、切换没写完)优先。
  LocalCodingRelayFailure? get relayFailure {
    if (state != _RowState.needsAttention ||
        tool.uiState == LocalCodingToolUiState.repairable ||
        authorizationLost ||
        proxyRepairSuggested ||
        (config.switchedToZhiban && config.globalDrifted) ||
        (compound?.failed == true &&
            compound?.phase == LocalCodingCompoundPhase.switchWrite)) {
      return null;
    }
    final failure = _verifyFailure;
    return failure == null
        ? null
        : localCodingRelayFailure(failure.code, failure.detail);
  }

  String get relayDetail => _verifyFailure?.detail ?? '';

  /// 契约 §2.7.4 · 版本目录给出了更高版本,且当前安装处在可以换版本的状态
  /// (已装官方来源,不在处理中 / 损坏)。只做升级,不给回退(2026-09-15 拍板)。
  bool get upgradable => tool.canUpgrade && _versionChangeable;

  bool get _versionChangeable => switch (state) {
        _RowState.installedOfficial ||
        _RowState.switched ||
        _RowState.configured ||
        _RowState.switchedUnverified ||
        _RowState.enableUnsupported =>
          true,
        _ => false,
      };

  String get formLabel => target.isDesktop ? '桌面端' : '命令行';
}

class _VendorCard extends ConsumerWidget {
  const _VendorCard({required this.vendor, required this.data, this.progress});

  final LocalCodingVendor vendor;
  final LocalCodingToolsPageData? data;
  final LocalCodingInspectProgress? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final progress = this.progress;
    final inspecting = progress != null && !progress.vendorDone(vendor);
    // 这张卡的安装与配置已在本次检测里读到:用新结果;否则沿用上次的数据(检测中
    // 变淡),首次进入还没有数据时显示骨架(2026-09-15 检测过程可视化)。
    final fresh = progress != null && progress.configRead(vendor)
        ? progress.snapshot
        : null;
    final source = fresh == null
        ? data
        : (data?.copyWith(snapshot: fresh, lastDetectedAt: DateTime.now()) ??
            LocalCodingToolsPageData(
                snapshot: fresh, lastDetectedAt: DateTime.now()));
    final batch = source?.batchFor(vendor);
    final rows = <_RowView>[
      if (source != null)
        for (final target in vendor.targets)
          if (source.snapshot.hasTarget(target))
            _rowView(source, target, batch),
    ];
    final cardState = _resolveCardState(rows);
    final meta = _brand(vendor);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      // 悬浮卡片(2026-09-15 用户在浏览器对比四种样式后选定):白底页面上去掉
      // 描边、只留两层很淡的阴影;深色下阴影看不出,保留原描边。
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: dark
            ? Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6))
            : null,
        boxShadow: dark ? null : _floatingCardShadow,
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _BrandTile(brand: meta, size: 60, markSize: 34),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          meta.name,
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        const _FormFactorHint(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta.subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (AppConfig.communityEdition)
                TextButton.icon(
                  onPressed: batch != null && !batch.done
                      ? null
                      : () async {
                          final saved = await showLocalCodingApiSettings(
                            context,
                            vendor,
                          );
                          if (saved == true && context.mounted) {
                            ref
                                .read(localCodingToolsProvider.notifier)
                                .refreshQuiet();
                          }
                        },
                  icon: const Icon(CupertinoIcons.settings, size: 16),
                  label: const Text('API 设置'),
                ),
              _StatusBadge(
                state: cardState,
                detecting: inspecting,
                unreadable: rows
                    .where((r) => r.installed)
                    .every((r) => r.tool.resultUnreadable),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(
              color: dark
                  ? scheme.outlineVariant.withValues(alpha: 0.4)
                  : _cardHeadDividerColor,
              height: 1),
          const SizedBox(height: 6),
          if (source == null)
            _SkeletonCardBody(vendor: vendor, progress: progress!)
          else
            _CardBody(
              vendor: vendor,
              rows: rows,
              cardState: cardState,
              snapshot: source.snapshot,
              data: source,
              progress: inspecting ? progress : null,
            ),
        ],
      ),
    );
  }

  _RowView _rowView(
    LocalCodingToolsPageData source,
    LocalCodingTarget target,
    LocalCodingBatch? batch,
  ) {
    final snapshot = source.snapshot;
    final tool = snapshot.stateFor(target);
    final config = snapshot.configurationFor(target);
    final op = source.operationFor(target);
    final compound = source.compoundFor(target);
    final batchItem = batch != null && batch.targets.contains(target)
        ? batch.itemFor(target)
        : null;
    final authorizationLost = config.switchedToZhiban &&
        (AppConfig.communityEdition
            ? (snapshot.expectedProfileVersions[target] ?? '').isEmpty
            : snapshot.registrationAvailable && !snapshot.authorizationConnected);
    // Codex(reqwest)读 NO_PROXY;Claude 桌面端取模型列表走系统网络栈,只认系统
    // 代理的绕过名单(契约 §2.7,2026-09-18)。Claude 命令行不读系统代理,不受影响。
    final verificationFailure = _verificationFailure(op, batchItem);
    final proxyRepairSuggested = config.switchedToZhiban &&
        verificationFailure?.code.endsWith('-GATEWAY-PROXY_INTERFERENCE') ==
            true &&
        (target.vendor == LocalCodingVendor.codex
            ? snapshot.proxyEnvNeedsFix
            : target == LocalCodingTarget.claudeDesktop &&
                snapshot.proxyBypassNeedsFix);
    final cli = snapshot.tools[LocalCodingTarget.codexCli];
    final sharedConfigTooOld = target == LocalCodingTarget.codexDesktop &&
        cli != null &&
        cli.versionTooOld;
    return _RowView(
      target: target,
      tool: tool,
      config: config,
      op: op,
      compound: compound,
      batchItem: batchItem,
      authorizationLost: authorizationLost,
      proxyRepairSuggested: proxyRepairSuggested,
      proxyEndpoint: snapshot.proxyStatus?.endpoint ?? '',
      sharedConfigTooOld: sharedConfigTooOld,
      state: _resolveRowState(
        tool: tool,
        config: config,
        op: op,
        compound: compound,
        batchItem: batchItem,
        batchRunning: batch != null && !batch.done,
        authorizationLost: authorizationLost,
        proxyRepairSuggested: proxyRepairSuggested,
        sharedConfigTooOld: sharedConfigTooOld,
      ),
    );
  }
}

/// 卡头 ⓘ:解释一张卡里装了什么。
class _FormFactorHint extends StatelessWidget {
  const _FormFactorHint();

  static const String message =
      '知办会一起安装命令行版和桌面版：命令行版在终端里输入指令使用，桌面版是图形界面应用。打开时任选其一即可。';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 300),
      child: Icon(CupertinoIcons.info_circle,
          size: 16, color: scheme.onSurfaceVariant),
    );
  }
}

/// 品牌色块 + 白色标识:OpenAI 花瓣(绿)/ Claude 星芒(橙),与 v1.6 原型一致。
class _BrandTile extends StatelessWidget {
  const _BrandTile({
    required this.brand,
    required this.size,
    required this.markSize,
  });

  final _ToolBrand brand;
  final double size;
  final double markSize;

  @override
  Widget build(BuildContext context) {
    if (brand.appIcon.isNotEmpty) {
      // 真实应用图标自带形状(Claude 是方圆角色块,Codex 是蓝色云朵),
      // 直接按尺寸绘制,不再套色块。
      return SizedBox(
        width: size,
        height: size,
        child: Image.asset(package: ClientAssets.packageName,
            brand.appIcon, fit: BoxFit.contain),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [brand.tileStart, brand.tileEnd],
        ),
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      child: SvgPicture.asset(
        package: ClientAssets.packageName,
        brand.markAsset,
        width: markSize,
        height: markSize,
      ),
    );
  }
}

/// 卡片信息行的取值:软件状态 / 版本 / 当前服务 / 服务连接。「最近检测」并入
/// 服务连接一行(2026-09-14 卡片改版)。
class _Fact {
  const _Fact(this.value, this.tone);

  final String value;
  final _DotColor tone;
}

class _CardFacts {
  const _CardFacts({
    required this.rows,
    required this.cardState,
    this.inspecting = false,
  });

  final List<_RowView> rows;
  final _RowState cardState;

  /// 卡片正在检测(含重新检测里的验证步骤)。
  final bool inspecting;

  List<_RowView> get _installedRows => rows.where((r) => r.installed).toList();

  String _formsLabel(Iterable<_RowView> subset) =>
      subset.map((r) => r.formLabel).join(' + ');

  /// 「版本」行:每个形态一段版本号,可升级的形态带「新版本 x」标签
  /// (2026-09-11 用户反馈:版本挤在软件状态里又长又乱)。没有任何已知版本时
  /// 返回空,不显示这一行。
  List<({String text, String upgradeTo})> versions() => [
        for (final r in _installedRows)
          if (r.state != _RowState.unsupported &&
              r.tool.installedVersion.trim().isNotEmpty)
            (
              text: '${r.formLabel} ${r.tool.installedVersion.trim()}',
              upgradeTo: r.upgradable ? r.tool.availableVersion : '',
            ),
      ];

  _Fact software() {
    final installedRows = _installedRows;
    if (installedRows.isEmpty) {
      return const _Fact('未安装', _DotColor.warning);
    }
    final damaged =
        rows.where((r) => r.tool.uiState == LocalCodingToolUiState.repairable);
    if (damaged.isNotEmpty) {
      return _Fact('安装已损坏（${_formsLabel(damaged)}）', _DotColor.error);
    }
    final unsupported =
        installedRows.where((r) => r.state == _RowState.unsupported).toList();
    // 检测结果读不懂的形态显示"检测异常",与真正的"暂不支持"分开(2026-09-15)。
    final unreadable = unsupported.where((r) => r.tool.resultUnreadable);
    final notSupported = unsupported.where((r) => !r.tool.resultUnreadable);
    if (unsupported.length == installedRows.length) {
      return notSupported.isEmpty
          ? const _Fact('检测异常', _DotColor.error)
          : const _Fact('暂不支持', _DotColor.error);
    }
    final usable =
        installedRows.where((r) => r.state != _RowState.unsupported).toList();
    final missing = rows.where((r) => !r.installed).toList();
    // 有新版本由「版本」行的标签提示,这里不再重复。
    final suffix = <String>[
      if (unreadable.isNotEmpty) '${_formsLabel(unreadable)}检测异常',
      if (notSupported.isNotEmpty) '${_formsLabel(notSupported)}暂不支持',
      if (missing.isNotEmpty) '${_formsLabel(missing)}未安装',
    ];
    final installedLabel = '已安装（${_formsLabel(usable)}）';
    if (suffix.isEmpty) return _Fact(installedLabel, _DotColor.success);
    return _Fact('$installedLabel· ${suffix.join('，')}',
        unsupported.isNotEmpty ? _DotColor.warning : _DotColor.success);
  }

  _Fact service() {
    final installedRows = _installedRows;
    if (installedRows.isEmpty) {
      return const _Fact('—', _DotColor.muted);
    }
    final switchedCount =
        installedRows.where((r) => r.config.switchedToZhiban).length;
    if (switchedCount > 0) {
      return _Fact(
        switchedCount == installedRows.length ? '自定义模型 API' : '自定义模型 API（部分）',
        rows.any((r) => r.needsRepair) ? _DotColor.warning : _DotColor.success,
      );
    }
    if (installedRows.any((r) => r.config.pathUnsafe)) {
      return const _Fact('无法判断', _DotColor.muted);
    }
    if (installedRows.any(
        (r) => r.config.currentService == LocalCodingCurrentService.unknown)) {
      return const _Fact('自定义配置', _DotColor.muted);
    }
    return const _Fact('官方服务', _DotColor.success);
  }

  _Fact connection() {
    switch (cardState) {
      case _RowState.notInstalled:
        return const _Fact('未检测', _DotColor.muted);
      case _RowState.processing:
        return _Fact(inspecting ? '正在验证' : '处理中', _DotColor.info);
      case _RowState.needsAttention:
        final attention = rows.firstWhere((r) => r.needsRepair);
        if (attention.config.pathUnsafe) {
          return const _Fact('配置不可访问', _DotColor.error);
        }
        if (attention.state == _RowState.componentMissing) {
          return const _Fact('缺少运行组件', _DotColor.error);
        }
        if (attention.authorizationLost) {
          return const _Fact('授权已失效', _DotColor.error);
        }
        if (attention.proxyRepairSuggested) {
          return const _Fact('连接失败，可能受代理影响', _DotColor.error);
        }
        if (attention.config.switchedToZhiban &&
            attention.config.globalDrifted) {
          // 契约 §2.7(B3):没有切换记录的知办配置同样报 drifted,但文案不同。
          return attention.config.globalSwitched
              ? const _Fact('配置已改动', _DotColor.error)
              : const _Fact('缺少切换记录', _DotColor.error);
        }
        switch (attention.relayFailure) {
          case LocalCodingRelayFailure.upstreamUnavailable:
            return const _Fact('中转站暂时不可用', _DotColor.error);
          case LocalCodingRelayFailure.quotaExhausted:
            return const _Fact('中转站拒绝请求', _DotColor.error);
          case LocalCodingRelayFailure.modelDenied:
            return const _Fact('模型未开放', _DotColor.error);
          case LocalCodingRelayFailure.rejected:
            return const _Fact('中转站返回错误', _DotColor.error);
          case LocalCodingRelayFailure.proxyDiverted:
            return const _Fact('连接失败，可能受代理影响', _DotColor.error);
          case LocalCodingRelayFailure.insufficientCredit:
            return const _Fact('积分已用完', _DotColor.error);
          case LocalCodingRelayFailure.memberKeyDisabled:
            return const _Fact('模型服务已停用', _DotColor.error);
          case null:
            break;
        }
        return const _Fact('无法连接', _DotColor.error);
      case _RowState.unsupported:
        return _installedRows.every((r) => r.tool.resultUnreadable)
            ? const _Fact('未检测', _DotColor.muted)
            : const _Fact('不适用', _DotColor.muted);
      case _RowState.switchedUnverified:
        return const _Fact('待检测', _DotColor.muted);
      case _RowState.configured:
        return const _Fact('已配置自定义模型 API', _DotColor.success);
      case _RowState.switched:
      case _RowState.installedOfficial:
      case _RowState.enableUnsupported:
      case _RowState.componentMissing:
        return const _Fact('正常', _DotColor.success);
    }
  }
}

enum _DotColor { success, warning, error, info, muted }

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.state,
    this.detecting = false,
    this.unreadable = false,
  });

  final _RowState state;

  /// 这张卡正在检测(2026-09-15):压过其它状态显示「检测中」。
  final bool detecting;

  /// 暂不支持的形态全是"检测结果读不懂"(2026-09-15):角标显示「检测异常」。
  final bool unreadable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late Color background;
    late Color foreground;
    late String label;
    late IconData? icon;
    switch (detecting ? _RowState.processing : state) {
      case _RowState.switched:
        background = const Color(0xFFDCFCE7);
        foreground = const Color(0xFF15803D);
        icon = CupertinoIcons.checkmark_alt_circle_fill;
        label = '运行正常';
        break;
      case _RowState.configured:
        background = const Color(0xFFDCFCE7);
        foreground = const Color(0xFF15803D);
        icon = CupertinoIcons.checkmark_alt_circle_fill;
        label = '已配置';
        break;
      case _RowState.installedOfficial:
      case _RowState.enableUnsupported:
        background = const Color(0xFFDCFCE7);
        foreground = const Color(0xFF15803D);
        icon = CupertinoIcons.checkmark_alt_circle_fill;
        label = '已安装';
        break;
      case _RowState.notInstalled:
        background = const Color(0xFFF3F4F6);
        foreground = const Color(0xFF92400E);
        icon = CupertinoIcons.circle_fill;
        label = '未安装';
        break;
      case _RowState.needsAttention:
      case _RowState.componentMissing:
        background = const Color(0xFFFEF3C7);
        foreground = const Color(0xFFB45309);
        icon = CupertinoIcons.exclamationmark_circle_fill;
        label = '需要处理';
        break;
      case _RowState.switchedUnverified:
        background = scheme.primary.withValues(alpha: 0.12);
        foreground = scheme.primary;
        icon = CupertinoIcons.time;
        label = '待检测';
        break;
      case _RowState.processing:
        background = scheme.primary.withValues(alpha: 0.12);
        foreground = scheme.primary;
        icon = null;
        label = detecting ? '检测中' : '处理中';
        break;
      case _RowState.unsupported:
        background = scheme.surfaceContainerHighest;
        foreground = scheme.onSurfaceVariant;
        icon = unreadable
            ? CupertinoIcons.exclamationmark_circle_fill
            : CupertinoIcons.minus_circle_fill;
        label = unreadable ? '检测异常' : '暂不支持';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 6),
          ] else ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CupertinoActivityIndicator(radius: 6),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片正文(2026-09-14 卡片改版,用户选定"操作跟着信息走"):四行信息,每行最
/// 右边放改这一行的操作——软件状态 → 补装 / 系统要求 / 查看原因,版本 → 升级 /
/// 版本行只有升级,当前服务 → 恢复官方配置,服务连接 → 诊断详情 / 重新检测;底部只留主按钮 +
/// 「打开」和一句说明,需要处理时上方出橙色提示。所有动作都作用于该厂商的两个
/// target;只有「打开」让用户选命令行还是桌面端。
class _CardBody extends ConsumerStatefulWidget {
  const _CardBody({
    required this.vendor,
    required this.rows,
    required this.cardState,
    required this.snapshot,
    required this.data,
    this.progress,
  });

  final LocalCodingVendor vendor;
  final List<_RowView> rows;
  final _RowState cardState;
  final LocalCodingToolsSnapshot snapshot;
  final LocalCodingToolsPageData data;

  /// 这张卡正在检测时的进度;检测完为 null。
  final LocalCodingInspectProgress? progress;

  @override
  ConsumerState<_CardBody> createState() => _CardBodyState();
}

class _CardBodyState extends ConsumerState<_CardBody> {
  final GlobalKey _openAnchor = GlobalKey();

  LocalCodingVendor get vendor => widget.vendor;
  List<_RowView> get rows => widget.rows;
  LocalCodingToolsSnapshot get snapshot => widget.snapshot;

  List<_RowView> get _installedRows => rows.where((r) => r.installed).toList();
  List<_RowView> get _missingRows => rows.where((r) => !r.installed).toList();
  List<_RowView> get _openableRows => rows.where((r) => r.openable).toList();

  /// F31 §3.2.1 · 「一键配置工具 / 修复并重试」作用的形态:未安装、走官方服务、
  /// 需要处理(中转站拒绝的除外)、版本或能力不够但有升级 / 接管路径的。已接入且
  /// 正常的不在内;来源不可信的不在内。
  List<_RowView> get _connectableRows => rows.where(_connectable).toList();

  bool _connectable(_RowView r) {
    if (r.config.pathUnsafe) return false;
    switch (r.state) {
      case _RowState.notInstalled:
      case _RowState.installedOfficial:
      case _RowState.componentMissing:
        return true;
      case _RowState.needsAttention:
        return r.relayFailure == null;
      case _RowState.enableUnsupported:
        // 版本过旧 / 桌面端不支持第三方推理:有升级或接管路径才接得上;Codex
        // 桌面端因命令行过旧被连累的,命令行有路径它就跟着走(链先升命令行)。
        if (r.tool.canUpgrade || r.tool.canAdopt) return true;
        if (r.sharedConfigTooOld) {
          final cli =
              rows.where((x) => x.target == LocalCodingTarget.codexCli);
          return cli.isNotEmpty &&
              (cli.first.tool.canUpgrade || cli.first.tool.canAdopt);
        }
        return false;
      default:
        return false;
    }
  }

  /// 接入按钮可点:要装 / 换程序时 Bridge 得支持安装;本环境没开放自定义模型 API
  /// 时只能装不能切(开发 / 测试包常见),没得装就灰掉。
  bool get _connectEnabled {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    final changesProgram = _connectableRows
        .any((r) => notifier.connectPlanFor(r.target).changesProgram);
    if (changesProgram && !snapshot.canInstall) return false;
    if (!snapshot.registrationAvailable) return changesProgram;
    return true;
  }
  List<_RowView> get _switchedRows =>
      rows.where((r) => r.switchedToZhiban).toList();
  List<_RowView> get _restorableRows =>
      rows.where((r) => r.restorable).toList();
  List<_RowView> get _attentionRows =>
      rows.where((r) => r.needsRepair).toList();
  List<_RowView> get _unsupportedRows =>
      rows.where((r) => r.state == _RowState.unsupported).toList();
  List<_RowView> get _upgradableRows =>
      rows.where((r) => r.upgradable).toList();

  bool get _processing => widget.cardState == _RowState.processing;

  bool get _inspecting => widget.progress != null;

  /// 检测中且安装与配置还没按本次检测填上:软件状态 / 版本 / 当前服务行变淡。
  bool get _configStale =>
      _inspecting && !widget.progress!.configRead(vendor);

  /// 当前这一步是不是在查这张卡(是则变淡的行尾显示「检测中」)。
  bool get _checkingThisCard =>
      _inspecting && widget.progress!.current?.vendor == vendor;

  /// 服务连接行的时间:上次真正验证连通的时间(Bridge 记录的 L3 / 桌面端 L2),
  /// 取该卡已切换形态里最近的一次。只在连接正常时显示;读本机状态(进页面静默
  /// 刷新、操作结束)不算检测,不会把它刷成"刚刚"(2026-09-15 用户反馈)。
  DateTime? get _lastVerifiedAt {
    if (widget.cardState != _RowState.switched &&
        widget.cardState != _RowState.configured) {
      return null;
    }
    DateTime? latest;
    for (final row in rows) {
      if (!row.installed) continue;
      final raw = row.config.switchedToZhiban
          ? row.config.globalLastVerifiedAt
          : row.config.configured
              ? row.config.lastVerifiedAt
              : '';
      final at = DateTime.tryParse(raw)?.toLocal();
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  /// 这些问题需要用户处理后重新检测,自动接入或修复不能解决。
  bool get _recheckOnly =>
      _attentionRows.isNotEmpty &&
      _attentionRows.every((r) => r.relayFailure != null || r.config.pathUnsafe);

  /// 需要处理的是安装损坏:诊断详情挂在软件状态行,否则挂在服务连接行。
  bool get _attentionIsDamage =>
      _attentionRows.isNotEmpty &&
      _attentionRows.first.tool.uiState == LocalCodingToolUiState.repairable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final facts = _CardFacts(
        rows: rows, cardState: widget.cardState, inspecting: _inspecting);
    final versions = facts.versions();
    final versionActions = _versionActions(context);
    final notice = _notice();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 560;
        final lines = <Widget>[
          _InfoRow(
            label: '软件状态',
            wide: wide,
            stale: _configStale,
            checking: _configStale && _checkingThisCard,
            value: _FactText(facts.software()),
            actions: [
              ..._softwareActions(context),
              // 没有已知版本号时不显示「版本」行,版本操作挂到软件状态行。
              if (versions.isEmpty) ...versionActions,
            ],
          ),
          if (versions.isNotEmpty)
            _InfoRow(
              label: '版本',
              wide: wide,
              stale: _configStale,
              checking: _configStale && _checkingThisCard,
              value: _VersionValue(versions),
              actions: versionActions,
            ),
          _InfoRow(
            label: '当前服务',
            wide: wide,
            stale: _configStale,
            checking: _configStale && _checkingThisCard,
            value: _FactText(facts.service()),
            actions: _serviceActions(context),
          ),
          _InfoRow(
            label: '服务连接',
            wide: wide,
            // 服务连接是这张卡的最后一步(Codex 还要查网络与代理)。
            stale: _inspecting,
            checking: _checkingThisCard,
            value: _ConnectionValue(
              fact: facts.connection(),
              verifiedAt: _lastVerifiedAt,
            ),
            actions: _connectionActions(context),
          ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              lines[i],
              if (i != lines.length - 1)
                Divider(
                  height: 1,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? scheme.outlineVariant.withValues(alpha: 0.25)
                      : _cardRowDividerColor,
                ),
            ],
            const SizedBox(height: 16),
            if (notice != null) ...[
              _NoticeStrip(text: notice),
              const SizedBox(height: 14),
            ],
            if (_inspecting)
              _CardInspectPanel(vendor: vendor, progress: widget.progress!)
            else
              _footer(context,
                  wide: wide, note: notice == null ? _note() : null),
          ],
        );
      },
    );
  }

  /// 需要处理时底部上方的橙色提示:点名哪个形态、为什么、修复并重试会做什么。
  String? _notice() {
    switch (widget.cardState) {
      case _RowState.needsAttention:
      case _RowState.componentMissing:
        return _rowHint(_attentionRows.first) ?? '有形态需要处理，可点「修复并重试」。';
      default:
        return null;
    }
  }

  /// 底部按钮旁的一句说明;不重复信息行里已经写明的内容。
  String _note() {
    final name = localCodingVendorName(vendor);
    // 这个包没带知办接入参数(多见于开发 / 测试包):切换按钮灰掉,说明为什么。
    if (!snapshot.registrationAvailable &&
        _connectableRows.isNotEmpty &&
        widget.cardState != _RowState.processing) {
      return '当前环境暂未开放自定义模型 API，可先安装并使用官方服务';
    }
    switch (widget.cardState) {
      case _RowState.processing:
        return '正在处理，可点击「查看进度」查看当前阶段。';
      case _RowState.needsAttention:
      case _RowState.componentMissing:
        return _rowHint(_attentionRows.first) ?? '有形态需要处理，可点「修复并重试」。';
      case _RowState.unsupported:
        return _rowHint(_unsupportedRows.first) ?? '当前安装暂不支持知办接入。';
      case _RowState.notInstalled:
        return '安装后自动接入自定义模型 API，使用你填写的模型服务 $name；命令行版与桌面版会一起安装。';
      case _RowState.switched:
      case _RowState.configured:
        // 检测是靠备用模型通过的(契约 §2.7 L3 备用模型):服务可用,但用户配置的
        // 那个模型现在用不了,不说的话他打开工具第一句就会撞上 502。
        for (final row in rows) {
          // 成功的 operation 会被清掉,整卡重新检测的结果留在批处理项里。
          final warning = row.batchItem?.modelWarning ?? row.op?.modelWarning;
          if (warning != null) {
            return '${localCodingTargetName(row.target)}：${localCodingModelWarningText(warning)}';
          }
        }
        return '原配置已安全备份，随时可以恢复官方配置';
      case _RowState.switchedUnverified:
        return '已切换为自定义模型 API，尚未检测服务连接';
      case _RowState.enableUnsupported:
        return _rowHint(rows
                .firstWhere((r) => r.state == _RowState.enableUnsupported)) ??
            '桌面端暂不支持自定义模型 API。';
      case _RowState.installedOfficial:
        if (_unsupportedRows.isNotEmpty) {
          return _rowHint(_unsupportedRows.first) ?? '当前安装暂不支持知办接入。';
        }
        // 版本 / 能力不够又没有升级或接管路径的形态:说明怎么办;有路径的由接入链
        // 顺手升,写在 _connectNote 里。
        final stuck = rows.where(
            (r) => r.state == _RowState.enableUnsupported && !_connectable(r));
        if (stuck.isNotEmpty && _switchedRows.isEmpty) {
          return _rowHint(stuck.first) ?? '桌面端暂不支持自定义模型 API。';
        }
        if (_switchedRows.isNotEmpty && _connectableRows.isEmpty) {
          return '部分形态已接入自定义模型 API；其余形态暂不支持，可随时恢复官方配置';
        }
        return _connectNote();
    }
  }

  /// 「一键配置工具」旁的说明:接入时会先做什么(升级 / 接管到哪个版本)。
  String _connectNote() {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    final changes = <String>[];
    for (final r in _connectableRows) {
      final plan = notifier.connectPlanFor(r.target);
      if (plan.action == LocalCodingProgramAction.upgrade ||
          plan.action == LocalCodingProgramAction.adopt) {
        changes.add('${r.formLabel}升级到 ${plan.toVersion}');
      }
    }
    if (changes.isNotEmpty) {
      return '接入时会先把${changes.join('、')}，之后使用你填写的模型服务自定义模型 API';
    }
    return '接入自定义模型 API 后使用你填写的模型服务';
  }

  Widget _footer(BuildContext context,
      {required bool wide, required String? note}) {
    final scheme = Theme.of(context).colorScheme;
    final buttons = _footerButtons(context);
    final noteText = note == null
        ? null
        : Text(
            note,
            style: TextStyle(
                color: scheme.onSurfaceVariant, fontSize: 13, height: 1.5),
          );
    if (!wide || buttons.length > 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (buttons.isNotEmpty)
            Wrap(spacing: 12, runSpacing: 10, children: buttons),
          if (buttons.isNotEmpty && noteText != null)
            const SizedBox(height: 10),
          if (noteText != null) noteText,
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          buttons[i],
        ],
        if (noteText != null) ...[
          if (buttons.isNotEmpty) const SizedBox(width: 16),
          Expanded(child: noteText),
        ],
      ],
    );
  }

  /// 底部按钮(F31 §3.2.1,2026-09-17):主按钮按卡状态取值,不再按功能开关堆 if。
  /// 「一键配置工具」和「修复并重试」跑的是同一条链;中转站拒绝、已切换待检测只给
  /// 「重新检测」;运行正常没有主操作,「打开」实心。
  List<Widget> _footerButtons(BuildContext context) {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    if (_processing) {
      final cancellable = rows.any((r) => r.op?.cancellable == true);
      return [
        _actionButton(context,
            label: '查看进度',
            icon: CupertinoIcons.chart_bar_alt_fill,
            onPressed: () => _openProgress(context),
            variant: _ButtonVariant.filled),
        if (cancellable)
          _actionButton(context, label: '取消', onPressed: () async {
            for (final row in rows) {
              if (row.op?.cancellable == true) {
                await notifier.cancelRunning(row.target);
              }
            }
          }, variant: _ButtonVariant.text),
      ];
    }

    final specs =
        <({String label, IconData? icon, VoidCallback? onPressed, Key? key})>[];
    final primary = _primaryAction(context);
    if (primary != null) specs.add(primary);
    if (_openableRows.isNotEmpty) {
      final single = _openableRows.length == 1 ? _openableRows.first : null;
      specs.add((
        label: single == null
            ? '打开'
            : (single.target.isDesktop ? '打开桌面端' : '打开 CLI'),
        icon: single == null
            ? CupertinoIcons.chevron_down
            : CupertinoIcons.arrow_up_right_square,
        onPressed: single == null
            ? () => _openMenu(context)
            : () => _openApp(context, single.target),
        key: _openAnchor,
      ));
    }
    return [
      for (var i = 0; i < specs.length; i++)
        _actionButton(
          context,
          key: specs[i].key,
          label: specs[i].label,
          icon: specs[i].icon,
          onPressed: specs[i].onPressed,
          variant: i == 0 ? _ButtonVariant.filled : _ButtonVariant.outlined,
        ),
    ];
  }

  /// 主按钮按卡状态取值(F31 §3.2.1 的表)。
  ({String label, IconData? icon, VoidCallback? onPressed, Key? key})?
      _primaryAction(BuildContext context) {
    final recheck = (
      label: '重新检测',
      icon: CupertinoIcons.refresh,
      onPressed: _recheckPressed(context),
      key: null,
    );
    switch (widget.cardState) {
      case _RowState.processing:
      case _RowState.switched:
      case _RowState.configured:
      case _RowState.unsupported:
        return null;
      // 「已切换，尚未检测服务连接」:说明文字要的下一步就是检测。
      case _RowState.switchedUnverified:
        return recheck;
      // 中转站拒绝或配置路径不安全时,需用户处理后重新检测。
      case _RowState.needsAttention:
      case _RowState.componentMissing:
        if (_recheckOnly) return recheck;
        return (
          label: '修复并重试',
          icon: CupertinoIcons.wrench_fill,
          onPressed: _connectEnabled ? () => _repairAll(context) : null,
          key: null,
        );
      case _RowState.notInstalled:
      case _RowState.installedOfficial:
      case _RowState.enableUnsupported:
        if (_connectableRows.isEmpty) return null;
        return (
          label: '一键配置工具',
          icon: CupertinoIcons.bolt_fill,
          onPressed:
              _connectEnabled ? () => _confirmAndConnect(context) : null,
          key: null,
        );
    }
  }

  /// 「重新检测」:读本机状态 + 已切换形态验证服务连接,进度都在卡片里(2026-09-15,
  /// 此前已切换卡片弹进度弹框)。结果用顶部浮动通知。
  VoidCallback _recheckPressed(BuildContext context) {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    return () => notifier.recheckVendor(vendor);
  }

  Widget _diagnosticsLink(BuildContext context) => _RowLink(
        label: '诊断详情',
        onPressed: snapshot.canDiagnose
            ? () => _showDiagnostics(context, _attentionRows.first.target)
            : null,
      );

  List<Widget> _softwareActions(BuildContext context) {
    if (_processing || _inspecting) return const [];
    final installableMissingRows =
        _missingRows.where((r) => !r.config.pathUnsafe).toList();
    return [
      if (_installedRows.isNotEmpty && installableMissingRows.isNotEmpty)
        _RowLink(
          // 已装了一种形态时点名补装哪一种,别让人以为要重装已有的那份。
          label: '安装${installableMissingRows.map((r) => r.formLabel).join(' + ')}',
          onPressed: snapshot.canInstall
              ? () => _connect(context, installableMissingRows, confirm: true)
              : null,
        ),
      if (_missingRows.isNotEmpty)
        _RowLink(
          label: '查看系统要求',
          onPressed: snapshot.canRequirements
              ? () => _showRequirements(context)
              : null,
        ),
      if (_unsupportedRows.isNotEmpty && _attentionRows.isEmpty)
        _RowLink(
          label: '查看原因',
          onPressed: () =>
              _showUnsupportedReason(context, _unsupportedRows.first),
        ),
      if (_attentionIsDamage) _diagnosticsLink(context),
    ];
  }

  /// 契约 §2.7.4 · 目录有更高版本 →「升级到 x.y.z」。不给回退(2026-09-15 拍板:
  /// 升不升级是用户自己的选择,正常情况下不需要回退)。
  List<Widget> _versionActions(BuildContext context) {
    if (_processing || _inspecting) return const [];
    final upgradable = _upgradableRows;
    final versions = upgradable.map((r) => r.tool.availableVersion).toSet();
    return [
      if (upgradable.isNotEmpty)
        _RowLink(
          label: versions.length == 1 ? '升级到 ${versions.first}' : '升级',
          onPressed:
              snapshot.canInstall ? () => _confirmAndUpgrade(context) : null,
        ),
    ];
  }

  List<Widget> _serviceActions(BuildContext context) {
    if (_processing || _inspecting || _restorableRows.isEmpty) return const [];
    return [
      _RowLink(
        label: '恢复官方配置',
        onPressed: () => _confirmAndRestore(context),
      ),
    ];
  }

  List<Widget> _connectionActions(BuildContext context) {
    if (_processing || _inspecting) return const [];
    return [
      if (_attentionRows.isNotEmpty && !_attentionIsDamage)
        _diagnosticsLink(context),
      if (widget.cardState != _RowState.switchedUnverified && !_recheckOnly)
        _RowLink(label: '重新检测', onPressed: _recheckPressed(context)),
    ];
  }

  // ─── 交互实现 ───────────────────────────────────────────────

  Future<void> _openProgress(BuildContext context) => _showBatchDialog(
        context,
        vendor,
        fallbackTargets: [
          for (final row in rows)
            if (row.state == _RowState.processing) row.target,
        ],
      );

  /// 「打开」下拉:命令行 / 桌面端任选。
  Future<void> _openMenu(BuildContext context) async {
    final picked = await showUiDropdownMenuBelow<LocalCodingTarget>(
      context: context,
      anchorKey: _openAnchor,
      items: [
        for (final row in _openableRows)
          UiDropdownMenuItem(
            value: row.target,
            label: row.target.isDesktop ? '打开桌面端' : '打开 CLI',
            icon: row.target.isDesktop
                ? CupertinoIcons.macwindow
                : CupertinoIcons.chevron_left_slash_chevron_right,
          ),
      ],
    );
    if (picked == null || !context.mounted) return;
    await _openApp(context, picked);
  }

  /// 「打开 CLI / 打开桌面端」:按用户自己的全局配置启动,不选项目、不改配置。
  Future<void> _openApp(BuildContext context, LocalCodingTarget target) async {
    final error =
        await ref.read(localCodingToolsProvider.notifier).openApp(target);
    if (!context.mounted) return;
    if (error != null) {
      BotToast.showText(text: _userMessage(error));
      return;
    }
    final name = localCodingTargetName(target);
    BotToast.showText(text: target.isDesktop ? '已打开 $name' : '已在系统终端打开 $name');
  }

  /// 「升级到 x.y.z」:对每个可升级形态依次升级;已切换态升级后自动重新检测连接。
  Future<void> _confirmAndUpgrade(BuildContext context) async {
    final upgradable = _upgradableRows;
    if (upgradable.isEmpty) return;
    final changes = upgradable
        .map((r) =>
            '${localCodingTargetName(r.target)} ${r.tool.installedVersion} → ${r.tool.availableVersion}')
        .join('；');
    final notes = upgradable
        .map((r) => r.tool.releaseNotes.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .join('\n');
    // 契约 §2.7.4(2026-09-14):官方位置的安装不分是不是知办装的都可升级,
    // 弹框必须讲清会改本机现有安装、发行方自动更新可能再改版本。
    final description = [
      '将升级 $changes。',
      _versionChangeNotice,
      '已切换为自定义模型 API 的形态升级后会自动重新检测服务连接。',
      if (notes.isNotEmpty) '更新说明：$notes',
    ].join('\n');
    final ok = await showUiConfirmDialog(
      context,
      title: '升级 ${localCodingVendorName(vendor)}',
      description: description,
      confirmLabel: '升级',
    );
    if (!ok || !context.mounted) return;
    await _runUpgrade(context, [for (final r in upgradable) r.target]);
  }

  static const String _versionChangeNotice =
      '会直接修改本机现有的这份安装（包括你自己用官方安装器装的），不改动你的配置；发行方自带的自动更新之后可能会再次改变版本。';

  Future<void> _runUpgrade(
    BuildContext context,
    List<LocalCodingTarget> targets,
  ) async {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    final run = notifier.upgradeTargets(targets);
    final dialog = _showBatchDialog(context, vendor);
    final error = await run;
    if (error != null && context.mounted) {
      BotToast.showText(text: _userMessage(error));
    }
    await dialog;
  }

  /// 「一键配置工具」(F31 §3.2.1):链前只弹一次确认框,列这次要做的事(升级 / 接管
  /// 到哪个版本、备份并改写配置、桌面端要不要先退出);确认后整条链在进度弹框里跑。
  /// 首次接入保持用户网络设置,真实请求失败后才提供代理诊断与修复。
  Future<void> _confirmAndConnect(BuildContext context) => _connect(
        context,
        _connectableRows,
        confirm: true,
      );

  Future<void> _connect(
    BuildContext context,
    List<_RowView> rows, {
    required bool confirm,
  }) async {
    final targets = [for (final r in rows) r.target];
    if (targets.isEmpty) return;
    final notifier = ref.read(localCodingToolsProvider.notifier);
    if (confirm) {
      final plans = {for (final t in targets) t: notifier.connectPlanFor(t)};
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _ConnectConfirmDialog(
          vendor: vendor,
          plans: plans,
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    // 批处理在 provider 里同步建立;进度弹框自己观察批处理 / compound / operation。
    final run = notifier.connectTargets(targets);
    final dialog = _showBatchDialog(context, vendor);
    final error = await run;
    if (error != null && context.mounted) {
      BotToast.showText(text: _userMessage(error));
    }
    await dialog;
  }

  Future<void> _confirmAndRestore(BuildContext context) async {
    final targets = [for (final r in _restorableRows) r.target];
    final names = targets.map(localCodingTargetName).join('、');
    final ok = await showUiConfirmDialog(
      context,
      title: '恢复官方配置',
      description:
          '将按切换时的备份恢复 $names 原有配置，之后使用官方服务。知办不再自动更新版本，已安装的版本保留。',
      confirmLabel: '恢复',
    );
    if (!ok || !context.mounted) return;
    final notifier = ref.read(localCodingToolsProvider.notifier);
    // 批处理在 provider 里同步建立;进度弹框按形态显示恢复进度,完成后自动关闭。
    final run = notifier.restoreTargets(targets);
    final dialog = _showBatchDialog(context, vendor);
    final error = await run;
    if (error != null && context.mounted) {
      BotToast.showText(text: _userMessage(error));
    }
    await dialog;
  }

  /// 「修复并重试」:跑的是同一条接入链,每步自己判断要不要做。要重装 / 换版本时
  /// 弹一次确认(桌面端要先退出应用),只是重写配置 / 重新验证就直接跑;代理拦截
  /// 先设例外(契约 §2.7 network.*)。中转站拒绝或路径不安全的形态只重新检测。
  Future<void> _repairAll(BuildContext context) async {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    final rows = _attentionRows
        .where((r) => r.relayFailure == null && !r.config.pathUnsafe)
        .toList();
    if (rows.isEmpty) return;
    if (rows.any((r) => r.proxyRepairSuggested)) {
      final error = await notifier.applyProxyFix(vendor: vendor);
      if (!context.mounted) return;
      if (error != null) {
        BotToast.showText(text: _userMessage(error));
        return;
      }
    }
    final confirm =
        rows.any((r) => notifier.connectPlanFor(r.target).changesProgram);
    await _connect(context, rows, confirm: confirm);
  }

  /// v1.7 §2.2 · 「查看原因」把 detect / config 里的 LCT 错误码翻译成中文。
  /// 企业策略冲突(§7.3)取自 config.policy_conflict + LCT-*-CONFIG-POLICY_CONFLICT。
  Future<void> _showUnsupportedReason(
      BuildContext context, _RowView row) async {
    final tool = row.tool;
    final config = row.config;
    var code = '';
    if (config.policyConflict ||
        config.errorCode.endsWith('-CONFIG-POLICY_CONFLICT')) {
      code = 'CONFIG-POLICY_CONFLICT';
    } else if (tool.errorCode.isNotEmpty) {
      // 从形如 LCT-<TARGET>-DETECT-<REASON> 里抽出 "DETECT-<REASON>"。
      final parts = tool.errorCode.split('-');
      if (parts.length >= 4) {
        code = '${parts[2]}-${parts.sublist(3).join('-')}';
      } else {
        code = tool.errorCode;
      }
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _UnsupportedReasonDialog(
        rawCode: tool.errorCode.isEmpty ? config.errorCode : tool.errorCode,
        reasonCode: code,
        subject: localCodingTargetName(row.target),
        openLabel: row.target.isDesktop ? '打开桌面端' : '打开 CLI',
      ),
    );
  }

  /// 「查看系统要求」:所有缺失形态合成一个弹框,按形态分节。
  Future<void> _showRequirements(BuildContext context) async {
    final notifier = ref.read(localCodingToolsProvider.notifier);
    final items = <LocalCodingRequirements>[];
    for (final row in _missingRows) {
      final requirements = await notifier.requirements(row.target);
      if (requirements != null) items.add(requirements);
    }
    if (!context.mounted) return;
    if (items.isEmpty) {
      BotToast.showText(text: '暂时无法读取系统要求');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _RequirementsDialog(vendor: vendor, items: items),
    );
  }

  Future<void> _showDiagnostics(
      BuildContext context, LocalCodingTarget target) async {
    final diag =
        await ref.read(localCodingToolsProvider.notifier).diagnostics(target);
    if (!context.mounted) return;
    if (diag == null) {
      BotToast.showText(text: '暂时无法读取诊断详情');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _DiagnosticsDialog(diagnostics: diag),
    );
  }
}

Future<void> _showBatchDialog(
  BuildContext context,
  LocalCodingVendor vendor, {
  List<LocalCodingTarget> fallbackTargets = const [],
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BatchProgressDialog(
      vendor: vendor,
      fallbackTargets: fallbackTargets,
    ),
  );
}

String? _rowHint(_RowView row) {
  final name = localCodingTargetName(row.target);
  switch (row.state) {
    case _RowState.needsAttention:
      if (row.config.pathUnsafe) {
        return '$name 的配置目录权限或链接不满足安全要求，知办暂时无法访问配置；请检查后重新检测';
      }
      final compound = row.compound;
      if (compound != null &&
          compound.failed &&
          compound.phase == LocalCodingCompoundPhase.switchWrite) {
        return '切换未完成，$name 原有配置已保留，可重试';
      }
      if (row.authorizationLost) {
        return '$name 的设备授权已失效（可能退出过知办、切换过环境或重装过），点「修复并重试」重新接入';
      }
      if (row.proxyRepairSuggested) {
        final via =
            row.proxyEndpoint.isEmpty ? '系统代理' : '系统代理（${row.proxyEndpoint}）';
        return '$name 请求你配置的模型服务失败，可能受$via影响；可点「修复并重试」尝试为你配置的模型服务设置代理例外，或先重新检测';
      }
      if (row.config.switchedToZhiban && row.config.globalDrifted) {
        return row.config.globalSwitched
            ? '$name 的自定义模型 API 配置被修改，点「修复并重试」重写知办线路'
            : '$name 的自定义模型 API 配置缺少本机切换记录（可能重装或清理过知办），点「修复并重试」重新接入';
      }
      final relay = row.relayFailure;
      if (relay == LocalCodingRelayFailure.proxyDiverted) {
        return '$name 检测未通过：${localCodingRelayFailureSummary(relay!, row.relayDetail)}；直连规则见「诊断详情」';
      }
      if (relay == LocalCodingRelayFailure.insufficientCredit ||
          relay == LocalCodingRelayFailure.memberKeyDisabled) {
        // 换票就被拒了,请求没到中转站,没有"中转站原话"可看。
        return '$name 检测未通过：${localCodingRelayFailureSummary(relay!, row.relayDetail)}';
      }
      if (relay != null) {
        return '$name 检测未通过：${localCodingRelayFailureSummary(relay, row.relayDetail)}；中转站原话见「诊断详情」';
      }
      if (row.config.switchedToZhiban) {
        return '$name 当前无法连接自定义模型 API，点「修复并重试」后继续使用';
      }
      return '$name 安装已损坏，点「修复并重试」按锁定版本重新安装';
    case _RowState.componentMissing:
      final version = row.tool.hostComponent?.version ?? '';
      return '$name 还缺少 Claude Code 运行组件${version.isEmpty ? '' : '（$version）'}，点「修复并重试」即可下载安装。';
    case _RowState.unsupported:
      if (row.tool.resultUnreadable) {
        return '$name 检测异常：知办没能读懂这一项的检测结果，点击「查看原因」了解详情；不影响你在终端或应用里照常使用。';
      }
      return '$name 当前的安装暂不支持知办接入，点击「查看原因」了解详情；不影响你在终端或应用里照常使用。';
    case _RowState.enableUnsupported:
      if (row.tool.versionTooOld) {
        final minimum = row.tool.minimumVersion.isEmpty
            ? ''
            : '升级到 ${row.tool.minimumVersion} 或更高版本后';
        final how = switch (row.tool.installSource) {
          'npm' => '，终端运行 npm i -g @openai/codex@latest 即可升级',
          'homebrew' => '，终端运行 brew upgrade codex 即可升级',
          _ => row.upgradable ? '，可在版本行点「升级」' : '',
        };
        return '$name 版本（${row.tool.installedVersion}）过旧，$minimum才能切换为自定义模型 API；现在仍可照常使用官方服务$how';
      }
      if (row.tool.thirdPartyUnsupported) {
        final version = row.tool.installedVersion.isEmpty
            ? ''
            : '（${row.tool.installedVersion}）';
        return '$name 版本$version过旧，还不支持第三方模型配置，更新 $name 后才能切换为自定义模型 API；现在仍可照常使用官方服务';
      }
      if (row.sharedConfigTooOld) {
        return '$name 与 Codex 命令行共用配置，命令行版本过旧，需先升级命令行才能切换为自定义模型 API；现在仍可照常使用官方服务';
      }
      return '$name 暂不支持自定义模型 API，将继续以官方服务使用；命令行仍可切换。';
    case _RowState.configured:
      return '桌面端无法自动发起真实请求，验证止于配置与凭证；打开桌面端发一条消息即可确认。';
    default:
      return null;
  }
}

enum _ButtonVariant { filled, outlined, text }

Widget _actionButton(
  BuildContext context, {
  Key? key,
  required String label,
  IconData? icon,
  required VoidCallback? onPressed,
  required _ButtonVariant variant,
}) {
  Widget child = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null && icon != CupertinoIcons.chevron_down) ...[
        Icon(icon, size: 16),
        const SizedBox(width: 6),
      ],
      Text(label),
      if (icon == CupertinoIcons.chevron_down) ...[
        const SizedBox(width: 4),
        const Icon(CupertinoIcons.chevron_down, size: 14),
      ],
    ],
  );
  switch (variant) {
    case _ButtonVariant.filled:
      return FilledButton(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        child: child,
      );
    case _ButtonVariant.outlined:
      return OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: child,
      );
    case _ButtonVariant.text:
      return TextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: child,
      );
  }
}

/// 图 4 · 「切换为自定义模型 API」确认弹框:三步说明 + 本次涉及的形态 +
/// 「之后可随时恢复官方配置」。
/// 「一键配置工具」的确认框(F31 §3.2.1):链前只弹这一次,列这次要做的事——升级 /
/// 接管到哪个版本(接管写明原来的版本保留)、备份并改写配置、桌面端要不要先退出。
/// 不写安装位置与 PATH 改动(2026-09-16 产品拍板:写多了像有风险,反而劝退)。
class _ConnectConfirmDialog extends StatelessWidget {
  const _ConnectConfirmDialog({
    required this.vendor,
    required this.plans,
  });

  final LocalCodingVendor vendor;
  final Map<LocalCodingTarget, LocalCodingConnectPlan> plans;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = localCodingVendorName(vendor);
    final names = plans.keys.map(localCodingTargetName).join('、');
    final changes = <String>[];
    final quit = <String>[];
    var upgrades = false;
    for (final entry in plans.entries) {
      final target = entry.key;
      final plan = entry.value;
      final targetName = localCodingTargetName(target);
      switch (plan.action) {
        case LocalCodingProgramAction.none:
          break;
        case LocalCodingProgramAction.install:
          changes.add('安装 $targetName');
        case LocalCodingProgramAction.repair:
          changes.add('重新安装 $targetName（安装已损坏，按锁定版本）');
        case LocalCodingProgramAction.adopt:
          changes.add(
              '$targetName ${plan.fromVersion} → ${plan.toVersion}（由知办接管，你原来的版本会保留）');
          upgrades = true;
        case LocalCodingProgramAction.upgrade:
          changes.add('$targetName ${plan.fromVersion} → ${plan.toVersion}（升级）');
          upgrades = true;
      }
      if (target.isDesktop &&
          (plan.action == LocalCodingProgramAction.repair ||
              plan.action == LocalCodingProgramAction.upgrade)) {
        quit.add(target == LocalCodingTarget.codexDesktop
            ? 'ChatGPT（Codex 桌面端）'
            : 'Claude 桌面端');
      }
    }
    final writesConfig = plans.values.any((p) => p.writeConfig);
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return UiContentDialog(
      size: UiDialogSize.standard,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: '一键配置工具',
              subtitle: '知办将把 $name 接入自定义模型 API，使用你填写的模型服务。',
              onClose: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: 20),
            if (changes.isNotEmpty) ...[
              Text('先把程序准备好：', style: small),
              const SizedBox(height: 4),
              for (final change in changes)
                Text('· $change',
                    style: TextStyle(color: scheme.onSurface, fontSize: 14)),
              if (upgrades) ...[
                const SizedBox(height: 4),
                Text('升级会直接更新本机现有的这份安装，不改动你的配置；以后有新版知办会自动更新。',
                    style: small),
              ],
              const SizedBox(height: 16),
            ],
            if (writesConfig) ...[
              const _NumberedStep(
                index: 1,
                icon: CupertinoIcons.archivebox,
                label: '备份原有官方配置',
                connector: true,
              ),
              const _NumberedStep(
                index: 2,
                icon: CupertinoIcons.pencil,
                label: '写入自定义模型 API 配置',
                connector: true,
              ),
              const _NumberedStep(
                index: 3,
                icon: CupertinoIcons.checkmark_shield,
                label: '检测服务连接是否正常',
                connector: false,
              ),
            ] else
              Text('配置已指向自定义模型 API，只重新检测服务连接。', style: small),
            const SizedBox(height: 16),
            Text('本次接入：$names', style: small),
            if (quit.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('请先完全退出 ${quit.join('、')}，再点开始；否则无法替换正在运行的应用。',
                  style: TextStyle(color: scheme.error, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '之后可随时恢复官方配置',
                style: TextStyle(color: scheme.primary, fontSize: 14),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('开始接入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep({
    required this.index,
    required this.icon,
    required this.label,
    required this.connector,
  });

  final int index;
  final IconData icon;
  final String label;
  final bool connector;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              child: Text(
                '$index',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (connector)
              Container(
                width: 2,
                height: 28,
                color: scheme.primary.withValues(alpha: 0.25),
              ),
          ],
        ),
        const SizedBox(width: 16),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(color: scheme.onSurface, fontSize: 15)),
            ],
          ),
        ),
      ],
    );
  }
}

enum _StepState { pending, active, done, failed }

/// 一项(一个 target)在进度弹框里的展示数据。
class _ItemProgress {
  const _ItemProgress({
    required this.steps,
    required this.activeIndex,
    required this.label,
    required this.percent,
    required this.running,
    required this.failed,
    required this.cancelled,
    required this.errorCode,
    required this.errorMessage,
    required this.cancellable,
    this.errorDetail = '',
  });

  final List<String> steps;
  final int activeIndex;
  final String label;
  final int? percent;
  final bool running;
  final bool failed;
  final bool cancelled;
  final String errorCode;
  final String errorMessage;
  final bool cancellable;

  /// 检测失败时中转站返回的原话。
  final String errorDetail;

  bool get finished => !running && !failed;
}

/// 图 11 · 进度弹框(按形态分块)。安装:下载安装包 / 验证安装包 / 安装应用 /
/// 检测软件状态;切换:备份原有配置 / 写入自定义模型 API 配置 / 检测服务连接。
/// 弹框自己观察 provider 的批处理 + 各项 operation / compound;全部成功自动
/// 关闭,任一项失败停留并给出诊断入口。
/// v3.11(2026-09-14):运行中可用右上角 × / Esc 关闭,批处理在后台继续(provider
/// keepAlive、Bridge 会话不挂在弹框上),卡片「查看进度」可重新打开;遮罩点击仍不
/// 关闭以防误触。
class _BatchProgressDialog extends ConsumerStatefulWidget {
  const _BatchProgressDialog({
    required this.vendor,
    this.fallbackTargets = const [],
  });

  final LocalCodingVendor vendor;

  /// 没有批处理(单独一次 operation)时用来决定显示哪些项。
  final List<LocalCodingTarget> fallbackTargets;

  @override
  ConsumerState<_BatchProgressDialog> createState() =>
      _BatchProgressDialogState();
}

class _BatchProgressDialogState extends ConsumerState<_BatchProgressDialog> {
  final Map<LocalCodingTarget, LocalCodingOperation> _lastOps = {};
  final Map<LocalCodingTarget, LocalCodingOperation> _lastComponentOps = {};
  final Map<LocalCodingTarget, LocalCodingCompound> _lastCompounds = {};
  LocalCodingBatch? _lastBatch;
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(localCodingToolsProvider).value;
    final batch = data?.batchFor(widget.vendor) ?? _lastBatch;
    if (batch != null) _lastBatch = batch;
    final targets = batch?.targets ??
        (widget.fallbackTargets.isEmpty
            ? widget.vendor.targets
            : widget.fallbackTargets);
    final componentOnly = batch?.componentOnly ?? false;

    final items = <LocalCodingTarget, _ItemProgress>{};
    final componentItems = <LocalCodingTarget, _ItemProgress>{};
    for (final target in targets) {
      final op = data?.operationFor(target);
      final compound = data?.compoundFor(target);
      final componentItem = batch?.componentFor(target);
      // 组件步在跑时该 target 的 operation 属于组件步,否则属于主步。
      final componentOwnsOp = componentItem != null &&
          componentItem.status == LocalCodingBatchItemStatus.running;
      final mainOp = componentOwnsOp ? null : op;
      final componentOp = componentOwnsOp ? op : null;
      if (mainOp != null) _lastOps[target] = mainOp;
      if (componentOp != null) _lastComponentOps[target] = componentOp;
      if (compound != null) _lastCompounds[target] = compound;
      if (!componentOnly) {
        items[target] = _itemProgress(
          target: target,
          batch: batch,
          op: mainOp,
          lastOp: _lastOps[target],
          compound: compound,
          lastCompound: _lastCompounds[target],
          // 升级:已切换态多一步全局验证。
          chainVerify:
              data?.snapshot.configurations[target]?.switchedToZhiban ?? false,
        );
      }
      if (componentItem != null) {
        componentItems[target] = _itemProgress(
          target: target,
          batch: batch,
          op: componentOp,
          lastOp: _lastComponentOps[target],
          compound: null,
          lastCompound: null,
          componentStep: componentItem,
        );
      }
    }
    final all = [...items.values, ...componentItems.values];
    final anyRunning =
        (batch != null && !batch.done) || all.any((i) => i.running);
    final anyFailed = all.any((i) => i.failed);
    final allCancelled = !anyRunning &&
        !anyFailed &&
        all.isNotEmpty &&
        all.every((i) => i.cancelled);
    final finished = !anyRunning && !anyFailed;

    if (finished && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(localCodingToolsProvider.notifier).dismissBatch(widget.vendor);
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
    }

    final scheme = Theme.of(context).colorScheme;
    final brand = _brand(widget.vendor);
    final name = localCodingVendorName(widget.vendor);
    final kind = batch?.kind ?? _inferKind(items.keys, data);
    late String title;
    late String subtitle;
    late String footer;
    late String cancelLabel;
    switch (kind) {
      case LocalCodingBatchKind.install:
        title = '正在安装 $name';
        subtitle = '请保持知办运行，安装完成后将自动检测';
        footer = '安装过程通常需要 1–3 分钟';
        cancelLabel = '取消安装';
        break;
      case LocalCodingBatchKind.connect:
        title = '正在接入 $name';
        subtitle = '请保持知办运行，完成后将自动检测服务连接';
        footer = '要下载新版本时通常需要 1–3 分钟，否则半分钟内完成';
        cancelLabel = '取消';
        break;
      case LocalCodingBatchKind.switchToZhiban:
        title = '正在切换 $name';
        subtitle = '请保持知办运行，完成后将自动检测服务连接';
        footer = '检测通常在半分钟内完成';
        cancelLabel = '取消检测';
        break;
      case LocalCodingBatchKind.repairSwitch:
        title = '正在修复 $name';
        subtitle = '请保持知办运行，完成后将自动检测服务连接';
        footer = '检测通常在半分钟内完成';
        cancelLabel = '取消检测';
        break;
      case LocalCodingBatchKind.verify:
        title = '正在检测 $name';
        subtitle = '命令行将发送一次真实请求，产生极少量模型用量；桌面端只校验配置与凭证';
        footer = '检测通常在半分钟内完成';
        cancelLabel = '取消检测';
        break;
      case LocalCodingBatchKind.upgrade:
        title = '正在升级 $name';
        subtitle = '请保持知办运行，升级不改动你的配置；已切换的形态完成后将自动检测连接';
        footer = '升级通常需要 1–3 分钟';
        cancelLabel = '取消升级';
        break;
      case LocalCodingBatchKind.restore:
        title = '正在恢复 $name 官方配置';
        subtitle = '按切换时的备份恢复原有配置，完成后使用官方服务';
        footer = '恢复通常在几秒内完成';
        cancelLabel = '取消';
        break;
    }
    if (finished) {
      title = allCancelled ? '已取消' : title.replaceFirst('正在', '已完成：');
    }

    final failedTargets = <LocalCodingTarget>[
      for (final entry in items.entries)
        if (entry.value.failed) entry.key,
      for (final entry in componentItems.entries)
        if (entry.value.failed) entry.key,
    ];
    final runningEntry = [
      ...items.entries.where((e) => e.value.running && e.value.cancellable),
      ...componentItems.entries
          .where((e) => e.value.running && e.value.cancellable),
    ];

    void close() => _close(
          context,
          anyRunning: anyRunning,
          anyFailed: anyFailed,
          failedTargets: failedTargets,
        );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: Focus(
        autofocus: true,
        child: UiContentDialog(
      size: UiDialogSize.standard,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BrandTile(brand: brand, size: 56, markSize: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // v3.11 · 运行中也能关:关掉只是不看进度,批处理照跑。
                IconButton(
                  key: const ValueKey('batch-progress-close'),
                  tooltip: anyRunning ? '关闭窗口，后台继续' : '关闭',
                  onPressed: close,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(CupertinoIcons.xmark,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 24),
            for (var i = 0; i < targets.length; i++) ...[
              if (items[targets[i]] != null)
                _ItemProgressView(
                  title: targets[i].isDesktop ? '桌面端' : '命令行',
                  icon: targets[i].isDesktop
                      ? CupertinoIcons.macwindow
                      : CupertinoIcons.chevron_left_slash_chevron_right,
                  progress: items[targets[i]]!,
                ),
              if (componentItems[targets[i]] != null) ...[
                if (items[targets[i]] != null) const SizedBox(height: 14),
                _ItemProgressView(
                  title: '桌面端运行组件（Claude Code 宿主）',
                  icon: CupertinoIcons.cube_box,
                  progress: componentItems[targets[i]]!,
                ),
              ],
              if (i != targets.length - 1) ...[
                const SizedBox(height: 16),
                Divider(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                    height: 1),
                const SizedBox(height: 16),
              ],
            ],
            const SizedBox(height: 24),
            Divider(
                color: scheme.outlineVariant.withValues(alpha: 0.4), height: 1),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        footer,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 14),
                      ),
                      if (anyRunning) ...[
                        const SizedBox(height: 4),
                        Text(
                          _backgroundHint(kind),
                          style: TextStyle(
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.8),
                              fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                if (anyRunning && runningEntry.isNotEmpty)
                  OutlinedButton(
                    onPressed: () => ref
                        .read(localCodingToolsProvider.notifier)
                        .cancelRunning(runningEntry.first.key),
                    child: Text(cancelLabel),
                  ),
                if (!anyRunning && anyFailed) ...[
                  TextButton(
                    onPressed: () =>
                        _openDiagnostics(context, failedTargets.first),
                    child: const Text('诊断详情'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final notifier =
                          ref.read(localCodingToolsProvider.notifier);
                      notifier.dismissBatch(widget.vendor);
                      for (final target in failedTargets) {
                        notifier.dismissCompound(target);
                      }
                      Navigator.of(context).pop();
                    },
                    child: const Text('关闭'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  /// 关闭弹框。运行中:只关窗口,批处理与 Bridge 会话都不受影响,卡片仍显示
  /// 「进行中」并可「查看进度」重开;失败停留态:与「关闭」按钮同义,清掉批处理与
  /// 失败 compound 让卡片回到快照状态。
  void _close(
    BuildContext context, {
    required bool anyRunning,
    required bool anyFailed,
    required List<LocalCodingTarget> failedTargets,
  }) {
    if (!anyRunning && anyFailed) {
      final notifier = ref.read(localCodingToolsProvider.notifier);
      notifier.dismissBatch(widget.vendor);
      for (final target in failedTargets) {
        notifier.dismissCompound(target);
      }
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  String _backgroundHint(LocalCodingBatchKind kind) {
    switch (kind) {
      case LocalCodingBatchKind.install:
        return '关闭此窗口不会中断安装，可随时在卡片上点「查看进度」';
      case LocalCodingBatchKind.connect:
        return '关闭此窗口不会中断接入，可随时在卡片上点「查看进度」';
      case LocalCodingBatchKind.upgrade:
        return '关闭此窗口不会中断升级，可随时在卡片上点「查看进度」';
      case LocalCodingBatchKind.restore:
        return '关闭此窗口不会中断恢复，可随时在卡片上点「查看进度」';
      case LocalCodingBatchKind.switchToZhiban:
      case LocalCodingBatchKind.repairSwitch:
      case LocalCodingBatchKind.verify:
        return '关闭此窗口不会中断检测，可随时在卡片上点「查看进度」';
    }
  }

  LocalCodingBatchKind _inferKind(
    Iterable<LocalCodingTarget> targets,
    LocalCodingToolsPageData? data,
  ) {
    for (final target in targets) {
      final compound = data?.compoundFor(target) ?? _lastCompounds[target];
      if (compound != null) {
        return compound.kind == LocalCodingCompoundKind.repairSwitch
            ? LocalCodingBatchKind.repairSwitch
            : LocalCodingBatchKind.switchToZhiban;
      }
      final op = data?.operationFor(target) ?? _lastOps[target];
      if (op != null) {
        return op.kind == LocalCodingOperationKind.verify
            ? LocalCodingBatchKind.verify
            : LocalCodingBatchKind.install;
      }
    }
    return LocalCodingBatchKind.install;
  }

  Future<void> _openDiagnostics(
      BuildContext context, LocalCodingTarget target) async {
    final diag =
        await ref.read(localCodingToolsProvider.notifier).diagnostics(target);
    if (!context.mounted) return;
    if (diag == null) {
      BotToast.showText(text: '暂时无法读取诊断详情');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _DiagnosticsDialog(diagnostics: diag),
    );
  }
}

/// 接入链失败时的标题:写明停在哪一步(F31 §3.2.1),下一步在失败块的文案里。
String _connectFailureLabel(
  LocalCodingConnectPlan? plan,
  LocalCodingCompound? compound,
  LocalCodingOperation? op,
  String errorCode,
) {
  if (compound != null && compound.failed) {
    return compound.phase == LocalCodingCompoundPhase.verify
        ? '接入后检测未通过'
        : '写入配置未完成';
  }
  if (op != null && op.kind == LocalCodingOperationKind.verify) {
    return '检测未通过';
  }
  if (plan != null &&
      plan.changesProgram &&
      ((op != null && op.kind == LocalCodingOperationKind.install) ||
          errorCode.contains('-INSTALL-'))) {
    return switch (plan.action) {
      LocalCodingProgramAction.install => '安装失败',
      LocalCodingProgramAction.repair => '重新安装失败',
      _ => '升级失败',
    };
  }
  return '接入未完成';
}

/// 把一项的 batch item + operation + compound 折算成弹框展示数据。
/// componentStep 非空时按"运行组件预置"步展示(M3 Task 8)。
_ItemProgress _itemProgress({
  required LocalCodingTarget target,
  required LocalCodingBatch? batch,
  required LocalCodingOperation? op,
  required LocalCodingOperation? lastOp,
  required LocalCodingCompound? compound,
  required LocalCodingCompound? lastCompound,
  LocalCodingBatchItem? componentStep,
  bool chainVerify = false,
}) {
  final item = componentStep ?? batch?.itemFor(target);
  final shownOp = op ?? lastOp;
  final shownCompound = compound ?? lastCompound;
  final kind = componentStep != null
      ? LocalCodingBatchKind.install
      : batch?.kind ??
          (shownCompound != null
              ? (shownCompound.kind == LocalCodingCompoundKind.repairSwitch
                  ? LocalCodingBatchKind.repairSwitch
                  : LocalCodingBatchKind.switchToZhiban)
              : (shownOp?.kind == LocalCodingOperationKind.verify
                  ? LocalCodingBatchKind.verify
                  : LocalCodingBatchKind.install));

  late List<String> steps;
  late int activeIndex;
  late String label;
  int? percent;
  switch (kind) {
    case LocalCodingBatchKind.install:
      steps = componentStep != null
          ? const ['下载运行组件', '验证运行组件', '安装运行组件', '检测运行组件']
          : const ['下载安装包', '验证安装包', '安装应用', '检测软件状态'];
      final stage = shownOp?.stage ?? 'preflight';
      activeIndex = switch (stage) {
        'verifying' => 1,
        'installing' => 2,
        'detecting' => 3,
        _ => 0,
      };
      final noun = componentStep != null ? '运行组件' : '安装包';
      label = switch (stage) {
        'preflight' => '正在准备...',
        'downloading' => '正在下载$noun...',
        'verifying' => '正在验证$noun...',
        'installing' => componentStep != null ? '正在安装运行组件...' : '正在安装应用...',
        'detecting' => componentStep != null ? '正在检测运行组件...' : '正在检测软件状态...',
        _ => '正在处理...',
      };
      percent = shownOp?.downloadPercent;
      if (percent == null && shownOp != null) {
        percent = switch (stage) {
          'verifying' => 70,
          'installing' => 80,
          'detecting' => 95,
          _ => null,
        };
      }
      break;
    case LocalCodingBatchKind.switchToZhiban:
    case LocalCodingBatchKind.repairSwitch:
      steps = target.isDesktop
          ? const ['备份原有配置', '写入知办配置', '校验配置与凭证']
          : const ['备份原有配置', '写入知办配置', '检测服务连接'];
      final phase =
          shownCompound?.phase ?? LocalCodingCompoundPhase.switchWrite;
      activeIndex = phase == LocalCodingCompoundPhase.switchWrite ? 0 : 2;
      label = activeIndex == 0
          ? '正在备份并写入配置...'
          : (target.isDesktop ? '正在校验配置与凭证...' : '正在检测服务连接...');
      if (activeIndex == 2 && shownOp != null) {
        percent = _verifyPercent(shownOp, target);
      }
      break;
    case LocalCodingBatchKind.upgrade:
      // 契约 §2.7.4 · 升级四步,已切换态再加一步全局验证(此时 op 是 verify 的探针)。
      const base = ['下载安装包', '验证安装包', '安装新版本', '检测软件状态'];
      steps = chainVerify
          ? [...base, target.isDesktop ? '校验配置与凭证' : '检测服务连接']
          : base;
      if (shownOp != null && shownOp.kind == LocalCodingOperationKind.verify) {
        activeIndex = 4;
        label = target.isDesktop ? '正在校验配置与凭证...' : '正在检测服务连接...';
        percent = _verifyPercent(shownOp, target);
        break;
      }
      final stage = shownOp?.stage ?? 'preflight';
      activeIndex = switch (stage) {
        'verifying' => 1,
        'installing' => 2,
        'detecting' => 3,
        _ => 0,
      };
      label = switch (stage) {
        'preflight' => '正在准备...',
        'downloading' => '正在下载新版本...',
        'verifying' => '正在验证安装包...',
        'installing' => '正在安装新版本...',
        'detecting' => '正在检测软件状态...',
        _ => '正在处理...',
      };
      percent = shownOp?.downloadPercent;
      if (percent == null && shownOp != null) {
        percent = switch (stage) {
          'verifying' => 70,
          'installing' => 80,
          'detecting' => 95,
          _ => null,
        };
      }
      break;
    case LocalCodingBatchKind.connect:
      // F31 §3.2.1 · 按该形态的接入计划显示步骤:程序到位(四步,跳过则不显示)→
      // 写入知办配置(已切换且未漂移则不显示)→ 检测服务连接。第②③步以 compound
      // 为准(此时 op 是 verify 的探针),第①步以安装 op 的 stage 为准。
      final plan = batch?.plans[target] ?? const LocalCodingConnectPlan();
      final programSteps = switch (plan.action) {
        LocalCodingProgramAction.none => const <String>[],
        LocalCodingProgramAction.install =>
          const ['下载安装包', '验证安装包', '安装应用', '检测软件状态'],
        LocalCodingProgramAction.repair =>
          const ['下载安装包', '验证安装包', '重新安装', '检测软件状态'],
        _ => const ['下载安装包', '验证安装包', '安装新版本', '检测软件状态'],
      };
      final verifyLabel =
          target.isDesktop ? '正在校验配置与凭证...' : '正在检测服务连接...';
      steps = [
        ...programSteps,
        if (plan.writeConfig) '写入知办配置',
        target.isDesktop ? '校验配置与凭证' : '检测服务连接',
      ];
      final configIndex = plan.writeConfig ? programSteps.length : -1;
      final verifyIndex = steps.length - 1;
      final verifyOp =
          shownOp != null && shownOp.kind == LocalCodingOperationKind.verify
              ? shownOp
              : null;
      if (shownCompound != null) {
        final writing =
            shownCompound.phase == LocalCodingCompoundPhase.switchWrite;
        activeIndex = writing && configIndex >= 0 ? configIndex : verifyIndex;
        label = writing ? '正在备份并写入配置...' : verifyLabel;
        if (!writing && verifyOp != null) {
          percent = _verifyPercent(verifyOp, target);
        }
        break;
      }
      if (verifyOp != null) {
        activeIndex = verifyIndex;
        label = verifyLabel;
        percent = _verifyPercent(verifyOp, target);
        break;
      }
      if (programSteps.isEmpty) {
        activeIndex = configIndex >= 0 ? configIndex : verifyIndex;
        label = configIndex >= 0 ? '正在备份并写入配置...' : '正在准备...';
        break;
      }
      final stage = shownOp?.stage ?? 'preflight';
      activeIndex = switch (stage) {
        'verifying' => 1,
        'installing' => 2,
        'detecting' => 3,
        _ => 0,
      };
      label = switch (stage) {
        'preflight' => '正在准备...',
        'downloading' => '正在下载安装包...',
        'verifying' => '正在验证安装包...',
        'installing' => plan.action == LocalCodingProgramAction.install
            ? '正在安装应用...'
            : '正在安装新版本...',
        'detecting' => '正在检测软件状态...',
        _ => '正在处理...',
      };
      percent = shownOp?.downloadPercent;
      if (percent == null && shownOp != null) {
        percent = switch (stage) {
          'verifying' => 70,
          'installing' => 80,
          'detecting' => 95,
          _ => null,
        };
      }
      break;
    case LocalCodingBatchKind.verify:
      steps = target.isDesktop
          ? const ['检查配置', '获取访问凭证']
          : const ['获取访问凭证', '发送真实请求'];
      final stage = shownOp?.stage ?? 'l1';
      activeIndex =
          target.isDesktop ? (stage == 'l2' ? 1 : 0) : (stage == 'l3' ? 1 : 0);
      label = target.isDesktop
          ? (activeIndex == 0 ? '正在检查配置...' : '正在获取访问凭证...')
          : (activeIndex == 0 ? '正在获取访问凭证...' : '正在发送真实请求...');
      if (shownOp != null) percent = _verifyPercent(shownOp, target);
      break;
    case LocalCodingBatchKind.restore:
      // 恢复是同步的 config.plan(restore_global) → config.execute,再重新检测;
      // 没有 operation 可观察,按批处理项状态推进。
      steps = const ['恢复原有配置', '检测软件状态'];
      activeIndex = 0;
      label = '正在恢复原有配置...';
      break;
  }

  if (shownOp?.kind == LocalCodingOperationKind.install &&
      shownOp?.stage == 'authorizing') {
    steps = ['管理员授权', ...steps];
    activeIndex = 0;
    label = '等待 Windows 管理员授权，请在系统提示中选择“是”';
    percent = null;
  }

  // 项状态:优先按批处理项;没有批处理时按 operation / compound 推断。
  var running = false;
  var failed = false;
  var cancelled = false;
  var errorCode = '';
  var errorMessage = '';
  var errorDetail = '';
  if (item != null) {
    errorMessage = item.errorMessage;
    errorDetail = item.errorDetail;
    switch (item.status) {
      case LocalCodingBatchItemStatus.pending:
        running = true;
        label = '等待中...';
        percent = null;
        activeIndex = -1;
        break;
      case LocalCodingBatchItemStatus.running:
        running = true;
        break;
      case LocalCodingBatchItemStatus.succeeded:
        break;
      case LocalCodingBatchItemStatus.failed:
        failed = true;
        errorCode = item.errorCode;
        break;
      case LocalCodingBatchItemStatus.cancelled:
        cancelled = true;
        break;
    }
  } else {
    running = (op != null && !op.isTerminal) ||
        (compound != null && !compound.failed);
    failed = (shownCompound?.failed ?? false) ||
        (shownOp != null && shownOp.isFailed && compound == null);
    cancelled = !running &&
        !failed &&
        shownOp != null &&
        shownOp.isCancelled &&
        compound == null;
    errorCode = shownCompound?.errorCode.isNotEmpty == true
        ? shownCompound!.errorCode
        : (shownOp?.errorCode ?? '');
  }
  if (errorCode.isEmpty && failed) {
    errorCode = shownCompound?.errorCode.isNotEmpty == true
        ? shownCompound!.errorCode
        : (shownOp?.errorCode ?? '');
  }
  if (failed && errorDetail.isEmpty) errorDetail = shownOp?.errorDetail ?? '';
  final relay = failed ? localCodingRelayFailure(errorCode, errorDetail) : null;
  if (relay != null && errorMessage.isEmpty) {
    errorMessage = localCodingRelayFailureSummary(relay, errorDetail);
  }
  if (!running && !failed) {
    activeIndex = steps.length;
    percent = 100;
    label = cancelled ? '已取消' : '已完成';
  }
  if (failed) {
    label = switch (kind) {
      LocalCodingBatchKind.install => '安装失败',
      LocalCodingBatchKind.verify => '检测未通过',
      LocalCodingBatchKind.upgrade =>
        shownOp?.kind == LocalCodingOperationKind.verify ? '升级后检测未通过' : '升级失败',
      LocalCodingBatchKind.connect => _connectFailureLabel(
          batch?.plans[target], shownCompound, shownOp, errorCode),
      _ => '切换未完成',
    };
    if (errorCode.endsWith('-AUTHORIZATION_CANCELLED')) {
      label = '已取消授权，尚未安装';
      percent = null;
    } else if (errorCode.endsWith('-AUTHORIZATION_TIMEOUT')) {
      label = '等待授权超时，尚未安装';
      percent = null;
    } else if (errorCode.endsWith('-AUTHORIZATION_FAILED')) {
      label = '未能申请管理员授权';
      percent = null;
    }
  }
  return _ItemProgress(
    steps: steps,
    activeIndex: activeIndex,
    label: label,
    percent: percent,
    running: running,
    failed: failed,
    cancelled: cancelled,
    errorCode: errorCode,
    errorMessage: errorMessage,
    errorDetail: errorDetail,
    cancellable: op != null && !op.isTerminal && op.cancellable,
  );
}

int? _verifyPercent(LocalCodingOperation op, LocalCodingTarget target) {
  if (op.isTerminal) return op.isSucceeded ? 100 : null;
  if (target.isDesktop) {
    return switch (op.stage) {
      'l1' => 30,
      'l2' => 70,
      _ => null,
    };
  }
  return switch (op.stage) {
    'l1' => 20,
    'l2' => 50,
    'l3' => 80,
    _ => null,
  };
}

class _ItemProgressView extends StatelessWidget {
  const _ItemProgressView({
    required this.title,
    required this.icon,
    required this.progress,
  });

  final String title;
  final IconData icon;
  final _ItemProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failedColor = const Color(0xFFDC2626);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                progress.label,
                style: TextStyle(
                  color: progress.failed ? failedColor : scheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (progress.percent != null)
              Text(
                '${progress.percent}%',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            // 失败项用红色满条,不再做不确定进度动画。
            value: progress.failed
                ? 1
                : (progress.percent == null ? null : progress.percent! / 100),
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            color: progress.failed ? failedColor : scheme.primary,
          ),
        ),
        const SizedBox(height: 14),
        _StepStrip(
          steps: progress.steps,
          activeIndex: progress.activeIndex,
          failed: progress.failed,
        ),
        if (progress.failed && progress.errorCode.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (progress.errorMessage.isNotEmpty) ...[
                  Text(
                    progress.errorMessage,
                    style: const TextStyle(
                        color: Color(0xFFB91C1C), fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  '错误码 ${progress.errorCode}',
                  style: const TextStyle(
                      color: Color(0xFFB91C1C),
                      fontSize: 13,
                      fontFamily: 'Menlo'),
                ),
                if (progress.errorDetail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    '${localCodingErrorDetailLabel(progress.errorDetail)} ${progress.errorDetail}',
                    style: const TextStyle(
                        color: Color(0xFFB91C1C), fontSize: 12, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 进度弹框的步骤条:每步等宽,状态图标在上、标签在下居中,不画连线
/// (2026-09-11 用户反馈:连线难看)。步数再多也只占一行、各列对齐
/// (安装即切换有六步,原来的 Wrap 会折成两行且列不对齐)。
class _StepStrip extends StatelessWidget {
  const _StepStrip({
    required this.steps,
    required this.activeIndex,
    required this.failed,
  });

  final List<String> steps;
  final int activeIndex;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: _StepNode(
              label: steps[i],
              state: i < activeIndex
                  ? _StepState.done
                  : i == activeIndex
                      ? (failed ? _StepState.failed : _StepState.active)
                      : _StepState.pending,
            ),
          ),
      ],
    );
  }
}

class _StepNode extends StatelessWidget {
  const _StepNode({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const doneColor = Color(0xFF16A34A);
    const failedColor = Color(0xFFDC2626);
    late Widget marker;
    late Color color;
    switch (state) {
      case _StepState.done:
        color = doneColor;
        marker = const Icon(CupertinoIcons.checkmark_alt_circle_fill,
            size: 18, color: doneColor);
        break;
      case _StepState.active:
        color = scheme.primary;
        marker = const SizedBox(
          width: 18,
          height: 18,
          child: CupertinoActivityIndicator(radius: 8),
        );
        break;
      case _StepState.failed:
        color = failedColor;
        marker = const Icon(CupertinoIcons.xmark_circle_fill,
            size: 18, color: failedColor);
        break;
      case _StepState.pending:
        color = scheme.onSurfaceVariant.withValues(alpha: 0.7);
        marker = Icon(CupertinoIcons.circle,
            size: 18, color: scheme.onSurfaceVariant.withValues(alpha: 0.5));
        break;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        marker,
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              height: 1.3,
              fontWeight: state == _StepState.active
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolBrand {
  const _ToolBrand({
    required this.name,
    required this.subtitle,
    required this.markAsset,
    required this.tileStart,
    required this.tileEnd,
    this.appIcon = '',
  });

  /// 发行方桌面应用的真实图标(从 Claude.app / Codex.app 的 icns 导出并裁到可见
  /// 形状,2026-09-11 用户反馈自绘的星芒和真实图标有差异)。为空时退回渐变
  /// 色块 + markAsset。
  final String appIcon;

  final String name;
  final String subtitle;
  final String markAsset;
  final Color tileStart;
  final Color tileEnd;
}

_ToolBrand _brand(LocalCodingVendor vendor) {
  switch (vendor) {
    case LocalCodingVendor.codex:
      return const _ToolBrand(
        name: 'Codex',
        subtitle: 'OpenAI 官方 AI 编程助手',
        markAsset: 'assets/icons/providers/openai-mark.svg',
        appIcon: 'assets/icons/providers/codex-app.png',
        tileStart: Color(0xFF12B08A),
        tileEnd: Color(0xFF0E8F70),
      );
    case LocalCodingVendor.claude:
      return const _ToolBrand(
        name: 'Claude',
        subtitle: 'Anthropic 官方 AI 编程助手',
        markAsset: 'assets/icons/providers/claude-mark.svg',
        appIcon: 'assets/icons/providers/claude-app.png',
        tileStart: Color(0xFFF0865C),
        tileEnd: Color(0xFFD9683F),
      );
  }
}

/// 单个 target 的状态判定,只以 tool.detect / config.status / 本地 op & compound /
/// 批处理项为准。Bridge 的 tool.detect 只会回 not_installed /
/// installed_unmanaged / repairable / unsupported 四态;CLI 的"运行正常"取决于
/// global_verification_level == 'l3',桌面端的"已配置"取决于 l2(契约 §2.7.3)。
_RowState _resolveRowState({
  required LocalCodingToolState tool,
  required LocalCodingConfigurationStatus config,
  required LocalCodingOperation? op,
  required LocalCodingCompound? compound,
  required LocalCodingBatchItem? batchItem,
  required bool batchRunning,
  bool authorizationLost = false,
  bool proxyRepairSuggested = false,
  bool sharedConfigTooOld = false,
}) {
  final runningOp = op != null && !op.isTerminal;
  final runningCompound = compound != null && !compound.failed;
  final runningItem = batchRunning &&
      batchItem != null &&
      (batchItem.status == LocalCodingBatchItemStatus.running ||
          batchItem.status == LocalCodingBatchItemStatus.pending);
  if (runningOp || runningCompound || runningItem) return _RowState.processing;
  if (config.pathUnsafe) return _RowState.needsAttention;
  // v1.7 §7.3 · 企业策略冲突压过其它状态,统一显示"暂不支持"。
  if (config.policyConflict) return _RowState.unsupported;
  // 本机多份安装时 Bridge 已自动选定用户实际在用的那份(契约 §2.7,2026-09-14),
  // 这里不再有"选择版本"态。
  if (tool.uiState == LocalCodingToolUiState.unsupported) {
    return _RowState.unsupported;
  }
  if (tool.uiState == LocalCodingToolUiState.repairable) {
    return _RowState.needsAttention;
  }
  if (tool.uiState == LocalCodingToolUiState.notInstalled) {
    return _RowState.notInstalled;
  }
  // 验证失败只对配置仍指向知办的形态有意义。恢复官方配置之后遗留的失败记录
  // (Codex 两形态共用配置,只恢复桌面端也会把命令行带回官方)不再算"需要处理",
  // 否则主按钮「修复并重试」一点又接回知办(12900 真机)。
  final verifyFailureStale = !config.switchedToZhiban;
  if (op != null &&
      op.isFailed &&
      op.kind == LocalCodingOperationKind.verify &&
      !verifyFailureStale) {
    return _RowState.needsAttention;
  }
  if (compound != null &&
      compound.failed &&
      !(compound.phase == LocalCodingCompoundPhase.verify &&
          verifyFailureStale)) {
    return _RowState.needsAttention;
  }
  if (batchItem != null &&
      batchItem.status == LocalCodingBatchItemStatus.failed &&
      config.switchedToZhiban) {
    return _RowState.needsAttention;
  }
  // 配置仍指向知办、设备授权却没了:不修就连不上,标"需要处理"(2026-09-14)。
  if (authorizationLost) return _RowState.needsAttention;
  // 仅真实验证失败产生代理诊断;配置状态本身不判故障。
  if (proxyRepairSuggested) return _RowState.needsAttention;
  // 契约 §2.7.2 global_drifted:切换后受管区域(provider / base_url / helper /
  // 模型别名)被改动,知办线路可能已失效;主动标"需要处理",修复并重试 = 重新切换。
  if (config.switchedToZhiban && config.globalDrifted) {
    return _RowState.needsAttention;
  }
  // 桌面端没有可写的第三方配置;命令行版本过旧(2026-09-15 最低版本门槛)且还没
  // 切换时同样只能用官方服务。已切换的旧版本照常显示,保留恢复官方配置的入口。
  if ((!tool.supportsEnable || sharedConfigTooOld) &&
      (tool.target.isDesktop || !config.switchedToZhiban)) {
    return _RowState.enableUnsupported;
  }
  // M3 Task 8 · 桌面端缺运行组件(如 Claude Desktop 的 Claude Code 宿主包)时,
  // 不论是否已切换都发不出消息,先修组件。
  if (tool.componentNeedsProvisioning) {
    return _RowState.componentMissing;
  }
  if (config.switchedToZhiban) {
    if (tool.target.isDesktop) {
      return config.globalVerifiedL2
          ? _RowState.configured
          : _RowState.switchedUnverified;
    }
    return config.globalVerifiedL3
        ? _RowState.switched
        : _RowState.switchedUnverified;
  }
  return _RowState.installedOfficial;
}

/// 卡级角标 = 所有形态的最差状态:处理中 > 需要处理 > 暂不支持 >
/// 待检测 > 已安装(含部分切换)> 已配置 / 运行正常;两种形态都没装 → 未安装;
/// 只装了桌面端且已切换 → 最高"已配置",不得显示"运行正常"。
_RowState _resolveCardState(List<_RowView> rows) {
  if (rows.isEmpty) return _RowState.notInstalled;
  if (rows.any((r) => r.state == _RowState.processing)) {
    return _RowState.processing;
  }
  if (rows.any((r) => r.needsRepair)) return _RowState.needsAttention;
  final installed = rows.where((r) => r.installed).toList();
  if (installed.isEmpty) return _RowState.notInstalled;
  if (installed.every((r) => r.state == _RowState.unsupported)) {
    return _RowState.unsupported;
  }
  final usable =
      installed.where((r) => r.state != _RowState.unsupported).toList();
  if (usable.any((r) => r.state == _RowState.switchedUnverified)) {
    return _RowState.switchedUnverified;
  }
  if (usable.every((r) =>
      r.state == _RowState.switched || r.state == _RowState.configured)) {
    return usable.any((r) => r.state == _RowState.switched)
        ? _RowState.switched
        : _RowState.configured;
  }
  return _RowState.installedOfficial;
}

/// 卡片信息行:标签 | 取值 | 行尾操作(文字链接)。窄卡时操作换到取值下方。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.actions,
    required this.wide,
    this.stale = false,
    this.checking = false,
  });

  final String label;
  final Widget value;
  final List<Widget> actions;
  final bool wide;

  /// 检测中、这一行还没按本次检测刷新:取值变淡(淡入回来,不改变行高)。
  final bool stale;

  /// 正在查这一行:行尾操作位显示「检测中」,取值位置不动。
  final bool checking;

  static const double _labelWidth = 76;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelBox = SizedBox(
      width: _labelWidth,
      child: Text(
        label,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
    );
    final value = AnimatedOpacity(
      opacity: stale ? 0.45 : 1,
      duration: const Duration(milliseconds: 220),
      child: this.value,
    );
    final actions = checking ? const [_CheckingMark()] : this.actions;
    if (wide) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              labelBox,
              const SizedBox(width: 12),
              Expanded(child: value),
              if (actions.isNotEmpty) ...[
                const SizedBox(width: 16),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [labelBox, const SizedBox(width: 12), Expanded(child: value)],
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: _labelWidth + 4, top: 4),
              child: Wrap(spacing: 8, children: actions),
            ),
        ],
      ),
    );
  }
}

/// 行尾「检测中」。
class _CheckingMark extends StatelessWidget {
  const _CheckingMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 32,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(radius: 6),
          const SizedBox(width: 6),
          Text('检测中',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// 标题下的说明行,始终是固定文字。检测进度 2026-09-15 起改为顶部浮动通知
/// ([_ResultToast]):说明行在页面顶端,滚到下面的卡片时看不到进度(用户反馈)。
class _PageSubtitle extends StatelessWidget {
  const _PageSubtitle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 24,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '安装、检测并配置本机 AI 编程工具',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 检测中替换卡片底部按钮行的本卡检测步骤,与按钮行等高,检测完换回按钮时卡片不跳。
class _CardInspectPanel extends StatelessWidget {
  const _CardInspectPanel({required this.vendor, required this.progress});

  final LocalCodingVendor vendor;
  final LocalCodingInspectProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = progress.current;
    final active = current?.vendor == vendor;
    final String title;
    if (active) {
      title = '正在${current!.label}…';
    } else if (current == null || current.vendor == null) {
      title = '正在准备检测…';
    } else {
      // 整机检测是一条串行流水线,轮到另一张卡时这张卡只是还没轮到 / 还剩最后一步,
      // 前后也就一两秒。以前写"等待 Claude 检测完成…",Codex 卡停在 3/4 时读起来像
      // 它依赖 Claude、卡住了(2026-09-20 用户反馈);这种一闪而过的状态不解释,
      // 查到哪个工具的哪一步由顶部进度交代。
      title = '检测中…';
    }
    final items = <Widget>[];
    var total = 0;
    for (var i = 0; i < progress.steps.length; i++) {
      final step = progress.steps[i];
      if (step.vendor != vendor) continue;
      total++;
      final done = i < progress.completed;
      final now = i == progress.completed;
      final color = done
          ? scheme.onSurface.withValues(alpha: 0.75)
          : now
              ? scheme.primary
              : scheme.onSurfaceVariant.withValues(alpha: 0.7);
      items.add(Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? _dotColor(_DotColor.success, scheme)
                    : now
                        ? scheme.primary
                        : scheme.outlineVariant,
              ),
            ),
            const SizedBox(width: 5),
            Text(step.label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ));
    }
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const CupertinoActivityIndicator(radius: 6),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(color: scheme.onSurface, fontSize: 13)),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(children: items),
            ),
          ),
          Text(
            '${progress.doneCountFor(vendor)}/$total',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 首次进入、这张卡还没读到任何结果:信息行标签照常,取值用灰条占位。
class _SkeletonCardBody extends StatelessWidget {
  const _SkeletonCardBody({required this.vendor, required this.progress});

  final LocalCodingVendor vendor;
  final LocalCodingInspectProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final checking = progress.current?.vendor == vendor;
    Widget bar(double width) => Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: width,
            height: 12,
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 560;
        final lines = [
          ('软件状态', 170.0),
          ('版本', 230.0),
          ('当前服务', 96.0),
          ('服务连接', 120.0),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              _InfoRow(
                label: lines[i].$1,
                wide: wide,
                checking: checking,
                value: bar(lines[i].$2),
                actions: const [],
              ),
              if (i != lines.length - 1)
                Divider(
                  height: 1,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? scheme.outlineVariant.withValues(alpha: 0.25)
                      : _cardRowDividerColor,
                ),
            ],
            const SizedBox(height: 16),
            _CardInspectPanel(vendor: vendor, progress: progress),
          ],
        );
      },
    );
  }
}

/// 行尾操作:紧凑文字链接,同一张卡的次要操作都落在右边线上。
class _RowLink extends StatelessWidget {
  const _RowLink({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}

class _FactText extends StatelessWidget {
  const _FactText(this.fact);

  final _Fact fact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      fact.value,
      style: TextStyle(
        fontSize: 14,
        color: fact.tone == _DotColor.error
            ? _dotColor(_DotColor.error, scheme)
            : scheme.onSurface,
      ),
    );
  }
}

/// 版本行取值:"命令行 0.153.4 · 桌面端 26.908.40834",可升级的形态后面带「新版本 x」。
class _VersionValue extends StatelessWidget {
  const _VersionValue(this.versions);

  final List<({String text, String upgradeTo})> versions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < versions.length; i++) ...[
          if (i > 0)
            Text('·',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14)),
          Text(versions[i].text,
              style: TextStyle(color: scheme.onSurface, fontSize: 14)),
          if (versions[i].upgradeTo.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '新版本 ${versions[i].upgradeTo}',
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// 服务连接行取值:状态点 + 状态 + "· 3 分钟前检测"(上次验证连通的时间)。
class _ConnectionValue extends StatefulWidget {
  const _ConnectionValue({required this.fact, required this.verifiedAt});

  final _Fact fact;

  /// 上次验证连通的时间;null 时不显示时间。
  final DateTime? verifiedAt;

  @override
  State<_ConnectionValue> createState() => _ConnectionValueState();
}

class _ConnectionValueState extends State<_ConnectionValue> {
  /// 每分钟重算一次相对时间("刚刚" → "3 分钟前"),只刷新文字,不触发检测。
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(covariant _ConnectionValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTick();
  }

  void _syncTick() {
    if (widget.verifiedAt == null) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final verifiedAt = widget.verifiedAt;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: _dotColor(widget.fact.tone, scheme),
            shape: BoxShape.circle,
          ),
        ),
        _FactText(widget.fact),
        if (verifiedAt != null)
          Text(
            '· ${_relativeTime(verifiedAt)}检测',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
      ],
    );
  }
}

/// 需要处理时底部上方的橙色提示条。
class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const amber = Color(0xFFF59E0B);
    final foreground = dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: dark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(CupertinoIcons.exclamationmark_circle_fill,
                size: 15, color: foreground),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: foreground, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

Color _dotColor(_DotColor dot, ColorScheme scheme) {
  switch (dot) {
    case _DotColor.success:
      return const Color(0xFF22C55E);
    case _DotColor.warning:
      return const Color(0xFFF59E0B);
    case _DotColor.error:
      return const Color(0xFFDC2626);
    case _DotColor.info:
      return scheme.primary;
    case _DotColor.muted:
      return scheme.onSurfaceVariant.withValues(alpha: 0.4);
  }
}

/// 「查看系统要求」:该厂商所有待安装形态合成一个弹框,按形态分节。
class _RequirementsDialog extends StatelessWidget {
  const _RequirementsDialog({required this.vendor, required this.items});

  final LocalCodingVendor vendor;
  final List<LocalCodingRequirements> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSatisfied = items.every((r) => r.satisfied);
    return UiContentDialog(
      size: UiDialogSize.standard,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: '系统要求 · ${localCodingVendorName(vendor)}',
              subtitle: '本机是否满足下载安装条件',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < items.length; i++) ...[
              Text(
                items[i].target.isDesktop ? '桌面端' : '命令行',
                style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              _reqRow('目标版本', items[i].version),
              _reqRow('平台 / 架构', '${items[i].platform} · ${items[i].arch}'),
              _reqRow('最低系统版本', _minOsLabel(items[i])),
              _reqRow('下载大小', _bytes(items[i].downloadSizeBytes)),
              _reqRow(
                  '可用磁盘',
                  items[i].availableFreeBytes == null
                      ? '未探测'
                      : _bytes(items[i].availableFreeBytes!)),
              _reqRow('下载主机', items[i].downloadHost),
              _reqRow('安装位置', _locationLabel(items[i].installLocationKind)),
              if (items[i].issues.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('待处理项',
                          style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                      const SizedBox(height: 6),
                      for (final issue in items[i].issues)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('· ${_issueText(issue)}',
                              style: const TextStyle(
                                  color: Color(0xFF92400E), fontSize: 13)),
                        ),
                    ],
                  ),
                ),
              ],
              if (i != items.length - 1) ...[
                const SizedBox(height: 12),
                Divider(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                    height: 1),
                const SizedBox(height: 12),
              ],
            ],
            const SizedBox(height: 12),
            if (allSatisfied)
              Text(
                '本机满足下载安装条件。',
                style: TextStyle(color: scheme.primary, fontSize: 13),
              ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reqRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style:
                      const TextStyle(color: Color(0xFF667085), fontSize: 13)),
            ),
            Expanded(
              child: Text(value,
                  style:
                      const TextStyle(color: Color(0xFF101828), fontSize: 13)),
            ),
          ],
        ),
      );

  /// The Bridge reports `min_os` in its own platform's version format
  /// ("11.0" on macOS, "10.0.17763" on Windows); show the name users know.
  static String _minOsLabel(LocalCodingRequirements req) {
    final current = req.osVersion.isEmpty ? '' : '（当前 ${req.osVersion}）';
    if (req.platform == 'windows') {
      return 'Windows 10 1809 及以上$current';
    }
    return 'macOS ${req.minOs}$current';
  }

  static String _locationLabel(String kind) {
    switch (kind) {
      case 'applications':
        return '「应用程序」文件夹（/Applications）';
      case 'user_applications':
        return '用户「应用程序」文件夹（~/Applications）';
      case 'user_local_bin':
        return '用户目录（~/.local/bin）';
      case 'windows_apps':
        return '系统应用目录（由 Windows 注册安装）';
      case 'claude_desktop_support':
        return 'Claude 桌面端数据目录';
      default:
        return kind.isEmpty ? '用户目录' : kind;
    }
  }

  static String _issueText(String code) {
    switch (code) {
      case 'UNSUPPORTED_OS':
        return '系统版本过低，请升级系统后重试';
      case 'UNSUPPORTED_ARCH':
        return '当前架构暂不支持一键安装';
      case 'INSUFFICIENT_DISK':
        return '磁盘空间不足';
      case 'TARGET_DIR_NOT_WRITABLE':
        return '目标目录不可写';
      case 'TARGET_CONFLICT':
        return '目标位置已有其他文件';
      case 'TARGET_IN_USE':
        return '目标应用正在运行，请先退出';
      case 'ADMIN_REQUIRED':
        // Windows：该应用注册需要管理员权限，标准账号无法自行完成。
        return '需要管理员账号才能安装，请联系管理员';
      default:
        return code;
    }
  }
}

/// 诊断详情。失败现场可一键交给支持：本地环境千差万别，失败又常发生在第三方 CLI
/// 里，只靠用户截图或复述定位不了（2026-09-16 两位测试用户的问题都是远程登机器才
/// 查清的）。上报成功只告诉用户"已记录、支持会联系"：编号对用户没有意义，他也不
/// 知道去哪儿联系（2026-09-17 产品拍板）；支持侧在 Admin「问题反馈」按账号与时间定位。
class _DiagnosticsDialog extends ConsumerStatefulWidget {
  const _DiagnosticsDialog({required this.diagnostics});

  final LocalCodingDiagnostics diagnostics;
  static const String title = '诊断详情';

  @override
  ConsumerState<_DiagnosticsDialog> createState() => _DiagnosticsDialogState();
}

class _DiagnosticsDialogState extends ConsumerState<_DiagnosticsDialog> {
  bool _sending = false;
  String _reference = '';

  LocalCodingDiagnostics get diagnostics => widget.diagnostics;

  Future<void> _send() async {
    setState(() => _sending = true);
    final reference = await ref
        .read(localCodingToolsProvider.notifier)
        .reportDiagnostics(diagnostics.target);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _reference = reference ?? '';
    });
    if (reference == null) {
      BotToast.showText(text: '发送失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      size: UiDialogSize.compact,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: _DiagnosticsDialog.title,
              subtitle: diagnostics.isEmpty
                  ? '当前会话尚无失败记录'
                  : '${localCodingTargetName(diagnostics.target)} · 最近一次问题记录',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
            if (!diagnostics.isEmpty) ...[
              _dgRow(
                  '阶段',
                  diagnostics.stage == 'app'
                      ? '知办本地校验 · ${_appKindLabel(diagnostics.kind)}'
                      : '${diagnostics.kind.isEmpty ? '-' : diagnostics.kind} / ${diagnostics.stage.isEmpty ? '-' : diagnostics.stage}'),
              _dgRow('错误码', diagnostics.errorCode),
              if (diagnostics.errorDetail.isNotEmpty)
                _dgRow(localCodingErrorDetailLabel(diagnostics.errorDetail),
                    diagnostics.errorDetail,
                    selectable: true),
              _dgRow(
                  '发生时间',
                  diagnostics.occurredAt.isEmpty
                      ? '-'
                      : diagnostics.occurredAt),
              const SizedBox(height: 12),
            ],
            if (diagnostics.suggestions.isNotEmpty) ...[
              const Text('建议',
                  style: TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              for (final s in diagnostics.suggestions)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('· $s',
                      style: const TextStyle(
                          color: Color(0xFF101828), fontSize: 13)),
                ),
            ],
            if (_reference.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                '问题已记录，支持人员会尽快联系你。',
                style: TextStyle(color: Color(0xFF101828), fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_reference.isEmpty)
                  TextButton(
                    onPressed: _sending ? null : _send,
                    child: Text(_sending ? '发送中…' : '发送给支持'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _appKindLabel(String kind) {
    switch (kind) {
      case 'app.install':
        return '下载安装';
      case 'app.switchToZhiban':
        return '切换为自定义模型 API';
      case 'app.repairSwitch':
        return '修复并重试';
      case 'app.connect':
        return '一键配置工具';
      case 'app.verify':
        return '检测服务连接';
      default:
        return kind;
    }
  }

  Widget _dgRow(String label, String value, {bool selectable = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(label,
                  style:
                      const TextStyle(color: Color(0xFF667085), fontSize: 13)),
            ),
            Expanded(
              // 中转站原话可以选中复制,方便发给支持。
              child: selectable
                  ? SelectableText(value,
                      style: const TextStyle(
                          color: Color(0xFF101828), fontSize: 13, height: 1.5))
                  : Text(value,
                      style: const TextStyle(
                          color: Color(0xFF101828), fontSize: 13)),
            ),
          ],
        ),
      );
}

/// 页面顶部的浮动通知(2026-09-15,用户在浏览器对比四种形式后选定"顶部浮动通知"):
/// 从页面顶部淡入并轻微下滑,浮在内容上方、不推动卡片;成功 3 秒、需要注意 5 秒后
/// 自动淡出,鼠标移上去暂停,可点 × 立刻关;新提示替换旧提示。
///
/// 全量检测(首次进入 / 重新检测)期间这里显示总进度,滚到哪张卡都看得到;检测结束
/// 原地换成结果:有检测结果提示(验证服务连接成功 / 失败)就显示它,否则显示
/// "检测完成",同样 3 秒后淡出(2026-09-15 用户反馈)。
class _ResultToast extends ConsumerStatefulWidget {
  const _ResultToast();

  @override
  ConsumerState<_ResultToast> createState() => _ResultToastState();
}

class _ResultToastState extends ConsumerState<_ResultToast> {
  static const Duration _fade = Duration(milliseconds: 220);

  LocalCodingPageBanner? _banner;
  bool _visible = false;
  Timer? _timer;
  final Stopwatch _elapsed = Stopwatch();
  Duration _remaining = Duration.zero;

  /// 检测进行中(或刚结束、还没决定显示什么)时到达的提示,检测结束后再显示。
  LocalCodingPageBanner? _pending;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // 离开页面期间后台操作留下的提示,回到页面时补显示一次。
    final initial = ref.read(localCodingToolsProvider).value?.banner;
    if (initial != null) {
      if (_inspectingNow()) {
        _pending = initial;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _show(initial);
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static Duration _lifetime(LocalCodingPageBanner banner) =>
      banner.kind == LocalCodingPageBannerKind.needsAttention
          ? const Duration(seconds: 5)
          : const Duration(seconds: 3);

  void _show(LocalCodingPageBanner banner) {
    setState(() {
      _banner = banner;
      _visible = true;
    });
    _start(_lifetime(banner));
  }

  void _start(Duration duration) {
    _timer?.cancel();
    _remaining = duration;
    _elapsed
      ..reset()
      ..start();
    _timer = Timer(duration, _hide);
  }

  void _pause() {
    if (!_visible || _timer == null) return;
    _timer!.cancel();
    _timer = null;
    _elapsed.stop();
    _remaining -= _elapsed.elapsed;
  }

  void _resume() {
    if (!_visible || _timer != null) return;
    const minimum = Duration(milliseconds: 800);
    _start(_remaining < minimum ? minimum : _remaining);
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    final banner = _banner;
    setState(() => _visible = false);
    // 淡出后清掉页面状态里的这条提示;期间来了新提示(_show 会取消这个计时)则不动。
    _timer = Timer(_fade, () {
      _timer = null;
      if (!mounted) return;
      setState(() => _banner = null);
      _dismissFromPage(banner);
    });
  }

  void _dismissFromPage(LocalCodingPageBanner? banner) {
    final current = ref.read(localCodingToolsProvider).value?.banner;
    if (banner != null && identical(current, banner)) {
      ref.read(localCodingToolsProvider.notifier).dismissBanner();
    }
  }

  /// 正在全量检测:有检测进度,或首次载入(重新载入)还没有数据。
  bool _inspectingNow() {
    final tools = ref.read(localCodingToolsProvider);
    return ref.read(localCodingInspectProgressProvider) != null ||
        (!tools.hasValue && !tools.hasError);
  }

  /// 检测开始:正在显示的旧提示让位给进度。
  void _startInspection() {
    _timer?.cancel();
    _timer = null;
    final banner = _banner;
    _banner = null;
    _visible = false;
    _dismissFromPage(banner);
  }

  /// 检测结束:等这一帧把检测结果(提示 / 整页失败)写进页面状态后再决定显示什么。
  void _finishInspection() {
    if (_finishing) return;
    _finishing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _finishing = false;
      // 还在检测(进度清掉了但数据还没到):等数据到了再结束。
      if (!mounted || _inspectingNow()) return;
      final pending = _pending;
      _pending = null;
      // 整页检测失败由错误页说明,不报"检测完成"。
      if (ref.read(localCodingToolsProvider).hasError) {
        if (pending != null) _show(pending);
        return;
      }
      _show(pending ??
          const LocalCodingPageBanner(
            kind: LocalCodingPageBannerKind.repairComplete,
            text: '',
            title: localCodingInspectDoneTitle,
          ));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<LocalCodingInspectProgress?>(
      localCodingInspectProgressProvider,
      (previous, next) {
        if (previous == null && next != null) {
          _startInspection();
        } else if (previous != null && next == null) {
          _finishInspection();
        }
      },
    );
    // 首次载入 / 重新载入:检测进度上报前后都没有数据,数据到了也算检测结束。
    ref.listen<bool>(
      localCodingToolsProvider
          .select((state) => !state.hasValue && !state.hasError),
      (previous, next) {
        if (previous == true && !next) _finishInspection();
      },
    );
    ref.listen<LocalCodingPageBanner?>(
      localCodingToolsProvider.select((state) => state.value?.banner),
      (previous, next) {
        if (next == null || identical(next, _banner)) return;
        if (_finishing || _inspectingNow()) {
          _pending = next;
          return;
        }
        _show(next);
      },
    );
    final loading = ref.watch(localCodingToolsProvider
        .select((state) => !state.hasValue && !state.hasError));
    final progress = ref.watch(localCodingInspectProgressProvider) ??
        (loading ? LocalCodingInspectProgress.starting() : null);
    if (progress != null) return _InspectProgressNotice(progress: progress);
    final banner = _banner;
    if (banner == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final attention = banner.kind == LocalCodingPageBannerKind.needsAttention;
    final title = banner.title;
    final text = banner.text;
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: _fade,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : const Offset(0, -0.25),
          duration: _fade,
          curve: Curves.easeOut,
          child: MouseRegion(
            onEnter: (_) => _pause(),
            onExit: (_) => _resume(),
            child: _FloatingNoticeShell(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      attention
                          ? CupertinoIcons.exclamationmark_circle_fill
                          : CupertinoIcons.checkmark_alt_circle_fill,
                      size: 18,
                      color: attention
                          ? const Color(0xFFD97706)
                          : _dotColor(_DotColor.success, scheme),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title.isNotEmpty)
                            Text(
                              title,
                              style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.45),
                            ),
                          if (text.isNotEmpty)
                            Text(
                              text,
                              style: TextStyle(
                                  color: title.isEmpty
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                  fontSize: title.isEmpty ? 13.5 : 13,
                                  height: 1.45),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    icon: Icon(CupertinoIcons.xmark,
                        color: scheme.onSurfaceVariant),
                    onPressed: _hide,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动通知的外壳:浅色主题悬浮阴影,深色主题描边。
class _FloatingNoticeShell extends StatelessWidget {
  const _FloatingNoticeShell({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: padding,
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerHigh : scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: dark
            ? Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5))
            : null,
        boxShadow: dark
            ? null
            : const [
                BoxShadow(
                    color: Color(0x240F172A),
                    offset: Offset(0, 10),
                    blurRadius: 30),
                BoxShadow(
                    color: Color(0x0F0F172A),
                    offset: Offset(0, 2),
                    blurRadius: 6),
              ],
      ),
      child: child,
    );
  }
}

/// 检测中的浮动进度:总进度文字 + 细进度条。
class _InspectProgressNotice extends StatelessWidget {
  const _InspectProgressNotice({required this.progress});

  final LocalCodingInspectProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style =
        TextStyle(color: scheme.onSurface, fontSize: 13.5, height: 1.45);
    final total = progress.steps.length;
    final current = progress.current;
    // 最后的网络与代理检查虽然挂在 Codex 卡下,两个工具都用得上(Claude 桌面端
    // 取模型列表也受系统代理影响);Claude 查完后再冒出"Codex …"像是倒回去了。
    final named = current?.vendor != null &&
        current?.kind != LocalCodingInspectStepKind.network;
    final step = current == null
        ? '$total/$total'
        : '${named ? '${localCodingVendorName(current.vendor!)} ' : ''}'
            '${current.label} ${progress.completed + 1}/$total';
    return _FloatingNoticeShell(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CupertinoActivityIndicator(radius: 7),
                const SizedBox(width: 10),
                Text('正在检测', style: style),
                Flexible(
                  child: Text(
                    '  ·  $step',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: total == 0 ? 0 : progress.completed / total),
                duration: const Duration(milliseconds: 250),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 3,
                  color: scheme.primary,
                  backgroundColor: scheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.exclamationmark_triangle_fill,
                  size: 32, color: scheme.error),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                        height: 1.5,
                      )),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(CupertinoIcons.refresh, size: 16),
                label: const Text('重新检测'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnsupportedReasonDialog extends StatelessWidget {
  const _UnsupportedReasonDialog({
    required this.rawCode,
    required this.reasonCode,
    required this.subject,
    required this.openLabel,
  });

  final String rawCode;
  final String reasonCode;
  final String subject;
  final String openLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final explanation = _explanationFor(reasonCode, openLabel);
    return UiContentDialog(
      size: UiDialogSize.compact,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: '查看原因',
              subtitle: reasonCode == 'DETECT-RESULT_UNREADABLE'
                  ? '$subject 检测异常'
                  : '$subject 当前的安装暂不支持知办接入',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
            Text(
              explanation,
              style: TextStyle(
                  color: scheme.onSurface, fontSize: 14, height: 1.55),
            ),
            if (rawCode.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('错误码：$rawCode',
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _explanationFor(String code, String openLabel) {
    switch (code) {
      case 'DETECT-UNTRUSTED_PATH':
        return '知办只接入来自官方发布渠道的安装。当前安装所在位置或签名无法通过来源校验，为了不覆盖你可能自行编译或替换过的程序，知办不做任何改动。';
      case 'DETECT-VERSION_UNKNOWN':
        return '知办无法识别当前工具的版本号（可能是未发行版本、被裁剪或本地改造过）。为避免推送不兼容的配置，知办不做任何改动。';
      case 'DETECT-DAMAGED':
        return '当前安装的签名校验未通过（文件可能损坏或被改动）。可以点击「修复并重试」按锁定版本重新安装。';
      case 'DETECT-LAYOUT_INCOMPLETE':
        return '当前安装缺少官方安装包里的配套组件（Codex 的 Code Mode 运行组件），每次启动都会提示 Code Mode 不可用。可以点击「修复并重试」按官方完整安装包重新安装。';
      case 'DETECT-RESULT_UNREADABLE':
        return '知办没能读懂本地连接组件返回的检测结果，通常是知办与本地连接组件版本不一致。为避免误操作，这一项暂不提供打开、切换和升级；不影响你在终端或应用里照常使用。可以重新检测，或把知办更新到最新版本后再试。';
      case 'CONFIG-POLICY_CONFLICT':
        return '你所在的组织已通过 Claude Code 的 managed-settings 固定了网关或凭据设置。知办不会绕过企业策略；如需通过知办使用，请联系管理员。此期间你仍然可以通过「$openLabel」以官方设置继续使用。';
      default:
        return '当前安装的来源或版本未通过兼容检查。不影响你在终端或应用里照常使用；也可以重新检测。';
    }
  }
}

String _relativeTime(DateTime instant) {
  final delta = DateTime.now().difference(instant);
  if (delta.inSeconds < 60) return '刚刚';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
  if (delta.inHours < 24) return '${delta.inHours} 小时前';
  return '${delta.inDays} 天前';
}

String _bytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String _userMessage(Object error) {
  if (error is LocalCodingToolsException) return error.userMessage;
  // Bridge 自己的原因(超时 / 退出 / 数据不兼容…)直接给用户看,不再统一成"检测失败"。
  if (error is LocalCodingBridgeException) return error.userMessage;
  return '检测失败，请重试';
}
