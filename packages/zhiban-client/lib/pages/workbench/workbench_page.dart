import 'package:zhiban_client/network/user_refresh.dart';
import 'dart:typed_data';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_ui/config/skeleton_config.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'models/workbench_app.dart';
import 'models/workbench_app_category.dart';
import 'providers/workbench_apps_provider.dart';
import 'package:zhiban_client/pages/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 工作台 Flutter 的 [redirectUrl] 仅为路径字符串（可含 `?query`），补全前导 `/` 供 [GoRouter.go]。
String? workbenchNormalizeFlutterLocation(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  return t.startsWith('/') ? t : '/$t';
}

bool workbenchGoRouterHasRoute(BuildContext context, String location) {
  final loc = location.trim();
  if (loc.isEmpty) return false;
  final uri = Uri.parse(loc.startsWith('/') ? loc : '/$loc');
  if (uri.path.isEmpty) return false;
  final match = GoRouter.of(context).configuration.findMatch(uri);
  return !match.isError && match.isNotEmpty;
}

class WorkbenchPage extends ConsumerStatefulWidget {
  const WorkbenchPage({super.key});

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(workbenchAppsProvider.notifier).refreshApps();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appsState = ref.watch(workbenchAppsProvider);
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: SafeArea(
        top: false,
        child: appsState.when(
          data: (data) => WorkbenchDesktopShell(state: data),
          error: (error, _) => _WorkbenchError(
            message: error.toString(),
            onRetry: () => UserRefresh.run(() => ref.read(workbenchAppsProvider.notifier).refreshApps()),
          ),
          loading: () => const WorkbenchLoading(showTabs: true),
        ),
      ),
    );
  }
}

enum _WorkbenchTabType { home, web }

class _WorkbenchTabData {
  const _WorkbenchTabData({
    required this.id,
    required this.type,
    required this.title,
    this.url,
    this.iconBytes,
    this.iconUrl,
  });

  final String id;
  final _WorkbenchTabType type;
  final String title;
  final Uri? url;
  final Uint8List? iconBytes;
  final String? iconUrl;

  bool get closable => type != _WorkbenchTabType.home;

  _WorkbenchTabData copyWith({
    String? title,
    Uri? url,
    Uint8List? iconBytes,
    String? iconUrl,
  }) {
    return _WorkbenchTabData(
      id: id,
      type: type,
      title: title ?? this.title,
      url: url ?? this.url,
      iconBytes: iconBytes ?? this.iconBytes,
      iconUrl: iconUrl ?? this.iconUrl,
    );
  }

  factory _WorkbenchTabData.home() {
    return const _WorkbenchTabData(
      id: 'home',
      type: _WorkbenchTabType.home,
      title: '工作台',
    );
  }

  factory _WorkbenchTabData.web({
    required String id,
    required String title,
    required Uri url,
  }) {
    return _WorkbenchTabData(
      id: id,
      type: _WorkbenchTabType.web,
      title: title,
      url: url,
      iconBytes: null,
      iconUrl: null,
    );
  }
}

class WorkbenchDesktopShell extends StatefulWidget {
  const WorkbenchDesktopShell({
    super.key,
    required this.state,
    this.onOpenApp
  });

  final WorkbenchAppsState state;
  final Future<void> Function(WorkbenchApp)? onOpenApp;

  @override
  State<WorkbenchDesktopShell> createState() => _WorkbenchDesktopShellState();
}

class _WorkbenchDesktopShellState extends State<WorkbenchDesktopShell> {
  final List<_WorkbenchTabData> _tabs = [_WorkbenchTabData.home()];
  String _activeTabId = 'home';
  int _tabSeed = 0;

  Future<void> _openWorkbenchTab(WorkbenchApp app) async {
    final override = widget.onOpenApp;
    if (override != null) {
      await override(app);
      return;
    }
    final url = await _buildWorkbenchUrl(app);
    if (!mounted) return;

    if (url != null) {
      final tabId = 'tab_${_tabSeed++}';
      setState(() {
        _tabs.add(
          _WorkbenchTabData.web(
            id: tabId,
            title: app.name.isEmpty ? '新标签页' : app.name,
            url: url,
          ),
        );
        _activeTabId = tabId;
      });
      return;
    }

    final location = workbenchNormalizeFlutterLocation(app.redirectUrl);
    if (location != null &&
        location.isNotEmpty &&
        workbenchGoRouterHasRoute(context, location)) {
      if (!mounted) return;
      context.go(location);
      return;
    }

    if (!mounted) return;
    BotToast.showText(
      text: '功能开发中，请到手机端查看',
      align: Alignment.center
    );
  }

  Future<Uri?> _buildWorkbenchUrl(WorkbenchApp app) async {
    final raw = _resolveWebUrl(app);
    if (raw == null) return null;
    final normalized = normalizeUrl(raw);
    if (normalized == null) return null;
    return attachDashboardTokens(normalized);
  }

  String? _resolveWebUrl(WorkbenchApp app) {
    final preferred = app.webview.trim();
    if (preferred.isNotEmpty) return preferred;

    final redirectUrl = app.redirectUrl.trim();
    if (redirectUrl.isNotEmpty && app.redirectType != 'flutter') {
      return redirectUrl;
    }

    return null;
  }

  void _closeTab(String tabId) {
    if (tabId == 'home') return;
    final index = _tabs.indexWhere((tab) => tab.id == tabId);
    if (index < 0) return;

    setState(() {
      _tabs.removeAt(index);
      if (_activeTabId == tabId) {
        final nextIndex = index > 0 ? index - 1 : 0;
        _activeTabId = _tabs[nextIndex].id;
      }
    });
  }

  void _selectTab(String tabId) {
    if (_activeTabId == tabId) return;
    setState(() => _activeTabId = tabId);
  }

  void _renameTab(String tabId, String title) {
    final index = _tabs.indexWhere((tab) => tab.id == tabId);
    if (index < 0) return;
    if (_tabs[index].title == title) return;
    setState(() {
      _tabs[index] = _tabs[index].copyWith(title: title);
    });
  }

  void _updateTabIcon(String tabId, Uint8List? iconBytes) {
    final index = _tabs.indexWhere((tab) => tab.id == tabId);
    if (index < 0) return;
    if (_tabs[index].iconBytes == iconBytes) return;
    setState(() {
      _tabs[index] = _tabs[index].copyWith(iconBytes: iconBytes);
    });
  }

  void _updateTabIconUrl(String tabId, String? iconUrl) {
    final index = _tabs.indexWhere((tab) => tab.id == tabId);
    if (index < 0) return;
    if (_tabs[index].iconUrl == iconUrl) return;
    setState(() {
      _tabs[index] = _tabs[index].copyWith(iconUrl: iconUrl);
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeIndex = _tabs.indexWhere((tab) => tab.id == _activeTabId);
    final selectedIndex = activeIndex >= 0 ? activeIndex : 0;

    return Column(
      children: [
        _WorkbenchTabStrip(
          tabs: _tabs,
          activeTabId: _activeTabId,
          onTabSelected: _selectTab,
          onTabClosed: _closeTab,
        ),
        Expanded(
          child: IndexedStack(
            index: selectedIndex,
            children: _tabs.map((tab) {
              switch (tab.type) {
                case _WorkbenchTabType.home:
                  return WorkbenchHomeView(
                    key: const ValueKey('workbench-home'),
                    state: widget.state,
                    onOpenApp: _openWorkbenchTab,
                    compact: false,
                  );
                case _WorkbenchTabType.web:
                  return BrowserTab(
                    key: ValueKey(tab.id),
                    initialTitle: tab.title,
                    initialUrl: tab.url!,
                    onTitleChanged: (title) => _renameTab(tab.id, title),
                    onIconChanged: (iconBytes) =>
                        _updateTabIcon(tab.id, iconBytes),
                    onIconUrlChanged: (iconUrl) =>
                        _updateTabIconUrl(tab.id, iconUrl),
                  );
              }
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _WorkbenchTabStrip extends StatelessWidget {
  const _WorkbenchTabStrip({
    required this.tabs,
    required this.activeTabId,
    required this.onTabSelected,
    required this.onTabClosed,
  });

  final List<_WorkbenchTabData> tabs;
  final String activeTabId;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabClosed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 42,
      padding: const EdgeInsets.only(top: 4, right: 8),
      decoration: BoxDecoration(
        color: ColorConfig.chromeBackground
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...tabs.map(
                    (tab) => _WorkbenchTabChip(
                      label: tab.title,
                      iconBytes: tab.iconBytes,
                      iconUrl: tab.iconUrl,
                      active: tab.id == activeTabId,
                      closable: tab.closable,
                      onTap: () => onTabSelected(tab.id),
                      onClose: tab.closable ? () => onTabClosed(tab.id) : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkbenchTabChip extends StatefulWidget {
  const _WorkbenchTabChip({
    required this.label,
    required this.iconBytes,
    required this.iconUrl,
    required this.active,
    required this.closable,
    required this.onTap,
    this.onClose,
  });

  final String label;
  final Uint8List? iconBytes;
  final String? iconUrl;
  final bool active;
  final bool closable;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  State<_WorkbenchTabChip> createState() => _WorkbenchTabChipState();
}

class _WorkbenchTabChipState extends State<_WorkbenchTabChip> {
  bool _hovered = false;
  bool _closeHovered = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.active
        ? ColorConfig.pageBackground
        : _hovered
            ? const Color(0xFFF5F8FF)
            : const Color(0xFFEAF0FF);
    final textColor =
        widget.active ? const Color(0xFF162033) : const Color(0xFF67738A);

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          setState(() {
            _hovered = false;
            _closeHovered = false;
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // 标签 hover 改为即时状态切换，避免 hover 过渡动画。
          child: Container(
            constraints: const BoxConstraints(minWidth: 116, maxWidth: 196),
            height: 40,
            padding: const EdgeInsets.only(left: 10, right: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TabFavicon(
                      iconBytes: widget.iconBytes,
                      iconUrl: widget.iconUrl,
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          widget.active ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                    ),
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.start,
                    ),
                  ),
                ),
                if (widget.closable) ...[
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _closeHovered = true),
                    onExit: (_) => setState(() => _closeHovered = false),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onClose,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: _closeHovered
                              ? const Color(0x12101828)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: Color(0xFF7E8695),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabFavicon extends StatelessWidget {
  const _TabFavicon({this.iconBytes, this.iconUrl});

  final Uint8List? iconBytes;
  final String? iconUrl;

  @override
  Widget build(BuildContext context) {
    if (iconBytes != null && iconBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          iconBytes!,
          width: 16,
          height: 16,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    if (iconUrl != null && iconUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: UiNetworkImage(
          imageUrl: iconUrl!,
          width: 16,
          height: 16,
          fit: BoxFit.cover,
          placeholderBuilder: (_, __) => _buildFallback(),
          errorBuilder: (_, __, ___) => _buildFallback(),
        ),
      );
    }

    return _buildFallback();
  }

  Widget _buildFallback() {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: const Color(0xFFD9E4FF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(
        Icons.public_rounded,
        size: 11,
        color: Color(0xFF4B6DD9),
      ),
    );
  }
}

class WorkbenchHomeView extends StatelessWidget {
  const WorkbenchHomeView({
    super.key,
    required this.state,
    required this.onOpenApp,
    required this.compact,
  });

  final WorkbenchAppsState state;
  final Future<void> Function(WorkbenchApp) onOpenApp;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.isFromCache)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              '当前显示缓存数据，接口成功后会自动更新。',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF8A5A00)
              ),
            ),
          ),
        Expanded(
          child: state.categories.isEmpty
              ? const _WorkbenchEmpty()
              : ListView.separated(
                  itemCount: state.categories.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 16),
                  itemBuilder: (context, index) => _CategorySection(
                    category: state.categories[index],
                    onOpenApp: onOpenApp,
                  ),
                  padding: EdgeInsets.fromLTRB(
                    0,
                    compact ? 12 : 16,
                    0,
                    16
                  ),
                ),
        ),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.onOpenApp
  });

  final WorkbenchAppCategory category;
  final Future<void> Function(WorkbenchApp) onOpenApp;

  @override
  Widget build(BuildContext context) {
    final sortedApps = [...category.apps]
      ..sort((a, b) => a.order.compareTo(b.order));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            category.categoryName.isEmpty
                ? category.category
                : category.categoryName,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF162033),
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: sortedApps.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 56,
            ),
            itemBuilder: (context, index) => _AppGridItem(
              app: sortedApps[index],
              onOpenApp: onOpenApp
            ),
          ),
        ],
      ),
    );
  }
}

class _AppGridItem extends StatelessWidget {
  const _AppGridItem({
    required this.app,
    required this.onOpenApp
  });

  final WorkbenchApp app;
  final Future<void> Function(WorkbenchApp) onOpenApp;

  void _handleTap() {
    onOpenApp(app);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF8FAFD),
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: UiNetworkImage(
                  imageUrl: app.icon,
                  width: 28,
                  height: 28,
                  fit: BoxFit.cover,
                  placeholderBuilder: (_, __) => Container(
                    width: 28,
                    height: 28,
                    color: const Color(0xFFF0F3F8),
                  ),
                  errorBuilder: (_, __, ___) => Container(
                    width: 28,
                    height: 28,
                    color: const Color(0xFFF0F3F8),
                    child: const Icon(
                      Icons.apps_rounded,
                      color: Colors.grey,
                      size: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  app.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF162033),
                  ),
                ),
              ),
              if (app.todoCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2457F5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${app.todoCount}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
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

class WorkbenchLoading extends StatelessWidget {
  const WorkbenchLoading({super.key, required this.showTabs});

  final bool showTabs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTabs)
          Container(
            height: 54,
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            decoration: const BoxDecoration(
              color: SkeletonConfig.surface,
              border: Border(
                bottom: BorderSide(color: SkeletonConfig.block)
              ),
            ),
            child: Row(
              children: [
                _WorkbenchLoadingTab(width: 124),
                const SizedBox(width: 8),
                _WorkbenchLoadingTab(width: 102),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            itemCount: 3,
            separatorBuilder: (context, index) => const SizedBox(height: 16),
            itemBuilder: (context, index) => _SkeletonCategoryCard(
              itemCount: index == 0
                  ? 6
                  : index == 1
                      ? 4
                      : 8,
            ),
          ),
        ),
      ],
    );
  }
}

class _SkeletonCategoryCard extends StatelessWidget {
  const _SkeletonCategoryCard({required this.itemCount});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SkeletonBlock(width: 80, height: 16, radius: 8),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: itemCount,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 56,
            ),
            itemBuilder: (context, itemIndex) => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFD),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const _SkeletonBlock(width: 28, height: 28, radius: 8),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonBlock(
                          width: itemIndex.isEven ? 52 : 64,
                          height: 11,
                          radius: 6,
                        ),
                        const SizedBox(height: 6),
                        _SkeletonBlock(
                          width: itemIndex.isEven ? 68 : 44,
                          height: 11,
                          radius: 6,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkbenchLoadingTab extends StatelessWidget {
  const _WorkbenchLoadingTab({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 34,
      decoration: BoxDecoration(
        color: SkeletonConfig.block,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        border: Border.all(color: SkeletonConfig.surface),
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.width,
    required this.height,
    required this.radius,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: SkeletonConfig.block,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _WorkbenchError extends StatelessWidget {
  const _WorkbenchError({
    required this.message,
    required this.onRetry
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 44, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            '应用列表加载失败',
            style: Theme.of(context).textTheme.titleMedium
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => onRetry(),
            child: const Text('重新加载')
          ),
        ],
      ),
    );
  }
}

class _WorkbenchEmpty extends StatelessWidget {
  const _WorkbenchEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '暂无可展示的应用',
        style: TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
      ),
    );
  }
}
