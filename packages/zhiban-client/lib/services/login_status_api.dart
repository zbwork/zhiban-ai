import 'package:zhiban_core/models/login_status.dart';
import 'package:zhiban_client/network/network.dart';

/// 「我的 · 登录状态」服务。
///
/// agent-bus cutover (M11):
/// - 列表走 `GET /me/sessions` (替代老 ai-office `/account/login-status`)
/// - 撤销走 `DELETE /me/sessions/{uuid}`，服务端会立即同步 Redis 黑名单
///   并通过 pglistener 跨进程广播，旧 access token 几秒内全部失效。
/// 完整契约见 docs/contracts/agent-bus-client-contract.md §11.4。
class LoginStatusService {
  Future<LoginStatus> fetchLoginStatus() async {
    final response = await request.get('/me/sessions');
    final data = response.data as Map<String, dynamic>;
    return LoginStatus.fromJson(data);
  }

  /// 撤销指定 session (踢出该设备)。
  ///
  /// 业务侧只允许撤销当前账号自己的 session，越权由 service 层返回 403。
  /// 调用方若撤的是 `isCurrent=true` 的设备，请在成功后清本地 token 并跳登录页。
  Future<void> revokeSession(String sessionUuid) async {
    await request.delete('/me/sessions/$sessionUuid');
  }
}
