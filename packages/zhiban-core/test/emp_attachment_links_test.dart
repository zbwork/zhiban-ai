import 'package:test/test.dart';
import 'package:zhiban_core/emp/emp_attachment_links.dart';

void main() {
  test('duplicate suppression tolerates a literal percent in local filename',
      () {
    final blocks = suppressDuplicateAttachmentLinks([
      {
        'type': 'file',
        'local_artifact': {'artifact_id': 'fixture'},
        'name': '50%完成.pptx',
      },
      {
        'type': 'markdown',
        'text': '[下载文件](sandbox:/mnt/data/50%完成.pptx)',
      },
    ]);

    expect(blocks.last['text'], '');
  });

  test('duplicate suppression preserves valid percent escapes', () {
    final blocks = suppressDuplicateAttachmentLinks([
      {
        'type': 'file',
        'local_artifact': {'artifact_id': 'fixture'},
        'name': '50%完成.pptx',
      },
      {
        'type': 'markdown',
        'text': '[下载文件](sandbox:/mnt/data/50%25%E5%AE%8C%E6%88%90.pptx)',
      },
    ]);

    expect(blocks.last['text'], '');
  });
}
