import 'package:flutter/material.dart';

/// Nexus design tokens — the one place a visual value is written down.
///
/// Every surface in the app reads colour, spacing, radius, size and motion
/// from here through a semantic name, so a screen never spells out a hex
/// value or a magic number. Changing how Nexus looks is a change to this
/// file, not a hunt through widgets.
///
/// Colours come in two palettes. The dark one is what Nexus ships: deep
/// slate, one quiet teal accent, nothing decorative. The light one exists so
/// the same semantic names keep working when appearance support lands — it is
/// data, not a second implementation.

/// The written-down dark values. Private on purpose: everything outside this
/// library goes through [NexusPalette] or the legacy [NexusColors] aliases,
/// both of which point back here, so a colour has exactly one definition.
abstract final class _Dark {
  static const bg = Color(0xFF0B0F14);
  static const surface = Color(0xFF121821);
  static const surfaceElevated = Color(0xFF1A2230);
  static const surfaceSecondary = Color(0xFF161E29);
  static const separator = Color(0xFF232D3D);
  static const textPrimary = Color(0xFFE8ECF2);
  static const textSecondary = Color(0xFF8A94A6);
  static const textTertiary = Color(0xFF6B7686);
  static const accent = Color(0xFF5EEAD4);
  static const accentStrong = Color(0xFF2DD4BF);
  static const onAccent = Color(0xFF06251F);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);
  static const onDanger = Color(0xFF2A0A0A);
  static const scrim = Color(0xCC05080C);
}

abstract final class _Light {
  static const bg = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceElevated = Color(0xFFFFFFFF);
  static const surfaceSecondary = Color(0xFFEFF2F6);
  static const separator = Color(0xFFDCE1E8);
  static const textPrimary = Color(0xFF111820);
  static const textSecondary = Color(0xFF5A6474);
  static const textTertiary = Color(0xFF6E7887);
  static const accent = Color(0xFF0E7490);
  static const accentStrong = Color(0xFF0B5F76);
  static const onAccent = Color(0xFFFFFFFF);
  static const success = Color(0xFF0F7A4A);
  static const warning = Color(0xFF8A5300);
  static const danger = Color(0xFFB3261E);
  static const onDanger = Color(0xFFFFFFFF);
  static const scrim = Color(0x6605080C);
}

/// Semantic colours. Names describe the *role*, never the hue, so a screen
/// can be re-themed without touching the widget that uses it.
@immutable
class NexusPalette extends ThemeExtension<NexusPalette> {
  const NexusPalette({
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceSecondary,
    required this.separator,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentStrong,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.onDanger,
    required this.scrim,
  });

  /// The page behind everything.
  final Color bg;

  /// The default raised container: rows, sheets, bars.
  final Color surface;

  /// A container raised above [surface] — menus, selected states.
  final Color surfaceElevated;

  /// A quiet fill for chips and avatars that should not read as a panel.
  final Color surfaceSecondary;

  /// Hairlines between rows. One pixel of separation, never a border for
  /// decoration.
  final Color separator;

  final Color textPrimary;
  final Color textSecondary;

  /// The dimmest ink that still passes contrast for small print.
  final Color textTertiary;

  /// Nexus itself: the accent that means "this is doing something".
  final Color accent;

  /// Pressed/lit variant of [accent].
  final Color accentStrong;

  /// Ink on top of [accent].
  final Color onAccent;

  final Color success;
  final Color warning;
  final Color danger;

  /// Ink on top of [danger].
  final Color onDanger;

  /// Behind a modal sheet.
  final Color scrim;

  /// The dark palette — the shipped identity. Values live in [_Dark] so the
  /// legacy [NexusColors] aliases and this palette cannot drift apart.
  static const dark = NexusPalette(
    bg: _Dark.bg,
    surface: _Dark.surface,
    surfaceElevated: _Dark.surfaceElevated,
    surfaceSecondary: _Dark.surfaceSecondary,
    separator: _Dark.separator,
    textPrimary: _Dark.textPrimary,
    textSecondary: _Dark.textSecondary,
    textTertiary: _Dark.textTertiary,
    accent: _Dark.accent,
    accentStrong: _Dark.accentStrong,
    onAccent: _Dark.onAccent,
    success: _Dark.success,
    warning: _Dark.warning,
    danger: _Dark.danger,
    onDanger: _Dark.onDanger,
    scrim: _Dark.scrim,
  );

  /// The light palette — same names, same roles.
  static const light = NexusPalette(
    bg: _Light.bg,
    surface: _Light.surface,
    surfaceElevated: _Light.surfaceElevated,
    surfaceSecondary: _Light.surfaceSecondary,
    separator: _Light.separator,
    textPrimary: _Light.textPrimary,
    textSecondary: _Light.textSecondary,
    textTertiary: _Light.textTertiary,
    accent: _Light.accent,
    accentStrong: _Light.accentStrong,
    onAccent: _Light.onAccent,
    success: _Light.success,
    warning: _Light.warning,
    danger: _Light.danger,
    onDanger: _Light.onDanger,
    scrim: _Light.scrim,
  );

  /// The palette for the current theme.
  static NexusPalette of(BuildContext context) =>
      Theme.of(context).extension<NexusPalette>() ?? dark;

  /// A tint of [accent] at [alpha] — the fill behind "this is Nexus" states.
  Color accentTint([double alpha = 0.12]) => accent.withValues(alpha: alpha);

  @override
  NexusPalette copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceSecondary,
    Color? separator,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentStrong,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? onDanger,
    Color? scrim,
  }) {
    return NexusPalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceSecondary: surfaceSecondary ?? this.surfaceSecondary,
      separator: separator ?? this.separator,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentStrong: accentStrong ?? this.accentStrong,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  NexusPalette lerp(covariant NexusPalette? other, double t) {
    if (other == null) return this;
    return NexusPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceSecondary: Color.lerp(
        surfaceSecondary,
        other.surfaceSecondary,
        t,
      )!,
      separator: Color.lerp(separator, other.separator, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentStrong: Color.lerp(accentStrong, other.accentStrong, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

/// Spacing scale, in logical pixels. Only these values: a 7 or a 13 in a
/// layout is a bug, not a preference.
abstract final class NexusSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;

  /// Horizontal gutter for phone pages.
  static const double page = 20;

  /// Vertical gap between two page sections.
  static const double section = 28;
}

/// Corner radii.
abstract final class NexusRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const Radius sheet = Radius.circular(22);

  static const BorderRadius row = BorderRadius.all(Radius.circular(md));
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Control and row heights.
abstract final class NexusSize {
  /// Anything tappable is at least this big — Apple's 44pt, Android's 48dp,
  /// take the larger. Below it, a target is a bug.
  static const double minTouch = 48;

  /// A list row with a title and a subtitle.
  static const double row = 64;

  /// A single-line list row.
  static const double rowCompact = 52;

  static const double button = 48;
  static const double field = 52;
  static const double navIcon = 24;
  static const double avatar = 44;

  /// The widest a column of content is allowed to get; past it, reading
  /// becomes work.
  static const double readable = 640;

  /// The widest the desktop content column gets.
  static const double desktop = 980;
}

/// Motion. Motion means something is happening — it is never decoration.
abstract final class NexusMotion {
  /// Colour and opacity changes.
  static const Duration fast = Duration(milliseconds: 120);

  /// The default for a state change the user caused.
  static const Duration base = Duration(milliseconds: 220);

  /// Entrances: sheets, expanding sections.
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuart;

  /// A state that settles should not bounce.
  static const Curve settle = Curves.easeInOut;

  /// Respect the platform's "reduce motion" setting: when animations are off,
  /// these collapse to zero and state changes land instantly.
  static Duration scaled(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;
}

/// The type scale. Four sizes carry the whole app: a page title, a row title,
/// body copy, and a caption. A new size is a design decision, not a style.
abstract final class NexusType {
  static const TextStyle display = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.15,
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.25,
  );

  static const TextStyle rowTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.45,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12.5,
    height: 1.35,
  );

  /// Uppercase group label above a section.
  static const TextStyle overline = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );

  static const TextStyle button = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
}

/// The dark-only colour names Nexus shipped with, kept as aliases so the
/// screens that have not been moved onto [NexusPalette] still compile and
/// still look right.
///
/// They are constants, not a palette: they cannot follow the appearance.
/// New code reads [NexusPalette.of] instead, and each screen moves over as it
/// is touched. Removing these is the follow-up once the last screen has.
abstract final class NexusColors {
  static const bg = _Dark.bg;
  static const surface = _Dark.surface;
  static const surfaceHi = _Dark.surfaceElevated;
  static const border = _Dark.separator;
  static const text = _Dark.textPrimary;
  static const muted = _Dark.textSecondary;
  static const accent = _Dark.accent;
  static const accentStrong = _Dark.accentStrong;
  static const ok = _Dark.success;
  static const warn = _Dark.warning;
  static const danger = _Dark.danger;
}
