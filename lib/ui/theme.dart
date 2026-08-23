import 'package:flutter/material.dart';

/// Nexus design language — calm and powerful.
///
/// Deep slate background, one quiet teal accent, generous spacing, no
/// decorative noise. Everything visible means something real.
class NexusColors {
  static const bg = Color(0xFF0B0F14);
  static const surface = Color(0xFF121821);
  static const surfaceHi = Color(0xFF1A2230);
  static const border = Color(0xFF232D3D);
  static const text = Color(0xFFE8ECF2);
  static const muted = Color(0xFF8A94A6);
  static const accent = Color(0xFF5EEAD4);
  static const accentStrong = Color(0xFF2DD4BF);
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);
}

ThemeData buildNexusTheme() {
  final scheme = ColorScheme.dark(
    surface: NexusColors.surface,
    primary: NexusColors.accent,
    onPrimary: const Color(0xFF06251F),
    secondary: NexusColors.accentStrong,
    onSurface: NexusColors.text,
    onSurfaceVariant: NexusColors.muted,
    error: NexusColors.danger,
    outline: NexusColors.border,
    surfaceContainerHighest: NexusColors.surfaceHi,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexusColors.bg,
    fontFamily: 'Roboto',
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: NexusColors.text),
      titleLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: NexusColors.text),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: NexusColors.text),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: NexusColors.text),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.4, color: NexusColors.muted),
      labelLarge: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.2),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: NexusColors.surface,
      indicatorColor: NexusColors.accent.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? NexusColors.accent : NexusColors.muted);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? NexusColors.text : NexusColors.muted,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: NexusColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: NexusColors.border)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NexusColors.accent,
        foregroundColor: const Color(0xFF06251F),
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NexusColors.text,
        side: const BorderSide(color: NexusColors.border),
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: NexusColors.accent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: NexusColors.surfaceHi,
      contentTextStyle: const TextStyle(color: NexusColors.text, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: NexusColors.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NexusColors.surface,
      hintStyle: const TextStyle(color: NexusColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NexusColors.accent, width: 1.5),
      ),
    ),
    dividerTheme: const DividerThemeData(color: NexusColors.border, thickness: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? NexusColors.accentStrong : NexusColors.muted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? NexusColors.accent.withValues(alpha: 0.35) : NexusColors.surfaceHi),
    ),
  );
}
