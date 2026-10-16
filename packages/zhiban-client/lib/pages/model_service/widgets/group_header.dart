import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 按分组展示模型列表时的标题行：展开/折叠箭头 + 分组名 + 数量徽标，尾部
/// 可选一个操作 widget（比如"添加模型"抽屉里的"添加本组全部"按钮）。
/// "添加模型"抽屉和"已添加模型"列表共用同一套视觉
/// (2026-08-27 反馈：已添加列表也要跟添加模型抽屉一样按分组展示)。
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.label,
    this.count,
    required this.collapsed,
    required this.onToggle,
    this.trailing,
    this.filled = false,
  });

  final String label;

  /// 数量徽标，为 null 时不渲染（参考样式里"已添加模型"列表的分组标题不带
  /// 数量）。
  final int? count;
  final bool collapsed;
  final VoidCallback onToggle;
  final Widget? trailing;

  /// 整行铺一层浅底色——"已添加模型"列表用这个样式，"添加模型"抽屉里筛选出
  /// 来的分组维持原来的无底色样式，两者共用同一个组件但视觉各自贴自己的
  /// 参考图(2026-08-27 反馈：已添加列表要参考截图里带底色的分组样式)。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? CupertinoIcons.chevron_right
                      : CupertinoIcons.chevron_down,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
    if (!filled) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: row);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: row,
    );
  }
}
