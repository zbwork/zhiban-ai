import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_employee_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_core/chat/chat_models.dart';

final communityEmployeeClientProvider =
    Provider((ref) => CommunityEmployeeCatalog());
final communitySkillClientProvider = Provider((ref) => CommunitySkillCatalog());

final communityEmployeesProvider = FutureProvider.autoDispose((ref) async {
  final rows = await ref.watch(communityEmployeeClientProvider).fetch();
  return rows
      .map((row) => AgentItem.fromJson({
            ...row,
            'intro': row['intro'] ?? '',
            'positionLabel': row['position_label'] ?? '',
            'model_primary': '',
            'metadata': {'system_prompt': row['system_prompt']},
            'supports_skill_bindings': false,
            'can_manage_skills': false,
          }))
      .toList(growable: false);
});

final communitySkillsProvider = FutureProvider.autoDispose((ref) async {
  final data = await ref.watch(communitySkillClientProvider).fetch();
  return (
    skills: (data['items'] as List)
        .map((row) => Skill.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false),
    categories: (data['categories'] as List)
        .map((row) =>
            SkillCategory.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false),
  );
});
