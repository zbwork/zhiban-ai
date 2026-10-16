// f03_skills_service.dart — F03 v0.9.1 SkillHub 客户端 API
// docs/features/F03-skills.md §3.3。
//
// 与现有 OpenClawSkillsService 并存：
//   - OpenClawSkillsService: legacy /app/openclaw-agent/skills 旧广场接口（待迁出）
//   - F03SkillsService:      新版 /api/agent-bus/v1/* 客户端接口
//
// 覆盖：
//   - GET    /conversations/{cuuid}/skill-rail-config   chip rail 装载
//   - GET    /skills                                    广场列表
//   - POST   /agents/{u}/skill-overrides                临时挂/摘
//   - DELETE /agents/{u}/skill-overrides/{skill_uuid}   清除 override
//   - POST   /builtin-skills/handshake                  builtin 上报
//
// UI 集成（chip rail 渲染、14 类 chip 控件、参数模式状态机）见 spec §5，本 service
// 仅提供数据层。
import 'package:dio/dio.dart';
import 'package:zhiban_client/network/network.dart';

import 'package:zhiban_client/pages/skills/models/f03_skill_models.dart';

class F03SkillsService {
  F03SkillsService();

  /// chip rail 装载（spec §3.3.A）。client_platform / device_id / version 由调用方
  /// 在 header 注入（X-Client-Platform / X-Device-Id / X-Client-Version）—
  /// 用于服务端做 builtin 兼容裁剪。
  Future<F03SkillRail> getSkillRailConfig(String conversationUUID,
      {String? acceptLanguage,
      String? clientPlatform,
      String? clientVersion,
      String? deviceId}) async {
    final headers = <String, dynamic>{};
    if (acceptLanguage != null) headers['Accept-Language'] = acceptLanguage;
    if (clientPlatform != null) headers['X-Client-Platform'] = clientPlatform;
    if (clientVersion != null) headers['X-Client-Version'] = clientVersion;
    if (deviceId != null) headers['X-Device-Id'] = deviceId;
    final resp = await request.get(
      '/conversations/$conversationUUID/skill-rail-config',
      options: Options(headers: headers),
    );
    return F03SkillRail.fromJson(_unwrap(resp));
  }

  /// 广场列表（spec §3.3.C）。
  Future<F03SkillSquare> listSkills({
    String? agentUUID,
    int? categoryID,
    String? keyword,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, dynamic>{'limit': limit, 'offset': offset};
    if (agentUUID != null) query['agent_uuid'] = agentUUID;
    if (categoryID != null) query['category_id'] = categoryID;
    if (keyword != null && keyword.isNotEmpty) query['q'] = keyword;
    final resp = await request.get('/skills', queryParameters: query);
    return F03SkillSquare.fromJson(_unwrap(resp));
  }

  /// 临时挂/摘技能（spec §3.3.B）。
  Future<F03Override> upsertOverride(
    String agentUUID, {
    required String skillUUID,
    required String behavior, // temporary_attach / temporary_detach
    DateTime? expiresAt,
  }) async {
    final body = <String, dynamic>{
      'skill_uuid': skillUUID,
      'behavior': behavior,
    };
    if (expiresAt != null) {
      body['expires_at'] = expiresAt.toUtc().toIso8601String();
    }
    final resp = await request.post(
      '/agents/$agentUUID/skill-overrides',
      data: body,
    );
    return F03Override.fromJson(_unwrap(resp));
  }

  /// 清除 override。
  Future<void> deleteOverride(String agentUUID, String skillUUID) async {
    await request.delete(
      '/agents/$agentUUID/skill-overrides/$skillUUID'
    );
  }

  /// 客户端 builtin 能力 handshake 上报（spec §3.3.D）。
  ///
  /// 客户端启动后 24h 内调一次，或客户端版本变化时立刻调。
  /// 服务端按 (account_id, client_platform, device_id) upsert，幂等。
  Future<void> reportHandshake({
    required String clientPlatform, // ios / android / macos / windows / web
    required String clientVersion,
    required String deviceId,
    required List<String> supportedBuiltinKeys,
  }) async {
    await request.post(
      '/builtin-skills/handshake',
      data: {
        'client_platform': clientPlatform,
        'client_version': clientVersion,
        'device_id': deviceId,
        'supported_builtin_keys': supportedBuiltinKeys,
      },
    );
  }

  Map<String, dynamic> _unwrap(Response resp) {
    final data = resp.data;
    if (data is Map<String, dynamic>) {
      // 后端 encode.JSON 形如 {code, message, data}; 兼容裸 map。
      if (data['data'] is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>;
      }
      return data;
    }
    return <String, dynamic>{};
  }
}
