import 'package:zhiban_client/config/client_assets.dart';
// F16 · 通话提示音播放器（拨号回铃 / 来电铃声）。
//
// 抽象接口便于测试注入；生产实现用 audioplayers 循环播放**自生成的中性提示音**
// （assets/sounds/rtc_ringback.wav、rtc_incoming.wav，正弦/双音，非任何商业铃声）。
// 由 RtcCallController 在状态机里驱动 play/stop，保证 connecting/active/idle 不残留声音。

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 通话提示音播放器抽象。
abstract class RtcCallTonePlayer {
  /// 主叫呼叫中：循环播放拨号回铃。
  Future<void> playOutgoingRingback();

  /// 被叫来电中：循环播放来电铃声。
  Future<void> playIncomingRingtone();

  /// 停止当前提示音（幂等）。
  Future<void> stop();

  /// 释放底层资源。
  Future<void> dispose();
}

/// 生产实现：audioplayers 低音量循环播放自生成提示音。
///
/// 构造不触碰平台（AudioPlayer 延迟到首次 play 才创建），故在任意环境构造都安全；
/// 真实播放仅在生产 macOS 端发生。所有调用 best-effort，失败只 log 不抛。
class AudioPlayersTonePlayer implements RtcCallTonePlayer {
  AudioPlayersTonePlayer();

  AudioPlayer? _player;

  // AssetSource 路径相对 `assets/`（audioplayers 默认前缀），实文件在 assets/sounds/ 下。
  static const String _ringback = 'sounds/rtc_ringback.wav';
  static const String _incoming = 'sounds/rtc_incoming.wav';
  static const double _volume = 0.5; // 低音量，避免突兀

  Future<void> _loop(String asset) async {
    try {
      final p = _player ??= AudioPlayer();
      p.audioCache.prefix = ClientAssets.path('assets/');
      await p.stop();
      await p.setReleaseMode(ReleaseMode.loop);
      await p.play(AssetSource(asset), volume: _volume);
    } catch (e) {
      debugPrint('[F16 RTC] tone play failed (ignored): $e');
    }
  }

  @override
  Future<void> playOutgoingRingback() => _loop(_ringback);

  @override
  Future<void> playIncomingRingtone() => _loop(_incoming);

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[F16 RTC] tone stop failed (ignored): $e');
    }
  }

  @override
  Future<void> dispose() async {
    final p = _player;
    _player = null;
    try {
      await p?.release();
      await p?.dispose();
    } catch (e) {
      debugPrint('[F16 RTC] tone dispose failed (ignored): $e');
    }
  }
}

/// 无声实现：不便播放音频时的安全降级（不报错、不播放）。
class SilentTonePlayer implements RtcCallTonePlayer {
  const SilentTonePlayer();
  @override
  Future<void> playOutgoingRingback() async {}
  @override
  Future<void> playIncomingRingtone() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
