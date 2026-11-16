// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

abstract final class PerantColors {
  static const paper = Color(0xFFF8F8F3);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF252A24);
  static const muted = Color(0xFF686F60);
  static const accent = Color(0xFF455C3E);
  static const accentDark = Color(0xFF31452C);
  static const soft = Color(0xFFEDF1E5);
  static const tintStrong = Color(0xFFE1E9D5);
  static const greenSoft = Color(0xFFE7EDDF);
  static const line = Color(0xFFE7EAE0);
  static const warning = Color(0xFF8A5A2B);
  static const peach = Color(0xFFF3E9DB);
  static const success = Color(0xFF72965D);
}

ThemeData perantTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: PerantColors.accent,
          surface: PerantColors.paper,
        ).copyWith(
          primary: PerantColors.accent,
          onPrimary: Colors.white,
          secondary: PerantColors.accent,
          onSecondary: Colors.white,
          primaryContainer: PerantColors.greenSoft,
          onPrimaryContainer: PerantColors.accentDark,
        ),
  );
  return base.copyWith(
    splashFactory: InkRipple.splashFactory,
    scaffoldBackgroundColor: PerantColors.paper,
    textTheme: base.textTheme.copyWith(
      headlineLarge: const TextStyle(
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
        letterSpacing: -.5,
      ),
      headlineSmall: const TextStyle(
        fontSize: 24,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
        letterSpacing: -.5,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
      ),
      titleMedium: const TextStyle(
        fontSize: 15,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: PerantColors.ink,
      ),
      bodyLarge: const TextStyle(
        fontSize: 15,
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
      fillColor: PerantColors.surface,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PerantColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PerantColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PerantColors.accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PerantColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PerantColors.ink,
        minimumSize: const Size(44, 48),
        side: const BorderSide(color: PerantColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: PerantColors.paper,
      indicatorColor: PerantColors.tintStrong,
      elevation: 0,
      height: 72,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: PerantColors.paper,
      modalBackgroundColor: PerantColors.paper,
      showDragHandle: true,
      dragHandleColor: Color(0xFFCED5C5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PerantColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
