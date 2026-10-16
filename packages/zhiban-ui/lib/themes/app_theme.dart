import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

class AppTheme {
  AppTheme._();

  static const Color brandColor = Color(0xFF2b7fff);
  static const double toolbarHeight = 48;

  /// Apple 平台不覆盖默认字体；随包鸿蒙仍供显式指定的组件使用。
  static String? get _fontFamily => switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => null,
        _ => 'packages/zhiban_ui/HarmonyOS Sans SC',
      };

  static ThemeData light({Color seedColor = brandColor}) {
    return _buildTheme(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
  }

  static ThemeData dark({Color seedColor = brandColor}) {
    return _buildTheme(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
  }

  /// 显式选用的分栏弹框操作样式；普通 TextButton 的默认主题不变。
  static ButtonStyle dialogActionStyle(
    BuildContext context, {
    required bool primary,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextButton.styleFrom(
      foregroundColor: primary ? scheme.primary : scheme.onSurfaceVariant,
      disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
      minimumSize: const Size(0, 52),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: primary ? FontWeight.w500 : FontWeight.w400,
      ),
      animationDuration: Duration.zero,
    ).copyWith(
      overlayColor: _stateColor(
        normal: Colors.transparent,
        disabled: Colors.transparent,
        pressed: _alpha(scheme.onSurface, 0.05),
        hovered: _alpha(scheme.onSurface, 0.03),
        focused: _alpha(scheme.onSurface, 0.10),
      ),
    );
  }

  static CupertinoThemeData cupertinoTheme({
    Color seedColor = brandColor,
    Brightness brightness = Brightness.light,
  }) {
    final scheme = _buildColorScheme(
      seedColor: seedColor,
      brightness: brightness,
    );

    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: scheme.primary,
      primaryContrastingColor: scheme.onPrimary,
      selectionHandleColor: scheme.primary,
      barBackgroundColor: scheme.surface,
      scaffoldBackgroundColor: scheme.surface,
      applyThemeToAll: true,
      textTheme: _buildCupertinoTextTheme(scheme),
    );
  }

  static Widget cupertinoThemeBuilder(BuildContext context, Widget? child) {
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: theme.brightness,
        primaryColor: theme.colorScheme.primary,
        primaryContrastingColor: theme.colorScheme.onPrimary,
        selectionHandleColor: theme.colorScheme.primary,
        barBackgroundColor: theme.colorScheme.surface,
        scaffoldBackgroundColor: theme.colorScheme.surface,
        applyThemeToAll: true,
        textTheme: _buildCupertinoTextTheme(theme.colorScheme),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }

  static ThemeData _buildTheme({
    required Color seedColor,
    required Brightness brightness,
  }) {
    final scheme = _buildColorScheme(
      seedColor: seedColor,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: _fontFamily,
      visualDensity: VisualDensity.compact,
    );
    final textTheme = base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    final inputDecorationTheme = _buildInputDecorationTheme(scheme);

    return base.copyWith(
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          ...base.pageTransitionsTheme.builders,
          // Repaint the revealed page as the IME closes during a pop. A zoom
          // snapshot would keep its keyboard-shortened body until animation end.
          TargetPlatform.android: const ZoomPageTransitionsBuilder(
            allowEnterRouteSnapshotting: false,
          ),
        },
      ),
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      cardColor: scheme.surface,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: scheme.onSurface),
      primaryIconTheme: IconThemeData(color: scheme.primary),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: _alpha(scheme.primary, 0.08),
      hoverColor: Colors.transparent,
      focusColor: _alpha(scheme.primary, 0.12),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: _alpha(scheme.primary, 0.25),
        selectionHandleColor: scheme.primary,
      ),
      cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
        brightness: brightness,
        primaryColor: scheme.primary,
        primaryContrastingColor: scheme.onPrimary,
        selectionHandleColor: scheme.primary,
        barBackgroundColor: scheme.surface,
        scaffoldBackgroundColor: scheme.surface,
        applyThemeToAll: true,
        textTheme: _buildCupertinoTextTheme(scheme),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // // 在主题层统一追加底部分割线，保证各页面 AppBar 与内容区边界清晰。
        // shape: Border(
        //   bottom: BorderSide(color: Color(0xFFEFF1F5), width: 1),
        // ),
        centerTitle: true,
        toolbarHeight: toolbarHeight,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
        actionsPadding: const EdgeInsets.only(right: 8),
        // centerTitle 场景下标题需要更醒目，显式提高字号避免看起来偏小。
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontSize: 16,
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      inputDecorationTheme: inputDecorationTheme,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: _alpha(scheme.onSurface, 0.12),
          disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: _alpha(scheme.onSurface, 0.12),
          disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ).copyWith(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return BorderSide(color: _alpha(scheme.onSurface, 0.12));
            }
            if (states.contains(WidgetState.pressed) ||
                states.contains(WidgetState.focused) ||
                states.contains(WidgetState.hovered)) {
              return BorderSide(color: scheme.outline, width: 1.2);
            }
            return BorderSide(color: scheme.outline);
          }),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurface,
          disabledForegroundColor: _alpha(scheme.onSurface, 0.38),
          highlightColor: _alpha(scheme.primary, 0.12),
          hoverColor: _alpha(scheme.primary, 0.08),
          focusColor: _alpha(scheme.primary, 0.12),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: _stateColor(
          normal: Colors.transparent,
          selected: scheme.primary,
          disabled: _alpha(scheme.onSurface, 0.12),
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: scheme.outline, width: 1.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: _stateColor(
          normal: scheme.primary,
          selected: scheme.primary,
          disabled: _alpha(scheme.onSurface, 0.38),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return _alpha(scheme.onSurface, 0.38);
          }
          if (states.contains(WidgetState.selected)) {
            return scheme.onPrimary;
          }
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return _alpha(scheme.onSurface, 0.12);
          }
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.surfaceContainerHighest;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return scheme.outline;
        }),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: _alpha(scheme.primary, 0.24),
        thumbColor: scheme.primary,
        overlayColor: _alpha(scheme.primary, 0.12),
        valueIndicatorColor: scheme.primary,
        valueIndicatorTextStyle: TextStyle(color: scheme.onPrimary),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: _alpha(scheme.primary, 0.18),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: _alpha(
          Colors.black,
          brightness == Brightness.dark ? 0.4 : 0.12,
        ),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: _alpha(
          Colors.black,
          brightness == Brightness.dark ? 0.5 : 0.16,
        ),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Colors.black54,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontSize: 10,
            height: 1.2,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: scheme.outlineVariant,
        overlayColor: _stateColor(
          normal: Colors.transparent,
          pressed: _alpha(scheme.primary, 0.10),
          hovered: _alpha(scheme.primary, 0.06),
          focused: _alpha(scheme.primary, 0.10),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(
            _alpha(
              Colors.black,
              brightness == Brightness.dark ? 0.5 : 0.16,
            ),
          ),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        inputDecorationTheme: inputDecorationTheme,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(
          scheme.surfaceContainerHighest,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        ),
        hintStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        selectedColor: scheme.primary,
        tileColor: Colors.transparent,
        selectedTileColor: _alpha(scheme.primary, 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _alpha(scheme.outlineVariant, 0.5),
        thickness: 1,
        space: 1,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: scheme.primary,
        collapsedIconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        collapsedTextColor: scheme.onSurface,
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        disabledColor: _alpha(scheme.onSurface, 0.12),
        checkmarkColor: scheme.primary,
        labelStyle: textTheme.labelLarge?.copyWith(color: scheme.onSurface),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primaryContainer;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.onPrimaryContainer;
            }
            if (states.contains(WidgetState.disabled)) {
              return _alpha(scheme.onSurface, 0.38);
            }
            return scheme.onSurface;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outline),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: scheme.primary,
        headerForegroundColor: scheme.onPrimary,
        inputDecorationTheme: inputDecorationTheme,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: scheme.surface,
        dialBackgroundColor: scheme.surfaceContainerHighest,
        dialHandColor: scheme.primary,
        hourMinuteColor: scheme.primaryContainer,
        hourMinuteTextColor: scheme.onPrimaryContainer,
        dayPeriodColor: scheme.surfaceContainerHighest,
        dayPeriodTextColor: scheme.onSurface,
        entryModeIconColor: scheme.primary,
        inputDecorationTheme: inputDecorationTheme,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          _alpha(scheme.onSurface, 0.30),
        ),
        trackColor: WidgetStatePropertyAll(
          _alpha(scheme.onSurface, 0.06),
        ),
        radius: const Radius.circular(999),
        thickness: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return 8;
          }
          return 6;
        }),
      ),
    );
  }

  static ColorScheme _buildColorScheme({
    required Color seedColor,
    required Brightness brightness,
  }) {
    return ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ).copyWith(
      primary: seedColor,
      onPrimary: Colors.white,
      surface: brightness == Brightness.light ? Colors.white : Colors.black,
      surfaceTint: Colors.transparent,
      outline: seedColor,
    );
  }

  static InputDecorationThemeData _buildInputDecorationTheme(
    ColorScheme scheme,
  ) {
    final radius = BorderRadius.circular(10);
    final enabledBorderSide =
        BorderSide(color: _alpha(scheme.outlineVariant, 0.5));
    return InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surface,
      focusColor: _alpha(scheme.primary, 0.12),
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: _alpha(scheme.onSurfaceVariant, 0.45)),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w500,
      ),
      errorStyle: TextStyle(color: scheme.error),
      iconColor: scheme.onSurfaceVariant,
      prefixIconColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return scheme.primary;
        return scheme.onSurfaceVariant;
      }),
      suffixIconColor: scheme.onSurfaceVariant,
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: enabledBorderSide,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: PlatformUtils.isMobile
            ? enabledBorderSide
            : BorderSide(color: _alpha(scheme.primary, 0.45), width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: _alpha(scheme.outlineVariant, 0.4)),
      ),
    );
  }

  static CupertinoTextThemeData _buildCupertinoTextTheme(ColorScheme scheme) {
    final baseTextStyle = TextStyle(
      color: scheme.onSurface,
      fontFamily: _fontFamily,
      fontSize: 17,
      height: 1.25,
    );

    return CupertinoTextThemeData(
      primaryColor: scheme.primary,
      textStyle: baseTextStyle,
      actionTextStyle: TextStyle(
        color: scheme.primary,
        fontFamily: _fontFamily,
        fontSize: 17,
        height: 1.25,
      ),
      actionSmallTextStyle: TextStyle(
        color: scheme.primary,
        fontFamily: _fontFamily,
        fontSize: 15,
        height: 1.25,
      ),
      tabLabelTextStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontFamily: _fontFamily,
        fontSize: 10,
        height: 1.2,
      ),
      navTitleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: _fontFamily,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      navLargeTitleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: _fontFamily,
        fontSize: 34,
        fontWeight: FontWeight.bold,
        height: 1.15,
      ),
      navActionTextStyle: TextStyle(
        color: scheme.primary,
        fontFamily: _fontFamily,
        fontSize: 17,
        height: 1.25,
      ),
      pickerTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: _fontFamily,
        fontSize: 21,
        height: 1.25,
      ),
      dateTimePickerTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: _fontFamily,
        fontSize: 21,
        height: 1.25,
      ),
    );
  }

  static Color _alpha(Color color, double alpha) {
    return color.withValues(alpha: alpha);
  }

  static WidgetStateProperty<Color?> _stateColor({
    required Color normal,
    Color? selected,
    Color? disabled,
    Color? pressed,
    Color? hovered,
    Color? focused,
    Color? dragged,
  }) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return disabled ?? _alpha(normal, 0.38);
      }
      if (states.contains(WidgetState.dragged)) {
        return dragged ?? pressed ?? selected ?? normal;
      }
      if (states.contains(WidgetState.pressed)) {
        return pressed ?? selected ?? normal;
      }
      if (states.contains(WidgetState.hovered)) {
        return hovered ?? normal;
      }
      if (states.contains(WidgetState.focused)) {
        return focused ?? normal;
      }
      if (states.contains(WidgetState.selected)) {
        return selected ?? normal;
      }
      return normal;
    });
  }
}
