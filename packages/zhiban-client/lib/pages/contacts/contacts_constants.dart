import 'package:flutter/cupertino.dart';
import 'package:zhiban_core/contacts/contact_models.dart';

enum ContactsMode { agents, org }

// 通讯录保留紧凑的“全部 / 企业创建的”两层导航；企业创建的列表同时包含
// 组织员工与平台员工。数字员工页使用独立的四分类目录。
enum AgentListFilter { all, enterprise }

const contactsBreadcrumbStyle = TextStyle(
  fontSize: 16,
  color: Color(0xFF7A7F87),
  fontWeight: FontWeight.w700,
);

const contactsBreadcrumbCurrentStyle = TextStyle(
  fontSize: 16,
  color: Color(0xFF4B5563),
  fontWeight: FontWeight.w700,
);

const contactsListHeaderStyle = TextStyle(
  fontSize: 15,
  color: Color(0xFF6B7280),
  fontWeight: FontWeight.w700,
);

// 通讯录侧栏树三档字号（对齐 Claude Design PC 稿）：叶子行 / 文件夹与分类行 / 分组标题各自独立。
const contactsSidebarTextSize = 14.0;
const contactsSidebarFolderTextSize = 15.0;
const contactsSidebarSectionLabelTextSize = 12.5;

// 通讯录侧栏树共用色板：accent 蓝、选中态浅蓝背景、未选中主文本色。
const contactsSidebarAccentColor = Color(0xFF3762E0);
const contactsSidebarSelectedBgColor = Color(0xFFEEF2FF);
const contactsSidebarPrimaryTextColor = Color(0xFF1A1D29);

/// 搜索时按 contactSearchVisibleDepartmentIdsProvider 过滤掉命中数为 0 的部门；
/// [visibleIds] 为 null（关键字为空，或过滤结果尚未算出）时不过滤，展示全部。
List<ContactDepartment> filterVisibleDepartments(
  List<ContactDepartment> items,
  Set<String>? visibleIds,
) {
  if (visibleIds == null) return items;
  return items.where((d) => visibleIds.contains(d.id)).toList(growable: false);
}

/// [onTaps] 跟 [labels] 一一对应；某一项传 null（或整个参数省略）表示那一段
/// 不可点击——当前所在这一段（最后一项）通常不该点，其余祖先段可点击跳转。
/// [fontSize] 覆盖默认字号（移动端比 PC 稿字号小一档，见 contacts_mobile_pages.dart）。
List<Widget> contactsBreadcrumbWidgets(
  List<String> labels, {
  List<VoidCallback?>? onTaps,
  double? fontSize,
}) {
  final baseStyle = fontSize == null
      ? contactsBreadcrumbStyle
      : contactsBreadcrumbStyle.copyWith(fontSize: fontSize);
  final currentStyle = fontSize == null
      ? contactsBreadcrumbCurrentStyle
      : contactsBreadcrumbCurrentStyle.copyWith(fontSize: fontSize);
  final iconSize = fontSize == null ? 12.0 : fontSize - 1;

  final children = <Widget>[];
  for (var i = 0; i < labels.length; i++) {
    if (i > 0) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            CupertinoIcons.chevron_right,
            size: iconSize,
            color: const Color(0xFFA6A6A6),
          ),
        ),
      );
    }
    final onTap = onTaps != null && i < onTaps.length ? onTaps[i] : null;
    final label = Text(
      labels[i],
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: i == labels.length - 1 ? currentStyle : baseStyle,
    );
    children.add(
      onTap == null ? label : GestureDetector(onTap: onTap, child: label),
    );
  }
  return children;
}

List<String> contactsBreadcrumbLabels(String eyebrow, String title) {
  if (eyebrow.contains('组织')) {
    return ['组织架构', title];
  }
  return [title];
}

/// 从根部门一路找到 [selected] 的祖先链（含 selected 自己）；面包屑点击跳转
/// 靠这份带 id 的路径，纯名字的 [departmentBreadcrumbLabels] 只是它的展示版。
List<ContactDepartment> departmentBreadcrumbPath(
  List<ContactDepartment> departments,
  ContactDepartment? selected,
) {
  if (selected == null) return const [];

  List<ContactDepartment>? findPath(
    ContactDepartment department,
    List<ContactDepartment> parents,
  ) {
    final next = [...parents, department];
    if (department.id == selected.id) return next;
    for (final child in department.children) {
      final path = findPath(child, next);
      if (path != null) return path;
    }
    return null;
  }

  for (final department in departments) {
    final path = findPath(department, const []);
    if (path != null) return path;
  }
  return [selected];
}

List<String> departmentBreadcrumbLabels(
  List<ContactDepartment> departments,
  ContactDepartment? selected,
) {
  if (selected == null) return const ['成员列表'];
  return departmentBreadcrumbPath(departments, selected)
      .map((d) => d.name)
      .toList(growable: false);
}

List<ContactAgent> filteredAgents(
  ContactAgentsSnapshot snapshot,
  AgentListFilter filter,
) {
  switch (filter) {
    case AgentListFilter.enterprise:
      return [...snapshot.enterprise, ...snapshot.platform];
    case AgentListFilter.all:
      return snapshot.all;
  }
}

List<String> agentBreadcrumbLabels(AgentListFilter filter) {
  switch (filter) {
    case AgentListFilter.enterprise:
      return const ['数字员工', '企业创建的'];
    case AgentListFilter.all:
      return const ['数字员工'];
  }
}

String sourceLabel(String source) {
  switch (source) {
    case 'personal':
      return '我创建的';
    case 'enterprise':
      return '组织创建';
    case 'platform':
      return '平台创建';
    default:
      return '未分类';
  }
}

String agentCreatedByLabel(String source) {
  switch (source) {
    case 'personal':
      return '由我创建';
    case 'platform':
      return '由平台创建';
    default:
      return '由企业管理员创建';
  }
}

Color sourceColor(String source) {
  switch (source) {
    case 'personal':
      return const Color(0xFF7C3AED);
    case 'enterprise':
    case 'platform':
      return const Color(0xFF2563EB);
    default:
      return const Color(0xFF64748B);
  }
}

String emailValue(ContactPerson person) {
  final candidates = <String>[person.id, person.subtitle, person.source];
  for (final item in candidates) {
    final value = item.trim();
    if (value.contains('@') && value.contains('.')) return value;
  }
  return '未设置';
}
