import 'package:flutter/material.dart';

/// [UiSegmentedTabs] 的一个分段。
class UiSegmentedTab<T> {
  const UiSegmentedTab({required this.value, required this.label, this.icon});

  final T value;
  final String label;

  /// 可选的分段图标，渲染在文字左侧；不传保持原有纯文字分段的样子，不影响
  /// 现有调用方（比如移动端消息中心的"消息/未读"）。
  final IconData? icon;
}

/// 分段滑块切换控件（shadcn segmented 风格）：灰色轨道 + 白色胶囊随选中项左右滑动。
///
/// 胶囊位置/宽度按每个分段的**实际渲染尺寸**测量后跟随动画，因此同时支持等宽
/// （[expand]=true，各分段撑满轨道，如移动端底部三个 tab 页顶部的筛选条）和
/// 内容自适应宽度（[expand]=false，桌面端按文字宽度收缩）两种布局，不用为
/// 两种场景各写一份。
///
/// 不用 InkWell/Material elevation（项目约定禁用），点击态用 GestureDetector；
/// 胶囊滑动是唯一的动效，分段本身切换态不再有阴影/透明度过渡。
///
/// **跨子树复用**：有的页面切 tab 时 body 会整体换成不同的 widget 子树（例如
/// 技能广场"技能广场/我的技能"两个 tab 对应两套完全不同的布局），这种场景下
/// 若不给这个滑块控件一个跨重建仍稳定的身份，Flutter 会把新旧两处的实例当成
/// 无关的组件——内部测量出的胶囊位置状态被销毁重建，滑动动画就没了。这个身份
/// 判定不应该要求每个调用方各自建一个 GlobalKey 并记得往下传，因此这里自动按
/// `T` 类型 + 传入的 `tabs` 取值集合生成一个全局稳定 key 并复用（同一逻辑 tab
/// 组在整个 App 里只会有一份，这个假设对"页面级 tab 切换器"成立）。如果某个
/// 场景需要多个相同类型/取值的切换器同时存在（比如列表里重复渲染），显式传
/// [groupId] 区分，或者直接传 Flutter 标准的 [key] 参数覆盖自动生成的身份。
class UiSegmentedTabs<T> extends StatelessWidget {
  const UiSegmentedTabs({
    super.key,
    required this.tabs,
    required this.current,
    required this.onChanged,
    this.groupId,
    this.expand = false,
    this.height = 38,
    this.trackColor = const Color(0xFFF0F2F5),
    this.trackRadius = 10,
    this.pillColor = Colors.white,
    this.pillRadius,
    this.activeColor = const Color(0xFF1E66F5),
    this.inactiveColor = const Color(0xFF4E5969),
    this.fontSize = 14,
    this.segmentPadding = const EdgeInsets.symmetric(horizontal: 14),
    this.trackPadding = const EdgeInsets.all(3),
  });

  final List<UiSegmentedTab<T>> tabs;
  final T current;
  final ValueChanged<T> onChanged;

  /// 覆盖自动生成的跨子树身份标识；同一 [groupId] 的实例会共享测量状态。
  /// 不传时按 `T` + [tabs] 取值集合自动生成，多数场景不需要手动指定。
  final Object? groupId;

  /// true：各分段等宽撑满轨道（移动端整行筛选条）。
  /// false：分段按文字内容自适应宽度，轨道可横向滚动（桌面端）。
  final bool expand;

  final double height;
  final Color trackColor;
  final double trackRadius;
  final Color pillColor;
  final double? pillRadius;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final EdgeInsets segmentPadding;
  final EdgeInsets trackPadding;

  static final Map<String, GlobalKey> _autoKeys = {};

  GlobalKey _resolveStateKey() {
    final id = groupId ?? '$T:${tabs.map((t) => t.value).join(',')}';
    return _autoKeys.putIfAbsent('$id', () => GlobalKey());
  }

  @override
  Widget build(BuildContext context) {
    return _UiSegmentedTabsImpl<T>(
      key: _resolveStateKey(),
      tabs: tabs,
      current: current,
      onChanged: onChanged,
      expand: expand,
      height: height,
      trackColor: trackColor,
      trackRadius: trackRadius,
      pillColor: pillColor,
      pillRadius: pillRadius,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      fontSize: fontSize,
      segmentPadding: segmentPadding,
      trackPadding: trackPadding,
    );
  }
}

class _UiSegmentedTabsImpl<T> extends StatefulWidget {
  const _UiSegmentedTabsImpl({
    required super.key,
    required this.tabs,
    required this.current,
    required this.onChanged,
    required this.expand,
    required this.height,
    required this.trackColor,
    required this.trackRadius,
    required this.pillColor,
    required this.pillRadius,
    required this.activeColor,
    required this.inactiveColor,
    required this.fontSize,
    required this.segmentPadding,
    required this.trackPadding,
  });

  final List<UiSegmentedTab<T>> tabs;
  final T current;
  final ValueChanged<T> onChanged;
  final bool expand;
  final double height;
  final Color trackColor;
  final double trackRadius;
  final Color pillColor;
  final double? pillRadius;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final EdgeInsets segmentPadding;
  final EdgeInsets trackPadding;

  @override
  State<_UiSegmentedTabsImpl<T>> createState() =>
      _UiSegmentedTabsImplState<T>();
}

class _UiSegmentedTabsImplState<T> extends State<_UiSegmentedTabsImpl<T>> {
  final _trackKey = GlobalKey();
  final List<GlobalKey> _segmentKeys = [];
  Rect? _pillRect;

  @override
  void initState() {
    super.initState();
    _syncKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _UiSegmentedTabsImpl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _syncKeys() {
    while (_segmentKeys.length < widget.tabs.length) {
      _segmentKeys.add(GlobalKey());
    }
    if (_segmentKeys.length > widget.tabs.length) {
      _segmentKeys.removeRange(widget.tabs.length, _segmentKeys.length);
    }
  }

  void _measure() {
    if (!mounted) return;
    final trackBox =
        _trackKey.currentContext?.findRenderObject() as RenderBox?;
    final index = widget.tabs.indexWhere((t) => t.value == widget.current);
    if (trackBox == null || index < 0 || index >= _segmentKeys.length) return;
    final segBox =
        _segmentKeys[index].currentContext?.findRenderObject() as RenderBox?;
    if (segBox == null) return;
    final origin = segBox.localToGlobal(Offset.zero, ancestor: trackBox);
    final rect = origin & segBox.size;
    if (rect != _pillRect) setState(() => _pillRect = rect);
  }

  @override
  Widget build(BuildContext context) {
    final row = Row(
      key: _trackKey,
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.tabs.length; i++)
          _buildSegment(i, widget.tabs[i]),
      ],
    );
    final track = Container(
      padding: widget.trackPadding,
      decoration: BoxDecoration(
        color: widget.trackColor,
        borderRadius: BorderRadius.circular(widget.trackRadius),
      ),
      child: Stack(
        children: [
          if (_pillRect != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: _pillRect!.left,
              top: _pillRect!.top,
              width: _pillRect!.width,
              height: _pillRect!.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.pillColor,
                  borderRadius: BorderRadius.circular(widget.pillRadius ??
                      (widget.trackRadius - widget.trackPadding.top)
                          .clamp(0, widget.trackRadius)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x18101828),
                      blurRadius: 6,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          row,
        ],
      ),
    );
    return widget.expand
        ? track
        : SingleChildScrollView(scrollDirection: Axis.horizontal, child: track);
  }

  Widget _buildSegment(int index, UiSegmentedTab<T> tab) {
    final selected = tab.value == widget.current;
    final color = selected ? widget.activeColor : widget.inactiveColor;
    final label = Text(
      tab.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: widget.fontSize,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: color,
        // CJK 字体 ascent/descent 比例不对称，默认 leading 会让文字视觉上偏上/偏下
        // （跟 ui_input.dart 同一个坑）；纯文字时不明显，紧挨图标就看得出没对齐。
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    final segment = GestureDetector(
      key: _segmentKeys[index],
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onChanged(tab.value),
      child: Container(
        height: widget.height - widget.trackPadding.vertical,
        padding: widget.segmentPadding,
        alignment: Alignment.center,
        child: tab.icon == null
            ? label
            : Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(tab.icon, size: widget.fontSize + 1, color: color),
                  const SizedBox(width: 4),
                  label,
                ],
              ),
      ),
    );
    return widget.expand ? Expanded(child: segment) : segment;
  }
}
