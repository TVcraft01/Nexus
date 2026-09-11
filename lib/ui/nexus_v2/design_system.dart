import 'package:flutter/material.dart';

/// Nexus UI v2: a quiet, content-first design system.
///
/// The visual language is inspired by the principles behind Apple's HIG:
/// clear hierarchy, familiar controls, restrained color, large touch targets,
/// and platform-aware layouts. It intentionally does not imitate Apple's
/// branding or proprietary assets.
class NexusV2Colors {
  static const background = Color(0xFF0B0D10);
  static const surface = Color(0xFF15181D);
  static const elevated = Color(0xFF1B1F25);
  static const separator = Color(0xFF2A2F37);
  static const primaryText = Color(0xFFF5F5F7);
  static const secondaryText = Color(0xFFA1A6AF);
  static const tertiaryText = Color(0xFF747A84);
  static const accent = Color(0xFF8B8FFF);
  static const positive = Color(0xFF58D6A5);
  static const warning = Color(0xFFF2C76A);
  static const destructive = Color(0xFFFF7474);
}

ThemeData buildNexusV2Theme({Brightness brightness = Brightness.dark}) {
  if (brightness == Brightness.light) {
    final scheme = ColorScheme.light(
      surface: const Color(0xFFF7F7F8),
      primary: const Color(0xFF5F63D8),
      onPrimary: Colors.white,
      onSurface: const Color(0xFF17181B),
      onSurfaceVariant: const Color(0xFF62666F),
      outline: const Color(0xFFD9DBE0),
      error: const Color(0xFFD63B3B),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF7F7F8),
      visualDensity: VisualDensity.standard,
      textTheme: _textTheme(Colors.black),
      cardTheme: _cardTheme(const Color(0xFFFFFFFF), const Color(0xFFE4E6EA)),
      dividerTheme: const DividerThemeData(color: Color(0xFFE2E4E8), space: 1),
      inputDecorationTheme: _inputTheme(const Color(0xFFFFFFFF), const Color(0xFFD6D8DD)),
      navigationBarTheme: _navigationBarTheme(const Color(0xFFF7F7F8), const Color(0xFFEDEEF2), scheme.primary),
      filledButtonTheme: _filledButtonTheme(scheme.primary),
      outlinedButtonTheme: _outlinedButtonTheme(const Color(0xFFD0D2D8), scheme.onSurface),
    );
  }

  const scheme = ColorScheme.dark(
    surface: NexusV2Colors.surface,
    primary: NexusV2Colors.accent,
    onPrimary: Colors.white,
    secondary: NexusV2Colors.accent,
    onSurface: NexusV2Colors.primaryText,
    onSurfaceVariant: NexusV2Colors.secondaryText,
    outline: NexusV2Colors.separator,
    error: NexusV2Colors.destructive,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexusV2Colors.background,
    visualDensity: VisualDensity.standard,
    textTheme: _textTheme(NexusV2Colors.primaryText),
    cardTheme: _cardTheme(NexusV2Colors.surface, NexusV2Colors.separator),
    dividerTheme: const DividerThemeData(color: NexusV2Colors.separator, space: 1),
    inputDecorationTheme: _inputTheme(NexusV2Colors.surface, NexusV2Colors.separator),
    navigationBarTheme: _navigationBarTheme(NexusV2Colors.background, NexusV2Colors.surface, NexusV2Colors.accent),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: NexusV2Colors.background,
      indicatorColor: NexusV2Colors.surface,
      minWidth: 76,
      minExtendedWidth: 224,
      selectedIconTheme: const IconThemeData(color: NexusV2Colors.accent, size: 22),
      unselectedIconTheme: const IconThemeData(color: NexusV2Colors.tertiaryText, size: 22),
      selectedLabelTextStyle: const TextStyle(color: NexusV2Colors.primaryText, fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: const TextStyle(color: NexusV2Colors.secondaryText, fontSize: 12, fontWeight: FontWeight.w500),
    ),
    filledButtonTheme: _filledButtonTheme(NexusV2Colors.accent),
    outlinedButtonTheme: _outlinedButtonTheme(NexusV2Colors.separator, NexusV2Colors.primaryText),
    dialogTheme: DialogThemeData(
      backgroundColor: NexusV2Colors.elevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 18,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: NexusV2Colors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: NexusV2Colors.elevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: NexusV2Colors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      contentTextStyle: const TextStyle(color: NexusV2Colors.primaryText, fontSize: 14),
    ),
  );
}

TextTheme _textTheme(Color primary) => TextTheme(
  displaySmall: TextStyle(fontSize: 32, height: 1.08, letterSpacing: -0.9, fontWeight: FontWeight.w700, color: primary),
  headlineMedium: TextStyle(fontSize: 27, height: 1.12, letterSpacing: -0.6, fontWeight: FontWeight.w700, color: primary),
  titleLarge: TextStyle(fontSize: 19, height: 1.2, letterSpacing: -0.2, fontWeight: FontWeight.w600, color: primary),
  titleMedium: TextStyle(fontSize: 16, height: 1.25, fontWeight: FontWeight.w600, color: primary),
  bodyLarge: TextStyle(fontSize: 15.5, height: 1.45, color: primary),
  bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: primary),
  bodySmall: TextStyle(fontSize: 12.5, height: 1.4, color: brightnessColor(primary)),
  labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  labelMedium: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
);

Color brightnessColor(Color primary) => primary.computeLuminance() > 0.5 ? const Color(0xFF666A73) : NexusV2Colors.secondaryText;

CardThemeData _cardTheme(Color color, Color border) => CardThemeData(
  color: color,
  elevation: 0,
  surfaceTintColor: Colors.transparent,
  margin: EdgeInsets.zero,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
    side: BorderSide(color: border),
  ),
);

InputDecorationTheme _inputTheme(Color fill, Color border) => InputDecorationTheme(
  filled: true,
  fillColor: fill,
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
  focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide(color: NexusV2Colors.accent, width: 1.5)),
);

NavigationBarThemeData _navigationBarTheme(Color background, Color indicator, Color accent) => NavigationBarThemeData(
  backgroundColor: background,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  height: 74,
  indicatorColor: indicator,
  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
  iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        size: 22,
        color: states.contains(WidgetState.selected) ? accent : NexusV2Colors.tertiaryText,
      )),
);

FilledButtonThemeData _filledButtonTheme(Color color) => FilledButtonThemeData(
  style: FilledButton.styleFrom(
    backgroundColor: color,
    foregroundColor: Colors.white,
    minimumSize: const Size(44, 44),
    padding: const EdgeInsets.symmetric(horizontal: 18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  ),
);

OutlinedButtonThemeData _outlinedButtonTheme(Color border, Color text) => OutlinedButtonThemeData(
  style: OutlinedButton.styleFrom(
    foregroundColor: text,
    side: BorderSide(color: border),
    minimumSize: const Size(44, 44),
    padding: const EdgeInsets.symmetric(horizontal: 18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  ),
);

class NexusV2PageTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const NexusV2PageTitle({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.displaySmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class NexusV2Group extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const NexusV2Group({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title!, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const Divider(indent: 56, endIndent: 0),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class NexusV2Row extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  const NexusV2Row({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = destructive ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              children: [
                if (leading != null) ...[
                  SizedBox(width: 28, child: Center(child: leading)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(title, style: theme.textTheme.bodyLarge?.copyWith(color: textColor)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 12),
                  trailing!,
                ],
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NexusV2Status extends StatelessWidget {
  final bool active;
  final String label;
  const NexusV2Status({super.key, required this.active, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = active ? NexusV2Colors.positive : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
