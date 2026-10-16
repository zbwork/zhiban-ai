import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/layout/models/main_nav_item.dart';
import 'package:zhiban_client/layout/session_layout.dart';
import 'widgets/desktop_sidebar.dart';

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  @override
  Widget build(BuildContext context) =>
      SessionLayout(builder: (context, unreadCount) {
        _syncChatRouteActive(context);
        return Scaffold(
            body: Row(children: [
          DesktopSidebar(
              navItems: mainNavItems
                  .where((item) => item.path != RoutePaths.settings)
                  .toList(),
              chatUnreadCount: unreadCount),
          Expanded(child: widget.child),
        ]));
      });

  /// 按当前路由是否落在 /chat 子树上，同步 [isChatRouteActiveProvider]。
  /// 不能直接在 build() 里写 provider（Riverpod 不允许 build 期间改状态），
  /// 用 addPostFrameCallback 延到这一帧画完之后再写；只有值真的变化才写，
  /// 避免每次 build 都触发一次无意义的 notifyListeners。
  void _syncChatRouteActive(BuildContext context) {
    // 移动端不在这里维护 isChatRouteActiveProvider：/chat/conversation 是
    // app_router.dart 里 ShellRoute 外面的顶层全屏路由，MainLayout（连同这个
    // ShellRoute 页面）只是被那个路由压在下面，并没有卸载——它自己的
    // GoRouterState.of(context) 永远只反映 ShellRoute 内部的路由（`/chat` 列表
    // 页那一层），压根看不到上面盖着的 /chat/conversation。之前这里按平台分叉
    // 判断，移动端分支因此实际上只会算出 false；而 MainLayout 只要因为未读数
    // 之类的 ref.watch 变化重建（新消息一来就会），就会把这个 false 写回去，
    // 跟 MobileConversationDetailPage 自己在 initState/dispose 里维护的 true
    // 互相打架——刚进会话详情页设的 true 立刻被这里的重建冲掉，导致移动端
    // "正在看这个会话"永远探测不到（2026-08-28 反馈：仍在震动、返回列表仍显示
    // 未读）。移动端的这个 provider 现在完全交给
    // MobileConversationDetailPage 独占维护，这里只处理桌面。
    if (!PlatformUtils.isDesktop) return;
    final location = GoRouterState.of(context).matchedLocation;
    // 桌面 /chat 是常驻的"列表 + 会话详情"分栏面板，进这个路由就等于在看
    // activeConversationId 那个会话。
    final isChat = location == RoutePaths.chat ||
        location.startsWith('${RoutePaths.chat}/');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(isChatRouteActiveProvider);
      if (current != isChat) {
        ref.read(isChatRouteActiveProvider.notifier).state = isChat;
        // 从别的 tab 切回对话页时主动补一次已读上报：如果当前 active 会话在
        // 离开对话页期间收到过新消息，之前唯一能清它的 _maybeAppendIncoming
        // 只在"检测到会话列表有新变化"这个事件触发时才会跑，光是切回 tab
        // 本身不算这种事件——导致停留在已经是 active 的那个会话上也不会消红点，
        // 切到别的会话时才会看见它一直没清过的未读突然冒出来（2026-08-25 实测）。
        if (isChat) {
          ref.read(chatProvider.notifier).markActiveConversationRead();
        }
      }
    });
  }
}
