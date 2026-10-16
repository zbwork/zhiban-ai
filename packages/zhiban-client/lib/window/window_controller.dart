import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const double _macOsInitialVerticalFreeSpaceFactor = 1 / 3;

/// Calculates the default top-left position inside a screen's visible area.
///
/// macOS uses an upper-biased vertical position so the window keeps more room
/// above the Dock. Other desktop platforms retain geometric centering.
Offset calculateInitialWindowPosition({
  required Offset visiblePosition,
  required Size visibleSize,
  required Size windowSize,
  required bool biasVerticallyUp,
}) {
  final remainingWidth =
      (visibleSize.width - windowSize.width).clamp(0.0, double.infinity);
  final remainingHeight =
      (visibleSize.height - windowSize.height).clamp(0.0, double.infinity);
  final verticalFactor =
      biasVerticallyUp ? _macOsInitialVerticalFreeSpaceFactor : 0.5;

  return Offset(
    visiblePosition.dx + remainingWidth / 2,
    visiblePosition.dy + remainingHeight * verticalFactor,
  );
}

class WindowController {
  WindowController._();

  static final WindowController instance = WindowController._();

  static const Size _loginSize = Size(480, 720);
  static const Size _loginMinSize = Size(480, 720);
  static const Size _homeInitialSize = Size(1080, 820);
  static const Size _homeMinSize = Size(900, 620);
  static const double _screenMargin = 32;

  bool _initialized = false;
  bool _showingHome = false;

  /// 当前已为「右侧外接面板」额外撑开了多少像素。同步 setOverlayWidth 时,
  /// 用 (新 width - _appliedOverlay) 算 delta 应用到窗口,这样多次开/关
  /// 不会反复累积或抖动。
  double _appliedOverlay = 0;
  final Map<String, double> _overlayWidths = {};
  Future<void> _overlayUpdate = Future.value();

  Future<void> init({required bool hasToken}) async {
    if (!PlatformUtils.isDesktop || _initialized) {
      return;
    }

    await windowManager.ensureInitialized();

    final options = WindowOptions(
      center: true,
      skipTaskbar: false,
      titleBarStyle: PlatformUtils.isWindows ? null : TitleBarStyle.hidden,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      if (hasToken) {
        await showHomeWindow();
      } else {
        await showLoginWindow();
      }
      await windowManager.show();
      await windowManager.focus();
    });

    _initialized = true;
  }

  Future<void> showLoginWindow() async {
    if (!PlatformUtils.isDesktop || (!_showingHome && _initialized)) {
      return;
    }
    await windowManager.setResizable(false);
    await windowManager.setMinimumSize(_loginMinSize);
    await windowManager.setSize(_loginSize);
    await _moveToPrimaryScreen(_loginSize);
    _showingHome = false;
  }

  Future<void> showHomeWindow({bool forceResize = false}) async {
    if (!PlatformUtils.isDesktop ||
        (_showingHome && _initialized && !forceResize)) {
      return;
    }
    final windowSize = await _fitSizeToPrimaryScreen(_homeInitialSize);
    final minSize = await _fitSizeToPrimaryScreen(_homeMinSize);
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(minSize);
    await windowManager.setSize(windowSize);
    await _moveToPrimaryScreen(windowSize);
    _showingHome = true;
  }

  Future<Size> _fitSizeToPrimaryScreen(Size size) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visibleSize = display.visibleSize ?? display.size;
      final maxWidth =
          (visibleSize.width - _screenMargin * 2).clamp(1.0, double.infinity);
      final maxHeight =
          (visibleSize.height - _screenMargin * 2).clamp(1.0, double.infinity);
      return Size(
        size.width.clamp(1.0, maxWidth),
        size.height.clamp(1.0, maxHeight),
      );
    } catch (_) {
      return size;
    }
  }

  /// 同步「右侧外接面板」需要的额外宽度到窗口尺寸,使主对话区不被挤压。
  ///
  /// width=0 表示面板关闭/收起,window 退回之前的宽度;
  /// width>0 表示面板打开,window 朝右扩 (width - 已应用 delta) 像素,
  /// 受屏幕可视宽度上限约束。窗口已被用户拖到顶住屏幕边时,会被 clamp 截断,
  /// 此时面板本身仍然渲染——chat_page 的 LayoutBuilder 会把它压窄到合适宽度。
  ///
  /// 仅在桌面 + 主窗口(home)生效;login 窗口不变。
  Future<void> setOverlayWidth(double width, {String owner = 'history'}) {
    _overlayWidths[owner] = width;
    _overlayUpdate = _overlayUpdate.catchError((_) {}).then((_) =>
        _applyOverlayWidth(_overlayWidths.values.fold(0.0, (a, b) => a + b)));
    return _overlayUpdate;
  }

  Future<void> _applyOverlayWidth(double width) async {
    if (!PlatformUtils.isDesktop || !_showingHome) return;
    if ((width - _appliedOverlay).abs() < 0.5) return;
    Size current;
    Offset currentPos;
    try {
      current = await windowManager.getSize();
      currentPos = await windowManager.getPosition();
    } catch (_) {
      return;
    }
    final delta = width - _appliedOverlay;

    // 拿当前光标所在屏幕(多显示器场景下,主屏不一定是窗口所在屏)
    // 的可视区域,作为右扩 / 左移的边界。
    double screenLeft = 0;
    double screenTop = 0;
    double screenW = double.infinity;
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final pos = display.visiblePosition ?? Offset.zero;
      final vs = display.visibleSize ?? display.size;
      screenLeft = pos.dx;
      screenTop = pos.dy;
      screenW = vs.width;
    } catch (_) {/* 拿不到屏幕信息就保持无上限,仅靠 _homeMinSize 兜底 */}
    final screenRight = screenLeft + screenW;

    // 1) 先看新窗口宽度能拿多少。Cap 在屏幕可视宽 + 不低于 _homeMinSize。
    final targetW =
        (current.width + delta).clamp(_homeMinSize.width, screenW).toDouble();
    final actualDelta = targetW - current.width;
    if (actualDelta.abs() < 0.5) return;

    // 2) 算新的左上角 x。优先保持当前 x(用户摆在哪就在哪);
    //    如果右扩后会越过 screenRight,把窗口整体往左挪,直到右边贴 screenRight;
    //    不够挪就再 clamp 到 screenLeft —— 这种情况说明窗口已经占满整屏宽,
    //    上一步 targetW 也已经卡到 screenW。
    double newX = currentPos.dx;
    final newRight = newX + targetW;
    if (newRight > screenRight) {
      newX = screenRight - targetW;
    }
    if (newX < screenLeft) {
      newX = screenLeft;
    }
    // 关面板回缩时不主动右移窗口——用户可能已经手动调整过 x,
    // 我们只把窗口宽度收回去,左上角原地不动。
    final shouldMove = actualDelta > 0 && (newX - currentPos.dx).abs() > 0.5;

    if (shouldMove) {
      await windowManager.setPosition(Offset(newX, currentPos.dy));
    }
    await windowManager.setSize(Size(targetW, current.height));
    // 屏幕信息能拿到时,可视区上下沿也顺手 clamp 一下,避免极端情况下窗口在 Y 方向超界。
    // 仅当 screenTop 真的有意义(非 0 或非默认)时不强行重设,这里 no-op。
    if (screenTop < 0) {/* keep */}

    _appliedOverlay += actualDelta;
    if (width == 0 && _appliedOverlay.abs() < 1) {
      _appliedOverlay = 0;
    }
  }

  Future<void> _moveToPrimaryScreen(Size windowSize) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visiblePosition = display.visiblePosition ?? Offset.zero;
      final visibleSize = display.visibleSize ?? display.size;
      final position = calculateInitialWindowPosition(
        visiblePosition: visiblePosition,
        visibleSize: visibleSize,
        windowSize: windowSize,
        biasVerticallyUp: PlatformUtils.isMacOS,
      );
      await windowManager.setPosition(position);
    } catch (_) {
      // fallback: if screen info unavailable, keep existing center behavior
      await windowManager.center();
    }
  }
}
