/// 客户端「我的」页用的账号信息聚合视图。
///
/// 字段 surface 沿用历史 ai-office 版命名，是因为 settings_page.dart 调用面比较大；
/// 实际数据来源已切到 agent-bus `/auth/me`（见 [`docs/contracts/agent-bus-client-contract.md` §11.2]）。
/// 凡是 agent-bus 暂时不返回的字段（employeeId、positionName、wallet 等），用空值/0 兜底；
/// 钱包模块在 v1.0 不做，UI 应隐藏对应入口。
class AccountInfo {
  final String employeeId;
  final String accountNo;
  final String name;
  final String nickname;
  final String email;
  final String phone;
  final String avatar;
  final String departmentId;
  final String departmentName;
  final String departmentFullName;
  final String positionName;
  final String tenantId;
  final String tenantName;
  final String tenantType;
  final String welcomeMsg;
  final int walletBalance;
  final String walletBalanceYuan;

  const AccountInfo({
    required this.employeeId,
    required this.accountNo,
    required this.name,
    required this.nickname,
    required this.email,
    required this.phone,
    required this.avatar,
    required this.departmentId,
    required this.departmentName,
    required this.departmentFullName,
    required this.positionName,
    required this.tenantId,
    required this.tenantName,
    required this.tenantType,
    required this.welcomeMsg,
    required this.walletBalance,
    required this.walletBalanceYuan,
  });

  /// agent-bus `/auth/me` 响应映射:
  /// ```
  /// { account: { id, uuid, displayName, email, emailMasked, phone, phoneMasked,
  ///              username, avatarUrl, departmentName, mustChangePassword },
  ///   scopes:  [ { kind, tenantId, tenantSlug, tenantName, ... } ] }
  /// ```
  /// 字段命名是混合的 (camelCase + 部分 snake_case alias)，这里两种都兼容。
  /// 同时兼容本地 SharedPreferences 缓存里的旧 schema (ai-office 时期 toJson 写下的)。
  factory AccountInfo.fromJson(Map<String, dynamic> json,
      {String? activeTenantId}) {
    final account =
        (json['account'] as Map?)?.cast<String, dynamic>() ?? const {};
    final scopes = (json['scopes'] as List?) ?? const [];
    final Map<String, dynamic> firstTenantScope = scopes
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .firstWhere(
          (s) =>
              (s['kind'] ?? '').toString() == 'tenant' &&
              (activeTenantId == null ||
                  s['tenantId'].toString() == activeTenantId),
          orElse: () => const <String, dynamic>{},
        );

    // 兼容老缓存: 老 schema 顶层是 {account, tenant, wallet}，account 里是 ai-office 字段名。
    final legacyTenant =
        (json['tenant'] as Map?)?.cast<String, dynamic>() ?? const {};
    final legacyWallet =
        (json['wallet'] as Map?)?.cast<String, dynamic>() ?? const {};

    String firstNonEmpty(Iterable<Object?> candidates) {
      for (final c in candidates) {
        final s = (c ?? '').toString().trim();
        if (s.isNotEmpty) return s;
      }
      return '';
    }

    final displayName = firstNonEmpty([
      account['displayName'],
      account['display_name'],
      account['nickname'],
      account['name'],
    ]);
    final phonePlain = firstNonEmpty([
      account['phone'],
      account['phonePlain'],
    ]);
    final phoneMasked = firstNonEmpty([
      account['phoneMasked'],
      account['phone_masked'],
    ]);
    final emailPlain = firstNonEmpty([
      account['email'],
      account['emailPlain'],
    ]);
    final avatar = firstNonEmpty([
      account['avatarUrl'],
      account['avatar_url'],
      account['avatar'],
    ]);
    final departmentName = firstNonEmpty([
      account['departmentName'],
      account['department_name'],
    ]);

    return AccountInfo(
      employeeId:
          firstNonEmpty([account['employeeId'], account['employee_id']]),
      accountNo: firstNonEmpty([
        account['username'],
        account['uuid'],
        account['accountNo'],
        account['id']?.toString(),
      ]),
      name: displayName,
      nickname: displayName,
      email: emailPlain,
      // 后端可能只返回脱敏号 (phoneMasked)，明文需要 phonePlain；都没有就退一步给脱敏号当展示。
      phone: phonePlain.isNotEmpty ? phonePlain : phoneMasked,
      avatar: avatar,
      departmentId:
          firstNonEmpty([account['departmentId'], account['department_id']]),
      departmentName: departmentName,
      departmentFullName: firstNonEmpty([
        account['departmentFullName'],
        account['department_full_name'],
        departmentName,
      ]),
      positionName:
          firstNonEmpty([account['positionName'], account['position_name']]),
      tenantId: firstNonEmpty([
        firstTenantScope['tenantSlug'],
        firstTenantScope['tenantId']?.toString(),
        legacyTenant['publicTenantId'],
      ]),
      tenantName: firstNonEmpty([
        firstTenantScope['tenantName'],
        legacyTenant['name'],
      ]),
      tenantType: firstNonEmpty([legacyTenant['tenantType']]),
      welcomeMsg:
          firstNonEmpty([account['welcomeMsg'], account['welcome_msg']]),
      // 钱包模块 v1.0 未实现; 这里恒为 0, UI 应隐藏余额/充值/账单入口。
      walletBalance:
          int.tryParse((legacyWallet['balance'] ?? '0').toString()) ?? 0,
      walletBalanceYuan: (legacyWallet['balanceYuan'] ?? '').toString(),
    );
  }

  /// 仅用于本地缓存往返。沿用旧 schema 让历史缓存仍能解析。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'account': <String, dynamic>{
          'employeeId': employeeId,
          'accountNo': accountNo,
          'displayName': name,
          'nickname': nickname,
          'emailPlain': email,
          'phonePlain': phone,
          'avatarUrl': avatar,
          'departmentId': departmentId,
          'departmentName': departmentName,
          'departmentFullName': departmentFullName,
          'positionName': positionName,
          'welcomeMsg': welcomeMsg,
        },
        'tenant': <String, dynamic>{
          'publicTenantId': tenantId,
          'name': tenantName,
          'tenantType': tenantType,
        },
        'wallet': <String, dynamic>{
          'balance': walletBalance,
          'balanceYuan': walletBalanceYuan,
        },
      };
}
