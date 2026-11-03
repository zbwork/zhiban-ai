import 'package:flutter/material.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_install_agent_dialog.dart';

void main() {
  testWidgets('damaged bound package can repair then use in original dialog',
      (tester) async {
    final skill = Skill(
        uuid: 's',
        slug: 's',
        displayName: '测试',
        description: '',
        source: 'builtin',
        status: 'active',
        installStatus: 'installed',
        downloadCount: 0,
        versionCount: 1,
        isInstalled: true);
    var repaired = false;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            builder: BotToastInit(),
            home: Scaffold(
                body: SkillInstallAgentDialog(
              skill: skill,
              localPackageHealthy: false,
              localAgents: [
                AgentItem(
                    agentId: 'e',
                    name: '员工',
                    description: '',
                    avatarUrl: '',
                    canManageSkills: true,
                    status: 'active',
                    isDefault: false,
                    syncStatus: 'synced',
                    lastSyncedAt: null,
                    skills: const [
                      AgentSkillItem(
                          slug: 's',
                          skillName: '测试',
                          status: 'active',
                          isInstalled: true)
                    ])
              ],
              onLocalAdd: (_) async {
                repaired = true;
              },
              onLocalUse: (_) async {},
            )))));
    expect(find.text('重新安装'), findsOneWidget);
    expect(find.text('使用'), findsNothing);
    await tester.tap(find.text('重新安装'));
    await tester.pumpAndSettle();
    expect(repaired, isTrue);
    expect(find.text('使用'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
