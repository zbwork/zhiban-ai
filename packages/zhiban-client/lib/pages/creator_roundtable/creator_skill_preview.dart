import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

import 'services/creator_asset_workflow.dart';

class CreatorSkillPreview extends StatefulWidget {
  const CreatorSkillPreview({
    super.key,
    required this.title,
    required this.content,
    required this.onDownload,
  });

  final String title;
  final String content;
  final VoidCallback onDownload;

  @override
  State<CreatorSkillPreview> createState() => _CreatorSkillPreviewState();
}

class _CreatorSkillPreviewState extends State<CreatorSkillPreview> {
  late final _sections = _readSections(widget.content);
  int _index = 0;
  int _zoom = 100;

  List<({String title, String body})> _readSections(String content) {
    final headings = {...CreatorAssetKind.skill.sections, '来源'};
    final matches = RegExp(r'^##[ \t]+(.+?)[ \t]*$', multiLine: true)
        .allMatches(content)
        .where((match) => headings.contains(match[1]))
        .toList();
    if (matches.isEmpty) return [(title: '全文', body: content)];
    return [
      for (var index = 0; index < matches.length; index++)
        (
          title: matches[index][1]!,
          body: content
              .substring(matches[index].end,
                  index + 1 < matches.length ? matches[index + 1].start : null)
              .trim(),
        ),
    ];
  }

  void _select(int index) => setState(() => _index = index);
  void _scale(int delta) => setState(() => _zoom += delta);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final section = _sections[_index];
    return UiContentDialog(
      size: UiDialogSize.wide,
      maxHeight: 660,
      child: SizedBox(
        height: 620,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                title: widget.title,
                subtitle: '技能 · SKILL.md',
                onClose: () => Navigator.pop(context),
              ),
              const Divider(),
              Expanded(
                child: LayoutBuilder(builder: (context, constraints) {
                  final reader = SingleChildScrollView(
                    key: ValueKey(_index),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(section.title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 10),
                        SelectableText(
                          section.body,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize:
                                (theme.textTheme.bodyMedium?.fontSize ?? 14) *
                                    _zoom /
                                    100,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  );
                  if (_sections.length == 1) return reader;
                  if (constraints.maxWidth < 550) {
                    return Column(children: [
                      DropdownButton<int>(
                        isExpanded: true,
                        value: _index,
                        onChanged: (index) {
                          if (index != null) _select(index);
                        },
                        items: [
                          for (final (index, item) in _sections.indexed)
                            DropdownMenuItem(
                                value: index, child: Text(item.title)),
                        ],
                      ),
                      Expanded(child: reader),
                    ]);
                  }
                  return Row(children: [
                    SizedBox(
                      width: 180,
                      child: ListView(
                        children: [
                          for (final (index, item) in _sections.indexed)
                            ListTile(
                              dense: true,
                              selected: index == _index,
                              title: Text(item.title),
                              onTap: () => _select(index),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 16),
                    Expanded(child: reader),
                  ]);
                }),
              ),
              const Divider(),
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一节',
                    onPressed: _index == 0 ? null : () => _select(_index - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${_index + 1} / ${_sections.length}'),
                  IconButton(
                    tooltip: '下一节',
                    onPressed: _index == _sections.length - 1
                        ? null
                        : () => _select(_index + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  IconButton(
                    tooltip: '缩小',
                    onPressed: _zoom <= 75 ? null : () => _scale(-25),
                    icon: const Icon(Icons.remove),
                  ),
                  Text('$_zoom%'),
                  IconButton(
                    tooltip: '放大',
                    onPressed: _zoom >= 200 ? null : () => _scale(25),
                    icon: const Icon(Icons.add),
                  ),
                  FilledButton(
                    onPressed: widget.onDownload,
                    child: const Text('下载技能'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
