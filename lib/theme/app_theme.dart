import 'package:flutter/material.dart';

class AppColors {
  static const Color ink = Color(0xFF11100E);
  static const Color muted = Color(0xFF766D61);
  static const Color line = Color(0xFFE9E0D2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color canvas = Color(0xFFFFFCF7);
  static const Color primary = Color(0xFFB47A13);
  static const Color primaryDark = Color(0xFF11100E);
  static const Color charcoal = Color(0xFF181612);
  static const Color gold = Color(0xFFC9962C);
  static const Color goldDeep = Color(0xFF8B5A07);
  static const Color champagne = Color(0xFFF7E9C9);
  static const Color copper = Color(0xFFC2762F);
  static const Color rose = Color(0xFFB76D5E);
  static const Color leaf = Color(0xFF3F7B52);
  static const Color mint = Color(0xFFF5EFE4);
  static const Color amber = gold;
  static const Color coral = rose;
  static const Color blue = Color(0xFF556C86);
  static const Color plum = Color(0xFF7B5B86);
  static const Color success = leaf;
}

class AppGradients {
  static const LinearGradient hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF10100E), Color(0xFF262018), Color(0xFFC9962C)],
  );

  static const LinearGradient warm = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFF8E8), Color(0xFFF4E4C8)],
  );

  static const LinearGradient coral = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5A07), Color(0xFFC9962C)],
  );
}

class AppTheme {
  static ThemeData build() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      secondary: AppColors.coral,
      surface: AppColors.surface,
      error: AppColors.coral,
    );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.canvas,
      useMaterial3: true,
      fontFamily: 'Inter',
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: AppColors.ink,
          fontSize: 32,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
          height: 1.04,
        ),
        headlineMedium: TextStyle(
          color: AppColors.ink,
          fontSize: 24,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
          height: 1.12,
        ),
        titleLarge: TextStyle(
          color: AppColors.ink,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        titleMedium: TextStyle(
          color: AppColors.ink,
          fontSize: 16,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        bodyLarge: TextStyle(color: AppColors.ink, fontSize: 15, height: 1.42),
        bodyMedium: TextStyle(
          color: AppColors.muted,
          fontSize: 13,
          height: 1.35,
        ),
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.ink,
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.line),
          minimumSize: const Size.fromHeight(46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        elevation: 0,
        indicatorColor: AppColors.primary.withAlpha(18),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? AppColors.primary : AppColors.muted,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.primary : AppColors.muted,
            size: 22,
          );
        }),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.muted,
        indicatorColor: AppColors.primary,
        labelStyle: TextStyle(fontWeight: FontWeight.w800),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}
