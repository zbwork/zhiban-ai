/// 内置目录的只读协议元数据。
///
/// 当前不属于用户可编辑的 Provider 配置，只用于模型列表探测、密钥检测和
/// 企业 BYOK 契约映射。Flutter 本地对话 Runtime 恢复前不得据此宣称已支持
/// 多协议对话。
enum AiEndpointType {
  /// OpenAI Chat Completions 兼容格式，绝大多数国产/第三方厂商都实现了这个协议。
  openaiCompatible,

  /// Anthropic Messages API 格式。
  anthropicMessages,

  /// Google Generative AI（Gemini）格式。
  googleGenerativeAi,

  /// 其他自定义协议，暂不假设具体格式。
  custom,
}
