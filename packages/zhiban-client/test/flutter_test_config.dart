import 'dart:async';

import 'package:zhiban_client/config/client_assets.dart';

import 'package:zhiban_client/rtc/dingrtc_video_view.dart';
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ClientAssets.packageName = null;
  DingRtcVideoView.debugForcePlaceholder = true;
  await testMain();
}
