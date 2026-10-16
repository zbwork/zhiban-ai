import 'package:flutter/material.dart';

abstract final class ChatTheme {
  // ===== 知办AI 品牌主色 =====
  /// 知办AI 主绿（按钮、链接、用户气泡尾巴等高频强调色）。
  static const Color brandPrimary = Color(0xFF07C160);

  /// 知办AI 辅助靛蓝（agent 头像渐变、AI 强调）。
  static const Color brandIndigo = Color(0xFF4F46E5);

  /// 聊天页根背景：飞书式白色画布，降低工作区的灰感。
  static const Color pageBg = Color(0xFFFFFFFF);

  static const Color sidebarBg = Color(0xFFF6F9FF);

  /// 侧栏内与滚动条并存时的左右内容留白（滚动条仍贴面板右缘）。
  static const double sidebarContentGutter = 8;

  /// 侧栏列表行 hover（浅灰底，无描边）。
  static const Color sidebarRowHover = Color(0xFFF1F3F7);

  /// 侧栏列表行 active / 展开（比 hover 略深）。
  static const Color sidebarRowActive = Color(0xFFE8EBF0);

  /// active 且鼠标悬停时再略深一档。
  static const Color sidebarRowActiveHover = Color(0xFFE0E3EA);

  static const Color border = Color(0xFFEAEAEA);
  static const Color answerBg = Color(0xFFF3F6F6);
  static const Color questionBg = Color(0xFFDCEBFF);

  // ===== 办公协作气泡配色 =====
  /// 己方消息气泡背景：取飞书参考图的低饱和浅蓝。
  static const Color enterpriseSelfBubble = Color(0xFFDCEBFF);

  /// 己方消息气泡描边:飞书式扁平气泡不显示可见描边。
  static const Color enterpriseSelfBubbleBorder = Color(0x00FFFFFF);

  /// 己方消息阴影:保持扁平。
  static const Color enterpriseSelfBubbleShadow = Color(0x00000000);

  /// 对方 / Agent 消息气泡背景：飞书参考图里的浅灰气泡。
  static const Color enterprisePeerBubble = Color(0xFFF3F6F6);

  /// 对方 / Agent 消息气泡描边:保持扁平。
  static const Color enterprisePeerBubbleBorder = Color(0x00FFFFFF);

  /// 对方 / Agent 消息阴影:保持扁平。
  static const Color enterprisePeerBubbleShadow = Color(0x00000000);

  /// 气泡正文：近黑。
  static const Color enterpriseBubbleText = Color(0xFF191919);

  // 兼容旧命名:历史代码仍引用 wx* token,实际值已切到办公协作配色。
  static const Color wxUserBubble = enterpriseSelfBubble;
  static const Color wxUserBubbleText = enterpriseBubbleText;
  static const Color wxAiBubble = enterprisePeerBubble;
  static const Color wxAiBubbleBorder = enterprisePeerBubbleBorder;

  /// 在线状态点（绿色，与 chat.html `bg-[#07C160]` 对齐）。
  static const Color wxOnline = Color(0xFF07C160);

  /// 状态 chip：思考中（in progress）色调，对应 .oc-status-chip。
  static const Color statusLiveBg = Color(0xFFEEF2FF);
  static const Color statusLiveBorder = Color(0xFFC7D2FE);
  static const Color statusLiveText = Color(0xFF4338CA);

  /// 状态 chip：完成（done）色调，对应 .oc-status-chip.done。
  static const Color statusDoneBg = Color(0xFFECFDF5);
  static const Color statusDoneBorder = Color(0xFFA7F3D0);
  static const Color statusDoneText = Color(0xFF047857);

  /// 状态 chip：出错（error）色调。
  static const Color statusErrorBg = Color(0xFFFEF2F2);
  static const Color statusErrorBorder = Color(0xFFFECACA);
  static const Color statusErrorText = Color(0xFFB91C1C);

  /// 状态 chip：已停止（stopped）色调。
  static const Color statusStoppedBg = Color(0xFFF3F4F6);
  static const Color statusStoppedBorder = Color(0xFFE5E7EB);
  static const Color statusStoppedText = Color(0xFF4B5563);

  /// "停止"红色按钮（位于状态条最右侧）。
  static const Color stopBtnBg = Color(0xFFFFF5F5);
  static const Color stopBtnBorder = Color(0xFFFECACA);
  static const Color stopBtnText = Color(0xFFB91C1C);

  /// 执行过程容器（.oc-timeline）。
  static const Color timelineBg = Color(0xFFFAFAFA);
  static const Color timelineBorder = Color(0xFFEEF2F7);
  static const Color timelineText = Color(0xFF4B5563);
  static const Color timelineMeta = Color(0xFF9CA3AF);

  /// 用量小字。
  static const Color usageText = Color(0xFF98A2B3);
}
