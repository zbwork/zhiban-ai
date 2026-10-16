import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:nexwork/config/login_layout_config.dart';
import 'package:zhiban_client/pages/login/models/select_option.dart';

class LoginSelect<T> extends StatefulWidget {
  final List<SelectOption<T>> options;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final IconData? prefixIcon;
  final String? placeholder;
  final String? errorText;
  final String Function(T)? displayBuilder;
  final bool enabled;

  const LoginSelect({
    required this.options,
    this.prefixIcon,
    this.placeholder,
    this.value,
    this.onChanged,
    this.errorText,
    this.displayBuilder,
    this.enabled = true,
    super.key,
  });

  @override
  State<LoginSelect<T>> createState() => _LoginSelectState<T>();
}

class _LoginSelectState<T> extends State<LoginSelect<T>>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _overlayEntry;
  bool _isExpanded = false;
  final FocusNode _focusNode = FocusNode();
  late final TextEditingController _textController;
  late AnimationController _animationController;
  late Animation<double> _expandAnimation;
  late Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _displayText);
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    _rotateAnimation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.dispose();
    _textController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LoginSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextText = _displayText;
    if (_textController.text != nextText) {
      _textController.text = nextText;
    }
  }

  void _toggleDropdown() {
    if (!widget.enabled) return;
    if (_isExpanded) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _handleTap() {
    if (!widget.enabled) return;
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    _toggleDropdown();
  }

  void _showOverlay() {
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _removeOverlay,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: offset.dx,
            top: offset.dy + size.height + 4,
            width: size.width,
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: _expandAnimation,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(maxHeight: 240),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.options.length,
                      itemBuilder: (context, index) {
                        final option = widget.options[index];
                        final isSelected = option.value == widget.value;

                        return _SelectOptionItem<T>(
                          option: option,
                          isSelected: isSelected,
                          onTap: () {
                            widget.onChanged?.call(option.value);
                            _removeOverlay();
                          },
                          displayBuilder: widget.displayBuilder,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _isExpanded = true);
    _animationController.forward();
  }

  void _removeOverlay() {
    _animationController.reverse().then((_) {
      _overlayEntry?.remove();
      _overlayEntry = null;
      if (mounted) {
        setState(() => _isExpanded = false);
      }
    });
  }

  String get _displayText {
    if (widget.value == null) return widget.placeholder ?? '';
    if (widget.displayBuilder != null) {
      return widget.displayBuilder!(widget.value as T);
    }
    final selectedOption = widget.options.firstWhere(
      (opt) => opt.value == widget.value,
      orElse: () => SelectOption<T>(
        value: widget.value as T,
        label: widget.placeholder ?? '',
      ),
    );
    return selectedOption.label;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = widget.value != null;

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (!hasFocus && _isExpanded) {
          _removeOverlay();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SizedBox(
          height: loginControlHeight,
          child: AbsorbPointer(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              enabled: widget.enabled,
              readOnly: true,
              showCursor: false,
              enableInteractiveSelection: false,
              decoration: InputDecoration(
                prefixIcon: widget.prefixIcon != null
                    ? Icon(widget.prefixIcon, size: 18)
                    : null,
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 40, minHeight: 0),
                suffixIcon: RotationTransition(
                  turns: _rotateAnimation,
                  child: const Icon(CupertinoIcons.chevron_down, size: 18),
                ),
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 0),
                hintText: widget.placeholder,
                errorText: widget.errorText,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                color: hasValue ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectOptionItem<T> extends StatefulWidget {
  final SelectOption<T> option;
  final bool isSelected;
  final VoidCallback onTap;
  final String Function(T)? displayBuilder;

  const _SelectOptionItem({
    required this.option,
    required this.isSelected,
    required this.onTap,
    this.displayBuilder,
  });

  @override
  State<_SelectOptionItem<T>> createState() => _SelectOptionItemState<T>();
}

class _SelectOptionItemState<T> extends State<_SelectOptionItem<T>> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayText = widget.displayBuilder != null
        ? widget.displayBuilder!(widget.option.value)
        : widget.option.label;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? scheme.primary.withValues(alpha: 0.08)
                : _isHovered
                    ? scheme.primary.withValues(alpha: 0.04)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (widget.option.icon != null) ...[
                Icon(
                  widget.option.icon,
                  size: 20,
                  color: widget.isSelected
                      ? scheme.primary
                      : _isHovered
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    color: widget.isSelected
                        ? scheme.primary
                        : scheme.onSurface,
                    fontSize: 14,
                    fontWeight:
                        widget.isSelected ? FontWeight.w500 : FontWeight.w400,
                  ),
                  child: Text(
                    displayText,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              AnimatedScale(
                duration: const Duration(milliseconds: 150),
                scale: widget.isSelected ? 1.0 : 0.0,
                child: Icon(
                  CupertinoIcons.checkmark_alt,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
