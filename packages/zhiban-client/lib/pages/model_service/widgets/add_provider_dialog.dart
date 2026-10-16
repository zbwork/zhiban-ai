import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

class NewProviderInput {
  const NewProviderInput({
    required this.name,
    required this.baseUrl
  });

  final String name;
  final String baseUrl;
}

/// 新增一个「目录里没有」的自定义服务商。内置目录里的厂商默认就在左侧列表，
/// 不需要走这个入口——这里只用于完全自定义/私有部署的服务地址。
Future<NewProviderInput?> showAddProviderDialog(BuildContext context) {
  return showDialog<NewProviderInput>(
    context: context,
    builder: (_) => const _AddProviderDialog(),
  );
}

class _AddProviderDialog extends StatefulWidget {
  const _AddProviderDialog();

  @override
  State<_AddProviderDialog> createState() => _AddProviderDialogState();
}

class _AddProviderDialogState extends State<_AddProviderDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  String? _nameError;
  String? _baseUrlError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _baseUrlController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    final nameError = name.isEmpty ? '请输入服务商名称' : null;
    final baseUrlError = baseUrl.isEmpty ? '请输入 API 地址' : null;

    if (nameError != null || baseUrlError != null) {
      setState(() {
        _nameError = nameError;
        _baseUrlError = baseUrlError;
      });
      return;
    }

    Navigator.of(context).pop(
      NewProviderInput(
        name: name,
        baseUrl: baseUrl
      )
    );
  }

  void _clearNameError(String _) {
    if (_nameError == null) return;
    setState(() => _nameError = null);
  }

  void _clearBaseUrlError(String _) {
    if (_baseUrlError == null) return;
    setState(() => _baseUrlError = null);
  }

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      size: UiDialogSize.standard,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(
              title: '添加自定义服务商',
              subtitle: '内置目录里的厂商已经在左侧列表，这里只用于目录之外的自定义地址',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
            UiInputField(
              label: '名称',
              controller: _nameController,
              hintText: '服务商名称',
              errorText: _nameError,
              onChanged: _clearNameError,
            ),
            const SizedBox(height: 14),
            UiInputField(
              label: 'API 地址',
              controller: _baseUrlController,
              hintText: 'https://api.example.com',
              errorText: _baseUrlError,
              onChanged: _clearBaseUrlError,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}

/// provider-list 场景下需要缩小而不是放大的图标——本身已经是满铺方形背景，
/// 照抄 Cherry Studio `iconDisplayConfig.ts` 的 `providerListContainedIcon` 名单。
const _kShrinkIconKeys = <String>{
  'cherryin',
  'aihubmix',
  'lmstudio',
  'anthropic',
  'zero-one',
  'groq',
  'aws-bedrock',
  // simple-icons 的 Qwen 标是贴着 24x24 viewBox 边缘画的品牌标，没有内边距，
  // 跟其余厂商图标"只占 viewBox ~54%"的情况相反——放大 1.2 倍会直接溢出图标
  // 槽位，跟旁边的模型名文字挤在一起(2026-08-27 反馈：icon 大小不对)。
  'qwen',
};

/// 厂商小图标：有目录 Logo 就渲染 SVG，没有就回退到首字母色块。
class ProviderIcon extends StatelessWidget {
  const ProviderIcon({
    super.key,
    required this.iconAssetPath,
    required this.name,
    this.size = 26,
  });

  final String? iconAssetPath;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (iconAssetPath == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(size * 0.2),
        ),
        child: Text(
          name.isEmpty ? '?' : name.characters.first,
          style: TextStyle(
            fontSize: size * 0.45,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
      );
    }
    // 照抄 Cherry Studio `iconDisplayConfig.ts` 里 provider-list 场景的配置：
    // 大多数图标自带内边距（比如 302.AI 的圆形只占 viewBox 的 54%），所以默认
    // 放大 1.2 倍去填满容器；但有一小撮图标本身就是满铺方形背景（Anthropic 那
    // 种直接画了个 0,0-120,120 纯色矩形），再放大只会把方角顶出裁切框，这几个
    // 反而要缩到 5/7，其余保持不变——这份名单是照抄来的，不是我们自己算的。
    final iconKey = iconAssetPath!.split('/').last.replaceFirst('.svg', '');
    final scale = _kShrinkIconKeys.contains(iconKey) ? 5 / 7 : 1.2;
    // 圆角必须贴着"缩放后真正画出来的那个方块"裁，不能贴着外层 size 裁：
    // scale<1 时图标本身比外层框小一圈，裁外层框只会裁到透明区域，图标自己
    // 那个有实色背景的方角完全露在裁切范围之外，等于没裁。
    final iconSize = size * scale;
    return SizedBox(
      width: size,
      height: size,
      child: OverflowBox(
        // 缩小场景（scale < 1）时目标尺寸比外层 SizedBox 传来的 tight 约束
        // 还小，必须显式把 min 归零，否则 OverflowBox 只覆盖 max、min 还留在
        // 外层的 size，会拼出 min > max 的非法约束（NOT NORMALIZED 崩溃）。
        minWidth: 0,
        minHeight: 0,
        maxWidth: iconSize,
        maxHeight: iconSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(iconSize * 0.2),
          child: SvgPicture.asset(
            package: ClientAssets.packageName,
            iconAssetPath!,
            width: iconSize,
            height: iconSize,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
