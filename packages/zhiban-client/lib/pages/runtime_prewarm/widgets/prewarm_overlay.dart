import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

import '../models/prewarm_group.dart';
import '../models/prewarm_task.dart';
import '../providers/prewarm_providers.dart';

/// 浮层标题（纯函数，便于单测）。degraded 不撒谎："已转为按需初始化"而非"已就绪"。
/// 一级聚合行用进度条展示进度,故标题**不再带 x/y 计数**。
String prewarmTitle({
  required bool hasActive,
  required bool hasFailed,
  required bool degraded,
  bool isEnsuring = false,
}) {
  if (hasActive || isEnsuring) return '正在准备运行环境';
  if (hasFailed) return '部分准备失败';
  if (degraded) return '已转为按需初始化';
  return '运行环境已就绪';
}

/// doc-10 §8.5 右下角登录预热任务浮层（§5b 聚合准备视图）。
/// 挂在应用全局展示层；watch prewarmControllerProvider，全部终态且无失败后自动收起。
/// 不把后端原子任务平铺：聚合成「初始化运行环境」+「加载/更新数字员工 - 名」两层,一级用进度条。
class PrewarmOverlay extends ConsumerStatefulWidget {
  const PrewarmOverlay({super.key});

  @override
  ConsumerState<PrewarmOverlay> createState() => _PrewarmOverlayState();
}

class _PrewarmOverlayState extends ConsumerState<PrewarmOverlay> {
  static const _collapsedSize = 40.0;

  /// 收起圆形图标的左上角坐标；null = 用默认右下角锚点。拖动只作用于收起态，
  /// 展开卡片仍固定在默认位置（卡片内部有滚动区，跟拖手势会打架）。
  Offset? _collapsedPosition;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(prewarmControllerProvider);
    if (!state.visible) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    // 卡片宽度响应式: max 300, 但不超过屏宽 - 32 (两侧各 16 留白)。
    final cardWidth = (media.size.width - 32).clamp(0.0, 300.0);
    // 移动端避让底部导航 + 安全区: bottom 内边距叠加 viewPadding.bottom + 估算导航高度。
    // (桌面 viewPadding.bottom 通常为 0, 故等价于固定 16。)
    final bottomInset = 16.0 +
        media.viewPadding.bottom +
        (media.size.width < 600 ? 72.0 : 0.0); // 移动端底部 NavigationBar ~64 + 余量

    if (state.collapsed) {
      final collapsedBottomInset =
          bottomInset + (PlatformUtils.isDesktop ? 72.0 : 0.0);
      final defaultPosition = Offset(
        media.size.width - 16 - _collapsedSize,
        media.size.height - collapsedBottomInset - _collapsedSize,
      );
      final position = _clampToScreen(
        _collapsedPosition ?? defaultPosition,
        media.size,
      );
      return Positioned(
        left: position.dx,
        top: position.dy,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _collapsedPosition = _clampToScreen(
                (_collapsedPosition ?? defaultPosition) + details.delta,
                media.size,
              );
            });
          },
          child: _PrewarmCollapsedBar(state: state),
        ),
      );
    }

    return Positioned(
      right: 16,
      bottom: bottomInset,
      child: _PrewarmCard(state: state, width: cardWidth),
    );
  }

  Offset _clampToScreen(Offset offset, Size screenSize) {
    return Offset(
      offset.dx.clamp(0.0, screenSize.width - _collapsedSize),
      offset.dy.clamp(0.0, screenSize.height - _collapsedSize),
    );
  }
}

class _PrewarmCollapsedBar extends ConsumerWidget {
  const _PrewarmCollapsedBar({required this.state});

  final PrewarmState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(prewarmControllerProvider.notifier);
    final title = prewarmTitle(
      hasActive: state.hasActive,
      hasFailed: state.hasFailed,
      degraded: state.degraded,
      isEnsuring: state.ensuring,
    );
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: controller.expand,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFEFF1F5)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: _statusIcon(),
          ),
        ),
      ),
    );
  }

  Widget _statusIcon() {
    if (state.hasActive || state.ensuring) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CupertinoActivityIndicator(radius: 8),
      );
    }
    if (state.hasFailed) {
      return const Icon(CupertinoIcons.exclamationmark_circle,
          size: 16, color: Color(0xFFE5484D));
    }
    if (state.degraded) {
      return const Icon(CupertinoIcons.info_circle,
          size: 16, color: Color(0xFF1D5FD6));
    }
    return const Icon(CupertinoIcons.checkmark_circle,
        size: 16, color: Color(0xFF2BA471));
  }
}

class _PrewarmCard extends ConsumerStatefulWidget {
  const _PrewarmCard({required this.state, required this.width});

  final PrewarmState state;
  final double width;

  @override
  ConsumerState<_PrewarmCard> createState() => _PrewarmCardState();
}

class _PrewarmCardState extends ConsumerState<_PrewarmCard> {
  // 已展开的一级分组 key（'runtime' / 'de:<uuid>'）。默认折叠,点击展开看子项。
  final Set<String> _expanded = <String>{};

  PrewarmState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(prewarmControllerProvider.notifier);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        constraints: const BoxConstraints(maxHeight: 360),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEFF1F5)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context, controller),
            const Divider(height: 1, color: Color(0xFFEFF1F5)),
            Flexible(child: _body(controller)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, PrewarmController controller) {
    final title = prewarmTitle(
      hasActive: state.hasActive,
      hasFailed: state.hasFailed,
      degraded: state.degraded,
      isEnsuring: state.ensuring,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          if (state.hasActive || state.ensuring)
            const SizedBox(
              width: 16,
              height: 16,
              child: CupertinoActivityIndicator(radius: 8),
            )
          else if (state.hasFailed)
            const Icon(CupertinoIcons.exclamationmark_circle,
                size: 16, color: Color(0xFFE5484D))
          else if (state.degraded)
            // 降级不是"就绪": 用中性信息图标, 不用绿色对勾。
            const Icon(CupertinoIcons.info_circle,
                size: 16, color: Color(0xFF1D5FD6))
          else
            const Icon(CupertinoIcons.checkmark_circle,
                size: 16, color: Color(0xFF2BA471)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1D2129),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: '收起任务栏',
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: controller.collapse,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  CupertinoIcons.minus,
                  size: 14,
                  color: Color(0xFF86909C),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(PrewarmController controller) {
    final children = <Widget>[];

    if (state.errorText != null && state.errorText!.isNotEmpty) {
      children.add(_notice(state.errorText!, isError: true));
    }
    if (state.degraded) {
      children.add(_notice(
        '当前预热任务较多，已转为按需初始化；使用时会自动准备。',
        isError: false
      ));
    }

    // 聚合: 后端原子任务 → 「初始化运行环境」+「加载/更新数字员工」两层一级行,不平铺。
    final groups = aggregatePrewarmTasks(state.tasks);
    if (state.ensuring && groups.isEmpty) {
      children.add(_ensuringPlaceholder());
    }
    for (final g in groups) {
      children.add(_groupTile(g));
    }

    if (state.hasFailed || (state.errorText?.isNotEmpty ?? false)) {
      children.add(_retryButton(controller));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _ensuringPlaceholder() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            '初始化运行环境',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF1D2129),
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            child: SizedBox(
              height: 4,
              child: LinearProgressIndicator(
                backgroundColor: Color(0xFFF2F3F5),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1D5FD6)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(String text, {required bool isError}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFFECE8) : const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isError ? const Color(0xFFCB272D) : const Color(0xFF1D5FD6),
        ),
      ),
    );
  }

  /// 一级聚合行: 标题 + 简短状态 + 进度条; 可点击展开子项。
  Widget _groupTile(PrewarmGroup g) {
    final expanded = _expanded.contains(g.key);
    final (statusColor, _) = _groupStatusStyle(g);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            if (expanded) {
              _expanded.remove(g.key);
            } else {
              _expanded.add(g.key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        g.title,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF1D2129),
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      g.statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 12,
                      color: const Color(0xFF86909C),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                _progressBar(g),
              ],
            ),
          ),
        ),
        if (expanded)
          for (final c in g.children) _childRow(c),
      ],
    );
  }

  /// 进度条: value 为终态比例; total 未知 → 不确定进度态(null)。颜色随状态。
  Widget _progressBar(PrewarmGroup g) {
    final (statusColor, _) = _groupStatusStyle(g);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 4,
        child: LinearProgressIndicator(
          value: g.progress, // null → 不确定进度动画
          backgroundColor: const Color(0xFFF2F3F5),
          valueColor: AlwaysStoppedAnimation<Color>(statusColor),
        ),
      ),
    );
  }

  Widget _childRow(PrewarmChildRow c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 5, 14, 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              c.label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF4E5969)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _statusChip(c.status),
        ],
      ),
    );
  }

  /// 一级行简短状态色: 部分失败=红 / 初始化中=橙 / 准备中=蓝 / 已就绪=绿。
  (Color, Color) _groupStatusStyle(PrewarmGroup g) {
    if (g.hasFailed) {
      return (const Color(0xFFCB272D), const Color(0xFFFFECE8));
    }
    if (g.hasRetrying) {
      return (const Color(0xFFD25F00), const Color(0xFFFFF3E8));
    }
    if (g.hasActive) {
      return (const Color(0xFF1D5FD6), const Color(0xFFEAF2FF));
    }
    return (const Color(0xFF2BA471), const Color(0xFFE8F8F0));
  }

  Widget _statusChip(PrewarmTaskStatus s) {
    final (label, bg, fg) = _statusStyle(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  (String, Color, Color) _statusStyle(PrewarmTaskStatus s) {
    switch (s) {
      case PrewarmTaskStatus.succeeded:
        return ('已就绪', const Color(0xFFE8F8F0), const Color(0xFF2BA471));
      case PrewarmTaskStatus.failed:
        return ('失败', const Color(0xFFFFECE8), const Color(0xFFCB272D));
      case PrewarmTaskStatus.running:
        return ('准备中', const Color(0xFFEAF2FF), const Color(0xFF1D5FD6));
      case PrewarmTaskStatus.waitingInstance:
        return ('等待实例', const Color(0xFFFFF3E8), const Color(0xFFD25F00));
      case PrewarmTaskStatus.retrying:
        return ('初始化中', const Color(0xFFFFF3E8), const Color(0xFFD25F00));
      case PrewarmTaskStatus.pending:
        return ('排队中', const Color(0xFFF2F3F5), const Color(0xFF86909C));
      case PrewarmTaskStatus.unknown:
        return ('—', const Color(0xFFF2F3F5), const Color(0xFF86909C));
    }
  }

  Widget _retryButton(PrewarmController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: SizedBox(
        width: double.infinity,
        child: TextButton(
          onPressed: controller.retry,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('重新预热', style: TextStyle(fontSize: 13)),
        ),
      ),
    );
  }
}
