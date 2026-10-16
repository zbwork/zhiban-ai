import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/cron/models/prompt_template.dart';

void main() {
  group('PromptTemplateSummary.fromJson', () {
    test('parses minimal active platform template', () {
      final dto = PromptTemplateSummary.fromJson({
        'uuid': 'plat-1',
        'scope_kind': 'platform',
        'code': 'p-active',
        'name': 'Platform Active',
        'is_system': true,
        'status': 'active',
        'is_readonly': true,
      });
      expect(dto.uuid, 'plat-1');
      expect(dto.scopeKind, PromptTemplateScopeKind.platform);
      expect(dto.code, 'p-active');
      expect(dto.name, 'Platform Active');
      expect(dto.isSystem, isTrue);
      expect(dto.status, PromptTemplateStatus.active);
      expect(dto.isReadonly, isTrue);
    });

    test('list DTO 应当不含 template_body 字段; 缺失也不报错', () {
      final dto = PromptTemplateSummary.fromJson({
        'uuid': 'tA-1',
        'scope_kind': 'tenant',
        'code': 'own',
        'name': 'Own',
        'status': 'active',
      });
      expect(dto.uuid, 'tA-1');
      expect(dto.scopeKind, PromptTemplateScopeKind.tenant);
      expect(dto.isSystem, isFalse);
      expect(dto.isReadonly, isFalse);
    });

    test('unknown scope / status fall back to .unknown', () {
      final dto = PromptTemplateSummary.fromJson({
        'uuid': 'x',
        'scope_kind': 'workspace',
        'code': 'x',
        'name': 'x',
        'status': 'pending',
      });
      expect(dto.scopeKind, PromptTemplateScopeKind.unknown);
      expect(dto.status, PromptTemplateStatus.unknown);
    });

    test('empty payload yields safe defaults', () {
      final dto = PromptTemplateSummary.fromJson(const <String, dynamic>{});
      expect(dto.uuid, '');
      expect(dto.code, '');
      expect(dto.name, '');
      expect(dto.scopeKind, PromptTemplateScopeKind.unknown);
      expect(dto.status, PromptTemplateStatus.unknown);
      expect(dto.isSystem, isFalse);
      expect(dto.isReadonly, isFalse);
    });
  });

  group('PromptTemplateVariable.fromJson', () {
    test('parses string variable with default', () {
      final v = PromptTemplateVariable.fromJson({
        'var_name': 'metric',
        'var_type': 'string',
        'required': true,
        'default_value': 'sales',
        'order_index': 0,
        'display_name': '指标',
      });
      expect(v.varName, 'metric');
      expect(v.varType, PromptTemplateVarType.string);
      expect(v.required, isTrue);
      expect(v.defaultValue, 'sales');
      expect(v.displayName, '指标');
      expect(v.orderIndex, 0);
      expect(v.options, isNull);
    });

    test('parses enum with options list', () {
      final v = PromptTemplateVariable.fromJson({
        'var_name': 'range',
        'var_type': 'enum',
        'required': false,
        'options': ['today', 'this_week', 'this_month'],
        'order_index': 1,
      });
      expect(v.varType, PromptTemplateVarType.enumType);
      expect(v.options, hasLength(3));
      expect(v.options!.first, 'today');
    });

    test('parses int / datetime / list types', () {
      final n = PromptTemplateVariable.fromJson({
        'var_name': 'n',
        'var_type': 'int',
        'required': false,
        'default_value': 5,
      });
      expect(n.varType, PromptTemplateVarType.intType);
      expect(n.defaultValue, 5);

      final when = PromptTemplateVariable.fromJson({
        'var_name': 'when',
        'var_type': 'datetime',
        'required': false,
      });
      expect(when.varType, PromptTemplateVarType.dateTime);

      final metrics = PromptTemplateVariable.fromJson({
        'var_name': 'metrics',
        'var_type': 'list',
        'required': false,
        'default_value': ['a', 'b'],
      });
      expect(metrics.varType, PromptTemplateVarType.list);
      expect((metrics.defaultValue as List).length, 2);
    });

    test('order_index 缺失时降级 0', () {
      final v = PromptTemplateVariable.fromJson({
        'var_name': 'x',
        'var_type': 'string',
      });
      expect(v.orderIndex, 0);
    });

    test('unknown var_type falls back to .unknown 不抛异常', () {
      final v = PromptTemplateVariable.fromJson({
        'var_name': 'foo',
        'var_type': 'bool',
      });
      expect(v.varType, PromptTemplateVarType.unknown);
    });
  });

  group('PromptTemplateDetail.fromJson', () {
    test('parses full detail incl. body + variables', () {
      final dto = PromptTemplateDetail.fromJson({
        'uuid': 'tA-1',
        'scope_kind': 'tenant',
        'code': 'daily',
        'name': '日报',
        'template_body': '请汇总{{range}}的{{metric}}',
        'is_system': false,
        'status': 'active',
        'is_readonly': false,
        'variables': [
          {
            'var_name': 'metric',
            'var_type': 'string',
            'required': true,
            'order_index': 1,
          },
          {
            'var_name': 'range',
            'var_type': 'enum',
            'required': false,
            'options': ['today', 'this_week'],
            'order_index': 0,
          },
        ],
      });
      expect(dto.uuid, 'tA-1');
      expect(dto.templateBody.contains('{{range}}'), isTrue);
      expect(dto.variables.length, 2);
      // 排序后 order_index 0 在前
      expect(dto.variables.first.varName, 'range');
      expect(dto.variables.last.varName, 'metric');
    });

    test('variables 缺失时为 empty list', () {
      final dto = PromptTemplateDetail.fromJson({
        'uuid': 'x',
        'scope_kind': 'tenant',
        'code': 'x',
        'name': 'x',
        'template_body': 'body',
        'status': 'active',
      });
      expect(dto.variables, isEmpty);
      expect(dto.templateBody, 'body');
    });

    test('variables 非 list 时安全降级', () {
      final dto = PromptTemplateDetail.fromJson({
        'uuid': 'x',
        'scope_kind': 'tenant',
        'code': 'x',
        'name': 'x',
        'template_body': 'body',
        'status': 'active',
        'variables': 'not a list',
      });
      expect(dto.variables, isEmpty);
    });
  });

  group('varTypeToWire', () {
    test('roundtrip 与后端枚举名一致', () {
      expect(varTypeToWire(PromptTemplateVarType.string), 'string');
      expect(varTypeToWire(PromptTemplateVarType.enumType), 'enum');
      expect(varTypeToWire(PromptTemplateVarType.intType), 'int');
      expect(varTypeToWire(PromptTemplateVarType.dateTime), 'datetime');
      expect(varTypeToWire(PromptTemplateVarType.list), 'list');
      expect(varTypeToWire(PromptTemplateVarType.unknown), 'string');
    });
  });
}
