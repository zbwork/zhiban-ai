import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/account_info_api.dart';

import 'sidebar_profile_popover.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';

/// 侧栏左上角用户块: 点击弹个人弹框 (向下展开)。
class SidebarUserTop extends ConsumerWidget {
  const SidebarUserTop({super.key, this.collapsed = false});

  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(accountInfoProvider).value;
    return Builder(
      // 用 SidebarUserMini 自己的 context 做弹框锚点定位。
      builder: (anchorContext) => SidebarUserMini(
        info: info,
        collapsed: collapsed,
        onTap: () => showSidebarProfilePopover(anchorContext, info: info),
      ),
    );
  }
}
