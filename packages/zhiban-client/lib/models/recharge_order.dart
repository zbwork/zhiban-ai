class NativeRechargeOrder {
  const NativeRechargeOrder({
    required this.outTradeNo,
    required this.codeUrl
  });

  final String outTradeNo;
  final String codeUrl;

  factory NativeRechargeOrder.fromJson(Map<String, dynamic> json) {
    return NativeRechargeOrder(
      outTradeNo: (json['outTradeNo'] ?? '').toString(),
      codeUrl: (json['codeUrl'] ?? '').toString(),
    );
  }
}

class AppRechargeOrder {
  const AppRechargeOrder({
    required this.outTradeNo,
    required this.prepayId,
    required this.appId,
    required this.partnerId,
    required this.packageValue,
    required this.nonceStr,
    required this.timestamp,
    required this.sign,
  });

  final String outTradeNo;
  final String prepayId;
  final String appId;
  final String partnerId;
  final String packageValue;
  final String nonceStr;
  final int timestamp;
  final String sign;

  factory AppRechargeOrder.fromJson(Map<String, dynamic> json) {
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? json;
    return AppRechargeOrder(
      outTradeNo: (data['outTradeNo'] ?? '').toString(),
      prepayId: (data['prepayId'] ?? '').toString(),
      appId: (data['appid'] ?? data['appId'] ?? '').toString(),
      partnerId: (data['partnerid'] ?? data['partnerId'] ?? '').toString(),
      packageValue: (data['package'] ?? 'Sign=WXPay').toString(),
      nonceStr: (data['noncestr'] ?? data['nonceStr'] ?? '').toString(),
      timestamp: int.tryParse((data['timestamp'] ?? '0').toString()) ?? 0,
      sign: (data['sign'] ?? '').toString(),
    );
  }

  bool get isValid =>
      prepayId.isNotEmpty &&
      appId.isNotEmpty &&
      partnerId.isNotEmpty &&
      nonceStr.isNotEmpty &&
      timestamp > 0 &&
      sign.isNotEmpty;
}

class RechargePaymentStatus {
  const RechargePaymentStatus({
    required this.outTradeNo,
    required this.transactionId,
    required this.status,
    required this.wechatTradeState,
    required this.wechatTradeDesc,
    required this.walletProcessed,
    required this.paymentSuccess,
    required this.paymentSuccessDesc,
    required this.paidAt,
    required this.walletProcessedAt,
  });

  final String outTradeNo;
  final String transactionId;
  final String status;
  final String wechatTradeState;
  final String wechatTradeDesc;
  final bool walletProcessed;
  final bool paymentSuccess;
  final String paymentSuccessDesc;
  final DateTime? paidAt;
  final DateTime? walletProcessedAt;

  factory RechargePaymentStatus.fromJson(Map<String, dynamic> json) {
    return RechargePaymentStatus(
      outTradeNo: (json['outTradeNo'] ?? '').toString(),
      transactionId: (json['transactionId'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      wechatTradeState: (json['wechatTradeState'] ?? '').toString(),
      wechatTradeDesc: (json['wechatTradeDesc'] ?? '').toString(),
      walletProcessed: json['walletProcessed'] == true,
      paymentSuccess: json['paymentSuccess'] == true,
      paymentSuccessDesc: (json['paymentSuccessDesc'] ?? '').toString(),
      paidAt: _parseDateTime(json['paidAt']),
      walletProcessedAt: _parseDateTime(json['walletProcessedAt']),
    );
  }

  bool get isPending {
    if (paymentSuccess) return false;
    return status == 'pending' ||
        wechatTradeState.isEmpty ||
        wechatTradeState == 'NOTPAY' ||
        wechatTradeState == 'USERPAYING';
  }
}

int? rechargeYuanToFen(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final normalized = trimmed.replaceAll('￥', '').replaceAll('¥', '');
  final amount = double.tryParse(normalized);
  if (amount == null || amount < 1) return null;
  return (amount * 100).round();
}

String rechargeFenToYuanText(int fen) => (fen / 100).toStringAsFixed(2);

DateTime? _parseDateTime(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}
