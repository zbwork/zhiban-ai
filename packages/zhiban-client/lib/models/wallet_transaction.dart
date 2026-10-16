class WalletTransactionsResult {
  const WalletTransactionsResult({
    required this.items,
    required this.total
  });

  final List<WalletTransactionItem> items;
  final int total;

  factory WalletTransactionsResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <WalletTransactionItem>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map<String, dynamic>) {
          items.add(WalletTransactionItem.fromJson(item));
        } else if (item is Map) {
          items.add(WalletTransactionItem.fromJson(
            Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return WalletTransactionsResult(
      items: items,
      total: int.tryParse((json['total'] ?? items.length).toString()) ??
          items.length,
    );
  }
}

class WalletTransactionItem {
  const WalletTransactionItem({
    required this.direction,
    required this.amount,
    required this.amountYuan,
    required this.balanceAfter,
    required this.reason,
    required this.remark,
    required this.bizNo,
    required this.usedAt,
    required this.createdAt,
  });

  final String direction;
  final int amount;
  final String amountYuan;
  final int balanceAfter;
  final String reason;
  final String remark;
  final String bizNo;
  final DateTime? usedAt;
  final DateTime? createdAt;

  factory WalletTransactionItem.fromJson(Map<String, dynamic> json) {
    return WalletTransactionItem(
      direction: (json['direction'] ?? '').toString(),
      amount: int.tryParse((json['amount'] ?? '0').toString()) ?? 0,
      amountYuan: (json['amountYuan'] ?? '').toString(),
      balanceAfter: int.tryParse((json['balanceAfter'] ?? '0').toString()) ?? 0,
      reason: (json['reason'] ?? '').toString(),
      remark: (json['remark'] ?? '').toString(),
      bizNo: (json['bizNo'] ?? '').toString(),
      usedAt: _parseDateTime(json['usedAt']),
      createdAt: _parseDateTime(json['createdAt']),
    );
  }

  bool get isCredit => direction == 'credit';

  bool get isDebit => direction == 'debit';

  DateTime? get displayTime => usedAt ?? createdAt;

  String get reasonLabel {
    switch (reason) {
      case 'initial_grant':
        return '开通赠送';
      case 'recharge':
        return '充值';
      case 'consume':
        return '消费';
      case 'refund':
        return '退款';
      case 'reward':
        return '奖励';
      default:
        return reason.isEmpty ? '余额变动' : reason;
    }
  }

  String get title {
    final text = remark.trim();
    if (text.isNotEmpty) return text;
    return reasonLabel;
  }

  String get normalizedAmountYuan {
    final parsed = double.tryParse(amountYuan);
    if (parsed != null) return parsed.toStringAsFixed(4);
    if (amount == 0) return '0.0000';
    return (amount / 10000).toStringAsFixed(4);
  }

  String get signedAmountLabel {
    final sign = isCredit ? '+' : '-';
    return '$sign$normalizedAmountYuan';
  }

  String get balanceAfterYuan => (balanceAfter / 10000).toStringAsFixed(4);
}

DateTime? _parseDateTime(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}
