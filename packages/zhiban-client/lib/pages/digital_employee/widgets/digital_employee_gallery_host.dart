import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/create_agent_dialog.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';

/// 数字员工桌面页与移动页共享的业务宿主。
///
/// 页面壳由两端分别实现；刷新、创建、编辑和打开会话只保留这一份。
class DigitalEmployeeGalleryHost extends ConsumerStatefulWidget {
  const DigitalEmployeeGalleryHost({
    super.key,
    required this.mobile,
    this.mobileFilterEnabled = true,
    this.filterTrailing,
    this.refreshCatalogOnMount = true,
  });

  final bool mobile;
  final bool mobileFilterEnabled;
  final Widget? filterTrailing;
  final bool refreshCatalogOnMount;

  @override
  ConsumerState<DigitalEmployeeGalleryHost> createState() =>
      DigitalEmployeeGalleryHostState();
}

class DigitalEmployeeGalleryHostState
    extends ConsumerState<DigitalEmployeeGalleryHost> {
  final _galleryKey = GlobalKey<OpenClawDigitalEmployeeGalleryState>();

  @override
  void initState() {
    super.initState();
    if (!widget.refreshCatalogOnMount) return;
    // provider 在会话期保留旧目录，切换菜单返回时先继续展示旧卡片，再后台拉取
    // /contacts/agents 对账。首次进入若 build 尚在加载则不发第二份重复请求。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(digitalEmployeeCatalogProvider);
      if (current.hasValue || current.hasError) {
        unawaited(
          ref.read(digitalEmployeeCatalogProvider.notifier).refresh(
                keepPreviousOnError: true
              ),
        );
      }
    });
  }

  Future<void> createAgent() async {
    await _galleryKey.currentState?.createAgent();
  }

  @override
  Widget build(BuildContext context) {
    return OpenClawDigitalEmployeeGallery(
      key: _galleryKey,
      mobile: widget.mobile,
      mobileFilterEnabled: widget.mobileFilterEnabled,
      filterTrailing: widget.filterTrailing,
      requestCreateAgentDraft: (ctx) => widget.mobile
          ? ctx.push<CreateAgentDraft>(
              RoutePaths.createAgent,
              extra: const CreateAgentPageArgs(),
            )
          : showDialog<CreateAgentDraft>(
              context: rootNavigatorKey.currentContext ?? ctx,
              builder: (_) => const CreateAgentDialog(),
            ),
      requestEditAgentDraft: (ctx, agent) {
        final args = CreateAgentPageArgs(
          title: '编辑数字员工',
          submitLabel: '保存数字员工',
          agentId: agent.agentId,
          enableDeleteAction: false,
          initialDraft: CreateAgentDraft.fromAgentItem(agent),
        );
        if (widget.mobile) {
          return ctx.push<CreateAgentDraft>(
            RoutePaths.createAgent,
            extra: args,
          );
        }
        return showDialog<CreateAgentDraft>(
          context: rootNavigatorKey.currentContext ?? ctx,
          builder: (_) => CreateAgentDialog(
            initialDraft: args.initialDraft,
            title: args.title,
            submitLabel: args.submitLabel,
            enableDeleteAction: args.enableDeleteAction,
            agentId: args.agentId,
          ),
        );
      },
      showToast: (message) => BotToast.showText(text: message),
      onOpenConversation: (conversationId, agent) async {
        ref.read(selectedHumanDirectProvider.notifier).state = null;
        ref.read(selectedGroupProvider.notifier).state = null;
        ref.read(selectedAgentProvider.notifier).select(agent);
        await ref.read(chatProvider.future);
        await ref
            .read(chatProvider.notifier)
            .selectConversation(conversationId);
        if (!mounted) return;
        if (widget.mobile) {
          this.context.push(RoutePaths.chatConversation);
          return;
        }
        this.context.go(RoutePaths.chat);
      },
    );
  }
}
