import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_avatar.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';

class AgentDetailContent extends StatelessWidget {
  const AgentDetailContent({
    super.key,
    required this.agent,
    required this.sourceLabel,
    required this.onChat,
  });

  final AgentItem agent;
  final String sourceLabel;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final desc =
        agent.description.trim().isEmpty ? '暂无简介' : agent.description.trim();
    final position = agent.positionLabel.trim();
    final skillNames = agent.skills
        .map((item) => item.skillName.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final appNames = dedupeCapabilityNames([
      ...agent.apps.map((item) => item.name),
      ...agent.configuredAppLabels.values,
    ]);
    final kbNames = dedupeCapabilityNames(
      agent.configuredKnowledgeBaseLabels.values.toList(growable: false),
    );
    final capabilityRows = visibleCapabilityRows(
      skillNames: skillNames,
      appNames: appNames,
      kbNames: kbNames,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AgentAvatar(url: agent.avatarUrl, size: 48),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      AgentSourceTag(
                        label: sourceLabel,
                        enterprise: sourceLabel != '我创建的',
                      ),
                      if (position.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        AgentPositionPill(label: position),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 16),
        Text(
          desc,
          style: const TextStyle(
            fontSize: 14,
            height: 1.6,
            color: Color(0xFF374151),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (capabilityRows.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 16),
          for (var i = 0; i < capabilityRows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            AgentCapabilityRow(
              label: capabilityRows[i].label,
              names: capabilityRows[i].names,
            ),
          ],
        ],
        const SizedBox(height: 28),
        Center(
          child: SizedBox(
            width: 200,
            height: 44,
            child: FilledButton.icon(
              onPressed: onChat,
              icon: const Icon(CupertinoIcons.chat_bubble_2_fill, size: 18),
              label: const Text(
                '去聊天',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
