import 'package:flutter/cupertino.dart';

import '../models/ai_model_capability.dart';

enum ModelModality {
  text('文本', CupertinoIcons.textformat),
  image('图片', CupertinoIcons.photo),
  embedding('嵌入', CupertinoIcons.cube),
  audio('音频', CupertinoIcons.waveform),
  video('视频', CupertinoIcons.video_camera),
  rerank('重排', CupertinoIcons.arrow_up_arrow_down);

  const ModelModality(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 从模型标识猜它的模态分类，纯本地关键词启发式——多数厂商的 `/models`
/// 列表接口本身不返回模态元数据（Google 的 `supportedGenerationMethods`
/// 是个例外，但为了三种协议口径一致，这里统一走同一套命名关键词规则）。
/// 跟 Cherry Studio/LobeChat 这类客户端的分类 chip 做法一样：不是厂商权威
/// 声明的模态，是"看名字猜的"，猜不中的一律兜底成文本。
ModelModality classifyModelId(String modelId) {
  final id = modelId.toLowerCase();
  bool any(List<String> keywords) => keywords.any(id.contains);

  if (any(['rerank'])) return ModelModality.rerank;
  if (any(['embed', 'bge-', 'bce-', 'gte-', 'nomic-embed'])) {
    return ModelModality.embedding;
  }
  if (any(['whisper', 'tts', 'speech', 'audio', 'voice', 'musicgen'])) {
    return ModelModality.audio;
  }
  // 图片必须判断在视频前面：阿里"万相"系列图片型号（wanx-v1、wanx2.1-t2i-plus、
  // wan2.6-image）和视频型号共用 "wan/wan2.x" 前缀，只能靠更具体的图片关键词
  // （wanx/t2i/i2i/image/img）先截胡，不然会被下面通用的视频关键词一起吃掉
  // （2026-08-27 反馈：qwen/阿里的图片模型比如 gemini-*-image、wan2.6-image
  // 被分类成文本或视频，导致"图片"分类永远是 0）。
  if (any([
    'dall-e',
    'dalle',
    'stable-diffusion',
    'sdxl',
    'sd3',
    'flux',
    'midjourney',
    'kolors',
    'cogview',
    'klein',
    'wanx',
    't2i',
    'i2i',
    'image',
    'img',
  ])) {
    return ModelModality.image;
  }
  if (any([
    'video',
    'sora',
    'runway',
    'cogvideo',
    'hunyuanvideo',
    'wan2.',
    't2v',
    'i2v',
  ])) {
    return ModelModality.video;
  }
  return ModelModality.text;
}

/// 从模型标识猜它支持的能力标签，跟 [classifyModelId] 一样是纯本地关键词
/// 启发式——CherryIN 这类聚合平台能在获取模型列表时直接给出"推理/工具调用/
/// 视觉"这些标签，是它们自己接口返回的定制元数据；标准 OpenAI/Anthropic/
/// Google/Ollama 的 `/models` 接口都不会给这些字段，这里只能按命名规律猜，
/// 猜不准的地方（尤其 reasoning/toolUse）宁可放宽规则多标一点，也不细究
/// ——不是权威声明，仅供参考。
Set<AiModelCapability> guessModelCapabilities(String modelId) {
  final id = modelId.toLowerCase();
  bool any(List<String> keywords) => keywords.any(id.contains);
  final modality = classifyModelId(modelId);
  final result = <AiModelCapability>{};

  if (modality == ModelModality.embedding) {
    result.add(AiModelCapability.embedding);
    // 嵌入/重排/语音/视频/图片模型不是通用对话模型，不参与下面的推理/工具/
    // 视觉猜测。
    return result;
  }
  if (modality != ModelModality.text) return result;

  if (any([
    'r1',
    'o1',
    'o3',
    'o4',
    'thinking',
    'reasoner',
    'reasoning',
    'qwq',
    'glm-z',
    'marco-o1',
  ])) {
    result.add(AiModelCapability.reasoning);
  }
  if (any([
    'vl',
    'vision',
    'llava',
    'gpt-4o',
    'gpt-5',
    'claude-3',
    'claude-4',
    'gemini',
    'internvl',
    'cogvlm',
    'pixtral',
    'moondream',
  ])) {
    result.add(AiModelCapability.vision);
  }
  // 工具调用现在是通用对话模型的标配能力，narrow 到单一任务的模型已经在
  // 上面按 modality 提前 return 了，剩下能走到这里的默认给工具调用标签。
  result.add(AiModelCapability.toolUse);
  return result;
}

/// 少数几个"同一厂商但历史上有多种前缀写法"的归一化——比如 OpenAI 的模型
/// 在不同网关里可能是 `chatgpt-4o-latest` 也可能是 `gpt-4.1`，硬切前缀会拆成
/// 两组；这张表只覆盖这几个已知会撞车的情况，不是穷举厂商列表（穷举列表在
/// [guessVendorGroup] 里被替换成通用规则了）。
const _kFamilyCanonicalization = <String, String>{
  'chatgpt': 'openai',
  'gpt': 'openai',
  'o1': 'openai',
  'o3': 'openai',
  'o4': 'openai',
  'qwen': 'alibaba',
  'qwq': 'alibaba',
  'kimi': 'moonshot',
  'chatglm': 'zhipu',
  'glm': 'zhipu',
  'grok': 'xai',
};

/// 从模型标识猜它所属的厂商分组，没有 "vendor/model" 前缀（聚合网关常见的
/// `chatgpt-4o-latest`、`qwen-max-latest` 这种扁平命名）时的兜底规则：取第
/// 一个 "-" 之前的片段当厂商/系列前缀（`deepseek-v3.2` → `deepseek`），版本
/// 号直接贴在前缀后面的写法（`qwen3-235b...`）再去掉末尾数字归一化，让它跟
/// `qwen-max-latest` 分到一组，不然同一厂商会被拆成两组。完全没有 "-" 时
/// （比如一个家族的基础款就叫 `k3`，同批还有 `k3-256k`）把整个 id 当前缀，
/// 不然这个基础款会被扔进"未分组"、跟同一家族的其他变体拆开（2026-09-03
/// 反馈：BeeBridge 的 `k3` 独立于 `K3` 分组之外单独出现）。猜不中/前缀太短
/// （比如短到只剩 1 个字符，没有辨识度）返回 null，调用方自己决定落到
/// "不分组"兜底，不编一个不存在的分组。
String? guessVendorGroup(String modelId) {
  final trimmed = modelId.trim();
  if (trimmed.contains('/')) return null;
  final dashIdx = trimmed.indexOf('-');
  if (dashIdx == 0) return null;
  var family =
      (dashIdx > 0 ? trimmed.substring(0, dashIdx) : trimmed).toLowerCase();
  if (family.length >= 4) {
    final stripped = family.replaceFirst(RegExp(r'\d+$'), '');
    if (stripped.length >= 3) family = stripped;
  }
  if (family.length < 2) return null;
  return _kFamilyCanonicalization[family] ?? family;
}
