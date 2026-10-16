import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'ui_control_text.dart';

/// Resolve alongside MaterialApp's theme and text scaling, including hot reload.
void configureUiTextToast(BuildContext context) {
  final options = BotToast.defaultOption.text;
  final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: 17,
        color: Colors.white,
      );
  options
    ..align = Alignment.center
    ..animationDuration = Duration.zero
    ..animationReverseDuration = Duration.zero
    ..backgroundColor = Colors.transparent
    ..contentColor = const Color(0xE61D2129)
    ..textStyle = UiControlText.labelStyle(style)!
    ..contentPadding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6);
}
