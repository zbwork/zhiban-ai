import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';

class DigitalEmployeeSearchField extends ConsumerStatefulWidget {
  const DigitalEmployeeSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.mobile = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool mobile;

  @override
  ConsumerState<DigitalEmployeeSearchField> createState() =>
      _DigitalEmployeeSearchFieldState();
}

class _DigitalEmployeeSearchFieldState
    extends ConsumerState<DigitalEmployeeSearchField> {
  Timer? _debounce;
  late final TextEditingController _controller = widget.controller ??
      TextEditingController(text: ref.read(digitalEmployeeSearchProvider));

  @override
  void dispose() {
    _debounce?.cancel();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UiSearchField(
      hintText: '搜索数字员工',
      controller: _controller,
      focusNode: widget.focusNode,
      fillColor: const Color(0xFFF3F4F7),
      showBorder: !widget.mobile,
      onChanged: (value) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          ref.read(digitalEmployeeSearchProvider.notifier).setKeyword(value);
        });
      },
    );
  }
}
