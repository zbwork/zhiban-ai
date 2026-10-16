import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class PlatformUtils {
  static const double tabletBreakpoint = 720;

  static bool get isMacOS {
    if (kIsWeb) return false;
    return Platform.isMacOS;
  }

  static bool get isWindows {
    if (kIsWeb) return false;
    return Platform.isWindows;
  }

  static bool get isLinux {
    if (kIsWeb) return false;
    return Platform.isLinux;
  }

  static bool get isIOS {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }

  static bool get isAndroid {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  static bool get isDesktop {
    if (kIsWeb) return false;
    return isMacOS || isWindows || isLinux;
  }

  static bool get isMobile {
    if (kIsWeb) return false;
    return isAndroid || isIOS;
  }

  static bool isTabletWidth(double width) {
    if (!isMobile) return false;
    return width >= tabletBreakpoint;
  }

  static bool isTabletLayout(BuildContext context) {
    return isTabletWidth(MediaQuery.sizeOf(context).width);
  }

  static String get deviceLabel {
    if (isMacOS) return 'MacBook';
    if (isWindows) return 'Windows PC';
    if (isLinux) return 'Linux';
    if (isIOS) return 'iPhone';
    if (isAndroid) return 'Android';
    return 'Unknown';
  }
}
