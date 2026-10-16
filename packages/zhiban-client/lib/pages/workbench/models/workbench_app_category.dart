import 'workbench_app.dart';

class WorkbenchAppCategory {
  const WorkbenchAppCategory({
    required this.categoryName,
    required this.category,
    required this.apps,
  });

  final String categoryName;
  final String category;
  final List<WorkbenchApp> apps;

  factory WorkbenchAppCategory.fromJson(Map<String, dynamic> json) {
    return WorkbenchAppCategory(
      categoryName: json['categoryName'] as String? ?? '',
      category: json['category'] as String? ?? '',
      apps: (json['apps'] as List<dynamic>? ?? [])
          .map((item) => WorkbenchApp.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'categoryName': categoryName,
      'category': category,
      'apps': apps.map((app) => app.toJson()).toList(),
    };
  }
}
