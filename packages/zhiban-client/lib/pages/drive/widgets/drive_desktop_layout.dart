import 'package:flutter/material.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_content_skeleton.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_content_view.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_sidebar.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';

class DriveDesktopLayout extends StatelessWidget {
  const DriveDesktopLayout({super.key, this.showUnavailableState = false});

  final bool showUnavailableState;

  @override
  Widget build(BuildContext context) {
    if (showUnavailableState) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: DriveContentView(showUnavailableState: true),
      );
    }
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: DriveSidebar()
          ),
          Expanded(child: DriveContentView()),
        ],
      ),
    );
  }
}

class DriveInitialSkeleton extends StatelessWidget {
  const DriveInitialSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(width: 280, child: _DriveSidebarSkeleton(showTitle: true)),
        Expanded(child: DriveContentSkeleton()),
      ],
    );
  }
}

class _DriveSidebarSkeleton extends StatelessWidget {
  const _DriveSidebarSkeleton({required this.showTitle});

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEFF1F5))),
              ),
              child: const UiSkeletonBlock(width: 48, height: 22, radius: 8),
            ),
          const SizedBox(height: 10),
          const _DriveSidebarRowSkeleton(width: 84),
          const _DriveSidebarRowSkeleton(width: 76),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Divider(height: 1, color: Color(0xFFEFF1F5)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 0, bottom: 4),
              children: const [
                _DriveSidebarRowSkeleton(width: 92, depth: 0),
                _DriveSidebarRowSkeleton(width: 64, depth: 1),
                _DriveSidebarRowSkeleton(width: 120, depth: 2),
                _DriveSidebarRowSkeleton(width: 104, depth: 2),
                _DriveSidebarRowSkeleton(width: 76, depth: 1),
                SizedBox(height: 8),
                _DriveSidebarRowSkeleton(width: 92, depth: 0),
                _DriveSidebarRowSkeleton(width: 64, depth: 1),
                _DriveSidebarRowSkeleton(width: 116, depth: 2),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(height: 1, color: Color(0xFFF0F0F0)),
          ),
          const SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(top: 4, bottom: 4),
              child: _DriveSidebarRowSkeleton(width: 64),
            ),
          ),
        ],
      ),
    );
  }
}

class _DriveSidebarRowSkeleton extends StatelessWidget {
  const _DriveSidebarRowSkeleton({required this.width, this.depth = 0});

  final double width;
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12 + depth * 18, 2, 12, 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            const UiSkeletonBlock(width: 18, height: 18, radius: 6),
            const SizedBox(width: 8),
            UiSkeletonBlock(width: width, height: 14, radius: 7),
          ],
        ),
      ),
    );
  }
}
