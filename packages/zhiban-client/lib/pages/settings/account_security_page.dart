import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/pages/settings/account_deletion_flow.dart';
import 'package:zhiban_client/services/logout_flow.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';

/// 账号安全正文（移动端整页 / 桌面端弹框复用同一份）。
class AccountSecurityBody extends StatelessWidget {
  const AccountSecurityBody({super.key});

  Future<void> _deleteAccount(BuildContext context) {
    return requestFrontendAccountDeletion(
      context,
      onConfirmed: () => performLogoutToLogin(
        context,
        failurePrefix: '注销账号退出失败'
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _deleteAccount(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF5F3),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: const Row(
              children: [
                Icon(
                  CupertinoIcons.person_crop_circle_badge_xmark,
                  color: Color(0xFFD92D20),
                  size: 22,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '注销账号',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFD92D20),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  color: Color(0xFFD92D20),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AccountSecurityPage extends StatelessWidget {
  const AccountSecurityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: const UiPageBar(title: '账号安全'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: const AccountSecurityBody(),
            ),
          ),
        ),
      ),
    );
  }
}
