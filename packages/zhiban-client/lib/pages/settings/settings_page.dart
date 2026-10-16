import 'package:zhiban_client/pages/settings/clear_cache_flow.dart';


import 'package:zhiban_client/config/client_assets.dart';
import 'widgets/recharge_widgets.dart';
import 'local_runtime_panel.dart';
import 'dart:async';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';
import 'package:zhiban_client/widgets/ui/desktop_update_check_feedback.dart';
import 'package:zhiban_client/widgets/ui/update_dialog.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_core/models/login_status.dart';
import 'package:zhiban_client/models/recharge_order.dart';
import 'package:zhiban_client/models/wallet_transaction.dart';
import 'package:zhiban_client/pages/chat/providers/chat_input_prefs_provider.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/settings/account_security_page.dart';
import 'package:zhiban_client/pages/settings/widgets/share_invite_dialog.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/env_override_service.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/login_status_api.dart';
import 'package:zhiban_client/services/wallet_api.dart';

import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';
import 'package:zhiban_ui/widgets/ui_switch.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final AccountInfoService _accountInfoService = AccountInfoService();

  Future<void> _clearCache() => confirmClearCache(context, ref);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: SafeArea(
        child: SettingsProfilePanel(
          compact: false,
          accountInfoService: _accountInfoService,
          onClearCache: _clearCache,
          onEditProfile: (context, info, service) => _showEditProfileDialog(
            context,
            info: info,
            service: service
          ),
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '关于我们',
        backgroundColor: ColorConfig.pageBackground,
      ),
      body: const SafeArea(
        child: _AboutPanel(showHeader: false)
      ),
    );
  }
}

/// 切环境：写入环境覆盖项后强制用户重启 App。
///
/// EnvOverrideService 的覆盖值只在 main() 启动时读一次灌进 AppConfig（见
/// env_override_service.dart 顶部注释），仅退出登录不会重新触发这个流程、
/// 新环境不会生效——因此这里不再提"退出登录"这个错误引导，而是直接要求
/// 完全退出并重新打开 App。桌面端 / Android 可以点按钮直接退出进程；iOS
/// 不允许 App 自我退出（Apple 平台规范），只能提示用户手动关闭。
Future<bool> applyEnvSwitch(BuildContext context, AppEnv picked) async {
  final current = AppConfig.env;
  if (picked == current) {
    BotToast.showText(text: '已是当前环境');
    return false;
  }
  await LocalAgentService.instance.beforeIdentityChange(null);
  await EnvOverrideService.save(picked);
  // 立刻同步内存值，不然没有真正杀进程重启前（iOS 无法自杀退出、Android
  // SystemNavigator.pop 也不保证进程立即终止），AppConfig.env 读到的还是切换
  // 前的旧值——"当前环境"文案、选中态都不会变，跟真的没切一样。
  AppConfig.applyEnvOverride(picked);
  if (!context.mounted) return true;
  final canAutoExit = PlatformUtils.isDesktop || PlatformUtils.isAndroid;
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => UiConfirmDialog(
      title: '环境已切换',
      description: '已记录新环境：${picked.displayName}。\n'
          '必须完全退出并重新打开 App 才会在新环境下生效——仅退出登录不会切换环境。'
          '${PlatformUtils.isIOS ? '\n请手动关闭 App 后重新打开。' : ''}',
      confirmLabel: canAutoExit ? '退出 App' : '我知道了',
      showCancelAction: false,
    ),
  );
  if (PlatformUtils.isDesktop) {
    exit(0);
  } else if (PlatformUtils.isAndroid) {
    await SystemNavigator.pop();
  }
  return true;
}

/// PC 端切环境弹框（移动端走 [EnvSwitchPage] 全屏页）。
class _EnvSwitchDialog extends StatelessWidget {
  const _EnvSwitchDialog({required this.current});

  final AppEnv current;

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      size: UiDialogSize.compact,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: ColorConfig.pageBackground,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiSheetHeader(
                  title: '切换环境',
                  subtitle: '当前：${current.displayName}，切换后需手动重启 App。',
                  onClose: () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: 16),
                for (final env in AppEnv.values) ...[
                  _EnvOptionTile(
                    env: env,
                    selected: env == current,
                    onTap: () => Navigator.of(context).pop(env),
                  ),
                  if (env != AppEnv.values.last) const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端切环境全屏页。注册在 [RoutePaths.envSwitch]，从关于页 push 进入。
class EnvSwitchPage extends StatefulWidget {
  const EnvSwitchPage({super.key});

  @override
  State<EnvSwitchPage> createState() => _EnvSwitchPageState();
}

class _EnvSwitchPageState extends State<EnvSwitchPage> {
  Future<void> _pick(AppEnv env) async {
    await applyEnvSwitch(context, env);
    // Android SystemNavigator.pop() 不保证进程立即终止、iOS 干脆没法自杀退出：
    // 只要用户还留在这个页面（没真的重启），就得重新读 AppConfig.env 刷新
    // "当前环境"文案和选中态，否则看起来像是没切成功。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = AppConfig.env;
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '切换环境',
        backgroundColor: ColorConfig.pageBackground,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '当前：${current.displayName}',
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF667085)
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '切换后需手动重启 App 才能彻底生效。',
                style: TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
              ),
              const SizedBox(height: 16),
              for (final env in AppEnv.values) ...[
                _EnvOptionTile(
                  env: env,
                  selected: env == current,
                  onTap: () => _pick(env),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EnvOptionTile extends StatelessWidget {
  const _EnvOptionTile({
    required this.env,
    required this.selected,
    required this.onTap,
  });

  final AppEnv env;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color:
                  selected ? const Color(0xFF2457F5) : const Color(0xFFE4E7EC),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      env.displayName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF162033),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      env.name,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF98A2B3),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  CupertinoIcons.checkmark_alt_circle_fill,
                  color: Color(0xFF2457F5),
                  size: 22,
                )
              else
                const Icon(
                  CupertinoIcons.circle,
                  color: Color(0xFFD0D5DD),
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsProfilePanel extends ConsumerStatefulWidget {
  const SettingsProfilePanel({
    super.key,
    required this.compact,
    required this.accountInfoService,
    required this.onClearCache,
    required this.onEditProfile,
  });

  final bool compact;
  final AccountInfoService accountInfoService;
  final VoidCallback onClearCache;
  final Future<bool?> Function(
    BuildContext context,
    AccountInfo info,
    AccountInfoService service,
  ) onEditProfile;

  @override
  ConsumerState<SettingsProfilePanel> createState() =>
      _SettingsProfilePanelState();
}

class _SettingsProfilePanelState extends ConsumerState<SettingsProfilePanel> {
  bool _uploadingAvatar = false;

  /// 让用户从本地选一张图，上传到 `/account/avatar`，
  /// 成功后 `invalidate(authMeProvider)` 触发本页 + 聊天右侧头像
  /// 一起刷新。失败给个 Toast，不动任何 UI 状态。
  Future<void> _changeAvatar() async {
    if (_uploadingAvatar) return;
    final file = await pickSingleImage();
    if (file == null || file.path.isEmpty) return;

    setState(() => _uploadingAvatar = true);
    try {
      await widget.accountInfoService.uploadAvatar(
        filePath: file.path,
        fileName: file.name,
      );
      ref.invalidate(authMeProvider);
      if (!mounted) return;
      BotToast.showText(text: '头像已更新');
    } catch (error) {
      if (!mounted) return;
      BotToast.showText(text: '更换头像失败：$error');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _editProfile(AccountInfo? info) async {
    if (info == null) {
      BotToast.showText(text: '账号信息加载中，请稍后再试');
      return;
    }
    final saved = await widget.onEditProfile(
      context,
      info,
      widget.accountInfoService,
    );
    if (saved != true || !mounted) return;
    ref.invalidate(authMeProvider);
  }

  Future<void> _openSupportConversation() async {
    final closeLoading = BotToast.showLoading();
    try {
      await openZhibanSupportConversation(ref);
      if (!mounted) return;
      context.go(RoutePaths.chat);
    } catch (error) {
      BotToast.showText(
        text: error is StateError ? error.message.toString() : '打开知办客服失败',
      );
    } finally {
      closeLoading();
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncInfo = ref.watch(accountInfoProvider);
    // asData 只匹配纯 AsyncData 状态；accountInfoProvider 被
    // ref.invalidate(authMeProvider) 触发静默刷新时会短暂进入
    // "loading 但带着上一次数据" 状态，此时 asData 是 null 但 value 仍能
    // 拿到旧数据——用 asData 会导致每次刷新都误判成"没数据"，重新闪一次
    // 整页骨架屏。
    final info = asyncInfo.value;
    // 页面外壳(操作列表)不依赖 info 就能渲染，不整页拦截；只有头像/姓名这一块
    // 真的等数据的时候才单独显示骨架屏（_ProfileBody 内部的 loading 分支）。
    final loading = asyncInfo.isLoading && info == null;
    final compact = widget.compact;
    final content = SizedBox.expand(
      child: Column(
        children: [
          if (!compact) const SizedBox(height: 28),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                0,
                compact ? 16 : 0,
                0,
                compact ? 32 : 18,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 0 : 28
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _ProfileBody(
                        info: info,
                        loadingHero: loading,
                        onClearCache: widget.onClearCache,
                        onEditProfile: () => _editProfile(info),
                        onChangeAvatar: _changeAvatar,
                        onOpenSupport: _openSupportConversation,
                        uploadingAvatar: _uploadingAvatar,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return content;
  }
}

class _ProfileHeroSkeleton extends StatelessWidget {
  const _ProfileHeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        PlatformUtils.isMobile ? 14 : 20,
        PlatformUtils.isMobile ? 14 : 18,
        PlatformUtils.isMobile ? 14 : 20,
        PlatformUtils.isMobile ? 14 : 18,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF4F8FF)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDDE9FF)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identity = Row(
            children: const [
              UiSkeletonBlock(width: 66, height: 66, radius: 22),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UiSkeletonBlock(width: 148, height: 20, radius: 10),
                    SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        UiSkeletonBlock(width: 92, height: 36, radius: 10),
                        UiSkeletonBlock(width: 92, height: 36, radius: 10),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
          return identity;
        },
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({
    required this.info,
    required this.loadingHero,
    required this.onClearCache,
    required this.onEditProfile,
    required this.onChangeAvatar,
    required this.onOpenSupport,
    required this.uploadingAvatar,
  });

  final AccountInfo? info;
  final bool loadingHero;
  final VoidCallback onClearCache;
  final VoidCallback onEditProfile;
  final VoidCallback onChangeAvatar;
  final VoidCallback onOpenSupport;
  final bool uploadingAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideBillingEntry = info?.phone.trim() == '13900000003';
    final accountItems = [
      if (PlatformUtils.isMobile && !hideBillingEntry) ...[
        _ActionItemData(
          icon: CupertinoIcons.creditcard_fill,
          iconColor: const Color(0xFF7C3AED),
          iconBackground: const Color(0xFFF2ECFF),
          title: '套餐与积分',
          subtitle: '查看权益、购买套餐和积分包',
          onTap: () => context.push(RoutePaths.billing),
        ),
      ],
      _ActionItemData(
        icon: CupertinoIcons.person_fill,
        iconColor: const Color(0xFF2F80ED),
        iconBackground: const Color(0xFFEAF3FF),
        title: '基础资料',
        subtitle: '管理个人信息与联系方式',
        onTap: () => PlatformUtils.isMobile
            ? context.push(RoutePaths.profileDetails, extra: info)
            : showProfileDetailsDialog(context, info),
      ),
      _ActionItemData(
        icon: CupertinoIcons.lock_fill,
        iconColor: const Color(0xFF20C769),
        iconBackground: const Color(0xFFE8FAEF),
        title: '登录状态',
        subtitle: '查看设备登录记录与活动状态',
        onTap: () => PlatformUtils.isMobile
            ? context.push(RoutePaths.loginStatus)
            : _showLoginStatusDialog(context),
      ),
      _ActionItemData(
        icon: CupertinoIcons.shield_fill,
        iconColor: const Color(0xFF7C4DFF),
        iconBackground: const Color(0xFFF0EAFE),
        title: '账号安全',
        subtitle: '查看账号保护与认证来源',
        onTap: () => PlatformUtils.isMobile
            ? context.push(RoutePaths.accountSecurity)
            : _showAccountSecurityDialog(context),
      ),
    ];
    final toolItems = <_ActionItemData>[
      _ActionItemData(
        icon: CupertinoIcons.cloud_fill,
        iconColor: const Color(0xFF0EA5E9),
        iconBackground: const Color(0xFFE6F7FF),
        title: '模型服务',
        subtitle: '管理本地模型服务商与 API 密钥',
        onTap: () => context.push(RoutePaths.modelService),
      ),
      if (PlatformUtils.isDesktop)
        _ActionItemData(
          icon: CupertinoIcons.desktopcomputer,
          iconColor: Theme.of(context).colorScheme.primary,
          iconBackground: Theme.of(context).colorScheme.primaryContainer,
          title: '本地运行',
          subtitle: '管理这台电脑上的数字员工运行状态',
          trailing: ListenableBuilder(
              listenable: LocalAgentService.instance,
              builder: (context, _) =>
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    BillingStatusText(
                        text: LocalAgentService.instance.online ? '已就绪' : '未连接',
                        color: LocalAgentService.instance.online
                            ? const Color(0xFF12B76A)
                            : Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 18),
                    const Icon(CupertinoIcons.chevron_right, size: 15),
                  ])),
          onTap: () => showDialog<void>(
              context: context, builder: (_) => const LocalRuntimePanel()),
        ),
    ];
    final chatItems = <_ActionItemData>[
      if (PlatformUtils.isMobile)
        _ActionItemData(
          icon: CupertinoIcons.paperplane_fill,
          iconColor: const Color(0xFF2563EB),
          iconBackground: const Color(0xFFEAF2FF),
          title: '回车键发送消息',
          subtitle: '关闭后回车换行，改用发送按钮发送',
          onTap: () => ref.read(enterToSendProvider.notifier).toggle(),
          trailing: UiSwitch(
            value: ref.watch(enterToSendProvider),
            onChanged: (v) => ref.read(enterToSendProvider.notifier).set(v),
          ),
        ),
    ];
    // F31 · "本地开发工具"入口 2026-09-10 移到头像弹框一级(sidebar_profile_popover),
    // 设置页不再重复放置;路由 /settings/ai-coding-tools 保持不变。
    final supportItems = [
      if (!PlatformUtils.isMobile) ...[
        _ActionItemData(
          icon: CupertinoIcons.paperplane_fill,
          iconColor: const Color(0xFF25D366),
          iconBackground: const Color(0xFFE8FAEF),
          title: '分享给朋友',
          subtitle: '邀请好友使用 知办AI',
          // F29: 桌面弹框（专属邀请码/链接/二维码/海报）；移动端入口在「我的」抽屉，见 mine_drawer.dart。
          onTap: () => showShareInviteDialog(context),
        ),
        _ActionItemData(
          icon: CupertinoIcons.chat_bubble_text_fill,
          iconColor: const Color(0xFF2F80ED),
          iconBackground: const Color(0xFFEAF3FF),
          title: '联系客服',
          subtitle: '反馈问题或获取帮助支持',
          onTap: onOpenSupport,
        ),
      ],
      _ActionItemData(
        icon: CupertinoIcons.trash_fill,
        iconColor: const Color(0xFFE53935),
        iconBackground: const Color(0xFFFFF0EE),
        title: '清除缓存',
        subtitle: '清除本地缓存与环境配置，不影响登录',
        onTap: onClearCache,
      ),
      _ActionItemData(
        icon: CupertinoIcons.info_circle_fill,
        iconColor: const Color(0xFFFF8A3D),
        iconBackground: const Color(0xFFFFF1E8),
        title: '关于我们',
        subtitle: '了解 知办AI 与相关信息',
        onTap: () => _showAboutSheet(context),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        loadingHero
            ? const _ProfileHeroSkeleton()
            : _ProfileHeroCard(
                info: info,
                onEditProfile: onEditProfile,
                onChangeAvatar: onChangeAvatar,
                uploadingAvatar: uploadingAvatar,
              ),
        const SizedBox(height: 16),
        _ActionGroupCard(
          title: '账号与安全',
          icon: CupertinoIcons.hexagon_fill,
          iconColor: const Color(0xFF165DFF),
          items: accountItems,
        ),
        if (toolItems.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ActionGroupCard(
            title: 'AI 与模型',
            icon: CupertinoIcons.sparkles,
            iconColor: const Color(0xFF165DFF),
            items: toolItems,
          ),
        ],
        if (chatItems.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ActionGroupCard(
            title: '聊天设置',
            icon: CupertinoIcons.chat_bubble_2_fill,
            iconColor: const Color(0xFF165DFF),
            items: chatItems,
          ),
        ],
        const SizedBox(height: 16),
        _ActionGroupCard(
          title: '支持与服务',
          icon: CupertinoIcons.headphones,
          iconColor: const Color(0xFF165DFF),
          items: supportItems,
        ),
      ],
    );
  }
}

String _avatarLetter(AccountInfo? info) {
  final raw = _displayName(info);
  if (raw.isEmpty || raw == '未命名用户') return 'U';
  return raw.characters.first.toUpperCase();
}

String _displayName(AccountInfo? info) {
  if (info == null) return '未命名用户';
  if (info.name.isNotEmpty) return info.name;
  if (info.nickname.isNotEmpty) return info.nickname;
  if (info.email.isNotEmpty) return info.email;
  return '未命名用户';
}

class _ProfileHeroCard extends StatelessWidget {
  const _ProfileHeroCard({
    required this.info,
    required this.onEditProfile,
    required this.onChangeAvatar,
    required this.uploadingAvatar,
  });

  final AccountInfo? info;
  final VoidCallback onEditProfile;
  final VoidCallback onChangeAvatar;
  final bool uploadingAvatar;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        PlatformUtils.isMobile ? 14 : 20,
        PlatformUtils.isMobile ? 14 : 18,
        PlatformUtils.isMobile ? 14 : 20,
        PlatformUtils.isMobile ? 14 : 18,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF4F8FF)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFDDE9FF)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF165DFF).withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = !PlatformUtils.isMobile && constraints.maxWidth >= 420;
          final identity = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProfileAvatar(
                info: info,
                uploading: uploadingAvatar,
                onTap: onChangeAvatar,
                size: 74,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Text(
                          _displayName(info),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF101828),
                            height: 1.2,
                          ),
                        ),
                        _Chip.muted(label: _editionLabel(info)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      (info?.email.trim().isNotEmpty == true)
                          ? info!.email.trim()
                          : '未设置邮箱',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF667085),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'UID: ${(info?.accountNo.trim().isNotEmpty == true) ? info!.accountNo.trim() : '-'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF667085),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _OutlinedAction(
                    icon: CupertinoIcons.pencil_outline,
                    label: '编辑资料',
                    primary: true,
                    compact: true,
                    onTap: onEditProfile,
                  ),
                  const SizedBox(height: 10),
                  _OutlinedAction(
                    icon: CupertinoIcons.camera,
                    label: uploadingAvatar ? '上传中…' : '更换头像',
                    compact: true,
                    onTap: uploadingAvatar ? () {} : onChangeAvatar,
                  ),
                ],
              ),
            ],
          );

          if (wide) return identity;
          final email = info?.email.trim() ?? '';
          void openProfileDetails() => PlatformUtils.isMobile
              ? context.push(RoutePaths.profileDetails, extra: info)
              : showProfileDetailsDialog(context, info);
          return GestureDetector(
            onTap: openProfileDetails,
            behavior: HitTestBehavior.opaque,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ProfileAvatar(
                  info: info,
                  uploading: uploadingAvatar,
                  onTap: openProfileDetails,
                  size: 50,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        email.isNotEmpty ? email : '未设置邮箱',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: email.isNotEmpty
                              ? const Color(0xFF101828)
                              : const Color(0xFF98A2B3),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _Chip.muted(label: _editionLabel(info)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: Color(0xFFB0BAC8),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _editionLabel(AccountInfo? info) {
    if (info == null || info.tenantType.isEmpty) return '个人版';
    switch (info.tenantType) {
      case 'enterprise':
      case 'company':
        return '企业版';
      case 'team':
        return '团队版';
      default:
        return '个人版';
    }
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.info,
    required this.uploading,
    required this.onTap,
    this.size = 88,
  });

  final AccountInfo? info;
  final bool uploading;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final url = info?.avatar.trim() ?? '';
    final lower = url.toLowerCase();
    final isServerPlaceholder = lower.contains('/portrait/default/');
    final hasNetworkAvatar =
        url.isNotEmpty && url.startsWith('http') && !isServerPlaceholder;
    return MouseRegion(
      cursor: uploading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: uploading ? null : onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size,
              height: size,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(),
              child: hasNetworkAvatar
                  ? UiNetworkImage(
                      imageUrl: url,
                      cacheKey: stableAvatarCacheKey(url),
                      fit: BoxFit.cover,
                      width: size,
                      height: size,
                      placeholderBuilder: (_, __) => _DefaultUserAvatar(
                        letter: _avatarLetter(info),
                        primary: primary,
                        size: size,
                      ),
                      errorBuilder: (_, __, ___) => _DefaultUserAvatar(
                        letter: _avatarLetter(info),
                        primary: primary,
                        size: size,
                      ),
                    )
                  : _DefaultUserAvatar(
                      letter: _avatarLetter(info),
                      primary: primary,
                      size: size,
                    ),
            ),
            if (uploading)
              Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
                child: const CupertinoActivityIndicator(
                  radius: 11,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 用户没上传头像时的默认预留：内置 3D 卡通用户头像 (`assets/user_icon.png`)。
/// 与聊天气泡左侧 user 头像 (`ChatAvatar` → `_DefaultAvatar`) 的兜底图保持一致。
/// 资源缺失（旧版本 / asset 没打包）时再退回首字母预留，保证不留白。
class _DefaultUserAvatar extends StatelessWidget {
  const _DefaultUserAvatar({
    required this.letter,
    required this.primary,
    this.size = 88,
  });

  final String letter;
  final Color primary;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      package: ClientAssets.packageName,
      'assets/user_icon.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) =>
          _AvatarLetter(letter: letter, primary: primary),
    );
  }
}

class _AvatarLetter extends StatelessWidget {
  const _AvatarLetter({required this.letter, required this.primary});

  final String letter;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: primary,
        ),
      ),
    );
  }
}

class _BasicInfoCard extends StatelessWidget {
  const _BasicInfoCard({required this.info});

  final AccountInfo? info;

  @override
  Widget build(BuildContext context) {
    final department = (info?.departmentFullName.isNotEmpty == true
            ? info!.departmentFullName
            : info?.departmentName) ??
        '';
    final tenant = info?.tenantName ?? '';
    final displayName =
        (info?.name.isNotEmpty == true) ? info!.name : (info?.nickname ?? '');
    return _SectionCard(
      title: '基础资料',
      icon: CupertinoIcons.list_bullet,
      child: Column(
        children: [
          _InfoRow(
            icon: CupertinoIcons.person_crop_circle,
            label: '姓名',
            value: displayName,
            placeholder: '未设置',
          ),
          _InfoRow(
            icon: CupertinoIcons.person,
            label: '账号',
            value: info?.accountNo ?? '',
            copyable: true,
          ),
          _InfoRow(
            icon: CupertinoIcons.mail,
            label: '邮箱',
            value: info?.email ?? '',
            placeholder: '未设置',
            copyable: true,
          ),
          _InfoRow(
            icon: CupertinoIcons.phone,
            label: '手机号',
            value: info?.phone ?? '',
            placeholder: '未设置',
            copyable: true,
          ),
          _InfoRow(
            icon: CupertinoIcons.building_2_fill,
            label: '部门',
            value: department,
            placeholder: '未设置',
          ),
          _InfoRow(
            icon: CupertinoIcons.person_2,
            label: '租户',
            value: tenant,
            placeholder: '个人',
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _AccountStatusCard extends StatelessWidget {
  const _AccountStatusCard({required this.info});

  final AccountInfo? info;

  @override
  Widget build(BuildContext context) {
    final completion = _completion(info);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionCard(
          title: '账户状态',
          icon: CupertinoIcons.shield_lefthalf_fill,
          child: Column(
            children: [
              _StatusRow(
                label: '登录状态',
                trailing: const BillingStatusText(text: '正常', color: Color(0xFF12B76A)),
              ),
              _StatusRow(
                label: '最近登录设备',
                trailing: Text(
                  _platformLabel(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF101828),
                  ),
                ),
              ),
              _StatusRow(
                label: '数据同步',
                trailing: const BillingStatusText(text: '已开启', color: Color(0xFF12B76A)),
              ),
              _StatusRow(
                label: '资料完整度',
                trailing: SizedBox(
                  width: 140,
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: completion / 100,
                            minHeight: 6,
                            backgroundColor: const Color(0xFFEEF2F7),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${completion.toStringAsFixed(0)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF101828),
                        ),
                      ),
                    ],
                  ),
                ),
                isLast: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _completion(AccountInfo? info) {
    if (info == null) return 20;
    var filled = 0;
    var total = 0;
    void check(String value) {
      total++;
      if (value.trim().isNotEmpty) filled++;
    }

    check(info.name);
    check(info.accountNo);
    check(info.employeeId);
    check(
      info.departmentFullName.isNotEmpty
          ? info.departmentFullName
          : info.departmentName,
    );
    check(info.tenantName);
    check(info.welcomeMsg);
    if (total == 0) return 0;
    return (filled / total) * 100;
  }

  String _platformLabel() {
    return PlatformUtils.deviceLabel;
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDEFF3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 14, color: primary),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF101828),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ActionGroupCard extends StatelessWidget {
  const _ActionGroupCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.items,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final List<_ActionItemData> items;

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    return Container(
      width: double.infinity,
      padding: isMobile
          ? const EdgeInsets.fromLTRB(8, 16, 8, 8)
          : const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE6ECF6)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF14213D).withValues(alpha: 0.035),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
            child: Row(
              children: [
                Container(
                  width: isMobile ? 24 : 30,
                  height: isMobile ? 24 : 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(isMobile ? 7 : 10),
                  ),
                  child: Icon(icon, size: isMobile ? 13 : 16, color: iconColor),
                ),
                SizedBox(width: isMobile ? 8 : 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 15,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF172033),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: isMobile ? 10 : 10),
          for (var i = 0; i < items.length; i++)
            _ActionListTile(data: items[i], isLast: i == items.length - 1),
        ],
      ),
    );
  }
}

class _ActionItemData {
  const _ActionItemData({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  // 非空时替换默认的 chevron_right，用于内嵌开关等场景（如「回车键发送消息」）。
  final Widget? trailing;
}

class _ActionListTile extends StatefulWidget {
  const _ActionListTile({required this.data, required this.isLast});

  final _ActionItemData data;
  final bool isLast;

  @override
  State<_ActionListTile> createState() => _ActionListTileState();
}

class _ActionListTileState extends State<_ActionListTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: data.onTap,
        // 设置项 hover 只需即时反馈，使用普通容器可避免不必要的动画过渡。
        child: Builder(
          builder: (context) {
            final isMobile = PlatformUtils.isMobile;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: isMobile
                      ? const EdgeInsets.symmetric(vertical: 10, horizontal: 8)
                      : const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
                  decoration: BoxDecoration(
                    color:
                        _hovered ? const Color(0xFFF8FBFF) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: isMobile ? 34 : 36,
                        height: isMobile ? 34 : 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: data.iconBackground,
                          borderRadius:
                              BorderRadius.circular(isMobile ? 9 : 11),
                        ),
                        child: Icon(
                          data.icon,
                          size: isMobile ? 16 : 18,
                          color: data.iconColor,
                        ),
                      ),
                      SizedBox(width: isMobile ? 12 : 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.3,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF172033),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              data.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: isMobile ? 11 : 11,
                                height: 1.35,
                                color: const Color(0xFF7E8AA0),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: isMobile ? 8 : 10),
                      data.trailing ??
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: isMobile ? 14 : 15,
                            color: const Color(0xFF8B98AA),
                          ),
                    ],
                  ),
                ),
                if (!widget.isLast)
                  const Divider(
                      height: 1, thickness: 0.5, color: Color(0xFFF0F4FA)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.placeholder = '--',
    this.copyable = false,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String placeholder;
  final bool copyable;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final hasValue = value.trim().isNotEmpty;
    final shown = hasValue ? value : placeholder;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 14, color: const Color(0xFF98A2B3)),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                child: Text(
                  label,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  shown,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: hasValue
                        ? const Color(0xFF101828)
                        : const Color(0xFF98A2B3),
                  ),
                ),
              ),
              if (copyable && hasValue)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  splashRadius: 18,
                  onPressed: () => _copy(context, value, label),
                  icon: const Icon(
                    CupertinoIcons.doc_on_doc,
                    size: 14,
                    color: Color(0xFF98A2B3),
                  ),
                  tooltip: '复制',
                ),
            ],
          ),
        ),
        if (!isLast)
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFF1F3F7)),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.trailing,
    this.isLast = false,
  });

  final String label;
  final Widget trailing;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF667085)),
                ),
              ),
              trailing,
            ],
          ),
        ),
        if (!isLast)
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFF1F3F7)),
      ],
    );
  }
}

class _OutlinedAction extends StatelessWidget {
  const _OutlinedAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final tint = primary ? accent : const Color(0xFF475467);
    final border =
        primary ? accent.withValues(alpha: 0.35) : const Color(0xFFE4E7EC);
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: compact ? 13 : 14, color: tint),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: tint,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
            : PlatformUtils.isMobile
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 7)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        minimumSize: PlatformUtils.isMobile ? Size.zero : null,
        tapTargetSize:
            PlatformUtils.isMobile ? MaterialTapTargetSize.shrinkWrap : null,
        textStyle: TextStyle(
          fontSize: compact ? 12 : 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip._({
    required this.label,
    required this.background,
    required this.textColor,
  });

  factory _Chip.muted({required String label}) => _Chip._(
        label: label,
        background: const Color(0xFFF1F4FA),
        textColor: const Color(0xFF475467),
      );

  final String label;
  final Color background;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _RechargeDialog extends StatefulWidget {
  const _RechargeDialog({required this.onSuccess});

  final VoidCallback onSuccess;

  @override
  State<_RechargeDialog> createState() => _RechargeDialogState();
}

class _RechargeDialogState extends State<_RechargeDialog> {
  final WalletService _walletService = WalletService();
  final TextEditingController _amountController = TextEditingController(
    text: '100',
  );
  NativeRechargeOrder? _order;
  RechargePaymentStatus? _status;
  Timer? _pollTimer;
  bool _creating = false;
  bool _querying = false;
  String? _error;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _createOrder() async {
    final amountFen = rechargeYuanToFen(_amountController.text);
    if (amountFen == null) {
      BotToast.showText(text: '请输入不少于 1 元的充值金额');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
      _status = null;
    });
    try {
      final order = await _walletService.createNativeRechargeOrder(
        amountFen: amountFen,
      );
      if (!mounted) return;
      setState(() => _order = order);
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openPaymentUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      BotToast.showText(text: '支付链接无效');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      BotToast.showText(text: '无法自动打开微信，支付链接已复制');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _queryStatus(silent: true);
    });
    _queryStatus(silent: true);
  }

  Future<void> _queryStatus({bool silent = false}) async {
    final order = _order;
    if (order == null || _querying) return;
    setState(() {
      _querying = true;
      if (!silent) _error = null;
    });
    try {
      final status = await _walletService.queryRechargePaymentStatus(
        outTradeNo: order.outTradeNo,
      );
      if (!mounted) return;
      setState(() => _status = status);
      if (status.paymentSuccess) {
        _pollTimer?.cancel();
        widget.onSuccess();
        BotToast.showText(text: '充值已到账');
      }
    } catch (error) {
      if (!mounted) return;
      if (!silent) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  Future<void> _closeOrder() async {
    final order = _order;
    if (order == null || _status?.paymentSuccess == true) {
      Navigator.of(context).pop();
      return;
    }
    try {
      await _walletService.closeRechargeOrder(outTradeNo: order.outTradeNo);
    } catch (_) {
      // 关闭订单失败不阻塞用户关闭弹窗，后端补偿任务仍会兜底同步。
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final amountFen = rechargeYuanToFen(_amountController.text);
    final order = _order;
    final amountText = amountFen == null
        ? _amountController.text
        : rechargeFenToYuanText(amountFen);
    return UiContentDialog(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: kUiDialogMaxWidth, maxHeight: 820),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 26,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 充值弹框头部统一使用 UiSheetHeader，保持标题/关闭按钮交互规范一致。
                UiSheetHeader(
                  title: order == null ? '充值' : '微信扫码支付',
                  subtitle: order == null
                      ? '当前支持微信支付，充值金额实时到账'
                      : '充值 ￥$amountText，支付完成后会自动到账',
                  onClose: _closeOrder,
                ),
                const SizedBox(height: 18),
                if (order == null) ...[
                  RechargeAmountCard(
                    controller: _amountController,
                    enabled: !_creating,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  const RechargePayMethodCard(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFD92D20),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed:
                        _creating || amountFen == null ? null : _createOrder,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF165DFF),
                      disabledBackgroundColor: const Color(0xFFE4E7EC),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: const Color(0xFF98A2B3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    child: Text(
                      _creating
                          ? '创建订单中...'
                          : amountFen == null
                              ? '请输入充值金额'
                              : '确认充值 ￥${rechargeFenToYuanText(amountFen)}',
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '最低充值 1 元，支付完成后请等待到账状态刷新',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
                  ),
                ] else ...[
                  _RechargePaymentPanel(
                    order: order,
                    amountText: amountText,
                    status: _status,
                    querying: _querying,
                    error: _error,
                    onOpen: () => _openPaymentUrl(order.codeUrl),
                    onQuery: () => _queryStatus(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RechargePaymentPanel extends StatelessWidget {
  const _RechargePaymentPanel({
    required this.order,
    required this.amountText,
    required this.status,
    required this.querying,
    required this.error,
    required this.onOpen,
    required this.onQuery,
  });

  final NativeRechargeOrder order;
  final String amountText;
  final RechargePaymentStatus? status;
  final bool querying;
  final String? error;
  final VoidCallback onOpen;
  final VoidCallback onQuery;

  @override
  Widget build(BuildContext context) {
    final success = status?.paymentSuccess == true;
    final statusText = success
        ? '已到账'
        : status?.paymentSuccessDesc.isNotEmpty == true
            ? status!.paymentSuccessDesc
            : '等待微信支付';
    final color = success ? const Color(0xFF12B76A) : const Color(0xFF667085);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE9EEF7)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '￥$amountText',
            style: const TextStyle(
              fontSize: 34,
              height: 1,
              fontWeight: FontWeight.w900,
              color: Color(0xFF165DFF),
            ),
          ),
          const SizedBox(height: 10),
          BillingStatusText(text: statusText, color: color),
          const SizedBox(height: 22),
          Container(
            width: 244,
            height: 244,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE4E7EC)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF14213D).withValues(alpha: 0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                QrImageView(
                  data: order.codeUrl,
                  version: QrVersions.auto,
                  gapless: false,
                  backgroundColor: Colors.white,
                ),
                if (success)
                  Container(
                    width: double.infinity,
                    height: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      size: 58,
                      color: Color(0xFF12B76A),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '打开手机微信扫一扫，完成支付后页面会自动刷新到账状态',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Color(0xFF667085),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFD92D20)),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: success ? null : onOpen,
                  icon: const Icon(CupertinoIcons.arrow_up_right_square),
                  label: const Text('打开微信支付'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF165DFF),
                    side: const BorderSide(color: Color(0xFFBBD2FF)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: success || querying ? null : onQuery,
                  icon: querying
                      ? const CupertinoActivityIndicator(radius: 7)
                      : const Icon(CupertinoIcons.refresh),
                  label: Text(querying ? '查询中' : '我已完成支付'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF475467),
                    side: const BorderSide(color: Color(0xFFE4E7EC)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  order.outTradeNo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF98A2B3),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                splashRadius: 18,
                onPressed: () => _copy(context, order.codeUrl, '支付链接'),
                icon: const Icon(
                  CupertinoIcons.doc_on_doc,
                  size: 15,
                  color: Color(0xFF98A2B3),
                ),
                tooltip: '复制支付链接',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WalletTransactionsDialog extends StatefulWidget {
  const _WalletTransactionsDialog();

  @override
  State<_WalletTransactionsDialog> createState() =>
      _WalletTransactionsDialogState();
}

class _WalletTransactionsDialogState extends State<_WalletTransactionsDialog> {
  static const _pageSize = 30;

  final WalletService _walletService = WalletService();
  final List<WalletTransactionItem> _items = [];
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _page = 1;
        _total = 0;
        _items.clear();
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || !_canLoadMore) return;
      setState(() {
        _loadingMore = true;
        _error = null;
      });
    }

    try {
      final nextPage = reset ? 1 : _page + 1;
      final result = await _walletService.fetchTransactions(
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _page = nextPage;
        _total = result.total;
        _items.addAll(result.items);
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool get _canLoadMore => _items.length < _total;

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: kUiDialogMaxWidth, maxHeight: 720),
        child: Container(
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 26,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
                child: Row(
                  children: [
                    const Expanded(
                      child: UiSheetHeader(
                        title: '账单明细',
                        subtitle: '按业务发生时间倒序展示最近账单',
                        onClose: null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 头部操作统一使用 UiIconButton，和其它弹框保持一致的尺寸与交互规范。
                    UiIconButton(
                      icon: CupertinoIcons.refresh,
                      tooltip: '刷新',
                      onTap: () => _load(reset: true),
                    ),
                    const SizedBox(width: 4),
                    UiIconButton(
                      icon: CupertinoIcons.xmark,
                      tooltip: '关闭',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: _buildContent(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 13));
    }

    if (_error != null && _items.isEmpty) {
      return _WalletStateMessage(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: '账单加载失败',
        subtitle: _error!,
        actionLabel: '重新加载',
        onAction: () => _load(reset: true),
      );
    }

    if (_items.isEmpty) {
      return const _WalletStateMessage(
        icon: CupertinoIcons.doc_text,
        title: '暂无账单记录',
        subtitle: '产生充值或消费后，账单会在这里展示',
      );
    }

    final children = <Widget>[];
    String? currentDate;
    for (final item in _items) {
      final date = _formatBillDate(item.displayTime);
      if (date != currentDate) {
        currentDate = date;
        children.add(_BillDateHeader(label: date));
      }
      children.add(_BillTransactionTile(item: item));
    }
    if (_error != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '加载更多失败：$_error',
            style: const TextStyle(fontSize: 12, color: Color(0xFFD92D20)),
          ),
        ),
      );
    }
    if (_canLoadMore) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Center(
            child: OutlinedButton(
              onPressed: _loadingMore ? null : () => _load(reset: false),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF165DFF),
                side: const BorderSide(color: Color(0xFFBBD2FF)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 11,
                ),
              ),
              child: Text(_loadingMore ? '加载中...' : '加载更多'),
            ),
          ),
        ),
      );
    }

    return ListView(padding: EdgeInsets.zero, children: children);
  }
}

class _BillDateHeader extends StatelessWidget {
  const _BillDateHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Color(0xFF98A2B3),
        ),
      ),
    );
  }
}

class _BillTransactionTile extends StatefulWidget {
  const _BillTransactionTile({required this.item});

  final WalletTransactionItem item;

  @override
  State<_BillTransactionTile> createState() => _BillTransactionTileState();
}

class _BillTransactionTileState extends State<_BillTransactionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final color =
        item.isCredit ? const Color(0xFF12B76A) : const Color(0xFFD75A4A);
    final icon = item.isCredit ? CupertinoIcons.plus : CupertinoIcons.minus;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showWalletTransactionDetail(context, item),
        // 账单行 hover 样式改为无动画切换，统一交互反馈。
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFFBFDFF) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  _hovered ? const Color(0xFFCFE0FF) : const Color(0xFFE9EEF7),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF14213D).withValues(alpha: 0.035),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF172033),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${item.reasonLabel} · ${_formatBillTime(item.displayTime)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF98A2B3),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                item.signedAmountLabel,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletStateMessage extends StatelessWidget {
  const _WalletStateMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE9EEF7)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: const Color(0xFF98A2B3)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF172033),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Color(0xFF98A2B3),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF165DFF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransactionDetailRow extends StatelessWidget {
  const _TransactionDetailRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final shown = value.trim().isEmpty ? '--' : value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 78,
                child: Text(
                  label,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shown,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF172033),
                  ),
                ),
              ),
              if (copyable && value.trim().isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  splashRadius: 18,
                  onPressed: () => _copy(context, value, label),
                  icon: const Icon(
                    CupertinoIcons.doc_on_doc,
                    size: 14,
                    color: Color(0xFF98A2B3),
                  ),
                  tooltip: '复制',
                ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 0.5, color: Color(0xFFF1F3F7)),
      ],
    );
  }
}

void _copy(BuildContext context, String value, String label) async {
  final v = value.trim();
  if (v.isEmpty) {
    BotToast.showText(text: '没有可复制的$label');
    return;
  }
  await Clipboard.setData(ClipboardData(text: v));
  BotToast.showText(text: '已复制$label');
}

Future<bool?> _showEditProfileDialog(
  BuildContext context, {
  required AccountInfo info,
  required AccountInfoService service,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _EditProfileDialog(info: info, service: service),
  );
}

/// 桌面端「基础资料」dialog。settings 页与侧栏头像弹框
/// (layout/widgets/sidebar_profile_popover.dart) 共用。
void showProfileDetailsDialog(BuildContext context, AccountInfo? info) {
  showDialog<void>(
    context: context,
    builder: (context) => UiContentDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kUiDialogMaxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
                child: UiSheetHeader(
                  title: '基础资料',
                  subtitle: '查看账号、联系方式与组织信息',
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _BasicInfoCard(info: info),
                      const SizedBox(height: 16),
                      _AccountStatusCard(info: info),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showAccountSecurityDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => UiContentDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kUiDialogMaxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
                child: UiSheetHeader(
                  title: '账号安全',
                  subtitle: '查看账号保护与认证来源',
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 18, 22, 22),
                child: AccountSecurityBody(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showLoginStatusDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => const _LoginStatusDialog(),
  );
}

class _LoginStatusDialog extends StatefulWidget {
  const _LoginStatusDialog();

  @override
  State<_LoginStatusDialog> createState() => _LoginStatusDialogState();
}

class _LoginStatusDialogState extends State<_LoginStatusDialog> {
  late Future<LoginStatus> _future;

  @override
  void initState() {
    super.initState();
    _future = LoginStatusService().fetchLoginStatus();
  }

  void _reload() {
    setState(() {
      _future = LoginStatusService().fetchLoginStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: kUiDialogMaxWidth, maxHeight: 720),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: UiSheetHeader(
                      title: '登录状态',
                      subtitle: '查看当前设备与登录设备',
                      onClose: null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 右侧操作统一使用 UiIconButton，保证尺寸、hover 与提示交互一致。
                  UiIconButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: '刷新',
                    onTap: _reload,
                  ),
                  const SizedBox(width: 4),
                  UiIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: '关闭',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: FutureBuilder<LoginStatus>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CupertinoActivityIndicator(radius: 12),
                      );
                    }
                    if (snapshot.hasError) {
                      return _EmptyState(
                        icon: CupertinoIcons.exclamationmark_triangle,
                        title: '登录状态加载失败',
                        subtitle: '${snapshot.error}',
                        actionLabel: '重新加载',
                        onAction: _reload,
                      );
                    }
                    final status = snapshot.data;
                    if (status == null) {
                      return _EmptyState(
                        icon: CupertinoIcons.lock_shield,
                        title: '暂无登录状态',
                        subtitle: '当前账号还没有可展示的设备与登录记录',
                        actionLabel: '刷新',
                        onAction: _reload,
                      );
                    }
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          _CurrentDeviceCard(device: status.currentDevice),
                          const SizedBox(height: 14),
                          _DeviceListCard(devices: status.devices),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentDeviceCard extends StatelessWidget {
  const _CurrentDeviceCard({required this.device});

  final LoginStatusDevice? device;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '当前设备',
      icon: CupertinoIcons.device_laptop,
      child: device == null
          ? const _MutedLine(text: '暂无当前设备信息')
          : _LoginStatusDeviceRow(
              device: device!,
              showCurrentTag: true,
              isLast: true,
            ),
    );
  }
}

class _DeviceListCard extends StatelessWidget {
  const _DeviceListCard({required this.devices});

  final List<LoginStatusDevice> devices;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '登录设备',
      icon: CupertinoIcons.rectangle_stack_person_crop_fill,
      child: devices.isEmpty
          ? const _MutedLine(text: '暂无登录设备记录')
          : Column(
              children: [
                for (var i = 0; i < devices.length; i++)
                  _LoginStatusDeviceRow(
                    device: devices[i],
                    showCurrentTag: true,
                    isLast: i == devices.length - 1,
                  ),
              ],
            ),
    );
  }
}

class _LoginStatusDeviceRow extends StatelessWidget {
  const _LoginStatusDeviceRow({
    required this.device,
    required this.showCurrentTag,
    required this.isLast,
  });

  final LoginStatusDevice device;
  final bool showCurrentTag;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final time = device.displayTime;
    final meta = [
      if (device.appVersion.isNotEmpty) '版本 ${device.appVersion}',
      if (time != null) '活跃 ${_formatBillDateTime(time)}',
    ].join(' · ');
    return _StatusListRow(
      icon: device.isCurrent
          ? CupertinoIcons.checkmark_shield_fill
          : CupertinoIcons.device_laptop,
      iconColor:
          device.isCurrent ? const Color(0xFF12B76A) : const Color(0xFF2F80ED),
      title: device.displayName,
      subtitle: meta.isEmpty ? '暂无设备版本与活跃时间' : meta,
      trailing: showCurrentTag && device.isCurrent
          ? const _SmallPill(text: '当前', color: Color(0xFF12B76A))
          : _SmallPill(
              text: device.isActive ? '正常' : '记录',
              color: device.isActive
                  ? const Color(0xFF12B76A)
                  : const Color(0xFF98A2B3),
            ),
      isLast: isLast,
    );
  }
}

class _StatusListRow extends StatelessWidget {
  const _StatusListRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.isLast,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF172033),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Color(0xFF667085),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              trailing,
            ],
          ),
        ),
        if (!isLast)
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFF1F3F7)),
      ],
    );
  }
}

class _MutedLine extends StatelessWidget {
  const _MutedLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: Color(0xFF98A2B3)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3FF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: const Color(0xFF165DFF), size: 26),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF172033),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Color(0xFF667085),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.info, required this.service});

  final AccountInfo info;
  final AccountInfoService service;

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.info.name,
  );
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameController.text.trim();
    if (name.length > 100) {
      BotToast.showText(text: '姓名不能超过 100 个字符');
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.service.updateProfile(displayName: name);
      if (!mounted) return;
      BotToast.showText(text: '资料已更新');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      BotToast.showText(text: '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kUiDialogMaxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          decoration: BoxDecoration(
            color: ColorConfig.pageBackground,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                title: '编辑资料',
                subtitle: '邮箱和手机号暂不可编辑',
                onClose: () => Navigator.of(context).pop(false),
                closeEnabled: !_saving,
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: '基本信息',
                icon: CupertinoIcons.person_fill,
                child: Column(
                  children: [
                    UiInputField(
                      label: '姓名',
                      controller: _nameController,
                      hintText: '请输入姓名',
                    ),
                    const SizedBox(height: 14),
                    _ReadonlyProfileRow(label: '邮箱', value: widget.info.email),
                    const SizedBox(height: 14),
                    _ReadonlyProfileRow(label: '手机号', value: widget.info.phone),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CupertinoActivityIndicator(radius: 8),
                          )
                        : const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadonlyProfileRow extends StatelessWidget {
  const _ReadonlyProfileRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF667085),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '未设置' : value,
            style: TextStyle(
              fontSize: 14,
              color: value.isEmpty
                  ? const Color(0xFF98A2B3)
                  : const Color(0xFF101828),
            ),
          ),
        ),
        const _ChipMutedReadonly(),
      ],
    );
  }
}

class _ChipMutedReadonly extends StatelessWidget {
  const _ChipMutedReadonly();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2F7),
        borderRadius: BorderRadius.circular(99),
      ),
      child: const Text(
        '只读',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF667085),
        ),
      ),
    );
  }
}

// 钱包模块 v1.0 入口已全部接 _showWalletComingSoon, 这两个对话框暂时不再被
// settings_page 直接调用; 保留实现等 v1.x 钱包重启用。
// ignore: unused_element
void _showWalletTransactionsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => const _WalletTransactionsDialog(),
  );
}

// ignore: unused_element
void _showRechargeDialog(
  BuildContext context, {
  required VoidCallback onSuccess,
}) {
  showDialog<void>(
    context: context,
    builder: (context) => _RechargeDialog(onSuccess: onSuccess),
  );
}

void _showWalletTransactionDetail(
  BuildContext context,
  WalletTransactionItem item,
) {
  showDialog<void>(
    context: context,
    builder: (context) => UiContentDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kUiDialogMaxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UiSheetHeader(
                title: item.title,
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 12),
              _TransactionDetailRow(
                label: '金额',
                value: '${item.signedAmountLabel} 元',
              ),
              _TransactionDetailRow(label: '类型', value: item.reasonLabel),
              _TransactionDetailRow(
                label: '发生时间',
                value: _formatBillDateTime(item.displayTime),
              ),
              _TransactionDetailRow(
                label: '变动后余额',
                value: '${item.balanceAfterYuan} 元',
              ),
              _TransactionDetailRow(
                label: '业务单号',
                value: item.bizNo,
                copyable: true,
              ),
              _TransactionDetailRow(label: '说明', value: item.remark),
            ],
          ),
        ),
      ),
    ),
  );
}

String _formatBillDate(DateTime? dateTime) {
  if (dateTime == null) return '未知日期';
  final local = dateTime.toLocal();
  return '${_twoDigits(local.month)}月${_twoDigits(local.day)}日';
}

String _formatBillTime(DateTime? dateTime) {
  if (dateTime == null) return '--:--';
  final local = dateTime.toLocal();
  return '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _formatBillDateTime(DateTime? dateTime) {
  if (dateTime == null) return '--';
  final local = dateTime.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

void _showAboutSheet(BuildContext context) {
  if (PlatformUtils.isMobile) {
    // 移动端走 Flutter 路由新页面,正文复用 PC 弹框内容,避免维护两套关于页 UI。
    context.push(RoutePaths.about);
    return;
  }

  showDialog<void>(
    context: context,
    builder: (context) => UiContentDialog(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: kUiDialogMaxWidth, maxHeight: 680),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: const DecoratedBox(
            decoration: BoxDecoration(color: ColorConfig.pageBackground),
            child: _AboutPanel(),
          ),
        ),
      ),
    ),
  );
}

class _MySkillsPanel extends ConsumerStatefulWidget {
  const _MySkillsPanel();

  @override
  ConsumerState<_MySkillsPanel> createState() => _MySkillsPanelState();
}

class _MySkillsPanelState extends ConsumerState<_MySkillsPanel> {
  String? _pendingSlug;

  Future<void> _uninstallSkill(InstalledSkill skill) async {
    setState(() => _pendingSlug = skill.slug);
    try {
      await ref.read(skillsProvider.notifier).uninstallSkill(skill.slug);
      ref.invalidate(installedSkillsProvider);
      if (mounted) {
        BotToast.showText(text: '已卸载 ${skill.displayTitle}');
      }
    } catch (error) {
      if (mounted) {
        BotToast.showText(text: '卸载失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _pendingSlug = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final installedAsync = ref.watch(installedSkillsProvider);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '我的技能',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF162033),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '这里展示当前已经安装的技能，并支持直接卸载。',
            style: TextStyle(fontSize: 13, color: Color(0xFF667085)),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: installedAsync.when(
              loading: () =>
                  const Center(child: CupertinoActivityIndicator(radius: 12)),
              error: (error, _) => _MySkillsStateMessage(
                icon: Icons.error_outline_rounded,
                title: '加载失败',
                description: error.toString(),
              ),
              data: (skills) {
                if (skills.isEmpty) {
                  return const _MySkillsStateMessage(
                    icon: Icons.inventory_2_outlined,
                    title: '还没有安装技能',
                    description: '去技能广场浏览可用技能后，会在这里看到它们。',
                  );
                }

                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: skills.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final skill = skills[index];
                    final isPending = _pendingSlug == skill.slug;
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE4E7EC)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  skill.displayTitle,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF162033),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  skill.slug,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF98A2B3),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '状态：${skill.statusLabel}'
                                  '${skill.installedAtLabel == null ? '' : ' · ${skill.installedAtLabel}'}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF667085),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 36,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFD92D20),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: isPending
                                  ? null
                                  : () => _uninstallSkill(skill),
                              icon: isPending
                                  ? const CupertinoActivityIndicator(
                                      radius: 7,
                                      color: Colors.white,
                                    )
                                  : const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 16,
                                    ),
                              label: Text(isPending ? '处理中' : '卸载'),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MySkillsStateMessage extends StatelessWidget {
  const _MySkillsStateMessage({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE4E7EC)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: const Color(0xFF98A2B3)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF162033),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Color(0xFF667085),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutPanel extends StatefulWidget {
  const _AboutPanel({this.showHeader = true});

  final bool showHeader;

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  late final Future<_AboutHeroSnapshot> _heroFuture = _loadHeroSnapshot();
  late final Future<_AboutSnapshot> _snapshotFuture = _loadSnapshot();
  bool _checkingForUpdates = false;
  final _updateFeedback = DesktopUpdateCheckFeedback();
  StreamSubscription<Map<String, dynamic>>? _updateEvents;
  // 隐藏入口：连点"应用信息" 5 次解锁切环境项，避免普通用户误操作。
  int _versionTapCount = 0;
  DateTime? _firstVersionTapAt;
  bool _envUnlocked = false;

  @override
  void initState() {
    super.initState();
    if (!PlatformUtils.isDesktop) return;
    _updateEvents = DesktopUpdateService.updateEvents.listen((event) {
      if (mounted) setState(() => _updateFeedback.accept(event));
    });
    final revision = _updateFeedback.revision;
    unawaited(DesktopUpdateService.getUpdateState().then((state) {
      if (mounted) {
        setState(() => _updateFeedback.restore(state, ifUnchanged: revision));
      }
    }));
  }

  @override
  void dispose() {
    _updateEvents?.cancel();
    super.dispose();
  }

  void _handleVersionTap() {
    if (_envUnlocked) return;
    final now = DateTime.now();
    // 3 秒内未完成 5 连击则重新计数，防止零散点击意外触发。
    if (_firstVersionTapAt == null ||
        now.difference(_firstVersionTapAt!) > const Duration(seconds: 3)) {
      _firstVersionTapAt = now;
      _versionTapCount = 1;
      return;
    }
    _versionTapCount += 1;
    if (_versionTapCount >= 5) {
      setState(() => _envUnlocked = true);
      BotToast.showText(text: '已解锁环境切换');
    }
  }

  Future<void> _showEnvSwitcher() async {
    // 按项目约定：移动端走全屏页面，PC 走弹框（settings 页面同款分支）。
    if (PlatformUtils.isMobile) {
      // 关于页本身在 PC 是 dialog、移动是路由页，这里只在移动端调，直接 push。
      await context.push(RoutePaths.envSwitch);
      // iOS 无法自杀退出、Android SystemNavigator.pop 也不保证进程立即终止，
      // pop 回来后必须重新读一次 AppConfig.env 刷新本页"当前环境"文案。
      if (mounted) setState(() {});
      return;
    }
    final picked = await showDialog<AppEnv>(
      context: context,
      builder: (ctx) => _EnvSwitchDialog(current: AppConfig.env),
    );
    if (picked == null || !mounted) return;
    await applyEnvSwitch(context, picked);
    if (mounted) setState(() {});
  }

  Future<_AboutHeroSnapshot> _loadHeroSnapshot() async {
    try {
      final deviceInfo = await DeviceInfoPlugin().deviceInfo;
      return _AboutHeroSnapshot.fromDeviceInfo(deviceInfo);
    } catch (_) {
      return const _AboutHeroSnapshot(
        displayName: '知办AI',
        summary: '当前设备信息暂不可用',
        platform: '未知平台',
        deviceName: null,
      );
    }
  }

  Future<_AboutSnapshot> _loadSnapshot() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return _AboutSnapshot(
        appName: packageInfo.appName,
        appVersion: packageInfo.version,
        buildNumber: packageInfo.buildNumber,
      );
    } catch (error) {
      return _AboutSnapshot(
        appName: '知办AI',
        appVersion: '未知版本',
        buildNumber: '--',
      );
    }
  }

  Future<void> _openLegalDoc(String title, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      BotToast.showText(text: '链接地址无效');
      return;
    }
    // 法律文本移动端走应用内 Browser,PC 端保留外部浏览器打开以符合桌面使用习惯。
    if (!PlatformUtils.isMobile) {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        BotToast.showText(text: '无法打开链接');
      }
      return;
    }
    if (!mounted) return;
    context.push(
      RoutePaths.browser,
      extra: {
        'title': title,
        'url': uri.toString()
      },
    );
  }

  Future<void> _checkForUpdates() async {
    if (_checkingForUpdates || _updateFeedback.busy) return;
    setState(() => _checkingForUpdates = true);
    final revision = PlatformUtils.isDesktop ? _updateFeedback.begin() : 0;
    try {
      if (PlatformUtils.isDesktop) {
        final feedUrl = AppUpdateService.appcastUrl();
        final result = await DesktopUpdateService.checkForUpdates(
          feedUrl: feedUrl,
        );
        if (!mounted) return;
        _updateFeedback.complete(result, ifUnchanged: revision);
        BotToast.showText(text: result.message);
      } else {
        final info = await AppUpdateService().fetchUpdateInfo();
        if (!mounted) return;
        if (info != null && info.isUpdateAvailable) {
          showUpdateAvailableDialog(context, info);
        } else {
          BotToast.showText(text: '已是最新版本');
        }
      }
    } catch (error) {
      if (!mounted) return;
      _updateFeedback.complete(DesktopUpdateCheckResult.failed,
          ifUnchanged: revision);
      BotToast.showText(text: '检查更新失败：$error');
    } finally {
      if (mounted) {
        setState(() => _checkingForUpdates = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AboutSnapshot>(
      future: _snapshotFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final loading =
            snapshot.connectionState == ConnectionState.waiting && data == null;

        return Container(
          height: double.infinity,
          padding: const EdgeInsets.all(20),
          child: loading
              ? const Center(child: CupertinoActivityIndicator(radius: 12))
              : FutureBuilder<_AboutHeroSnapshot>(
                  future: _heroFuture,
                  builder: (context, heroSnapshot) {
                    final heroData = heroSnapshot.data;
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.showHeader) ...[
                            // Dialog 头部统一复用 UiSheetHeader,保持标题/关闭按钮 start 对齐规范。
                            UiSheetHeader(
                              title: '关于我们',
                              subtitle: '查看应用信息与隐私政策。',
                              onClose: () => Navigator.of(context).pop(),
                            ),
                            const SizedBox(height: 16),
                          ],
                          _AboutHeroCard(snapshot: heroData),
                          const SizedBox(height: 16),
                          _AboutLinkTile(
                            title: '应用信息',
                            description: data == null
                                ? '读取中'
                                : 'v${data.appVersion} (${data.buildNumber})',
                            icon: CupertinoIcons.app_badge,
                            tint: const Color(0xFF2457F5),
                            showArrow: false,
                            // 隐藏入口：5 连点解锁下方"切换环境"。
                            onTap: _handleVersionTap,
                          ),
                          const SizedBox(height: 16),
                          _AboutLinkTile(
                            title: '用户协议',
                            description: '查看知办AI服务的使用条款。',
                            icon: CupertinoIcons.doc_text,
                            tint: const Color(0xFF2457F5),
                            onTap: () => _openLegalDoc(
                                '用户协议', AppConfig.userAgreementUrl),
                          ),
                          const SizedBox(height: 16),
                          _AboutLinkTile(
                            title: '隐私政策',
                            description: '查看我们如何收集、使用和保护信息。',
                            icon: CupertinoIcons.shield_lefthalf_fill,
                            tint: const Color(0xFF2457F5),
                            onTap: () => _openLegalDoc(
                                '隐私政策', AppConfig.privacyPolicyUrl),
                          ),
                          if (_envUnlocked) ...[
                            const SizedBox(height: 16),
                            _AboutLinkTile(
                              title: '切换环境',
                              description:
                                  '当前：${AppConfig.env.displayName}，切换后需重启 App 生效。',
                              icon: CupertinoIcons.cube_box,
                              tint: const Color(0xFFB45309),
                              onTap: _showEnvSwitcher,
                            ),
                          ],
                          const SizedBox(height: 16),
                          _AboutLinkTile(
                            title: '检查更新',
                            description: '检查应用是否有新版本。',
                            icon: CupertinoIcons.arrow_clockwise,
                            tint: const Color(0xFF2457F5),
                            trailingText: PlatformUtils.isDesktop
                                ? _updateFeedback.label
                                : (_checkingForUpdates ? '检查中' : null),
                            onTap: _checkingForUpdates || _updateFeedback.busy
                                ? null
                                : _checkForUpdates,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class _AboutHeroCard extends StatelessWidget {
  const _AboutHeroCard({required this.snapshot});

  final _AboutHeroSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final displayName = snapshot?.displayName ?? '知办AI';
    final summary = snapshot?.summary ?? '正在读取设备信息';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [primary.withValues(alpha: 0.12), const Color(0xFFEFF4FF)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFD8E4FF)),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD8E4FF)),
            ),
            child: Icon(Icons.auto_awesome_rounded, color: primary, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF162033),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  summary,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF475467),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutLinkTile extends StatelessWidget {
  const _AboutLinkTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.tint,
    this.trailingText,
    this.showArrow = true,
    this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color tint;
  final String? trailingText;
  final bool showArrow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE4E7EC)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: tint, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF162033),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: Color(0xFF667085),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (trailingText != null) ...[
                Text(
                  trailingText!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF98A2B3),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (showArrow)
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: enabled
                      ? const Color(0xFF98A2B3)
                      : const Color(0xFFD0D5DD),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutSnapshot {
  const _AboutSnapshot({
    required this.appName,
    required this.appVersion,
    required this.buildNumber,
  });

  final String appName;
  final String appVersion;
  final String buildNumber;
}

class _AboutHeroSnapshot {
  const _AboutHeroSnapshot({
    required this.displayName,
    required this.summary,
    required this.platform,
    required this.deviceName,
  });

  final String displayName;
  final String summary;
  final String platform;
  final String? deviceName;

  factory _AboutHeroSnapshot.fromDeviceInfo(BaseDeviceInfo deviceInfo) {
    if (deviceInfo is MacOsDeviceInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary:
            '${deviceInfo.modelName} · ${deviceInfo.computerName} · ${deviceInfo.osRelease}',
        platform: 'macOS',
        deviceName: deviceInfo.computerName,
      );
    }
    if (deviceInfo is WindowsDeviceInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary:
            '${deviceInfo.productName} · ${deviceInfo.computerName} · ${deviceInfo.displayVersion}',
        platform: 'Windows',
        deviceName: deviceInfo.computerName,
      );
    }
    if (deviceInfo is LinuxDeviceInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary: deviceInfo.prettyName,
        platform: 'Linux',
        deviceName: deviceInfo.machineId,
      );
    }
    if (deviceInfo is AndroidDeviceInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary:
            '${deviceInfo.brand} ${deviceInfo.model} · Android ${deviceInfo.version.release}',
        platform: 'Android',
        deviceName: deviceInfo.name,
      );
    }
    if (deviceInfo is IosDeviceInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary:
            '${deviceInfo.modelName} · ${deviceInfo.name} · ${deviceInfo.systemVersion}',
        platform: 'iOS',
        deviceName: deviceInfo.name,
      );
    }
    if (deviceInfo is WebBrowserInfo) {
      return _AboutHeroSnapshot(
        displayName: '知办AI',
        summary:
            '${deviceInfo.browserName.name} · ${deviceInfo.appVersion ?? '--'}',
        platform: 'Web',
        deviceName: deviceInfo.userAgent,
      );
    }
    return const _AboutHeroSnapshot(
      displayName: '知办AI',
      summary: '当前设备信息暂不可用',
      platform: '未知平台',
      deviceName: null,
    );
  }
}

// ─── Mobile full-screen pages ────────────────────────────────────────────────

class _BasicInfoReadonlyRow extends StatelessWidget {
  const _BasicInfoReadonlyRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF667085),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '未设置' : value,
            style: TextStyle(
              fontSize: 14,
              color: value.isEmpty
                  ? const Color(0xFF98A2B3)
                  : const Color(0xFF101828),
            ),
          ),
        ),
      ],
    );
  }
}

class ProfileDetailsPage extends ConsumerStatefulWidget {
  const ProfileDetailsPage({super.key, this.info});
  final AccountInfo? info;

  @override
  ConsumerState<ProfileDetailsPage> createState() => _ProfileDetailsPageState();
}

class _ProfileDetailsPageState extends ConsumerState<ProfileDetailsPage> {
  final _service = AccountInfoService();
  TextEditingController? _nameController;
  bool _initialized = false;
  bool _saving = false;
  bool _uploadingAvatar = false;

  void _initControllers(AccountInfo info) {
    if (_initialized) return;
    _nameController = TextEditingController(text: info.name);
    _initialized = true;
  }

  @override
  void dispose() {
    _nameController?.dispose();
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    if (_uploadingAvatar) return;
    final file = await pickSingleImage();
    if (file == null || file.path.isEmpty) return;
    setState(() => _uploadingAvatar = true);
    try {
      await _service.uploadAvatar(filePath: file.path, fileName: file.name);
      ref.invalidate(authMeProvider);
      if (!mounted) return;
      BotToast.showText(text: '头像已更新');
    } catch (error) {
      if (!mounted) return;
      BotToast.showText(text: '更换头像失败：$error');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_initialized) return;
    final name = _nameController!.text.trim();
    if (name.length > 100) {
      BotToast.showText(text: '姓名不能超过 100 个字符');
      return;
    }
    setState(() => _saving = true);
    try {
      await _service.updateProfile(displayName: name);
      if (!mounted) return;
      ref.invalidate(authMeProvider);
      BotToast.showText(text: '资料已更新');
      context.pop();
    } catch (error) {
      if (!mounted) return;
      BotToast.showText(text: '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncInfo = ref.watch(accountInfoProvider);
    final info = asyncInfo.value ?? widget.info;
    if (info != null) _initControllers(info);

    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '基础资料',
        actions: [
          TextButton(
            onPressed: (_saving || !_initialized) ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CupertinoActivityIndicator(radius: 8),
                  )
                : const Text(
                    '保存',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
          ),
        ],
      ),
      body: info == null
          ? const Center(child: CupertinoActivityIndicator(radius: 12))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _changeAvatar,
                      child: Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _ProfileAvatar(
                              info: info,
                              uploading: _uploadingAvatar,
                              onTap: _changeAvatar,
                              size: 80,
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: const BoxDecoration(
                                  color: Color(0xFF165DFF),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _displayName(info),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF101828),
                      ),
                    ),
                    const SizedBox(height: 32),
                    _SectionCard(
                      title: '基本信息',
                      icon: CupertinoIcons.person_fill,
                      child: Column(
                        children: [
                          UiInputField(
                            label: '姓名',
                            controller:
                                _nameController ?? TextEditingController(),
                            hintText: '请输入姓名',
                          ),
                          const SizedBox(height: 14),
                          _BasicInfoReadonlyRow(
                              label: '账号', value: info.accountNo),
                          const SizedBox(height: 14),
                          _BasicInfoReadonlyRow(label: '邮箱', value: info.email),
                          const SizedBox(height: 14),
                          _BasicInfoReadonlyRow(
                              label: '手机号', value: info.phone),
                          if (info.departmentName.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            _BasicInfoReadonlyRow(
                                label: '部门', value: info.departmentName),
                          ],
                          if (info.tenantName.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            _BasicInfoReadonlyRow(
                                label: '租户', value: info.tenantName),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _AccountStatusCard(info: info),
                  ],
                ),
              ),
            ),
    );
  }
}

class LoginStatusPage extends StatefulWidget {
  const LoginStatusPage({super.key});

  @override
  State<LoginStatusPage> createState() => _LoginStatusPageState();
}

class _LoginStatusPageState extends State<LoginStatusPage> {
  late Future<LoginStatus> _future;

  @override
  void initState() {
    super.initState();
    _future = LoginStatusService().fetchLoginStatus();
  }

  void _reload() {
    setState(() {
      _future = LoginStatusService().fetchLoginStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '登录状态',
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.refresh, size: 20),
            tooltip: '刷新',
            onPressed: _reload,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: FutureBuilder<LoginStatus>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CupertinoActivityIndicator(radius: 12));
          }
          if (snapshot.hasError) {
            return _EmptyState(
              icon: CupertinoIcons.exclamationmark_triangle,
              title: '登录状态加载失败',
              subtitle: '${snapshot.error}',
              actionLabel: '重新加载',
              onAction: _reload,
            );
          }
          final status = snapshot.data;
          if (status == null) {
            return _EmptyState(
              icon: CupertinoIcons.lock_shield,
              title: '暂无登录状态',
              subtitle: '当前账号还没有可展示的设备与登录记录',
              actionLabel: '刷新',
              onAction: _reload,
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              children: [
                _CurrentDeviceCard(device: status.currentDevice),
                const SizedBox(height: 14),
                _DeviceListCard(devices: status.devices),
              ],
            ),
          );
        },
      ),
    );
  }
}

class WalletTransactionsPage extends StatefulWidget {
  const WalletTransactionsPage({super.key});

  @override
  State<WalletTransactionsPage> createState() => _WalletTransactionsPageState();
}

class _WalletTransactionsPageState extends State<WalletTransactionsPage> {
  static const _pageSize = 30;
  final WalletService _walletService = WalletService();
  final List<WalletTransactionItem> _items = [];
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _page = 1;
        _total = 0;
        _items.clear();
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || !_canLoadMore) return;
      setState(() {
        _loadingMore = true;
        _error = null;
      });
    }
    try {
      final nextPage = reset ? 1 : _page + 1;
      final result = await _walletService.fetchTransactions(
          page: nextPage, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _page = nextPage;
        _total = result.total;
        _items.addAll(result.items);
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool get _canLoadMore => _items.length < _total;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '账单明细',
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.refresh, size: 20),
            tooltip: '刷新',
            onPressed: () => _load(reset: true),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(child: _buildContent(context)),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 13));
    }
    if (_error != null && _items.isEmpty) {
      return _WalletStateMessage(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: '账单加载失败',
        subtitle: _error!,
        actionLabel: '重新加载',
        onAction: () => _load(reset: true),
      );
    }
    if (_items.isEmpty) {
      return const _WalletStateMessage(
        icon: CupertinoIcons.doc_text,
        title: '暂无账单记录',
        subtitle: '产生充值或消费后，账单会在这里展示',
      );
    }
    final children = <Widget>[];
    String? currentDate;
    for (final item in _items) {
      final date = _formatBillDate(item.displayTime);
      if (date != currentDate) {
        currentDate = date;
        children.add(_BillDateHeader(label: date));
      }
      children.add(_BillTransactionTile(item: item));
    }
    if (_canLoadMore) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: _loadingMore
                ? const CupertinoActivityIndicator(radius: 10)
                : TextButton(
                    onPressed: () => _load(reset: false),
                    child: const Text('加载更多'),
                  ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: children,
    );
  }
}
