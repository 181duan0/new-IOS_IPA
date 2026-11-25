import 'package:flutter/material.dart';

class TacticalColors {
  static const Color bg = Color(0xFF0A0C10);
  static const Color surface = Color(0xFF12161F);
  static const Color surfaceElevated = Color(0xFF1A202C);
  static const Color border = Color(0xFF252D3D);
  static const Color crimson = Color(0xFFE51924);
  static const Color crimsonDark = Color(0xFFB31019);
  static const Color crimsonGlow = Color(0x33E51924);
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);
  static const Color emerald = Color(0xFF22C55E);
  static const Color amber = Color(0xFFF59E0B);
  static const Color cyan = Color(0xFF38BDF8);
}

ThemeData buildTacticalTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: TacticalColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: TacticalColors.crimson,
      secondary: TacticalColors.cyan,
      surface: TacticalColors.surface,
      error: TacticalColors.crimson,
      onPrimary: Colors.white,
      onSurface: TacticalColors.textPrimary,
    ),
    cardTheme: CardThemeData(
      color: TacticalColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: TacticalColors.border, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: TacticalColors.crimson,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF2B1D22),
        disabledForegroundColor: TacticalColors.textMuted,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TacticalColors.textPrimary,
        side: const BorderSide(color: TacticalColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: TacticalColors.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TacticalColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TacticalColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TacticalColors.crimson, width: 1.4),
      ),
      hintStyle: const TextStyle(color: TacticalColors.textMuted, fontSize: 13),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : TacticalColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? TacticalColors.crimson : TacticalColors.surfaceElevated,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: TacticalColors.surfaceElevated,
      contentTextStyle: const TextStyle(color: TacticalColors.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: TacticalColors.border),
      ),
    ),
  );
}
