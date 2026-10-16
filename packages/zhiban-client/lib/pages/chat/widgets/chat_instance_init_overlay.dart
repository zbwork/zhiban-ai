import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'lobster_loading_view.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Widget? buildChatInstanceInitOverlay(WidgetRef ref) {
  final instanceAsync = ref.watch(openClawInstanceProvider);
  final instance = instanceAsync.asData?.value;
  final isBootstrapping = instanceAsync.isLoading && instance == null;
  // 阶段 1：实例还没 running——OpenClaw pod 在 creating / pending。
  final isCreatingInstance = instance != null &&
      !instance.isIdle &&
      !instance.isRunning &&
      !instance.isError;
  // 阶段 2：实例已 running 但默认 agent（"私人助理"）还没建好——ensureDefaultAgent
  // 在跑（首次需要 OpenClaw CLI 建 workspace、写 7 文件、调 OpenClaw 注册 agent）。
  // 不挡住这一段会让用户进到一个空对话页，加载一会才弹出私人助理（产品体验 bug）。
  final isInitializingAgent =
      instance != null && instance.isRunning && !instance.defaultAgentReady;
  // 阶段 3：实例 running 且默认 agent 已建好，但 OpenClaw gateway 还没真正能接 WS。
  // 这一段是 k8s pod Running 到 :18789 control-server 真正 listen + 能完成 v3
  // connect 握手之间的真空期，过早放用户进对话页 → 首条 chat.send 直接撞
  // i/o timeout（OpenClaw WS 调用失败: ws dial: ... i/o timeout）。
  // ai-office 后端通过 gatewaywsclient.Probe 实测，给出 gatewayReady 信号。
  final isWaitingGateway = instance != null &&
      instance.isRunning &&
      instance.defaultAgentReady &&
      !instance.gatewayReady;

  if (instanceAsync.hasError) {
    return _InstanceInitErrorOverlay(
      error: instanceAsync.error!,
      onRetry: () => ref.invalidate(openClawInstanceProvider),
    );
  }

  if (instance?.isError == true) {
    return _InstanceInitErrorOverlay(
      error: '龙虾初始化失败',
      onRetry: () => ref.invalidate(openClawInstanceProvider),
    );
  }

  if (isBootstrapping) {
    return const Center(
      child: CupertinoActivityIndicator()
    );
  }

  if (isCreatingInstance) {
    return LobsterLoadingView(
      title: '正在启动龙虾',
      subtitle: instance.message?.trim().isNotEmpty == true
          ? instance.message!.trim()
          : '基础服务已提交启动请求，正在轮询实例状态，请稍候片刻。',
    );
  }

  if (isInitializingAgent) {
    return const LobsterLoadingView(
      title: '正在初始化数字员工 · 私人助理',
      subtitle: '帮你建立专属工作空间、装配默认技能（小红书/高德地图等），稍后即可开始对话。',
    );
  }

  if (isWaitingGateway) {
    return const LobsterLoadingView(
      title: '正在唤醒龙虾',
      subtitle: '基础服务已就绪，正在等待对话通道完成预热，通常只需几秒。',
    );
  }

  return null;
}

class _InstanceInitErrorOverlay extends StatelessWidget {
  const _InstanceInitErrorOverlay({
    required this.error,
    required this.onRetry
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF5F8FE),
      child: Center(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle_fill,
                size: 36,
                color: Color(0xFFD92D20),
              ),
              const SizedBox(height: 16),
              const Text(
                '龙虾初始化失败',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF162033),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Color(0xFF667085),
                ),
              ),
              const SizedBox(height: 20),
              CupertinoButton.filled(
                onPressed: onRetry,
                child: const Text('重新初始化'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
