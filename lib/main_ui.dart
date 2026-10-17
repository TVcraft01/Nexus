/// A fresh, self-contained UI shell for Nexus — the front end only.
///
/// This file is deliberately independent of everything already in `lib/`: it
/// imports no mesh, no store, no model, and no `lib/ui` widget. It is a shell
/// you can run by itself, look at, and then wire the real behaviour behind:
///
///     flutter run -t lib/main_ui.dart
///
/// It reaches for real code in four places, and each is a feature whose owner
/// lives outside the shell:
///   * `core/services/icon_service.dart`, from [CustomizationPage] — the
///     launcher mark is a manifest component, so the page that offers it talks
///     to its owner rather than to a mock of it.
///   * `core/mic_access.dart`, from the mic's first tap — the microphone
///     permission, asked once in the open, so a refusal can disable the button
///     and say why instead of arriving as silence.
///   * `core/speech.dart` — the phone's own recognizer, behind two ways in.
///     *Dictation* is the mic next to the field: a tap opens a listening
///     session and a second tap closes it, a hold listens for one utterance and
///     ends on the release. The words stream into the composer while they are
///     being spoken and then *stay* there as a draft — nothing is sent until the
///     user sends it. *Live conversation* is the button beside it: a dark,
///     full-screen page that listens the moment it opens, shows what was said in
///     large type, and then **stops** — the microphone is re-opened only by a
///     tap. See [_HomeTabState] for the session, [_HoldToTalk] for the gesture
///     that owns the hold, and [_LivePage] for the overlay.
///   * `core/ollama_service.dart` — the brain. A sent message and a finished
///     live turn both go to the small model running on the user's own PC, and
///     the page shows the answer when it arrives. Nothing here talks to a cloud
///     model, and a PC that cannot be reached says so in words instead of
///     going quiet (see [kNexusOllamaUnreachableText]).
///
/// Everything else on screen is still mock data: the two opening bubbles, the
/// file list, and the paired devices are the shell's own, not the mesh's.
///
/// What lives here:
///   * [NexusUiColors] / [NexusType] / [NexusLayout] — the design tokens.
///   * [NexusTheme] — Material 3 light and dark themes built from those tokens.
///   * [NexusUiApp] / [NexusShell] — the app root and the four-tab frame.
///   * [HomeTab], [FilesTab], [DevicesTab], [SettingsTab] — the four screens.
///   * [CustomizationPage] — what Settings pushes to: one row per look, the
///     App icon first.
///   * [PrivacyPage] — the other pushed page: what voice input does with the
///     audio, where a store review and a curious user both look for it.
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
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show LongPressGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:google_fonts/google_fonts.dart';

import 'core/ai_status.dart';
import 'core/local_ai_service.dart';
import 'core/mic_access.dart';
import 'core/ollama_service.dart';
import 'core/on_device_ai_service.dart';
import 'core/services/icon_service.dart';
import 'core/speech.dart';

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/// The one purple in the app: seed colour, active tab, mic/send, switches on.
const Color kNexusAccent = Color(0xFF773DDC);

/// How far a held finger may drift off the mic button and still mean "send
/// this": the button's own disc, plus a thumb's worth of slack.
///
/// Past that the finger has left the button, and leaving is a cancel — the
/// gesture everyone already knows from a voice note. The slack is generous on
/// purpose: a thumb rolls as it holds, and cancel-on-a-wobble would throw away
/// sentences the user meant to keep.
const double kNexusMicSlack = 24;

/// How long the finger has to stay down before the mic press is a hold instead
/// of a tap: under this it is a tap — dictate until told otherwise — and over
/// it the press is one utterance that ends when the finger comes up.
///
/// The boundary is what the whole interaction turns on, so it is named once,
/// here, and the long press that implements it is built with exactly this
/// deadline rather than the framework's half-second default: half a second of
/// drift is the difference between "stop listening" and "say something", and
/// the user cannot see which one they got while their thumb is still down.
const Duration kNexusMicHold = Duration(milliseconds: 250);

/// The key on the ring that pulses around the mic button while a session is
/// live — the recording indicator, and a compliance requirement rather than
/// decoration (Apple asks for a visible indicator; Google asks that it be
/// honest). It is on the ring so a test can prove it is on screen for the whole
/// of a session: nothing in this file may make it dismissible, auto-hiding, or
/// conditional on the field being empty.
const Key kNexusRecordingIndicator = Key('nexus-mic-recording-indicator');

/// The level meter in the composer while a dictation is open: the visible answer
/// to "is it hearing me right now?".
///
/// A key rather than a colour probe, so a test can hold the composer to having
/// the meter for the whole of every dictation session — in both its tap and its
/// hold form — and to having none once the microphone is closed.
const Key kNexusLevelBars = Key('nexus-level-bars');

/// How tall a bar stands at full voice, and how small it sits while the room is
/// quiet.
///
/// The small end is deliberately a *dot* rather than nothing: a meter that
/// vanished between words would read as a meter that had stopped working, and
/// the one thing it exists to say is whether the phone is hearing anything at
/// all. These are the ends of the scale, and they are here rather than in the
/// widget so a test can measure against the same numbers the screen uses.
const double kNexusBarMaxHeight = 24;
const double kNexusBarMinHeight = 3;

/// The live conversation overlay, its way out, and the recording badge inside
/// it — three keys because they answer three different questions: is the
/// immersive screen up, can it be left, and is the microphone honestly showing
/// that it is open on a page where the composer's ring is underneath it.
const Key kNexusLiveOverlay = Key('nexus-live-overlay');
const Key kNexusLiveClose = Key('nexus-live-close');
const Key kNexusLiveRecordingIndicator = Key('nexus-live-recording-indicator');

/// The large type in the middle of the live overlay: what was just heard.
const Key kNexusLiveText = Key('nexus-live-text');

/// The badge shown on the live page between turns, when the microphone is
/// closed. Its whole job is to be the opposite of the recording badge: a page
/// that went from "Recording" to nothing would leave the user unable to tell a
/// closed microphone from a paused animation.
const Key kNexusLivePausedIndicator = Key('nexus-live-paused-indicator');

/// The orb, and the same orb in its grey, still, microphone-closed form. Two
/// keys because "the microphone is closed" is the one thing this page must be
/// able to prove about itself, and colour is not something a widget test reads
/// as easily as a key.
const Key kNexusLiveOrb = Key('nexus-live-orb');
const Key kNexusLiveOrbIdle = Key('nexus-live-orb-idle');

/// The way back from a guard trip: live conversation stops listening rather
/// than looping for ever, and this is the one control that reopens the mic.
const Key kNexusLiveResume = Key('nexus-live-resume');

/// The sentence under the orb: the page's plain-language answer to "is the
/// microphone on?".
const Key kNexusLiveStatus = Key('nexus-live-status');

/// The orb while the answer is being written on the PC — blue and pulsing, so
/// "working on it" is never mistaken for "listening to you" or "stopped".
const Key kNexusLiveOrbThinking = Key('nexus-live-orb-thinking');

/// What both surfaces say while the model on the PC is being asked: the thread's
/// placeholder bubble and the live page's large type.
///
/// One constant for both because it is one state — the request is out, nothing is
/// recording, and the only thing that can happen next is an answer.
const String kNexusThinking = 'Nexus is thinking…';

/// The live overlay's own ground and ink.
///
/// Deliberately not the app's tokens: live conversation is a dark room the user
/// steps into, and it stays dark in light mode for the same reason a camera
/// viewfinder does — the screen is the subject, and a bright page around it
/// competes with the one thing the user is doing.
const Color kNexusLiveGround = Color(0xFF111113);

/// The "thinking" blue: the orb while the model on the PC is writing.
///
/// Blue rather than another purple on purpose — purple is the app's accent and
/// means *the microphone is open* everywhere else in this shell, and an orb that
/// stayed purple while the request was out would say exactly the wrong thing.
const Color kNexusLiveThinking = Color(0xFF3B82F6);
const Color kNexusLiveThinkingLight = Color(0xFF7EB0FF);
const Color kNexusLiveThinkingDeep = Color(0xFF1D4ED8);
const Color kNexusLiveInk = Color(0xFFF7F5FF);
const Color kNexusLiveInkMuted = Color(0xFFA79FC2);

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
        ColorScheme.fromSeed(
          seedColor: kNexusAccent,
          brightness: brightness,
        ).copyWith(
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
      textTheme: GoogleFonts.interTextTheme(base.textTheme)
          .apply(bodyColor: c.textStrong, displayColor: c.textStrong),
      extensions: <ThemeExtension<dynamic>>[c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: NexusType.rowTitle(c)
            .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accent.withValues(alpha: 0.18),
        selectionHandleColor: c.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.onAccent : c.surface,
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
        contentTextStyle: NexusType.rowMeta(c)
            .copyWith(color: c.background, fontSize: 13.5),
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

/// One line of the conversation on the Home tab.
///
/// Two of them are the shell's own opening lines; the rest are what the user
/// typed and what the model on their PC answered. A message is immutable once
/// placed — an answer *replaces* its placeholder in the list rather than editing
/// it — so what is on screen can always be read as the history of the thread
/// rather than as something still being written.
class NexusMockMessage {
  const NexusMockMessage(
    this.text, {
    this.mine = false,
    this.thinking = false,
    this.failed = false,
  });

  final String text;

  /// True for the user's side of the thread (right, grey, tail on the left).
  final bool mine;

  /// True for the placeholder bubble that stands where an answer will arrive:
  /// drawn muted and italic so a sentence that is still being thought about is
  /// never mistaken for one the assistant said.
  final bool thinking;

  /// True when this line is the shell explaining that it could not answer —
  /// not an answer. It is a different widget on screen (a red, bordered notice
  /// with a warning icon), it is never read out loud, and it never offers to be
  /// replayed; see [NexusErrorBubble].
  final bool failed;
}

/// How a listening session was opened, which is the whole difference between
/// the two gestures on the mic button.
///
/// * [continuous] — a tap. The microphone stays open until the next tap, so the
///   user can think between sentences; interim words collect in the field and
///   are still there when the session ends.
/// * [oneShot] — a hold. One utterance, ended by the release, with the words
///   that were heard left in the field for the user to send.
/// * [live] — the live conversation overlay. One turn at a time, each one ended
///   by the recognizer itself when the user stops speaking; the words go to the
///   overlay rather than to the field, and the next turn begins when the user
///   taps for it.
///
/// No mode ever sends, and only the *gesture* that opened a session can end it:
/// a tap's session is closed by a tap, a hold's by its release, and a live turn
/// by its recognizer or by the overlay closing.
enum _MicMode { continuous, oneShot, live }

/// The Claude-shaped home screen: a greeting, a short thread, and the composer
/// pinned at the bottom above the keyboard.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  final TextEditingController _message = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// Where the thread is scrolled to. The latest bubble is the one that matters
  /// — the user just sent it, or just got an answer to it — so every change to
  /// the thread is followed by a scroll to the end (see [_scrollToLatest]).
  /// Without it a phone-shaped screen leaves the new message below the fold and
  /// the reply looks like it never came.
  final ScrollController _threadScroll = ScrollController();

  /// The two layout-showing bubbles, plus anything typed and sent on top.
  final List<NexusMockMessage> _thread = <NexusMockMessage>[
    const NexusMockMessage(
      'Everything stays on your devices. Nothing here leaves the room.',
    ),
    const NexusMockMessage('What’s in my Downloads?', mine: true),
  ];

  /// How long a session may stay open without words from the recognizer.
  ///
  /// A guard, not a stopwatch: a live microphone must never outlive this
  /// without the user having done something. Thirty seconds is longer than any
  /// sentence this composer is for, and shorter than "the button is broken".
  ///
  /// It measures both modes the same way — a tap's session that nobody closes
  /// and a hold nobody releases both end here — because the thing it protects is
  /// the microphone being open, not the gesture that opened it.
  static const Duration _micTimeout = Duration(seconds: 30);

  /// The live session's number, or null when the microphone is closed.
  ///
  /// A number rather than a bool, because three things race to end a session —
  /// the finger, the guard above, and the recognizer's own answer — and a
  /// late answer has to be recognisable as belonging to a session nobody is
  /// waiting for any more. It lives in this state rather than in the button
  /// because the field rebuilds on every keystroke: a rebuild must never be
  /// able to lose the fact that the phone is listening to the room.
  int? _micSession;

  /// Session numbers, handed out in order and never reused.
  int _micSessions = 0;

  /// The microphone permission's answer: null until the first hold asks, true
  /// when it may be used, false when the user refused.
  ///
  /// Asked once and remembered for the session, because Android will not show
  /// the dialog a second time: a button that kept asking would silently do
  /// nothing, which is the failure this whole path exists to avoid.
  bool? _micAllowed;

  /// Why the microphone is not usable, when it is not. Set exactly when the ask
  /// came back refused, and shown wherever the button can carry a sentence.
  String? _micRefusal;

  /// True while the finger is down on the mic button.
  ///
  /// Separate from [_listening] on purpose: the ask for the microphone can be
  /// on screen for a second or two, and the finger can be gone by the time it
  /// is answered. Holding means "this gesture intends to talk", and a session
  /// is only opened while that is still true.
  bool _micHeld = false;

  /// How the live session was opened, or null when the microphone is closed.
  ///
  /// It is the whole difference between the two gestures, and it outlives the
  /// finger that started them: a *hold* is one utterance, so its release is what
  /// ends it and its words are the user's idea of the sentence; a *tap* opens
  /// the microphone until the next tap, so no release can end it and what the
  /// field has collected is whatever the user has said so far.
  _MicMode? _micMode;

  /// The live session's interim words. Subscribed when the session opens and
  /// cancelled when it ends, so nothing outlives the utterance that produced it.
  StreamSubscription<String>? _micPartials;

  /// How loud the microphone is hearing right now, as 0..1 for the bars.
  ///
  /// A notifier rather than `setState`, because the meter is the only thing that
  /// changes with it: rebuilding the thread and the composer twenty times a
  /// second to move five bars would be a repaint nobody asked for. It is reset
  /// to silence when a session ends, so no bar is ever left standing at the last
  /// reading of a microphone that is closed.
  final ValueNotifier<double> _micLevel = ValueNotifier<double>(0);

  /// The loudness readings for the live session, cancelled with the words it
  /// came in.
  StreamSubscription<double>? _micRms;

  /// The one microphone ask in flight, if there is one.
  ///
  /// A second gesture arriving while the system dialog is still on screen
  /// shares this ask instead of opening a second one: Android will not show the
  /// dialog twice, so a second ask is a call that answers nothing, and the
  /// button would look broken at exactly the moment the user is answering it.
  Future<bool>? _micAsking;

  /// True while the live conversation overlay is on screen.
  ///
  /// It is this state's rather than the overlay's because the microphone is the
  /// composer's: the overlay is one more surface onto the same session machine,
  /// not a second recognizer with a life of its own. That is what makes the
  /// background rule, the one permission ask and the guard hold for live mode
  /// without being written twice.
  bool _liveOpen = false;

  /// What the page shows while the microphone is closed: [waiting] after a turn
  /// that was heard, [guarded] after one the 30-second guard swept up.
  ///
  /// It is the reason, not a mode: the microphone is closed in both, the orb is
  /// grey in both, and the only way out of either is [_liveResume]. Nothing
  /// counts down here — live conversation has no timer at all, which is what
  /// makes "the mic is on if and only if the page says Listening" a fact about
  /// the code rather than a promise about it.
  _LivePhase _liveIdle = _LivePhase.waiting;

  /// True while the model is being asked for an answer: the microphone is
  /// closed, the orb is blue, and the page is waiting on a future rather than
  /// on the user.
  bool _liveThinking = false;

  /// True once the answer has started arriving: the orb is still working, but
  /// the large type is the answer growing rather than "Thinking…".
  bool _liveAnswering = false;

  /// The part of the answer that has arrived, in the order the model said it.
  String _liveAnswerText = '';

  /// Which live turn is current, counted so an answer can be dropped.
  ///
  /// The same idea as [_micSessions]: a request is part of the turn that made
  /// it, and a reply that arrives after the user has closed the page or started
  /// the next turn belongs to nobody. Without this, a slow PC could answer into a
  /// page that had already moved on.
  int _liveTurns = 0;

  /// Whether the live turn in flight has heard a voice at all.
  ///
  /// The silence that ends a turn only counts *after* speech: a page that opened
  /// onto a quiet room must wait for the user, not hand an empty utterance to
  /// the recognizer a second later. Reset by [_liveTurn] and set by a loud
  /// reading or an interim word.
  bool _liveVoice = false;

  /// The pause after speech, counting down to the end of the turn, or null when
  /// the room is still talking. Restarted by every word and every loud reading
  /// (see [_noteLiveSound]), so it only ever fires on a speaker who stopped.
  Timer? _liveQuiet;

  /// Whether the turn in flight has already asked the recognizer for its
  /// transcript. One ask per turn: a second `finish` on a recognizer that is
  /// already finishing is a call nobody answers.
  bool _liveFinished = false;

  /// What the live overlay is showing: the words captured so far, and the guess
  /// arriving right now.
  ///
  /// The partial is drawn in place of the captured sentence while it is being
  /// spoken, so the user watches their own words form in large type rather than
  /// waiting for a silent screen to decide. It is cleared when the turn ends.
  String _liveSaid = '';
  String _livePartial = '';

  /// The route the overlay is pushed as, so this state can take it down when the
  /// microphone ends for a reason the user did not tap (see [_closeLive]).
  PageRoute<void>? _liveRoute;

  /// The overlay's view of the session, pushed to the page that is already on
  /// screen. The page is a route above this tab, so `setState` here cannot
  /// rebuild it; the notifier is the one wire across that boundary.
  final ValueNotifier<_LiveState> _live = ValueNotifier<_LiveState>(
    const _LiveState(
      phase: _LivePhase.waiting,
      partial: '',
      said: '',
      answer: '',
    ),
  );

  /// True while a session is live: exactly what the button reads.
  bool get _listening => _micSession != null;

  /// Which brain would answer right now, for the one line above the composer.
  /// Null until the first check lands; the note says something true either way.
  AiStatus? _brain;

  /// What the composer says the answer comes from: the same three states the
  /// Settings row reports, said in the second person. The line used to promise
  /// the PC — which was true when the PC was the only brain, and became a lie
  /// the moment the model was on the phone.
  String get _brainNote => switch (_brain?.source) {
    AiSource.onDevice => 'This device answers — nothing here goes to a cloud.',
    AiSource.pc => 'Your PC answers — nothing here goes to a cloud.',
    _ => 'Your own devices answer — nothing here goes to a cloud.',
  };

  Future<void> _readBrain() async {
    final AiStatus status = await AiStatus.detect();
    if (mounted) setState(() => _brain = status);
  }

  @override
  void initState() {
    super.initState();
    // Two rebuild triggers: the trailing button swaps mic ⇄ send with the
    // text, and the pill's outline lights up while the field has focus.
    _message.addListener(_onChanged);
    _focus.addListener(_onChanged);
    // Where the answers come from: one file check and one HTTP probe, read once
    // when the screen opens rather than per message.
    unawaited(_readBrain());
    // The microphone is only ever open while this app is on screen, and this is
    // what makes that true rather than hoped for: Android and Apple both treat a
    // recognizer running behind a backgrounded app as a violation, and this app
    // has no business listening to a room it was not asked about.
    WidgetsBinding.instance.addObserver(this);
  }

  /// The screen left the foreground, or came back to it.
  ///
  /// Anything other than `resumed` means the user is no longer looking at the
  /// composer, so a live session ends here and now: `inactive` is the app losing
  /// focus (the shade, a dialog, another window), `paused` is it going away. The
  /// stop keeps whatever was heard in the field, because a phone call arriving
  /// mid-sentence is not the user cancelling their sentence.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    // The live overlay goes with the session that opened it: leaving the app is
    // the end of the conversation as far as this phone is concerned, and coming
    // back to a dark page that has silently stopped listening would be a worse
    // answer than the composer.
    if (_liveOpen) {
      _closeLive(reason: 'background');
      return;
    }
    if (_listening) _stopListening(reason: 'background');
  }

  /// Whether this app is in the foreground, which is the only place a
  /// microphone may be opened from.
  ///
  /// A platform that has not reported a lifecycle state yet (the first frame, a
  /// widget test, a desktop window) is not the background: refusing to listen
  /// there would break the button on the strength of a fact nobody has stated.
  /// A state that *is* reported, and is not `resumed`, is the background — by
  /// then the observer above has already ended any session anyway.
  bool get _inForeground {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // The screen going away must not leave the microphone open behind it, so an
    // utterance still in flight is taken back. Only this screen's own session
    // is stopped — an idle stop would end somebody else's.
    //
    // The session itself is closed by the answer or the guard that follows in
    // [_listen], which is also where its `mic:stop` line comes from — so this
    // stays a one-line release rather than a second place that has to remember
    // to log. And it cannot repaint: a disposed element throws on setState.
    if (_listening) unawaited(SpeechInput.current.stop());
    _live.dispose();
    _micLevel.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Streams that deliver after this are quiet here, so these need none of the
    // mounted checks the live paths carry.
    unawaited(_micPartials?.cancel());
    _micPartials = null;
    unawaited(_micRms?.cancel());
    _micRms = null;
    _liveQuiet?.cancel();
    _liveQuiet = null;
    _message
      ..removeListener(_onChanged)
      ..dispose();
    _focus
      ..removeListener(_onChanged)
      ..dispose();
    _threadScroll.dispose();
    super.dispose();
  }

  bool get _hasText => _message.text.trim().isNotEmpty;

  /// Sends the draft: the user's bubble, a placeholder for the answer, and the
  /// request to the model on the PC.
  ///
  /// The placeholder goes in on the same frame as the user's own bubble, so the
  /// thread never has a moment where the message appears to have been swallowed
  /// — the wait is *shown*, in a muted bubble that says what is happening, and
  /// then replaced by the answer or by the reason there isn't one.
  ///
  /// Nothing about this blocks: no spinner over the composer, no disabled send
  /// button, and the user can type the next message while this one is out. Each
  /// send owns the index of its own placeholder, so two answers in flight can
  /// never land in each other's bubble.
  void _send() {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _thread.add(NexusMockMessage(text, mine: true));
      _thread.add(const NexusMockMessage(kNexusThinking, thinking: true));
      _message.clear();
    });
    _focus.unfocus();
    _scrollToLatest();
    unawaited(_answer(text, _thread.length - 1));
  }

  /// Puts the newest line of the thread on screen, once the frame that added it
  /// has been laid out.
  ///
  /// The callback is what makes the target correct: `maxScrollExtent` is the
  /// height of the content as laid out, and before the frame it is still the
  /// height of the thread without the bubble that is being added. Waiting a
  /// frame costs nothing the user can see, and it is the difference between
  /// scrolling to the end of the old thread and the end of the new one.
  ///
  /// A failure to scroll is not worth reporting: a thread shorter than the
  /// screen has nothing to scroll, and an animation that arrives after the tab
  /// has gone has no controller to move.
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_threadScroll.hasClients) return;
      final ScrollPosition position = _threadScroll.position;
      final double end = position.maxScrollExtent;
      if ((end - position.pixels).abs() < 1) return;
      unawaited(
        _threadScroll.animateTo(
          end,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  /// Waits for the answer and puts it where the placeholder was.
  ///
  /// A failure is not an exception on its way to a crash reporter: it is a
  /// sentence in the thread, because the user is looking at a chat and the one
  /// thing they can act on is "there is no brain behind this". [OllamaException]
  /// already carries that sentence; anything else — a bug in the seam, a future
  /// that completed in a way nobody planned — is reported as the same
  /// unreachable message rather than as a stack trace on somebody's phone.
  ///
  /// The failure is a [NexusErrorBubble] and not a reply: it is red, it is not
  /// spoken, and it cannot be replayed, because it is the shell talking about
  /// itself rather than the assistant answering.
  Future<void> _answer(String prompt, int index) async {
    final StringBuffer buffer = StringBuffer();
    // Whether any of the answer has been shown yet: until it has, the bubble is
    // still the placeholder and may be replaced under us; after it has, the
    // words on screen are this turn's.
    bool shown = false;
    bool failed = false;
    try {
      await for (final String piece
          in LocalAiService.current.generateResponseStream(prompt)) {
        // The screen may be gone, and the bubble may have been answered
        // already by a seam that resolved twice: a replaced bubble is left
        // alone.
        if (!mounted || index >= _thread.length) return;
        if (!shown && !_thread[index].thinking) return;
        shown = true;
        buffer.write(piece);
        // A half-written answer is a placeholder, not a reply: the words are
        // on screen as they arrive, and the copy/speaker row waits for the
        // sentence to be whole. See [NexusChatBubble.thinking].
        setState(
          () => _thread[index] = NexusMockMessage(
            buffer.toString(),
            thinking: true,
          ),
        );
        _scrollToLatestSoon();
      }
    } on OllamaException catch (error) {
      _appendFailure(buffer, error.message);
      failed = true;
    } on OnDeviceAiException catch (error) {
      // The model stopped mid-answer: the words it managed are kept, and the
      // sentence that says so is what the bubble ends with.
      _appendFailure(buffer, error.message);
      failed = true;
    } catch (_) {
      _appendFailure(buffer, kNexusOllamaUnreachableText);
      failed = true;
    }
    if (!mounted || index >= _thread.length) return;
    String reply = buffer.toString();
    if (reply.isEmpty) {
      // Nothing at all came back and nothing threw: a brain that answered with
      // silence is not an answer, and the user is owed the notice.
      reply = kNexusOllamaUnreachableText;
      failed = true;
    }
    setState(() => _thread[index] = NexusMockMessage(reply, failed: failed));
    _scrollToLatest();
    // The answer is spoken once it is whole, which is what makes the assistant a
    // companion rather than a screen: the user asked out loud, so the reply
    // comes back out loud too. It never blocks the thread and never throws —
    // a device with no speech engine just leaves the words on the bubble. A
    // failure is never spoken: a machine apologising for itself is noise, and a
    // truncated sentence read aloud is worse than one that is read.
    if (!failed) unawaited(SpeechOutput.current.speak(reply));
  }

  /// Appends a failure sentence to what has been streamed so far.
  ///
  /// The separator only exists when there is something to separate: a failure
  /// before the first token leaves the notice standing alone, which is exactly
  /// what it looked like before streaming.
  void _appendFailure(StringBuffer buffer, String sentence) {
    if (buffer.isNotEmpty) buffer.write('\n\n');
    buffer.write(sentence);
  }

  /// When the answer was last followed down the thread, for [_scrollToLatestSoon].
  DateTime _lastStreamScroll = DateTime.fromMillisecondsSinceEpoch(0);

  /// Follows a streaming answer, but not once per token: an animation started
  /// forty times a second is not a scroll, it is a stutter.
  void _scrollToLatestSoon() {
    final DateTime now = DateTime.now();
    if (now.difference(_lastStreamScroll) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastStreamScroll = now;
    _scrollToLatest();
  }

  /// One listening session, opened the way the gesture asked for: a tap leaves
  /// the microphone open until the next tap, a hold wants one utterance that
  /// ends when the finger comes up.
  ///
  /// Words never send themselves. Whatever the session produces — the
  /// recognizer's final transcript, or the interim guesses [_watchPartials] has
  /// already written — is a *draft* in the field, and the send arrow is what
  /// turns a draft into a message. That is the difference from the voice note
  /// this replaced: there the release was the send, and the only chance to read
  /// the sentence back was while the thumb was still down on it.
  ///
  /// The finger decides when the utterance is over; the recognizer decides what
  /// was in it. So this waits for the sentence it hands over — but never
  /// unconditionally: the wait is guarded by [_micTimeout], and every way out of
  /// here closes the session before it does anything else, so the button can
  /// never be left saying "listening".
  ///
  /// Nothing is heard and nothing happens: a mis-hear, a hold that caught no
  /// words, a finger that left the button before it came up, a refused
  /// microphone and a device with no recognizer all arrive here as the same
  /// null, and none of them is worth a card — the thread stays as it was.
  ///
  /// What the phone hears is written verbatim. It is *not* run through the
  /// assistant's `spokenToWritten` repair yet, because nothing in this shell
  /// parses commands: that repair exists to make "report dot pdf" readable to
  /// the file grammar, and there is no grammar here to read it.
  Future<void> _listen(_MicMode mode) async {
    if (_listening) return;
    // No microphone from the background, ever: the only states a session opens
    // in are the ones where the user is looking at the button they pressed.
    if (!_inForeground) return;
    final speech = SpeechInput.current;
    if (!speech.available) return; // the button is inert in this case
    // The keyboard goes with the microphone's arrival. The field is read-only
    // for the length of the session, but a field that is still *focused* still
    // holds an open input connection, and a keyboard left standing over the
    // listening layout is half the screen the user needs to read what is being
    // heard. Unfocusing closes the connection too, so keys typed at a stale IME
    // have nothing to land on. The caret comes back with the draft: the words
    // are editable again the moment Stop or X ends the session (see
    // [_Composer], whose field is read-only for exactly this window).
    _focus.unfocus();
    final int session = ++_micSessions;    setState(() {
      _micSession = session;
      _micMode = mode;
    });
    _logMic('mic:start ${_stamp()} mode=${mode.name}');
    _watchPartials(session);
    _watchLevel(session);
    // The overlay draws its own state, and it is a route above this tab: it can
    // only be told about the session through the notifier.
    _syncLive();
    try {
      String? heard;
      try {
        heard = await speech.listen().timeout(_micTimeout);
      } on TimeoutException {
        // The recognizer went quiet without answering and the guard has run
        // out. The microphone is released on the platform side too, because
        // nothing else will.
        final bool timedOut = _endMic(session, 'timeout');
        // A live turn that missed the guard is not restarted: a recognizer that
        // ignored a whole turn is not one to hand the microphone back to a
        // moment later, and a silent loop would look exactly like the phone
        // listening when nobody asked it to. The page stays, stops saying it is
        // recording, and offers the one thing that is true — a tap to continue.
        if (timedOut && mode == _MicMode.live && mounted) _liveGuardTripped();
        return;
      } catch (_) {
        final bool failed = _endMic(session, 'error');
        if (failed && mode == _MicMode.live && mounted) _closeLive();
        return;
      }
      final String text = heard?.trim() ?? '';
      // `empty` is the recognizer closing the session on its own: Android
      // answers null both for silence and for its own no-match error, and from
      // here they are one ending — the button goes back to the mic and the words
      // already on screen are left where the user can read and edit them.
      final bool ended = _endMic(session, text.isEmpty ? 'empty' : 'final');
      // A transcript from a session the user already ended is nobody's: dropped,
      // not written. A cancelled utterance must never write words into a field.
      if (!ended || !mounted) return;
      // Live conversation has its own page and its own next turn; nothing it
      // hears is ever typed into the composer underneath it.
      if (mode == _MicMode.live) {
        _onLiveHeard(text);
        return;
      }
      if (text.isEmpty) return;
      _message.text = text;
    } finally {
      // The guarantee the button rests on. Every path above has already closed
      // its session; this is for the one that returns early, and for the one a
      // later edit might introduce — no exit may leave the session open.
      if (_micSession == session) _endMic(session, 'error');
    }
  }

  /// The recognizer's interim words for the session [session], written into the
  /// field as they arrive, so the sentence is on screen while it is still being
  /// spoken rather than only when it is over.
  ///
  /// Every write is checked against the session token. A partial can be in
  /// flight when the session ends, and a guess from a session nobody is holding
  /// any more must never land in a field that belongs to the next one — the
  /// words would then be attributed to whoever holds the button now.
  void _watchPartials(int session) {
    unawaited(_micPartials?.cancel());
    _micPartials = SpeechInput.current.partials.listen((String heard) {
      if (!mounted || _micSession != session) return;
      final String text = heard.trim();
      if (text.isEmpty) return;
      _logMic('mic:partial $text');
      if (_micMode == _MicMode.live) {
        // The overlay is the field in live mode: the words being guessed go to
        // the big type in the middle of it, and the composer behind it stays
        // exactly as the user left it.
        //
        // A word is also evidence that the turn has a voice in it, and it pushes
        // the end of the turn back: a speaker who is still being heard cannot be
        // finished off by the pause between two sentences.
        _noteLiveWord(session);
        setState(() => _livePartial = text);
        _syncLive();
        return;
      }
      _message.text = text;
    });
  }

  /// The recognizer's loudness readings for the session [session], forwarded to
  /// the meter as they arrive.
  ///
  /// Same session token as the words, for the same reason: a reading still in
  /// flight when the session ends belongs to a closed microphone, and a bar that
  /// moved on it would be the meter claiming the phone is hearing something the
  /// user has already stopped saying.
  void _watchLevel(int session) {
    unawaited(_micRms?.cancel());
    _micRms = SpeechInput.current.rms.listen((double db) {
      if (!mounted || _micSession != session) return;
      _micLevel.value = rmsToLevel(db);
      if (_micMode == _MicMode.live) _noteLiveSound(session, db);
    });
  }

  /// The turn has heard a voice: the microphone is open, the user is talking,
  /// and the pause that ends the turn starts again from here.
  ///
  /// Called for an interim word and for a reading above [kSpeechVoiceDb]. Both
  /// are the same fact from two channels — the recognizer understanding and the
  /// microphone hearing — and either one is enough to prove the room is not
  /// silent.
  void _noteLiveWord(int session) {
    if (!mounted || _micSession != session || _micMode != _MicMode.live) return;
    _liveVoice = true;
    _liveQuiet?.cancel();
    _liveQuiet = null;
  }

  /// One loudness reading, in the live turn [session]: either the room has a
  /// voice in it (see [_noteLiveWord]) or it has gone quiet, which starts the
  /// pause that ends the turn.
  ///
  /// Between the two thresholds nothing happens at all. A single number is a
  /// noisy thing to decide a sentence on, and the gap between [kSpeechVoiceDb]
  /// and [kSpeechQuietDb] is what stops a desk fan, a door, or the phone's own
  /// speaker from being read as the beginning or the end of speech.
  void _noteLiveSound(int session, double db) {
    if (db >= kSpeechVoiceDb) {
      _noteLiveWord(session);
      return;
    }
    if (db > kSpeechQuietDb) return;
    _armLiveSettle(session);
  }

  /// Starts the pause after speech, if it is not already running.
  ///
  /// Only a turn that has heard a voice may end on silence, only once per turn,
  /// and only while it is still the live session — the same token every other
  /// late arrival in this file is checked against.
  void _armLiveSettle(int session) {
    if (!mounted || _micSession != session || _micMode != _MicMode.live) return;
    if (!_liveVoice || _liveFinished || _liveQuiet != null) return;
    _liveQuiet = Timer(kSpeechTurnGap, () {
      _liveQuiet = null;
      if (!mounted || _micSession != session) return;
      if (_micMode != _MicMode.live || _liveFinished) return;
      _liveFinished = true;
      // Live conversation's missing end-of-turn, in one line: ask the recognizer
      // for the transcript it has been holding. Without this the page waits for
      // a final result the phone may never send on its own — the failure the
      // first on-device run of live mode hit, where the words were heard, the
      // page showed them forming, and no answer ever came.
      _logMic('mic:settle ${_stamp()}');
      unawaited(SpeechInput.current.finish());
    });
  }

  /// The finger has been down on the mic for [kNexusMicHold]: this press is a
  /// hold, so it means one utterance, and its release is what ends it.
  ///
  /// The ask still comes first and still blocks the session, so a refusal can
  /// never be mistaken for a quiet room. The second check is the press still
  /// being a press: the ask can sit on screen for a moment, and if the finger is
  /// gone by then there is nothing left holding the button, so nothing opens.
  ///
  /// A hold never touches a session a tap opened, and that is why [_micHeld] is
  /// left alone in the first line: the release of a press that opened nothing
  /// finds no hold in flight and is a no-op, rather than the end of the user's
  /// continuous session.
  Future<void> _micHoldStart() async {
    if (_micHeld || _listening) return;
    // The button is the send arrow: this press is not talking, and its release
    // must not read as ending an utterance either — which is why the flag below
    // is set after this line and not before it.
    if (_hasText) return;
    _micHeld = true;
    if (!_micUsable) return; // the button is inert in this case
    if (!await _ensureMicAllowed()) return;
    if (!_micHeld || !mounted) return; // released while the ask was on screen
    await _listen(_MicMode.oneShot);
  }

  /// The tap: open the microphone, or close the session it opened.
  ///
  /// One gesture and two meanings, decided by what is already happening rather
  /// than by where the finger is — the toggle every recorder has, and the reason
  /// this composer no longer needs a hint to explain the button.
  void _micTap() {
    if (_listening) {
      // The words already streamed into the field are the user's, so a stop
      // keeps them: it ends the listening, not the sentence.
      _stopListening();
      return;
    }
    if (!_micUsable) return; // the note line already says why not
    unawaited(_micTapStart());
  }

  /// The tap's opening half: ask if it has to, then listen until the next tap.
  ///
  /// The ask can be on screen for a moment, and a hold can arrive while it is:
  /// whichever gesture gets there first owns the session, and the other finds
  /// [_listening] already true and leaves it alone.
  Future<void> _micTapStart() async {
    if (!await _ensureMicAllowed()) return;
    if (!mounted || _listening) return;
    await _listen(_MicMode.continuous);
  }

  /// The finger came up on a hold.
  ///
  /// Still on the button means the utterance is over and its words are wanted,
  /// so the recognizer is asked to hand over its transcript instead of throwing
  /// it away — and that transcript goes into the field, one tap short of being
  /// sent. Anywhere else means the gesture was abandoned, and abandoning it
  /// throws the utterance away: nothing is written, and the field is cleared of
  /// the guesses that were streaming into it.
  void _micHoldEnd(bool cancelled) {
    if (!_micHeld) return;
    _micHeld = false;
    // No session means nothing was ever started — a refused microphone, or a
    // release that got in before the ask was answered.
    if (!_listening) return;
    if (cancelled) {
      _stopListening(reason: 'cancelled');
      return;
    }
    // Release *is* the end of the utterance: the recognizer is asked to hand
    // over what it heard rather than to throw it away, and [listen] answers
    // with that transcript a moment later, which is what fills the field.
    _logMic('mic:release ${_stamp()}');
    unawaited(SpeechInput.current.finish());
  }

  /// Opens live conversation: the keyboard goes, the dark page comes up, and the
  /// microphone opens on the same frame the user can see the orb breathing.
  ///
  /// It is refused while a dictation session is already open, because the
  /// composer's mic owns the microphone and two sessions cannot share it. The
  /// button is drawn inert for that reason rather than this check earning its
  /// keep on its own — the check is the rule, the button is the hint.
  Future<void> _openLive() async {
    if (_liveOpen || _listening || !_micUsable || !_inForeground) return;
    // The overlay is the way out of the keyboard: live conversation is a page to
    // look at, and a keyboard sliding back over it would be the wrong answer to
    // the tap that hid it.
    _focus.unfocus();
    if (!await _ensureMicAllowed()) return;
    if (!mounted || _liveOpen || _listening) return;
    setState(() {
      _liveOpen = true;
      _liveIdle = _LivePhase.waiting;
      _liveThinking = false;
      _liveAnswering = false;
      _liveSaid = '';
      _liveAnswerText = '';
      _livePartial = '';
    });
    _syncLive();
    _pushLive();
    unawaited(_liveTurn());
  }

  /// One turn of live conversation: listen, and let the recognizer decide when
  /// the sentence is over.
  ///
  /// There is no finger here to release and no second tap, so the end of the
  /// turn is the recognizer's own end-of-speech — the same event that closes a
  /// dictation session as `empty`. Everything after it (the pause, the next
  /// turn, the close of the overlay) is [_onLiveHeard].
  Future<void> _liveTurn() async {
    if (!_liveOpen || _listening) return;
    if (!_inForeground) {
      _closeLive(reason: 'background');
      return;
    }
    // Every route back to a live microphone passes through here, and the state
    // of the last turn is cleared on the way: the next turn is one the user
    // asked for, it starts with nothing said, and any answer still in flight
    // from the turn before it is now nobody's.
    //
    // The end-of-turn detector starts fresh with it: this turn has not heard a
    // voice yet, has not asked for a transcript, and has no pause running.
    _liveQuiet?.cancel();
    _liveQuiet = null;
    _liveVoice = false;
    _liveFinished = false;
    _liveTurns++;
    if (mounted) {
      setState(() {
        _liveIdle = _LivePhase.waiting;
        _liveThinking = false;
        _liveAnswering = false;
        _liveSaid = '';
        _liveAnswerText = '';
        _livePartial = '';
      });
    } else {
      _liveIdle = _LivePhase.waiting;
      _liveThinking = false;
    }
    await _listen(_MicMode.live);
  }

  /// The guard ended a live turn: the microphone is closed and it stays closed.
  ///
  /// The page is deliberately not closed with it. An overlay that vanished after
  /// thirty silent seconds would look like the app had crashed or the user had
  /// been kicked out; an overlay that stopped breathing, went grey, said the mic
  /// was off and offered a tap to continue says exactly what happened. Nothing is
  /// started here — relearning the microphone is the user's decision.
  void _liveGuardTripped() {
    if (!_liveOpen || !mounted) return;
    setState(() {
      _liveIdle = _LivePhase.guarded;
      _liveThinking = false;
      _liveAnswering = false;
      _livePartial = '';
    });
    _syncLive();
  }

  /// The tap that opens a live turn — the only way one ever opens after the
  /// first, whether the last one was heard or swept up by the guard.
  ///
  /// Refused while an answer is on its way: the user tapping a *thinking* orb is
  /// asking to interrupt a request that is already out, and the honest answer is
  /// to let it finish and then show what it said.
  void _liveResume() {
    if (!_liveOpen || _listening || _liveThinking || _liveAnswering) return;
    unawaited(_liveTurn());
  }

  /// A live turn ended with [text] — or with nothing, when the room was quiet.
  ///
  /// The microphone closes here and stays closed until a tap: the old version
  /// restarted itself after a pause, which on real hardware looked exactly like
  /// an app recording a room nobody had asked about. What happens next depends on
  /// whether there is anything to answer. A quiet turn has nothing to send, so it
  /// lands straight in [waiting] with the previous sentence still on screen. A
  /// turn with words in it goes to [thinking] while the PC is asked, and the
  /// answer — or the reason there isn't one — replaces the large type when it
  /// arrives, in [_liveAnswer].
  void _onLiveHeard(String text) {
    if (!_liveOpen || !mounted) return;
    final String prompt = text.trim();
    setState(() {
      _livePartial = '';
      _liveIdle = _LivePhase.waiting;
      _liveThinking = prompt.isNotEmpty;
      if (prompt.isNotEmpty) _liveSaid = prompt;
    });
    _syncLive();
    if (prompt.isEmpty) return;
    unawaited(_liveAnswer(prompt, _liveTurns));
  }

  /// Asks the model on the PC and puts its answer on the page.
  ///
  /// The wait is a state of the page, not a spinner on top of it: the orb goes
  /// blue and pulses, the text says [kNexusThinking], and the microphone is
  /// closed for the whole of it. When the answer comes it takes the large type,
  /// and the page drops into [waiting] — grey orb, "tap to continue" — whether
  /// the answer was words or a sentence about the PC being unreachable. A failure
  /// is information the user needs, not something to hide behind a state that
  /// looks like listening.
  Future<void> _liveAnswer(String prompt, int turn) async {
    final StringBuffer buffer = StringBuffer();
    // Only a sentence the model actually said is read out loud. The unreachable
    // notice is the shell talking, and hearing a machine apologise for its PC is
    // worse than reading it.
    bool spoken = true;
    try {
      await for (final String piece
          in LocalAiService.current.generateResponseStream(prompt)) {
        // Dropped when the page is gone or the user has already moved on: an
        // answer belongs to the turn that asked for it.
        if (!mounted || !_liveOpen || turn != _liveTurns) return;
        buffer.write(piece);
        // The words are the page now: the orb keeps its working colour while
        // the answer is being written, but the large type shows the answer
        // arriving instead of leaving the screen on "Thinking…".
        setState(() {
          _liveAnswering = true;
          _liveAnswerText = buffer.toString();
        });
        _syncLive();
      }
    } on OllamaException catch (error) {
      buffer.write(buffer.isEmpty ? error.message : '\n\n${error.message}');
      spoken = false;
    } on OnDeviceAiException catch (error) {
      buffer.write(buffer.isEmpty ? error.message : '\n\n${error.message}');
      spoken = false;
    } catch (_) {
      buffer.write(
        buffer.isEmpty
            ? kNexusOllamaUnreachableText
            : '\n\n$kNexusOllamaUnreachableText',
      );
      spoken = false;
    }
    if (buffer.isEmpty) {
      buffer.write(kNexusOllamaUnreachableText);
      spoken = false;
    }
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    setState(() {
      _liveThinking = false;
      _liveAnswering = false;
      _liveIdle = _LivePhase.waiting;
      _liveSaid = buffer.toString();
      _liveAnswerText = '';
    });
    _syncLive();
    // The answer is said once it is whole, and the page is already in the grey
    // "tap to continue" state by the time the voice starts: what the user sees
    // is the reply they can read, and what they hear is the same reply —
    // neither of which is a microphone that could still be open.
    if (spoken) unawaited(SpeechOutput.current.speak(buffer.toString()));
  }

  /// Pushes the overlay and keeps a handle on it.
  ///
  /// The route is the one surface in this file that is not built by this state,
  /// so two things are wired here: the state notifier the page listens to, and
  /// the way back. A route the platform takes away (the system back gesture) is
  /// a close like any other — the microphone must always go with the page that
  /// was showing it.
  void _pushLive() {
    final PageRoute<void> route = PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'live-conversation'),
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondary,
      ) => _LivePage(
        state: _live,
        onClose: _closeLive,
        onResume: _liveResume,
        level: _micLevel,
      ),
      transitionsBuilder: (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondary,
        Widget child,
      ) => FadeTransition(opacity: animation, child: child),
    );
    _liveRoute = route;
    unawaited(
      Navigator.of(context).push(route).whenComplete(() {
        _liveRoute = null;
        // Somebody else took the route down: ending the session is the only
        // way the microphone can be as gone as the page is.
        if (_liveOpen) _closeLive();
      }),
    );
  }

  /// Closes live conversation and the session with it.
  ///
  /// [reason] is the log's word for why the session ended — `closed` for the X,
  /// `background` for the app going away. It never touches the composer's field:
  /// live conversation has no draft in the field to throw away, which is the
  /// point of it being its own page.
  void _closeLive({String reason = 'closed'}) {
    // Only a live session is this method's to end. A dictation session that a
    // race left open belongs to the button that opened it.
    if (_micMode == _MicMode.live) _stopListening(reason: reason);
    final PageRoute<void>? route = _liveRoute;
    _liveRoute = null;
    if (mounted) {
      setState(() {
        _liveOpen = false;
        _liveIdle = _LivePhase.waiting;
        _liveThinking = false;
        _liveAnswering = false;
        _liveSaid = '';
        _liveAnswerText = '';
        _livePartial = '';
      });
    } else {
      _liveOpen = false;
      _liveIdle = _LivePhase.waiting;
      _liveThinking = false;
    }
    // Any answer still in flight is now nobody's.
    _liveTurns++;
    _syncLive();
    // Removed rather than popped: this is the page going away because what it
    // was showing has ended, and a 200ms slide would leave a dark rectangle
    // over a composer that is already listening to nothing.
    if (route != null && mounted && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// Tells the overlay what the session is doing right now.
  ///
  /// Only while this screen is alive: a recognizer answering after the screen
  /// went away reaches [_endMic], and a notifier disposed with the screen throws
  /// on the way out — nobody is looking at the overlay by then anyway.
  void _syncLive() {
    if (!mounted) return;
    _live.value = _LiveState(
      phase: _micMode == _MicMode.live
          ? _LivePhase.listening
          : (_liveThinking
                ? (_liveAnswering ? _LivePhase.answering : _LivePhase.thinking)
                : _liveIdle),
      partial: _livePartial,
      said: _liveSaid,
      answer: _liveAnswerText,
    );
  }

  /// Asks for the microphone the first time a gesture wants it, and remembers
  /// the answer for the rest of the session.
  ///
  /// Returns whether the microphone may be used. A refusal is counted: the
  /// button goes inert and the composer says why, which is the difference
  /// between a disabled control and a broken one.
  ///
  /// The ask is deliberately here, on the gesture, and not at startup: a
  /// permission dialog that arrives before the user has reached for the
  /// microphone is a dialog about a feature they have not asked for.
  Future<bool> _ensureMicAllowed() {
    final bool? known = _micAllowed;
    if (known != null) return Future<bool>.value(known);
    // One ask at a time, shared: a second gesture while the dialog is up is the
    // same question, and asking it twice would leave the second caller waiting
    // on a dialog Android will not show.
    return _micAsking ??= _askForMic().whenComplete(() => _micAsking = null);
  }

  Future<bool> _askForMic() async {
    final result = await MicrophoneAccess.requestOnce();
    if (!mounted) return false;
    setState(() {
      _micAllowed = result.granted;
      _micRefusal = result.granted
          ? null
          : (result.message ?? 'Microphone permission needed.');
    });
    return result.granted;
  }

  /// Whether the mic button can do anything at all: a device that can listen,
  /// and a microphone the user has not refused.
  bool get _micUsable => SpeechInput.current.available && _micAllowed != false;

  /// What the mic button says about itself: both of its gestures when it can
  /// listen, and the reason it is inert when it cannot. A disabled button with
  /// no explanation just looks broken.
  String get _micTooltip {
    if (_micRefusal != null) return _micRefusal!;
    if (!SpeechInput.current.available) {
      return 'Voice input isn’t set up on this device';
    }
    return 'Tap to dictate, hold to talk';
  }

  /// The composer's note line: why the microphone cannot be used, and otherwise
  /// the shell's usual mock-thread note. Nothing here explains the gestures any
  /// more: a tap does something now, so there is nothing left to teach.
  String? get _micNotice => _micRefusal;

  /// What the live button says about itself. Deliberately not the dictation
  /// button's sentence, even when both are inert: two buttons reading the same
  /// words would be two controls the user cannot tell apart, and the reason
  /// belongs to the mic they were reaching for.
  String get _liveTooltip => _micUsable
      ? 'Live conversation'
      : 'Live conversation isn’t available here';

  /// The X on the composer's left: end the dictation and throw its words away.
  ///
  /// `cancelled` is the reason the log already knows as a user's own discard, and
  /// the only one that empties the field in a tap dictation as well as in a hold
  /// — see [_endMic].
  void _cancelDictation() {
    if (!_listening) return;
    _stopListening(reason: 'cancelled');
  }

  /// End the session now, answering nothing and waiting for nothing: the second
  /// tap, the app going to the background, or the guard's own timeout.
  ///
  /// The order here is the whole fix. The state is cleared *before* the
  /// platform is told, and the platform's answer is never awaited — because
  /// this seam resolves the pending listen only when the recognizer reports
  /// back, and a recognizer that was stopped or replaced reports back to nobody
  /// (see `releaseRecognizerIf` in MainActivity, which returns without
  /// answering when the session it holds is no longer the live one). Waiting on
  /// that answer is what left the button stuck on "listening", with no tap able
  /// to end it.
  ///
  /// [reason] is what the log says and what decides whether the words already in
  /// the field are kept: `cancelled` is a gesture throwing its utterance away and
  /// clears them, while `stopped` and `background` end the listening and leave
  /// the draft exactly where it was.
  void _stopListening({String reason = 'stopped'}) {
    final int? session = _micSession;
    if (session == null) return;
    _endMic(session, reason);
    unawaited(SpeechInput.current.stop());
  }

  /// Closes the session [session] — state, log, and (only where nothing else
  /// will) the microphone — and answers whether it was still the live one.
  ///
  /// A false answer means the user, the guard or a newer session got there
  /// first: this session is over, and its outcome, words included, must be
  /// dropped rather than acted on.
  ///
  /// The clearing rule is the shape of the whole interaction, in one line: the
  /// field is emptied only when the user's own gesture abandoned the utterance —
  /// a held finger that slid off the button (`cancelled`), or a hold nobody
  /// released until the guard swept it up (`timeout`). Everything else keeps the
  /// words on screen: a transcript is a draft, a tap-stop ends the listening and
  /// not the sentence, and a recognizer that closes itself has still heard what
  /// is in the field. "Never clear the field on release" is this line.
  bool _endMic(int session, String reason) {
    if (_micSession != session) return false;
    final _MicMode? mode = _micMode;
    final bool abandoned = mode == _MicMode.oneShot;
    _micSession = null;
    _micMode = null;
    // The overlay is told the turn is over on the same frame the guard or the
    // recognizer ended it, so it never shows "listening" for a closed session.
    _syncLive();
    // Repaint only if this screen can: an answer can arrive after the screen is
    // gone, and setState on a disposed element throws.
    if (mounted) setState(() {});
    _logMic('mic:stop ${_stamp()} reason=$reason');
    // The interim words belong to this session and to no other, so they stop
    // arriving with it — a guess from a session nobody is holding must never
    // land in a field that belongs to the next one. The controller is left alone
    // once the screen is gone, where touching it would throw.
    unawaited(_micPartials?.cancel());
    _micPartials = null;
    // The meter's input stops with the session, and the meter goes back to
    // silence: bars left standing at the last reading of a closed session would
    // be the screen lying about a microphone that is no longer open.
    unawaited(_micRms?.cancel());
    _micRms = null;
    // And the pause that was counting down to the end of this turn goes with it:
    // a timer that outlived its session would ask a recognizer for a transcript
    // nobody is holding any more.
    _liveQuiet?.cancel();
    _liveQuiet = null;
    _liveVoice = false;
    if (mounted) _micLevel.value = 0;
    // The X throws the words away in either dictation mode — that is the whole
    // difference between it and the stop square. The guard does the same only for
    // a hold, whose release nobody ever made. Live conversation has no draft in
    // this field to discard, so it is never touched from there.
    if (mounted &&
        mode != _MicMode.live &&
        (reason == 'cancelled' || (abandoned && reason == 'timeout'))) {
      _message.clear();
    }
    if (reason == 'timeout' || reason == 'error') {
      // Deliberately not for `final`: the recognizer already finished, and a
      // stop sent now could land on a newer session's recognizer instead.
      unawaited(SpeechInput.current.stop());
    }
    return true;
  }

  /// One line per session boundary, on the stream Flutter's own logs use —
  /// `adb logcat | grep mic:` — because the failures worth catching here happen
  /// on a phone with no debugger attached.
  static void _logMic(String line) => debugPrint(line);

  /// The phone's own clock, so a log line can be lined up with what is on
  /// screen at that moment.
  static String _stamp() => DateTime.now().toIso8601String();

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
                  controller: _threadScroll,
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
                          // A failure is not a reply: it takes a notice of its
                          // own instead of a bubble, so a red, bordered sentence
                          // with a warning sign can never be mistaken for
                          // something the assistant said.
                          child: message.failed
                              ? NexusErrorBubble(
                                  text: message.text,
                                  maxWidth: bubbleWidth,
                                )
                              : NexusChatBubble(
                                  text: message.text,
                                  mine: message.mine,
                                  thinking: message.thinking,
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
            brainNote: _brainNote,
            onSend: _send,
            listening: _listening,
            micEnabled: _micUsable,
            micTooltip: _micTooltip,
            micNotice: _micNotice,
            level: _micLevel,
            onCancel: _cancelDictation,
            onMicTap: _micTap,
            onHoldStart: () => unawaited(_micHoldStart()),
            onHoldEnd: _micHoldEnd,
            onLiveTap: () => unawaited(_openLive()),
            liveEnabled: _micUsable && !_listening,
            liveTooltip: _liveTooltip,
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

/// What copying a line says, in one line, next to the thumb that asked.
const String kNexusCopied = 'Message copied';

/// What the two controls under a Nexus message call themselves. Constants
/// because a test — and a screen reader — should name the same control the
/// user sees, and because the copy icon and the error bubble's copy icon are
/// the same promise said twice.
const String kNexusCopyTooltip = 'Copy message';
const String kNexusSpeakTooltip = 'Read aloud';

/// The key on the red notice that stands where a failed answer would have been.
const Key kNexusErrorBubble = Key('nexus-error-bubble');

/// The failure notice's palette: a light red wash, a red rim, red ink.
///
/// Exactly the colours asked for, and named so a test can pin them: `#FFEBEE`
/// background, `#B3261E` text and `#E6A5A0` border. Dark mode gets its own wash
/// (`#3A1B1B`) rather than this one, because a pale red block on a black page is
/// a glare, not a warning — the same reason every other token in this file has
/// two values.
const Color kNexusErrorWash = Color(0xFFFFEBEE);
const Color kNexusErrorInk = Color(0xFFB3261E);
const Color kNexusErrorRim = Color(0xFFE6A5A0);
const Color kNexusErrorWashDark = Color(0xFF3A1B1B);
const Color kNexusErrorInkDark = Color(0xFFFFB4AB);
const Color kNexusErrorRimDark = Color(0xFF7F3A35);

/// Copies [text] and says so.
///
/// The snack bar is the acknowledgement: a clipboard write is otherwise
/// invisible, and the user has no way to tell a copied sentence from a tap that
/// missed. It replaces the previous one rather than queueing, so a second copy
/// does not put the first message's snack bar in front of it.
Future<void> nexusCopyMessage(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text(kNexusCopied),
        duration: Duration(milliseconds: 1400),
      ),
    );
}

/// A message bubble. The user's side is grey with the tail on the left; Nexus's
/// side is the surface colour, outlined.
///
/// Under every Nexus message — the opening lines, every answer the model gives,
/// and nothing else — sits a row with two controls: **copy** (the same clipboard
/// write a long press does, made visible instead of hidden behind a gesture) and
/// **speak** (reads the sentence again). The row is unconditional on purpose. It
/// was briefly drawn only where the device reported a speech engine, and a phone
/// run showed the result: a speaker that appeared on one message and not the
/// next reads like a bug, not like capability. The row is also outside the
/// bubble rather than inside it, so it is the same two buttons under a one-line
/// answer and a paragraph.
///
/// A long press on the bubble still copies, on both sides of the thread: a
/// gesture that already exists costs nothing to keep, and copy is the thing
/// people try first.
class NexusChatBubble extends StatelessWidget {
  const NexusChatBubble({
    super.key,
    required this.text,
    required this.mine,
    this.thinking = false,
    this.maxWidth = 320,
  });

  final String text;
  final bool mine;

  /// True while this bubble is a placeholder for an answer that has not arrived:
  /// muted ink, italic, and no controls: "Nexus is thinking…" is not a sentence
  /// anybody wants on their clipboard or in their ear.
  final bool thinking;

  /// Cap on the bubble, so long messages never reach the screen edge.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GestureDetector(
              // Opaque, so a press on the padding between the words and the
              // bubble's edge is still a press on the bubble.
              behavior: HitTestBehavior.opaque,
              onLongPress: thinking
                  ? null
                  : () => unawaited(nexusCopyMessage(context, text)),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: mine ? c.bubbleMine : c.bubbleTheirs,
                  border: mine ? null : Border.all(color: c.hairline),
                  borderRadius: BorderRadius.only(
                    topLeft: NexusLayout.bubble,
                    topRight: NexusLayout.bubble,
                    bottomLeft: mine
                        ? NexusLayout.bubble
                        : NexusLayout.bubbleTail,
                    bottomRight: mine
                        ? NexusLayout.bubbleTail
                        : NexusLayout.bubble,
                  ),
                ),
                child: Text(
                  text,
                  style: thinking
                      ? NexusType.bubble(c).copyWith(
                          color: c.textMuted,
                          fontStyle: FontStyle.italic,
                        )
                      : NexusType.bubble(c),
                ),
              ),
            ),
            if (!mine && !thinking) _MessageActions(text: text),
          ],
        ),
      ),
    );
  }
}

/// The failure notice that stands where an answer would have been.
///
/// Deliberately *not* a [NexusChatBubble]. A bubble is the assistant speaking;
/// this is the shell saying it has nothing to say, and the two must not look
/// alike — no amount of wording makes "PC not found" read as an answer when it
/// is painted in the same surface colour and the same ink as one.
///
/// So: a red rim, a light red wash, red ink and a warning sign, on Nexus's side
/// of the thread. It carries **copy** and nothing else — copying the sentence is
/// how a user reports it, while a speaker here would read the bad news aloud, so
/// the notice is never spoken when it arrives and never offers to be replayed.
class NexusErrorBubble extends StatelessWidget {
  const NexusErrorBubble({super.key, required this.text, this.maxWidth = 320});

  final String text;

  /// Cap on the notice, the same cap a bubble gets.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color wash = dark ? kNexusErrorWashDark : kNexusErrorWash;
    final Color ink = dark ? kNexusErrorInkDark : kNexusErrorInk;
    final Color rim = dark ? kNexusErrorRimDark : kNexusErrorRim;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () => unawaited(nexusCopyMessage(context, text)),
              child: Container(
                key: kNexusErrorBubble,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: wash,
                  border: Border.all(color: rim),
                  borderRadius: const BorderRadius.only(
                    topLeft: NexusLayout.bubble,
                    topRight: NexusLayout.bubble,
                    bottomLeft: NexusLayout.bubbleTail,
                    bottomRight: NexusLayout.bubble,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded, size: 18, color: ink),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        text,
                        style: NexusType.bubble(c).copyWith(color: ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Copy only. The absence of the speaker is the point: a failure is
            // not something the assistant said, so there is nothing to replay.
            _MessageActions(text: text, speak: false),
          ],
        ),
      ),
    );
  }
}

/// The two controls under a Nexus message: copy it, or hear it again.
///
/// Muted 16dp glyphs on the message's own side of the thread — quiet enough not
/// to compete with the composer, close enough to the sentence they belong to
/// that there is no doubt which line they act on.
class _MessageActions extends StatelessWidget {
  const _MessageActions({required this.text, this.speak = true});

  final String text;

  /// False on the failure notice, which offers copy and never a speaker.
  final bool speak;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _BubbleAction(
            tooltip: kNexusCopyTooltip,
            icon: Icons.copy_rounded,
            onTap: () => unawaited(nexusCopyMessage(context, text)),
          ),
          if (speak)
            _BubbleAction(
              tooltip: kNexusSpeakTooltip,
              icon: Icons.volume_up_outlined,
              onTap: () => unawaited(SpeechOutput.current.speak(text)),
            ),
        ],
      ),
    );
  }
}

/// One 32dp tap target in a message's action row.
class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: c.textMuted),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }
}

/// The bottom pill: rounded input, and one filled purple button that follows the
/// field — a mic while there is nothing to send, a stop while the microphone is
/// open, the send arrow once there are words in the field.
///
/// The arrow is the only way a message leaves this composer. A transcript the
/// microphone leaves behind is a draft like any other, so the release of a hold
/// ends the listening rather than the sentence, and the tap that ends a
/// dictation keeps what it collected.
///
/// The hold that opens a one-utterance session is not this button's: it wraps
/// the slot the button lives in, because the button is not the same widget at
/// both ends of the gesture (see [_HoldToTalk]).
///
/// Beside it sits the second way in: [Icons.waves_rounded], the live
/// conversation button. It is drawn outlined rather than filled, because the
/// filled circle is the composer's one primary action and live mode is the other
/// room, not the send button's rival. It stands down while dictation is open:
/// one microphone, one session.
///
/// While a dictation is live the whole pill becomes the indicator. The mic and
/// the live door leave, the pill takes the accent as a wash and a rim, the field
/// grows a [_LevelBars] meter beside the words — five bars that stand up with the
/// user's voice and fall back to dots when they pause, drawn from the
/// recognizer's own loudness reading rather than from a decoration — and the two
/// ways a dictation can end sit where a thumb already is: an X on the left that
/// throws the words away, a stop square on the right that keeps them. That is the
/// answer to "the user cannot tell it is listening": the control changes shape,
/// and then it moves when they speak. The field itself stops accepting input for
/// the same reason: while the mic is open, the words in it are the recognizer's,
/// and a keyboard fighting them for the same text is the one conflict the user
/// cannot see coming.
///
/// The X and the live button are [_CancelSlot] and [_LiveSlot], always present in
/// the row and empty when not wanted, because a child that comes and goes shifts
/// the row and would take the mic's hold recogniser down in the middle of a
/// press — the bug that recogniser lives one level up to avoid.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.hasText,
    required this.brainNote,
    required this.onSend,
    required this.listening,
    required this.micEnabled,
    required this.micTooltip,
    required this.micNotice,
    required this.level,
    required this.onCancel,
    required this.onMicTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onLiveTap,
    required this.liveEnabled,
    required this.liveTooltip,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasText;
  final VoidCallback onSend;

  /// True while the microphone is open: the trailing button stops instead of
  /// sending, whatever the field happens to hold.
  final bool listening;

  /// False when the mic button cannot do anything here — a device that cannot
  /// listen, or a microphone the user refused. The button is drawn inert rather
  /// than hidden: one that disappears reads as a missing feature, not as a
  /// permission the user declined.
  final bool micEnabled;

  /// What the mic button says about itself, including the reason it is inert.
  final String micTooltip;

  /// The refusal, the hint, or nothing. It goes where the composer's own note
  /// goes — the one place in this pill that holds a sentence without moving
  /// anything — so the reason is visible without a long press.
  final String? micNotice;

  /// The sentence for when there is no refusal: where the next answer will
  /// come from. Built by the screen from the real brain status, because
  /// "your PC answers" stopped being true the day the model moved onto the
  /// phone.
  final String brainNote;

  /// The X on the left of the pill while a dictation is open: clear the field
  /// and close the microphone. Deliberately not the stop button with a
  /// different glyph — the whole point of two controls is that "keep this" and
  /// "throw this away" are never one mis-tap apart.
  final VoidCallback onCancel;

  /// How loud the microphone is hearing, as 0..1, at whatever rate the platform
  /// reports it — the meter's only input. A listenable rather than a number
  /// because it changes many times a second and only the bars care: a value that
  /// rebuilt this whole composer twenty times a second would repaint the thread
  /// and the field along with it.
  final ValueListenable<double> level;

  /// The tap on the mic, or on the stop it became: one toggle, with the state
  /// deciding which half of it this is.
  final VoidCallback onMicTap;

  /// The finger has been down long enough to talk: open the microphone for one
  /// utterance.
  final VoidCallback onHoldStart;

  /// The finger came up, with whether it had left the button — when it has, the
  /// utterance is abandoned and the field is cleared.
  final ValueChanged<bool> onHoldEnd;

  /// Opens the live conversation overlay.
  final VoidCallback onLiveTap;

  /// False while the live button can do nothing: no recognizer, a refused
  /// microphone, or a dictation session already holding the microphone.
  final bool liveEnabled;

  /// What the live button says about itself, including why it is inert.
  final String liveTooltip;

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
                // Cross-faded rather than swapped, so the hint arriving and
                // leaving is a fade and not a flicker. The key is the sentence
                // itself, which is what makes a change of sentence a change of
                // child for the switcher to animate.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: Text(
                    // The note changed with the brain: it used to say the
                    // composer reached nobody, then that the PC answers, and
                    // now it names whichever of the two really will — the phone
                    // itself when its model is loaded, the PC when that is what
                    // is reachable. The refusal still wins here, because why the
                    // microphone cannot be used is the more urgent fact.
                    micNotice ?? brainNote,
                    key: ValueKey<String>(micNotice ?? brainNote),
                    textAlign: TextAlign.center,
                    style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
                // While a dictation is open the pill itself changes: it takes on
                // the accent as a wash and a rim, which is the part that is
                // visible from across a room. A button swapping its glyph is not,
                // and that was the whole problem with the old feedback.
                decoration: BoxDecoration(
                  color: listening
                      ? c.accent.withValues(alpha: 0.07)
                      : c.surface,
                  borderRadius: const BorderRadius.all(NexusLayout.pill),
                  border: Border.all(
                    color: listening || focused
                        ? c.accent.withValues(alpha: 0.55)
                        : c.hairline,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    // The way out of a dictation that was a mistake: one press
                    // clears the field and closes the microphone, so the words
                    // never survive to be sent by accident.
                    _CancelSlot(listening: listening, onCancel: onCancel),
                    // The meter stands *beside* the words, between the X and the
                    // field, and never behind them: bars under a sentence make
                    // both the bars and the sentence unreadable, and the sentence
                    // is the part the user is actually reading.
                    _LevelSlot(listening: listening, level: level),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          // Typing and the recognizer cannot both own the
                          // field: a keyboard edit in the middle of a dictation
                          // fights the words streaming in, and a caret drag
                          // while the mic is open is a selection the next
                          // transcript will overwrite anyway. The field is a
                          // read-only draft until Stop or X ends the session,
                          // and the words are the user's to edit again after.
                          readOnly: listening,
                          enableInteractiveSelection: !listening,
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
                          // A read-only field has no input connection to submit
                          // from, but the guard stays: nothing may post a message
                          // while the microphone is the thing writing into it.
                          onSubmitted: (_) {
                            if (!listening) onSend();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _HoldToTalk(
                      // On whenever the microphone can be used at all — and
                      // deliberately not keyed on the button's current state,
                      // which was measured to be a bug: a recognizer that is
                      // added and removed with the button is disposed *under the
                      // finger* the moment its state changes, and it does change
                      // mid-press (the long press is what opens the session, and
                      // the first interim word is what fills the field). The
                      // release would then land on nobody and leave the session
                      // open until the guard swept it up. So the recognizer
                      // stays, and the handlers decide: a press that began on the
                      // arrow, or during somebody else's session, is refused in
                      // [_HomeTabState._micHoldStart], and a release with no
                      // press of its own is refused in
                      // [_HomeTabState._micHoldEnd].
                      enabled: micEnabled,
                      onStart: onHoldStart,
                      onEnd: onHoldEnd,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                              scale: animation,
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            ),
                        // The button on its way out is decoration the moment it
                        // starts leaving, and it is decoration sitting exactly
                        // where the incoming one is. Left able to take a pointer,
                        // it answers for a button the user can no longer see —
                        // measured, not imagined: a tap one frame after a swap
                        // landed on the outgoing button (whose scale transition
                        // had the incoming one at zero size) and opened a
                        // microphone instead of sending the sentence that was
                        // already in the field.
                        layoutBuilder:
                            (
                              Widget? currentChild,
                              List<Widget> previousChildren,
                            ) => Stack(
                              alignment: Alignment.center,
                              children: <Widget>[
                                for (final Widget child in previousChildren)
                                  IgnorePointer(child: child),
                                ?currentChild,
                              ],
                            ),
                        child: listening
                            ? _RoundAction(
                                key: const ValueKey<String>('stop'),
                                icon: Icons.stop_rounded,
                                // Named for what the tap does, because a tap — not
                                // the release of a hold — is what ends a session
                                // the user opened with a tap.
                                tooltip: 'Stop listening',
                                // The ring inside this circle is the recording
                                // indicator, and it is up for the whole of every
                                // session, in both modes: this is the only state
                                // the button is in while the microphone is open.
                                listening: true,
                                holdIsTaken: micEnabled,
                                onTap: onMicTap,
                              )
                            : hasText
                            ? _RoundAction(
                                key: const ValueKey<String>('send'),
                                icon: Icons.arrow_upward_rounded,
                                tooltip: 'Send',
                                holdIsTaken: micEnabled,
                                onTap: onSend,
                              )
                            : _RoundAction(
                                key: const ValueKey<String>('mic'),
                                icon: Icons.mic_rounded,
                                tooltip: micTooltip,
                                enabled: micEnabled,
                                holdIsTaken: micEnabled,
                                onTap: onMicTap,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // The second way in. It stands down while a dictation is open
                    // — one microphone at a time — but the slot itself is always
                    // in the row, because a child that comes and goes shifts the
                    // row and would take the mic's hold recogniser down with it
                    // in the middle of a press.
                    _LiveSlot(
                      listening: listening,
                      enabled: liveEnabled,
                      tooltip: liveTooltip,
                      onTap: onLiveTap,
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
///
/// Listening does not move it or recolour it — the glyph becomes a stop and a
/// ring breathes *inside* the circle. A halo drawn outside would resize the
/// composer every time the microphone opened, and a control that jumps on the
/// gesture that starts it is worse than no animation at all.
///
/// The hold belongs to [_HoldToTalk] one level up rather than to this circle:
/// the finger outlives the glyph, and this widget is swapped for the stop the
/// moment a session opens.
///
/// [holdIsTaken] is what keeps the two long presses apart. A [Tooltip] shows on
/// a long press, and its recogniser wins that gesture outright, being nearer the
/// finger: a slot whose long press means "talk" would open a tooltip and never a
/// session. So the tooltip asks for [TooltipTriggerMode.manual] there: the
/// message still comes up for a mouse and is still read out by a screen reader,
/// and the long press is left to the microphone. Every button in this slot is
/// built with it, including the stop and the send arrow, because the hold is the
/// slot's and not the glyph's — a glyph that came and went with it would take the
/// recogniser down mid-press with it. An inert button holds nothing, so its
/// tooltip keeps the default long press, which is where the reason it cannot be
/// used can still be read by hand.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.enabled = true,
    this.listening = false,
    this.holdIsTaken = false,
    this.outlined = false,
  });

  final IconData icon;
  final String tooltip;

  /// The tap. Every state has one: the mic opens a session, the stop closes it,
  /// and the send arrow posts the field.
  final VoidCallback? onTap;

  /// False draws the circle neutral and refuses the tap: in this file purple
  /// means the user can act on it, and a button that can't be pressed isn't
  /// purple.
  final bool enabled;

  /// True while the microphone is open: a ring pulses inside the circle. That
  /// ring is the recording indicator, and this is the flag that puts it on
  /// screen — see [kNexusRecordingIndicator].
  final bool listening;

  /// True when a long press in this slot belongs to the microphone's hold, so
  /// the tooltip must not take that gesture for itself.
  final bool holdIsTaken;

  /// Draws the button as an outlined secondary action rather than a filled
  /// primary one: surface fill, accent rim, accent glyph. It is what keeps the
  /// live button from competing with the send arrow beside it while still
  /// reading as something the user can press — the colour rule holds either way,
  /// because the accent is only ever painted on a control that acts.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final Color fill = !enabled ? c.raised : (outlined ? c.surface : c.accent);
    final Color glyph = !enabled
        ? c.textMuted
        : (outlined ? c.accent : c.onAccent);
    final circle = Material(
      color: fill,
      shape: outlined
          ? CircleBorder(
              side: BorderSide(
                color: enabled ? c.accent.withValues(alpha: 0.45) : c.hairline,
              ),
            )
          : const CircleBorder(),
      child: InkWell(
        // The tap is the short one: it starts nothing, it explains. The splash
        // is the acknowledgement that the tap landed at all.
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        splashColor: Colors.white.withValues(alpha: 0.2),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: glyph),
        ),
      ),
    );
    return Tooltip(
      message: tooltip,
      triggerMode: holdIsTaken
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: listening
          ? _ListeningRing(color: c.onAccent, child: circle)
          : circle,
    );
  }
}

/// The microphone's hold gesture, wrapped around the button slot rather than
/// around the button.
///
/// A long press is a sequence: it starts under one finger and ends wherever that
/// finger happens to be, and the button inside this slot is not the same widget
/// at both ends of it — opening the microphone swaps the mic for a stop, and the
/// first interim word turns the empty field into the send arrow, both of which a
/// `switch` child is thrown away by. A recogniser owned by that child would be
/// thrown away with it, and the release would land on nobody: the session would
/// sit open until the thirty-second guard swept it up. Owning the gesture one
/// level up means the recogniser outlives the glyph it started on, and a release
/// is always a release.
///
/// The deadline is [kNexusMicHold] rather than the framework's half second,
/// because the two gestures have to be told apart by the *finger*: the framework's
/// [GestureDetector] long press cannot be rebuilt with a shorter one, so this is
/// built on [LongPressGestureRecognizer] directly. The tap it replaces is not
/// claimed here: a tap belongs to whatever is under the finger (the button's own
/// [InkWell]), which is where it wins the arena for a release this side of the
/// deadline, and where its splash already is.
class _HoldToTalk extends StatelessWidget {
  const _HoldToTalk({
    required this.enabled,
    required this.onStart,
    required this.onEnd,
    required this.child,
  });

  /// False when the microphone cannot be used at all: a device with no
  /// recognizer, or a refused microphone. Nothing is claimed then, so whatever is
  /// under the finger keeps the long press — the tooltip, which is where a
  /// refusal explains itself.
  ///
  /// It is deliberately *not* keyed on what the button currently shows. Whether
  /// this press is a hold is decided by [_HomeTabState._micHoldStart] when the
  /// deadline passes, which is the only moment the answer is worth computing and
  /// the one moment the recogniser is guaranteed to still be alive.
  final bool enabled;

  /// Held past the deadline: this is one utterance.
  final VoidCallback onStart;

  /// Released, with true when the finger had left the button by then.
  final ValueChanged<bool> onEnd;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: enabled
          ? <Type, GestureRecognizerFactory>{
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: kNexusMicHold,
                      debugOwner: this,
                    ),
                    (LongPressGestureRecognizer instance) {
                      instance.onLongPressStart = (LongPressStartDetails _) =>
                          onStart();
                      instance.onLongPressEnd = (LongPressEndDetails details) =>
                          onEnd(
                            !_stillOnButton(context, details.globalPosition),
                          );
                    },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: child,
    );
  }

  /// Whether a released finger is still on the button: the disc plus
  /// [kNexusMicSlack]. Anything further away has left the button, and for the
  /// hold that is how the gesture is abandoned — a release this far out is a
  /// cancel, not a tap, whatever the deadline says.
  ///
  /// Measured from this widget's own box rather than from remembered
  /// coordinates, so it stays true whatever the composer's size does while the
  /// finger is down — including the field growing under the live transcript.
  static bool _stillOnButton(BuildContext context, Offset point) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return true;
    final Offset centre = box.localToGlobal(box.size.center(Offset.zero));
    return (point - centre).distance <= box.size.width / 2 + kNexusMicSlack;
  }
}

/// The pulse inside the mic button while it listens: a 1.5px ring that grows
/// from behind the glyph out to the edge of the circle, fading as it goes.
///
/// This is the recording indicator, and it is a compliance requirement rather
/// than decoration: while the microphone is open the user must be able to see
/// that it is, so the ring is on screen for the whole of every session, in both
/// modes, and nothing in this file may make it dismissible, auto-hiding, or
/// dependent on anything but [listening]. It wears
/// [kNexusRecordingIndicator] so a test can hold it to that.
///
/// It repeats for as long as it is in the tree, which is the point — there may
/// be no words on screen at all, so the ring is what says the phone is still
/// listening. That also means a widget test must not `pumpAndSettle` while
/// listening: the animation never comes to rest.
class _ListeningRing extends StatefulWidget {
  const _ListeningRing({required this.color, required this.child});

  /// The glyph colour to pulse in (the button's [NexusUiColors.onAccent]).
  final Color color;

  final Widget child;

  @override
  State<_ListeningRing> createState() => _ListeningRingState();
}

class _ListeningRingState extends State<_ListeningRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        widget.child,
        // The ring is decoration: it must never eat the tap that stops the
        // utterance, so it sits above the button but out of touch.
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) {
              final double t = _controller.value;
              return Container(
                key: kNexusRecordingIndicator,
                width: 12 + 26 * t,
                height: 12 + 26 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.5 * (1 - t)),
                    width: 1.5,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The X that appears at the left of the pill while a dictation is open.
///
/// A slot that is always in the composer's row and only has a button in it while
/// the microphone is open. The slot is what keeps the row's other children —
/// above all the hold recogniser around the mic — in the same places when the
/// composer transforms under a finger that is still down.
class _CancelSlot extends StatelessWidget {
  const _CancelSlot({required this.listening, required this.onCancel});

  final bool listening;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (!listening) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _RoundAction(
        key: const ValueKey<String>('cancel-dictation'),
        icon: Icons.close_rounded,
        tooltip: 'Cancel dictation',
        outlined: true,
        onTap: onCancel,
      ),
    );
  }
}

/// The live conversation button's slot, for the same reason: it stands down
/// while a dictation is open, and it must not take the rest of the row — or the
/// recogniser holding the microphone — with it when it goes.
class _LiveSlot extends StatelessWidget {
  const _LiveSlot({
    required this.listening,
    required this.enabled,
    required this.tooltip,
    required this.onTap,
  });

  final bool listening;
  final bool enabled;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (listening) return const SizedBox.shrink();
    return _RoundAction(
      key: const ValueKey<String>('live'),
      icon: Icons.waves_rounded,
      tooltip: tooltip,
      outlined: true,
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// The meter's slot in the composer's row: between the X and the words while a
/// dictation is open, and nothing at all otherwise.
///
/// A slot rather than a conditional child, like [_CancelSlot] and [_LiveSlot],
/// because a row whose children shift takes the mic's hold recogniser down with
/// it in the middle of a press.
class _LevelSlot extends StatelessWidget {
  const _LevelSlot({required this.listening, required this.level});

  final bool listening;
  final ValueListenable<double> level;

  @override
  Widget build(BuildContext context) {
    if (!listening) return const SizedBox.shrink();
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 12, bottom: 8),
      // Only the bars rebuild as the voice moves, not the pill around them.
      child: ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (BuildContext context, double value, Widget? child) =>
            _LevelBars(key: kNexusLevelBars, level: value, color: c.accent),
      ),
    );
  }
}

/// The level meter: five rounded bars whose heights come from the microphone.
///
/// This is the real thing rather than a decoration — the heights are drawn from
/// [SpeechInput.rms], the recognizer's own reading of how loud the room is, so
/// the bars move when the user speaks and fall back to dots when they stop.
/// Nothing here animates on its own: a meter with a life of its own would say
/// "I am hearing you" whether or not anybody was speaking, which is the one
/// claim it must never make.
///
/// **The height is the reading, and the only motion is the fall.** A bar is a
/// [TweenAnimationBuilder] over `minHeight + (maxHeight - minHeight) × level`
/// with a very short duration ([_barGlide], 100ms) and [Curves.easeOut]. That
/// combination is deliberate and asymmetric on purpose: `easeOut` covers most of
/// its distance in the first frames, so a loud reading snaps *up* almost at once
/// — one or two frames, invisible at reading speed — while a room going quiet
/// eases *down* over the whole 100ms instead of dropping like a light switch.
///
/// Why any motion at all, when the phone already asked for less of it: Android
/// only calls `onRmsChanged` a few times a second, and a bar that jumps between
/// those readings and then holds perfectly still is what reads as *stuttering*.
/// The glide is what turns forty readings a second apart into a meter that looks
/// continuous — and it is short enough that it can never be the thing that is
/// late. A reading is never delayed: it is the target the animation is already
/// heading for.
class _LevelBars extends StatelessWidget {
  const _LevelBars({
    super.key,
    required this.level,
    this.color,
    this.bars = 5,
    this.width = 3.5,
    this.maxHeight = kNexusBarMaxHeight,
    this.minHeight = kNexusBarMinHeight,
  });

  /// The loudness, 0..1, from [rmsToLevel]. Zero is a silent room and is drawn
  /// as dots, not as an empty slot.
  final double level;

  final Color? color;
  final int bars;
  final double width;
  final double maxHeight;
  final double minHeight;

  /// How tall bar [i] stands at [level] — the mapping, in one line, with no
  /// smoothing anywhere after it.
  ///
  /// The middle bar is the level itself: `3 + 21 × level` at the default ends,
  /// straight from the recognizer's reading to a number of pixels. The bars
  /// either side are the same number scaled by a fixed profile, because five
  /// clones of one meter read as five meters rather than as one voice — it is the
  /// *height* that is real, and the shape across the row is the design.
  double _heightAt(int i, double level) {
    final double shape = _profile[i % _profile.length];
    final double span = (maxHeight - minHeight) * level.clamp(0.0, 1.0);
    return minHeight + span * shape;
  }

  static const List<double> _profile = <double>[0.45, 0.78, 1, 0.82, 0.5];

  /// How long a bar takes to reach a new reading: fast enough to be trailing
  /// nothing, long enough that the gaps between Android's readings disappear.
  static const Duration _barGlide = Duration(milliseconds: 100);

  @override
  Widget build(BuildContext context) {
    final Color paint = color ?? context.ui.accent;
    return SizedBox(
      height: maxHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < bars; i++)
            TweenAnimationBuilder<double>(
              // The target is the reading; the tween's `begin` is where the bar
              // already is, which is what makes a new reading glide rather than
              // restart. `key` on the index so a re-ordered row could never
              // animate one bar into another's height.
              key: ValueKey<int>(i),
              tween: Tween<double>(
                begin: _heightAt(i, level),
                end: _heightAt(i, level),
              ),
              duration: _barGlide,
              curve: Curves.easeOut,
              builder: (BuildContext context, double height, Widget? child) =>
                  Container(
                    width: width,
                    height: height,
                    margin: EdgeInsets.symmetric(horizontal: width / 2),
                    decoration: BoxDecoration(
                      color: paint,
                      borderRadius: BorderRadius.circular(width),
                    ),
                  ),
            ),
        ],
      ),
    );
  }
}

/// What the live page is allowed to be doing, which is the whole privacy story
/// of this screen in one enum.
///
/// * [listening] — the microphone is open, the badge says so and the orb
///   breathes purple.
/// * [thinking] — the microphone is closed and the PC is writing an answer. The
///   orb is blue and pulsing, and the large type says what is happening. Nothing
///   is recording, nothing is counting down, and the only event that ends it is
///   the answer arriving.
/// * [waiting] — the microphone is closed because a turn just ended. The orb is
///   grey and still, the badge says the mic is off, and the page waits for a tap
///   — there is no countdown and nothing restarts on its own.
/// * [answering] — the answer has started arriving. The orb keeps the working
///   colour of [thinking], the microphone is still closed, and the large type
///   is the answer growing rather than a placeholder. This is the state that
///   makes a small model tolerable: the page shows words while the phone is
///   still writing them instead of sitting on "Thinking…" for ten seconds.
/// * [guarded] — the microphone is closed because the 30-second guard swept a
///   turn up. Same grey orb, same tap, different sentence: this is the one the
///   user is owed an explanation for.
///
/// There is deliberately no state that moves between these on a timer. A page
/// that thinks it is doing something the user cannot name is the bug this enum
/// exists to prevent — and a page that *is* doing something the user cannot name
/// would be worse.
enum _LivePhase { listening, thinking, answering, waiting, guarded }

/// What live conversation is doing, as the overlay draws it.
///
/// A plain value in a [ValueNotifier], because the overlay is a route above this
/// tab and cannot be rebuilt by `setState` here. It carries three facts and no
/// logic: what the microphone is doing, the guess arriving right now, and the
/// sentence the last turn captured.
@immutable
class _LiveState {
  const _LiveState({
    required this.phase,
    required this.partial,
    required this.said,
    required this.answer,
  });

  final _LivePhase phase;
  final String partial;
  final String said;

  /// The answer being written, empty unless [phase] is [_LivePhase.answering].
  final String answer;

  /// Whether the microphone is open right now — the one question the badge, the
  /// orb, the meter and the status line all answer from.
  bool get listening => phase == _LivePhase.listening;
}

/// The colours the live page draws itself with, resolved from the app's theme.
///
/// The page used to be one hardcoded dark ground in both brightnesses, which is
/// how a light-theme phone ended up with a black screen it could not explain. It
/// is still a room of its own — the ink and the orb are not composer tokens —
/// but the *ground* now follows the theme, so light mode stays light and dark
/// mode keeps the immersive black it was designed around.
@immutable
class _LivePalette {
  const _LivePalette({
    required this.ground,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.closeWash,
    required this.pausedWash,
    required this.idleCore,
  });

  /// The page behind everything.
  final Color ground;

  /// Large type and icons that must be read.
  final Color ink;

  /// Labels, the privacy line, and the icon on a closed microphone.
  final Color muted;

  final Color accent;

  /// The disc behind the X, and the pill behind the paused badge.
  final Color closeWash;
  final Color pausedWash;

  /// The grey the orb turns while the microphone is closed. Grey on purpose: a
  /// purple orb that merely stopped moving would still read as "live" to anyone
  /// glancing at the screen.
  final List<Color> idleCore;

  factory _LivePalette.of(BuildContext context) {
    final NexusUiColors c = context.ui;
    if (Theme.of(context).brightness == Brightness.dark) {
      return _LivePalette(
        ground: kNexusLiveGround,
        ink: kNexusLiveInk,
        muted: kNexusLiveInkMuted,
        accent: kNexusAccent,
        closeWash: Colors.white.withValues(alpha: 0.08),
        pausedWash: Colors.white.withValues(alpha: 0.06),
        idleCore: const <Color>[
          Color(0xFF4D4D57),
          Color(0xFF3A3A43),
          Color(0xFF2B2B33),
        ],
      );
    }
    return _LivePalette(
      ground: c.surface,
      ink: c.textStrong,
      muted: c.textMuted,
      accent: c.accent,
      closeWash: c.raised,
      pausedWash: c.raised,
      idleCore: const <Color>[
        Color(0xFFD9D9D3),
        Color(0xFFC3C3BC),
        Color(0xFFAEAEA7),
      ],
    );
  }
}

/// Live conversation: the full-screen page the waveform button opens.
///
/// A page rather than a sheet, because it must cover the tab bar — nothing about
/// this mode is a draft in the composer, and nothing underneath it should look
/// like it still is. It listens on the frame it opens, shows what was said in
/// large type, and then **stops**: the microphone closes, the orb goes grey, and
/// the next turn begins only when the user taps. With no conversation behind it
/// yet, the user's own sentence is the honest thing to put on it. The two ways
/// on are the X at the bottom and the orb itself.
///
/// The page follows the app's brightness. In dark mode it is the immersive room
/// the design asks for; in light mode it is the theme's own surface with the
/// theme's ink, because a page that turned black under a light theme looked like
/// a glitch rather than like a deliberate room. What does not change is the
/// signal: purple breathing means the mic is open, grey and still means it is
/// not.
///
/// The badge in the top-left is the indicator for this screen. The composer's
/// ring is still in the tree under this route, and a test finds it, but a widget
/// nobody can see does not tell the user their microphone is open.
class _LivePage extends StatelessWidget {
  const _LivePage({
    required this.state,
    required this.onClose,
    required this.onResume,
    required this.level,
  });

  /// The same loudness readings the composer's meter uses: the page's own meter
  /// is real voice too, not a second decoration.

  final ValueListenable<_LiveState> state;
  final VoidCallback onClose;

  /// Opens the next turn. The only thing that may: every state of this page
  /// that is not [listening] waits for this tap, and is drawn so the tap is
  /// obviously what it waits for.
  final VoidCallback onResume;
  final ValueListenable<double> level;

  @override
  Widget build(BuildContext context) {
    final _LivePalette palette = _LivePalette.of(context);
    return Scaffold(
      key: kNexusLiveOverlay,
      backgroundColor: palette.ground,
      body: SafeArea(
        child: ValueListenableBuilder<_LiveState>(
          valueListenable: state,
          builder: (BuildContext context, _LiveState live, Widget? child) {
            // The one line of large type: the guess while it is being spoken,
            // the captured sentence once the turn is over. A quiet turn keeps
            // the previous sentence, so hesitating does not wipe the screen.
            final String headline = switch (live.phase) {
              _LivePhase.listening =>
                live.partial.isEmpty ? 'Listening…' : live.partial,
              // The wait is written in the same large type the answer will use,
              // so the page never looks stalled and never looks like it is
              // listening while a request is out.
              _LivePhase.thinking => kNexusThinking,
              // The answer, as it is written: the same large type the whole
              // sentence will use, filled in a token at a time.
              _LivePhase.answering =>
                live.answer.isEmpty ? kNexusThinking : live.answer,
              _ => live.said.isEmpty ? 'Say something.' : live.said,
            };
            return Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        height: 34,
                        // The badge swaps with the microphone, not with the
                        // animation: "Recording" only ever describes an open
                        // mic, and the grey "Mic off" is the closed state made
                        // visible instead of leaving a screen that looks live.
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: switch (live.phase) {
                            _LivePhase.listening => _LiveRecordingBadge(
                              ink: palette.ink,
                            ),
                            _LivePhase.waiting => _LivePausedBadge(
                              muted: palette.muted,
                              wash: palette.pausedWash,
                            ),
                            _LivePhase.guarded => const SizedBox.shrink(),
                            // The orb is the badge while an answer is being
                            // written: two signals for one state is one too
                            // many.
                            _LivePhase.thinking => const SizedBox.shrink(),
                            _LivePhase.answering => const SizedBox.shrink(),
                          },
                        ),
                      ),
                      // A name for the page, not a control: it shrinks rather
                      // than pushing the badge off the edge when the text scale
                      // or a narrow phone leaves no room for both.
                      Expanded(
                        child: Text(
                          'Live conversation',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            color: palette.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          // The orb is the resume control as well as the status
                          // light: with the microphone closed its grey circle is
                          // the most obvious thing on the page, and "tap it to
                          // go again" is the one instruction the page has.
                          GestureDetector(
                            // A control exactly when the tap would do something:
                            // while a turn is live there is nothing to resume,
                            // and while an answer is being written the tap is
                            // refused by [_liveResume] anyway — better to be
                            // inert than to look like it was ignored.
                            onTap: live.phase == _LivePhase.listening ||
                                    live.phase == _LivePhase.thinking ||
                                    live.phase == _LivePhase.answering
                                ? null
                                : onResume,
                            behavior: HitTestBehavior.opaque,
                            child: _LiveOrb(phase: live.phase, palette: palette),
                          ),
                          const SizedBox(height: 36),
                          Text(
                            headline,
                            key: kNexusLiveText,
                            textAlign: TextAlign.center,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: palette.ink,
                              fontSize: 32,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            switch (live.phase) {
                              _LivePhase.listening =>
                                'Listening — just speak.',
                              _LivePhase.thinking =>
                                // Not "on your PC": the same page is shown
                                // when the answer is coming from this device,
                                // and the line names the wait, not the machine.
                                'Mic off — asking the AI…',
                              _LivePhase.answering =>
                                'Mic off — answering…',
                              _LivePhase.waiting =>
                                'Mic off — tap to continue.',
                              _LivePhase.guarded =>
                                'Mic off. Nothing is recording.',
                            },
                            key: kNexusLiveStatus,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              color: palette.muted,
                              fontSize: 14,
                            ),
                          ),
                          // The one way on. Deliberately a button and never a
                          // countdown: the microphone is closed until a person
                          // asks for it, which is the whole fix for a phone that
                          // used to restart itself after every turn.
                          if (live.phase != _LivePhase.listening &&
                              live.phase != _LivePhase.thinking &&
                              live.phase != _LivePhase.answering) ...<Widget>[
                            const SizedBox(height: 18),
                            FilledButton.icon(
                              key: kNexusLiveResume,
                              onPressed: onResume,
                              icon: const Icon(Icons.mic_rounded, size: 18),
                              label: const Text('Tap to continue'),
                              style: FilledButton.styleFrom(
                                backgroundColor: palette.accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                textStyle: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // The meter while it listens, and the same promise the Privacy
                // page makes — said here too, where the microphone actually is.
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    children: <Widget>[
                      SizedBox(
                        height: 26,
                        child: live.listening
                            ? ValueListenableBuilder<double>(
                                valueListenable: level,
                                builder:
                                    (
                                      BuildContext context,
                                      double value,
                                      Widget? child,
                                    ) => _LevelBars(
                                      level: value,
                                      color: palette.accent,
                                      bars: 7,
                                      width: 4.5,
                                      maxHeight: 26,
                                      minHeight: 4,
                                    ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 10),
                      // The way out, where a thumb is: the bottom of the screen.
                      // Large on purpose — the one control this page has must not
                      // be a hunt.
                      IconButton(
                        key: kNexusLiveClose,
                        tooltip: 'Close live conversation',
                        onPressed: onClose,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 34,
                          color: palette.ink,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: palette.closeWash,
                          minimumSize: const Size(72, 72),
                          shape: const CircleBorder(),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Icon(
                            Icons.lock_outline,
                            size: 13,
                            color: palette.muted,
                          ),
                          const SizedBox(width: 6),
                          // Flexible, not fixed: the promise is a sentence, and a
                          // sentence has to be able to wrap on a narrow phone (and
                          // at a large text size) rather than run off the edge.
                          Flexible(
                            child: Text(
                              'Processed on this device. Audio never leaves it.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                color: palette.muted,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The indicator on the live page: a pill that says what is happening in a word,
/// for as long as the microphone is open.
class _LiveRecordingBadge extends StatelessWidget {
  const _LiveRecordingBadge({required this.ink});

  /// Readable against the accent wash under any theme.
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: kNexusLiveRecordingIndicator,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: kNexusAccent.withValues(alpha: 0.28),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: kNexusAccent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.mic_rounded, size: 13, color: ink),
          const SizedBox(width: 6),
          Text(
            'Recording',
            style: GoogleFonts.inter(
              color: ink,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The other half of that indicator: the microphone is closed, and the page says
/// so in grey rather than by showing nothing at all.
///
/// Nothing at all would be ambiguous in the worst way — a page between turns and
/// a page whose badge failed to appear look identical — and this badge is what
/// makes the closed microphone readable as a state rather than as an absence.
/// It is not shown while an answer is being written: there the orb is blue and
/// the large type says what is happening, and a second grey "Mic off" pill would
/// be one signal too many for one fact.
class _LivePausedBadge extends StatelessWidget {
  const _LivePausedBadge({required this.muted, required this.wash});

  final Color muted;
  final Color wash;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: kNexusLivePausedIndicator,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: muted.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.mic_off_rounded, size: 13, color: muted),
          const SizedBox(width: 6),
          Text(
            'Mic off',
            style: GoogleFonts.inter(
              color: muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The orb at the centre of the live page: the one big, wordless answer to what
/// the phone is doing, in colour.
///
/// * Listening — purple, breathing, with a ring leaving it on every breath.
/// * Thinking — blue, pulsing: the microphone is closed and the PC is writing.
/// * Anything else — grey and still.
///
/// Colour is as load-bearing as motion on purpose: motion alone is too easy to
/// miss, and a still purple orb still looks live to somebody glancing at the
/// screen. The states never share a hue, so the page can be read from across a
/// room in the time it takes to glance at it.
class _LiveOrb extends StatefulWidget {
  const _LiveOrb({required this.phase, required this.palette});

  final _LivePhase phase;
  final _LivePalette palette;

  bool get listening => phase == _LivePhase.listening;

  /// Whether the orb is in its working colour: the model is writing (or about to
  /// write), so the page pulses blue either way — an answer arriving slowly is
  /// still the same wait, and a colour change halfway through it would read as a
  /// state change the user has to interpret.
  bool get thinking =>
      phase == _LivePhase.thinking || phase == _LivePhase.answering;

  /// Whether this state moves at all. Both of the moving states are states where
  /// something is happening that the user is waiting on; the still ones are the
  /// states where the next move is the user's.
  bool get animated => listening || thinking;

  @override
  State<_LiveOrb> createState() => _LiveOrbState();
}

class _LiveOrbState extends State<_LiveOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animated) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _LiveOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.animated && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final _LivePalette palette = widget.palette;
        final double t = widget.animated ? _controller.value : 0.35;
        final double pulse = math.sin(t * math.pi);
        // Thinking pulses a little harder than listening breathes: it is a
        // shorter, more urgent state, and the two are never on screen together.
        final double breathe = 1 +
            (widget.thinking ? 0.11 : widget.listening ? 0.06 : 0) * pulse;
        final Color glow = widget.listening
            ? palette.accent
            : widget.thinking
            ? kNexusLiveThinking
            : palette.muted;
        final double glowAlpha = widget.listening
            ? 0.35
            : widget.thinking
            ? 0.34 + 0.2 * pulse
            : 0.12;
        final List<Color> core = widget.listening
            ? const <Color>[Color(0xFFA97BFF), kNexusAccent, Color(0xFF3C1578)]
            : widget.thinking
            ? const <Color>[
                kNexusLiveThinkingLight,
                kNexusLiveThinking,
                kNexusLiveThinkingDeep,
              ]
            : palette.idleCore;
        return SizedBox(
          key: kNexusLiveOrb,
          width: 240,
          height: 240,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Transform.scale(
                scale: breathe,
                child: Container(
                  width: 236,
                  height: 236,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: <Color>[
                        glow.withValues(alpha: glowAlpha),
                        glow.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.listening)
                Container(
                  width: 120 + 118 * t,
                  height: 120 + 118 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: palette.accent.withValues(
                        alpha: 0.45 * (1 - t),
                      ),
                      width: 1.5,
                    ),
                  ),
                ),
              Transform.scale(
                scale: widget.listening ? breathe : 1,
                // The colour change is eased but quick, and the grey is a
                // property of the closed state rather than of the animation: a
                // test can ask for the idle orb and find it the moment the
                // turn ends, without waiting for a fade.
                child: AnimatedContainer(
                  // One key per visual state, on purpose: a test — and a person —
                  // should be able to ask "which state is the orb in?" and get
                  // an answer that is the state, not an interpolation between
                  // two of them.
                  key: widget.listening
                      ? null
                      : widget.thinking
                      ? kNexusLiveOrbThinking
                      : kNexusLiveOrbIdle,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.4),
                      colors: core,
                    ),
                  ),
                  child: Icon(
                    widget.thinking
                        ? Icons.auto_awesome_rounded
                        : Icons.waves_rounded,
                    size: 46,
                    color: widget.animated ? Colors.white : palette.muted,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

/// A device the Files tab can look at. Mock only.
class NexusMockDevice {
  const NexusMockDevice(
    this.name,
    this.detail,
    this.icon, {
    this.online = true,
  });

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
  NexusMockDevice(
    'My PC',
    'Desktop · this room',
    Icons.desktop_windows_rounded,
  ),
  NexusMockDevice(
    'Studio Mac',
    'Laptop · last seen Oct 9',
    Icons.laptop_mac_rounded,
    online: false,
  ),
];

const List<NexusMockFile> kNexusMockFiles = <NexusMockFile>[
  NexusMockFile('Downloads', 'Folder · 6 items', 'Today', Icons.folder_rounded),
  NexusMockFile('report.pdf', '4.0 KB', 'Oct 11', Icons.picture_as_pdf_rounded),
  NexusMockFile('studio_shoot_01.jpg', '3.4 MB', 'Oct 9', Icons.image_rounded),
  NexusMockFile('mix_v3.wav', '48.2 MB', 'Oct 4', Icons.graphic_eq_rounded),
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
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
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
                  Text(
                    '${file.size} · ${file.date}',
                    style: NexusType.rowMeta(c),
                  ),
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

/// The key on the Brain section's download bar — the filled part, so a test can
/// read how far along a fetch is without measuring pixels.
const Key kNexusBrainProgress = Key('nexus-brain-progress');

/// The settings screen: appearance, voice, the brain, privacy, and what this
/// build is.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
    this.onDevice,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  /// The on-device brain the Brain section manages. Null builds the real one;
  /// a test supplies one pointed at a temp directory, which is what makes the
  /// status, download and delete rows provable without 470 MB or a platform
  /// channel.
  final OnDeviceAiService? onDevice;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _wakeWord = true;
  bool _spokenReplies = false;

  /// The brain the Brain section reports and manages.
  late final OnDeviceAiService _onDevice =
      widget.onDevice ?? OnDeviceAiService();

  /// Which brain would answer right now. Null while the first check is in
  /// flight, which is why the row says "Checking…" rather than guessing.
  AiStatus? _aiStatus;
  bool _modelPresent = false;
  int _modelBytes = 0;
  bool _downloading = false;
  double _downloadProgress = 0;
  String? _brainError;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshBrain());
  }

  /// Re-reads where the answers come from, and how big the model on this device
  /// is. Both answers are cheap — a file check and one HTTP probe — and both
  /// are allowed to fail: a row that cannot be computed says the honest thing.
  Future<void> _refreshBrain() async {
    final bool present = await _onDevice.isModelPresent();
    final int bytes = present ? await _onDevice.model.sizeBytes() : 0;
    final AiStatus status = await AiStatus.detect(model: _onDevice.model);
    if (!mounted) return;
    setState(() {
      _modelPresent = present;
      _modelBytes = bytes;
      _aiStatus = status;
    });
  }

  /// Fetches the model into this app's documents, with the progress the row
  /// shows. The download is the user's decision, so it is never started by a
  /// question; a failure leaves nothing half-written behind (the file only ever
  /// appears after its hash matches) and says so.
  Future<void> _downloadModel() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _brainError = null;
    });
    final bool done = await _onDevice.download(
      onProgress: (double progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      if (!done) {
        _brainError =
            'The model did not download. Check your connection and try '
            'again — nothing was kept.';
      }
    });
    await _refreshBrain();
  }

  /// Deletes the model, and says how much room that made. The next question
  /// falls back to the PC, which is exactly what the status row then reports.
  Future<void> _deleteModel() async {
    setState(() => _brainError = null);
    final int freed = await _onDevice.delete();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Freed ${_megabytes(freed)} MB.')),
    );
    await _refreshBrain();
  }

  static int _megabytes(int bytes) =>
      (bytes + 1024 * 1024 - 1) ~/ (1024 * 1024);

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
            title: 'Privacy',
            subtitle: 'What voice input does with your audio',
            leading: const NexusIconTile(Icons.privacy_tip_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const PrivacyPage(),
              ),
            ),
          ),
          NexusRow(
            title: 'Cloud sync',
            subtitle: 'No account, no server copy',
            leading: const NexusIconTile(Icons.cloud_off_outlined),
            trailing: Text('Off', style: NexusType.rowMeta(c)),
          ),
          // Where the words come from, and the one row that can change it. The
          // status is a value, not a switch: there is nothing to turn on — the
          // app asks the device and then the PC on its own — and the only
          // choice the user has is whether the 470 MB lives on this phone.
          const NexusSectionLabel('Brain'),
          NexusRow(
            title: 'AI status',
            subtitle: _aiStatus?.detail ??
                'Checking where the answers come from…',
            leading: const NexusIconTile(Icons.memory_rounded),
            trailing: Text(
              _aiStatus?.label ?? 'Checking…',
              style: NexusType.rowMeta(c),
            ),
          ),
          if (_downloading)
            _BrainProgress(
              progress: _downloadProgress,
              label: _onDevice.model.label,
              megabytes: _onDevice.model.model.megabytes,
            )
          else if (_modelPresent)
            NexusRow(
              title: 'On-device model',
              subtitle:
                  '${_onDevice.model.label} — ${_megabytes(_modelBytes)} MB '
                  'on this device',
              leading: const NexusIconTile(Icons.download_done_rounded),
              trailing: Text('Downloaded', style: NexusType.rowMeta(c)),
            )
          else
            NexusRow(
              title: 'Download model',
              subtitle:
                  '${_onDevice.model.label} — '
                  '${_onDevice.model.model.megabytes} MB. Runs here, no '
                  'network, no account',
              leading: const NexusIconTile(Icons.download_rounded),
              trailing: const NexusChevron(),
              onTap: _downloadModel,
            ),
          if (_modelPresent && !_downloading)
            NexusRow(
              title: 'Delete model',
              subtitle:
                  'Frees ${_megabytes(_modelBytes)} MB. Answers come from your '
                  'PC instead',
              leading: const NexusIconTile(Icons.delete_outline_rounded),
              trailing: const NexusChevron(),
              onTap: _deleteModel,
            ),
          if (_brainError != null)
            NexusRow(
              title: 'Download failed',
              subtitle: _brainError,
              leading: const NexusIconTile(Icons.warning_amber_rounded),
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

/// The download in progress: one row saying how far along it is, and one thin
/// bar underneath that the eye can read from across a room.
///
/// A bar rather than only a percentage because the number is the detail and the
/// bar is the answer: 470 MB is minutes of waiting, and a user who can see it
/// moving knows the app is working.
class _BrainProgress extends StatelessWidget {
  const _BrainProgress({
    required this.progress,
    required this.label,
    required this.megabytes,
  });

  /// 0 to 1, from [Llm.download] through [OnDeviceAiService.download].
  final double progress;

  final String label;
  final int megabytes;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final int percent = (progress * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const NexusIconTile(Icons.downloading_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Downloading $label',
                      style: NexusType.rowTitle(c),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$percent% of $megabytes MB — keep Nexus open',
                      style: NexusType.rowMeta(c),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text('$percent%', style: NexusType.rowMeta(c)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: const BorderRadius.all(NexusLayout.tile),
            child: SizedBox(
              height: 4,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: c.raised),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      key: kNexusBrainProgress,
                      widthFactor: progress.clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: ColoredBox(color: c.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Icon not switched: $failure')));
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

/// The privacy screen the Settings row of the same name pushes to: the one
/// promise this build can make about voice, said in the open where a store
/// review and a nervous user both go looking for it.
///
/// It is deliberately a stub — two lines and no policy — because the policy is
/// not this file's to write. What it *is* this file's to say, it says exactly:
/// recognition runs on the platform's own on-device recognizer, and nothing
/// here posts audio anywhere. The second line is the shape of the link that will
/// replace it, with [policyLink] standing in until there is a URL to point at.
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  /// The placeholder the published policy will be linked from. Swapping this
  /// string is the whole of what the page needs from whoever writes one.
  static const String policyLink = '<link>';

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: <Widget>[
          Text(
            'Voice input is processed on this device. Audio is never sent '
            'anywhere.',
            style: NexusType.rowTitle(c),
          ),
          const SizedBox(height: 10),
          Text(
            'Full privacy policy: $policyLink',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}
