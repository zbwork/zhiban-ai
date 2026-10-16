import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_field_style.dart';
import 'ui_control_text.dart';

class UiInputField extends StatefulWidget {
  const UiInputField({
    super.key,
    this.label,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.showCounter = false,
    this.enabled = true,
    this.readOnly = false,
    this.obscureText = false,
    this.borderRadius,
    this.contentPadding,
    this.height,
    this.isDense = true,
    this.prefixIcon,
    this.prefixIconConstraints,
    this.prefixText,
    this.prefixStyle,
    this.suffixIcon,
    this.clearable = false,
    this.clearIconSize = 15,
    this.inputFormatters,
    this.textStyle,
    this.errorText,
    this.validator,
    this.filled = true,
    this.fillColor,
    this.showBorder = true,
    this.autofillHints,
  }) : assert(controller == null || initialValue == null);

  final String? label;
  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final int? maxLength;
  final bool showCounter;
  final bool enabled;
  final bool readOnly;
  final bool obscureText;
  final double? borderRadius;
  final EdgeInsetsGeometry? contentPadding;
  final double? height;
  final bool isDense;
  final Widget? prefixIcon;

  /// 不传时沿用默认的 `BoxConstraints(minWidth: 36, minHeight: 0)`；某些场景
  /// （比如更窄/更宽的前缀图标位）需要自定义时可以覆盖。
  final BoxConstraints? prefixIconConstraints;
  final String? prefixText;
  final TextStyle? prefixStyle;
  final Widget? suffixIcon;
  final bool clearable;
  final double clearIconSize;
  final List<TextInputFormatter>? inputFormatters;
  final TextStyle? textStyle;
  final String? errorText;

  /// Registers with the nearest Form only when validation is requested.
  final FormFieldValidator<String>? validator;
  final bool filled;
  final Color? fillColor;
  final bool showBorder;
  final Iterable<String>? autofillHints;

  @override
  State<UiInputField> createState() => _UiInputFieldState();
}

class _UiInputFieldState extends State<UiInputField> {
  bool _hovered = false;
  bool _focused = false;
  final _ownedFocusNode = FocusNode();
  // InputDecorator inserts a Semantics wrapper when prefix text becomes
  // visible. Preserve the editor and its input connection across reparenting.
  final _inputKey = GlobalKey();
  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode;
  bool _showClearButton = false;
  TextEditingController? _ownedController;
  final _formFieldKey = GlobalKey<FormFieldState<String>>();

  TextEditingController get _controller =>
      widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = TextEditingController(text: widget.initialValue);
    }
    _showClearButton = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant UiInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    final oldController = oldWidget.controller ?? _ownedController!;
    oldController.removeListener(_onTextChanged);
    if (widget.controller != null) {
      _ownedController?.dispose();
      _ownedController = null;
    } else {
      _ownedController ??= TextEditingController(text: widget.initialValue);
    }
    _showClearButton = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final field = _formFieldKey.currentState;
    if (field != null && field.value != _controller.text) {
      field.didChange(_controller.text);
    }
    final show = _controller.text.isNotEmpty;
    if (show == _showClearButton || !mounted) return;
    setState(() => _showClearButton = show);
  }

  @override
  void dispose() {
    _ownedFocusNode.dispose();
    _controller.removeListener(_onTextChanged);
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.validator == null) {
      return _buildInput(context, widget.errorText);
    }
    return FormField<String>(
      key: _formFieldKey,
      initialValue: _controller.text,
      enabled: widget.enabled,
      validator: (_) => widget.validator!(_controller.text),
      builder: (field) =>
          _buildInput(context, field.errorText ?? widget.errorText),
    );
  }

  Widget _buildInput(BuildContext context, String? errorText) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showLabel = widget.label != null && widget.label!.isNotEmpty;
    final isFixedSingleLine = widget.minLines == 1 && widget.maxLines == 1;
    final usesSingleLineBaseline = widget.minLines == 1;
    final normalizedHint = switch (widget.hintText) {
      final hint? when hint.trim().isNotEmpty => hint,
      _ => null,
    };
    final baseTextStyle =
        widget.textStyle ??
        theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
          fontSize: usesSingleLineBaseline ? 15 : null,
          height: 1.6,
          leadingDistribution: usesSingleLineBaseline
              ? TextLeadingDistribution.even
              : null,
          textBaseline: TextBaseline.alphabetic,
        );
    final resolvedTextStyle = isFixedSingleLine
        ? UiControlText.inputStyle(baseTextStyle)
        : baseTextStyle;
    final singleLineVerticalPadding = widget.height != null
        ? UiFieldStyle.verticalPaddingForHeight(widget.height!)
        : UiFieldStyle.verticalPaddingForHeight(UiFieldStyle.defaultHeight);
    final radius = BorderRadius.circular(
      widget.borderRadius ?? UiFieldStyle.defaultBorderRadius,
    );

    final borderSide = !widget.showBorder
        ? BorderSide.none
        : BorderSide(
            color: _hovered
                ? UiFieldStyle.hoverBorderColor(scheme)
                : UiFieldStyle.enabledBorderColor(scheme),
          );
    final fillColor =
        widget.fillColor ??
        (_hovered ? UiFieldStyle.hoverFillColor(scheme) : null);
    final hasError = errorText != null && errorText.isNotEmpty;
    final effectiveBorderSide = !widget.showBorder
        ? BorderSide.none
        : hasError
        ? BorderSide(color: scheme.error)
        : borderSide;
    final effectiveFormatters = <TextInputFormatter>[
      ...?widget.inputFormatters,
      if (isFixedSingleLine)
        FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
    ];
    final suffixIcon =
        widget.suffixIcon ??
        (widget.clearable && _showClearButton && widget.enabled
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _controller.clear();
                  widget.onChanged?.call('');
                },
                child: Icon(
                  CupertinoIcons.clear_circled_solid,
                  size: widget.clearIconSize,
                ),
              )
            : null);

    final decoration = InputDecoration(
      enabled: widget.enabled,
      visualDensity: isFixedSingleLine ? VisualDensity.standard : null,
      hintText: isFixedSingleLine ? null : normalizedHint,
      hintStyle: resolvedTextStyle?.copyWith(
        color:
            theme.inputDecorationTheme.hintStyle?.color ??
            scheme.onSurfaceVariant.withValues(alpha: 0.45),
      ),
      errorText: isFixedSingleLine ? null : errorText,
      errorMaxLines: 3,
      filled: widget.filled,
      fillColor: fillColor,
      prefixText: widget.prefixText,
      prefixStyle: widget.prefixStyle,
      prefixIcon: widget.prefixIcon == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 8),
              child: widget.prefixIcon,
            ),
      prefixIconConstraints: widget.prefixIcon == null
          ? null
          : widget.prefixIconConstraints ??
                const BoxConstraints(minWidth: 36, minHeight: 0),
      suffixIcon: suffixIcon == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 6),
              child: suffixIcon,
            ),
      suffixIconConstraints: suffixIcon == null
          ? null
          : const BoxConstraints(minWidth: 36, minHeight: 0),
      contentPadding: isFixedSingleLine
          ? (widget.contentPadding?.resolve(Directionality.of(context)) ??
                    const EdgeInsets.symmetric(horizontal: 10))
                .copyWith(top: 0, bottom: 0)
          : widget.contentPadding ??
                (usesSingleLineBaseline
                    ? EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: singleLineVerticalPadding,
                      )
                    : null),
      isDense: usesSingleLineBaseline || widget.isDense,
      counterText: '',
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: effectiveBorderSide,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: effectiveBorderSide,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: !widget.showBorder
            ? BorderSide.none
            : BorderSide(
                color: hasError
                    ? scheme.error
                    : UiFieldStyle.focusBorderColor(scheme),
              ),
      ),
    );
    final input = TextField(
      key: _inputKey,
      cursorHeight: resolvedTextStyle?.fontSize == null
          ? null
          : resolvedTextStyle!.fontSize! * 1.2,
      controller: _controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onTapOutside: (_) => FocusScope.of(context).unfocus(),
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      autocorrect: !widget.obscureText,
      enableSuggestions: !widget.obscureText,
      keyboardType: widget.keyboardType,
      autofillHints: widget.autofillHints,
      inputFormatters: effectiveFormatters,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      textInputAction: isFixedSingleLine ? TextInputAction.done : null,
      maxLength: widget.maxLength,
      textAlignVertical: usesSingleLineBaseline
          ? TextAlignVertical.center
          : null,
      style: resolvedTextStyle,
      decoration: isFixedSingleLine
          ? InputDecoration(
              hintText: normalizedHint,
              hintStyle: decoration.hintStyle,
              isCollapsed: true,
              isDense: true,
              visualDensity: VisualDensity.standard,
              contentPadding: EdgeInsets.zero,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              counterText: '',
            )
          : decoration,
    );
    Widget field = isFixedSingleLine
        ? SizedBox(
            height: widget.height ?? UiFieldStyle.defaultHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? _focusNode.requestFocus : null,
              child: InputDecorator(
                decoration: decoration,
                baseStyle: resolvedTextStyle,
                isFocused: _focused,
                isHovering: _hovered,
                isEmpty: _controller.text.isEmpty,
                expands: true,
                child: Center(child: input),
              ),
            ),
          )
        : input;
    field = Focus(
      canRequestFocus: false,
      onFocusChange: (focused) {
        if (mounted && _focused != focused) {
          setState(() => _focused = focused);
        }
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: field,
      ),
    );
    if (isFixedSingleLine) {
      // Prefix/suffix actions belong to the same input, even though its
      // editable region and decoration now have separate layout ownership.
      field = TextFieldTapRegion(child: field);
    }

    if (isFixedSingleLine && hasError) {
      field = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          field,
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
              errorText,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        ],
      );
    }

    if (widget.showCounter && widget.maxLength != null) {
      field = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  return Text(
                    '${value.text.characters.length}/${widget.maxLength}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    }

    if (!showLabel) return field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UiFieldStyle.labelText(
          widget.label!,
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
          scheme,
        ),
        const SizedBox(height: 6),
        field,
      ],
    );
  }
}
