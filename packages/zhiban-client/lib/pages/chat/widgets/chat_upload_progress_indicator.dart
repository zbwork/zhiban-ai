import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 本地媒体上传中的轻量进度胶囊(P2/P3)。
///
/// 放在自己气泡左侧(与 [ChatSendStatusIndicator] 同位),仅在 uploading
/// (自己 pending + 本地路径 + 已知进度)时由 pane 选用;不改气泡/输入框/整体样式。
class ChatUploadProgressIndicator extends StatelessWidget {
  const ChatUploadProgressIndicator({
    super.key,
    required this.progress, // 0-100;<0 视为 indeterminate「上传中」
    required this.onCancel,
  });

  final int progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final label = progress >= 0 ? '上传中 $progress%' : '上传中';
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF).withValues(alpha: 0.88),
          border: Border.all(color: const Color(0xFFE5EAF2)),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: progress >= 0
                    ? CircularProgressIndicator(
                        value: (progress.clamp(0, 100)) / 100,
                        strokeWidth: 2,
                        backgroundColor: const Color(0xFFE8F0FF),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF1677FF),
                        ),
                      )
                    : const CupertinoActivityIndicator(radius: 7),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF4E5969),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                  child: Text(
                    '取消',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFFF53F3F),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
