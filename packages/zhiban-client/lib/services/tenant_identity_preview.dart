import 'package:flutter/foundation.dart';
import 'package:zhiban_core/models/account_info.dart';

/// Presentation only: never use this snapshot for API identity or permissions.
final _preview = ValueNotifier<AccountInfo?>(null);
ValueListenable<AccountInfo?> get tenantIdentityPreview => _preview;

AccountInfo beginTenantIdentityPreview({
  required AccountInfo? current,
  required String tenantId,
  required String tenantName,
}) {
  final json = current?.toJson() ?? <String, dynamic>{};
  // The old member name belongs to the previous tenant. Clear it during the
  // transition so the header shows its neutral loading placeholder instead of
  // presenting stale identity data.
  final account =
      (json['account'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
  account['displayName'] = '';
  account['nickname'] = '';
  json['account'] = account;
  json['tenant'] = <String, dynamic>{
    'publicTenantId': tenantId,
    'name': tenantName,
  };
  final next = AccountInfo.fromJson(json);
  _preview.value = next;
  return next;
}

void clearTenantIdentityPreview([AccountInfo? expected]) {
  if (expected == null || identical(_preview.value, expected)) {
    _preview.value = null;
  }
}
