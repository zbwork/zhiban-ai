class WorkbenchApp {
  const WorkbenchApp({
    required this.uuid,
    required this.name,
    required this.icon,
    required this.description,
    required this.code,
    required this.redirectType,
    required this.redirectUrl,
    required this.order,
    required this.color,
    required this.displayMode,
    required this.todoCount,
    required this.webview,
  });

  final String uuid;
  final String name;
  final String icon;
  final String description;
  final String code;
  final String redirectType;
  final String redirectUrl;
  final int order;
  final String color;
  final String displayMode;
  final int todoCount;
  final String webview;

  factory WorkbenchApp.fromJson(Map<String, dynamic> json) {
    return WorkbenchApp(
      uuid: json['uuid'] as String? ?? '',
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      description: json['description'] as String? ?? '',
      code: json['code'] as String? ?? '',
      redirectType: json['redirectType'] as String? ?? '',
      redirectUrl: json['redirectUrl'] as String? ?? '',
      order: json['order'] is int ? json['order'] as int : 0,
      color: json['color'] as String? ?? '',
      displayMode: json['displayMode'] as String? ?? 'side_panel',
      todoCount: json['todoCount'] is int ? json['todoCount'] as int : 0,
      webview: json['webview'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'name': name,
      'icon': icon,
      'description': description,
      'code': code,
      'redirectType': redirectType,
      'redirectUrl': redirectUrl,
      'order': order,
      'color': color,
      'displayMode': displayMode,
      'todoCount': todoCount,
      'webview': webview,
    };
  }
}
