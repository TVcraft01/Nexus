/// A fresh, self-contained UI shell for Nexus — the front end only.
///
/// This file is deliberately independent of everything already in `lib/`: it
/// imports no mesh, no store, no model, and no `lib/ui` widget. It is a shell
/// you can run by itself, look at, and then wire the real behaviour behind:
///
///     flutter run -t lib/main_ui.dart
///
/// The one thing it does reach for is `core/services/icon_service.dart`, and
/// only from [CustomizationPage]: the launcher mark is a manifest component
/// with an owner of its own, so the page that offers it talks to that owner
/// rather than to a mock of it. Everything else on screen is still mock data.
///
/// What lives here:
///   * [NexusUiColors] / [NexusType] / [NexusLayout] — the design tokens.
///   * [NexusTheme] — Material 3 light and dark themes built from those tokens.
///   * [NexusUiApp] / [NexusShell] — the app root and the four-tab frame.
///   * [HomeTab], [FilesTab], [DevicesTab], [SettingsTab] — the four screens.
///   * [CustomizationPage] — what Settings pushes to: one row per look, the
///     App icon first.
///
/// The colour rule the whole file follows: purple (`#773DDC`) is painted
/// *only* on something the user can act on — the mic/send button, the active
/// tab, a switch that is on, a focused text field, an action label. Everything
/// static is neutral: backgrounds, hairlines, icon tiles, body text, muted
/// labels, and the offline dot.
///
/// Typography is Inter via `google_fonts`, which fetches the font files on
/// first run (and falls back to the platform sans when it cannot reach them).
/// The screens are mock data only — no answer, fetch, or pair runs here yet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/services/icon_service.dart';

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/// The one purple in the app: seed colour, active tab, mic/send, switches on.
const Color kNexusAccent = Color(0xFF773DDC);

/// The neutral colours the shell is built from, as a [ThemeExtension] so a
/// single token serves both brightnesses and the dark-mode switch can
/// interpolate between them rather than swapping abruptly.
@immutable
class NexusUiColors extends ThemeExtension<NexusUiColors> {
  const NexusUiColors({
    required this.background,
    required this.surface,
    required this.raised,
    required this.hairline,
    required this.textStrong,
    required this.textMuted,
    required this.bubbleMine,
    required this.bubbleTheirs,
    required this.online,
    required this.offline,
    required this.accent,
    required this.onAccent,
  });

  /// The page behind everything: `#FAFAF8` in light mode.
  final Color background;

  /// Cards, pills, sheets, the navigation bar: one step up from [background].
  final Color surface;

  /// Icon tiles, inactive switches, the neutral chip: one step up from
  /// [surface] without being interactive.
  final Color raised;

  /// Every 1px divider, border and outline in the shell.
  final Color hairline;

  /// Body copy: `#1A1A1A` in light mode.
  final Color textStrong;

  /// Labels, timestamps, hints, inactive tabs.
  final Color textMuted;

  /// The user's own message bubble — light grey, no border.
  final Color bubbleMine;

  /// Nexus's bubble — surface white, outlined with [hairline].
  final Color bubbleTheirs;

  /// The paired-and-reachable dot.
  final Color online;

  /// The paired-but-away dot.
  final Color offline;

  /// Interactive purple. Never used as an area fill behind static content.
  final Color accent;

  /// What sits on top of [accent] (the mic glyph, the switch thumb).
  final Color onAccent;

  /// Light: the palette from the brief.
  static const NexusUiColors light = NexusUiColors(
    background: Color(0xFFFAFAF8),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFF1F1EE),
    hairline: Color(0xFFE6E6E1),
    textStrong: Color(0xFF1A1A1A),
    textMuted: Color(0xFF77776F),
    bubbleMine: Color(0xFFEFEFEA),
    bubbleTheirs: Color(0xFFFFFFFF),
    online: Color(0xFF2F9E63),
    offline: Color(0xFFC7C7C1),
    accent: kNexusAccent,
    onAccent: Color(0xFFFFFFFF),
  );

  /// Dark: the same neutrals, inverted. Purple lifts a step so it keeps its
  /// contrast on a dark page.
  static const NexusUiColors dark = NexusUiColors(
    background: Color(0xFF111113),
    surface: Color(0xFF1A1A1D),
    raised: Color(0xFF232327),
    hairline: Color(0xFF2C2C31),
    textStrong: Color(0xFFF2F2F0),
    textMuted: Color(0xFF9C9CA3),
    bubbleMine: Color(0xFF26262B),
    bubbleTheirs: Color(0xFF1E1E22),
    online: Color(0xFF4CC38A),
    offline: Color(0xFF55555C),
    accent: Color(0xFF9D6BF5),
    onAccent: Color(0xFFFFFFFF),
  );

  @override
  NexusUiColors copyWith({
    Color? background,
    Color? surface,
    Color? raised,
    Color? hairline,
    Color? textStrong,
    Color? textMuted,
    Color? bubbleMine,
    Color? bubbleTheirs,
    Color? online,
    Color? offline,
    Color? accent,
    Color? onAccent,
  }) {
    return NexusUiColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      hairline: hairline ?? this.hairline,
      textStrong: textStrong ?? this.textStrong,
      textMuted: textMuted ?? this.textMuted,
      bubbleMine: bubbleMine ?? this.bubbleMine,
      bubbleTheirs: bubbleTheirs ?? this.bubbleTheirs,
      online: online ?? this.online,
      offline: offline ?? this.offline,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  NexusUiColors lerp(ThemeExtension<NexusUiColors>? other, double t) {
    if (other is! NexusUiColors) return this;
    return NexusUiColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      textStrong: Color.lerp(textStrong, other.textStrong, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      bubbleMine: Color.lerp(bubbleMine, other.bubbleMine, t)!,
      bubbleTheirs: Color.lerp(bubbleTheirs, other.bubbleTheirs, t)!,
      online: Color.lerp(online, other.online, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// Fixed measurements the shell is built around.
abstract final class NexusLayout {
  /// Widest the content column ever gets. The phone layout is unaffected; a
  /// desktop window stops stretching the list rows into a ruler.
  static const double content = 560;

  /// Height of the tab bar's icon+label strip, above the safe area.
  static const double tabBar = 56;

  /// The one corner radius family: pills, sheets and tiles all come from it.
  static const Radius pill = Radius.circular(26);
  static const Radius card = Radius.circular(16);
  static const Radius tile = Radius.circular(12);
  static const Radius bubble = Radius.circular(20);
  static const Radius bubbleTail = Radius.circular(6);
}

/// The type ramp. Every style goes through Inter, and every colour it is
/// handed comes from [NexusUiColors] — no style invents its own grey.
abstract final class NexusType {
  /// "Hey, what do you need?" — the only large text in the shell.
  static TextStyle greeting(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 27,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
    color: c.textStrong,
  );

  /// The line under the greeting.
  static TextStyle lede(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: c.textMuted,
  );

  /// A screen title: "Files", "Devices", "Settings".
  static TextStyle pageTitle(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: c.textStrong,
  );

  /// The small caps label above a group of rows.
  static TextStyle section(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
    color: c.textMuted,
  );

  /// A row's main line, and the device switcher's own label.
  static TextStyle rowTitle(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.25,
    color: c.textStrong,
  );

  /// A row's second line, sizes, dates, "6 items".
  static TextStyle rowMeta(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: c.textMuted,
  );

  /// A message bubble's text.
  static TextStyle bubble(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    height: 1.45,
    color: c.textStrong,
  );

  /// The composer's placeholder.
  static TextStyle hint(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: c.textMuted,
  );

  /// A tab bar label.
  static TextStyle tab(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    color: c.textMuted,
  );

  /// The wordmark.
  static TextStyle wordmark(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: c.textStrong,
  );
}

/// Reads the shell's tokens off the ambient theme.
extension NexusContext on BuildContext {
  /// This build's palette.
  NexusUiColors get ui =>
      Theme.of(this).extension<NexusUiColors>() ?? NexusUiColors.light;

  /// This build's text theme (Inter, from the theme).
  TextTheme get texts => Theme.of(this).textTheme;
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// Builds the Material 3 theme for one brightness.
///
/// `useMaterial3: true` is the foundation; on top of it the neutral surface
/// colours from [NexusUiColors] replace the tonal ones M3 would derive, so the
/// page never picks up a tinted lavender cast from the seed. Only `primary`
/// keeps the purple, which is how a stray default action still lands on an
/// interactive colour rather than on a background.
abstract final class NexusTheme {
  static ThemeData light() => _build(NexusUiColors.light, Brightness.light);

  static ThemeData dark() => _build(NexusUiColors.dark, Brightness.dark);

  static ThemeData _build(NexusUiColors c, Brightness brightness) {
    final base = ThemeData(useMaterial3: true, brightness: brightness);
    final scheme =
        ColorScheme.fromSeed(seedColor: kNexusAccent, brightness: brightness)
            .copyWith(
              primary: c.accent,
              onPrimary: c.onAccent,
              surface: c.surface,
              onSurface: c.textStrong,
              onSurfaceVariant: c.textMuted,
              outline: c.hairline,
              outlineVariant: c.hairline,
            );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      dividerColor: c.hairline,
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: c.textStrong,
        displayColor: c.textStrong,
      ),
      extensions: <ThemeExtension<dynamic>>[c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: NexusType.rowTitle(c).copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accent.withValues(alpha: 0.18),
        selectionHandleColor: c.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? c.onAccent
              : c.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.accent : c.raised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.accent : c.hairline,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(NexusLayout.card),
        ),
        textStyle: NexusType.rowTitle(c),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Colors.black.withValues(alpha: 0.35),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        showDragHandle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.textStrong,
        contentTextStyle: NexusType.rowMeta(
          c,
        ).copyWith(color: c.background, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(NexusLayout.tile),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

void main() => runApp(const NexusUiApp());

/// The shell app. Holds the one piece of state that outlives a tab — dark mode
/// — because the Settings tab toggles it and the whole frame has to follow.
class NexusUiApp extends StatefulWidget {
  const NexusUiApp({super.key});

  @override
  State<NexusUiApp> createState() => _NexusUiAppState();
}

class _NexusUiAppState extends State<NexusUiApp> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      theme: NexusTheme.light(),
      darkTheme: NexusTheme.dark(),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: NexusShell(
        darkMode: _dark,
        onDarkModeChanged: (value) => setState(() => _dark = value),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

/// The frame: four tabs, one body, and the tab bar that switches between them.
///
/// The bodies sit in an [IndexedStack] so a half-typed message and a scrolled
/// file list survive a trip to another tab — the cheap version of the thing a
/// real shell would do with routes.
class NexusShell extends StatefulWidget {
  const NexusShell({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  /// Whether the shell is currently in dark mode.
  final bool darkMode;

  /// Called when the Settings tab flips the appearance switch.
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<NexusShell> createState() => _NexusShellState();
}

class _NexusShellState extends State<NexusShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      body: IndexedStack(
        index: _tab,
        children: <Widget>[
          const HomeTab(),
          const FilesTab(),
          const DevicesTab(),
          SettingsTab(
            darkMode: widget.darkMode,
            onDarkModeChanged: widget.onDarkModeChanged,
          ),
        ],
      ),
      bottomNavigationBar: NexusTabBar(
        index: _tab,
        onSelected: (index) => setState(() => _tab = index),
      ),
    );
  }
}

/// One entry in the tab bar.
class NexusTabSpec {
  const NexusTabSpec(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// The Instagram-shaped bar: hairline on top, no indicator pill, icon over a
/// small label, purple only on the tab you are looking at.
class NexusTabBar extends StatelessWidget {
  const NexusTabBar({
    super.key,
    required this.index,
    required this.onSelected,
    this.tabs = _defaultTabs,
  });

  /// Which tab is active.
  final int index;

  /// Called with the tapped tab's index.
  final ValueChanged<int> onSelected;

  /// The four tabs, in order.
  final List<NexusTabSpec> tabs;

  static const List<NexusTabSpec> _defaultTabs = <NexusTabSpec>[
    NexusTabSpec('Home', Icons.home_outlined, Icons.home_rounded),
    NexusTabSpec('Files', Icons.folder_outlined, Icons.folder_rounded),
    NexusTabSpec('Devices', Icons.devices_outlined, Icons.devices_rounded),
    NexusTabSpec('Settings', Icons.settings_outlined, Icons.settings_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Material(
          type: MaterialType.transparency,
          // heightFactor 1 is what keeps the bar bar-height: without it the
          // Align would stretch to whatever the Scaffold offers the bottom
          // slot, which is the whole screen — and the body would get none.
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: NexusLayout.content),
              child: SizedBox(
                height: NexusLayout.tabBar,
                child: Row(
                  children: <Widget>[
                    for (int i = 0; i < tabs.length; i++)
                      Expanded(
                        child: _TabButton(
                          spec: tabs[i],
                          selected: i == index,
                          onTap: () => onSelected(i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final NexusTabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    const Duration fade = Duration(milliseconds: 170);
    final color = selected ? c.accent : c.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(NexusLayout.tile),
        splashColor: c.accent.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            AnimatedScale(
              scale: selected ? 1 : 0.92,
              duration: fade,
              curve: Curves.easeOut,
              child: Icon(
                selected ? spec.activeIcon : spec.icon,
                size: 23,
                color: color,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              style: NexusType.tab(c).copyWith(color: color),
              duration: fade,
              child: Text(spec.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shared body of the three list screens: a title block, then content
/// centred in [NexusLayout.content].
class NexusTabBody extends StatelessWidget {
  const NexusTabBody({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String title;

  /// Muted line under the title.
  final String? subtitle;

  /// Optional neutral action on the title line.
  final Widget? trailing;

  /// The list or page content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth > NexusLayout.content
              ? NexusLayout.content
              : box.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(title, style: NexusType.pageTitle(c)),
                          if (subtitle != null) ...<Widget>[
                            const SizedBox(height: 3),
                            Text(subtitle!, style: NexusType.rowMeta(c)),
                          ],
                        ],
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(width: width, child: child),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

/// A group label: "APPEARANCE", "PAIRED DEVICES".
class NexusSectionLabel extends StatelessWidget {
  const NexusSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(text.toUpperCase(), style: NexusType.section(context.ui)),
    );
  }
}

/// A neutral rounded square holding an icon — the leading tile on file rows
/// and device rows. Deliberately not purple: it is decoration, not a control.
class NexusIconTile extends StatelessWidget {
  const NexusIconTile(this.icon, {super.key, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: const BorderRadius.all(NexusLayout.tile),
      ),
      child: Icon(icon, size: size * 0.5, color: c.textMuted),
    );
  }
}

/// The online/offline dot on a device row.
class NexusStatusDot extends StatelessWidget {
  const NexusStatusDot({super.key, required this.online, this.size = 8});

  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: online ? c.online : c.offline,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// One settings/devices row: optional leading tile, title, second line, and a
/// trailing control. `onTap` is what makes the row interactive — and what
/// decides whether its label is allowed to be purple.
class NexusRow extends StatelessWidget {
  const NexusRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.accentTitle = false,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Paints the title purple — only pass true for a row that is an action.
  final bool accentTitle;

  /// What a screen reader says for this row, when the row shows something the
  /// label cannot: a tick, a colour swatch. Null leaves the row's own text to
  /// speak for itself.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final titleColor = accentTitle ? c.accent : c.textStrong;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: NexusType.rowTitle(c).copyWith(color: titleColor),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: NexusType.rowMeta(c)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null && onLongPress == null) return _labelled(row);
    return _labelled(
      InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: const BorderRadius.all(NexusLayout.tile),
        child: row,
      ),
    );
  }

  /// Adds the row's spoken label when it has one, and stays out of the way
  /// when it does not — an unlabelled row is announced by its own text.
  Widget _labelled(Widget child) {
    final label = semanticLabel;
    if (label == null) return child;
    return Semantics(
      container: true,
      button: onTap != null || onLongPress != null,
      label: label,
      child: child,
    );
  }
}

/// The chevron a row shows when it leads somewhere.
class NexusChevron extends StatelessWidget {
  const NexusChevron({super.key});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.chevron_right_rounded,
      size: 20,
      color: context.ui.textMuted,
    );
  }
}

/// A short, honest note that a control is not wired to anything yet.
void nexusNotWired(BuildContext context, String what) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('$what is not wired up yet — this shell is UI only.'),
        duration: const Duration(milliseconds: 1600),
      ),
    );
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

/// One line of the fake conversation the Home tab opens with.
class NexusMockMessage {
  const NexusMockMessage(this.text, {this.mine = false});

  final String text;

  /// True for the user's side of the thread (right, grey, tail on the left).
  final bool mine;
}

/// The Claude-shaped home screen: a greeting, a short thread, and the composer
/// pinned at the bottom above the keyboard.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final TextEditingController _message = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// The two layout-showing bubbles, plus anything typed and sent on top.
  final List<NexusMockMessage> _thread = <NexusMockMessage>[
    const NexusMockMessage(
      'Everything stays on your devices. Nothing here leaves the room.',
    ),
    const NexusMockMessage('What’s in my Downloads?', mine: true),
  ];

  @override
  void initState() {
    super.initState();
    // Two rebuild triggers: the trailing button swaps mic ⇄ send with the
    // text, and the pill's outline lights up while the field has focus.
    _message.addListener(_onChanged);
    _focus.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _message
      ..removeListener(_onChanged)
      ..dispose();
    _focus
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  bool get _hasText => _message.text.trim().isNotEmpty;

  void _send() {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _thread.add(NexusMockMessage(text, mine: true));
      _message.clear();
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    // The thread sits in a column no wider than NexusLayout.content. Bubbles
    // are capped against that column rather than the raw screen width, so a
    // desktop window does not stretch a one-line message across the page.
    final double screen = MediaQuery.sizeOf(context).width;
    final double column = screen < NexusLayout.content
        ? screen
        : NexusLayout.content;
    final double bubbleWidth = (column - 40) * 0.82;

    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          const _HomeHeader(),
          Expanded(
            // Centred while the thread is short, scrollable once it is not,
            // and never clipped when the keyboard takes the bottom half.
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: NexusLayout.content,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Hey, what do you need?',
                        textAlign: TextAlign.center,
                        style: NexusType.greeting(c),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ask me anything. Your devices answer directly — no '
                        'account, no cloud.',
                        textAlign: TextAlign.center,
                        style: NexusType.lede(c),
                      ),
                      const SizedBox(height: 30),
                      for (final message in _thread)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: NexusChatBubble(
                            text: message.text,
                            mine: message.mine,
                            maxWidth: bubbleWidth,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _Composer(
            controller: _message,
            focusNode: _focus,
            hasText: _hasText,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// The slim header: wordmark on the left, "On this device" on the right.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: <Widget>[
          Text('Nexus', style: NexusType.wordmark(c)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.raised,
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.lock_outline, size: 13, color: c.textMuted),
                const SizedBox(width: 5),
                Text('On this device', style: NexusType.rowMeta(c)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A message bubble. The user's side is grey with the tail on the left; Nexus's
/// side is the surface colour, outlined.
class NexusChatBubble extends StatelessWidget {
  const NexusChatBubble({
    super.key,
    required this.text,
    required this.mine,
    this.maxWidth = 320,
  });

  final String text;
  final bool mine;

  /// Cap on the bubble, so long messages never reach the screen edge.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: mine ? c.bubbleMine : c.bubbleTheirs,
            border: mine ? null : Border.all(color: c.hairline),
            borderRadius: BorderRadius.only(
              topLeft: NexusLayout.bubble,
              topRight: NexusLayout.bubble,
              bottomLeft: mine ? NexusLayout.bubble : NexusLayout.bubbleTail,
              bottomRight: mine ? NexusLayout.bubbleTail : NexusLayout.bubble,
            ),
          ),
          child: Text(text, style: NexusType.bubble(c)),
        ),
      ),
    );
  }
}

/// The bottom pill: rounded input, and one filled purple button that is a mic
/// while the field is empty and the send arrow once there is something to send.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.hasText,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasText;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final focused = focusNode.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: NexusLayout.content),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'UI shell only — typing here does not reach the assistant.',
                  textAlign: TextAlign.center,
                  style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: const BorderRadius.all(NexusLayout.pill),
                  border: Border.all(
                    color: focused
                        ? c.accent.withValues(alpha: 0.55)
                        : c.hairline,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          style: NexusType.rowTitle(
                            c,
                          ).copyWith(fontSize: 15, fontWeight: FontWeight.w400),
                          cursorColor: c.accent,
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Message Nexus',
                            hintStyle: NexusType.hint(c),
                          ),
                          onSubmitted: (_) => onSend(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, animation) =>
                          ScaleTransition(
                            scale: animation,
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          ),
                      child: hasText
                          ? _RoundAction(
                              key: const ValueKey<String>('send'),
                              icon: Icons.arrow_upward_rounded,
                              tooltip: 'Send',
                              onTap: onSend,
                            )
                          : _RoundAction(
                              key: const ValueKey<String>('mic'),
                              icon: Icons.mic_rounded,
                              tooltip: 'Voice input',
                              onTap: () => nexusNotWired(context, 'Voice input'),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The filled purple circle: the only solid accent fill in the shell.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.accent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          splashColor: Colors.white.withValues(alpha: 0.2),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: c.onAccent),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

/// A device the Files tab can look at. Mock only.
class NexusMockDevice {
  const NexusMockDevice(this.name, this.detail, this.icon, {this.online = true});

  final String name;
  final String detail;
  final IconData icon;
  final bool online;
}

/// A row in the file list. Mock only.
class NexusMockFile {
  const NexusMockFile(this.name, this.size, this.date, this.icon);

  final String name;
  final String size;
  final String date;
  final IconData icon;
}

const List<NexusMockDevice> kNexusMockDevices = <NexusMockDevice>[
  NexusMockDevice('This Phone', 'Pixel · Android', Icons.smartphone_rounded),
  NexusMockDevice('My PC', 'Desktop · this room', Icons.desktop_windows_rounded),
  NexusMockDevice(
    'Studio Mac',
    'Laptop · last seen Oct 9',
    Icons.laptop_mac_rounded,
    online: false,
  ),
];

const List<NexusMockFile> kNexusMockFiles = <NexusMockFile>[
  NexusMockFile(
    'Downloads',
    'Folder · 6 items',
    'Today',
    Icons.folder_rounded,
  ),
  NexusMockFile(
    'report.pdf',
    '4.0 KB',
    'Oct 11',
    Icons.picture_as_pdf_rounded,
  ),
  NexusMockFile(
    'studio_shoot_01.jpg',
    '3.4 MB',
    'Oct 9',
    Icons.image_rounded,
  ),
  NexusMockFile(
    'mix_v3.wav',
    '48.2 MB',
    'Oct 4',
    Icons.graphic_eq_rounded,
  ),
  NexusMockFile(
    'session_archive.zip',
    '212 MB',
    'Sep 28',
    Icons.folder_zip_rounded,
  ),
  NexusMockFile(
    'voice_memos.m4a',
    '18.6 MB',
    'Sep 20',
    Icons.music_note_rounded,
  ),
];

/// The Drive-shaped files screen: pick a device, then read its list.
class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  NexusMockDevice _device = kNexusMockDevices.first;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusTabBody(
      title: 'Files',
      subtitle: 'Browse a device without copying anything.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: NexusDeviceSwitcher(
              devices: kNexusMockDevices,
              selected: _device,
              onSelected: (device) => setState(() => _device = device),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Row(
              children: <Widget>[
                // Both halves shrink rather than overflow: a long device name
                // (or a large text-size setting) shortens with an ellipsis.
                Expanded(
                  child: Text(
                    'Downloads · ${kNexusMockFiles.length} items',
                    style: NexusType.section(c),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'On ${_device.name}',
                    style: NexusType.rowMeta(c),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: kNexusMockFiles.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                thickness: 1,
                color: c.hairline,
                indent: 56,
              ),
              itemBuilder: (context, index) => NexusFileRow(
                file: kNexusMockFiles[index],
                onLongPress: () => _showFileActions(kNexusMockFiles[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The long-press placeholder: what will be offered once the file layer is
  /// real. Shown now so the gesture has somewhere to go.
  void _showFileActions(NexusMockFile file) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final c = sheetContext.ui;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.raised,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(file.name, style: NexusType.rowTitle(c)),
                const SizedBox(height: 2),
                Text(
                  '${file.size} · ${file.date}',
                  style: NexusType.rowMeta(c),
                ),
                const SizedBox(height: 14),
                Text(
                  'File actions are a placeholder in this shell.',
                  style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                for (final action in _fileActions)
                  NexusRow(
                    title: action.$2,
                    leading: NexusIconTile(action.$1, size: 36),
                    trailing: const NexusChevron(),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      nexusNotWired(context, action.$2);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

const List<(IconData, String)> _fileActions = <(IconData, String)>[
  (Icons.open_in_new_rounded, 'Open'),
  (Icons.send_outlined, 'Send to a device'),
  (Icons.edit_outlined, 'Rename'),
];

/// The pill-shaped device picker at the top of the Files tab.
class NexusDeviceSwitcher extends StatelessWidget {
  const NexusDeviceSwitcher({
    super.key,
    required this.devices,
    required this.selected,
    required this.onSelected,
  });

  final List<NexusMockDevice> devices;
  final NexusMockDevice selected;
  final ValueChanged<NexusMockDevice> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<NexusMockDevice>(
        tooltip: 'Switch device',
        position: PopupMenuPosition.under,
        onSelected: onSelected,
        itemBuilder: (menuContext) => <PopupMenuEntry<NexusMockDevice>>[
          for (final device in devices)
            PopupMenuItem<NexusMockDevice>(
              value: device,
              child: Row(
                children: <Widget>[
                  Icon(device.icon, size: 18, color: c.textMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(device.name, style: NexusType.rowTitle(c)),
                  ),
                  if (device.name == selected.name)
                    Icon(Icons.check_rounded, size: 16, color: c.accent),
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.hairline),
            borderRadius: const BorderRadius.all(Radius.circular(22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              NexusStatusDot(online: selected.online),
              const SizedBox(width: 9),
              Icon(selected.icon, size: 17, color: c.textMuted),
              const SizedBox(width: 7),
              Text(selected.name, style: NexusType.rowTitle(c)),
              const SizedBox(width: 4),
              Icon(Icons.expand_more_rounded, size: 18, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// One file row: tile, name, size and date, and the long-press affordance.
class NexusFileRow extends StatelessWidget {
  const NexusFileRow({super.key, required this.file, this.onLongPress});

  final NexusMockFile file;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return InkWell(
      onLongPress: onLongPress,
      onTap: onLongPress == null
          ? null
          : () => nexusNotWired(context, 'Opening ${file.name}'),
      borderRadius: const BorderRadius.all(NexusLayout.tile),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
        child: Row(
          children: <Widget>[
            NexusIconTile(file.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    file.name,
                    style: NexusType.rowTitle(c),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text('${file.size} · ${file.date}', style: NexusType.rowMeta(c)),
                ],
              ),
            ),
            Icon(Icons.more_horiz_rounded, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

/// The paired-devices screen: who is here, who is away, and how to add one.
class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusTabBody(
      title: 'Devices',
      subtitle: 'Paired directly, over your own network.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Paired'),
          for (final device in kNexusMockDevices) ...<Widget>[
            NexusRow(
              title: device.name,
              subtitle: device.detail,
              leading: NexusIconTile(device.icon),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    device.online ? 'Online' : 'Offline',
                    style: NexusType.rowMeta(c),
                  ),
                  const SizedBox(width: 8),
                  NexusStatusDot(online: device.online),
                ],
              ),
              onTap: () => nexusNotWired(context, 'Device details'),
            ),
            Divider(height: 1, thickness: 1, color: c.hairline, indent: 56),
          ],
          NexusRow(
            title: 'Pair a device',
            subtitle: 'Show a QR code, or plug in a cable',
            leading: const NexusIconTile(Icons.add_rounded),
            accentTitle: true,
            onTap: () => nexusNotWired(context, 'Pairing'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 26, 4, 0),
            child: Text(
              'Nothing about these devices is uploaded anywhere. Access '
              'between them stops the moment they are out of range.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// The settings screen: appearance, voice, privacy, and what this build is.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _wakeWord = true;
  bool _spokenReplies = false;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusTabBody(
      title: 'Settings',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Appearance'),
          NexusRow(
            title: 'Dark mode',
            subtitle: 'Neutral greys either way — purple stays for actions',
            leading: const NexusIconTile(Icons.dark_mode_outlined),
            trailing: Switch(
              value: widget.darkMode,
              onChanged: widget.onDarkModeChanged,
            ),
          ),
          NexusRow(
            title: 'Customization',
            subtitle: 'App icon — and what else you can change',
            leading: const NexusIconTile(Icons.tune_rounded),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const CustomizationPage(),
              ),
            ),
          ),
          const NexusSectionLabel('Voice'),
          NexusRow(
            title: 'Voice & speech',
            subtitle: 'Wake word, replies, voice',
            leading: const NexusIconTile(Icons.graphic_eq_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => _VoiceSettingsPage(
                  wakeWord: _wakeWord,
                  spokenReplies: _spokenReplies,
                  onWakeWordChanged: (value) {
                    setState(() => _wakeWord = value);
                  },
                  onSpokenRepliesChanged: (value) {
                    setState(() => _spokenReplies = value);
                  },
                ),
              ),
            ),
          ),
          const NexusSectionLabel('Privacy'),
          NexusRow(
            title: 'On-device model',
            subtitle: 'Runs here, not in a data centre',
            leading: const NexusIconTile(Icons.memory_rounded),
            trailing: Text('Loaded', style: NexusType.rowMeta(c)),
          ),
          NexusRow(
            title: 'Cloud sync',
            subtitle: 'No account, no server copy',
            leading: const NexusIconTile(Icons.cloud_off_outlined),
            trailing: Text('Off', style: NexusType.rowMeta(c)),
          ),
          const NexusSectionLabel('About'),
          const NexusRow(
            title: 'Build',
            subtitle: 'Front end only — no mesh, store or model attached',
            leading: NexusIconTile(Icons.info_outline_rounded),
            trailing: Text('UI shell preview'),
          ),
        ],
      ),
    );
  }

}

/// The one pushed page in the shell, so the back gesture has something real to
// ---------------------------------------------------------------------------
// Customization
// ---------------------------------------------------------------------------

/// One group on the Customization page: the section label and the rows under
/// it.
///
/// The page is a list of these rather than a hand-written column of widgets, so
/// the options still to come — accent colour, type, motion — arrive as one more
/// entry with a row each. The page's layout, its scrolling, the row anatomy and
/// the way a choice is stored all stay as they are.
@immutable
class NexusCustomizationSection {
  const NexusCustomizationSection({required this.label, required this.rows});

  /// The group's heading, e.g. "Launcher icon".
  final String label;

  /// The rows under it, in the order they are shown.
  final List<Widget> rows;
}

/// What each icon mode means, in the same words the row and the picker use.
String _iconModeMeaning(IconMode mode) => switch (mode) {
  IconMode.light => 'Always the light mark.',
  IconMode.dark => 'Always the dark mark.',
  IconMode.auto => 'Follows the system theme.',
};

/// Everything about how Nexus looks: what the Settings row of the same name
/// pushes to.
///
/// It is the one place in the shell wired to real behaviour — [IconService],
/// which stores the choice and tells Android which launcher alias to enable —
/// because the launcher mark lives in the app manifest and cannot be faked in
/// the UI layer. Every other setting on this page can be.
class CustomizationPage extends StatefulWidget {
  const CustomizationPage({super.key});

  @override
  State<CustomizationPage> createState() => _CustomizationPageState();
}

class _CustomizationPageState extends State<CustomizationPage> {
  /// The mode the row shows. Held here so a tap redraws the row at once; the
  /// truth still lives in [IconService].
  IconMode _iconMode = IconService.instance.mode;

  @override
  void initState() {
    super.initState();
    // The stored choice arrives asynchronously — it is a preference read — so
    // the row corrects itself from the settled service rather than staying on
    // the default it was first built with. attach() is idempotent, and it is
    // also what keeps Auto following the system theme while the app runs.
    unawaited(
      IconService.instance.attach().then((_) {
        if (mounted) setState(() => _iconMode = IconService.instance.mode);
      }),
    );
  }

  /// What the icon row says: the chosen mode, and the one platform that can act
  /// on it.
  String _iconSubtitle() {
    if (!IconService.instance.switchingSupported) {
      return 'Light, Dark or Auto — the launcher mark switches on Android.';
    }
    return _iconModeMeaning(_iconMode);
  }

  /// Every group on the page, in the order it is shown: adding an option is
  /// adding a section here and nothing else.
  List<NexusCustomizationSection> _sections() => <NexusCustomizationSection>[
    NexusCustomizationSection(
      label: 'Launcher icon',
      rows: <Widget>[
        NexusRow(
          title: 'App icon',
          subtitle: _iconSubtitle(),
          leading: const NexusIconTile(Icons.apps_outlined),
          trailing: _IconModeValue(mode: _iconMode),
          onTap: _chooseIcon,
        ),
      ],
    ),
  ];

  /// The icon picker: three choices, one tap. The choice goes to [IconService],
  /// which stores it and switches the launcher alias — this only reports the
  /// outcome, and says so plainly when Android refuses the switch or when this
  /// platform has no icon to switch.
  Future<void> _chooseIcon() async {
    final IconMode? chosen = await showModalBottomSheet<IconMode>(
      context: context,
      builder: (sheetContext) => _IconPicker(current: _iconMode),
    );
    if (chosen == null || !mounted) return;
    setState(() => _iconMode = chosen);
    await IconService.instance.setMode(chosen);
    if (!mounted) return;
    final String? failure = IconService.instance.failure;
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Icon not switched: $failure')));
    } else if (!IconService.instance.switchingSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved — the launcher mark switches on Android'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Customization')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          for (final section in _sections()) ...<Widget>[
            NexusSectionLabel(section.label),
            ...section.rows,
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
            child: Text(
              'Accent colour, type and motion join this page the same way — one '
              'row each.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The icon row's value: the mode in force, then the chevron that says the row
/// opens something.
class _IconModeValue extends StatelessWidget {
  const _IconModeValue({required this.mode});

  final IconMode mode;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(mode.label, style: NexusType.rowMeta(context.ui)),
        const NexusChevron(),
      ],
    );
  }
}

/// The icon picker: the three marks, the one in force ticked.
///
/// A sheet in the shell's own idiom, offering the same three choices, in the
/// same words, to the same [IconService] the row does; only the chrome is the
/// shell's.
class _IconPicker extends StatelessWidget {
  const _IconPicker({required this.current});

  /// The mode in force when the sheet opened.
  final IconMode current;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: c.raised,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('App icon', style: NexusType.rowTitle(c)),
            const SizedBox(height: 6),
            Text(
              'Android names the launcher icon in the app manifest: the switch '
              'takes effect at once, and the phone redraws it a moment later. '
              'Only Android can do this — the choice is remembered either way.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5, fontSize: 11.5),
            ),
            const SizedBox(height: 10),
            for (final mode in IconMode.values)
              NexusRow(
                title: mode.label,
                subtitle: _iconModeMeaning(mode),
                // The tick says which mark is in force to the eye; the
                // semantics label says it to a screen reader, which cannot see
                // a tick.
                semanticLabel: mode == current
                    ? '${mode.label}. ${_iconModeMeaning(mode)} Selected'
                    : '${mode.label}. ${_iconModeMeaning(mode)}',
                trailing: mode == current
                    ? Icon(Icons.check_rounded, size: 20, color: c.accent)
                    : null,
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
  }
}

/// The one pushed page in the shell, so the back gesture has something real to
/// do: the voice controls the Settings tab points at.
class _VoiceSettingsPage extends StatelessWidget {
  const _VoiceSettingsPage({
    required this.wakeWord,
    required this.spokenReplies,
    required this.onWakeWordChanged,
    required this.onSpokenRepliesChanged,
  });

  final bool wakeWord;
  final bool spokenReplies;
  final ValueChanged<bool> onWakeWordChanged;
  final ValueChanged<bool> onSpokenRepliesChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Voice & speech')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          NexusRow(
            title: 'Wake word',
            subtitle: 'Listen for “Hey Nexus” while the app is open',
            leading: const NexusIconTile(Icons.hearing_outlined),
            trailing: Switch(value: wakeWord, onChanged: onWakeWordChanged),
          ),
          NexusRow(
            title: 'Speak replies',
            subtitle: 'Read answers out loud when they arrive',
            leading: const NexusIconTile(Icons.volume_up_outlined),
            trailing: Switch(
              value: spokenReplies,
              onChanged: onSpokenRepliesChanged,
            ),
          ),
          NexusRow(
            title: 'Voice',
            subtitle: 'Used for both listening and speaking',
            leading: const NexusIconTile(Icons.record_voice_over_outlined),
            trailing: Text('Default', style: NexusType.rowMeta(c)),
            onTap: () => nexusNotWired(context, 'Voice picking'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
            child: Text(
              'Audio is processed on this device. Nothing is streamed to a '
              'server for recognition or synthesis.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
