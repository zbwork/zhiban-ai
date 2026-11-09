import 'dart:async';
import 'dart:io';

import 'package:zhiban_client/config/client_assets.dart';

import 'package:zhiban_client/rtc/dingrtc_video_view.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ClientAssets.packageName =
      File('assets/model_catalog/providers.json').existsSync()
          ? null
          : 'zhiban_client';
  DingRtcVideoView.debugForcePlaceholder = true;
  await testMain();
}
