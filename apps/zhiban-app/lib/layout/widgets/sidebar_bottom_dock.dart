import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/account_info_api.dart';

import 'package:zhiban_ui/widgets/ui_icon_button.dart';

import 'sidebar_billing_section.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'sidebar_community_section.dart';
import 'sidebar_profile_popover.dart';
import 'sidebar_update_section.dart';

class SidebarBottomDock extends ConsumerWidget {
  const SidebarBottomDock({super.key, this.collapsed = false});

  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(accountInfoProvider).value;
    final hideBillingEntry = info?.phone.trim() == '13900000003';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SidebarCommunitySection(collapsed: collapsed),
        if (!AppConfig.communityEdition) SidebarUpdateSection(collapsed: collapsed),
        if (!AppConfig.communityEdition && !hideBillingEntry) SidebarBillingSection(collapsed: collapsed),
        const SizedBox(height: 8),
        // 「我的企业」恒显 (对齐企业微信); 单企业时弹框只有当前企业一行打勾。
        _MyCompanyItem(collapsed: collapsed),
      ],
    );
  }
}

/// 底部「我的企业」入口 (对齐企业微信左下角): 点击向上弹企业列表, 可切换企业。
class _MyCompanyItem extends StatefulWidget {
  const _MyCompanyItem({required this.collapsed});

  final bool collapsed;

  @override
  State<_MyCompanyItem> createState() => _MyCompanyItemState();
}

class _MyCompanyItemState extends State<_MyCompanyItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) {
      return UiIconButton(
        icon: CupertinoIcons.building_2_fill,
        tooltip: '我的企业',
        size: 44,
        iconSize: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        onTap: () => showSidebarCompanyPopover(context),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => showSidebarCompanyPopover(context),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.64)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: [
              Icon(
                CupertinoIcons.building_2_fill,
                size: 18,
                color: Color(0xFF344054),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  '我的企业',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF344054),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
