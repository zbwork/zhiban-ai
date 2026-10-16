import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enterToSendPrefsKey = 'chat_enter_to_send';

/// 「回车键发送消息」开关（设置页 · 聊天设置）。参考微信：默认关闭 → 有内容
/// 显示发送按钮、回车换行；开 → 键盘回车直接发送（历史行为）。纯本机偏好
/// （SharedPreferences），不跨设备同步。
class EnterToSendNotifier extends Notifier<bool> {
  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_enterToSendPrefsKey) ?? false;
  }

  Future<void> toggle() => set(!state);

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enterToSendPrefsKey, value);
  }
}

final enterToSendProvider = NotifierProvider<EnterToSendNotifier, bool>(
  EnterToSendNotifier.new,
);
