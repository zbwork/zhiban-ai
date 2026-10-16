enum SidebarUpdateState {
  available(title: '新版本发布了', description: '点击立即更新'),
  checking(title: '检查更新中', isBusy: true),
  downloading(title: '下载新版中...', isBusy: true),
  downloadingFull(title: '正在下载完整安装包...', isBusy: true),
  downloaded(title: '更新包已下载', description: '点击开始升级'),
  preparing(title: '正在准备升级...', isBusy: true),
  readyToRestart(title: '安装已就绪', description: '点击重启应用'),
  installing(
    title: '正在安装更新…',
    description: '完成后将自动重启',
    isBusy: true,
  ),
  failed(title: '下载失败', description: '点击重试');

  const SidebarUpdateState({
    required this.title,
    this.description,
    this.isBusy = false,
  });

  final String title;
  final String? description;
  final bool isBusy;
}

enum SidebarUpdateAction { none, download, prepare, restart }
