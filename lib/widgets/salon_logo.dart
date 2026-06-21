import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SalonLogo extends StatelessWidget {
  final String logoUrl;
  final double size;
  final Color color;

  const SalonLogo({
    super.key,
    required this.logoUrl,
    this.size = 50,
    this.color = AppColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    final hasLogo = logoUrl.trim().isNotEmpty;
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: hasLogo ? Colors.white : color.withAlpha(16),
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasLogo
          ? Image.network(
              logoUrl.trim(),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  _FallbackLogo(color: color),
            )
          : _FallbackLogo(color: color),
    );
  }
}

class _FallbackLogo extends StatelessWidget {
  final Color color;

  const _FallbackLogo({required this.color});

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.storefront_outlined, color: color, size: 22);
  }
}
