import 'dart:async';
import 'package:zhiban_client/rtc/dingrtc_video_view.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  DingRtcVideoView.debugForcePlaceholder = true;
  await testMain();
}
