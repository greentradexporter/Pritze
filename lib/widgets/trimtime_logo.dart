import 'package:flutter/material.dart';

class TrimtimeLogo extends StatelessWidget {
  final double size;
  final bool shadow;

  const TrimtimeLogo({super.key, this.size = 48, this.shadow = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: shadow
            ? const [
                BoxShadow(
                  color: Color(0x1A111827),
                  blurRadius: 16,
                  offset: Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: EdgeInsets.all(size * 0.06),
            child: Image.asset(
              'assets/brand/pritze_icon_mark_transparent.png',
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
