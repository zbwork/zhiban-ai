import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:flutter/material.dart';

class SkillsSearchBar extends StatelessWidget {
  const SkillsSearchBar({
    required this.controller,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return UiSearchField(
      hintText: '搜索技能',
      fillColor: Colors.white,
      controller: controller,
      enabled: enabled,
      onChanged: (_) {},
    );
  }
}
