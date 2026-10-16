/// 基础响应Model
class ResDataModel {
  int? code;
  bool? success;
  String? message;
  dynamic data;
  String? traceId;
  ResDataModel({
    this.code,
    this.success,
    this.message,
    this.data,
    this.traceId,
  });
  factory ResDataModel.fromJson(Map<String, dynamic> json) {
    return ResDataModel(
      success: json['success'],
      code: json['code'],
      message: json['message'],
      data: json['data'],
      traceId: json['traceId'],
    );
  }
}
