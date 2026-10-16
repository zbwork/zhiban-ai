import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 登陆页顶部渐变色
class LoginTopBarBackground extends StatelessWidget {
  const LoginTopBarBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: Stack(
        children: [
          Container(
            height: 210.0,
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFFC3D8FB),
                  Color(0x00FFFFFF),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.3, 1],
              ),
            ),
          ),
          Container(
            height: double.infinity,
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Color(0xFFF3E5EA),
                  Color(0x00FFFFFF),
                ],
                center: Alignment(1, -1),
                radius: 0.6,
                focal: Alignment(1.0, -1.0),
                focalRadius: 0.33,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
