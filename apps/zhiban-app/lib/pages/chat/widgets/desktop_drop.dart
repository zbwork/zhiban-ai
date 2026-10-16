import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class DesktopDrop extends StatefulWidget {
  const DesktopDrop({
    super.key,
    required this.child,
    required this.onDropFiles,
  });

  final Widget child;
  final ValueChanged<List<XFile>> onDropFiles;

  @override
  State<DesktopDrop> createState() => _DesktopDropState();
}

class _DesktopDropState extends State<DesktopDrop> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);
        if (details.files.isEmpty) return;
        widget.onDropFiles(details.files);
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: widget.child,
          ),
          if (_isDragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black38,
                  alignment: Alignment.center,
                  child: const Text(
                    '松开添加到对话',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
