import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

/// 统一的页面级 AppBar，自带 chevron_left 返回按钮。
/// 用于所有通过 context.push / MaterialPage 打开的全屏子页面。
class UiPageBar extends StatelessWidget implements PreferredSizeWidget {
  const UiPageBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions = const [],
    this.backgroundColor,
    this.leading,
    this.leadingWidth,
    this.onBack,
    this.showBackButton = true,
    this.showBottomBorder = true,
  });

  final String? title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final Color? backgroundColor;

  /// 完全替换 leading 区域；优先级高于 onBack。
  final Widget? leading;

  /// 当 [leading] 需要超过默认 56px 宽度时设置；为 null 时使用 AppBar 默认值。
  final double? leadingWidth;

  /// 自定义返回行为；为 null 时默认 context.pop()。ignored when [leading] is set.
  final VoidCallback? onBack;

  /// 是否显示默认返回按钮；一级页面可关闭，显式 [leading] 不受影响。
  final bool showBackButton;

  /// 是否显示底部 1px 分割线。默认 true（沿用全局 appBarTheme 的 shape）；
  /// 设为 false 时显式用空 Border 覆盖主题 shape，得到无边框 AppBar。
  final bool showBottomBorder;

  @override
  Size get preferredSize => const Size.fromHeight(AppTheme.toolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: backgroundColor,
      title: titleWidget ?? (title != null ? Text(title!) : null),
      titleSpacing: titleWidget != null ? 0 : null,
      automaticallyImplyLeading: false,
      leading: leading ??
          (showBackButton
              ? IconButton(
                  icon: const Icon(CupertinoIcons.chevron_left),
                  onPressed: onBack ?? () => context.pop(),
                )
              : null),
      leadingWidth: leadingWidth,
      actions: actions,
      shape: showBottomBorder ? null : const Border(),
    );
  }
}
