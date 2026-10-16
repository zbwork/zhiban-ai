/// emp_block_readable_text.dart — Plan 16 Phase 3 minimal closed-loop。
///
/// 把后端 finalize / SSE message.completed 透出的 EMP blocks (text / markdown / 富 typed)
/// 统一规一化成"客户端聊天气泡可见的纯文本", 让 zhiban-app 在 Phase 3 富组件 widget 上线前
/// 也**不再把 typed 富 block 抽空** —— 但**仍只是只读 fallback 文本**, 不是富 UI。
///
/// 设计纪律 (Plan 16 §I.F / §C.4):
///   - 这是**只读 fallback 文本**, 不是完整富 UI 替代。
///   - 不伪造提交按钮 / 不假装能执行 action / 不发 callback。
///   - 不引入第三方依赖 (fl_chart 等留 Phase 3 引入时单独提案)。
///   - 已 seed 富组件 (chart/form/action/approval/artifact/source/progress/app_card) 走每类自己的
///     "单行摘要"; 未 seed type (table/plan/code/tool_result/inline error) 也尽量给出可读兜底。
///   - 完全无法解析的 block 跳过 (不写空行, 不写 "[unknown]" 之类的污染)。
///
/// 健壮性纪律 (本轮 F1 收尾):
///   - **不允许** 对外部 JSON 字段直接 `as List`/`as Map`; runtime 可能返不规范类型 (string/map/null/number),
///     必须用 [_asList] / [_asMap] / [_asString] safe helper, 类型不符直接退化到最小 fallback;
///   - 单个 block render 抛异常**不能**影响整条 message 的其余 block 输出: [_renderOneBlock] 用
///     try/catch 兜底, 失败时返回最小 "[<type>]" 占位文本, 让相邻 markdown/plain 继续可见。
library;

/// empBlocksToReadableText — 主入口。
///
/// blocks 一般是 `List<dynamic>` (来自 JSON decode); 每个元素期望是 `Map<String, dynamic>`。
/// 不合法形态直接返回 ""。
///
/// 容错: 单个 block 即使字段错位 / 类型不对也不会中断后续 block 的渲染 (单 try/catch + safe helper)。
String empBlocksToReadableText(dynamic blocks) {
  if (blocks is! List) return '';
  final parts = <String>[];
  for (final b in blocks) {
    if (b is! Map) continue;
    final text = _renderOneBlock(b);
    if (text.isNotEmpty) parts.add(text);
  }
  return parts.join('\n');
}

/// plainBlocksText — 只取纯文本类 block(无 type / markdown / plain / text)的原文,
/// typed 富 block(chart/action/table/...)整块跳过、不产出 "[类型] 标题" 兜底摘要。
///
/// 跟 [empBlocksToReadableText] 的区别: 后者对 typed block 也会给兜底摘要文本
/// (用于列表 preview / WuKong 通知正文这类"没有富组件渲染能力,好歹给点字"的场景);
/// 这个函数是给"正文文字 + EMP 富组件分开渲染"的场景用的——EMP 卡片本身已经由
/// 专门的 widget 渲染,正文这份纯文本不该再重复一次 typed block 的兜底摘要
/// (2026-08-08 复现:数字员工回复"markdown 介绍文字 + action 卡片"混排时,
/// 正文被整段替换成 EMP 摘要文本、介绍文字直接消失)。
String plainBlocksText(dynamic blocks) {
  if (blocks is! List) return '';
  final parts = <String>[];
  for (final b in blocks) {
    if (b is! Map) continue;
    if (_asString(b['x_source']).toLowerCase() == 'a2a_timeline') continue;
    final type = _asString(b['type']).toLowerCase();
    if (type.isNotEmpty &&
        type != 'markdown' &&
        type != 'plain' &&
        type != 'text') {
      continue;
    }
    final rawText = _asString(b['text']);
    final text = rawText.isNotEmpty ? rawText : _asString(b['markdown']);
    if (text.isNotEmpty) parts.add(text);
  }
  return parts.join('\n');
}

String _renderOneBlock(Map block) {
  // A2A / 工具执行过程块只在「已调用工具」时间线展示，绝不进入正文纯文本、会话列表 preview
  // 或 WuKong display text。x_source="a2a_timeline" 覆盖被打上该来源的任意块（含 markdown/plain/
  // tool_call/tool_result），集中在此过滤，避免逐个 caller 漏过滤。
  // 注意：x_source="a2a_approval" 是结构化审批 EMP，**不**在此过滤——它要交给 EMP renderer 渲染
  // 成当前会话内的审批卡（见 emp_blocks_view）。
  if (_asString(block['x_source']).toLowerCase() == 'a2a_timeline') return '';
  final type = _asString(block['type']).toLowerCase();
  // text 类 (含没 type / type=markdown/plain/text): 用 text/markdown 字段拼出来。
  if (type.isEmpty || type == 'markdown' || type == 'plain' || type == 'text') {
    final rawText = _asString(block['text']);
    if (rawText.isNotEmpty) return rawText;
    return _asString(block['markdown']);
  }
  // typed 富 block / 未知 type: try/catch + safe helper 双层保护。哪怕单个字段类型错也不能让整条
  // message 的其它 block 跟着没掉。
  try {
    switch (type) {
      case 'chart':
        return _renderChart(block);
      case 'form':
        return _renderForm(block);
      case 'action':
      case 'action_bar': // canonical mapping 前的形态; Bus adapter 会改 → 'action', 兜底也认
        return _renderAction(block);
      case 'approval':
      case 'confirm':
      case 'approval_request':
        return _renderApproval(block);
      case 'artifact':
        return _renderArtifact(block);
      case 'source':
      case 'citation':
        return _renderSource(block);
      case 'progress':
        return _renderProgress(block);
      case 'app_card':
        return _renderAppCard(block);
      case 'plan':
        return _renderPlan(block);
      case 'tool_call':
        // tool_call 是过程起点，实时 UI 由 timeline 展示；正文 fallback 里不再
        // 输出 "[tool_call]" 这种协议占位，避免污染最终回答。
        return '';
      case 'tool_result':
        // tool_result 是执行过程，正文由 markdown/text 等最终回答块承载。
        // 如果把工具结果降级为正文，会污染聊天气泡和会话列表摘要。
        return '';
      case 'reasoning':
        // reasoning 是执行过程，已由消息气泡上方 timeline 展示；不进入正文、
        // 复制文本或会话预览，避免同一思考过程重复出现。
        return '';
      case 'suggestion':
      case 'suggestions':
        return _renderSuggestion(block);
      case 'mermaid':
      case 'flowchart':
        return _renderDiagramSource(block, type);
      case 'code':
        return _renderCode(block);
      case 'table':
        return _renderTable(block);
      case 'error':
        return _renderInlineError(block);
      case '':
        return '';
      default:
        // unknown 但有 type: 给最小化 "[type] <title>" 兜底, 避免完全抽空。
        final t = _asString(block['title']);
        return t.isNotEmpty ? '[$type] $t' : '[$type]';
    }
  } catch (_) {
    // 兜底: 任意 render 抛异常都退化到 "[<type>]"; 不抛给 caller, 不影响下一个 block。
    return '[$type]';
  }
}

// ---- safe helpers (F1 hardening) ----

/// 把任意 dynamic 当 String 取; 不是 String/num/bool → ""; null → ""。
/// 不调 `.toString()` 在 Map/List 上 (避免产生形如 "{a: 1}" 的脏值, 拼出来的 UI 一眼看出 bug)。
String _asString(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return '';
}

/// 把任意 dynamic 当 List 取; 不是 List → null。**禁止**用 `v as List?`, 因为 v 是 Map/String 时
/// `as List?` 会抛 TypeError, runtime 给的 typed block 字段类型不规范时整条 message 会被卡死。
List<dynamic>? _asList(Object? v) {
  if (v is List) return v;
  return null;
}

/// 把任意 dynamic 当 Map 取; 不是 Map → null。
Map<dynamic, dynamic>? _asMap(Object? v) {
  if (v is Map) return v;
  return null;
}

// ---- per-type renderers ----

String _renderChart(Map b) {
  final title = _asString(b['title']);
  final kind = _asString(b['chart_kind']);
  final kindFallback = kind.isNotEmpty ? kind : _asString(b['kind']);
  final summary = _asString(b['summary']);
  final unit = _asString(b['unit']);
  final source = _asString(b['source']);
  final updatedAt = _asString(b['updated_at']);

  final label = title.isNotEmpty
      ? title
      : (kindFallback.isNotEmpty ? kindFallback : '图表');
  // round-9 fallback 文本最多 1 短行 + summary; 不输出 insights/table 原文以免污染历史正文,
  // 让客户端富 widget 才是 source-of-truth。unit/source/updated_at 各占 1 个小段。
  final tail = <String>[];
  if (summary.isNotEmpty) tail.add(summary);
  final meta = <String>[];
  if (unit.isNotEmpty) meta.add('单位: $unit');
  if (source.isNotEmpty) meta.add('来源: $source');
  if (updatedAt.isNotEmpty) meta.add('更新: $updatedAt');
  if (meta.isNotEmpty) tail.add(meta.join(' · '));
  if (tail.isEmpty) return '[图表] $label';
  return '[图表] $label · ${tail.join(' · ')}';
}

String _renderForm(Map b) {
  // 故意**不**读 b['submit_label']: 表单提交按钮文案 (例如 "提交" / "Submit") 暗示用户能直接
  // 点这条 fallback 就发出去, 但 Stage 4 只读 fallback **不能** 真触发提交回路, 显示"提交"会
  // 误导用户。只允许出 title + description; 其余统一固定占位文案。
  final title = _asString(b['title']);
  final desc = _asString(b['description']);
  if (title.isNotEmpty && desc.isNotEmpty) return '[表单] $title · $desc';
  if (title.isNotEmpty) return '[表单] $title · 需在客户端最新版查看完整组件';
  return '[表单] · 需在客户端最新版查看完整组件';
}

String _renderAction(Map b) {
  final title = _asString(b['title']);
  // F1: 不再 `as List?`; runtime 可能返 Map / String / null, 必须 safe coerce。
  final actions =
      _asList(b['actions']) ?? _asList(b['buttons']) ?? _asList(b['items']);
  final labels = <String>[];
  if (actions != null) {
    for (final a in actions) {
      final am = _asMap(a);
      if (am == null) continue;
      final lab = _firstNonEmpty([
        _asString(am['label']),
        _asString(am['title']),
        _asString(am['text']),
      ]);
      if (lab.isNotEmpty) labels.add(lab);
    }
  }
  final head = title.isNotEmpty ? '[操作栏] $title' : '[操作栏]';
  if (labels.isEmpty) return '$head · 需在客户端最新版查看完整组件';
  return '$head · ${labels.join(' / ')}';
}

String _renderApproval(Map b) {
  final title = _firstNonEmpty([_asString(b['title']), _asString(b['prompt'])]);
  final base = title.isNotEmpty ? '[审批] $title' : '[审批]';
  return '$base · 需在客户端最新版查看完整组件';
}

String _renderArtifact(Map b) {
  final kind =
      _firstNonEmpty([_asString(b['artifact_kind']), _asString(b['kind'])]);
  final name = _firstNonEmpty([
    _asString(b['name']),
    _asString(b['title']),
    _asString(b['filename']),
  ]);
  final base = name.isNotEmpty ? name : '附件';
  return kind.isNotEmpty ? '[附件 · $kind] $base' : '[附件] $base';
}

String _renderSource(Map b) {
  final title = _firstNonEmpty([_asString(b['title']), _asString(b['name'])]);
  final url = _asString(b['url']);
  if (title.isNotEmpty && url.isNotEmpty) return '[来源] $title ($url)';
  if (title.isNotEmpty) return '[来源] $title';
  if (url.isNotEmpty) return '[来源] $url';
  // F1: items / sources 也 safe coerce; 拿不到合法 List → 退化到 [来源]
  final items = _asList(b['items']) ?? _asList(b['sources']);
  if (items != null && items.isNotEmpty) return '[来源] ${items.length} 项';
  return '[来源]';
}

String _renderProgress(Map b) {
  final percent = b['percent'] ?? b['progress'];
  final label = _firstNonEmpty([_asString(b['label']), _asString(b['title'])]);
  final base = label.isNotEmpty ? '[进度] $label' : '[进度]';
  if (percent is num) return '$base · ${percent.toStringAsFixed(0)}%';
  return base;
}

String _renderAppCard(Map b) {
  final title = _firstNonEmpty([_asString(b['title']), _asString(b['name'])]);
  final summary =
      _firstNonEmpty([_asString(b['summary']), _asString(b['description'])]);
  final base = title.isNotEmpty ? '[卡片] $title' : '[卡片]';
  return summary.isNotEmpty ? '$base · $summary' : base;
}

String _renderPlan(Map b) {
  final title = _asString(b['title']);
  // F1: steps / items 安全 coerce; 错型 → 直接退到 head, 不再 count。
  final steps = _asList(b['steps']) ?? _asList(b['items']);
  final head = title.isNotEmpty ? '[计划] $title' : '[计划]';
  if (steps == null || steps.isEmpty) return head;
  return '$head · ${steps.length} 步';
}

String _renderSuggestion(Map b) {
  final title = _firstNonEmpty([_asString(b['title']), _asString(b['name'])]);
  final items =
      _asList(b['suggestions']) ?? _asList(b['items']) ?? _asList(b['options']);
  final labels = <String>[];
  if (items != null) {
    for (final item in items) {
      if (item is String && item.trim().isNotEmpty) {
        labels.add(item.trim());
        continue;
      }
      final m = _asMap(item);
      if (m == null) continue;
      final label = _firstNonEmpty([
        _asString(m['label']),
        _asString(m['text']),
        _asString(m['title']),
        _asString(m['value']),
      ]);
      if (label.trim().isNotEmpty) labels.add(label.trim());
    }
  }
  final inline = _firstNonEmpty([
    _asString(b['text']),
    _asString(b['summary']),
    _asString(b['description']),
  ]);
  final base = title.isNotEmpty ? '[建议] $title' : '[建议]';
  if (labels.isNotEmpty) return '$base · ${labels.join(' / ')}';
  return inline.isNotEmpty ? '$base · $inline' : base;
}

String _renderDiagramSource(Map b, String type) {
  final title = _firstNonEmpty([_asString(b['title']), _asString(b['name'])]);
  final source = _firstNonEmpty([
    _asString(b['source']),
    _asString(b['code']),
    _asString(b['text']),
    _asString(b['content']),
    _asString(b['diagram']),
    _asString(b['mermaid']),
  ]);
  final base = title.isNotEmpty ? '[图表源码] $title' : '[图表源码] $type';
  return source.isNotEmpty ? '$base · $source' : base;
}

String _renderCode(Map b) {
  final lang = _firstNonEmpty([_asString(b['language']), _asString(b['lang'])]);
  final text = _firstNonEmpty([
    _asString(b['text']),
    _asString(b['source']),
    _asString(b['content']),
  ]);
  if (text.isEmpty) return '[代码]';
  final fence = '```$lang';
  return '$fence\n$text\n```';
}

String _renderTable(Map b) {
  final title = _asString(b['title']);
  final rows = _asList(b['rows']);
  final base = title.isNotEmpty ? '[表格] $title' : '[表格]';
  if (rows != null) return '$base · ${rows.length} 行';
  return base;
}

String _renderInlineError(Map b) {
  final msg = _firstNonEmpty([_asString(b['message']), _asString(b['text'])]);
  return msg.isNotEmpty ? '[错误] $msg' : '[错误]';
}

String _firstNonEmpty(List<String> candidates) {
  for (final c in candidates) {
    if (c.isNotEmpty) return c;
  }
  return '';
}
