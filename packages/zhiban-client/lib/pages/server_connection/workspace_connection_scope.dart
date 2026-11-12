import 'package:flutter/material.dart';

/// Desktop supplies workspace composition; shared UI never imports the App.
class WorkspaceConnectionScope extends InheritedWidget {
  const WorkspaceConnectionScope({
    super.key,
    required this.connect,
    required this.returnToLocal,
    required super.child,
  });
  final Future<void> Function(String address) connect;
  final Future<void> Function() returnToLocal;

  static WorkspaceConnectionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceConnectionScope>();

  @override
  bool updateShouldNotify(WorkspaceConnectionScope oldWidget) => false;
}
