import 'dart:convert';
import 'local_attachment.dart';
import 'local_model_client.dart';

/// Shared limits mirror the community helper submit contract.
class LocalTurnInput {
  static const maxMessage = 150000, maxPersona = 200000, maxHistory = 500000;
  static String content(String text, Iterable<LocalAttachment> files) => [
        text,
        for (final f in files)
          if (f.text.isEmpty)
            '附件：${f.name}（${f.size} 字节）。未提取文字，需通过本轮附件索引中的相对路径用本地工具处理；不要声称已读取、识别图片或执行文件。'
          else
            '附件：${f.name}\n<file_content>\n${f.text}\n</file_content>'
      ].where((s) => s.isNotEmpty).join('\n\n');

  static void validate(String message, String persona) {
    if (message.length > maxMessage) {
      throw const LocalModelException('消息和附件合计超过 150,000 字符，请拆分后发送');
    }
    if (persona.length > maxPersona) {
      throw const LocalModelException('员工人设和技能合计超过 200,000 字符，请减少绑定技能');
    }
  }

  static List<Map<String, String>> history(List<Map<String, String>> messages) {
    final kept = <Map<String, String>>[];
    var size = 2;
    for (final message in messages.reversed) {
      final next = jsonEncode(message).length + (kept.isEmpty ? 0 : 1);
      if (size + next > maxHistory) break;
      kept.insert(0, message);
      size += next;
    }
    while (kept.isNotEmpty && kept.first['role'] != 'user') {
      kept.removeAt(0);
    }
    return kept;
  }
}
