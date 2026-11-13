import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery_host.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import 'community_market_providers.dart';
import '../digital_employee/services/digital_employee_service.dart';

class CommunityEmployeeGallery extends ConsumerWidget {
  const CommunityEmployeeGallery({
    super.key,
    this.filterTrailing,
    this.galleryKey,
  });

  final Widget? filterTrailing;
  final GlobalKey<DigitalEmployeeGalleryHostState>? galleryKey;

  Future<void> _add(
      BuildContext context, WidgetRef ref, AgentItem template) async {
    final connection = AppConfig.connectionEpoch;
    final confirmed = await showUiConfirmDialog(
      context,
      title: '添加到当前服务器',
      description:
          '将“${template.displayName}”的名称、简介和角色提示复制到当前服务器，使用服务器配置的运行时。模板所需技能和外部应用需另行配置。',
      confirmLabel: '添加',
    );
    if (!confirmed ||
        !context.mounted ||
        connection != AppConfig.connectionEpoch) {
      return;
    }
    final close = BotToast.showLoading();
    try {
      final agent = await ref.read(chatServiceProvider).createAgent(
            name: template.name,
            description: template.description,
            welcomeMsg: template.welcomeMsg,
            systemPrompt: template.systemPrompt,
            tags: template.tags,
            avatarUrl: template.avatarUrl,
            positionLabel: template.positionLabel,
            visibility: 'private',
            status: 'published',
          );
      if (!context.mounted || connection != AppConfig.connectionEpoch) return;
      ref.invalidate(agentsProvider);
      ref.invalidate(digitalEmployeeCatalogProvider);
      BotToast.showText(text: '已添加 ${agent.displayName}，可在“我的”中查看');
    } catch (_) {
      BotToast.showText(text: '添加失败，请检查当前服务器的运行时配置后重试');
    } finally {
      close();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keyword = ref.watch(digitalEmployeeSearchProvider).toLowerCase();
    final catalog = ref.watch(communityEmployeesProvider);
    final templates = [
      for (final agent in catalog.value ?? const <AgentItem>[])
        if ('${agent.name} ${agent.description} ${agent.tags.join(' ')}'
            .toLowerCase()
            .contains(keyword))
          agent,
    ];
    final serverCatalog = ref.watch(digitalEmployeeCatalogProvider).value;
    final filter = ref.watch(digitalEmployeeFilterProvider);
    final needsPublic = filter == DigitalEmployeeCatalogFilter.all ||
        filter == DigitalEmployeeCatalogFilter.platform;
    if (catalog.isLoading &&
        !catalog.hasValue &&
        needsPublic &&
        (serverCatalog?.all.isEmpty ?? true)) {
      return const DigitalEmployeeGallerySkeleton(mobile: false);
    }
    return Column(
      children: [
        if (catalog.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Expanded(child: Text('公共数字员工加载失败，请检查网络后重试')),
                TextButton(
                  onPressed: () => ref.invalidate(communityEmployeesProvider),
                  child: const Text('重试公共目录'),
                ),
              ],
            ),
          ),
        Expanded(
          child: DigitalEmployeeGalleryHost(
            key: galleryKey,
            mobile: false,
            filterTrailing: filterTrailing,
            publicTemplates: templates,
            publicTemplatesLoading: catalog.isLoading,
            onAddPublicTemplate: (agent) => _add(context, ref, agent),
          ),
        ),
      ],
    );
  }
}
