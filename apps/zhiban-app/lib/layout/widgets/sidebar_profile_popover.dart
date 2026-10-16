// 桌面端侧栏两个弹框 (docs/contracts/agent-bus-client-contract.md §11.6)。
//
// 1. 左上角头像弹框 (showSidebarProfilePopover, 向下展开, 结构对齐飞书):
//    身份区(头像+成员名+编辑笔+当前企业, 点击弹个人名片卡片) → 帮助与客服(知办客服会话) /
//    本地开发工具(F31, 仅 macOS / Windows 且构建开关开启, 2026-09-10 从设置页提到这一级) /
//    设置 / 退出登录 → 管理后台(独立分组, 外链, **当前所在租户** scope.isAdmin 且
//    adminWebUrl 非空——不能用"这个账号在任意租户是不是管理员", 那样会把 A 租户的
//    管理员身份带进只是普通成员的 B 租户, 见 2026-08-24 修复)。
// 2. 底部「我的企业」弹框 (showSidebarCompanyPopover, 向上展开):
//    企业列表, 当前企业 (JWT act_tid) 打勾, 点击其他企业切换 —
//    复用登录选租户同一条链路: switchToTenantApi → enterHomeAfterLogin(resetScope: true)。
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/im/wukong/wukong_session_identity.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/chat/widgets/contact_profile_card.dart';
import 'package:zhiban_client/pages/login/login_navigation.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';
import 'package:zhiban_client/services/logout_flow.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_client/widgets/ui/desktop_update_check_feedback.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';

const double _popoverWidth = 292;

enum _PopoverDirection { below, above }

/// 在锚点上方/下方弹出侧栏弹框，位置贴锚点、水平不出屏。
Future<void> _showAnchoredPopover(
  BuildContext anchorContext, {
  required _PopoverDirection direction,
  required Widget child,
  required String barrierLabel,
}) {
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  final overlayBox = Overlay.of(anchorContext, rootOverlay: true)
      .context
      .findRenderObject() as RenderBox?;
  final overlaySize = overlayBox?.size ?? MediaQuery.of(anchorContext).size;
  final anchorTopLeft =
      anchorBox?.localToGlobal(Offset.zero) ?? const Offset(10, 40);
  final anchorHeight = anchorBox?.size.height ?? 0;

  final maxLeft = overlaySize.width - _popoverWidth - 10;
  final left = anchorTopLeft.dx.clamp(10.0, maxLeft < 10 ? 10.0 : maxLeft);

  return showGeneralDialog<void>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.transparent,
    pageBuilder: (ctx, _, __) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => Navigator.of(ctx).pop(),
              child: const SizedBox.expand(),
            ),
          ),
          if (direction == _PopoverDirection.below)
            Positioned(
              left: left.toDouble(),
              top: (anchorTopLeft.dy + anchorHeight + 6)
                  .clamp(10.0, overlaySize.height - 10.0)
                  .toDouble(),
              child: child,
            )
          else
            Positioned(
              left: left.toDouble(),
              bottom: (overlaySize.height - anchorTopLeft.dy + 6)
                  .clamp(10.0, overlaySize.height - 10.0)
                  .toDouble(),
              child: child,
            ),
        ],
      );
    },
  );
}

/// 左上角头像弹框 (向下展开)。
Future<void> showSidebarProfilePopover(
  BuildContext anchorContext, {
  required AccountInfo? info,
}) {
  final container = ProviderScope.containerOf(anchorContext, listen: false);
  final cachedMe = container.read(authMeProvider).value;
  return _showAnchoredPopover(
    anchorContext,
    direction: _PopoverDirection.below,
    barrierLabel: '关闭个人弹框',
    child: SidebarProfilePopover(
      info: info,
      hostContext: anchorContext,
      initialMe: cachedMe,
      loadMe: () => container.read(authMeProvider.future),
    ),
  );
}

/// 底部「我的企业」弹框 (向上展开)。
Future<void> showSidebarCompanyPopover(BuildContext anchorContext) {
  final container = ProviderScope.containerOf(anchorContext, listen: false);
  final cachedMe = container.read(authMeProvider).value;
  return _showAnchoredPopover(
    anchorContext,
    direction: _PopoverDirection.above,
    barrierLabel: '关闭企业弹框',
    child: SidebarCompanyPopover(
      hostContext: anchorContext,
      initialMe: cachedMe,
      loadMe: () => container.read(authMeProvider.future),
    ),
  );
}

// ---------------------------------------------------------------------------
// 头像弹框
// ---------------------------------------------------------------------------

class SidebarProfilePopover extends ConsumerStatefulWidget {
  const SidebarProfilePopover({
    super.key,
    required this.info,
    required this.hostContext,
    this.initialMe,
    @visibleForTesting this.loadMe,
    @visibleForTesting this.loadCurrentTenantId,
    @visibleForTesting this.localCodingToolsAvailable,
  });

  final AccountInfo? info;

  /// F31 · "本地开发工具"行的显隐;null = 按平台与构建开关判定(仅测试覆盖)。
  final bool? localCodingToolsAvailable;

  /// 弹框 pop 之后继续导航/弹 dialog 用的宿主 context (侧栏, 活在 router 之下)。
  final BuildContext hostContext;

  /// 打开弹框时已有的会话数据；有值时首帧直接渲染，不重复请求 `/auth/me`。
  final MeResult? initialMe;

  /// 测试注入点; 默认走 fetchMeApi / JWT act_tid。
  final Future<MeResult> Function()? loadMe;
  final Future<int> Function()? loadCurrentTenantId;

  @override
  ConsumerState<SidebarProfilePopover> createState() =>
      _SidebarProfilePopoverState();
}

class _SidebarProfilePopoverState extends ConsumerState<SidebarProfilePopover> {
  MeResult? _me;
  int _currentTenantId = 0;

  @override
  void initState() {
    super.initState();
    _me = widget.initialMe;
    _load();
  }

  Future<void> _load() async {
    // 两路并行: 当前租户 (JWT act_tid) / scopes。任一失败不阻塞其余。
    final loadCurrentTenantId = widget.loadCurrentTenantId ??
        () async => (await WukongSessionIdentity.current())?.tenantId ?? 0;
    final loadMe = widget.loadMe ?? fetchMeApi;

    loadCurrentTenantId().then((tid) {
      if (mounted && tid > 0) setState(() => _currentTenantId = tid);
    }).catchError((_) {});
    if (_me != null) return;
    try {
      final me = await loadMe();
      if (mounted) setState(() => _me = me);
    } catch (_) {
      // 拉不到 scopes: 管理后台隐藏 (fail-closed), 其余入口可用。
    }
  }

  String get _tenantLine {
    final me = _me;
    if (me != null) {
      for (final s in me.tenantScopes) {
        if (s.tenantId == _currentTenantId && s.tenantName.trim().isNotEmpty) {
          return s.tenantName.trim();
        }
      }
    }
    return widget.info?.tenantName.trim() ?? '';
  }

  /// 管理后台入口只看**当前所在租户**是不是管理员, 不是"这个账号在任意租户是不是
  /// 管理员"——账号在 A 租户是管理员、当前正在 B 租户以普通成员身份查看时, 不该
  /// 在 B 租户的界面上露出管理入口(哪怕点进去 admin-web 会自己再校验一次)。
  bool get _showAdminEntry {
    final me = _me;
    if (me == null) return false;
    if (AppConfig.adminWebUrl().trim().isEmpty) return false;
    for (final s in me.scopes) {
      if (s.tenantId == _currentTenantId) return s.isAdmin;
    }
    return false;
  }

  /// 点击身份区: 弹「个人名片」卡片 (复用聊天联系人名片, 与企业微信一致)。
  /// 弹框保持打开, 名片叠在其右侧出现; 点名片外任意处只关名片, 弹框还在。
  /// 自己的名片不能给自己发消息/打电话, 按钮禁用。
  void _openProfileCard() {
    final info = widget.info;
    // 锚点 = 本弹框卡片右上角 (context 即整个 popover 的 RenderBox)。
    // _ProfileCardRoute 内部是 left = anchor.dx + 10 / top = anchor.dy - 12,
    // 这里回推让名片贴弹框右缘 8px、顶部对齐。
    final popoverBox = context.findRenderObject() as RenderBox?;
    final popoverTopLeft =
        popoverBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final anchor = Offset(
      popoverTopLeft.dx + (popoverBox?.size.width ?? _popoverWidth) - 2,
      popoverTopLeft.dy + 12,
    );
    showChatContactProfileCard(
      context,
      anchor: anchor,
      profile: ChatContactProfile(
        kind: 'human',
        accountUuid: info?.accountNo ?? '',
        displayName: sidebarDisplayName(info),
        avatarUrl: info?.avatar ?? '',
        departmentName: info?.departmentFullName.trim().isNotEmpty == true
            ? info!.departmentFullName
            : (info?.departmentName ?? ''),
        email: info?.email ?? '',
        companyName: _tenantLine,
        isSelf: true,
      ),
    );
  }

  void _openSettings() {
    final host = widget.hostContext;
    Navigator.of(context).pop();
    if (!host.mounted) return;
    host.go(RoutePaths.settings);
  }

  Future<void> _checkForUpdates() async {
    Navigator.of(context).pop();
    if (!PlatformUtils.isDesktop) {
      BotToast.showText(text: '请在设置中检查更新');
      return;
    }
    BotToast.showText(text: '正在检查更新');
    final result = await DesktopUpdateService.checkForUpdates(
      feedUrl: AppUpdateService.appcastUrl(),
    );
    BotToast.showText(text: result.message);
  }

  /// F31 · 本地开发工具入口(2026-09-10 从"设置 → 支持与服务"挪到弹框一级,
  /// 设置页入口已移除)。显隐:桌面端 macOS / Windows + 构建开关。
  bool get _showLocalCodingTools =>
      widget.localCodingToolsAvailable ??
      ((PlatformUtils.isMacOS || PlatformUtils.isWindows) &&
          AppConfig.localCodingToolsEnabled);

  void _openLocalCodingTools() {
    final host = widget.hostContext;
    Navigator.of(context).pop();
    if (!host.mounted) return;
    host.go(RoutePaths.localCodingTools);
  }

  Future<void> _openAdminWeb() async {
    final url = AppConfig.adminWebUrl().trim();
    Navigator.of(context).pop();
    if (url.isEmpty) return;
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) BotToast.showText(text: '打开管理后台失败');
  }

  Future<void> _openHelp() async {
    final host = widget.hostContext;
    final closeLoading = BotToast.showLoading();
    try {
      await openZhibanSupportConversation(ref);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (host.mounted) host.go(RoutePaths.chat);
    } catch (error) {
      BotToast.showText(
        text: error is StateError ? error.message.toString() : '打开知办客服失败',
      );
    } finally {
      closeLoading();
    }
  }

  Future<void> _logout() async {
    final host = widget.hostContext;
    Navigator.of(context).pop();
    if (!host.mounted) return;
    // 沿用设置页同款二次确认, 避免误触清会话。
    final confirmed = await showUiConfirmDialog(
      host,
      title: '退出登录',
      description: '确认退出当前账号吗？',
      confirmLabel: '退出登录',
      cancelLabel: '取消',
      danger: true,
    );
    if (!confirmed || !host.mounted) return;
    await performLogoutToLogin(host);
  }

  @override
  Widget build(BuildContext context) {
    // 结构对齐飞书个人弹框: 身份区 / 帮助与客服·设置·退出登录 / 管理后台(独立分组)。
    return _PopoverCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _IdentityHeader(
            info: widget.info,
            tenantLine: _tenantLine,
            onTap: _openProfileCard,
          ),
          const _PopoverDivider(),
          _ActionRow(
            icon: CupertinoIcons.question_circle,
            label: '帮助与客服',
            onTap: _openHelp,
          ),
          if (_showLocalCodingTools)
            _ActionRow(
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              label: '本地开发工具',
              onTap: _openLocalCodingTools,
            ),
          if (PlatformUtils.isDesktop)
            _ActionRow(
              icon: CupertinoIcons.arrow_clockwise,
              label: '检查更新',
              onTap: _checkForUpdates,
            ),
          _ActionRow(
            icon: CupertinoIcons.gear,
            label: '设置',
            onTap: _openSettings,
          ),
          _ActionRow(
            icon: CupertinoIcons.square_arrow_right,
            label: '退出登录',
            onTap: _logout,
          ),
          if (_showAdminEntry) ...[
            const _PopoverDivider(),
            _ActionRow(
              icon: Icons.admin_panel_settings_outlined,
              label: '管理后台',
              showExternalIcon: true,
              onTap: _openAdminWeb,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 「我的企业」弹框
// ---------------------------------------------------------------------------

class SidebarCompanyPopover extends StatefulWidget {
  const SidebarCompanyPopover({
    super.key,
    required this.hostContext,
    this.initialMe,
    @visibleForTesting this.loadMe,
    @visibleForTesting this.loadCurrentTenantId,
  });

  final BuildContext hostContext;

  /// 打开弹框时已有的会话数据；有值时首帧直接渲染，不重复请求 `/auth/me`。
  final MeResult? initialMe;

  final Future<MeResult> Function()? loadMe;
  final Future<int> Function()? loadCurrentTenantId;

  @override
  State<SidebarCompanyPopover> createState() => _SidebarCompanyPopoverState();
}

class _SidebarCompanyPopoverState extends State<SidebarCompanyPopover> {
  MeResult? _me;
  int _currentTenantId = 0;
  int? _switchingTenantId;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _me = widget.initialMe;
    _load();
  }

  Future<void> _load() async {
    final loadCurrentTenantId = widget.loadCurrentTenantId ??
        () async => (await WukongSessionIdentity.current())?.tenantId ?? 0;
    final loadMe = widget.loadMe ?? fetchMeApi;

    loadCurrentTenantId().then((tid) {
      if (mounted && tid > 0) setState(() => _currentTenantId = tid);
    }).catchError((_) {});
    if (_me != null) return;
    try {
      final me = await loadMe();
      if (mounted) setState(() => _me = me);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _switchTenant(ScopeOption s) async {
    if (_switchingTenantId != null || s.tenantId == _currentTenantId) return;
    setState(() => _switchingTenantId = s.tenantId);
    try {
      await switchToTenantApi(s.tenantId);
      if (!mounted) return;
      final host = widget.hostContext;
      Navigator.of(context).pop();
      if (!host.mounted) return;
      enterHomeAfterLogin(host, resetScope: true);
    } catch (e) {
      BotToast.showText(text: formatError(e));
      if (mounted) setState(() => _switchingTenantId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenantScopes = _me?.tenantScopes ?? const <ScopeOption>[];
    // 紧凑密度 (对齐企业微信): 宽 240、卡片四周 4px、行高 36px;
    // 长企业名 ellipsis 截断, 不靠加宽解决。
    return _PopoverCard(
      width: 240,
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loadFailed)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text(
                '企业列表加载失败，请稍后重试',
                style: TextStyle(fontSize: 12, color: Color(0xFF667085)),
              ),
            )
          else if (_me == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(child: CupertinoActivityIndicator()),
            )
          else
            ...tenantScopes.map(
              (s) => _TenantRow(
                scope: s,
                isCurrent: s.tenantId == _currentTenantId,
                busy: _switchingTenantId == s.tenantId,
                disabled: _switchingTenantId != null &&
                    _switchingTenantId != s.tenantId,
                onTap: () => _switchTenant(s),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 共享搭件
// ---------------------------------------------------------------------------

class _PopoverCard extends StatelessWidget {
  const _PopoverCard({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(8, 12, 8, 8),
    this.width = _popoverWidth,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE4E7EC)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A101828),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _IdentityHeader extends StatefulWidget {
  const _IdentityHeader({
    required this.info,
    required this.tenantLine,
    required this.onTap,
  });

  final AccountInfo? info;
  final String tenantLine;
  final VoidCallback onTap;

  @override
  State<_IdentityHeader> createState() => _IdentityHeaderState();
}

class _IdentityHeaderState extends State<_IdentityHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final name = sidebarDisplayName(widget.info);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF4F6FA) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SidebarUserAvatar(info: widget.info, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF101828),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          CupertinoIcons.pencil,
                          size: 15,
                          color: Color(0xFF98A2B3),
                        ),
                      ],
                    ),
                    if (widget.tenantLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.tenantLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF8C95A6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TenantRow extends StatefulWidget {
  const _TenantRow({
    required this.scope,
    required this.isCurrent,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  final ScopeOption scope;
  final bool isCurrent;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  State<_TenantRow> createState() => _TenantRowState();
}

class _TenantRowState extends State<_TenantRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.scope;
    final tenantName = s.tenantName.trim().isNotEmpty
        ? s.tenantName.trim()
        : (s.tenantSlug.trim().isNotEmpty
            ? s.tenantSlug.trim()
            : '租户 ${s.tenantId}');
    final interactive = !widget.disabled && !widget.busy && !widget.isCurrent;
    // 企业微信式行样式: 圆角方块底的企业图标占位 (当前企业蓝底蓝图标、其余灰底灰图标),
    // 当前企业文字蓝色高亮 + 尾部打勾。
    const brand = Color(0xFF2563EB);
    final fgColor = widget.isCurrent ? brand : const Color(0xFF344054);
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: interactive ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: widget.disabled ? 0.5 : 1.0,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _hovered && interactive
                  ? const Color(0xFFF4F6FA)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? const Color(0xFFEAF2FF)
                        : const Color(0xFFF2F3F5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    CupertinoIcons.building_2_fill,
                    size: 14,
                    color: widget.isCurrent ? brand : const Color(0xFF6B7785),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tenantName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          widget.isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: fgColor,
                    ),
                  ),
                ),
                if (widget.busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CupertinoActivityIndicator(),
                  )
                else if (widget.isCurrent)
                  const Icon(
                    CupertinoIcons.checkmark_alt,
                    size: 16,
                    color: brand,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showExternalIcon = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 外链行 (帮助与客服/管理后台) 尾部的「跳出」图标, 对齐飞书。
  final bool showExternalIcon;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF344054);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF4F6FA) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: color,
                  ),
                ),
              ),
              if (widget.showExternalIcon)
                const Icon(
                  CupertinoIcons.arrow_up_right_square,
                  size: 15,
                  color: Color(0xFF98A2B3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopoverDivider extends StatelessWidget {
  const _PopoverDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Divider(height: 1, thickness: 1, color: Color(0xFFEDF0F4)),
    );
  }
}
