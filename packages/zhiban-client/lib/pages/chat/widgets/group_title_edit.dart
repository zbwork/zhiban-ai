import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

String normalizeGroupTitleInput(String value) => value.trim();

String? groupTitleValidationError(String value) {
  final normalized = normalizeGroupTitleInput(value);
  if (normalized.isEmpty) return '群名不能为空';
  if (normalized.runes.length > 64) return '群名最多 64 个字符';
  return null;
}

String groupRenameFailureMessage(Object error) {
  if (error is DioException && error.response?.statusCode == 403) {
    return '仅群主可修改群名';
  }
  return '修改群名失败';
}

class GroupTitleEdit extends StatefulWidget {
  const GroupTitleEdit({
    super.key,
    required this.title,
    required this.onSubmit,
    this.onInvalid,
    this.editable = true,
  });

  final String title;
  final Future<bool> Function(String title) onSubmit;
  final ValueChanged<String>? onInvalid;
  final bool editable;

  @override
  State<GroupTitleEdit> createState() => _GroupTitleEditState();
}

class _GroupTitleEditState extends State<GroupTitleEdit> {
  static const TextStyle _titleStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: Color(0xFF1D2129),
    height: 1.2,
  );

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _editing = false;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title);
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant GroupTitleEdit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.editable && oldWidget.editable) {
      _editing = false;
      _saving = false;
      _errorText = null;
      _controller.text = widget.title;
      _focusNode.unfocus();
    }
    if (!_editing && widget.title != oldWidget.title) {
      _controller.text = widget.title;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startEditing() {
    if (!widget.editable || _editing || _saving) return;
    setState(() {
      _editing = true;
      _errorText = null;
      _controller.text = widget.title;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  void _cancelEditing() {
    if (!_editing) return;
    setState(() {
      _editing = false;
      _saving = false;
      _errorText = null;
      _controller.text = widget.title;
    });
    _focusNode.unfocus();
  }

  void _handleFocusChange() {
    if (_editing && !_focusNode.hasFocus) {
      unawaited(_commit());
    }
  }

  Future<void> _commit() async {
    if (!_editing || _saving) return;
    final error = groupTitleValidationError(_controller.text);
    if (error != null) {
      widget.onInvalid?.call(error);
      setState(() => _errorText = error);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_editing) return;
        _focusNode.requestFocus();
      });
      return;
    }

    final normalized = normalizeGroupTitleInput(_controller.text);
    if (normalized == widget.title.trim()) {
      _cancelEditing();
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });
    final ok = await widget.onSubmit(normalized);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
      _errorText = null;
      _controller.text = ok ? normalized : widget.title;
    });
    _focusNode.unfocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelEditing();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_editing && widget.editable) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Focus(
          onKeyEvent: _handleKeyEvent,
          child: UiInputField(
            controller: _controller,
            focusNode: _focusNode,
            enabled: !_saving,
            maxLength: 64,
            onSubmitted: (_) => unawaited(_commit()),
            textStyle: _titleStyle,
            errorText: _errorText,
            borderRadius: 4,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            fillColor: Colors.white,
          ),
        ),
      );
    }

    final titleText = Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _titleStyle,
    );
    if (!widget.editable) return titleText;

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _startEditing,
        child: titleText,
      ),
    );
  }
}
