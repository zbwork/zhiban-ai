/// F08 §3.1.1 / R9 · Bus client prompt template 只读 service.
///
/// 调用 services/agent-bus 已落的两条客户端只读 API:
///   - GET /cron/prompt-templates              → 列表
///   - GET /cron/prompt-templates/{uuid}/variables → 详情 + 变量 schema
///
/// 注意 (与 admin 路径分离):
///   - 客户端**只**可见 status='active' 的模板; admin 路径才能看 draft / archived.
///   - 跨可见统一返 `cron.prompt_template_not_found`, 不区分 (不存在 / 跨租户 / archived),
///     本 service 不替后端兜底分类.
///
/// 本期 (I) 仅作为 API seam, **不**接入 legacy OpenClaw 任务页主存盘链路.
library;

import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

import '../models/prompt_template.dart';

class CronPromptTemplateService {
  CronPromptTemplateService();

  // baseUrl (AppConfig.apiUrl) 已经包含 /api/agent-bus/v1, 路径相对即可.
  static const String _list = '/cron/prompt-templates';
  static const String _detailPrefix = '/cron/prompt-templates/';
  static const String _detailSuffix = '/variables';

  /// 列出当前账号可见的 active prompt 模板 (platform + 本租户).
  /// list DTO 不含 template_body; 需要 body 调 [getVariables].
  Future<List<PromptTemplateSummary>> listVisibleTemplates() async {
    final data = responseAsMap(await request.get(_list));
    final items = data['items'];
    if (items is! List) {
      return const <PromptTemplateSummary>[];
    }
    final out = <PromptTemplateSummary>[];
    for (final item in items) {
      if (item is Map) {
        out.add(PromptTemplateSummary.fromJson(item.cast<String, dynamic>()));
      }
    }
    return out;
  }

  /// 拉指定 active 模板的 body + 变量 schema; 跨可见 / 非 active 会从后端拿到
  /// `cron.prompt_template_not_found`, 调用方自行处理 (UI 通常提示 "模板已下线或无权限").
  Future<PromptTemplateDetail> getVariables(String uuid) async {
    final encoded = Uri.encodeComponent(uuid);
    final data = responseAsMap(
      await request.get('$_detailPrefix$encoded$_detailSuffix'),
    );
    return PromptTemplateDetail.fromJson(data);
  }
}
