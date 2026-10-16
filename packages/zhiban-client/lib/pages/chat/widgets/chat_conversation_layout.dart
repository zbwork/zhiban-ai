import 'package:zhiban_ui/utils/platform_utils.dart';

/// 会话详情布局配置。
/// 消息列表与底部输入框共用横向留白，避免移动端出现上下宽度不一致。
class ChatConversationLayout {
  const ChatConversationLayout._();

  static const double horizontalPaddingDesktop = 16;
  static const double horizontalPaddingMobile = 8;
  static const double bubbleWidthRatioDesktop = 0.86;
  static const double bubbleWidthRatioMobile = 0.9;

  static double horizontalPadding() {
    return PlatformUtils.isMobile
        ? horizontalPaddingMobile
        : horizontalPaddingDesktop;
  }

  static double maxBubbleWidthForContainer(double containerWidth) {
    final horizontalInset = horizontalPadding() * 2;
    final messageAvailableWidth =
        (containerWidth - horizontalInset).clamp(0.0, double.infinity);
    final ratio = PlatformUtils.isMobile
        ? bubbleWidthRatioMobile
        : bubbleWidthRatioDesktop;
    // 气泡最大宽度基于扣除列表留白后的可用消息区域计算(不再有头像占位)。
    return messageAvailableWidth * ratio;
  }
}
