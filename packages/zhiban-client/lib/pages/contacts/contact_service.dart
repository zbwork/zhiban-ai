import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/contacts/contact_models.dart';

final _readOptions = Options(
  receiveTimeout: const Duration(seconds: 15),
  extra: const {'silent': true, 'pageRead': true},
);

class ContactsService {
  const ContactsService();

  Future<List<ContactDepartment>> tree() async {
    final raw = responseAsMap(
        await request.get('/contacts/tree', options: _readOptions));
    final items = raw['items'] is List ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => ContactDepartment.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<ContactPerson>> members({
    String departmentId = '',
    String keyword = '',
    String kind = 'all',
  }) async {
    final raw = responseAsMap(
      await request.get('/contacts', options: _readOptions, queryParameters: {
        'kind': kind,
        'limit': 100,
        if (departmentId.isNotEmpty) 'department_id': departmentId,
        if (keyword.trim().isNotEmpty) 'q': keyword.trim(),
      }),
    );
    final items = raw['items'] is List ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => ContactPerson.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// 拉全量成员(按 `nextCursor` 翻页直到没有下一页), 不受单页 100 条上限截断。
  /// 用于本地通讯录快照([ContactsDirectoryStore])——组织架构成员必须按部门 id
  /// 分组匹配, 全量数据缺一条都可能导致某个部门漏人。
  Future<List<ContactPerson>> membersAll({
    String kind = 'all',
    String keyword = '',
  }) async {
    final result = <ContactPerson>[];
    String cursor = '';
    while (true) {
      final raw = responseAsMap(
        await request.get('/contacts', options: _readOptions, queryParameters: {
          'kind': kind,
          'limit': 100,
          if (cursor.isNotEmpty) 'cursor': cursor,
          if (keyword.trim().isNotEmpty) 'q': keyword.trim(),
        }),
      );
      final items = raw['items'] is List ? raw['items'] as List : const [];
      result.addAll(
        items
            .whereType<Map>()
            .map((e) => ContactPerson.fromJson(e.cast<String, dynamic>())),
      );
      final next = (raw['nextCursor'] ?? '').toString();
      if (next.isEmpty || items.isEmpty) break;
      cursor = next;
    }
    return result;
  }

  Future<ContactPerson> member(String accountUuid) async {
    final raw = responseAsMap(
      await request.get('/contacts/members/$accountUuid',
          options: _readOptions),
    );
    return ContactPerson.fromJson(raw);
  }

  Future<ContactAgent> agent(String agentUuid, {bool silent = false}) async {
    final raw = responseAsMap(
      await request.get(
        '/contacts/agents/$agentUuid',
        options: silent
            ? Options(extra: const <String, dynamic>{'silent': true})
            : null,
      ),
    );
    return ContactAgent.fromJson(raw);
  }

  Future<ContactAgentsSnapshot> agents({
    String keyword = ''
  }) async {
    // 两个请求互相独立，并行发出（此前串行等待，首屏耗时是两段之和）。
    final responses = await Future.wait([
      request.get('/agents', options: _readOptions, queryParameters: {
        'source': 'personal',
        'mine': 1,
        'limit': 200,
        if (keyword.trim().isNotEmpty) 'q': keyword.trim(),
      }),
      request.get('/contacts/agents', options: _readOptions, queryParameters: {
        'source': 'all',
        'limit': 200,
        if (keyword.trim().isNotEmpty) 'q': keyword.trim(),
      }),
    ]);
    final personalResp = responseAsMap(responses[0]);
    final personalItems = personalResp['items'] is List
        ? personalResp['items'] as List
        : const [];
    final raw = responseAsMap(responses[1]);
    List<ContactAgent> parseGroup(String key) {
      final items = raw[key] is List ? raw[key] as List : const [];
      return items
          .whereType<Map>()
          .map((e) => ContactAgent.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
    }

    final personalAgents = personalItems
        .whereType<Map>()
        .map((e) => AgentItem.fromJson(e.cast<String, dynamic>()))
        .map(ContactAgent.fromAgentItem)
        .toList(growable: false);

    return ContactAgentsSnapshot(
      personal: personalAgents,
      enterprise: parseGroup('enterprise'),
      platform: parseGroup('platform'),
    );
  }
}
