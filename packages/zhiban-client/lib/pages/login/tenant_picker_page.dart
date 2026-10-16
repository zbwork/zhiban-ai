// 租户选择页 (docs/contracts/agent-bus-client-contract.md §10.1 第 5 步)。
//
// 入口: 登录/注册成功后, login_page 拿到 me.tenantScopes; 长度 ≥2 时
// - 移动端: `context.push(RoutePaths.tenantPicker, extra: scopes)` 跳全屏页。
// - 桌面端: `showTenantPickerDialog(context, scopes)` 弹 Dialog。
// 点击某一行 → 调 /auth/scope/switch 写新 accessToken → 进主页。
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/login/login_navigation.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';

// ---------------------------------------------------------------------------
// 共享内容体：标题 + 副标题 + 租户卡片列表
// ---------------------------------------------------------------------------

class TenantPickerBody extends StatelessWidget {
  final List<ScopeOption> scopes;
  final String? maskedPhone;
  final int? switchingTenantId;
  final ValueChanged<ScopeOption> onPick;

  const TenantPickerBody({
    super.key,
    required this.scopes,
    this.maskedPhone,
    this.switchingTenantId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '你可进入以下企业',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Color(0xFF101828),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _subtitleText(maskedPhone, scopes.length),
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Color(0xFF8C95A6),
          ),
        ),
        const SizedBox(height: 22),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            itemCount: scopes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) {
              final s = scopes[i];
              final isSwitching = switchingTenantId == s.tenantId;
              return TenantCard(
                tenant: s,
                busy: isSwitching,
                disabled: switchingTenantId != null && !isSwitching,
                onTap: () => onPick(s),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _subtitleText(String? maskedPhone, int n) {
    final phone =
        (maskedPhone == null || maskedPhone.isEmpty) ? '' : '$maskedPhone ';
    return '$phone已在以下企业或组织绑定了账号，你可进入这 $n 个企业或组织。';
  }
}

// ---------------------------------------------------------------------------
// 桌面端 Dialog
// ---------------------------------------------------------------------------

Future<ScopeOption?> showTenantPickerDialog(
  BuildContext context,
  List<ScopeOption> scopes, {
  String? maskedPhone,
}) {
  return showDialog<ScopeOption>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => UiPickerDialog(
      size: UiDialogSize.compact,
      maxHeight: 480,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: '选择企业',
              onClose: () => Navigator.of(ctx).pop(),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: TenantPickerBody(
                scopes: scopes,
                maskedPhone: maskedPhone,
                onPick: (s) => Navigator.of(ctx).pop(s),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 移动端全屏页
// ---------------------------------------------------------------------------

class TenantPickerPage extends ConsumerStatefulWidget {
  final List<ScopeOption> tenantScopes;
  final String? maskedPhone;

  const TenantPickerPage({
    super.key,
    required this.tenantScopes,
    this.maskedPhone,
  });

  @override
  ConsumerState<TenantPickerPage> createState() => _TenantPickerPageState();
}

class _TenantPickerPageState extends ConsumerState<TenantPickerPage> {
  int? _switchingTenantId;

  Future<void> _onPick(ScopeOption s) async {
    if (_switchingTenantId != null) return;
    setState(() => _switchingTenantId = s.tenantId);
    try {
      await switchToTenantApi(s.tenantId);
      if (!mounted) return;
      enterHomeAfterLogin(context, resetScope: true);
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: formatError(e));
      setState(() => _switchingTenantId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFF),
      appBar: UiPageBar(
        backgroundColor: const Color(0xFFF7FAFF),
        showBottomBorder: false,
        onBack: () => context.canPop() ? context.pop() : context.go('/login'),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TenantPickerBody(
                  scopes: widget.tenantScopes,
                  maskedPhone: widget.maskedPhone,
                  switchingTenantId: _switchingTenantId,
                  onPick: _onPick,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 租户卡片
// ---------------------------------------------------------------------------

class TenantCard extends StatelessWidget {
  final ScopeOption tenant;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  const TenantCard({
    super.key,
    required this.tenant,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tenantName = _firstNonEmpty([
      tenant.tenantName,
      tenant.tenantSlug,
      tenant.tenantId > 0 ? '租户 ${tenant.tenantId}' : '',
    ]);
    final memberName = _firstNonEmpty([
      tenant.memberDisplayName,
      tenant.tenantSlug,
      tenantName,
    ]);
    final initial = _firstVisibleChar(tenantName);
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E9F0)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6EEFF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1F4FCC),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tenantName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF101828),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        memberName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8C95A6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CupertinoActivityIndicator(),
                  )
                else
                  const Icon(CupertinoIcons.chevron_right,
                      size: 18, color: Color(0xFFB0B7C2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _firstVisibleChar(String s) {
    final t = s.trim();
    if (t.isEmpty) return '?';
    return t.substring(0, 1);
  }

  String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}
