import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

class LobsterLoadingView extends StatefulWidget {
  const LobsterLoadingView({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  State<LobsterLoadingView> createState() => _LobsterLoadingViewState();
}

class _LobsterLoadingViewState extends State<LobsterLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final pulse = 0.5 + 0.5 * math.sin(t * math.pi * 2);
          final spin = t * math.pi * 2;
          final haloScale = 0.96 + pulse * 0.08;
          final orbScale = 0.98 + pulse * 0.04;
          final isMobile = PlatformUtils.isMobile;
          return Container(
            width: 460,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              border:
                  isMobile ? null : Border.all(color: const Color(0xFFE6ECF5)),
              boxShadow: isMobile
                  ? null
                  : [
                      BoxShadow(
                        color: const Color(0xFF2F6BFF)
                            .withValues(alpha: 0.08 + pulse * 0.05),
                        blurRadius: 26,
                        offset: const Offset(0, 12),
                      ),
                    ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 112,
                  height: 112,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Transform.scale(
                        scale: haloScale,
                        child: Container(
                          width: 112,
                          height: 112,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFFBFD8FF).withValues(alpha: 0.7),
                                const Color(0xFFBFD8FF).withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Transform.rotate(
                        angle: spin,
                        child: SizedBox(
                          width: 86,
                          height: 86,
                          child: Stack(
                            children: List.generate(3, (index) {
                              final angle = (index * 2 * math.pi / 3) + spin;
                              return Positioned(
                                left: 43 + math.cos(angle) * 34 - 4,
                                top: 43 + math.sin(angle) * 34 - 4,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: index == 0
                                        ? const Color(0xFF6A9DFF)
                                        : index == 1
                                            ? const Color(0xFF2457F5)
                                            : const Color(0xFF9BC0FF),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                      Transform.scale(
                        scale: orbScale,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF2F6BFF),
                                Color(0xFF6A96FF)
                              ],
                            ),
                          ),
                          child: const Center(
                            child: Text(
                              '🦞',
                              style: TextStyle(fontSize: 30)
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF162033),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: Color(0xFF667085),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
