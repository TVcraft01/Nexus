import 'package:flutter/material.dart';

import 'design/tokens.dart';

// The tokens live in design/tokens.dart; re-exported so every existing
// `import 'theme.dart'` keeps working.
export 'design/tokens.dart';

/// Builds the Nexus theme from the design tokens.
///
/// Nothing here invents a value: colours come from [NexusPalette], sizes from
/// [NexusSize], radii from [NexusRadius] and type from [NexusType]. Changing
/// how the app looks is a change to the token file.
///
/// The dark theme is what ships. The light one is built from the same code
/// path so appearance support is wiring, not a rewrite — but no screen claims
/// to support it yet.
ThemeData buildNexusTheme({Brightness brightness = Brightness.dark}) {
  final palette = brightness == Brightness.dark
      ? NexusPalette.dark
      : NexusPalette.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent,
    onPrimary: palette.onAccent,
    secondary: palette.accentStrong,
    onSecondary: palette.onAccent,
    error: palette.danger,
    onError: palette.onDanger,
    surface: palette.surface,
    onSurface: palette.textPrimary,
    onSurfaceVariant: palette.textSecondary,
    outline: palette.separator,
    outlineVariant: palette.separator,
    surfaceContainerLowest: palette.bg,
    surfaceContainerLow: palette.surface,
    surfaceContainer: palette.surface,
    surfaceContainerHigh: palette.surfaceElevated,
    surfaceContainerHighest: palette.surfaceSecondary,
    shadow: const Color(0x66000000),
    scrim: palette.scrim,
    inverseSurface: palette.textPrimary,
    onInverseSurface: palette.bg,
    inversePrimary: palette.accentStrong,
  );

  TextStyle ink(TextStyle base, Color color) =>
      base.copyWith(color: color);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.bg,
    canvasColor: palette.bg,
    splashFactory: InkSparkle.splashFactory,
    extensions: [palette],
    textTheme: TextTheme(
      headlineMedium: ink(NexusType.display, palette.textPrimary),
      titleLarge: ink(NexusType.title, palette.textPrimary),
      titleMedium: ink(NexusType.rowTitle, palette.textPrimary),
      bodyLarge: ink(NexusType.body, palette.textPrimary),
      bodyMedium: ink(NexusType.body, palette.textPrimary),
      bodySmall: ink(NexusType.caption, palette.textSecondary),
      labelLarge: ink(NexusType.button, palette.textPrimary),
      labelSmall: ink(NexusType.overline, palette.textTertiary),
    ),
    // No card in Nexus is a decorated box any more: a Card is a surface to
    // group rows on, with a hairline only when it needs an edge.
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: NexusRadius.card),
    ),
    dividerTheme: DividerThemeData(
      color: palette.separator,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: palette.textSecondary,
      textColor: palette.textPrimary,
      contentPadding: const EdgeInsets.symmetric(horizontal: NexusSpace.lg),
      minVerticalPadding: NexusSpace.md,
      shape: const RoundedRectangleBorder(borderRadius: NexusRadius.row),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.accentTint(0.16),
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: NexusSize.navIcon,
          color: states.contains(WidgetState.selected)
              ? palette.accent
              : palette.textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? palette.textPrimary
              : palette.textSecondary,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: palette.surface,
      indicatorColor: palette.accentTint(0.16),
      selectedIconTheme: IconThemeData(color: palette.accent),
      unselectedIconTheme: IconThemeData(color: palette.textSecondary),
      selectedLabelTextStyle: TextStyle(
        color: palette.textPrimary,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: palette.textSecondary,
        fontWeight: FontWeight.w500,
        fontSize: 12.5,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        disabledBackgroundColor: palette.surfaceSecondary,
        disabledForegroundColor: palette.textTertiary,
        minimumSize: const Size(0, NexusSize.button),
        padding: const EdgeInsets.symmetric(horizontal: NexusSpace.xl),
        shape: const RoundedRectangleBorder(borderRadius: NexusRadius.row),
        textStyle: NexusType.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: palette.separator),
        minimumSize: const Size(0, NexusSize.button),
        padding: const EdgeInsets.symmetric(horizontal: NexusSpace.xl),
        shape: const RoundedRectangleBorder(borderRadius: NexusRadius.row),
        textStyle: NexusType.button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accent,
        minimumSize: const Size(NexusSize.minTouch, NexusSize.button),
        textStyle: NexusType.button,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.textSecondary,
        minimumSize: const Size(NexusSize.minTouch, NexusSize.minTouch),
        highlightColor: palette.accentTint(0.10),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.surfaceElevated,
      contentTextStyle: ink(NexusType.body, palette.textPrimary),
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.all(NexusSpace.lg),
      shape: const RoundedRectangleBorder(borderRadius: NexusRadius.row),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: palette.surface,
      modalBarrierColor: palette.scrim,
      showDragHandle: true,
      dragHandleColor: palette.separator,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: NexusRadius.sheet),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: NexusRadius.card),
      titleTextStyle: ink(NexusType.title, palette.textPrimary),
      contentTextStyle: ink(NexusType.body, palette.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      hintStyle: ink(NexusType.body, palette.textTertiary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.lg,
        vertical: NexusSpace.md,
      ),
      border: const OutlineInputBorder(
        borderRadius: NexusRadius.row,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: NexusRadius.row,
        borderSide: BorderSide(color: palette.separator),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NexusRadius.row,
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.onAccent
            : palette.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : palette.surfaceSecondary,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : palette.separator,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: palette.surface,
        foregroundColor: palette.textSecondary,
        selectedForegroundColor: palette.accent,
        selectedBackgroundColor: palette.accentTint(0.12),
        side: BorderSide(color: palette.separator),
        textStyle: NexusType.caption,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: NexusRadius.card),
      textStyle: ink(NexusType.body, palette.textPrimary),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: NexusRadius.pill,
        border: Border.all(color: palette.separator),
      ),
      textStyle: ink(NexusType.caption, palette.textPrimary),
      waitDuration: const Duration(milliseconds: 500),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearTrackColor: palette.surfaceSecondary,
      circularTrackColor: palette.surfaceSecondary,
    ),
    // Android phones in this app's range still default to a ripple that
    // ignores the surface colour; keep the highlight subtle and consistent.
    hoverColor: palette.accentTint(0.06),
    focusColor: palette.accentTint(0.10),
    visualDensity: VisualDensity.standard,
  );
}
