import 'package:flutter/cupertino.dart';

/// 模型能力标签用于展示；toolUse 同步给 Bus，作为自动备用模型的资格条件。
enum AiModelCapability {
  reasoning,
  toolUse,
  vision,
  webSearch,
  embedding;

  String get label {
    switch (this) {
      case AiModelCapability.reasoning:
        return '推理';
      case AiModelCapability.toolUse:
        return '工具调用';
      case AiModelCapability.vision:
        return '视觉';
      case AiModelCapability.webSearch:
        return '联网搜索';
      case AiModelCapability.embedding:
        return '向量';
    }
  }

  IconData get icon {
    switch (this) {
      case AiModelCapability.reasoning:
        return CupertinoIcons.lightbulb;
      case AiModelCapability.toolUse:
        return CupertinoIcons.wrench;
      case AiModelCapability.vision:
        return CupertinoIcons.eye;
      case AiModelCapability.webSearch:
        return CupertinoIcons.globe;
      case AiModelCapability.embedding:
        return CupertinoIcons.cube;
    }
  }

  /// 每种能力标签的专属配色，用于列表里的圆角徽标背景/图标着色——区分开
  /// 比统一用 primary 色更好认，参考 Cherry Studio 每种能力 tag 各自一个色。
  Color get badgeColor {
    switch (this) {
      case AiModelCapability.reasoning:
        return const Color(0xFF7C3AED);
      case AiModelCapability.toolUse:
        return const Color(0xFFF79009);
      case AiModelCapability.vision:
        return const Color(0xFF12B76A);
      case AiModelCapability.webSearch:
        return const Color(0xFF2F80ED);
      case AiModelCapability.embedding:
        return const Color(0xFF0891B2);
    }
  }
}
