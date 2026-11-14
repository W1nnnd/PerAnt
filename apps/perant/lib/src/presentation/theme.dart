// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

abstract final class PerantColors {
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF111111);
  static const muted = Color(0xFF686870);
  static const accent = Color(0xFF111111);
  static const soft = Color(0xFFF2F2F7);
  static const line = Color(0xFFE5E5EA);
}

ThemeData perantTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: PerantColors.accent,
          surface: PerantColors.paper,
        ).copyWith(
          primary: PerantColors.ink,
          onPrimary: Colors.white,
          secondary: PerantColors.ink,
          onSecondary: Colors.white,
          primaryContainer: PerantColors.ink,
          onPrimaryContainer: Colors.white,
        ),
  );
  return base.copyWith(
    splashFactory: InkRipple.splashFactory,
    scaffoldBackgroundColor: PerantColors.paper,
    textTheme: base.textTheme.copyWith(
      headlineLarge: const TextStyle(
        fontSize: 34,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
        letterSpacing: -1,
      ),
      headlineSmall: const TextStyle(
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
        letterSpacing: -.7,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
      ),
      titleMedium: const TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        height: 1.6,
        color: PerantColors.ink,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        height: 1.6,
        color: PerantColors.ink,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        height: 1.6,
        color: PerantColors.muted,
      ),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: PerantColors.paper,
      foregroundColor: PerantColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerColor: PerantColors.line,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF2F2F7),
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PerantColors.accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PerantColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PerantColors.ink,
        minimumSize: const Size(44, 48),
        side: const BorderSide(color: PerantColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: PerantColors.paper,
      indicatorColor: Color(0xFFE5E5EA),
      elevation: 0,
      height: 72,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PerantColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
