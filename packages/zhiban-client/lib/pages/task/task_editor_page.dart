import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/widgets/task_editor_content.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_client/config/color_config.dart';

class TaskEditorPageArgs {
  const TaskEditorPageArgs({
    this.job,
    this.agents = const [],
    this.conversations = const [],
  });

  final CronJob? job;
  final List<AgentItem> agents;
  final List<ConversationItem> conversations;
}

class TaskEditorPage extends StatelessWidget {
  const TaskEditorPage({required this.args, super.key});

  final TaskEditorPageArgs args;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: args.job == null ? '新建任务' : '编辑任务'
      ),
      body: SafeArea(
        child: TaskEditorContent(
          job: args.job,
          agents: args.agents,
          conversations: args.conversations,
          showHeader: false,
          onCancel: () => context.pop(),
          onSubmit: (draft) => context.pop(draft),
        ),
      ),
    );
  }
}
