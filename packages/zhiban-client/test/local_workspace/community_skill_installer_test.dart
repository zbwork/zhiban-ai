import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_installer.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

Uint8List bundle({String path = 'SKILL.md'}) {
  final inner = Archive()
    ..addFile(ArchiveFile(path, 9, utf8.encode('# MySkill')))
    ..addFile(ArchiveFile('references/data.txt', 4, utf8.encode('data')));
  final pkg = Uint8List.fromList(ZipEncoder().encode(inner));
  final manifest = utf8.encode(jsonEncode({
    'format_version': 1,
    'skills': [
      {
        'code': 'demo',
        'version': {
          'version': '1.0.0',
          'package_path': 'skills/demo.zip',
          'package_sha256': sha256.convert(pkg).toString()
        }
      }
    ]
  }));
  return Uint8List.fromList(ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
    ..addFile(ArchiveFile('skills/demo.zip', pkg.length, pkg))));
}

class FakePackages extends CommunitySkillCatalog {
  FakePackages(this.bytes);
  final Uint8List bytes;
  int calls = 0;
  @override
  Future<({Uint8List bytes, String sha256})> downloadBundle(String uuid) async {
    calls++;
    return (bytes: bytes, sha256: sha256.convert(bytes).toString());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('bundle verifies hashes and blocks traversal and broken checksum', () {
    final bytes = bundle();
    final parsed = parseCommunitySkillBundle({
      'bytes': bytes,
      'sha256': sha256.convert(bytes).toString(),
      'code': 'demo',
      'version': '1.0.0'
    });
    expect(parsed['prompt'], '# MySkill');
    expect((parsed['files'] as Map).keys, contains('references/data.txt'));
    expect(
        () => parseCommunitySkillBundle({
              'bytes': bytes,
              'sha256': 'wrong',
              'code': 'demo',
              'version': '1.0.0'
            }),
        throwsStateError);
    final bad = bundle(path: '../SKILL.md');
    expect(
        () => parseCommunitySkillBundle({
              'bytes': bad,
              'sha256': sha256.convert(bad).toString(),
              'code': 'demo',
              'version': '1.0.0'
            }),
        throwsStateError);
  });
  test('install merges concurrent download, survives reopen, detects tampering',
      () async {
    final dir = await Directory.systemTemp.createTemp('community-skill-test-');
    addTearDown(() => dir.delete(recursive: true));
    var store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi,
        path: '${dir.path}/db',
        skills: [
          {
            'id': 'demo',
            'name': 'Demo',
            'description': '',
            'prompt': '',
            'executable': 0
          }
        ]);
    final client = FakePackages(bundle());
    final installer = CommunitySkillInstaller(store,
        client: client, root: '${dir.path}/packages');
    final item = {
      'skill_uuid': 'uuid',
      'code': 'demo',
      'latest_version': '1.0.0'
    };
    await Future.wait(
        [installer.install('demo', item), installer.install('demo', item)]);
    expect(client.calls, 1);
    final metadata = (await store.installedSkill('demo'))!;
    expect((await CommunitySkillInstaller.verifiedFiles(metadata)).length, 2);
    await store.db.close();
    store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi,
        path: '${dir.path}/db',
        skills: [
          {
            'id': 'demo',
            'name': 'Demo',
            'description': '',
            'prompt': '',
            'executable': 0
          }
        ]);
    expect((await store.skills()).single['executable'], 1);
    expect((await store.skills()).single['prompt'], '# MySkill');
    await File('${metadata['root']}/SKILL.md').writeAsString('tampered');
    await expectLater(
        CommunitySkillInstaller.verifiedFiles(metadata), throwsStateError);
    final reopened = CommunitySkillInstaller(store,
        client: client, root: '${dir.path}/packages');
    await reopened.install('demo', item);
    expect(client.calls, 2);
    final restored = (await store.installedSkill('demo'))!;
    expect(
        utf8.decode((await CommunitySkillInstaller.verifiedFiles(
            restored))['SKILL.md']!),
        '# MySkill');
    final offline = CommunitySkillInstaller(store,
        client: client, root: '${dir.path}/packages');
    await offline.install('demo', item);
    expect(client.calls, 2);
    await store.db.close();
  });
  test('verified package resources reach the runtime snapshot', () async {
    final bytes = bundle();
    final parsed = parseCommunitySkillBundle({
      'bytes': bytes,
      'sha256': sha256.convert(bytes).toString(),
      'code': 'demo',
      'version': '1.0.0'
    });
    expect(parsed['prompt'], '# MySkill');
    expect((parsed['files'] as Map).length, greaterThan(1));
    final dir =
        await Directory.systemTemp.createTemp('production-skill-install-');
    addTearDown(() => dir.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi,
        path: '${dir.path}/db',
        skills: [
          {
            'id': 'real',
            'name': '路线图',
            'description': '',
            'prompt': '',
            'executable': 0
          }
        ]);
    addTearDown(store.db.close);
    final installer = CommunitySkillInstaller(store,
        client: FakePackages(bytes), root: '${dir.path}/packages');
    await installer.install('real',
        {'skill_uuid': 'real', 'code': 'demo', 'latest_version': '1.0.0'});
    expect((await store.skills()).single['prompt'], parsed['prompt']);
    final runtimeDir =
        (await installer.prepareForRun('employee', 'run', ['real']))!;
    expect(await File('$runtimeDir/demo/SKILL.md').readAsString(),
        parsed['prompt']);
    for (final entry in (parsed['files'] as Map<String, Uint8List>).entries) {
      expect(await File('$runtimeDir/demo/${entry.key}').readAsBytes(),
          entry.value);
    }
  });
}
