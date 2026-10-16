import 'package:zhiban_client/im/wukong/wukong_session_identity.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:riverpod/riverpod.dart';

/// F28 客户端添加企业成员 — Bus 接口 1–3 封装。
/// 契约见 docs/features/F28-member-invitation.md §4.1 与
/// docs/contracts/agent-bus-client-contract.md「添加企业成员」。

/// 当前有效邀请（企业二维码与企业链接共用同一 token/URL/失效时间）。
class MemberInviteLink {
  const MemberInviteLink({
    required this.url,
    required this.expiresAt,
    required this.tenantName,
  });

  final String url;
  final DateTime? expiresAt;
  final String tenantName;

  factory MemberInviteLink.fromJson(Map<String, dynamic> json) {
    return MemberInviteLink(
      url: (json['url'] ?? '').toString(),
      expiresAt: DateTime.tryParse((json['expires_at'] ?? '').toString()),
      tenantName: (json['tenant_name'] ?? '').toString(),
    );
  }
}

/// 手机号定向邀请的单条结果（部分失败不影响其余）。
class MemberAddByPhoneResult {
  const MemberAddByPhoneResult({
    required this.phone,
    required this.ok,
    this.error = '',
    this.invitationUuid = '',
    this.status = '',
    this.smsSent = false,
  });

  final String phone;
  final bool ok;
  final String invitationUuid;
  final String status;
  final bool smsSent;

  /// invalid_phone / invalid_name / already_member / invitation_pending / internal
  final String error;

  factory MemberAddByPhoneResult.fromJson(Map<String, dynamic> json) {
    return MemberAddByPhoneResult(
      phone: (json['phone'] ?? '').toString(),
      ok: json['ok'] == true,
      error: (json['error'] ?? '').toString(),
      invitationUuid: (json['invitation_uuid'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      smsSent: json['sms_sent'] == true,
    );
  }

  String get errorLabel {
    switch (error) {
      case 'invalid_phone':
        return '手机号格式不正确';
      case 'invalid_name':
        return '姓名不能为空';
      case 'already_member':
        return '已是企业成员';
      case 'invitation_pending':
        return '已有待处理邀请';
      default:
        return '邀请失败，请稍后再试';
    }
  }
}

class MemberInviteService {
  const MemberInviteService();

  Future<MemberInviteLink> fetchLink() async {
    final raw = responseAsMap(await request.get('/org/member-invite'));
    return MemberInviteLink.fromJson(raw);
  }

  Future<MemberInviteLink> resetLink() async {
    final raw = responseAsMap(await request.post('/org/member-invite/reset'));
    return MemberInviteLink.fromJson(raw);
  }

  Future<List<MemberAddByPhoneResult>> addByPhone(
    List<({String phone, String name})> items,
  ) async {
    final raw = responseAsMap(await request.post(
      '/org/members/add-by-phone',
      data: <String, dynamic>{
        'items': [
          for (final it in items) {'phone': it.phone, 'name': it.name},
        ],
      },
    ));
    final results = raw['results'] is List ? raw['results'] as List : const [];
    return results
        .whereType<Map>()
        .map((e) => MemberAddByPhoneResult.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }
}

final memberInviteServiceProvider =
    Provider<MemberInviteService>((_) => const MemberInviteService());

/// 当前用户在当前租户是否可添加企业成员。
///
/// 口径：`/auth/me` 当前租户 scope（JWT act_tid）的 perms 含
/// `tenant.member.invite`。任何环节取不到都返回 false（fail-closed，
/// 与后端 handler 校验同权限点；这里只控制按钮可见性）。
final canInviteMemberProvider = FutureProvider<bool>((ref) async {
  try {
    final identity = await WukongSessionIdentity.current();
    final tenantId = identity?.tenantId ?? 0;
    if (tenantId <= 0) return false;
    final me = await ref.watch(authMeProvider.future);
    for (final scope in me.tenantScopes) {
      if (scope.tenantId == tenantId) {
        return scope.perms.contains('tenant.member.invite');
      }
    }
    return false;
  } catch (_) {
    return false;
  }
});

/// 当前有效邀请链接（打开弹窗时拉取；重置后由弹窗内部刷新）。
final memberInviteLinkProvider = FutureProvider.autoDispose<MemberInviteLink>(
  (ref) => ref.watch(memberInviteServiceProvider).fetchLink(),
);
