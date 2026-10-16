import '../models/catalog_entry.dart';

/// Cherry Studio icon registry 的 Flutter 适配：先按 modelId 的稳定家族前缀
/// 匹配品牌，再回退分组和当前 Provider。这里只列本项目已打包 SVG 的品牌。
final _modelVendorIconPatterns = <(RegExp, String)>[
  (RegExp(r'^(?:anthropic\.)?claude', caseSensitive: false), 'anthropic'),
  (
    RegExp(r'^(?:gemini|palm|veo|imagen|learnlm|lyria|gemma)',
        caseSensitive: false),
    'google'
  ),
  (RegExp(r'^grok', caseSensitive: false), 'grok'),
  (
    RegExp(
      r'^(?:gpt|o[134](?:[-_]|$)|chatgpt|codex|davinci|babbage|dall-e|text-moderation|text-embedding-(?:3|ada))',
      caseSensitive: false,
    ),
    'openai'
  ),
  (RegExp(r'^(?:qwen|qwq|qvq|tongyi)', caseSensitive: false), 'qwen'),
  (
    RegExp(r'^(?:doubao|skylark|seed|seedance|seedream|ep-)',
        caseSensitive: false),
    'volcengine'
  ),
  (
    RegExp(r'^(?:kimi|moonshot|k3(?:[-_.]|$))', caseSensitive: false),
    'moonshot'
  ),
  (RegExp(r'^deepseek', caseSensitive: false), 'deepseek'),
  (RegExp(r'^sonar', caseSensitive: false), 'perplexity'),
  (RegExp(r'^baichuan', caseSensitive: false), 'baichuan'),
  (RegExp(r'^mimo-', caseSensitive: false), 'mimo'),
  (RegExp(r'^(?:minimax|abab)', caseSensitive: false), 'minimax'),
  (RegExp(r'^step-', caseSensitive: false), 'step'),
  (
    RegExp(r'^(?:glm|chatglm|cogview|cogvideo|codegeex)', caseSensitive: false),
    'zhipu'
  ),
  (
    RegExp(
      r'^(?:open-|labs-)?(?:mistral|pixtral|codestral|ministral|voxtral|devstral|mixtral|magistral)',
      caseSensitive: false,
    ),
    'mistral'
  ),
  (RegExp(r'^(?:nemotron|nvidia)', caseSensitive: false), 'nvidia'),
  (RegExp(r'^voyage', caseSensitive: false), 'voyage'),
  (RegExp(r'^jina', caseSensitive: false), 'jina'),
];

/// 分组名（目录 groupName 真实数据 / modelId "vendor/model" 前缀 / 关键词猜
/// 出来的分组）跟内置目录 provider id 对不上时的别名——目录里是
/// `anthropic`/`openai`/`gemini`/`grok`/`dashscope`/`doubao`，实际见到的分组
/// 名却是更口语化的 `claude`/`chatgpt`/`google`/`xai`/`alibaba`/`bytedance`。
/// 只给最常见的建别名，查不到就摊手回退到首字母色块（[vendorGroupIconAssetPath]
/// 自带这个兜底），不瞎猜一个不存在的图标。
///
/// 「添加模型」列表和「已添加模型」列表共用这套映射——不给两个地方各写一遍
/// 几乎一样的逻辑(2026-08-27 反馈：已添加的模型也要有图标和分类)。
const kVendorGroupAliasToCatalogId = <String, String>{
  'claude': 'anthropic',
  'chatgpt': 'openai',
  'gpt': 'openai',
  'google': 'gemini',
  'xai': 'grok',
  'bytedance': 'doubao',
  // Qwen 本身没有单独入驻目录，借 dashscope（阿里云百炼，唯一收录 Qwen 模型
  // 的厂商条目）的图标；dashscope 的目录图标已经是真实 Qwen 品牌 SVG。
  'alibaba': 'dashscope',
  'qwen': 'dashscope',
  'qwq': 'dashscope',
  'tongyi': 'dashscope',
};

/// 分组名的展示文案——只处理"大小写/品牌拼写"这种确定性事实（ChatGPT 不是
/// Chatgpt），不做品牌替换（不会把 "alibaba" 显示成目录里查到的另一个不同
/// 名字），查不到就首字母大写兜底。
const kVendorGroupDisplayLabel = <String, String>{
  'chatgpt': 'ChatGPT',
  'gpt': 'GPT',
  'openai': 'OpenAI',
  'claude': 'Claude',
  'anthropic': 'Anthropic',
  'gemini': 'Gemini',
  'google': 'Google',
  'deepseek': 'DeepSeek',
  'minimax': 'MiniMax',
  'moonshot': 'Moonshot',
  'zhipu': '智谱',
  'xai': 'xAI',
  'grok': 'Grok',
  'alibaba': '阿里',
  'bytedance': '字节跳动',
  'mistral': 'Mistral',
  'meta': 'Meta',
};

String vendorGroupDisplayLabel(String group) {
  final mapped = kVendorGroupDisplayLabel[group.toLowerCase()];
  if (mapped != null) return mapped;
  if (group.isEmpty) return group;
  return group[0].toUpperCase() + group.substring(1);
}

/// 按分组名去内置目录里找一个真实存在的 Logo（先按 id 直接匹配，再查上面
/// 那张小别名表），找不到就返回 null——调用方的 `ProviderIcon` 会自动回退成
/// 首字母色块，不瞎猜一个不存在的图标。
String? vendorGroupIconAssetPath(
  String group,
  List<CatalogProviderEntry> providers,
) {
  if (group.isEmpty) return null;
  String normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
  final normalizedGroup = normalize(group);
  final aliasId = kVendorGroupAliasToCatalogId[normalizedGroup];
  for (final entry in providers) {
    final idNorm = normalize(entry.id);
    if (idNorm == normalizedGroup || (aliasId != null && idNorm == aliasId)) {
      return entry.iconAssetPath;
    }
  }
  return null;
}

/// 按 Cherry Studio 的回退顺序解析服务端模型图标：modelId 家族、列表分组、
/// 当前 Provider。modelId 取最后一个 `/` 片段，兼容聚合网关的命名空间 ID。
String? modelVendorIconAssetPath({
  required String modelId,
  required String group,
  required List<CatalogProviderEntry> providers,
  String? providerCatalogId,
}) {
  final baseModelId = modelId.trim().split('/').last.toLowerCase();
  for (final (pattern, iconKey) in _modelVendorIconPatterns) {
    if (!pattern.hasMatch(baseModelId)) continue;
    final matched = _iconAssetPathForKey(iconKey, providers);
    if (matched != null) return matched;
  }

  final groupIcon = vendorGroupIconAssetPath(group, providers);
  if (groupIcon != null) return groupIcon;

  if (providerCatalogId == null || providerCatalogId.isEmpty) return null;
  return vendorGroupIconAssetPath(providerCatalogId, providers);
}

String? _iconAssetPathForKey(
  String iconKey,
  List<CatalogProviderEntry> providers,
) {
  final suffix = '/${iconKey.toLowerCase()}.svg';
  for (final provider in providers) {
    final path = provider.iconAssetPath;
    if (path != null && path.toLowerCase().endsWith(suffix)) return path;
  }
  return null;
}
