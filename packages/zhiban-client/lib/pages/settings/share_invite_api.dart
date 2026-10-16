import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:riverpod/riverpod.dart';

/// F29 分享给朋友 — Bus 接口封装。
/// 契约见 docs/features/F29-friend-share-invite.md §4.1 与
/// docs/contracts/agent-bus-client-contract.md §17。

/// 账号专属邀请码（稳定不过期；服务端 find-or-create）。
class ShareInvite {
  const ShareInvite({required this.inviteCode, required this.url});

  /// 大写展示形态，如 ZBAI-8K29。
  final String inviteCode;

  /// 官网落地链接（服务端拼接，客户端不自拼），如 https://www.zbwork.cn/?ref=ZBAI-8K29。
  final String url;

  factory ShareInvite.fromJson(Map<String, dynamic> json) {
    return ShareInvite(
      inviteCode: (json['invite_code'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
    );
  }
}

class ShareInviteService {
  const ShareInviteService();

  Future<ShareInvite> fetchInvite() async {
    final raw = responseAsMap(await request.get('/share/invite'));
    return ShareInvite.fromJson(raw);
  }
}

final shareInviteServiceProvider =
    Provider<ShareInviteService>((_) => const ShareInviteService());

/// 打开分享弹框时拉取；autoDispose 保证登出/切号后不留旧码。
final shareInviteProvider = FutureProvider.autoDispose<ShareInvite>(
  (ref) => ref.watch(shareInviteServiceProvider).fetchInvite(),
);
