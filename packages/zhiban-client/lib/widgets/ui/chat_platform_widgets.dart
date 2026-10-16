import 'package:flutter/widgets.dart';
import 'package:zhiban_core/chat/chat_models.dart';

/// 平台入口提供组件，共享页面不导入移动实现。
typedef TouchPromptBuilder = Widget Function({
  Key? key,
  required FocusNode focusNode,
  required TextEditingController controller,
  required ValueChanged<ChatAttachmentPickKind> onPickAttachment,
  required VoidCallback onPickFromDrive,
  required ValueChanged<List<String>> onSend,
  VoidCallback? onStop,
  required bool isSending,
  bool enabled,
  bool sendReady,
  ValueChanged<String>? onNotify,
  String conversationUuid,
  bool showSkillButton,
  VoidCallback? onVoiceCall,
  bool voiceCallActive,
  bool voiceCallEnabled,
  VoidCallback? onVideoCall,
  bool videoCallActive,
  bool videoCallEnabled,
  bool allowAttachmentOnlySend,
  Map<String, String> skillIconUrls,
});

typedef TouchImageBuilder = Widget Function({
  Key? key,
  required Widget child,
  required VoidCallback onDismiss,
  VoidCallback? onDownload,
  VoidCallback? onNext,
  VoidCallback? onPrevious,
  bool hasMultipleImages,
});

abstract interface class SkillDraftInput {
  List<({String slug, String name})> get selectedSkills;
  void restoreSelectedSkills(List<({String slug, String name})> skills);
  void addSelectedSkill({required String slug, required String name});
}

class ChatPlatformWidgets extends InheritedWidget {
  const ChatPlatformWidgets({
    super.key,
    required this.promptInput,
    required this.imageViewer,
    required super.child,
  });

  final TouchPromptBuilder promptInput;
  final TouchImageBuilder imageViewer;

  static ChatPlatformWidgets of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatPlatformWidgets>()!;

  @override
  bool updateShouldNotify(ChatPlatformWidgets oldWidget) =>
      promptInput != oldWidget.promptInput ||
      imageViewer != oldWidget.imageViewer;
}
