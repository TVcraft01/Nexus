import 'package:flutter/material.dart';

/// Nexus visual system — calm, direct and platform-aware.
///
/// The goal is not to decorate the app like an AI dashboard. Surfaces separate
/// content only where useful; hierarchy, spacing and system-like controls do
/// most of the visual work.
class NexusColors {
  static const bg = Color(0xFF0A0D12);
  static const surface = Color(0xFF12161D);
  static const surfaceHi = Color(0xFF191F28);
  static const surfaceElevated = Color(0xFF222934);
  static const border = Color(0xFF27303B);
  static const borderStrong = Color(0xFF364150);
  static const text = Color(0xFFF5F6F8);
  static const muted = Color(0xFFA5ADBA);
  static const faint = Color(0xFF778190);
  static const accent = Color(0xFF7C8CFF);
  static const accentStrong = Color(0xFF6879F2);
  static const ok = Color(0xFF49D5A0);
  static const warn = Color(0xFFF0C45B);
  static const danger = Color(0xFFFF7373);
}

ThemeData buildNexusTheme() {
  const scheme = ColorScheme.dark(
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

  final base = Typography.material2021().white;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexusColors.bg,
    fontFamily: 'Roboto',
    visualDensity: VisualDensity.standard,
    textTheme: base.copyWith(
      displaySmall: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: NexusColors.text,
      ),
      headlineMedium: const TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.55,
        color: NexusColors.text,
      ),
      titleLarge: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: NexusColors.text,
      ),
      titleMedium: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: NexusColors.text,
      ),
      bodyLarge: const TextStyle(
        fontSize: 15,
        height: 1.48,
        color: NexusColors.text,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        height: 1.45,
        color: NexusColors.text,
      ),
      bodySmall: const TextStyle(
        fontSize: 13,
        height: 1.42,
        color: NexusColors.muted,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: NexusColors.bg,
      foregroundColor: NexusColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      toolbarHeight: 56,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: NexusColors.surface,
      indicatorColor: NexusColors.accent.withValues(alpha: 0.14),
      minWidth: 76,
      minExtendedWidth: 220,
      groupAlignment: -0.88,
      selectedIconTheme: const IconThemeData(color: NexusColors.accent, size: 22),
      unselectedIconTheme: const IconThemeData(color: NexusColors.faint, size: 22),
      selectedLabelTextStyle: const TextStyle(
        color: NexusColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w600,
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
      height: 72,
      indicatorColor: NexusColors.accent.withValues(alpha: 0.13),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
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
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: NexusColors.border.withValues(alpha: 0.75)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: NexusColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: NexusColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(color: NexusColors.text, fontSize: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NexusColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NexusColors.text,
        side: const BorderSide(color: NexusColors.borderStrong),
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: NexusColors.accent,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: NexusColors.surfaceElevated,
      elevation: 10,
      contentTextStyle: const TextStyle(color: NexusColors.text, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NexusColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(color: NexusColors.faint),
      labelStyle: const TextStyle(color: NexusColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: NexusColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
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
          states.contains(WidgetState.selected) ? Colors.white : NexusColors.muted),
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
      ),
      textStyle: const TextStyle(color: NexusColors.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
  );
}
