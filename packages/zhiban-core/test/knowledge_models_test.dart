import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:test/test.dart';

void main() {
  group('KbItem', () {
    test('parses scope flags', () {
      final shared = KbItem.fromJson(const {
        'uuid': 'u1',
        'name': '共享知识库',
        'scope': 'shared',
        'status': 'active',
      });
      expect(shared.isShared, true);
      expect(shared.isAgent, false);

      final agent = KbItem.fromJson(const {
        'uuid': 'u2',
        'name': '财务.知识库',
        'scope': 'agent',
        'status': 'active',
        'agentId': 'ag_001',
      });
      expect(agent.isAgent, true);
      expect(agent.agentId, 'ag_001');
    });
  });

  group('KbDocument', () {
    test('source label mapping', () {
      final d1 = KbDocument.fromJson(const {
        'uuid': 'u',
        'kbUuid': 'k',
        'fileUuid': 'f',
        'fileName': 'a.pdf',
        'sizeBytes': 1024,
        'source': 'drive_link',
        'status': 'ready',
        'chunksCount': 10,
        'createdAt': '2026-04-01T10:00:00Z',
      });
      expect(d1.sourceLabel, '来自云盘');
      expect(d1.statusLabel, '可用');
      expect(d1.kbFolderUuid, '');

      final d2 = KbDocument.fromJson(const {
        'uuid': 'u',
        'fileName': 'a',
        'sizeBytes': 0,
        'source': 'kb_upload',
        'status': 'pending',
      });
      expect(d2.sourceLabel, 'KB 内上传');
      expect(d2.statusLabel, '待处理');
    });

    test('status labels cover all states', () {
      for (final entry in {
        'pending': '待处理',
        'parsing': '解析中',
        'indexing': '索引中',
        'ready': '可用',
        'failed': '失败',
      }.entries) {
        final d = KbDocument.fromJson({
          'uuid': 'u',
          'fileName': 'x',
          'sizeBytes': 0,
          'source': 'kb_upload',
          'status': entry.key,
        });
        expect(d.statusLabel, entry.value, reason: entry.key);
      }
    });

    test('size formatting', () {
      final d = KbDocument.fromJson(const {
        'uuid': 'u',
        'fileName': 'big.pdf',
        'sizeBytes': 5 * 1024 * 1024, // 5MB
        'source': 'kb_upload',
        'status': 'ready',
      });
      expect(d.sizeDisplay.endsWith('MB'), true);
    });

    test('indexedAt parses optional', () {
      final d = KbDocument.fromJson(const {
        'uuid': 'u',
        'fileName': 'x',
        'sizeBytes': 0,
        'source': 'drive_link',
        'status': 'ready',
        'indexedAt': '2026-04-02T08:30:00Z',
      });
      expect(d.indexedAt, isNotNull);
      expect(d.indexedAt!.year, 2026);

      final d2 = KbDocument.fromJson(const {
        'uuid': 'u',
        'fileName': 'x',
        'sizeBytes': 0,
        'source': 'drive_link',
        'status': 'ready',
      });
      expect(d2.indexedAt, isNull);
    });
  });

  group('KbFolder', () {
    test('parses snake_case folder tree node', () {
      final folder = KbFolder.fromJson(const {
        'uuid': 'folder-1',
        'kb_uuid': 'kb-1',
        'parent_uuid': 'parent-1',
        'name': '制度资料',
        'path': '/制度资料',
        'created_at': '2026-06-01T10:00:00Z',
        'updated_at': '2026-06-01T11:00:00Z',
      });
      expect(folder.uuid, 'folder-1');
      expect(folder.kbUuid, 'kb-1');
      expect(folder.parentUuid, 'parent-1');
      expect(folder.name, '制度资料');
      expect(folder.updatedAt.hour, 11);
    });

    test('document parses kb_folder_uuid', () {
      final doc = KbDocument.fromJson(const {
        'uuid': 'doc-1',
        'kb_uuid': 'kb-1',
        'kb_folder_uuid': 'folder-1',
        'file_uuid': 'file-1',
        'file_name': 'a.pdf',
        'file_size': 100,
        'source': 'kb_upload',
        'status': 'ready',
      });
      expect(doc.kbFolderUuid, 'folder-1');
    });
  });
}
