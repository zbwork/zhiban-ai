import 'package:zhiban_client/routes/route_paths.dart';

class MainNavItem {
  final String mobileIconAsset;
  final String mobileIconAssetSelected;
  final double mobileIconWidth;
  final double mobileIconHeight;
  final double mobileSelectedIconWidth;
  final double mobileSelectedIconHeight;
  final String label;
  final String path;
  final bool opensMorePanel;

  /// 移动端底部导航栏单独显示的标签，为 null 时回退到 [label]。
  final String? mobileLabel;

  const MainNavItem({
    required this.mobileIconAsset,
    required this.mobileIconAssetSelected,
    required this.label,
    required this.path,
    this.mobileLabel,
    this.mobileIconWidth = 25,
    this.mobileIconHeight = 25,
    this.mobileSelectedIconWidth = 25,
    this.mobileSelectedIconHeight = 25,
    this.opensMorePanel = false,
  });
}

const _chatNavItem = MainNavItem(
  mobileIconAsset: 'assets/images/main_layout/mobile_nav/chat.svg',
  mobileIconAssetSelected:
      'assets/images/main_layout/mobile_nav/chat_selected.svg',
  label: '对话',
  path: RoutePaths.chat,
);
const _digitalEmployeeNavItem = MainNavItem(
  mobileIconAsset: 'assets/images/main_layout/mobile_nav/employees.svg',
  mobileIconAssetSelected:
      'assets/images/main_layout/mobile_nav/employees_selected.svg',
  label: '数字员工',
  path: RoutePaths.digitalEmployee,
);
const _skillsNavItem = MainNavItem(
  mobileIconAsset: 'assets/images/main_layout/mobile_nav/skills.svg',
  mobileIconAssetSelected:
      'assets/images/main_layout/mobile_nav/skills_selected.svg',
  label: '技能广场',
  mobileLabel: '技能',
  path: RoutePaths.inspire,
);
const _taskNavItem = MainNavItem(
  mobileIconAsset: 'assets/images/main_layout/mobile_nav/tasks.svg',
  mobileIconAssetSelected:
      'assets/images/main_layout/mobile_nav/tasks_selected.svg',
  label: '自动任务',
  mobileLabel: '任务',
  path: RoutePaths.task,
);

/// 桌面端沿用既有侧栏信息架构；不要因移动端入口收敛而改动此列表。
const mainNavItems = [
  _chatNavItem,
  _digitalEmployeeNavItem,
  _skillsNavItem,
  _taskNavItem,
  // 云盘是文件体系的统一入口。"知识库"是 Space 下与云盘并列的索引视图,
  // 渲染在云盘页内部的侧栏(§2 存储 UI 结构全景),不在主导航单列。
  MainNavItem(
    mobileIconAsset: 'assets/images/main_layout/mobile_nav/drive.svg',
    mobileIconAssetSelected:
        'assets/images/main_layout/mobile_nav/drive_selected.svg',
    label: '云盘',
    path: RoutePaths.drive,
  ),
  MainNavItem(
    mobileIconAsset: 'assets/images/main_layout/mobile_nav/contacts.svg',
    mobileIconAssetSelected:
        'assets/images/main_layout/mobile_nav/contacts_selected.svg',
    label: '通讯录',
    path: RoutePaths.contacts,
  ),
  MainNavItem(
    mobileIconAsset: 'assets/images/main_layout/mobile_nav/employees.svg',
    mobileIconAssetSelected:
        'assets/images/main_layout/mobile_nav/employees_selected.svg',
    label: '我的',
    path: RoutePaths.settings,
  ),
];
