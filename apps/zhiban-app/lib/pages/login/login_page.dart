import 'package:zhiban_client/network/user_refresh.dart';

import 'package:zhiban_client/config/client_assets.dart';
import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'widgets/login_topbar_background.dart';
import 'package:nexwork/config/login_layout_config.dart';
import 'package:zhiban_client/pages/login/login_tenant_scope_flow.dart';
import 'package:zhiban_client/pages/login/models/login_account_state.dart';
import 'package:zhiban_client/pages/login/providers/login_account_provider.dart';
import 'providers/login_qr_provider.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _mobileController = TextEditingController();
  final _captchaController = TextEditingController();
  final _smsCodeController = TextEditingController();
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showDesktopCaptcha = false;

  @override
  void dispose() {
    _mobileController.dispose();
    _captchaController.dispose();
    _smsCodeController.dispose();
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<LoginAccountState>(loginAccountProvider, (prev, next) {
      final error = next.error;
      if (error == null || error.isEmpty || prev?.error == error) return;
      BotToast.showText(text: error);
    });
    final state = ref.watch(loginAccountProvider);
    return _buildDesktopLoginPage(context, state);
  }

  void _handleMobileChanged(String value) {
    ref.read(loginAccountProvider.notifier).onMobileChanged();
    _smsCodeController.clear();
    _captchaController.clear();
    final showDesktopCaptcha = value.length >= 11;
    if (_showDesktopCaptcha != showDesktopCaptcha) {
      setState(() => _showDesktopCaptcha = showDesktopCaptcha);
      if (showDesktopCaptcha) {
        ref.read(loginAccountProvider.notifier).fetchCaptcha();
      }
    }
  }

  Future<bool> _sendSmsCode() {
    if (!ref.read(loginAccountProvider.notifier).validateAgreement()) {
      return Future.value(false);
    }
    return ref.read(loginAccountProvider.notifier).sendSmsCode(
          mobile: _mobileController.text,
          captchaCode: _captchaController.text,
        );
  }

  Future<void> _refreshCaptcha() {
    return ref.read(loginAccountProvider.notifier).fetchCaptcha();
  }

  Future<void> _submitLogin(BuildContext context) async {
    if (!ref.read(loginAccountProvider.notifier).validateAgreement()) return;
    final outcome = await ref.read(loginAccountProvider.notifier).submit(
          mobile: _mobileController.text,
          smsCode: _smsCodeController.text,
        );
    if (!mounted || !outcome.success || !context.mounted) return;
    await enterHomeWithTenantScope(context, outcome.tenantScopes);
  }

  Widget _buildLabeledField({
    required Widget child,
    required String label,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        child,
      ],
    );
  }

  Future<void> _submitPassword() async {
    final outcome =
        await ref.read(loginAccountProvider.notifier).submitPassword(
              identifier: _identifierController.text,
              password: _passwordController.text,
            );
    if (!mounted || !outcome.success) return;
    _passwordController.clear();
    await enterHomeWithTenantScope(context, outcome.tenantScopes);
  }

  Widget _buildPasswordTab(LoginAccountState state) {
    final loading = state.isLoggingIn;
    return AutofillGroup(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLabeledField(
            label: '账号',
            child: UiInputField(
              controller: _identifierController,
              hintText: '邮箱 / 手机号 / 用户名',
              enabled: !loading,
              height: loginControlHeight,
              autofillHints: const [AutofillHints.username],
            )),
        const SizedBox(height: 14),
        _buildLabeledField(
            label: '密码',
            child: UiInputField(
              controller: _passwordController,
              hintText: '请输入密码',
              obscureText: true,
              enabled: !loading,
              height: loginControlHeight,
              autofillHints: const [AutofillHints.password],
              onSubmitted: loading ? null : (_) => _submitPassword(),
            )),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: loading ? null : _submitPassword,
          child:
              loading ? const CupertinoActivityIndicator() : const Text('登录'),
        ),
      ],
    ));
  }

  Widget _buildCaptchaImage(LoginAccountState state) {
    Uint8List? bytes;
    final raw = state.captchaData?.captchaBase64 ?? '';
    if (raw.isNotEmpty) {
      try {
        final normalized =
            raw.contains(',') ? raw.substring(raw.indexOf(',') + 1) : raw;
        bytes = base64Decode(normalized);
      } catch (_) {
        bytes = null;
      }
    }

    return GestureDetector(
      onTap: state.isCaptchaLoading ? null : _refreshCaptcha,
      child: Container(
        width: double.infinity,
        height: loginControlHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE0E6F0)),
        ),
        child: bytes != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.fill,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                ),
              )
            : Text(
                state.isCaptchaLoading ? '加载中...' : '换一张',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
      ),
    );
  }

  Widget _buildDesktopAccountTab(
    BuildContext context,
    LoginAccountState state,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildLabeledField(
          label: '手机号',
          child: UiInputField(
            controller: _mobileController,
            hintText: '请输入手机号',
            prefixIcon: const Icon(CupertinoIcons.phone_fill, size: 18),
            clearable: true,
            height: loginControlHeight,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            onChanged: _handleMobileChanged,
          ),
        ),
        if (_showDesktopCaptcha) ...[
          const SizedBox(height: 14),
          _buildLabeledField(
            label: '图形验证码',
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: UiInputField(
                    controller: _captchaController,
                    hintText: '图形验证码',
                    prefixIcon: const Icon(CupertinoIcons.shield, size: 18),
                    clearable: true,
                    height: loginControlHeight,
                    keyboardType: TextInputType.text,
                    inputFormatters: const [],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _buildCaptchaImage(state)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        _buildLabeledField(
          label: '短信验证码',
          child: Builder(
            builder: (context) {
              final input = UiInputField(
                controller: _smsCodeController,
                hintText: '短信验证码',
                prefixIcon: const Icon(
                  CupertinoIcons.chat_bubble_text_fill,
                  size: 18,
                ),
                clearable: true,
                height: loginControlHeight,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                autofillHints: const [AutofillHints.oneTimeCode],
              );
              final button = TextFieldTapRegion(
                child: Consumer(
                  builder: (context, ref, _) {
                    final countdown = ref.watch(loginSmsCountdownProvider);
                    return OutlinedButton(
                      onPressed: (state.isSendingSms || countdown > 0)
                          ? null
                          : _sendSmsCode,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1677FF),
                        side: const BorderSide(color: Color(0xFFD8E2F0)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        fixedSize: const Size.fromHeight(loginControlHeight),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                                fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          countdown > 0 ? '${countdown}s' : '获取短信验证码',
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    );
                  },
                ),
              );
              return Row(
                children: [
                  Expanded(flex: 3, child: input),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: loginControlHeight,
                      child: button,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CupertinoCheckbox(
                value: state.agreementChecked,
                activeColor: const Color(0xFF1677FF),
                onChanged: (value) => ref
                    .read(loginAccountProvider.notifier)
                    .setAgreementChecked(value ?? false),
              ),
            ),
            Expanded(
              child: Wrap(
                children: [
                  Text(
                    '我已阅读并同意',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  ),
                  GestureDetector(
                    onTap: openLoginPrivacyPolicy,
                    child: const Text(
                      '《隐私政策》',
                      style: TextStyle(color: Color(0xFF1677FF), fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Builder(builder: (context) {
          final loading = state.isLoggingIn || state.isRegistering;
          final foregroundColor = Theme.of(context).colorScheme.surface;
          return FilledButton(
            onPressed: loading ? null : () => _submitLogin(context),
            style: FilledButton.styleFrom(
              fixedSize: const Size.fromHeight(loginControlHeight),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading) ...[
                  CupertinoActivityIndicator(color: foregroundColor, radius: 7),
                  const SizedBox(width: 8),
                ],
                Text(
                  '注册 / 登录',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: foregroundColor, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDesktopLoginPage(
    BuildContext context,
    LoginAccountState state,
  ) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFF),
      body: Stack(
        children: [
          const _LoginHeroBackground(),
          LayoutBuilder(
            builder: (context, constraints) {
              // 桌面登录窗口 480x720 (window_controller.dart _loginSize), 高于 380 阈值,
              // 因此默认会显示 "手机号 / 扫码登录" Tab。
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 32,
                        top: 42,
                        right: 32,
                        bottom: 16,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.white),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF165DFF)
                                    .withValues(alpha: 0.10),
                                blurRadius: 28,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const _LoginBrandHeader(),
                                const SizedBox(height: 22),
                                if (communityPasswordLoginOnly)
                                  _buildPasswordTab(state)
                                else
                                  _LoginTabs(
                                    accountTabBuilder: (context) => Consumer(
                                      builder: (context, ref, _) =>
                                          _buildDesktopAccountTab(
                                        context,
                                        ref.watch(loginAccountProvider),
                                      ),
                                    ),
                                    qrTab: const _QrLoginPanel(),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 桌面端 Tab 容器: 圆角胶囊样式 (pill/segment), 对齐 legacy easyo-app login_page 风格。
/// Tab 内容按当前选中项懒加载, 避免未进入的登录方式提前请求接口。
class _LoginTabs extends ConsumerStatefulWidget {
  const _LoginTabs({required this.accountTabBuilder, required this.qrTab});
  final WidgetBuilder accountTabBuilder;
  final Widget qrTab;

  @override
  ConsumerState<_LoginTabs> createState() => _LoginTabsState();
}

class _LoginTabsState extends ConsumerState<_LoginTabs> {
  int _tabIndex = 0;

  void _switchTo(int index) {
    if (_tabIndex == index) return;
    setState(() => _tabIndex = index);
    // 切 Tab 顺手清错: 上一 Tab 残留的错误提示不应影响新 Tab。
    ref.read(loginAccountProvider.notifier).clearError();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F6FC),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFFE2E8F4)),
          ),
          child: Row(
            children: [
              Expanded(
                  child: _PillTab(
                      label: '手机号登录',
                      selected: _tabIndex == 0,
                      onTap: () => _switchTo(0))),
              Expanded(
                  child: _PillTab(
                      label: '扫码登录',
                      selected: _tabIndex == 1,
                      onTap: () => _switchTo(1))),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (_tabIndex == 0) widget.accountTabBuilder(context) else widget.qrTab,
      ],
    );
  }
}

class _PillTab extends StatelessWidget {
  const _PillTab(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? const Color(0xFFB7CDFF) : Colors.transparent,
            width: 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF1677FF).withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? const Color(0xFF1677FF) : const Color(0xFF667085),
          ),
        ),
      ),
    );
  }
}

/// 二维码面板: 显示二维码 + 状态文案 + 刷新按钮。登录成功直接跳主页 (或选租户)。
class _QrLoginPanel extends ConsumerWidget {
  const _QrLoginPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(qrInfoProvider);
    // 进入 Tab 才开始轮询; 切走时 autoDispose 自动停。
    final status = ref.watch(qrStatusProvider);

    // 终态自动跳。注意 ref.listen 不能在 ConsumerWidget.build 之外用, 这里直接绑定。
    ref.listen<AsyncValue<QRLoginStatus>>(qrStatusProvider, (prev, next) async {
      final s = next.value;
      if (s == null) return;
      if (s.status == 'confirmed' && s.login != null) {
        // 复用与短信登录同样的 outcome: 单租户直接进, 多租户去选择页。
        final me = s.login!;
        if (!context.mounted) return;
        // 这里没办法直接拿到 fetchMeApi 列表 (QR 流程已 minted token); 桌面端先按
        // actScope 的 tenant 直接进, 后续在主页通过 /auth/me 自行获取 scope 列表切换。
        // 这与 docs §10.4 "首次进入按 caller 当前 actScope" 一致。
        unawaited(_enter(context, me));
      } else if (s.status == 'expired' || s.status == 'cancelled') {
        // 失效后保持文案 3s, 用户主动点"刷新"重新拉。
      }
    });

    return SizedBox(
      height: 320,
      child: info.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => _QrError(
            message: '$e',
            onRefresh: () => UserRefresh.run(
                () => ref.read(qrInfoProvider.notifier).refresh())),
        data: (qr) => _QrCard(
          imageDataUri: qr.qrcodeImage,
          status: status.value,
          onRefresh: () => UserRefresh.run(
              () => ref.read(qrInfoProvider.notifier).refresh()),
        ),
      ),
    );
  }

  Future<void> _enter(BuildContext context, AuthLoginResult res) async {
    // 与 _loginOrRegister 行为对齐: 走 fetchMeApi 决定是否要选租户。
    try {
      final me = await fetchMeApi();
      if (!context.mounted) return;
      await enterHomeWithTenantScope(context, me.tenantScopes);
    } catch (_) {
      if (!context.mounted) return;
      // /auth/me 失败兜底: 直接按 actScope 进主页, 主页里会再尝试。
      enterHomeAfterLogin(context);
    }
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({
    required this.imageDataUri,
    required this.status,
    required this.onRefresh,
  });
  final String imageDataUri;
  final QRLoginStatus? status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      final raw = imageDataUri.contains(',')
          ? imageDataUri.substring(imageDataUri.indexOf(',') + 1)
          : imageDataUri;
      bytes = base64Decode(raw);
    } catch (_) {
      bytes = null;
    }
    final s = status;
    final terminal =
        s != null && (s.status == 'expired' || s.status == 'cancelled');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 220,
                height: 220,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE0E6F0)),
                ),
                child: bytes != null
                    ? Image.memory(bytes, gaplessPlayback: true)
                    : const Center(child: CircularProgressIndicator()),
              ),
              if (terminal)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.statusDesc,
                            style: const TextStyle(
                              color: Color(0xFF101828),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: onRefresh,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('刷新二维码'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            s?.statusDesc ?? '请使用手机 知办AI 扫码登录',
            style: TextStyle(
              color: s?.status == 'scanned'
                  ? const Color(0xFF1677FF)
                  : const Color(0xFF667085),
              fontSize: 13,
              fontWeight:
                  s?.status == 'scanned' ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _QrError extends StatelessWidget {
  const _QrError({required this.message, required this.onRefresh});
  final String message;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.exclamationmark_circle,
              color: Color(0xFFEF4444), size: 28),
          const SizedBox(height: 10),
          Text(
            '获取二维码失败：$message',
            style: const TextStyle(color: Color(0xFF667085), fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _LoginBrandHeader extends StatelessWidget {
  const _LoginBrandHeader();

  @override
  Widget build(BuildContext context) {
    const logoSize = 56.0;
    final logo = Container(
      width: logoSize,
      height: logoSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF165DFF).withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        package: ClientAssets.packageName,
        'assets/app_icon.png',
        width: logoSize,
        height: logoSize,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '知办AI',
          style: const TextStyle(
            fontSize: 30,
            height: 1,
            fontWeight: FontWeight.w900,
            color: Color(0xFF101828),
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        Text(
          '数字员工协作平台',
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF667085),
            letterSpacing: 0,
          ),
          textAlign: TextAlign.left,
        ),
      ],
    );
    return Row(
      children: [
        logo,
        const SizedBox(width: 18),
        Expanded(child: title),
      ],
    );
  }
}

class _LoginHeroBackground extends StatelessWidget {
  const _LoginHeroBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const LoginTopBarBackground(),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFFEAF2FF).withValues(alpha: 0.92),
                  Colors.white,
                ],
                begin: Alignment.bottomLeft,
                end: Alignment.topRight,
              ),
            ),
          ),
        ),
        Positioned(
          right: -65,
          top: 74,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFBBD2FF).withValues(alpha: 0.35),
                width: 40,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
