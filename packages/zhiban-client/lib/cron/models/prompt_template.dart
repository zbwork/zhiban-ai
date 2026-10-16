/// F08 §3.1.1 / R9 · Bus client 端 cron prompt template 只读 model.
///
/// API seam: 这是 zhiban-app 与 services/agent-bus 的客户端 prompt 模板桥;
/// 后端契约见:
///   - GET /api/agent-bus/v1/cron/prompt-templates              → list (active only)
///   - GET /api/agent-bus/v1/cron/prompt-templates/{uuid}/variables → detail + variables
///
/// 与 admin 路径严格分离:
///   - 客户端只暴露 status='active' 的模板;
///   - draft / archived / 跨租户 / 不存在 统一返 `cron.prompt_template_not_found`.
///
/// 本期 (I) 只新建 model + service seam, **不**接 legacy OpenClaw 任务编辑器主存盘链路.
/// 任务页迁移到 Bus F08 后, 编辑器读这套 model + 服务即可挂模板选择器 + 变量表单.
///
/// 设计原则:
///   - `fromJson` 容错 (不 throw 单字段类型错; 缺失字段降级到合理默认值);
///   - 不抛业务异常; 反序列化层面只关心结构.
library;

enum PromptTemplateScopeKind { platform, tenant, unknown }

PromptTemplateScopeKind _parseScope(String? raw) {
  switch (raw) {
    case 'platform':
      return PromptTemplateScopeKind.platform;
    case 'tenant':
      return PromptTemplateScopeKind.tenant;
    default:
      return PromptTemplateScopeKind.unknown;
  }
}

enum PromptTemplateStatus { draft, active, archived, unknown }

PromptTemplateStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'draft':
      return PromptTemplateStatus.draft;
    case 'active':
      return PromptTemplateStatus.active;
    case 'archived':
      return PromptTemplateStatus.archived;
    default:
      return PromptTemplateStatus.unknown;
  }
}

enum PromptTemplateVarType { string, enumType, intType, dateTime, list, unknown }

PromptTemplateVarType _parseVarType(String? raw) {
  switch (raw) {
    case 'string':
      return PromptTemplateVarType.string;
    case 'enum':
      return PromptTemplateVarType.enumType;
    case 'int':
      return PromptTemplateVarType.intType;
    case 'datetime':
      return PromptTemplateVarType.dateTime;
    case 'list':
      return PromptTemplateVarType.list;
    default:
      return PromptTemplateVarType.unknown;
  }
}

String varTypeToWire(PromptTemplateVarType ty) {
  switch (ty) {
    case PromptTemplateVarType.string:
      return 'string';
    case PromptTemplateVarType.enumType:
      return 'enum';
    case PromptTemplateVarType.intType:
      return 'int';
    case PromptTemplateVarType.dateTime:
      return 'datetime';
    case PromptTemplateVarType.list:
      return 'list';
    case PromptTemplateVarType.unknown:
      return 'string';
  }
}

/// list DTO. **不**包含 template_body —— 后端列表接口故意不返 body 防泄露.
class PromptTemplateSummary {
  const PromptTemplateSummary({
    required this.uuid,
    required this.scopeKind,
    required this.code,
    required this.name,
    required this.isSystem,
    required this.status,
    required this.isReadonly,
  });

  final String uuid;
  final PromptTemplateScopeKind scopeKind;
  final String code;
  final String name;
  final bool isSystem;
  final PromptTemplateStatus status;
  final bool isReadonly;

  factory PromptTemplateSummary.fromJson(Map<String, dynamic> json) {
    return PromptTemplateSummary(
      uuid: (json['uuid'] as String?) ?? '',
      scopeKind: _parseScope(json['scope_kind'] as String?),
      code: (json['code'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      isSystem: json['is_system'] == true,
      status: _parseStatus(json['status'] as String?),
      isReadonly: json['is_readonly'] == true,
    );
  }
}

/// 变量定义 (UI 表单生成 + create/patch cron job 用).
class PromptTemplateVariable {
  const PromptTemplateVariable({
    required this.varName,
    required this.varType,
    required this.required,
    this.defaultValue,
    this.options,
    this.displayName,
    this.orderIndex = 0,
  });

  final String varName;
  final PromptTemplateVarType varType;
  final bool required;
  final dynamic defaultValue;
  final List<dynamic>? options;
  final String? displayName;
  final int orderIndex;

  factory PromptTemplateVariable.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final orderRaw = json['order_index'];
    return PromptTemplateVariable(
      varName: (json['var_name'] as String?) ?? '',
      varType: _parseVarType(json['var_type'] as String?),
      required: json['required'] == true,
      defaultValue: json['default_value'],
      options: rawOptions is List ? List<dynamic>.from(rawOptions) : null,
      displayName: json['display_name'] as String?,
      orderIndex: orderRaw is num ? orderRaw.toInt() : 0,
    );
  }
}

/// detail DTO. 含 template_body + 变量 schema.
///
/// 注意: client API 端点 (GET .../{uuid}/variables) 对 draft/archived 返回
/// `cron.prompt_template_not_found`, 这是后端故意的不暴露存在性策略.
class PromptTemplateDetail {
  const PromptTemplateDetail({
    required this.uuid,
    required this.scopeKind,
    required this.code,
    required this.name,
    required this.templateBody,
    required this.isSystem,
    required this.status,
    required this.isReadonly,
    required this.variables,
  });

  final String uuid;
  final PromptTemplateScopeKind scopeKind;
  final String code;
  final String name;
  final String templateBody;
  final bool isSystem;
  final PromptTemplateStatus status;
  final bool isReadonly;
  final List<PromptTemplateVariable> variables;

  factory PromptTemplateDetail.fromJson(Map<String, dynamic> json) {
    final rawVars = json['variables'];
    final vars = <PromptTemplateVariable>[];
    if (rawVars is List) {
      for (final item in rawVars) {
        if (item is Map) {
          vars.add(
            PromptTemplateVariable.fromJson(item.cast<String, dynamic>()),
          );
        }
      }
    }
    // 保持 order_index 升序; 后端 repo 已按此序返回, 但前端不依赖排序顺序.
    vars.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return PromptTemplateDetail(
      uuid: (json['uuid'] as String?) ?? '',
      scopeKind: _parseScope(json['scope_kind'] as String?),
      code: (json['code'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      templateBody: (json['template_body'] as String?) ?? '',
      isSystem: json['is_system'] == true,
      status: _parseStatus(json['status'] as String?),
      isReadonly: json['is_readonly'] == true,
      variables: vars,
    );
  }
}
