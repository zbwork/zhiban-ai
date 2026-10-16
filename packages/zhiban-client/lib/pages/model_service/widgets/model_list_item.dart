import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/ai_model_config.dart';
import '../services/model_modality_classifier.dart';

class ModelListItem extends StatelessWidget {
  const ModelListItem({
    super.key,
    required this.model,
    required this.onEdit,
    required this.onRemove,
    this.leading,
    this.availabilityNote,
    this.showBottomDivider = true,
  });

  final AiModelConfig model;

  /// 点设置图标才触发编辑——整行不再是可点区域，避免跟"移除"误触
  /// (2026-08-27 反馈：点击效果只挂在设置图标上)。
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  /// 厂商/分组 Logo（跟"添加模型"列表同一套 [ProviderIcon] + 分组图标解析
  /// 逻辑），不传就不占位置。
  final Widget? leading;
  final String? availabilityNote;

  /// 最后一行由外层列表容器提供底边框，避免两条线叠加变深。
  final bool showBottomDivider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 分类徽标要显示，但"文本"是绝大多数模型的默认兜底分类，每行都标一遍纯属
    // 噪音——只在猜出图片/嵌入/音频/视频/重排这些有信息量的分类时才显示
    // (2026-08-27 反馈：类型 tag 要显示，但不要文本 tag)。
    final modality = classifyModelId(model.modelId);
    final showModality = modality != ModelModality.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: showBottomDivider
            ? Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
              )
            : null,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 10)
          ],
          Expanded(
            child: Text(
              model.displayName.isEmpty ? model.modelId : model.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (availabilityNote != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(availabilityNote!,
                  style:
                      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            ),
          if (showModality)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: modality.label,
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(modality.icon,
                      size: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          for (final capability in model.capabilities)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: capability.label,
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: capability.badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(capability.icon,
                      size: 12, color: capability.badgeColor),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: IconButton(
              visualDensity: VisualDensity.compact,
              splashRadius: 16,
              onPressed: onEdit,
              icon: Icon(
                CupertinoIcons.gear_alt,
                size: 17,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              tooltip: '设置',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: IconButton(
              visualDensity: VisualDensity.compact,
              splashRadius: 16,
              onPressed: onRemove,
              icon: Icon(
                CupertinoIcons.minus,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              tooltip: '移除模型',
            ),
          ),
        ],
      ),
    );
  }
}
