// f03_skills_providers.dart — F03 v0.9.1 SkillHub Riverpod 接入
// docs/features/F03-skills.md §3.3 / §5。
//
// 提供：
//   - f03SkillsServiceProvider          F03SkillsService 单例
//   - skillRailProvider(convUuid)       autoDispose 拉取并缓存 chip rail；
//                                       config_version 变化时手动 invalidate 重拉
//   - reportHandshakeOnceProvider       App 启动后只调一次 handshake 上报的 helper
//
// UI 集成（chip rail 渲染、参数模式、14 类 chip 控件）见 spec §5，本文件不涉及。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/skills/services/f03_skills_service.dart';
import 'package:zhiban_client/pages/skills/models/f03_skill_models.dart';

final f03SkillsServiceProvider = Provider<F03SkillsService>((ref) {
  return F03SkillsService();
});

/// chip rail 当前会话维度的 autoDispose family。
///
/// 服务端返回 `cache_ttl_seconds`（默认 300s）+ `config_version`；前端可：
///   - 进入会话时 read 一次
///   - SSE 收到 `skill-rail-config-invalidate` 事件 → ref.invalidate(skillRailProvider(uuid))
///   - 用户手动下拉刷新 → ref.invalidate(...)
final skillRailProvider =
    FutureProvider.autoDispose.family<F03SkillRail, String>((ref, convUuid) {
  final svc = ref.watch(f03SkillsServiceProvider);
  return svc.getSkillRailConfig(convUuid);
});

/// builtin handshake 上报；调用方按需在 App 启动 / version bump 时调一次。
///
/// 这里不放 autoDispose — 应用周期内只调一次，幂等由后端保证。
class F03HandshakeReporter {
  F03HandshakeReporter(this._svc);
  final F03SkillsService _svc;

  Future<void> report({
    required String clientPlatform,
    required String clientVersion,
    required String deviceId,
    required List<String> supportedBuiltinKeys,
  }) async {
    await _svc.reportHandshake(
      clientPlatform: clientPlatform,
      clientVersion: clientVersion,
      deviceId: deviceId,
      supportedBuiltinKeys: supportedBuiltinKeys,
    );
  }
}

final f03HandshakeReporterProvider = Provider<F03HandshakeReporter>((ref) {
  return F03HandshakeReporter(ref.watch(f03SkillsServiceProvider));
});
