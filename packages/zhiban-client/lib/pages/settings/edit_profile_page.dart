import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _service = AccountInfoService();
  late final TextEditingController _nameController;
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    if (_initialized) {
      _nameController.dispose();
    }
    super.dispose();
  }

  void _initControllers(AccountInfo info) {
    if (_initialized) return;
    _nameController = TextEditingController(text: info.name);
    _initialized = true;
  }

  Future<void> _save() async {
    if (_saving || !_initialized) return;
    final name = _nameController.text.trim();
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
      context.pop(true);
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
    // asData 在 accountInfoProvider 静默刷新期间会变 null（见
    // settings_page.dart 同款注释），改用 value 保留刷新前的旧数据。
    final info = asyncInfo.value;
    if (info != null) _initControllers(info);

    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        backgroundColor: ColorConfig.pageBackground,
        title: '编辑资料',
        leading: IconButton(
          icon: const Icon(CupertinoIcons.xmark),
          onPressed: _saving ? null : () => context.pop(false),
        ),
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
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700
                    ),
                  ),
          ),
        ],
      ),
      body: info == null
          ? const Center(child: CupertinoActivityIndicator(radius: 12))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                child: _SectionCard(
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
                      _ReadonlyRow(label: '邮箱', value: info.email),
                      const SizedBox(height: 14),
                      _ReadonlyRow(label: '手机号', value: info.phone),
                    ],
                  ),
                ),
              ),
            ),
    );
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

class _ReadonlyRow extends StatelessWidget {
  const _ReadonlyRow({required this.label, required this.value});

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
        Container(
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
        ),
      ],
    );
  }
}
