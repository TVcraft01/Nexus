import 'package:flutter/material.dart';

/// Nexus design language — quiet, precise, and useful.
///
/// The UI should feel like a finished system product rather than an AI demo:
/// low visual noise, clear hierarchy, restrained surfaces, and one purposeful
/// accent for interactive state.
class NexusColors {
  static const bg = Color(0xFF0A0D12);
  static const surface = Color(0xFF10151C);
  static const surfaceHi = Color(0xFF171D26);
  static const surfaceElevated = Color(0xFF1C232D);
  static const border = Color(0xFF242C37);
  static const borderStrong = Color(0xFF303A47);
  static const text = Color(0xFFF2F4F7);
  static const muted = Color(0xFF98A2B3);
  static const faint = Color(0xFF697586);
  static const accent = Color(0xFF7C8CFF);
  static const accentStrong = Color(0xFF6375F4);
  static const ok = Color(0xFF45D39C);
  static const warn = Color(0xFFF4C65D);
  static const danger = Color(0xFFFF7272);
}

ThemeData buildNexusTheme() {
  final scheme = ColorScheme.dark(
    surface: NexusColors.surface,
    primary: NexusColors.accent,
    onPrimary: Colors.white,
    secondary: NexusColors.accentStrong,
    onSecondary: Colors.white,
    onSurface: NexusColors.text,
    onSurfaceVariant: NexusColors.muted,
    error: NexusColors.danger,
    onError: Colors.white,
    outline: NexusColors.border,
    surfaceContainerHighest: NexusColors.surfaceHi,
  );

  final baseText = Typography.material2021().white;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexusColors.bg,
    fontFamily: 'Roboto',
    textTheme: baseText.copyWith(
      displaySmall: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: NexusColors.text,
      ),
      headlineMedium: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: NexusColors.text,
      ),
      titleLarge: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w650,
        letterSpacing: -0.15,
        color: NexusColors.text,
      ),
      titleMedium: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w650,
        color: NexusColors.text,
      ),
      bodyLarge: const TextStyle(
        fontSize: 15,
        height: 1.45,
        color: NexusColors.text,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        height: 1.45,
        color: NexusColors.text,
      ),
      bodySmall: const TextStyle(
        fontSize: 12.5,
        height: 1.42,
        color: NexusColors.muted,
      ),
      labelLarge: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w650,
        letterSpacing: 0.1,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.05,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: NexusColors.bg,
      foregroundColor: NexusColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: NexusColors.surface,
      indicatorColor: NexusColors.accent.withValues(alpha: 0.14),
      selectedIconTheme: const IconThemeData(color: NexusColors.accent),
      unselectedIconTheme: const IconThemeData(color: NexusColors.faint),
      selectedLabelTextStyle: const TextStyle(
        color: NexusColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w650,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: NexusColors.muted,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: NexusColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: NexusColors.accent.withValues(alpha: 0.14),
      height: 72,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 21,
          color: selected ? NexusColors.accent : NexusColors.faint,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w650 : FontWeight.w500,
          color: selected ? NexusColors.text : NexusColors.muted,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: NexusColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: NexusColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: NexusColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: NexusColors.borderStrong),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: NexusColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: NexusColors.border),
      ),
      textStyle: const TextStyle(color: NexusColors.text, fontSize: 13.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NexusColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w650),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NexusColors.text,
        side: const BorderSide(color: NexusColors.borderStrong),
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: NexusColors.accent,
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: NexusColors.surfaceElevated,
      elevation: 10,
      contentTextStyle: const TextStyle(color: NexusColors.text, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: NexusColors.borderStrong),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NexusColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(color: NexusColors.faint),
      labelStyle: const TextStyle(color: NexusColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: NexusColors.accent, width: 1.4),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: NexusColors.border,
      thickness: 1,
      space: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? Colors.white
              : NexusColors.muted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NexusColors.accent.withValues(alpha: 0.6)
              : NexusColors.surfaceHi),
      trackOutlineColor: WidgetStateProperty.all(NexusColors.borderStrong),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: NexusColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NexusColors.border),
      ),
      textStyle: const TextStyle(color: NexusColors.text, fontSize: 12),
    ),
  );
}
