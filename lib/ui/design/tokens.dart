import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Nexus design tokens — the one place a visual value is written down.
///
/// Every surface in the app reads colour, spacing, radius, size and motion
/// from here through a semantic name, so a screen never spells out a hex
/// value or a magic number. Changing how Nexus looks is a change to this
/// file, not a hunt through widgets.
///
/// Colours come in two palettes. The dark one is what Nexus ships: deep
/// slate, one system-blue accent, nothing decorative. The light one exists so
/// the same semantic names keep working when appearance support lands — it is
/// data, not a second implementation.
///
/// The accent is a single colour, never a gradient and never a low-alpha
/// wash across a surface: the mint-teal that shipped before read as an "AI
/// product", and one confident blue reads as software someone shipped.

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
  static const accent = Color(0xFF0A84FF);
  static const accentStrong = Color(0xFF409CFF);
  static const onAccent = Color(0xFFFFFFFF);
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
  static const accent = Color(0xFF007AFF);
  static const accentStrong = Color(0xFF0062CC);
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

/// Spacing scale, in logical pixels. An 8pt rhythm with a 4pt sub-step for
/// icon/label micro-gaps; a 7 or a 13 in a layout is a bug, not a preference.
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

  /// Horizontal gutter for phone pages — Apple's 16pt margin.
  static const double page = 16;

  /// Vertical gap between two page sections — Apple's 16pt between groups.
  static const double section = 16;
}

/// Corner radii.
abstract final class NexusRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  static const BorderRadius row = BorderRadius.all(Radius.circular(md));
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));

  /// The floating composer at the bottom of the assistant. Between [card] and
  /// [pill] on purpose: a card's 16 reads as a panel, a capsule reads as a
  /// search box, and the input a chat app puts under a thread is neither.
  static const BorderRadius composer = BorderRadius.all(Radius.circular(22));
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

/// Elevation. Nexus carries depth with hairlines, not drop shadows: only the
/// two things that genuinely float over the page get one.
abstract final class NexusShadow {
  /// A seated surface that still reads as above the page — the composer, a
  /// floating banner.
  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x47000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  /// A modal sheet, which casts upward.
  static const List<BoxShadow> sheet = [
    BoxShadow(
      color: Color(0x52000000),
      blurRadius: 32,
      offset: Offset(0, -8),
    ),
  ];
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

/// Springs, written in Apple's two parameters instead of physics' three.
///
/// A spring has no duration: how long it takes to settle falls out of how
/// bouncy it is and how fast it moves. Anything a finger can touch animates
/// through here, because a spring can be grabbed and re-targeted mid-flight —
/// a fixed curve cannot.
///
/// The defaults are the ones Apple ships: critically damped (no overshoot) at
/// the response of a drawer. Bounce is reserved for a gesture that itself
/// carried momentum — a flick — and never for something that merely appeared.
abstract final class NexusSpring {
  /// No overshoot. The default for every touchable surface.
  static const double damped = 1.0;

  /// A gesture that carried momentum: a throw, a flick, a sheet let go of.
  static const double momentum = 0.8;

  /// How quickly the value reaches its target, in seconds. This is not a
  /// duration — it is the speed of the response.
  static const Duration response = Duration(milliseconds: 350);

  /// A spring from [damping] and [response].
  ///
  /// Apple describes the curve with a damping ratio and a response time;
  /// Flutter wants mass, stiffness and a ratio. The two are the same curve:
  /// stiffness is the angular frequency squared, ω = 2π / response.
  static SpringDescription of({
    double damping = damped,
    Duration speed = response,
  }) {
    final seconds = speed.inMicroseconds / Duration.microsecondsPerSecond;
    final omega = 2 * math.pi / seconds;
    return SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: omega * omega,
      ratio: damping,
    );
  }
}

/// The type scale: Apple's text styles, in the sizes and weights a phone
/// actually uses, with the tracking each size needs.
///
/// Tracking is size-specific and is *not* one value for every size. Apple's
/// rule (WWDC "The Details of UI Typography"): large display text wants
/// negative tracking because letters read too far apart as they grow, body
/// copy sits near zero, and small text wants slightly positive tracking to
/// stay legible. The numbers below follow the SF Pro tracking curve — the
/// per-point step is about -0.086 px in the text range (17pt ≈ -0.43,
/// 16pt ≈ -0.31, 15pt ≈ -0.23, 13pt ≈ -0.08, 12pt = 0, 11pt ≈ +0.06) and
/// flattens to about -0.02em once the face switches to Display at 20pt and
/// up. So `display` and `title` are negative, `body` is nearly neutral, and
/// `caption`/`overline` come back toward zero or positive. Line height moves
/// the other way: tight (1.2) on large text, looser (1.4) on the small copy
/// that is read in sentences.
///
/// Weights are chosen for the face that will render them: Roboto, which
/// Android actually has, is lighter than SF at the same weight, so a row
/// title takes `w500` where iOS would say "regular" — it lands at the same
/// optical weight on the device.
abstract final class NexusType {
  /// The range the app's layouts are built for, as a multiple of each size.
  ///
  /// Apple's own scale runs to 3× at the largest accessibility sizes, but
  /// Nexus is built on fixed rows and a fixed tab bar; past 1.5× the honest
  /// answer is a redesign, not a bigger font. Below 0.85× text stops being
  /// legible at arm's length.
  static const double minScale = 0.85;
  static const double maxScale = 1.5;

  /// The user's text-size preference, clamped to [minScale]–[maxScale].
  ///
  /// Flutter already applies the platform's scaler to every `Text`, so the
  /// only reason to ask for it is to *bound* it (see [NexusTextScaling]) or
  /// to grow something that is not text — a row's height, a gutter.
  static TextScaler scalerOf(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).clamp(minScaleFactor: minScale, maxScaleFactor: maxScale);

  /// [value] at the user's text size. A row's height is there to hold a title
  /// and a caption; when those grow, so does the row.
  static double scaled(BuildContext context, double value) =>
      value * scalerOf(context).scale(1.0);

  /// Large Title. Sits inside the page and scrolls with it, the way an iOS
  /// large title does.
  static const TextStyle display = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.68,
    height: 1.2,
  );

  /// Title 3 / a sheet's title.
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.40,
    height: 1.25,
  );

  /// Body 17 — the title of a list row.
  static const TextStyle rowTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.43,
    height: 1.29,
  );

  /// Subheadline 15 — body copy that is read, not scanned.
  static const TextStyle body = TextStyle(
    fontSize: 15,
    letterSpacing: -0.23,
    height: 1.33,
  );

  /// Footnote 13 — the second line of a row, a value, a caption.
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    letterSpacing: -0.08,
    height: 1.38,
  );

  /// Uppercase group label above a section. Uppercase carries its own gap, so
  /// this one is deliberately positive.
  static const TextStyle overline = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.62,
    height: 1.3,
  );

  /// Headline 17 — a button's label.
  static const TextStyle button = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.43,
    height: 1.2,
  );

  /// The one size below the scale, and the only reason it exists: a two-digit
  /// number drawn inside a 26pt progress ring, where the footnote size would
  /// not fit. It is never used for words.
  static const TextStyle micro = TextStyle(
    fontSize: 10,
    letterSpacing: 0,
    height: 1.0,
  );

  /// Callout 16 — a card's own heading, one step under a title, and the size
  /// the assistant's cards were spelling out by hand before they had a name.
  /// Emphasis is the widget's (`copyWith(fontWeight:)`), not a second token:
  /// what a size owns is its size, its tracking and its leading.
  static const TextStyle callout = TextStyle(
    fontSize: 16,
    letterSpacing: -0.31,
    height: 1.31,
  );

  /// Caption 1 12 — the smallest size still read as a sentence.
  static const TextStyle caption1 = TextStyle(
    fontSize: 12,
    letterSpacing: 0,
    height: 1.33,
  );

  /// Caption 2 11 — a device's id, a live status line: print under print,
  /// where the words are labels for something already on screen.
  static const TextStyle caption2 = TextStyle(
    fontSize: 11,
    letterSpacing: 0.06,
    height: 1.27,
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
