import 'package:flutter/material.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/apps/providers/apps_providers.dart';
import 'package:zhiban_client/pages/apps/services/apps_service.dart';
import 'package:zhiban_client/pages/apps/widgets/app_webview_container.dart';
import 'package:zhiban_client/pages/workbench/models/workbench_app.dart';
import 'package:zhiban_client/pages/workbench/models/workbench_app_category.dart';
import 'package:zhiban_client/pages/workbench/providers/workbench_apps_provider.dart';

/// 「应用」入口（composer 工具栏触发）：复用客户端工作台应用列表，按分类展示用户入口应用。
/// 移动端：底部弹出的 modalBottomSheet（原交互不变）。
/// 桌面端：普通居中弹框（UiPickerDialog + UiSheetHeader 通用关闭按钮，不做成全屏）。
Future<void> showAppsPlazaSheet(
  BuildContext context, {
  required String conversationUuid,
}) {
  if (!PlatformUtils.isMobile) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (ctx) => UiPickerDialog(
        size: UiDialogSize.wide,
        maxHeight: 640,
        child: _AppsPlazaBody(
          conversationUuid: conversationUuid,
          header: (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 4),
            child: UiSheetHeader(
              title: '应用',
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.white,
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.78),
              child: _AppsPlazaBody(
                conversationUuid: conversationUuid,
                header: (ctx) => Column(
                  children: [
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5E8EF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '应用',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1D2129),
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded),
                            tooltip: '关闭',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 「应用」面板内容（搜索 + 分类 tab + 应用格子），移动端 sheet 与桌面端 dialog
/// 共用；差别只在 [header]（移动端拖拽把手+标题行，桌面端 UiSheetHeader）。
class _AppsPlazaBody extends ConsumerStatefulWidget {
  const _AppsPlazaBody({required this.conversationUuid, required this.header});

  final String conversationUuid;
  final WidgetBuilder header;

  @override
  ConsumerState<_AppsPlazaBody> createState() => _AppsPlazaBodyState();
}

class _AppsPlazaBodyState extends ConsumerState<_AppsPlazaBody> {
  final TextEditingController _searchController = TextEditingController();
  int _selectedIndex = 0;
  String _keyword = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appsAsync = ref.watch(workbenchAppsProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.header(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: UiSearchField(
            hintText: '搜索应用',
            showBorder: false,
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _keyword = value.trim();
                _selectedIndex = 0;
              });
            },
            onClear: () {
              setState(() => _keyword = '');
            },
          ),
        ),
        Flexible(
          child: appsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '应用加载失败：$e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF98A2B3)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(workbenchAppsProvider.notifier).refreshApps(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
            data: (state) => AppsWorkbenchGrid(
              categories: state.categories,
              selectedIndex: _selectedIndex,
              keyword: _keyword,
              conversationUuid: widget.conversationUuid,
              onSelectedIndexChanged: (index) =>
                  setState(() => _selectedIndex = index),
            ),
          ),
        ),
      ],
    );
  }
}

class AppsWorkbenchGrid extends ConsumerWidget {
  const AppsWorkbenchGrid({
    super.key,
    required this.categories,
    required this.selectedIndex,
    required this.keyword,
    required this.conversationUuid,
    required this.onSelectedIndexChanged,
  });

  final List<WorkbenchAppCategory> categories;
  final int selectedIndex;
  final String keyword;
  final String conversationUuid;
  final ValueChanged<int> onSelectedIndexChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nonEmptyCategories =
        categories.where((category) => category.apps.isNotEmpty).toList();
    final allApps = [
      for (final category in nonEmptyCategories) ...category.apps,
    ]..sort((a, b) => a.order.compareTo(b.order));
    final normalizedKeyword = keyword.toLowerCase();
    final searching = normalizedKeyword.isNotEmpty;

    final tabs = <String>[
      searching ? '搜索结果' : '常用应用',
      ...nonEmptyCategories.map((category) => category.categoryName),
    ];
    final safeSelectedIndex = selectedIndex < 0
        ? 0
        : selectedIndex >= tabs.length
            ? tabs.length - 1
            : selectedIndex;
    final visibleApps = _visibleApps(
      allApps: allApps,
      categories: nonEmptyCategories,
      selectedIndex: safeSelectedIndex,
      keyword: normalizedKeyword,
    );

    if (allApps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text('暂无可用应用', style: TextStyle(color: Color(0xFF98A2B3))),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: UiSegmentedTabs<int>(
            groupId: 'apps-plaza-category-tabs',
            height: 40,
            trackColor: Colors.transparent,
            trackPadding: EdgeInsets.zero,
            pillColor: const Color(0xFFEAF2FF),
            activeColor: const Color(0xFF0F6BFF),
            inactiveColor: const Color(0xFF4E5969),
            segmentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            current: safeSelectedIndex,
            onChanged: onSelectedIndexChanged,
            tabs: [
              for (var i = 0; i < tabs.length; i++)
                UiSegmentedTab(value: i, label: tabs[i]),
            ],
          ),
        ),
        Expanded(
          child: visibleApps.isEmpty
              ? const Center(
                  child: Text('暂无匹配应用',
                      style: TextStyle(color: Color(0xFF98A2B3))),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 520 ? 5 : 4;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 96,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: visibleApps.length,
                      itemBuilder: (ctx, i) => _WorkbenchAppTile(
                        app: visibleApps[i],
                        conversationUuid: conversationUuid,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  List<WorkbenchApp> _visibleApps({
    required List<WorkbenchApp> allApps,
    required List<WorkbenchAppCategory> categories,
    required int selectedIndex,
    required String keyword,
  }) {
    if (keyword.isNotEmpty) {
      return allApps
          .where((app) =>
              app.name.toLowerCase().contains(keyword) ||
              app.code.toLowerCase().contains(keyword) ||
              app.description.toLowerCase().contains(keyword))
          .toList();
    }
    if (selectedIndex == 0) {
      return allApps.take(8).toList();
    }
    final categoryIndex = selectedIndex - 1;
    if (categoryIndex < 0 || categoryIndex >= categories.length) {
      return <WorkbenchApp>[];
    }
    return categories[categoryIndex].apps;
  }
}

class _WorkbenchAppTile extends ConsumerWidget {
  const _WorkbenchAppTile({
    required this.app,
    required this.conversationUuid
  });

  final WorkbenchApp app;
  final String conversationUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color =
        _parseColor(app.color) ?? Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _launch(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: app.icon.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        app.icon,
                        width: 30,
                        height: 30,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Icon(Icons.apps_rounded, size: 24, color: color),
                      ),
                    )
                  : Icon(Icons.apps_rounded, size: 24, color: color),
            ),
            const SizedBox(height: 7),
            Text(
              app.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF1D2129)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launch(BuildContext context, WidgetRef ref) async {
    if (conversationUuid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先进入有效会话后再打开应用'))
      );
      return;
    }
    if (app.uuid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('应用暂不可用'))
      );
      return;
    }

    final svc = ref.read(appsBusServiceProvider);
    final state = generateCsrfState();
    final nonce = generateNonce();
    final messenger = ScaffoldMessenger.of(context);
    // 桌面端：应用广场本身是个普通居中弹框，点应用不关掉它，直接在上面再弹一个
    // 原生弹框（showAppWebViewDialog）加载 webview；应用广场留在下面，关掉应用
    // 弹框后能看到还开着的应用广场。移动端保持原交互不变：sheet pop + displayMode
    // 驱动的 openAppWebView（fullscreen/sidePanel/externalBrowser）。
    if (!PlatformUtils.isMobile) {
      try {
        final result = await svc.launch(
          appUuid: app.uuid,
          conversationUuid: conversationUuid,
          state: state,
          nonce: nonce,
        );
        if (!context.mounted) return;
        await showAppWebViewDialog(
          context,
          launchUrl: result.launchUrl,
          title: app.name,
        );
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('应用启动失败: $e')));
      }
      return;
    }

    final navigator = Navigator.of(context);
    try {
      final result = await svc.launch(
        appUuid: app.uuid,
        conversationUuid: conversationUuid,
        state: state,
        nonce: nonce,
      );
      navigator.pop();
      if (!context.mounted) return;
      await openAppWebView(
        context,
        launchUrl: result.launchUrl,
        displayMode: result.displayMode,
        title: app.name,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('应用启动失败: $e')));
    }
  }

  Color? _parseColor(String s) {
    if (s.isEmpty) return null;
    var hex = s.startsWith('#') ? s.substring(1) : s;
    if (hex.length == 6) hex = 'FF$hex';
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(v);
  }
}
