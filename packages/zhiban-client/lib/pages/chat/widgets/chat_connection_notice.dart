import 'package:flutter/cupertino.dart';

/// kicked / IM 连接异常时聊天区顶部的轻量提示条(P3)。
///
/// 放在消息列表上方,不遮挡消息 / 输入框,不改气泡 / 输入框样式。提供「重新登录」恢复入口
/// ([onReLogin] 由宿主 pane 接已有 `SessionService.clearSessionStorage()` + `/login`)。
/// 人↔人与群聊 pane 共用本组件。
class ChatConnectionNotice extends StatelessWidget {
  const ChatConnectionNotice({
    super.key,
    required this.onReLogin,
    this.message = '当前账号已在其他设备登录,IM 连接已断开',
  });

  final VoidCallback onReLogin;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF3E8), // 轻量橙底,与既有红色"加载失败"banner 区分
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle_fill,
            size: 16,
            color: Color(0xFFF77234),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A5A1E)),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onReLogin,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                '重新登录',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF165DFF),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
