import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderBox, SelectedContent;
import 'package:flutter/services.dart';
import 'package:zhiban_client/utils/haptic_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

import 'chat_message_menu_overlay.dart';

/// 桌面端不画拖拽手柄(选区仍然正常,只是没有那个可拖动的圆点)——手柄是触屏
/// 交互的产物,鼠标拖选场景下没必要。toolbar 始终走 [TextSelectionHandleControls]
/// 混入的空实现,交给 [SelectableRegion.contextMenuBuilder] 处理,跟平台无关。
class _ChatTextSelectionHandleControls extends CupertinoTextSelectionControls
    with TextSelectionHandleControls {
  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    if (!PlatformUtils.isMobile) return const SizedBox.shrink();
    return super.buildHandle(context, type, textLineHeight, onTap);
  }

  @override
  Size getHandleSize(double textLineHeight) {
    if (!PlatformUtils.isMobile) return Size.zero;
    return super.getHandleSize(textLineHeight);
  }
}

final _chatTextSelectionHandleControls = _ChatTextSelectionHandleControls();

/// 复制一段聊天文本到系统剪贴板,并提示「已复制」。
/// 与 [CopyWidget] 底部复制按钮同语义:空白(trim 为空)不复制、不提示;否则写原文 + toast。
Future<void> copyChatMessageText(String text) async {
  if (text.trim().isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  BotToast.showText(text: '已复制');
}

/// 一条已挂载的 [ChatSelectableSurface] 在 [ChatSelectionController] 里的登记项。
/// 每个 surface 自己的 `GlobalKey<SelectableRegionState>` + `FocusNode`——两者都
/// 只能绑定给唯一一个 widget,不能在多个 surface 间共享,所以一条消息气泡有
/// 几段文字(比如图文混排,文字被图片隔开)就有几个 `_RegisteredRegion`。
class _RegisteredRegion {
  final GlobalKey<SelectableRegionState> regionKey =
      GlobalKey<SelectableRegionState>();
  final FocusNode focusNode = FocusNode();
  String selectedText = '';

  void dispose() => focusNode.dispose();
}

/// 一个消息气泡对应一个 [ChatSelectionController],可以驱动气泡里**任意数量**
/// 的 [ChatSelectableSurface](气泡内容常常是文字夹着图片/文件,多段文字各自
/// 独立成一个 surface,由这个 controller 统一"外部控制"——全选所有段落 / 清空
/// 所有段落)。
///
/// 只负责"记录当前选区文本 + 全选 / 清空"这几件事,不参与手势判断——手势(长按/
/// 右键弹菜单)完全是气泡容器([ChatSelectionGestureMixin])自己的事,跟气泡里
/// 有没有可选文字无关。见 [ChatSelectableSurface] 顶部说明。
class ChatSelectionController {
  final List<_RegisteredRegion> _regions = <_RegisteredRegion>[];

  /// 每次某个 surface 上报选区变化(拖手柄调整范围)都会触发一次,供
  /// [ChatSelectionGestureMixin] 拖手柄时暂时隐藏菜单用。`selectAllWithHandles`
  /// 首次全选那次变化发生在菜单还没弹出之前,不会被误当成"正在拖拽"。
  VoidCallback? onSelectionActivity;

  void _register(_RegisteredRegion region) => _regions.add(region);

  void _unregister(_RegisteredRegion region) {
    _regions.remove(region);
    region.dispose();
  }

  /// 拼接所有已登记 surface 当前上报的选区文本(空的跳过)。桌面拖选一段文字后
  /// 右键,菜单的「复制」用这个覆盖整条复制;正常情况下只有一个 surface 有非空
  /// 选区,拼接不会产生歧义。
  String get selectedText =>
      _regions.map((r) => r.selectedText).where((t) => t.isNotEmpty).join();

  /// 全选**所有**已登记 surface 并显示手柄(移动端长按外部触发,见
  /// [ChatSelectionGestureMixin])。
  ///
  /// 每个 surface 都要先 `requestFocus()`:`SelectableRegionState` 有一个焦点
  /// 监听,只要它的 `FocusNode` 没有焦点就会把选区清掉(`_handleFocusChanged` →
  /// `clearSelection()`,见 Flutter `selectable_region.dart`)——不显式要焦点,
  /// `selectAll()` 设完选区几乎立刻又被这个监听清空,表现为"震动了、菜单弹出来
  /// 了,但文字始终没被选中"。
  ///
  /// `cause` 必须传 [SelectionChangedCause.toolbar] 才会渲染工具条/手柄 ——
  /// `SelectableRegionState.selectAll` 只在这个 cause 下才展示,其余值只改选区、
  /// 不出手柄。这是**唯一**能触发选区的入口 —— [ChatSelectableSurface] 自己的
  /// 直接长按/拖拽已经被禁用,选区完全由外层气泡手势"外部控制"。
  void selectAllWithHandles() {
    for (final region in _regions) {
      region.focusNode.requestFocus();
      region.regionKey.currentState?.selectAll(SelectionChangedCause.toolbar);
    }
  }

  void clear() {
    for (final region in _regions) {
      region.regionKey.currentState?.clearSelection();
      region.selectedText = '';
    }
  }

  void dispose() {}
}

/// 把 [ChatSelectionController] 透传给子树里唯一的 [ChatSelectableSurface]。
/// 纯数据载体,从不触发 rebuild。
class ChatMessageSelectionScope extends InheritedWidget {
  const ChatMessageSelectionScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ChatSelectionController controller;

  static ChatSelectionController? of(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<ChatMessageSelectionScope>()
        ?.controller;
  }

  @override
  bool updateShouldNotify(ChatMessageSelectionScope oldWidget) => false;
}

/// 一段可选中文字。统一用 [SelectableRegion] 承载(不再区分 `SelectableText` /
/// `SelectionArea` 两套实现):子树里任意 `Text` / `Text.rich` 都会自动加入这个
/// region 的选区(Flutter 的 ambient selection 机制),不需要每个文本块单独
/// 包一层选中逻辑。
///
/// 一条消息气泡可以放**多个** `ChatSelectableSurface`(比如图文混排,文字被
/// 图片隔开成好几段)——只把文字块包在这里,图片 / 文件卡片 / EMP 按钮等其他
/// 子控件留在外面、完全不经过这个 widget,它们的点击不受任何影响。
///
/// 移动端内部(直接长按/拖拽这段文字)的选中交互被永久禁用(`IgnorePointer`
/// 常开):选区完全"外部控制",只能由气泡容器的长按手势(见
/// [ChatSelectionGestureMixin])调 [ChatSelectionController.selectAllWithHandles]
/// 触发,不存在"用户直接在文字上长按/双击/拖拽也能独立产生选区"这条路径。
/// 选区一旦存在,拖动手柄调整范围仍然可用——手柄由 Flutter 画在应用级 Overlay
/// 里,不是这段文字自己的子树,不受这里的 `IgnorePointer` 影响。桌面端不加这层
/// `IgnorePointer`,保留鼠标拖选 / 双击选词。
///
/// 系统选区工具条(复制/全选/分享)恒不出现——`contextMenuBuilder` 恒定返回空
/// widget,消息气泡的操作菜单完全由 [ChatSelectionGestureMixin] 接管。
///
/// 不在任何 [ChatMessageSelectionScope] 内时(如技能详情、EMP 摘要等非消息气泡
/// 的独立展示场景):退化为普通可选中区域,可直接触摸/拖拽选中,系统工具条照常
/// 显示,行为不变。
class ChatSelectableSurface extends StatefulWidget {
  const ChatSelectableSurface({
    super.key,
    required this.child,
    this.onSelectionChanged,
  });

  final Widget child;
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  @override
  State<ChatSelectableSurface> createState() => _ChatSelectableSurfaceState();
}

class _ChatSelectableSurfaceState extends State<ChatSelectableSurface> {
  FocusNode? _standaloneFocusNode;
  ChatSelectionController? _controller;
  _RegisteredRegion? _region;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = ChatMessageSelectionScope.of(context);
    if (identical(controller, _controller)) return;
    if (_controller != null && _region != null) {
      _controller!._unregister(_region!);
    }
    _controller = controller;
    _region = controller == null ? null : _RegisteredRegion();
    if (controller != null && _region != null) {
      controller._register(_region!);
    }
  }

  @override
  void dispose() {
    _standaloneFocusNode?.dispose();
    if (_controller != null && _region != null) {
      _controller!._unregister(_region!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final region = _region;
    if (region == null) {
      _standaloneFocusNode ??= FocusNode();
      return SelectableRegion(
        focusNode: _standaloneFocusNode!,
        selectionControls: _chatTextSelectionHandleControls,
        onSelectionChanged: widget.onSelectionChanged,
        child: widget.child,
      );
    }
    return IgnorePointer(
      ignoring: PlatformUtils.isMobile,
      child: SelectableRegion(
        key: region.regionKey,
        focusNode: region.focusNode,
        selectionControls: _chatTextSelectionHandleControls,
        onSelectionChanged: (content) {
          region.selectedText = content?.plainText.trim() ?? '';
          _controller?.onSelectionActivity?.call();
          widget.onSelectionChanged?.call(content);
        },
        contextMenuBuilder: (_, __) => const SizedBox.shrink(),
        child: widget.child,
      ),
    );
  }
}

/// 承载"长按/右键 → 自研菜单"的公共手势状态机,供 IM 消息 region
/// (`ChatMessageActionRegion`,见 chat_message_action_menu.dart) 与人↔agent
/// 本地菜单 region ([ChatLocalMessageActionRegion]) 复用。
///
/// **气泡容器级手势,气泡里的文字选区完全由它"外部控制"**:长按气泡任意位置
/// (不管长按在文字上还是图片/空白处)都用 `GestureDetector.onLongPressStart`
/// 包住整个气泡直接弹菜单——这是长期在生产环境验证过的做法,不依赖、也不会被
/// 气泡里的文字内容影响。移动端额外调用
/// [ChatSelectionController.selectAllWithHandles] 把文字置为全选态(带可拖拽
/// 手柄);[ChatSelectableSurface] 自己**不**响应任何直接触摸/拖拽,选区只可能
/// 由这里触发,不存在两条手势路径互相竞争的问题。
mixin ChatSelectionGestureMixin<T extends StatefulWidget> on State<T> {
  final ChatSelectionController selectionController = ChatSelectionController();

  /// 传给气泡自己的 [TapRegion] 和 [showChatFeishuMenu] 的 `groupId`,让两者
  /// 算同一个 tap region 组——选区手柄画在 Overlay 里,不是气泡子树的一部分,
  /// 拖手柄第一下落点在气泡范围内、菜单卡片外,不加这层分组会被判定成"点击
  /// 外部"直接把刚弹出的菜单关掉。
  Object get menuGroupId => this;

  final GlobalKey _bubbleKey = GlobalKey();

  /// 气泡当前的全局矩形,外扩一点当"点击外部"判定的安全区(见
  /// [showChatFeishuMenu] 的 `safeZone` 参数)——选区手柄画在 Overlay 里,
  /// 手柄本身可能落在气泡视觉边界外几十像素(比如底部手柄的圆形指示器),
  /// `menuGroupId` 分组只覆盖气泡本身的渲染范围,覆盖不到这几十像素,不外扩
  /// 的话摸手柄第一下会被判成点击外部,菜单和选区一起被清掉。
  ///
  /// **仅移动端需要**:桌面端不画手柄(见 `_ChatTextSelectionHandleControls`
  /// 恒返回零尺寸),这层安全区在桌面端没有存在意义,反而会把"气泡内、菜单外"
  /// 的点击也判成"内部点击"——桌面端右键选中文字弹菜单后,点气泡内别处会清空
  /// 选区(SelectableRegion 桌面端未加 IgnorePointer,照常响应点击),但因为落
  /// 点仍在这个安全区/分组内,`onTapOutside` 不触发,表现为"选区没了菜单还在"。
  Rect? get menuSafeZone {
    if (!PlatformUtils.isMobile) return null;
    final box = _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return (topLeft & box.size).inflate(56);
  }

  /// 是否有任何可执行操作;false 时 [buildSelectionRegion] 透明返回 child。
  bool get hasAnyAction;

  /// 在 [globalPosition] 弹出菜单,返回是否真的选中了某一项。实现方要拿选区
  /// 文本(比如「复制」)一律现读 `selectionController.selectedText`,不要缓存
  /// 这一刻的快照——菜单开着的时候用户还能拖手柄改选区。
  /// 传 [menuVisible] 给 [showChatFeishuMenu] 的 `visible` 参数——拖手柄时
  /// 只是暂时切成不可见/不可点(见 [_handleSelectionActivity]),菜单本身没
  /// 关闭,不会影响这个 Future 的 resolve 时机。
  Future<bool> showMenu(
    Offset globalPosition, {
    ValueListenable<bool>? menuVisible,
  });

  ValueNotifier<bool>? _menuVisible;
  Timer? _dragSettleTimer;

  /// 拖手柄调整选区期间(见 [ChatSelectionController.onSelectionActivity])
  /// 暂时把菜单切成不可见,松手 260ms 内选区不再变化就当"拖拽结束",在原位置
  /// 重新显示——**不**走 dismiss/reopen 那一套(不清选区、不 resolve
  /// showMenu 的 Future),只是切一个 [ValueNotifier] 的可见性,这是之前几轮
  /// "抢焦点重选"方案反复引发级联问题后,能安全隔离改动范围的做法。
  void _handleSelectionActivity() {
    _menuVisible?.value = false;
    _dragSettleTimer?.cancel();
    _dragSettleTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      _menuVisible?.value = true;
    });
  }

  @override
  void dispose() {
    _dragSettleTimer?.cancel();
    selectionController.dispose();
    super.dispose();
  }

  Future<void> _open(Offset globalPosition) async {
    final menuVisible =
        PlatformUtils.isMobile ? ValueNotifier<bool>(true) : null;
    _menuVisible = menuVisible;
    if (menuVisible != null) {
      selectionController.onSelectionActivity = _handleSelectionActivity;
    }
    await showMenu(globalPosition, menuVisible: menuVisible);
    selectionController.onSelectionActivity = null;
    _dragSettleTimer?.cancel();
    _menuVisible = null;
    menuVisible?.dispose();
    if (!mounted) return;
    selectionController.clear();
  }

  void _onLongPressStart(Offset globalPosition) {
    if (!hasAnyAction) return;
    unawaited(HapticUtils.lightImpact());
    if (PlatformUtils.isMobile) {
      // 全选和弹菜单必须顺序执行(而不是并发),这样 _open 读到的
      // selectedText 才是全选之后的最新值,不是长按落下瞬间的旧值——但不需要
      // 等下一帧:SelectableRegionState 此刻已经挂载好了,同步调用即可。
      // 之前用 addPostFrameCallback 等下一帧反而是 bug:应用空闲时 Flutter
      // 不会平白调度一帧,回调可能被无限期挂起,表现为长按完全没反应。
      selectionController.selectAllWithHandles();
      unawaited(_open(globalPosition));
      return;
    }
    unawaited(_open(globalPosition));
  }

  void _onSecondaryPointerDown(Offset globalPosition) {
    if (!hasAnyAction) return;
    unawaited(_open(globalPosition));
  }

  /// 用这个包裹气泡内容:接右键(桌面)/ 长按(全平台)手势。没有可用操作时不拦
  /// 手势(气泡照常 tap/预览),但 [ChatMessageSelectionScope] 恒定包住——
  /// 不随 [hasAnyAction] 变化增减,子树里的 [ChatSelectableSurface] 任何时候
  /// 都能找到同一个 scope,不会出现"流式回复刚开始 hasAnyAction 还是假的时候
  /// 挂载成无 scope 兜底态,文字到齐后 hasAnyAction 变真也追不回来"这种情况。
  ///
  /// 气泡内每段可选中文字([ChatSelectableSurface])都永久 `IgnorePointer`,
  /// 自己不响应任何手势,所以这里可以直接用普通 [GestureDetector],不需要跟
  /// 谁抢竞技场。
  Widget buildSelectionRegion({required Widget child}) {
    final scoped = ChatMessageSelectionScope(
      controller: selectionController,
      child: child,
    );
    if (!hasAnyAction) return scoped;
    return TapRegion(
      key: _bubbleKey,
      // 桌面端不把整个气泡分进菜单的 groupId(见 menuSafeZone 的说明):
      // 只有移动端拖手柄需要"点气泡内不算点外部"这层豁免,桌面端点气泡内别处
      // 应该跟点真正的外部一样关闭菜单。
      groupId: PlatformUtils.isMobile ? menuGroupId : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if ((event.buttons & kSecondaryMouseButton) != 0) {
            _onSecondaryPointerDown(event.position);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) => _onLongPressStart(d.globalPosition),
          child: scoped,
        ),
      ),
    );
  }
}

/// 人↔agent 本地消息菜单项 (label / icon / danger + 本地可执行回调)。
class ChatLocalMenuItem {
  const ChatLocalMenuItem({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.danger = false,
    this.isCopy = false,
  });

  final IconData icon;
  final String label;
  final bool danger;

  /// 标记「复制」项:选中片段非空时,region 用选中片段覆盖 [onSelected] 的整条复制
  /// (见 [_ChatLocalMessageActionRegionState.showMenu])。
  final bool isCopy;
  final VoidCallback onSelected;
}

/// 人↔agent 聊天消息的操作菜单 region(桌面右键 + 移动端长按,机制见
/// [ChatSelectionGestureMixin])。
///
/// **不复用** IM 的 `ChatMessageAction` / `ImMessage` 语义 (撤回 / 引用 / 转发 / 多选
/// 等需要 WuKong IM 域支撑,agent 是 SSE / chat message 域)。本 region 只承诺
/// **本地可执行** 菜单项 (当前至少「复制」),与 IM 共用 [showChatFeishuMenu] 飞书风视觉。
///
/// `items` 为空时透明返回 child (不提供 scope / 不拦手势)。
class ChatLocalMessageActionRegion extends StatefulWidget {
  const ChatLocalMessageActionRegion({
    super.key,
    required this.child,
    required this.items,
  });

  final Widget child;
  final List<ChatLocalMenuItem> items;

  @override
  State<ChatLocalMessageActionRegion> createState() =>
      _ChatLocalMessageActionRegionState();
}

class _ChatLocalMessageActionRegionState
    extends State<ChatLocalMessageActionRegion>
    with ChatSelectionGestureMixin<ChatLocalMessageActionRegion> {
  @override
  bool get hasAnyAction => widget.items.isNotEmpty;

  @override
  Future<bool> showMenu(
    Offset globalPosition, {
    ValueListenable<bool>? menuVisible,
  }) async {
    final index = await showChatFeishuMenu(
      context: context,
      globalPosition: globalPosition,
      groupId: menuGroupId,
      safeZone: menuSafeZone,
      visible: menuVisible,
      items: widget.items
          .map((i) => ChatMenuOverlayItem(
                icon: i.icon,
                label: i.label,
                danger: i.danger,
              ))
          .toList(growable: false),
    );
    if (index == null || index < 0 || index >= widget.items.length) {
      return false;
    }
    final item = widget.items[index];
    // 点「复制」这一刻现读——弹菜单之后用户还能拖手柄改选区。
    final liveText = selectionController.selectedText;
    if (item.isCopy && liveText.isNotEmpty) {
      unawaited(copyChatMessageText(liveText));
    } else {
      item.onSelected();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      buildSelectionRegion(child: widget.child);
}
