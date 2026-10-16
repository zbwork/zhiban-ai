import 'package:zhiban_client/config/client_assets.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';

String digitalEmployeeWelcomeMessage(AgentItem agent) {
  final configured = agent.welcomeMsg.trim();
  if (configured.isNotEmpty) return configured;
  final name =
      agent.displayName.trim().isEmpty ? '数字员工' : agent.displayName.trim();
  return '你好，我是你的得力小帮手-$name，繁琐事务我来承接，让工作轻松一点。';
}

class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    this.bottomInset = 0,
    this.message = '暂无消息，开始新的对话吧',
  });

  final double bottomInset;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              package: ClientAssets.packageName,
              'assets/images/chat_empty_illustration.png',
              width: 184,
              height: 134,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF8B98AD),
                height: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: 34,
              height: 2,
              decoration: BoxDecoration(
                color: const Color(0xFFDDE5F2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
