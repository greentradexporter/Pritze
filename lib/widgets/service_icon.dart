import 'package:flutter/material.dart';

import '../models/service_catalog.dart';
import '../theme/app_theme.dart';

class ServiceImageIcon extends StatelessWidget {
  final String category;
  final double size;
  final Color? color;

  const ServiceImageIcon({
    super.key,
    required this.category,
    this.size = 48,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? serviceColorForCategory(category);
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withAlpha(34)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D0F172A),
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.asset(
          serviceIconAssetForCategory(category),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return ColoredBox(
              color: AppColors.champagne,
              child: Icon(
                serviceFallbackIconForCategory(category),
                color: accent,
                size: size * 0.46,
              ),
            );
          },
        ),
      ),
    );
  }
}
