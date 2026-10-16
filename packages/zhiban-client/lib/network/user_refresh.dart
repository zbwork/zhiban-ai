import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';

/// Only explicit refresh callbacks may opt into transport-error Toasts.
/// Zone-local state isolates concurrent automatic requests and deduplicates fanout.
class UserRefresh {
  static final Object _key = Object();
  bool _shown = false;
  bool _active = true;

  static T run<T>(T Function() action) {
    final current = Zone.current[_key];
    if (current is UserRefresh && current._active) return action();
    final scope = UserRefresh();
    return runZoned(() {
      try {
        final result = action();
        if (result is Future) {
          // Observe completion without creating an unhandled error Future.
          unawaited(result.then<void>((_) {
            scope._active = false;
          }, onError: (Object _, StackTrace __) {
            scope._active = false;
          }));
        } else {
          scope._active = false;
        }
        return result;
      } catch (_) {
        scope._active = false;
        rethrow;
      }
    }, zoneValues: {_key: scope});
  }

  static void showNetworkError(String message) {
    final scope = Zone.current[_key];
    if (scope is! UserRefresh || !scope._active || scope._shown) return;
    scope._shown = true;
    BotToast.showText(text: message, align: Alignment.center);
  }
}
