import 'package:zhiban_core/drive/drive_models.dart';
import 'package:test/test.dart';

void main() {
  group('DriveSpace', () {
    test('displayName prefers name, falls back by kind', () {
      expect(
        DriveSpace.fromJson(const {
          'uuid': '1',
          'kind': 'personal',
          'name': '',
          'status': 'active'
        }).displayName,
        '我的空间',
      );
      expect(
        DriveSpace.fromJson(const {
          'uuid': '2',
          'kind': 'tenant',
          'name': '某某公司',
          'status': 'active'
        }).displayName,
        '某某公司',
      );
    });

    test('isOrg true for tenant/department/shared', () {
      expect(DriveSpace.fromJson(const {'uuid': '1', 'kind': 'personal'}).isOrg,
          false);
      for (final k in ['tenant', 'department', 'shared']) {
        expect(DriveSpace.fromJson({'uuid': 'x', 'kind': k}).isOrg, true);
      }
    });

    test('parses shared folder description', () {
      final sp = DriveSpace.fromJson(const {
        'uuid': 's1',
        'kind': 'shared',
        'name': 'AI项目',
        'description': '项目资料协作',
        'status': 'active',
      });
      expect(sp.description, '项目资料协作');
    });
  });

  group('DriveFolder (snake_case)', () {
    test('parses kind flags + parent_uuid + agent_id', () {
      final f = DriveFolder.fromJson(const {
        'uuid': 'u1',
        'name': '财务数字人',
        'kind': 'de_agent',
        'is_system': true,
        'agent_id': 'ag_001',
        'parent_uuid': 'parent-uuid',
        'path': '/数字员工/财务数字人',
        'sort': 1,
      });
      expect(f.uuid, 'u1');
      expect(f.isAgentRoot, true);
      expect(f.isSystem, true);
      expect(f.parentId, 'parent-uuid');
      expect(f.agentId, 'ag_001');
    });

    test('regular folder + missing fields default', () {
      final f = DriveFolder.fromJson(const {});
      expect(f.uuid, '');
      expect(f.kind, 'regular');
      expect(f.isSystem, false);
      expect(f.parentId, '');
    });
  });

  group('DriveFile (snake_case)', () {
    test('parses size + display + folder_uuid', () {
      final f1 = DriveFile.fromJson(const {
        'uuid': 'u',
        'name': 'a.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 1024,
        'source': 'user_upload',
        'space_uuid': 'sp',
        'folder_uuid': 'p',
        'owner_account_uuid': 'acc-u',
        'owner_display_name': '李强',
        'owner_avatar_url': 'avatar-key',
        'created_at': '2026-04-01T10:00:00Z',
        'updated_at': '2026-04-01T10:00:00Z',
      });
      expect(f1.sizeDisplay, '1.0KB');
      expect(f1.spaceUuid, 'sp');
      expect(f1.driveFolderUuid, 'p');
      expect(f1.ownerAccountUuid, 'acc-u');
      expect(f1.ownerDisplayName, '李强');
      expect(f1.ownerAvatarUrl, 'avatar-key');
      expect(f1.mimeType, 'application/pdf');
      expect(f1.typeDisplay, 'PDF');

      final f2 = DriveFile.fromJson(
          const {'uuid': 'u', 'name': 'a', 'size_bytes': 2400000});
      expect(f2.sizeDisplay.endsWith('MB'), true);
    });

    test('uses readable file type instead of raw application MIME', () {
      DriveFile file(String name, String mimeType) => DriveFile.fromJson({
            'uuid': name,
            'name': name,
            'mime_type': mimeType,
          });

      expect(
        file(
          '聚合内容导入模板.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ).typeDisplay,
        'XLSX',
      );
      expect(
          file('无扩展名', 'application/pdf; charset=binary').typeDisplay, 'PDF');
      expect(file('未知文件', 'application/octet-stream').typeDisplay, '文件');
    });

    test('created_at fallback when invalid', () {
      final f = DriveFile.fromJson(
          const {'uuid': 'u', 'name': 'x', 'created_at': 'not-a-date'});
      expect(f.createdAt, isA<DateTime>());
    });
  });

  group('DriveFavoriteItem', () {
    test('parses drive and knowledge favorite projection', () {
      final drive = DriveFavoriteItem.fromJson(const {
        'favorite_uuid': 'fav-1',
        'target_kind': 'drive_file',
        'target_uuid': 'file-1',
        'space_uuid': 'space-1',
        'folder_uuid': 'folder-1',
        'name': '报告.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 2048,
        'status': 'ready',
        'created_at': '2026-07-20T10:00:00Z',
        'updated_at': '2026-07-21T10:00:00Z',
        'favorited_at': '2026-07-22T10:00:00Z',
      });
      expect(drive.isDriveFile, true);
      expect(drive.sourceLabel, '云盘');
      expect(drive.sizeDisplay, '2.0KB');

      final kb = DriveFavoriteItem.fromJson(const {
        'favorite_uuid': 'fav-2',
        'target_kind': 'kb_document',
        'target_uuid': 'doc-1',
        'kb_uuid': 'kb-1',
        'name': '制度.docx',
        'favorited_at': '2026-07-22T10:00:00Z',
      });
      expect(kb.isKbDocument, true);
      expect(kb.kbUuid, 'kb-1');
      expect(kb.sourceLabel, '知识库');
    });
  });

  group('FolderChildren', () {
    test('parses mixed payload', () {
      final c = FolderChildren.fromJson(const {
        'folders': [
          {'uuid': 'f1', 'name': '子目录', 'kind': 'regular'}
        ],
        'files': [
          {'uuid': 'fa', 'name': 'a.pdf', 'size_bytes': 100}
        ],
        'total': 1,
      });
      expect(c.folders, hasLength(1));
      expect(c.files, hasLength(1));
      expect(c.total, 1);
    });
  });

  group('PreviewUrl', () {
    test('parses url + expires_at', () {
      final p = PreviewUrl.fromJson(
          const {'url': 'https://x', 'expires_at': '2026-04-01T10:00:00Z'});
      expect(p.url, 'https://x');
      expect(p.expiresAt, isA<DateTime>());
    });
  });

  group('DriveBootstrap (spaces envelope)', () {
    test('parses personal + tenant + departments + shared; orgSpaces merges',
        () {
      final b = DriveBootstrap.fromJson(const {
        'spaces': {
          'personal': {'uuid': 'p', 'kind': 'personal', 'name': '我的'},
          'tenant': {'uuid': 't', 'kind': 'tenant', 'name': '公司'},
          'departments': [
            {'uuid': 'd1', 'kind': 'department', 'name': '财务部'}
          ],
          'shared': [
            {'uuid': 's1', 'kind': 'shared', 'name': '协作空间'}
          ],
        }
      });
      expect(b.personal?.uuid, 'p');
      expect(b.tenant?.uuid, 't');
      expect(b.departments, hasLength(1));
      expect(b.shared, hasLength(1));
      // orgSpaces = tenant + departments + shared
      expect(b.orgSpaces.map((s) => s.uuid).toList(), ['t', 'd1', 's1']);
      // allSpaces = personal + org
      expect(b.allSpaces.first.uuid, 'p');
      expect(b.allSpaces, hasLength(4));
    });

    test('tolerates null tenant + missing lists', () {
      final b = DriveBootstrap.fromJson(const {
        'spaces': {
          'personal': {'uuid': 'p', 'kind': 'personal'},
          'tenant': null,
        }
      });
      expect(b.personal, isNotNull);
      expect(b.tenant, isNull);
      expect(b.orgSpaces, isEmpty);
    });
  });

  group('PresignTicket', () {
    test('single mode', () {
      final t = PresignTicket.fromJson(const {
        'mode': 'single',
        'ticket': {
          'file_uuid': 'f1',
          'presign_url': 'https://oss/put',
          'expires_in': 600,
        }
      });
      expect(t.isMultipart, false);
      expect(t.fileUuid, 'f1');
      expect(t.presignUrl, 'https://oss/put');
    });

    test('multipart mode', () {
      final t = PresignTicket.fromJson(const {
        'mode': 'multipart',
        'ticket': {
          'file_uuid': 'f2',
          'part_urls': ['https://oss/p1', 'https://oss/p2'],
          'part_size': 10485760,
          'expires_in': 1800,
        }
      });
      expect(t.isMultipart, true);
      expect(t.partUrls, hasLength(2));
      expect(t.partSize, 10485760);
    });
  });

  group('RecycleItem (F06 基础设置)', () {
    test('parses snake_case fields + timestamps', () {
      final r = RecycleItem.fromJson(const {
        'uuid': 'r1',
        'target_kind': 'folder',
        'space_uuid': 's1',
        'name': 'recycle-test',
        'location_path': '云盘 / 项目资料',
        'mime_type': 'image/png',
        'deleted_by_account_uuid': 'acc-2',
        'deleted_by_display_name': '张伟',
        'deleted_by_avatar_url': 'avatars/a2.png',
        'deleted_at_logical': '2026-05-30T21:25:52Z',
        'expires_at': '2026-06-29T21:25:52Z',
        'bytes_to_reclaim': 0,
      });
      expect(r.uuid, 'r1');
      expect(r.isFolder, true);
      expect(r.isFile, false);
      expect(r.name, 'recycle-test');
      expect(r.spaceUuid, 's1');
      expect(r.locationPath, '云盘 / 项目资料');
      expect(r.mimeType, 'image/png');
      expect(r.deletedByAccountUuid, 'acc-2');
      expect(r.deletedByDisplayName, '张伟');
      expect(r.deletedByAvatarUrl, 'avatars/a2.png');
      expect(r.bytesToReclaim, 0);
      expect(r.sizeDisplay, '');
    });

    test('file kind + size formatting', () {
      final r = RecycleItem.fromJson(const {
        'uuid': 'r2',
        'target_kind': 'file',
        'name': 'big.bin',
        'bytes_to_reclaim': 12582912,
      });
      expect(r.isFile, true);
      expect(r.sizeDisplay.endsWith('MB'), true);
    });
  });

  group('SpaceMember (F06 基础设置)', () {
    test('parses account_uuid + role', () {
      final m = SpaceMember.fromJson(
          const {'account_uuid': 'acc-1', 'role': 'editor'});
      expect(m.accountUuid, 'acc-1');
      expect(m.role, 'editor');
    });
  });
}
