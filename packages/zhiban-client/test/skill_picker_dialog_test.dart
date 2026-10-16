import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/services/skills_service.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_picker_dialog.dart';

void main() {
  testWidgets('desktop skill picker uses sidebar and single-column rows',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, String>? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skillsServiceProvider.overrideWithValue(_FakeSkillsService()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) => const SkillPickerDialog(
                      initialSelected: {'markdown': '文档转Markdown'},
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('skill_picker_desktop_sidebar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('skill_picker_skill_list')),
      findsOneWidget,
    );
    expect(find.byType(GridView), findsNothing);
    expect(find.text('办公学习'), findsOneWidget);
    expect(find.text('文档转Markdown'), findsOneWidget);
    expect(find.text('把多种文档转换为便于编辑的 Markdown'), findsOneWidget);
    expect(find.text('开源网站 · 30 人添加'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('skill_picker_row_daily-report')),
    );
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result?.keys, containsAll(<String>['markdown', 'daily-report']));
  });

  testWidgets('narrow skill picker keeps filters without fixed sidebar',
      (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skillsServiceProvider.overrideWithValue(_FakeSkillsService()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SkillPickerDialog(initialSelected: {})
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('skill_picker_desktop_sidebar')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('skill_picker_skill_list')),
      findsOneWidget,
    );
    expect(find.text('搜索技能'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakeSkillsService extends OpenClawSkillsService {
  static final _skills = <Skill>[
    Skill(
      uuid: 'skill-1',
      slug: 'markdown',
      displayName: '文档转Markdown',
      description: '把多种文档转换为便于编辑的 Markdown',
      source: 'open_source',
      categoryId: 1,
      status: 'active',
      installStatus: 'installed',
      isInstalled: true,
      supportsInstallAction: false,
      downloadCount: 30,
      versionCount: 1,
    ),
    Skill(
      uuid: 'skill-2',
      slug: 'daily-report',
      displayName: '代码日报',
      description: '统计 GitLab 与 GitHub 提交并生成日报',
      source: 'internal',
      categoryId: 1,
      status: 'active',
      installStatus: '',
      isInstalled: false,
      supportsInstallAction: false,
      downloadCount: 8,
      versionCount: 1,
    ),
  ];

  @override
  Future<List<SkillCategory>> listCategories() async => const [
        SkillCategory(id: 1, code: 'office_study', name: '办公学习', sortOrder: 1),
        SkillCategory(id: 2, code: 'daily_life', name: '生活日常', sortOrder: 2),
      ];

  @override
  Future<Map<String, dynamic>> listSkills({
    String? keyword,
    String? source,
    int? categoryId,
    int page = 1,
    int pageSize = 20,
    String? sortBy,
    String? sortOrder,
  }) async {
    final normalized = keyword?.trim().toLowerCase();
    final filtered = _skills.where((skill) {
      if (categoryId != null && skill.categoryId != categoryId) return false;
      if (normalized != null &&
          normalized.isNotEmpty &&
          !skill.displayTitle.toLowerCase().contains(normalized)) {
        return false;
      }
      return true;
    }).toList(growable: false);
    return {'list': filtered, 'total': filtered.length};
  }
}
