// F16 FE-03b · 全局通话浮层 (飞书桌面质感)。
//
// 挂在 MainLayout 的 Stack 顶层，跟随 [rtcCallControllerProvider] 状态渲染:
//   - incomingRinging         → 来电卡（接听绿 / 拒接红）
//   - outgoingRinging/connecting → 呼叫中条（取消红 + 三点动画）
//   - active                  → 通话中条（时长 + 静音 + 挂断红）
// 顶部居中浮层；圆角、轻阴影、紧凑；不遮挡输入框主区。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/add_group_members_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:window_manager/window_manager.dart';

import '../dingrtc_video_view.dart';
import '../rtc_call_controller.dart';
import '../rtc_client.dart';
import '../rtc_native_meeting_window.dart' show RtcMeetingLayout;
import '../rtc_platform_capabilities.dart';

// 克制配色。
const Color _kAccept = Color(0xFF34C759); // 接听绿
const Color _kDanger = Color(0xFFFF3B30); // 拒接 / 取消 / 挂断红
const Color _kCallBlue = Color(0xFF2563EB); // 通话态蓝（品牌色）

/// FE-03 延伸 · 窗口内通话热键映射 (纯函数, 便于单测)。
/// 仅在「有通话」时拦截 Enter/Esc; idle 返回 none → 不影响输入框回车发送。
enum RtcHotkeyAction { none, accept, reject, cancelOutgoing, hangUp }

RtcHotkeyAction rtcHotkeyFor(RtcCallPhase phase, LogicalKeyboardKey key) {
  final isEnter =
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;
  final isEsc = key == LogicalKeyboardKey.escape;
  switch (phase) {
    case RtcCallPhase.incomingRinging:
      if (isEnter) return RtcHotkeyAction.accept; // 回车接听
      if (isEsc) return RtcHotkeyAction.reject; // Esc 拒接
      return RtcHotkeyAction.none;
    case RtcCallPhase.outgoingRinging:
      if (isEsc) return RtcHotkeyAction.cancelOutgoing; // 呼叫中 Esc 取消
      return RtcHotkeyAction.none;
    case RtcCallPhase.connecting:
    case RtcCallPhase.active:
      if (isEsc) return RtcHotkeyAction.hangUp; // 已接通 Esc 挂断
      return RtcHotkeyAction.none;
    case RtcCallPhase.ending:
    case RtcCallPhase.error:
    case RtcCallPhase.idle:
      return RtcHotkeyAction.none; // 不拦截，Enter 留给输入框发送
  }
}

/// 全局来电/呼叫/通话浮层宿主。作为 MainLayout Stack 的子节点。
class RtcCallOverlayHost extends ConsumerStatefulWidget {
  const RtcCallOverlayHost({super.key, this.desktopContentLeftInset = 0});

  /// 桌面端聊天主内容区左缘（= 导航栏 176 + 会话列表 240 = 416）。
  /// 主叫呼叫卡在此 inset 右侧的内容区内居中，避免落到侧栏/会话列表上。
  final double desktopContentLeftInset;

  @override
  ConsumerState<RtcCallOverlayHost> createState() => _RtcCallOverlayHostState();
}

class _RtcCallOverlayHostState extends ConsumerState<RtcCallOverlayHost> {
  StreamSubscription<void>? _inviteSub;
  bool _compactOutgoingMinimized = false;
  String? _compactOutgoingCallUuid;
  bool _meetingMinimized = false;
  String? _meetingMinimizedCallUuid;
  // 常驻的内嵌 Navigator (见 build() 里的挂载注释)：选人页/错误弹框在移动端全屏
  // 会议中要弹在会议壳之上又不遮挡通话本身，靠它而不是 rootNavigatorKey。
  final GlobalKey<NavigatorState> _inlineNavigatorKey =
      GlobalKey<NavigatorState>();
  // Navigator/Overlay 即使当前路由是零尺寸 SizedBox.shrink()，仍会在 Positioned.fill
  // 范围内整块吃掉命中测试——不加这个开关，常驻挂着的空 Navigator 会让底下会议壳
  // (含"…"菜单按钮) 全部点不动。只有真的 push 了选人页/弹框时才放开命中测试。
  bool _inlineNavigatorBusy = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _inviteSub = ref.read(rtcCallControllerProvider).inviteRequests.listen((_) {
      if (mounted) unawaited(_handleInviteRequest());
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _inviteSub?.cancel();
    super.dispose();
  }

  /// 窗口内热键: 仅在有通话时拦截 (返回 true=已消费)，否则放行给输入框。
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final c = ref.read(rtcCallControllerProvider);
    if (!c.hasActiveCall) return false;
    switch (rtcHotkeyFor(c.phase, e.logicalKey)) {
      case RtcHotkeyAction.accept:
        c.acceptIncoming();
        return true;
      case RtcHotkeyAction.reject:
        c.rejectIncoming();
        return true;
      case RtcHotkeyAction.cancelOutgoing:
        c.cancelOutgoing();
        return true;
      case RtcHotkeyAction.hangUp:
        c.hangUp();
        return true;
      case RtcHotkeyAction.none:
        return false;
    }
  }

  Future<void> _handleInviteRequest() async {
    final controller = ref.read(rtcCallControllerProvider);
    final roomUuid = controller.roomUuid ?? '';
    if (!controller.canInviteParticipants || roomUuid.isEmpty) {
      await _showInviteErrorDialog('当前会议暂不能邀请参会人');
      return;
    }
    Set<String> existing = const <String>{};
    try {
      final detail = await RoomsService().getGroupRoom(roomUuid);
      existing = {
        for (final m in detail.members)
          if (m.id.isNotEmpty) m.id,
      };
    } catch (e) {
      await _showInviteErrorDialog('读取群成员失败:$e');
      return;
    }
    if (!mounted) return;
    // macOS 会议是独立原生窗口，跟主 App 窗口是两个 OS 级窗口；选人弹框开在主
    // App 窗口里，不把主窗口提到前台的话会被会议窗口挡住，看起来像"弹框在下面"。
    // 移动端没有独立窗口，这一步是 no-op。
    await _bringAppWindowToFront();
    try {
      final AddGroupMembersResult? picked;
      if (PlatformUtils.isMobile) {
        // 移动端会议是全屏 app 内 Flutter 壳，跟 GoRouter 的 Navigator 是平级
        // sibling——选人页面若走 rootNavigatorKey push 会被会议壳整个盖住看不见。
        // 改用挂在这层会议 Overlay 自己 Stack 里的 _inlineNavigatorKey（见 build()），
        // 保证选人页面渲染层级一定盖在会议壳之上，且不用把通话收起来。
        picked = await _pickGroupMembersInline(existing);
      } else {
        // RtcCallOverlayHost 挂在 MaterialApp.router builder 的自建 Overlay 里，
        // 跟 GoRouter 的 Navigator 是平级 sibling，不是它的后代——本地 context 没有
        // Navigator 祖先，showDialog/Navigator.push 会直接抛
        // "context that does not include a Navigator"。改用 rootNavigatorKey 拿一个
        // 真正在 Navigator 子树里的 context（桌面端没有会议壳挡住弹框的问题）。
        final navContext = rootNavigatorKey.currentContext;
        if (navContext == null || !navContext.mounted) return;
        picked = await pickGroupMembers(
          navContext,
          existingMemberIds: existing,
          mobile: false,
        );
      }
      if (picked == null || picked.total == 0) return;
      try {
        await RoomsService().addGroupParticipants(
          roomUuid: roomUuid,
          accountUuids: picked.accountUuids,
          agentUuids: picked.agentUuids,
        );
        // ignore: discarded_futures
        ref.read(conversationsProvider.notifier).refresh();
        if (picked.accountUuids.isNotEmpty) {
          await controller.inviteParticipants(
            picked.accountUuids,
            showErrorToast: false,
          );
        }
        if (picked.agentUuids.isNotEmpty) {
          await _showInviteErrorDialog('数字员工已添加到群聊，当前会议暂不支持自动入会');
        }
      } catch (e) {
        await _showInviteErrorDialog('邀请参会人失败:$e');
      }
    } finally {
      // _bringAppWindowToFront 为了让选人弹框显示在最前，把主 App 窗口提到了
      // macOS 独立会议窗口前面；选人流程结束后（不管选没选、邀请成功与否）
      // 必须把会议窗口带回前台，否则看起来像"邀完人会议弹框消失了"。
      controller.returnToMeeting();
    }
  }

  /// 移动端选人：push 到常驻的 [_inlineNavigatorKey]（跟会议壳同一层 Stack），
  /// 而不是 rootNavigatorKey 对应的 GoRouter Navigator——否则会被全屏会议壳盖住。
  Future<AddGroupMembersResult?> _pickGroupMembersInline(
      Set<String> existing) async {
    final nav = _inlineNavigatorKey.currentState;
    if (nav == null) return null;
    setState(() => _inlineNavigatorBusy = true);
    try {
      return await nav.push<AddGroupMembersResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => AddGroupMembersDialog(
            existingMemberIds: existing,
            mobile: true
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _inlineNavigatorBusy = false);
    }
  }

  Future<void> _bringAppWindowToFront() async {
    if (!PlatformUtils.isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // best-effort：拿不到窗口句柄也不阻断弹框本身。
    }
  }

  Future<void> _showInviteErrorDialog(String message) async {
    if (!mounted) return;
    await _bringAppWindowToFront();
    Widget buildDialog(BuildContext ctx) => AlertDialog(
          title: const Text('邀请参会人'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
    if (PlatformUtils.isMobile) {
      // 同 _pickGroupMembersInline：走会议壳自己的 _inlineNavigatorKey，不然错误
      // 弹框会被全屏会议壳盖住看不见。
      final ctx = _inlineNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      setState(() => _inlineNavigatorBusy = true);
      try {
        await showDialog<void>(
          context: ctx,
          useRootNavigator: false,
          builder: buildDialog,
        );
      } finally {
        if (mounted) setState(() => _inlineNavigatorBusy = false);
      }
      return;
    }
    final navContext = rootNavigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    await showDialog<void>(context: navContext, builder: buildDialog);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(rtcCallControllerProvider);
    return Stack(
      children: [
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            // 统一会议模型：active 或群会议本端已入会 → 进会议。audio/video 同一壳（audio = cameraOff 的会议）。
            // macOS 原生独立会议窗口显示成功 → app 内只显示轻量状态条；否则 → app 内会议壳 fallback。
            if (controller.meetingActive) {
              if (controller.nativeMeetingVisible) {
                return _positioned(context, RtcCallPhase.active,
                    _animatedIn(_MeetingStatusBar(controller: controller)));
              }
              final compact = MediaQuery.of(context).size.width < 720;
              final callUuid = controller.callUuid;
              if (_meetingMinimizedCallUuid != callUuid) {
                _meetingMinimizedCallUuid = callUuid;
                _meetingMinimized = false;
              }
              if (compact && _meetingMinimized) {
                return DraggableCallSurface(
                  padding: const EdgeInsets.fromLTRB(12, 56, 12, 24),
                  initialAlignment: Alignment.topRight,
                  child: _MinimizedActiveCallPill(
                    controller: controller,
                    onRestore: () => setState(() => _meetingMinimized = false),
                  ),
                );
              }
              return _VideoMeetingShell(
                controller: controller,
                contentLeftInset: compact ? 0 : widget.desktopContentLeftInset,
                compact: compact,
                onMinimize: compact
                    ? () => setState(() => _meetingMinimized = true)
                    : null,
              );
            }
            // 被叫来电：macOS 原生独立浮窗显示时，app 内不再重复来电卡（避免两个来电卡）。
            if (controller.phase == RtcCallPhase.incomingRinging &&
                !controller.inAppIncomingVisible) {
              return const SizedBox.shrink();
            }
            // 移动端来电：全屏接听页（原生电话体验），不用桌面那套小卡片。
            if (controller.phase == RtcCallPhase.incomingRinging &&
                PlatformUtils.isMobile) {
              return _FullScreenIncomingCallView(controller: controller);
            }
            // 来电/呼叫/接通中 → 小卡片（飞书质感、不贴顶、可拖动）。
            final compact = MediaQuery.of(context).size.width < 720;
            final compactOutgoing = compact &&
                (controller.phase == RtcCallPhase.outgoingRinging ||
                    controller.phase == RtcCallPhase.connecting);
            if (compactOutgoing) {
              final callUuid = controller.callUuid;
              if (_compactOutgoingCallUuid != callUuid) {
                _compactOutgoingCallUuid = callUuid;
                _compactOutgoingMinimized = false;
              }
              if (_compactOutgoingMinimized) {
                return DraggableCallSurface(
                  padding: const EdgeInsets.fromLTRB(12, 56, 12, 24),
                  initialAlignment: Alignment.topRight,
                  child: _MinimizedOutgoingCallPill(
                    controller: controller,
                    onRestore: () =>
                        setState(() => _compactOutgoingMinimized = false),
                  ),
                );
              }
              return _CompactOutgoingCallScreen(
                controller: controller,
                onMinimize: () =>
                    setState(() => _compactOutgoingMinimized = true),
              );
            }
            final card = _cardFor(controller, compact);
            if (card == null) return const SizedBox.shrink();
            return _positioned(context, controller.phase, _animatedIn(card));
          },
        ),
        // 常驻内嵌 Navigator：选人页/错误弹框要用它 push 时见
        // _pickGroupMembersInline / _showInviteErrorDialog——渲染层级排在上面这个
        // ListenableBuilder 之后，保证一定盖在会议全屏壳之上；同时它是
        // RtcCallOverlayHost 自己 Stack 里的真实 Navigator 祖先，
        // AddGroupMembersDialog/AlertDialog 内部的 Navigator.pop 能就地正确关闭，
        // 不用像 rootNavigatorKey 那样绕远路。
        // IgnorePointer 必须加：即使当前路由是零尺寸 SizedBox.shrink()，
        // Positioned.fill 范围内的 Navigator/Overlay 仍会整块吃掉命中测试——不加
        // 这层，常驻挂着的空 Navigator 会让底下会议壳(含"…"菜单按钮)全部点不动；
        // 只有真的 push 了选人页/弹框 (_inlineNavigatorBusy) 时才放开命中测试。
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_inlineNavigatorBusy,
            child: Navigator(
              key: _inlineNavigatorKey,
              onGenerateRoute: (_) => PageRouteBuilder(
                opaque: false,
                pageBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget? _cardFor(RtcCallController c, bool compact) {
    switch (c.phase) {
      case RtcCallPhase.incomingRinging:
        return _IncomingCallCard(controller: c);
      case RtcCallPhase.outgoingRinging:
      case RtcCallPhase.connecting:
        return _OutgoingCallCard(controller: c, compact: compact);
      case RtcCallPhase.active: // active 由会议壳 / 状态条接管（build 内处理）
      case RtcCallPhase.ending:
      case RtcCallPhase.error:
      case RtcCallPhase.idle:
        return null;
    }
  }

  /// 入场轻动效（缩放 + 淡入）。
  Widget _animatedIn(Widget card) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.96, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, v, child) => Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.scale(scale: v, child: child),
        ),
        child: card,
      );

  /// 按相位放置可拖动浮层（不贴顶）：
  /// - incoming → 顶部居中（mobile）/ 右上角（desktop）。
  /// - active 状态条 → 聊天主内容区右上角，小胶囊，不挡输入框。
  /// - outgoing / connecting → 顶部居中（desktop 用 desktopContentLeftInset 把居中区
  ///   限定在导航栏+会话列表右侧；compact 全宽居中）。
  Widget _positioned(BuildContext context, RtcCallPhase phase, Widget card) {
    final compact = MediaQuery.of(context).size.width < 720; // 窄窗 / 移动近似
    final inset = compact ? 0.0 : widget.desktopContentLeftInset;
    switch (phase) {
      case RtcCallPhase.incomingRinging:
        return DraggableCallSurface(
          padding: compact
              ? const EdgeInsets.fromLTRB(12, 56, 12, 24)
              : EdgeInsets.fromLTRB(inset + 12, 56, 28, 24),
          initialAlignment:
              compact ? const Alignment(0, -1) : Alignment.topRight,
          child: card,
        );
      case RtcCallPhase.active:
        return DraggableCallSurface(
          padding: compact
              ? const EdgeInsets.fromLTRB(12, 56, 12, 24)
              : EdgeInsets.fromLTRB(inset + 12, 68, 24, 24),
          initialAlignment: Alignment.topRight,
          child: card,
        );
      case RtcCallPhase.outgoingRinging:
      case RtcCallPhase.connecting:
        return DraggableCallSurface(
          padding: EdgeInsets.fromLTRB(inset + 12, 56, 12, 24),
          initialAlignment: const Alignment(0, -1),
          child: card,
        );
      case RtcCallPhase.ending:
      case RtcCallPhase.error:
      case RtcCallPhase.idle:
        return const SizedBox.shrink();
    }
  }
}

/// 可拖动浮层外壳：在 [padding] 限定的安全区内按 [initialAlignment] 摆放 [child]，
/// 鼠标拖动整张卡片并夹在安全区内；按钮点击不被拖拽吞掉（pan 与 tap 共存于手势竞技场）。
/// 每次通话重新挂载 → 拖拽位移自动复位到默认锚点。
class DraggableCallSurface extends StatefulWidget {
  const DraggableCallSurface({
    super.key,
    required this.child,
    required this.initialAlignment,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final Alignment initialAlignment;
  final EdgeInsets padding;

  @override
  State<DraggableCallSurface> createState() => _DraggableCallSurfaceState();
}

class _DraggableCallSurfaceState extends State<DraggableCallSurface> {
  Offset _offset = Offset.zero;
  final GlobalKey _childKey = GlobalKey();

  /// 把位移夹在安全区内：child 不得越出 [area] 减去其自身尺寸的可行范围。
  Offset _clamp(Offset next, Size area, Size child, Alignment a) {
    final freeW = (area.width - child.width).clamp(0.0, double.infinity);
    final freeH = (area.height - child.height).clamp(0.0, double.infinity);
    final baseX = freeW * (a.x + 1) / 2; // Align 决定的基准位置
    final baseY = freeH * (a.y + 1) / 2;
    return Offset(
      next.dx.clamp(-baseX, freeW - baseX),
      next.dy.clamp(-baseY, freeH - baseY),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Padding(
        padding: widget.padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                Align(
                  alignment: widget.initialAlignment,
                  child: Transform.translate(
                    offset: _offset,
                    child: GestureDetector(
                      behavior: HitTestBehavior.deferToChild,
                      onPanUpdate: (d) {
                        final sz = _childKey.currentContext?.size;
                        var next = _offset + d.delta;
                        if (sz != null) {
                          next =
                              _clamp(next, area, sz, widget.initialAlignment);
                        }
                        setState(() => _offset = next);
                      },
                      child: KeyedSubtree(key: _childKey, child: widget.child),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 浮层外壳：白底圆角 + 轻阴影 + 紧凑。
class _Shell extends StatelessWidget {
  const _Shell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E6EB)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// 圆形操作按钮（接听/拒接/取消/挂断/静音）。
class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
    this.enabled = true,
    this.size = 40,
    this.iconSize = 20,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  final bool enabled;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: enabled ? color : color.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: iconSize),
        ),
      ),
    );
    return Tooltip(message: tooltip, child: btn);
  }
}

class _IncomingCallCard extends StatelessWidget {
  const _IncomingCallCard({required this.controller});
  final RtcCallController controller;

  @override
  Widget build(BuildContext context) {
    final name = controller.peerName ?? '同事';
    final video = controller.isVideo;
    return _Shell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(
            child: ChatAvatar(
              url: controller.peerAvatarUrl,
              fallbackText: name,
              size: 48,
              kind: ChatAvatarKind.user,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('邀请你进行${video ? '视频' : '语音'}通话',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF86909C))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RoundActionButton(
            icon: CupertinoIcons.phone_down_fill,
            color: _kDanger,
            tooltip: '拒接',
            enabled: !controller.busy,
            onTap: () => controller.rejectIncoming(),
          ),
          const SizedBox(width: 10),
          _RoundActionButton(
            icon: video
                ? CupertinoIcons.video_camera_solid
                : CupertinoIcons.phone_fill,
            color: _kAccept,
            tooltip: '接听',
            enabled: !controller.busy,
            onTap: () => controller.acceptIncoming(),
          ),
        ],
      ),
    );
  }
}

/// 移动端来电全屏页（原生电话体验）：大头像居中 + 姓名 + 通话类型，底部拒接/接听
/// 大按钮左右分布、按钮下方带文字标签。不用 InkWell（项目约定）,水波纹/点击态用
/// GestureDetector + AnimatedOpacity 代替。
class _FullScreenIncomingCallView extends StatelessWidget {
  const _FullScreenIncomingCallView({required this.controller});
  final RtcCallController controller;

  @override
  Widget build(BuildContext context) {
    final name = controller.peerName ?? '同事';
    final video = controller.isVideo;
    return Positioned.fill(
      child: Material(
        color: _kMeetPanelBg,
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              ClipOval(
                child: ChatAvatar(
                  url: controller.peerAvatarUrl,
                  fallbackText: name,
                  size: 112,
                  kind: ChatAvatarKind.user,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: _kMeetText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '邀请你进行${video ? '视频' : '语音'}通话',
                style: const TextStyle(fontSize: 15, color: Color(0xFF86909C)),
              ),
              const Spacer(flex: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _FullScreenCallActionButton(
                      icon: CupertinoIcons.phone_down_fill,
                      color: _kDanger,
                      label: '拒绝',
                      enabled: !controller.busy,
                      onTap: () => controller.rejectIncoming(),
                    ),
                    _FullScreenCallActionButton(
                      icon: video
                          ? CupertinoIcons.video_camera_solid
                          : CupertinoIcons.phone_fill,
                      color: _kAccept,
                      label: '接听',
                      enabled: !controller.busy,
                      onTap: () => controller.acceptIncoming(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏来电页专用的大号圆形操作按钮（图标 + 下方文字标签）。
class _FullScreenCallActionButton extends StatefulWidget {
  const _FullScreenCallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_FullScreenCallActionButton> createState() =>
      _FullScreenCallActionButtonState();
}

class _FullScreenCallActionButtonState
    extends State<_FullScreenCallActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.enabled ? widget.onTap : null,
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: (widget.enabled ? widget.color : widget.color)
                  .withValues(alpha: widget.enabled ? (_pressed ? 0.82 : 1) : 0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 10),
          Text(widget.label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF86909C))),
        ],
      ),
    );
  }
}

/// 主叫呼叫卡（聊天主区中间偏上的竖向卡）：圆形头像 + 姓名 + 状态文案 + 红色取消按钮。
class _OutgoingCallCard extends StatelessWidget {
  const _OutgoingCallCard({required this.controller, this.compact = false});
  final RtcCallController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = controller.peerName ?? '同事';
    final connecting = controller.phase == RtcCallPhase.connecting;
    final video = controller.isVideo;
    // outgoingRinging → 取消(/cancel)；connecting(已答应) → 结束(/leave)，不能再 /cancel。
    final actionLabel = connecting ? '结束' : '取消';
    return Material(
      color: Colors.transparent,
      child: Container(
        width: compact ? double.infinity : 360,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E6EB)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x14000000),
                blurRadius: 24,
                offset: Offset(0, 10)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _kCallBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                  video
                      ? CupertinoIcons.video_camera_solid
                      : CupertinoIcons.phone_fill,
                  size: 30,
                  color: _kCallBlue),
            ),
            const SizedBox(height: 14),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1D2129))),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(connecting ? '接通中' : (video ? '正在发起视频通话' : '正在发起语音通话'),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF86909C))),
                const _AnimatedDots(color: Color(0xFF86909C)),
              ],
            ),
            const SizedBox(height: 22),
            _RoundActionButton(
              icon: CupertinoIcons.phone_down_fill,
              color: _kDanger,
              tooltip: actionLabel,
              enabled: connecting
                  ? controller.canHangUp
                  : controller.canCancelOutgoing,
              onTap: () => connecting
                  ? controller.hangUp()
                  : controller.cancelOutgoing(),
            ),
            const SizedBox(height: 6),
            Text(actionLabel,
                style: const TextStyle(fontSize: 12, color: Color(0xFF86909C))),
          ],
        ),
      ),
    );
  }
}

class _CompactOutgoingCallScreen extends StatelessWidget {
  const _CompactOutgoingCallScreen({
    required this.controller,
    required this.onMinimize,
  });

  final RtcCallController controller;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    final video = controller.isVideo;
    return Positioned.fill(
      child: Material(
        color: _kMeetPanelBg,
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    _MeetIconBtn(
                      icon: CupertinoIcons.chevron_down,
                      tooltip: '最小化',
                      onTap: onMinimize,
                    ),
                    const Spacer(),
                    Text(
                      video ? '视频通话' : '语音通话',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _kMeetText,
                      ),
                    ),
                    const Spacer(),
                    _MeetIconBtn(
                      icon: CupertinoIcons.phone_down_fill,
                      tooltip: controller.phase == RtcCallPhase.connecting
                          ? '结束'
                          : '取消',
                      color: _kDanger,
                      onTap: controller.phase == RtcCallPhase.connecting
                          ? controller.hangUp
                          : controller.cancelOutgoing,
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: _OutgoingCallCard(controller: controller),
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

class _MinimizedOutgoingCallPill extends StatelessWidget {
  const _MinimizedOutgoingCallPill({
    required this.controller,
    required this.onRestore,
  });

  final RtcCallController controller;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final video = controller.isVideo;
    final connecting = controller.phase == RtcCallPhase.connecting;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onRestore,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE5E6EB)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                video
                    ? CupertinoIcons.video_camera_solid
                    : CupertinoIcons.phone_fill,
                size: 17,
                color: _kCallBlue,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  connecting ? '接通中' : (video ? '正在视频呼叫' : '正在语音呼叫'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _kMeetText,
                  ),
                ),
              ),
              const _AnimatedDots(color: _kMeetSub),
              const SizedBox(width: 8),
              _RoundActionButton(
                icon: CupertinoIcons.phone_down_fill,
                color: _kDanger,
                tooltip: connecting ? '结束' : '取消',
                enabled: connecting
                    ? controller.canHangUp
                    : controller.canCancelOutgoing,
                onTap:
                    connecting ? controller.hangUp : controller.cancelOutgoing,
                size: 30,
                iconSize: 15,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 移动端会议最小化胶囊：会中标题栏点「最小化」后收起成小球，可拖动、点击恢复；
/// 挂断/静音仍可直接操作，不必先展开。
class _MinimizedActiveCallPill extends StatelessWidget {
  const _MinimizedActiveCallPill({
    required this.controller,
    required this.onRestore,
  });

  final RtcCallController controller;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final video = controller.isVideo;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onRestore,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE5E6EB)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                video
                    ? CupertinoIcons.video_camera_solid
                    : CupertinoIcons.phone_fill,
                size: 17,
                color: _kCallBlue,
              ),
              const SizedBox(width: 8),
              _CallDurationText(start: controller.connectedAt),
              const SizedBox(width: 8),
              _RoundActionButton(
                icon: controller.muted
                    ? CupertinoIcons.mic_slash_fill
                    : CupertinoIcons.mic_fill,
                color: controller.muted ? _kDanger : _kCallBlue,
                tooltip: controller.muted ? '取消静音' : '静音',
                onTap: () => controller.toggleMute(),
                size: 30,
                iconSize: 15,
              ),
              const SizedBox(width: 6),
              _RoundActionButton(
                icon: CupertinoIcons.phone_down_fill,
                color: _kDanger,
                tooltip: '挂断',
                enabled: controller.canEndMeeting,
                onTap: () => controller.hangUp(),
                size: 30,
                iconSize: 15,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 轻量通话状态条（macOS 独立会议窗口已显示时，主应用只留此条）：
/// 「语音/视频通话中 · 时长」+ 回到会议窗口 + 挂断。不遮挡输入框/header（右下角、可拖）。
class _MeetingStatusBar extends StatelessWidget {
  const _MeetingStatusBar({required this.controller});
  final RtcCallController controller;

  @override
  Widget build(BuildContext context) {
    final video = controller.isVideo;
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 48,
        constraints: const BoxConstraints(minWidth: 236, maxWidth: 292),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E6EB)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _kCallBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                video
                    ? CupertinoIcons.video_camera_solid
                    : CupertinoIcons.phone_fill,
                size: 15,
                color: _kCallBlue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      video ? '视频通话中' : '语音通话中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1D2129),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('·',
                      style: TextStyle(fontSize: 13, color: Color(0xFF86909C))),
                  const SizedBox(width: 6),
                  _CallDurationText(start: controller.connectedAt),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _StatusIconButton(
              icon: CupertinoIcons.arrow_up_left_arrow_down_right,
              color: _kCallBlue,
              tooltip: '回到会议窗口',
              onTap: () => controller.returnToMeeting(),
            ),
            const SizedBox(width: 6),
            _StatusIconButton(
              icon: CupertinoIcons.phone_down_fill,
              color: _kDanger,
              tooltip: '挂断',
              enabled: controller.canEndMeeting,
              onTap: () => controller.hangUp(),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIconButton extends StatelessWidget {
  const _StatusIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color:
            enabled ? color.withValues(alpha: 0.10) : const Color(0xFFF2F3F5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              icon,
              color: enabled ? color : const Color(0xFFC9CDD4),
              size: 17,
            ),
          ),
        ),
      ),
    );
  }
}

/// 通话时长 mm:ss，每秒刷新。
class _CallDurationText extends StatefulWidget {
  const _CallDurationText({required this.start});
  final DateTime? start;

  @override
  State<_CallDurationText> createState() => _CallDurationTextState();
}

class _CallDurationTextState extends State<_CallDurationText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.start;
    final secs = start == null
        ? 0
        : DateTime.now().difference(start).inSeconds.clamp(0, 86400);
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).toString().padLeft(2, '0');
    return Text('$mm:$ss',
        style: const TextStyle(fontSize: 12, color: Color(0xFF86909C)));
  }
}

/// 轻量"…"三点呼吸动画（不引入新动画库）。
class _AnimatedDots extends StatefulWidget {
  const _AnimatedDots({required this.color});
  final Color color;

  @override
  State<_AnimatedDots> createState() => _AnimatedDotsState();
}

class _AnimatedDotsState extends State<_AnimatedDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) {
        final n = (_ac.value * 3).floor() % 3 + 1; // 1..3 个点
        return SizedBox(
          width: 16,
          child: Text('.' * n,
              style: TextStyle(fontSize: 12, color: widget.color)),
        );
      },
    );
  }
}

// ───── 视频会议壳（飞书桌面质感，浅色，可拖动）─────
// 真实画面经 DingRtcVideoView（macOS FlutterPlatformView）渲染；远端 userId 未到 → 「等待对方加入」
// 真实空状态（**绝不伪造画面**）。麦克风/摄像头/挂断/参会人/布局真实可用；屏幕共享/录制/AI 总结/
// 字幕/多人邀请为 **disabled 预留态**（未接 backend/native，点击不假成功）；
// 设备下拉复用 controller 已拉取的设备/音频路由列表，app 内 fallback 与原生会议窗同语义。

const Color _kMeetPanelBg = Color(0xFFFFFFFF); // 会议窗口底（浅色）
const Color _kMeetBorder = Color(0xFFE5E6EB);
const Color _kMeetBarBg = Color(0xFFFFFFFF);
const Color _kMeetStageBg = Color(0xFFF2F3F5); // 画面区浅灰
const Color _kMeetTileBg = Color(0xFFE9EBEE); // 视频块底
const Color _kMeetText = Color(0xFF1D2129);
const Color _kMeetSub = Color(0xFF86909C);
const Color _kMeetIcon = Color(0xFF4E5969);

/// 可拖动视频会议壳（app 内 fallback：macOS 原生会议窗口不可用时用）。标题栏为拖拽把手；
/// 布局/参会人状态由 [RtcCallController] 持有（与 native 会议窗口共享），壳仅管自身拖拽位移。
/// 通话结束重新挂载 → 位移复位默认。
class _VideoMeetingShell extends StatefulWidget {
  const _VideoMeetingShell({
    required this.controller,
    this.contentLeftInset = 0,
    this.compact = false,
    this.onMinimize,
  });
  final RtcCallController controller;
  final double contentLeftInset;
  final bool compact;
  final VoidCallback? onMinimize;

  @override
  State<_VideoMeetingShell> createState() => _VideoMeetingShellState();
}

class _VideoMeetingShellState extends State<_VideoMeetingShell> {
  Offset _offset = Offset.zero;
  String? _compactMaximizedTileId;
  final GlobalKey _remoteScreenTileKey = GlobalKey();
  bool _mobileMoreMenuOpen = false;

  void _resetPosition() => setState(() => _offset = Offset.zero);

  void _toggleMobileMoreMenu() =>
      setState(() => _mobileMoreMenuOpen = !_mobileMoreMenuOpen);

  Offset _clamp(Offset next, Size area, Size panel) {
    final freeW = (area.width - panel.width).clamp(0.0, double.infinity);
    final freeH = (area.height - panel.height).clamp(0.0, double.infinity);
    final baseX = freeW / 2; // 居中基准
    final baseY = freeH / 2;
    return Offset(
      next.dx.clamp(-baseX, freeW - baseX),
      next.dy.clamp(-baseY, freeH - baseY),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // 移动端：全屏无边框，SafeArea 保留刘海/Home 条。
    if (widget.compact) {
      return Positioned.fill(
        // 移动端会议是全屏 app 内 Flutter 壳（不像 macOS 有独立原生窗口），菜单/弹框
        // 必须是这个 Stack 自己的子节点、不能走 showDialog/showModalBottomSheet——
        // 那些走的是 rootNavigatorKey 对应的 GoRouter Navigator，跟这层会议 Overlay
        // 是平级 sibling，层级更低，弹出的东西会被这层会议壳整个盖住，看起来像“没反应”。
        child: Stack(
          children: [
            Material(
              color: _kMeetPanelBg,
              child: SafeArea(
                child: Column(
                  children: [
                    _MeetingTitleBar(
                      controller: c,
                      layout: c.meetingLayout,
                      onPanUpdate: (_) {},
                      onToggleLayout: c.switchLayout,
                      onReset: () {},
                      compact: true,
                      onMinimize: widget.onMinimize,
                      onToggleMoreMenu: _toggleMobileMoreMenu,
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _MeetingStage(
                              controller: c,
                              layout: c.meetingLayout,
                              compact: true,
                              maximizedTileId: _compactMaximizedTileId,
                              remoteScreenTileKey: _remoteScreenTileKey,
                              onMaximizeTile: (id) =>
                                  setState(() => _compactMaximizedTileId = id),
                              onExitMaximize: () => setState(
                                  () => _compactMaximizedTileId = null),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _MeetingControlBar(
                      controller: c,
                      participantsOpen: c.participantsPanelOpen,
                      onToggleParticipants: c.toggleParticipants,
                      compact: true,
                    ),
                  ],
                ),
              ),
            ),
            if (_mobileMoreMenuOpen) ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleMobileMoreMenu,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 58,
                right: 12,
                child: _MobileMeetingMoreMenu(
                  controller: c,
                  onClose: _toggleMobileMoreMenu,
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(left: widget.contentLeftInset),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = Size(constraints.maxWidth, constraints.maxHeight);
            // desktop 920~1100×620~720，按窗口 clamp；窄窗自适应不溢出。
            final w = math.min(1040.0, area.width - 24).clamp(320.0, 1100.0);
            final h = math.min(700.0, area.height - 24).clamp(280.0, 720.0);
            final panel = Size(w.toDouble(), h.toDouble());
            return Align(
              alignment: const Alignment(0, -0.05),
              child: Transform.translate(
                offset: _offset,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: panel.width,
                    height: panel.height,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: _kMeetPanelBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kMeetBorder),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x1A000000),
                            blurRadius: 24,
                            offset: Offset(0, 10)),
                      ],
                    ),
                    child: Column(
                      children: [
                        _MeetingTitleBar(
                          controller: c,
                          layout: c.meetingLayout,
                          onPanUpdate: (d) => setState(() =>
                              _offset = _clamp(_offset + d.delta, area, panel)),
                          onToggleLayout: c.switchLayout,
                          onReset: _resetPosition,
                        ),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                  child: _MeetingStage(
                                      controller: c, layout: c.meetingLayout)),
                              if (c.participantsPanelOpen)
                                _MeetingParticipantsPanel(
                                  controller: c,
                                  onClose: c.toggleParticipants,
                                ),
                            ],
                          ),
                        ),
                        _MeetingControlBar(
                          controller: c,
                          participantsOpen: c.participantsPanelOpen,
                          onToggleParticipants: c.toggleParticipants,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 标题栏：会议信息 + 时长 + 连接 + 布局/还原/结束；整条为拖拽把手（空白处可拖，按钮仍可点）。
class _MeetingTitleBar extends StatelessWidget {
  const _MeetingTitleBar({
    required this.controller,
    required this.layout,
    required this.onPanUpdate,
    required this.onToggleLayout,
    required this.onReset,
    this.compact = false,
    this.onMinimize,
    this.onToggleMoreMenu,
  });
  final RtcCallController controller;
  final RtcMeetingLayout layout;
  final GestureDragUpdateCallback onPanUpdate;
  final VoidCallback onToggleLayout;
  final VoidCallback onReset;
  final bool compact;
  final VoidCallback? onMinimize;
  final VoidCallback? onToggleMoreMenu;

  @override
  Widget build(BuildContext context) {
    // 移动端：简化标题栏，去掉布局切换/位置还原，仅显示通话类型+时长+结束按钮。
    if (compact) {
      return Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          color: _kMeetPanelBg,
          border: Border(bottom: BorderSide(color: _kMeetBorder)),
        ),
        child: Row(
          children: [
            if (onMinimize != null)
              _MeetIconBtn(
                icon: CupertinoIcons.chevron_down,
                tooltip: '最小化',
                onTap: onMinimize!,
              ),
            SizedBox(width: onMinimize != null ? 4 : 0),
            Icon(
              controller.isVideo
                  ? CupertinoIcons.video_camera_solid
                  : CupertinoIcons.phone_fill,
              size: 16,
              color: _kCallBlue,
            ),
            const SizedBox(width: 8),
            Text(
              controller.isVideo ? '视频通话' : '语音通话',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _kMeetText,
              ),
            ),
            const SizedBox(width: 10),
            if (controller.connectedAt != null)
              _CallDurationText(start: controller.connectedAt)
            else
              const Text('接通中',
                  style: TextStyle(fontSize: 12, color: _kMeetSub)),
            const Spacer(),
            _MeetIconBtn(
              icon: CupertinoIcons.ellipsis,
              tooltip: '更多',
              onTap: () => onToggleMoreMenu?.call(),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onPanUpdate: onPanUpdate, // 拖动整条标题栏移动会议窗口
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        // 不透明底色 → 标题栏空白处可被拖动（color 须放进 decoration，不能与 decoration 并存）。
        decoration: const BoxDecoration(
          color: _kMeetPanelBg,
          border: Border(bottom: BorderSide(color: _kMeetBorder)),
        ),
        child: Row(
          children: [
            const Icon(CupertinoIcons.info_circle, size: 15, color: _kMeetSub),
            const SizedBox(width: 6),
            const Text('视频通话',
                style: TextStyle(
                    fontSize: 13,
                    color: _kMeetText,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            if (controller.connectedAt != null)
              _CallDurationText(start: controller.connectedAt)
            else
              const Text('接通中',
                  style: TextStyle(fontSize: 12, color: _kMeetSub)),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.wifi, size: 14, color: _kMeetSub),
            const Spacer(),
            _MeetIconBtn(
              icon: layout == RtcMeetingLayout.gallery
                  ? CupertinoIcons.rectangle_grid_1x2
                  : CupertinoIcons.square_grid_2x2,
              tooltip: '切换布局',
              onTap: onToggleLayout,
            ),
            _MeetIconBtn(
                icon: CupertinoIcons.arrow_counterclockwise,
                tooltip: '还原位置',
                onTap: onReset),
            _MeetIconBtn(
                icon: CupertinoIcons.xmark,
                tooltip: '结束通话',
                color: _kDanger,
                onTap: () => controller.hangUp()),
          ],
        ),
      ),
    );
  }
}

/// 移动端会议标题栏「更多」菜单：以 [_VideoMeetingShellState] 自己 Stack 里的
/// 普通子节点渲染（不走 showDialog/showModalBottomSheet），跟会议壳在同一层，
/// 不会被会议壳的 Positioned.fill 盖住。目前只有「邀请参会人」一项。
class _MobileMeetingMoreMenu extends StatelessWidget {
  const _MobileMeetingMoreMenu(
      {required this.controller, required this.onClose});

  final RtcCallController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final canInvite = controller.canInviteParticipants;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kMeetBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canInvite
              ? () {
                  onClose();
                  controller.requestInviteParticipants();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(CupertinoIcons.person_add,
                    size: 17, color: canInvite ? _kCallBlue : _kMeetSub),
                const SizedBox(width: 10),
                Text('邀请参会人',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: canInvite ? _kMeetText : _kMeetSub,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 画面区：gallery=左右分屏；speaker=远端主画面 + 本地 PiP。
class _MeetingStage extends StatelessWidget {
  const _MeetingStage({
    required this.controller,
    required this.layout,
    this.compact = false,
    this.maximizedTileId,
    this.onMaximizeTile,
    this.onExitMaximize,
    this.remoteScreenTileKey,
  });
  final RtcCallController controller;
  final RtcMeetingLayout layout;
  final bool compact;
  final String? maximizedTileId;
  final ValueChanged<String>? onMaximizeTile;
  final VoidCallback? onExitMaximize;
  final Key? remoteScreenTileKey;

  @override
  Widget build(BuildContext context) {
    final isVideoCall = controller.isVideo;
    final remoteIds = controller.remoteUserIds;
    final remoteScreenUserId = controller.remoteScreenUserId;
    final remoteScreenEntry = controller.remoteScreenSharing &&
            remoteScreenUserId != null &&
            remoteScreenUserId.isNotEmpty
        ? _MeetingTileEntry(
            id: 'screen:$remoteScreenUserId',
            child: _MeetingVideoTile(
              key: remoteScreenTileKey ??
                  ValueKey('tile-remote-screen-$remoteScreenUserId'),
              role: RtcVideoRole.remoteScreen,
              name: '屏幕共享',
              callUuid: controller.callUuid,
              remoteUserId: remoteScreenUserId,
              isVideoCall: true,
            ),
          )
        : null;
    final local = _MeetingTileEntry(
      id: 'local',
      child: _MeetingVideoTile(
        key: const ValueKey('tile-local'),
        role: RtcVideoRole.local,
        name: '我',
        avatarUrl: controller.selfAvatarUrl,
        callUuid: controller.callUuid,
        cameraOn: controller.cameraOn,
        muted: controller.muted,
        isSelf: true,
        isVideoCall: isVideoCall,
      ),
    );
    final joinedTiles = remoteIds.map((uid) {
      final fallbackName = remoteIds.length == 1
          ? controller.displayName
          : '成员 ${remoteIds.indexOf(uid) + 1}';
      final display =
          controller.participantDisplayFor(uid, fallbackName: fallbackName);
      // 数字员工 1v1：agent 参与者不进 /calls 参与者列表 (Phase 1 only-human)，
      // participantDisplayFor 查不到时用发起通话时已知的 peerAvatarUrl 兜底。
      final avatarUrl = display.avatarUrl.isNotEmpty
          ? display.avatarUrl
          : (remoteIds.length == 1 ? (controller.peerAvatarUrl ?? '') : '');
      return _MeetingTileEntry(
        id: 'remote:$uid',
        child: _MeetingVideoTile(
          key: ValueKey('tile-remote-$uid'),
          role: RtcVideoRole.remote,
          name: display.name,
          avatarUrl: avatarUrl,
          callUuid: controller.callUuid,
          remoteUserId: uid,
          isVideoCall: isVideoCall,
          remoteCameraOn: controller.isRemoteCameraOn(uid),
        ),
      );
    }).toList();
    // 已发起邀请、还没入会（含会中途邀请的新人）的参与者也要出一个"呼叫中"占位块，
    // 不能只在 remoteIds 完全为空时才显示——否则已有一人在会时再邀请第二个人，
    // 被邀请人会一直不出现在画面上（看起来像邀请没生效）。
    final calling = controller.callingParticipants;
    final callingTiles = List<_MeetingTileEntry>.generate(calling.length, (i) {
      final p = calling[i];
      return _MeetingTileEntry(
        id: 'calling:$i',
        child: _MeetingVideoTile(
          key: ValueKey('tile-calling-$i-${p.name}'),
          role: RtcVideoRole.remote,
          name: p.name.isNotEmpty ? p.name : '成员 ${i + 1}',
          avatarUrl: p.avatarUrl,
          callUuid: controller.callUuid,
          remoteUserId: null,
          isVideoCall: isVideoCall,
          waitingText: '呼叫中...',
        ),
      );
    });
    final remoteTiles = joinedTiles.isEmpty && callingTiles.isEmpty
        ? <_MeetingTileEntry>[
            _MeetingTileEntry(
              id: 'remote:waiting',
              child: _MeetingVideoTile(
                key: const ValueKey('tile-remote-wait'),
                role: RtcVideoRole.remote,
                name: controller.displayName,
                avatarUrl: controller.peerAvatarUrl ?? '',
                callUuid: controller.callUuid,
                remoteUserId: null,
                isVideoCall: isVideoCall,
                waitingText: '等待对方加入',
              ),
            )
          ]
        : [...joinedTiles, ...callingTiles];
    final entries = <_MeetingTileEntry>[
      if (remoteScreenEntry != null) remoteScreenEntry,
      local,
      if (remoteScreenEntry == null) ...remoteTiles,
    ];
    final tiles = [for (final entry in entries) entry.child];
    return Container(
      color: _kMeetStageBg,
      padding: const EdgeInsets.all(12),
      child: compact
          ? _CompactMeetingStage(
              entries: entries,
              maximizedTileId: maximizedTileId,
              onMaximizeTile: onMaximizeTile,
              onExitMaximize: onExitMaximize,
            )
          : layout == RtcMeetingLayout.gallery
              ? _MeetingGalleryGrid(tiles: tiles)
              : Stack(
                  children: [
                    Positioned.fill(
                        child: (remoteScreenEntry ?? remoteTiles.first).child),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child:
                          SizedBox(width: 168, height: 116, child: local.child),
                    ),
                  ],
                ),
    );
  }
}

class _MeetingTileEntry {
  const _MeetingTileEntry({required this.id, required this.child});
  final String id;
  final Widget child;
}

class _CompactMeetingStage extends StatelessWidget {
  const _CompactMeetingStage({
    required this.entries,
    required this.maximizedTileId,
    required this.onMaximizeTile,
    required this.onExitMaximize,
  });

  final List<_MeetingTileEntry> entries;
  final String? maximizedTileId;
  final ValueChanged<String>? onMaximizeTile;
  final VoidCallback? onExitMaximize;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const _TileWaiting();
    _MeetingTileEntry? maximized;
    if (maximizedTileId != null) {
      for (final entry in entries) {
        if (entry.id == maximizedTileId) {
          maximized = entry;
          break;
        }
      }
    }
    if (maximized != null) {
      return Stack(
        children: [
          Positioned.fill(child: maximized.child),
          Positioned(
            top: 12,
            right: 12,
            child: _ExitMaximizeButton(onTap: onExitMaximize),
          ),
        ],
      );
    }

    if (entries.length <= 2) {
      return Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Expanded(
                child: _TappableMeetingTile(
                    entry: entries[i], onTap: onMaximizeTile)),
          ],
        ],
      );
    }

    final primary = entries.first;
    final secondary = entries.skip(1).toList(growable: false);
    return Column(
      children: [
        Expanded(
            child: _TappableMeetingTile(entry: primary, onTap: onMaximizeTile)),
        const SizedBox(height: 10),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: secondary.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final entry = secondary[index];
              return SizedBox(
                width: 160,
                child:
                    _TappableMeetingTile(entry: entry, onTap: onMaximizeTile),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TappableMeetingTile extends StatelessWidget {
  const _TappableMeetingTile({required this.entry, required this.onTap});
  final _MeetingTileEntry entry;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        entry.child,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap == null ? null : () => onTap!(entry.id),
          ),
        ),
      ],
    );
  }
}

class _ExitMaximizeButton extends StatelessWidget {
  const _ExitMaximizeButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            '退出',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _MeetingGalleryGrid extends StatelessWidget {
  const _MeetingGalleryGrid({required this.tiles});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.length <= 2) {
      return Row(
        children: [
          Expanded(child: tiles[0]),
          const SizedBox(width: 12),
          Expanded(child: tiles.length == 1 ? const _TileWaiting() : tiles[1]),
        ],
      );
    }
    final columns = tiles.length <= 4 ? 2 : 3;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 16 / 9,
      ),
      itemCount: tiles.length,
      itemBuilder: (_, i) => tiles[i],
    );
  }
}

/// 单个视频块（统一会议）：
/// - 本地：cameraOn → 真实本地 DingRtcVideoView；否则头像 +「摄像头已关」（audio 也是此态，不伪造视频）。
/// - 远端：userId 未到 → 「等待对方加入」；video 通话 → 真实远端 DingRtcVideoView；audio → 头像（无视频）。
/// - 远端屏幕共享：真实远端 screen track，优先作为会议主画面。
class _MeetingVideoTile extends StatelessWidget {
  const _MeetingVideoTile({
    super.key,
    required this.role,
    required this.name,
    this.avatarUrl = '',
    this.callUuid,
    this.remoteUserId,
    this.cameraOn = true,
    this.muted = false,
    this.isSelf = false,
    this.isVideoCall = true,
    this.remoteCameraOn = false,
    this.waitingText = '等待对方加入',
  });
  final RtcVideoRole role;
  final String name;
  final String avatarUrl;
  final String? callUuid;
  final String? remoteUserId;
  final bool cameraOn;
  final bool muted;
  final bool isSelf;
  final bool isVideoCall;
  // 远端是否在推摄像头（语音通话中对方中途开摄像头时为 true）。
  final bool remoteCameraOn;
  final String waitingText;

  Widget _content() {
    if (role == RtcVideoRole.local) {
      // 本地：开摄像头才挂真实视图（audio/关摄像头 → 头像预留态，不伪造视频）。
      return cameraOn
          ? DingRtcVideoView(
              key: const ValueKey('meeting-local-view'),
              role: RtcVideoRole.local,
              callUuid: callUuid)
          : _TileAvatar(name: name, avatarUrl: avatarUrl, caption: '摄像头已关');
    }
    // 远端
    if (remoteUserId == null || remoteUserId!.isEmpty) {
      return _TileWaiting(text: waitingText);
    }
    if (role == RtcVideoRole.remoteScreen) {
      return DingRtcVideoView(
        key: ValueKey('meeting-remote-screen-$remoteUserId'),
        role: RtcVideoRole.remoteScreen,
        userId: remoteUserId,
        callUuid: callUuid,
      );
    }
    // 视频通话，或语音通话中对方中途开了摄像头 → 挂真实远端视图；否则头像。
    return (isVideoCall || remoteCameraOn)
        ? DingRtcVideoView(
            key: ValueKey('meeting-remote-$remoteUserId'),
            role: RtcVideoRole.remote,
            userId: remoteUserId,
            callUuid: callUuid)
        : _TileAvatar(name: name, avatarUrl: avatarUrl); // 语音通话且对方未开摄像头 → 头像
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _kMeetTileBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _content(),
          // 名牌 + 静音标记（左下角）。
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0x99000000),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelf && muted) ...[
                    const Icon(CupertinoIcons.mic_slash_fill,
                        size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                  ],
                  Text(isSelf ? '$name (我)' : name,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频块内远端未到：浅色真实空状态（不伪造画面）。
class _TileWaiting extends StatelessWidget {
  const _TileWaiting({this.text = '等待对方加入'});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 56,
            height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: Color(0xFFD9DCE0), shape: BoxShape.circle),
              child: Icon(CupertinoIcons.person_fill,
                  size: 28, color: Color(0xFF9AA0AA)),
            ),
          ),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(fontSize: 13, color: _kMeetSub)),
        ],
      ),
    );
  }
}

/// 视频块内头像预留态（关摄像头 / 语音通话无视频 —— 不伪造画面）。
class _TileAvatar extends StatelessWidget {
  const _TileAvatar({required this.name, this.avatarUrl = '', this.caption});
  final String name;
  final String avatarUrl;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(
            child: ChatAvatar(
              url: avatarUrl,
              fallbackText: name,
              size: 60,
              kind: ChatAvatarKind.user,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 10),
            Text(caption!,
                style: const TextStyle(fontSize: 12, color: _kMeetSub)),
          ],
        ],
      ),
    );
  }
}

/// 底部控制条：mic/camera/hangup/参会人/邀请 真实；屏幕共享/录制/AI/字幕/更多 disabled 预留态。
/// 视觉按飞书会议工具栏收紧：小圆角 icon button，mic/camera 为主按钮 + 紧邻下拉分裂按钮。
class _MeetingControlBar extends StatelessWidget {
  const _MeetingControlBar({
    required this.controller,
    required this.participantsOpen,
    required this.onToggleParticipants,
    this.compact = false,
  });
  final RtcCallController controller;
  final bool participantsOpen;
  final VoidCallback onToggleParticipants;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    // 移动端：只保留麦克风、挂断、摄像头三个核心按钮，居中均分。
    if (compact) {
      return Container(
        height: 96,
        decoration: const BoxDecoration(
          color: _kMeetBarBg,
          border: Border(top: BorderSide(color: _kMeetBorder)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _MeetTool(
              label: c.muted ? '已静音' : '麦克风',
              icon: c.muted
                  ? CupertinoIcons.mic_slash_fill
                  : CupertinoIcons.mic_fill,
              tooltip: c.muted ? '取消静音' : '静音',
              active: !c.muted,
              onTap: () => c.toggleMute(),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: '挂断',
                  child: Material(
                    color: c.canEndMeeting
                        ? _kDanger
                        : _kDanger.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(28),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: c.canEndMeeting ? () => c.hangUp() : null,
                      child: const SizedBox(
                        width: 56,
                        height: 56,
                        child: Icon(CupertinoIcons.phone_down_fill,
                            color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text('结束',
                    style: TextStyle(fontSize: 11, color: _kMeetSub)),
              ],
            ),
            _MeetTool(
              label: c.cameraOn ? '摄像头' : '已关闭',
              icon: c.cameraOn
                  ? CupertinoIcons.video_camera_solid
                  : CupertinoIcons.video_camera,
              tooltip: c.cameraOn ? '关闭摄像头' : '开启摄像头',
              active: c.cameraOn,
              onTap: () => c.toggleCamera(),
            ),
          ],
        ),
      );
    }
    final participantCount = 1 + c.remoteUserIds.length;
    final audioDevices =
        c.speakerDevices.isNotEmpty ? c.speakerDevices : c.microphoneDevices;
    return Container(
      height: 72,
      decoration: const BoxDecoration(
        color: _kMeetBarBg,
        border: Border(top: BorderSide(color: _kMeetBorder)),
      ),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 10),
              _MeetSplitTool(
                label: c.muted ? '已静音' : '麦克风',
                icon: c.muted
                    ? CupertinoIcons.mic_slash_fill
                    : CupertinoIcons.mic_fill,
                tooltip: c.muted ? '取消静音' : '静音',
                active: !c.muted,
                onTap: () => c.toggleMute(),
                chevronTooltip: audioDevices.isEmpty ? '音频设备 · 未检测到' : '音频设备',
                devices: audioDevices,
                onDeviceSelected: (d) => c.selectDevice(d.kind, d.id),
              ),
              const SizedBox(width: 8),
              _MeetSplitTool(
                label: c.cameraOn ? '摄像头' : '已关闭',
                icon: c.cameraOn
                    ? CupertinoIcons.video_camera_solid
                    : CupertinoIcons.video_camera,
                tooltip: c.cameraOn ? '关闭摄像头' : '开启摄像头',
                active: c.cameraOn,
                onTap: () => c.toggleCamera(),
                chevronTooltip:
                    c.cameraDevices.isEmpty ? '摄像头设备 · 未检测到' : '摄像头设备',
                devices: c.cameraDevices,
                onDeviceSelected: (d) => c.selectDevice(d.kind, d.id),
              ),
              const SizedBox(width: 8),
              _MeetTool(
                  label: c.screenShareBusy
                      ? '共享中'
                      : (c.remoteScreenSharing ? '对方共享中' : '共享'),
                  icon: CupertinoIcons.rectangle_on_rectangle_angled,
                  tooltip: RtcPlatformCapabilities.current.supportsScreenShare
                      ? (c.screenShareBusy ? '正在共享屏幕' : '共享屏幕')
                      : '共享屏幕 · 暂未支持',
                  active: c.screenShareBusy,
                  enabled:
                      RtcPlatformCapabilities.current.supportsScreenShare &&
                          !c.screenShareBusy,
                  onTap: () => c.toggleScreenShare()),
              const SizedBox(width: 8),
              const _MeetTool(
                  label: '录制',
                  icon: CupertinoIcons.smallcircle_circle,
                  tooltip: '录制 · 暂未支持',
                  enabled: false),
              const SizedBox(width: 8),
              const _MeetTool(
                  label: 'AI 总结',
                  icon: CupertinoIcons.sparkles,
                  tooltip: 'AI 总结 · 暂未支持',
                  enabled: false),
              const SizedBox(width: 8),
              const _MeetTool(
                  label: '字幕',
                  icon: CupertinoIcons.captions_bubble,
                  tooltip: '字幕 · 暂未支持',
                  enabled: false),
              const SizedBox(width: 8),
              _MeetTool(
                label: '参会人 $participantCount',
                icon: CupertinoIcons.person_2_fill,
                tooltip: '参会人',
                active: participantsOpen,
                onTap: onToggleParticipants,
              ),
              const SizedBox(width: 8),
              if (c.canInviteParticipants) ...[
                _MeetTool(
                  label: '邀请',
                  icon: CupertinoIcons.person_add,
                  tooltip: '邀请',
                  onTap: () => c.requestInviteParticipants(),
                ),
                const SizedBox(width: 8),
              ],
              const _MeetTool(
                  label: '更多',
                  icon: CupertinoIcons.ellipsis,
                  tooltip: '更多 · 暂未支持',
                  enabled: false),
              const SizedBox(width: 12),
              SizedBox(
                width: 58,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: '挂断',
                      child: Material(
                        color: c.canEndMeeting
                            ? _kDanger
                            : _kDanger.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: c.canEndMeeting ? () => c.hangUp() : null,
                          child: const SizedBox(
                            width: 52,
                            height: 34,
                            child: Icon(CupertinoIcons.phone_down_fill,
                                color: Colors.white, size: 19),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('结束',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF4E5969),
                          height: 1,
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _MeetSplitTool extends StatelessWidget {
  const _MeetSplitTool({
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.chevronTooltip,
    required this.onTap,
    this.devices = const <RtcDeviceInfo>[],
    this.onDeviceSelected,
    this.active = false,
  });

  final String label;
  final IconData icon;
  final String tooltip;
  final String chevronTooltip;
  final VoidCallback onTap;
  final List<RtcDeviceInfo> devices;
  final ValueChanged<RtcDeviceInfo>? onDeviceSelected;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final bg =
        active ? _kCallBlue.withValues(alpha: 0.10) : const Color(0xFFF2F3F5);
    final fg = active ? _kCallBlue : _kMeetIcon;
    return SizedBox(
      width: 66,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 34,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: tooltip,
                  child: Material(
                    color: bg,
                    borderRadius:
                        const BorderRadius.horizontal(left: Radius.circular(8)),
                    child: InkWell(
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(8)),
                      onTap: onTap,
                      child: SizedBox(
                        width: 36,
                        height: 34,
                        child: Icon(icon, size: 18, color: fg),
                      ),
                    ),
                  ),
                ),
                Container(width: 1, height: 18, color: const Color(0xFFDADDE3)),
                _MeetDeviceChevron(
                  tooltip: chevronTooltip,
                  background: bg,
                  devices: devices,
                  onDeviceSelected: onDeviceSelected,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: Color(0xFF4E5969),
                height: 1,
              )),
        ],
      ),
    );
  }
}

/// 会议控制条扁平 icon 按钮（active 蓝 / 普通灰 / disabled 浅灰，tooltip）。
class _MeetTool extends StatelessWidget {
  const _MeetTool({
    required this.label,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.enabled = true,
  });
  final String label;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color =
        !enabled ? const Color(0xFFC9CDD4) : (active ? _kCallBlue : _kMeetIcon);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: !enabled
                  ? const Color(0xFFF7F8FA)
                  : (active
                      ? _kCallBlue.withValues(alpha: 0.10)
                      : const Color(0xFFF2F3F5)),
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: enabled ? onTap : null,
                child: SizedBox(
                  width: 36,
                  height: 34,
                  child: Icon(icon, size: 18, color: color),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: enabled
                      ? const Color(0xFF4E5969)
                      : const Color(0xFFB7BDC6),
                  height: 1,
                )),
          ],
        ),
      ),
    );
  }
}

/// 设备下拉箭头（app fallback 用 controller 已拉取的设备/路由列表；native 窗仍走原生菜单）。
class _MeetDeviceChevron extends StatelessWidget {
  const _MeetDeviceChevron({
    required this.tooltip,
    required this.background,
    required this.devices,
    required this.onDeviceSelected,
  });
  final String tooltip;
  final Color background;
  final List<RtcDeviceInfo> devices;
  final ValueChanged<RtcDeviceInfo>? onDeviceSelected;

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final rect = topLeft & box.size;
    final anchorTop = math.max(8.0, rect.top - 120);
    final selected = await showMenu<RtcDeviceInfo>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, anchorTop, rect.width, rect.height),
        Offset.zero & overlay.size,
      ),
      items: devices.isEmpty
          ? const <PopupMenuEntry<RtcDeviceInfo>>[
              PopupMenuItem<RtcDeviceInfo>(
                enabled: false,
                child: Text('未检测到设备'),
              ),
            ]
          : devices
              .map(
                (d) => PopupMenuItem<RtcDeviceInfo>(
                  value: d,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        child: d.isCurrent
                            ? const Icon(CupertinoIcons.checkmark,
                                size: 14, color: _kCallBlue)
                            : null,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          d.name,
                          overflow: TextOverflow.ellipsis
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
    );
    if (selected != null) onDeviceSelected?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
        child: InkWell(
          borderRadius:
              const BorderRadius.horizontal(right: Radius.circular(8)),
          onTap: () => _openMenu(context),
          child: const SizedBox(
            width: 20,
            height: 34,
            child: Icon(CupertinoIcons.chevron_down,
                size: 11, color: Color(0xFF9CA3AF)),
          ),
        ),
      ),
    );
  }
}

/// 标题栏小 icon 按钮。
class _MeetIconBtn extends StatelessWidget {
  const _MeetIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = _kMeetIcon,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: SizedBox(
              width: 32, height: 32, child: Icon(icon, size: 16, color: color)),
        ),
      ),
    );
  }
}

/// 参会人侧栏：标题 + 关闭 + 列表（本端真实 mic/camera，对端状态未上报 → 中性）。
class _MeetingParticipantsPanel extends StatelessWidget {
  const _MeetingParticipantsPanel(
      {required this.controller, required this.onClose});
  final RtcCallController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final joined = controller.joinedParticipants;
    final calling = controller.callingParticipants;
    final count = 1 + joined.length + calling.length;
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: _kMeetPanelBg,
        border: Border(left: BorderSide(color: _kMeetBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Text('参会人 ($count)',
                    style: const TextStyle(
                        fontSize: 14,
                        color: _kMeetText,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                _MeetIconBtn(
                    icon: CupertinoIcons.xmark, tooltip: '收起', onTap: onClose),
              ],
            ),
          ),
          const Divider(height: 1, color: _kMeetBorder),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                _ParticipantRow(
                  name: '我',
                  selfLabel: true,
                  micOn: !controller.muted,
                  cameraOn: controller.cameraOn,
                  stateKnown: true,
                ),
                for (final p in joined)
                  _ParticipantRow(
                    name: p.name,
                    avatarUrl: p.avatarUrl,
                    micOn: true,
                    cameraOn: true,
                    stateKnown: false, // 对端状态未上报 → 中性显示
                  ),
                for (final p in calling)
                  _ParticipantRow(
                    name: '${p.name}（呼叫中...）',
                    avatarUrl: p.avatarUrl,
                    micOn: false,
                    cameraOn: false,
                    stateKnown: false,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.name,
    required this.micOn,
    required this.cameraOn,
    this.avatarUrl = '',
    this.selfLabel = false,
    this.stateKnown = true,
  });
  final String name;
  final String avatarUrl;
  final bool micOn;
  final bool cameraOn;
  final bool selfLabel;
  final bool stateKnown;

  @override
  Widget build(BuildContext context) {
    final iconColor = stateKnown ? _kMeetIcon : const Color(0xFFC9CDD4);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          ClipOval(
            child: ChatAvatar(
              url: avatarUrl,
              fallbackText: name,
              size: 30,
              kind: ChatAvatarKind.user,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: _kMeetText)),
          ),
          Icon(micOn ? CupertinoIcons.mic_fill : CupertinoIcons.mic_slash_fill,
              size: 15, color: iconColor),
          const SizedBox(width: 10),
          Icon(
              cameraOn
                  ? CupertinoIcons.video_camera_solid
                  : CupertinoIcons.video_camera,
              size: 15,
              color: iconColor),
        ],
      ),
    );
  }
}
