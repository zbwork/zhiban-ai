import 'package:zhiban_client/pages/task/widgets/task_editor_content.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/material.dart';

class TaskEditorDialog extends StatelessWidget {
  const TaskEditorDialog({
    this.job,
    this.agents = const <AgentItem>[],
    this.conversations = const <ConversationItem>[],
    super.key,
  });

  final CronJob? job;
  final List<AgentItem> agents;
  final List<ConversationItem> conversations;

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      child: TaskEditorContent(
        job: job,
        agents: agents,
        conversations: conversations,
        onCancel: () => Navigator.of(context).pop(),
        onSubmit: (draft) => Navigator.of(context).pop(draft),
      ),
    );
  }
}
