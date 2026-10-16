import 'package:zhiban_client/network/user_refresh.dart';
import 'package:flutter/material.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

/// Shared mobile list feedback. The page owns request and controller lifecycles.
class UiPullToRefresh extends StatelessWidget {
  const UiPullToRefresh({
    super.key,
    required this.controller,
    required this.onRefresh,
    required this.child,
    this.enablePullUp = false,
    this.onLoading,
  });

  final RefreshController controller;
  final VoidCallback onRefresh;
  final Widget child;
  final bool enablePullUp;
  final VoidCallback? onLoading;

  @override
  Widget build(BuildContext context) => RefreshConfiguration(
        springDescription: const SpringDescription(
          mass: 1,
          stiffness: 364.718677686,
          damping: 35.2,
        ),
        child: SmartRefresher(
          controller: controller,
          onRefresh: () => UserRefresh.run(onRefresh),
          enablePullUp: enablePullUp,
          onLoading: onLoading,
          header: const ClassicHeader(
            idleText: '下拉刷新',
            releaseText: '释放刷新',
            refreshingText: '刷新中...',
            completeText: '刷新完成',
            failedText: '刷新失败',
          ),
          footer: const ClassicFooter(
            idleText: '上拉加载',
            canLoadingText: '释放加载',
            loadingText: '加载中...',
            noDataText: '没有更多了',
            failedText: '加载失败',
          ),
          child: child,
        ),
      );
}
