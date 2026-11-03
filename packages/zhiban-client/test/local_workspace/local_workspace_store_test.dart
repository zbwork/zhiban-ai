import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

void main() {
  sqfliteFfiInit();
  test(
      'reopen preserves employees, skills and messages; update does not cascade',
      () async {
    final dir = await Directory.systemTemp.createTemp('community-store-');
    final path = '${dir.path}/workspace.db';
    const skill = {
      'id': 'summary',
      'name': '总结',
      'description': '文本总结',
      'prompt': '总结文本'
    };
    var store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: path, skills: [skill]);
    final employee = <String, Object?>{
      'id': 'one',
      'name': '助手',
      'prompt': '帮助用户',
      'provider_id': 'p',
      'model_id': 'm',
      'skills': '["summary"]',
      'created': 1,
      'metadata':
          '{"description":"主要职责","welcome_msg":"你好","tags":["办公"],"internal_description":"备注","system_prompt":""}',
    };
    await store.saveEmployee(employee);
    await store.saveEmployee({...employee, 'id': 'two'});
    await store.addMessage('one', 'user', '你好',
        attachments:
            '[{"name":"test.txt","path":"/local/test.txt","size":4,"text":"test"}]');
    final replyId =
        await store.addMessage('one', 'assistant', '', status: 'pending');
    const timeline =
        '[{"key":"tool:1","title":"写入文件","start":1,"end":2,"status":"done","name":"write_file"}]';
    await store.finishMessage(replyId, '完成', 'complete', timeline: timeline);
    await store.addMessage('one', 'assistant', '', status: 'pending');
    await store.addMessage('two', 'user', '保留');
    await store.saveEmployee({...employee, 'name': '新名字'});
    expect((await store.messages('one')).length, 3);
    await store.db.close();
    store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: path, skills: [skill]);
    expect((await store.employees()).length, 2);
    expect((await store.employees()).first['metadata'], employee['metadata']);
    expect((await store.skills()).length, 1);
    expect((await store.messages('one')).last['status'], 'interrupted');
    expect((await store.messages('one'))[1]['timeline'], timeline);
    expect((await store.messages('one')).first['attachments'],
        contains('test.txt'));
    await store.deleteEmployee('one');
    expect(await store.messages('one'), isEmpty);
    expect((await store.messages('two')).single['content'], '保留');
    await expectLater(store.addMessage('absent', 'user', 'orphan'),
        throwsA(isA<DatabaseException>()));
    await store.db.close();
    await dir.delete(recursive: true);
  });
}
