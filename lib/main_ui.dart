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

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        defaultTargetPlatform,
        kIsWeb,
        listEquals,
        visibleForTesting;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/gestures.dart' show LongPressGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
// The colour wheel in Settings → Theme. A package rather than a hand-rolled
// wheel for the obvious reason: a wheel that is nearly a colour space is worse
// than no wheel, and this one is the HSV wheel with the hex bar under it.
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    show ColorPicker, ColorLabelType, PaletteType;
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/ai_status.dart';
import 'core/appearance.dart';
import 'core/chat_log.dart';
import 'core/device_capabilities.dart';
import 'core/device_memory.dart';
import 'core/local_ai_service.dart';
import 'core/mic_access.dart';
import 'core/ollama_service.dart';
import 'core/on_device_ai_service.dart';
import 'core/on_device_model.dart';
import 'core/onboarding.dart';
import 'core/pair_invite.dart';
import 'core/paired_devices.dart';
import 'core/services/icon_service.dart';
import 'core/version.dart';
import 'core/speech.dart';
import 'core/system_actions.dart';

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/// The one purple in the app: seed colour, active tab, mic/send, switches on.
///
/// Still the default identity — [NexusAccent.purple] is this colour — but no
/// longer the only one: the Theme section offers four more accents, and every
/// surface reads its accent from [NexusUiColors] rather than from this constant.
const Color kNexusAccent = Color(0xFF773DDC);

/// The accent every action in the app is painted with.
///
/// One colour, chosen by the user on a wheel, plus the two readable versions of
/// it a phone needs: an accent that reads as ink on a white page is not the same
/// value that reads as ink on a black one, so [light] and [dark] are derived
/// from what was picked rather than painted raw. The derivation only moves
/// lightness, and only when it has to — a colour the user picked that is already
/// legible is painted exactly as it was picked.
///
/// The shipped purple is the one accent that is not derived: it is the app's own
/// identity, and it is kept exactly as the design tokens name it.
@immutable
class NexusAccent {
  const NexusAccent._(this.seed, this.light, this.dark);

  /// A colour the user picked, made readable in whichever appearance is on
  /// screen.
  ///
  /// A pale yellow is a reasonable thing to want from an accent picker and an
  /// unusable thing to read a label in, and a picker that let the user choose
  /// text they cannot see would be offering a way to break the app. So the hue
  /// they picked is kept and its lightness is moved only as far as legibility
  /// requires — which, for most of the wheel, is not at all.
  factory NexusAccent.custom(Color seed) =>
      NexusAccent._(seed, _asLightInk(seed), _asDarkInk(seed));

  /// The app's own accent: the purple it shipped with, unchanged.
  static const NexusAccent purple = NexusAccent._(
    kNexusAccent,
    kNexusAccent,
    Color(0xFF9D6BF5),
  );

  /// What the user picked: the swatch the row draws, and the seed
  /// `ColorScheme.fromSeed` derives the rest of Material's colours from.
  final Color seed;

  /// The accent on a light page.
  final Color light;

  /// The same accent lifted for a dark page.
  final Color dark;

  /// The swatch the row draws — always the light-mode value, because the row is
  /// a colour the user is choosing rather than a colour that is being applied.
  Color get swatch => light;

  /// Whether this is the user's own colour rather than the shipped purple.
  bool get isCustom => seed != kNexusAccent;

  /// What the Theme row says under its title: the colour, in the hex a user who
  /// is choosing one can compare against anything else on their phone.
  String get label => isCustom ? 'Custom ${_hex(seed)}' : 'Nexus Purple';

  /// What sits on top of the accent — a glyph on a filled button, a switch
  /// thumb: white, or near-black when the accent is pale enough that white
  /// would disappear into it.
  Color onAccentFor(Brightness brightness) {
    final Color accent = brightness == Brightness.dark ? dark : light;
    return accent.computeLuminance() > 0.5
        ? const Color(0xFF141414)
        : const Color(0xFFFFFFFF);
  }

  /// The palette this accent paints, in the brightness it is being shown in.
  NexusUiColors palette(Brightness brightness) => brightness == Brightness.dark
      ? NexusUiColors.dark.copyWith(
          accent: dark,
          onAccent: onAccentFor(brightness),
        )
      : NexusUiColors.light.copyWith(
          accent: light,
          onAccent: onAccentFor(brightness),
        );

  /// [seed] as ink on a light page: the colour itself when it is already dark
  /// enough to read, and a deepened version of it when it is not.
  ///
  /// Stepped, and measured by luminance rather than by lightness, because the
  /// two are not the same question: yellow at half lightness is still the
  /// brightest thing on the page, so a colour can be "dark" in HSL terms and
  /// unreadable as ink. Each step moves the hue's own lightness down until the
  /// colour actually is legible, which takes one step for a pale blue and five
  /// for a pale yellow.
  static Color _asLightInk(Color seed) {
    const double ceiling = 0.45;
    if (seed.computeLuminance() <= ceiling) return seed;
    HSLColor hsl = HSLColor.fromColor(seed);
    Color ink = seed;
    for (int step = 0; step < 8; step++) {
      hsl = hsl.withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0));
      ink = hsl.toColor();
      if (ink.computeLuminance() <= ceiling || hsl.lightness <= 0.0) break;
    }
    return ink;
  }

  /// [seed] as ink on a dark page: the colour itself when it already stands out
  /// against a near-black surface, and a lifted version of it when it does not.
  ///
  /// Lifted in steps rather than by one fixed amount, because how far a colour
  /// has to travel depends on where it started: a navy picked at the bottom of
  /// the wheel needs three steps where a mid-purple needs none. The hue never
  /// moves — only lightness — so the accent stays the colour the user chose.
  static Color _asDarkInk(Color seed) {
    const double floor = 0.2;
    if (seed.computeLuminance() >= floor) return seed;
    HSLColor hsl = HSLColor.fromColor(seed);
    Color lifted = seed;
    for (int step = 0; step < 6; step++) {
      hsl = hsl.withLightness((hsl.lightness + 0.2).clamp(0.0, 0.9));
      lifted = hsl.toColor();
      if (lifted.computeLuminance() >= floor || hsl.lightness >= 0.9) break;
    }
    return lifted;
  }

  /// The colour as `#RRGGBB`, for the row's value line.
  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  bool operator ==(Object other) =>
      other is NexusAccent && other.seed == seed;

  @override
  int get hashCode => seed.hashCode;
}

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

/// The pill a system action settles into: "Flashlight on." Not a bubble, and
/// keyed so a test can tell it from one.
const Key kNexusSystemBubble = Key('nexus-system-bubble');

/// The rolling waveform the live page draws the voice with, and the scrolling
/// transcript above it.
const Key kNexusLiveWave = Key('nexus-live-wave');
const Key kNexusLiveTranscript = Key('nexus-live-transcript');
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
    required this.danger,
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

  /// Destructive actions: the red of "delete this", and the ink of a warning.
  /// A token rather than `Colors.red` because the same red has to read on a
  /// white page and on a black one, and because a destructive row that is not
  /// clearly different from every other row is the bug this exists to prevent.
  final Color danger;

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
    danger: Color(0xFFB3261E),
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
    danger: Color(0xFFFFB4AB),
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
    Color? danger,
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
      danger: danger ?? this.danger,
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
      danger: Color.lerp(danger, other.danger, t)!,
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
  static ThemeData light({NexusAccent accent = NexusAccent.purple}) =>
      _build(accent.palette(Brightness.light), Brightness.light, accent);

  static ThemeData dark({NexusAccent accent = NexusAccent.purple}) =>
      _build(accent.palette(Brightness.dark), Brightness.dark, accent);

  static ThemeData _build(
    NexusUiColors c,
    Brightness brightness,
    NexusAccent accent,
  ) {
    final base = ThemeData(useMaterial3: true, brightness: brightness);
    final scheme =
        ColorScheme.fromSeed(
          // The seed is what the user picked, not the readable version of it:
          // the derived scheme only needs a hue, and every accent-bearing token
          // is overwritten from the palette below anyway.
          seedColor: accent.seed,
          brightness: brightness,
        ).copyWith(
          error: c.danger,
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

void main() async {
  // Preferences are read before the first frame: the model, so the first
  // question after a restart loads the file the user picked, and the accent, so
  // a custom colour does not open as the shipped purple and then swap under the
  // user's eyes. Both reads are one file, and the model's is still not awaited
  // by the brain — see `OnDeviceAiService._warmChoice`.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(ModelChoice.instance.ensureLoaded());
  final int? seed = await Appearance.accentSeed();
  runApp(NexusUiApp(initialAccent: accentFromSeed(seed)));
}

/// The accent a stored seed stands for.
///
/// The shipped purple is answered by [NexusAccent.purple] rather than by
/// `NexusAccent.custom(kNexusAccent)` on purpose: the two differ — the derived
/// one lifts the colour for a dark page — and the app's own identity is the one
/// accent that is painted exactly as the tokens name it.
@visibleForTesting
NexusAccent accentFromSeed(int? seed) {
  if (seed == null) return NexusAccent.purple;
  final Color colour = Color(seed);
  return colour == kNexusAccent ? NexusAccent.purple : NexusAccent.custom(colour);
}

/// The shell app. Holds what outlives a tab — appearance and accent — because
/// the Settings tab changes them and the whole frame has to follow.
///
/// Appearance follows the phone until the user says otherwise: [ThemeMode]
/// .system is the default, so a phone that switches to dark at sunset takes the
/// app with it, and the manual switch is an override rather than a requirement.
/// The override is deliberately all-or-nothing (dark or light, not a third
/// "system" switch position) because the row above it is the one that decides.
class NexusUiApp extends StatefulWidget {
  const NexusUiApp({super.key, this.initialAccent});

  /// The accent to open with, read from the preference before the first frame.
  /// Null is a test that does not care, and starts on the shipped purple.
  final NexusAccent? initialAccent;

  @override
  State<NexusUiApp> createState() => _NexusUiAppState();
}

class _NexusUiAppState extends State<NexusUiApp> {
  /// True while the app takes its brightness from the platform. Starts true:
  /// the phone already knows what time it is, and an app that opens in the
  /// wrong half of the day is a setting the user never chose.
  bool _followSystem = true;

  /// The user's own choice, used only while [_followSystem] is false.
  bool _dark = false;

  /// Which accent every surface paints itself with. Read from the preference in
  /// [main] so the first frame is already the user's colour.
  late NexusAccent _accent = widget.initialAccent ?? NexusAccent.purple;

  /// Whether this device has already seen the welcome screen.
  ///
  /// Null is the one frame before the preference has been read, and it is not
  /// the same answer as "no": the welcome screen and the shell are two different
  /// apps to open into, and guessing would flash the wrong one at the user. The
  /// read is one preference, so the gap is a frame on a phone — and in a test, no
  /// gap at all: a store that cannot be reached counts as [Onboarding.isDone]'s
  /// own answer, which is that the user has been here before.
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    Onboarding.isDone().then((bool done) {
      if (mounted) setState(() => _onboarded = done);
    });
  }

  ThemeMode get _themeMode => _followSystem
      ? ThemeMode.system
      : (_dark ? ThemeMode.dark : ThemeMode.light);

  /// Paints the app in [value] and remembers it.
  ///
  /// The write is fire-and-forget: the frame the user is looking at must not
  /// wait on a file, and a store that refuses the write costs them the colour
  /// after a restart rather than the colour now.
  void _setAccent(NexusAccent value) {
    if (value == _accent) return;
    setState(() => _accent = value);
    unawaited(Appearance.setAccentSeed(value.seed.toARGB32()));
  }

  /// The user left the welcome screen — by downloading a model or by skipping.
  /// The flag is already written by the time this runs; this only swaps the
  /// screen, so the tap they just made moves them forward in the same frame.
  void _finishOnboarding() {
    if (mounted) setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    final bool? onboarded = _onboarded;
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      theme: NexusTheme.light(accent: _accent),
      darkTheme: NexusTheme.dark(accent: _accent),
      themeMode: _themeMode,
      home: switch (onboarded) {
        true => NexusShell(
          followSystem: _followSystem,
          darkMode: _dark,
          accent: _accent,
          onFollowSystemChanged: (value) =>
              setState(() => _followSystem = value),
          onDarkModeChanged: (value) => setState(() => _dark = value),
          onAccentChanged: _setAccent,
        ),
        false => WelcomeView(onDone: _finishOnboarding),
        // The ground the shell would paint, with nothing on it. Deliberately
        // blank rather than a logo: a mark that appears and vanishes inside one
        // frame is a flicker, and this window is not long enough to read one.
        null => const _NexusBootGround(),
      },
    );
  }
}

/// The one frame before the app knows which screen it is.
class _NexusBootGround extends StatelessWidget {
  const _NexusBootGround();

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.ui.background, child: const SizedBox.expand());
}

// ---------------------------------------------------------------------------
// First run
// ---------------------------------------------------------------------------

/// The keys the welcome screen hangs its three decisions on: the download, and
/// the way past it. Keys rather than text so a test can point at the control the
/// user points at, whatever the wording becomes.
const Key kNexusWelcomeDownload = Key('nexus-welcome-download');
const Key kNexusWelcomeSkip = Key('nexus-welcome-skip');
const Key kNexusWelcomeProgress = Key('nexus-welcome-progress');

/// The first-run screen: one question — which model — answered for the user by
/// the only fact that predicts it, and answered *with* them rather than behind
/// their back.
///
/// Why it exists at all: the app's first useful moment is a 470 MB download it
/// cannot start without being asked, and the two models on offer are a real
/// trade (fast and occasionally wrong about the action JSON, or slower and
/// right). A user meeting that choice cold on the Settings screen has no way to
/// make it; a user told "your phone has 6 GB, so this one" and offered both has.
///
/// What it deliberately is not: a tour, an account, a permission walk, or a
/// wall. Every path through it — download, or skip — lands in exactly the app
/// that was there before this screen existed, and the flag is written on the way
/// out of either.
class WelcomeView extends StatefulWidget {
  const WelcomeView({super.key, this.onDevice, this.onDone, this.ramProbe});

  /// The brain whose download button this screen borrows. Null builds the real
  /// one; a test supplies one pointed at a temp directory, which is what makes
  /// the download provable without 470 MB or a platform channel.
  final OnDeviceAiService? onDevice;

  /// Called when the user is done here — after a finished download, after
  /// "Skip for now". The shell is what swaps the screen; this screen never
  /// touches the app root itself.
  final VoidCallback? onDone;

  /// How much memory this device has, or null when it will not say. A test seam
  /// in the shape the rest of the shell uses; the app probes the device.
  final Future<int?> Function()? ramProbe;

  @override
  State<WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<WelcomeView> {
  /// The model this screen recommends, once the RAM has been read.
  OnDeviceModelChoice _recommended = OnDeviceModelChoice.qwen;
  int? _ram;
  bool _probed = false;

  /// True when the recommended model's file is already on disk — a phone that
  /// downloaded the small model before this screen existed must not be asked to
  /// download it again.
  bool _present = false;

  bool _downloading = false;
  double _progress = 0;
  String? _error;

  late final OnDeviceAiService _onDevice = widget.onDevice ?? OnDeviceAiService();

  /// Whether this device can run a model at all. Answered by the capability
  /// registry, so the same device that is not offered the download in Settings
  /// is not offered it here either — and is told what to do instead.
  bool get _supported => DeviceCapabilities.current.supportsOnDeviceAi();

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  /// Reads the RAM, decides what to recommend, and asks whether that model is
  /// already here. One pass, on mount: the answer cannot change while the screen
  /// is open.
  Future<void> _probe() async {
    final int? ram = await (widget.ramProbe ?? DeviceMemory.totalBytes)();
    final OnDeviceModelChoice choice = recommendedModel(ram);
    bool present = false;
    try {
      present = await _onDevice.model.withChoice(choice).isPresent();
    } on Object catch (error) {
      debugPrint('WELCOME: could not look for a model ($error)');
    }
    if (!mounted) return;
    setState(() {
      _ram = ram;
      _recommended = choice;
      _present = present;
      _probed = true;
    });
  }

  /// Downloads the recommended model, then hands the user to the app.
  ///
  /// The selection is made first so the file lands under the name the brain will
  /// look for and Settings' own row agrees with what just happened — one
  /// selection, not a second one made behind it.
  Future<void> _download() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    await ModelChoice.instance.select(_recommended);
    final bool ok = await _onDevice.download(
      onProgress: (double progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _downloading = false;
        _error =
            'The download did not finish. Check your connection and try again.';
      });
      return;
    }
    await Onboarding.complete();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${_recommended.label} is ready. Ask away.'),
          duration: const Duration(seconds: 3),
        ),
      );
    widget.onDone?.call();
  }

  /// The way past: no download, no questions, straight into the app. The
  /// recommendation is still the selected model, so the Settings row offers
  /// exactly the download the user just declined — the same 470 MB, one tap
  /// away, where they now know to look for it.
  Future<void> _skip() async {
    await ModelChoice.instance.select(_recommended);
    await Onboarding.complete();
    if (!mounted) return;
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final OnDeviceModelChoice choice = _recommended;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final double width = box.maxWidth > NexusLayout.content
                ? NexusLayout.content
                : box.maxWidth;
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                  children: <Widget>[
                    Text(
                      'Welcome to Nexus.',
                      style: NexusType.greeting(c),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Let's get your private AI set up.",
                      style: NexusType.lede(c),
                    ),
                    const SizedBox(height: 26),
                    NexusRow(
                      title: _probed
                          ? 'This device has ${DeviceMemory.label(_ram)} of RAM'
                          : 'Checking this device',
                      subtitle: _probed
                          ? recommendationReason(_ram, choice)
                          : 'Reading how much memory it has…',
                      leading: const NexusIconTile(Icons.memory_rounded),
                    ),
                    const SizedBox(height: 8),
                    if (_supported)
                      NexusRow(
                        title: _present
                            ? '${choice.label} — already downloaded'
                            : 'Recommended: ${choice.label}',
                        subtitle: '${choice.megabytes} MB — ${choice.blurb}',
                        leading: const NexusIconTile(Icons.auto_awesome_rounded),
                        accentTitle: true,
                      )
                    else
                      const NexusRow(
                        title: 'This device cannot run a model',
                        subtitle:
                            'Nexus will answer from Ollama on your PC, on the '
                            'same Wi-Fi. Everything else works without it.',
                        leading: NexusIconTile(Icons.cloud_off_rounded),
                      ),
                    if (_downloading) ...<Widget>[
                      const SizedBox(height: 14),
                      LinearProgressIndicator(
                        key: kNexusWelcomeProgress,
                        value: _progress == 0 ? null : _progress,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Downloading ${choice.label} — ${(_progress * 100).round()}% '
                        'of ${choice.megabytes} MB',
                        style: NexusType.rowMeta(c),
                      ),
                    ],
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 14),
                      Text(
                        _error!,
                        style: NexusType.rowMeta(
                          c,
                        ).copyWith(color: c.danger),
                      ),
                    ],
                    const SizedBox(height: 26),
                    if (_supported)
                      FilledButton(
                        key: kNexusWelcomeDownload,
                        onPressed: !_probed || _downloading
                            ? null
                            : (_present ? _skip : _download),
                        child: Text(
                          _downloading
                              ? 'Downloading…'
                              : (_present
                                    ? 'Start chatting'
                                    : 'Download Recommended AI'),
                        ),
                      ),
                    const SizedBox(height: 10),
                    TextButton(
                      key: kNexusWelcomeSkip,
                      onPressed: _downloading ? null : _skip,
                      child: const Text('Skip for now'),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Both models run entirely on this device. Nothing you say '
                      'is sent anywhere, and you can switch or delete them in '
                      'Settings.',
                      style: NexusType.rowMeta(c).copyWith(height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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
    this.followSystem = true,
    this.accent = NexusAccent.purple,
    this.onFollowSystemChanged,
    this.onAccentChanged,
  });

  /// Whether the shell is currently in dark mode, as the user chose it. What is
  /// *on screen* is `Theme.of(context).brightness`, which differs from this
  /// whenever the app is following the phone — see [followSystem].
  final bool darkMode;

  /// True while appearance comes from the platform's own light/dark setting.
  final bool followSystem;

  /// Which accent the shell paints itself with.
  final NexusAccent accent;

  /// Called when the Settings tab flips the appearance switch.
  final ValueChanged<bool> onDarkModeChanged;

  /// Called when the user hands appearance back to the phone, or takes it back.
  final ValueChanged<bool>? onFollowSystemChanged;

  /// Called when the Theme section picks a different accent.
  final ValueChanged<NexusAccent>? onAccentChanged;

  @override
  State<NexusShell> createState() => _NexusShellState();
}

class _NexusShellState extends State<NexusShell> {
  int _tab = 0;

  /// The Settings screen's own scroll position, owned here rather than there
  /// for one reason: coming back to the screen has to start at the top, and the
  /// tab that was left halfway down a long section would otherwise return the
  /// user to a row they cannot place. The shell is what knows the tab was just
  /// selected; the screen only knows how to be scrolled.
  final ScrollController _settingsScroll = ScrollController();

  /// How many times Settings has been opened, handed to the tab as a signal to
  /// re-read the Brain section. Kept here rather than in the screen because the
  /// *shell* is what knows a tab was selected — the screen only knows how to
  /// look again.
  int _settingsEpoch = 0;

  /// The same signal for Home, whose composer line says where the next answer
  /// comes from. Two counters rather than one because the two screens read at
  /// different moments and neither should refresh the other.
  int _homeEpoch = 0;

  @override
  void dispose() {
    _settingsScroll.dispose();
    super.dispose();
  }

  /// Shows tab [index], and puts Settings back at its first row on the way in.
  void _select(int index) {
    // A visit is also a fresh reading: the PC's Ollama coming up after the app
    // started is the case this catches, and the moment to ask is the moment the
    // user looks at the rows that answer it.
    if (index == _settingsIndex) _settingsEpoch++;
    if (index == _homeIndex) _homeEpoch++;
    setState(() => _tab = index);
    if (index != _settingsIndex) return;
    // After the frame that shows it: a controller with no clients cannot jump,
    // and a screen being built right now has none yet. Jump rather than
    // animate — this is where the screen starts, not a journey.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_settingsScroll.hasClients) return;
      _settingsScroll.jumpTo(0);
    });
  }

  /// Where Settings lives in the tab bar, named once so [_select] and the body
  /// cannot disagree about which tab gets the treatment above.
  static const int _settingsIndex = 3;

  /// Where Home lives, for the same reason.
  static const int _homeIndex = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    // What the switch reports, which is not always what the user chose: while
    // the app follows the phone, the phone has the last word.
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: c.background,
      body: IndexedStack(
        index: _tab,
        children: <Widget>[
          HomeTab(refreshEpoch: _homeEpoch),
          const FilesTab(),
          const DevicesTab(),
          SettingsTab(
            darkMode: dark,
            onDarkModeChanged: widget.onDarkModeChanged,
            followSystem: widget.followSystem,
            onFollowSystemChanged: widget.onFollowSystemChanged,
            accent: widget.accent,
            onAccentChanged: widget.onAccentChanged,
            scrollController: _settingsScroll,
            refreshEpoch: _settingsEpoch,
          ),
        ],
      ),
      bottomNavigationBar: NexusTabBar(
        index: _tab,
        onSelected: _select,
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
    this.dangerTitle = false,
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

  /// Paints the title in the danger colour. For the one kind of row that
  /// destroys something: it has to be recognisable as destructive before it is
  /// read, not after.
  final bool dangerTitle;

  /// What a screen reader says for this row, when the row shows something the
  /// label cannot: a tick, a colour swatch. Null leaves the row's own text to
  /// speak for itself.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final titleColor = dangerTitle
        ? c.danger
        : (accentTitle ? c.accent : c.textStrong);
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

/// The label on the dialog's one action button — the way out of a refused
/// permission. A constant because two things point at it: the dialog, and the
/// tests that prove a user who said "don't allow" is offered the system page
/// rather than left holding a control that cannot work.
const String kNexusOpenSettingsLabel = 'Open settings';

/// The dialog a refused permission gets: what is missing, and the one place it
/// can be put right.
///
/// A dialog rather than a snack bar or a notice line, because the user has just
/// asked for something and been told no — and the answer to "no" is a door, not
/// a sentence. Returns true when the user asked to be taken there, false for
/// every other way out ("Not now", the back gesture, a tap outside), so the
/// caller decides what opening the page means on its platform.
Future<bool> showNexusPermissionDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final c = context.ui;
  final bool? open = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: c.surface,
      title: Text(title, style: NexusType.rowTitle(dialogContext.ui)),
      content: Text(
        message,
        style: NexusType.rowMeta(dialogContext.ui).copyWith(height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Not now', style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text(kNexusOpenSettingsLabel),
        ),
      ],
    ),
  );
  return open ?? false;
}

/// The title on the dialog that stands in front of a destructive row.
const String kNexusDeleteModelTitle = 'Delete AI Model?';

/// The Settings row that forgets the conversation, and the question it asks
/// first. Two strings because they are two things: the row is what the user is
/// looking for, the dialog is what they have to mean.
const String kNexusClearChatRow = 'Clear chat';
const String kNexusClearChatTitle = 'Clear chat?';

/// The row whose switch becomes a spinner while the theme changes, and the key
/// on that spinner — so a test can catch the moment and a user never sees a
/// control that looks stuck.
const Key kNexusDarkModeRow = Key('nexus-dark-mode-row');
const Key kNexusThemeBusy = Key('nexus-theme-busy');

/// Asks a yes/no question about something that cannot be undone.
///
/// Returns true only when the user pressed the button that says so; every other
/// way out — Cancel, the system back gesture, a tap on the barrier — answers
/// false. That is the whole contract: the *default* answer to "are you sure" is
/// no, and a dialog that answered yes by being dismissed would be worse than no
/// dialog at all.
Future<bool> showNexusConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) async {
  final NexusUiColors c = context.ui;
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: c.surface,
      title: Text(title, style: NexusType.rowTitle(dialogContext.ui)),
      content: Text(
        message,
        style: NexusType.rowMeta(dialogContext.ui).copyWith(height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel, style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          key: kNexusConfirmAction,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            confirmLabel,
            style: TextStyle(color: c.danger, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The title on the dialog that stands in front of the bin icon, the sentence
/// it shows before a pairing is broken, the button that finds nearby devices
/// before it can find any, and what that button says afterwards.
///
/// Constants because all four are read by tests as well as by users: the
/// confirmation is the only thing between a mis-tap and a broken pairing.
const String kNexusForgetTitle = 'Forget this device?';
const Key kNexusDiscoverNearby = Key('nexus-discover-nearby');
const String kNexusDiscoverySoon =
    'Nearby discovery coming soon. Use QR for now.';

/// The key on a destructive dialog's confirm button.
const Key kNexusConfirmAction = Key('nexus-confirm-action');

/// The key on the Theme section's colour row, on the button that opens the
/// wheel, on the wheel itself, and on the one way back to the shipped purple.
///
/// The row is what the accent *is*; the button is what changes it. They are keyed
/// apart because a test that taps the row and a test that reads its subtitle are
/// asking about two different things.
const Key kNexusAccentRow = Key('nexus-accent-row');
const Key kNexusPickColor = Key('nexus-pick-color');
const Key kNexusColorWheel = Key('nexus-color-wheel');
const Key kNexusResetAccent = Key('nexus-reset-accent');

/// The Theme section's accent control: one row that says what the app paints
/// with, and one button that opens a colour wheel.
///
/// A wheel rather than a row of presets, because the presets were five colours
/// somebody else had chosen and the point of the row is that this app is the
/// user's. The wheel paints the app *while* the thumb drags it — the preview is
/// the app itself — so there is nothing to confirm, and the dialog's buttons are
/// only the way back to the shipped purple and the way out.
class _AccentRow extends StatelessWidget {
  const _AccentRow({required this.selected, required this.onSelected});

  final NexusAccent selected;
  final ValueChanged<NexusAccent>? onSelected;

  Future<void> _pick(BuildContext context) async {
    final ValueChanged<NexusAccent>? onSelected = this.onSelected;
    if (onSelected == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) =>
          _AccentWheelDialog(accent: selected, onChanged: onSelected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    // Not a [NexusRow] with a trailing button, and deliberately: a row lays its
    // trailing control out beside the words, and "Pick a custom color" is a
    // sentence rather than a glyph — beside the title on a 390pt phone it leaves
    // the second line about fifty points wide and the row unreadable. So the
    // button goes *under* the words it belongs to, at the disc's full-width
    // indent, and the row has nothing left that can be squeezed.
    return Semantics(
      container: true,
      label: 'Accent colour. ${selected.label}',
      child: Padding(
        key: kNexusAccentRow,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _AccentDisc(color: selected.swatch),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Accent colour', style: NexusType.rowTitle(c)),
                  const SizedBox(height: 3),
                  Text(
                    'Buttons, switches and the active tab — ${selected.label}',
                    style: NexusType.rowMeta(c),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    key: kNexusPickColor,
                    onPressed: onSelected == null ? null : () => _pick(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Pick a custom color'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The disc that stands where an icon tile would: the accent in full, at the
/// same size as the tiles beside it, so the row says which colour is in force
/// before it is read.
class _AccentDisc extends StatelessWidget {
  const _AccentDisc({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: c.hairline),
      ),
    );
  }
}

/// The colour wheel itself, in a dialog.
///
/// Stateful for one reason: the wheel needs to know which colour it is showing,
/// and `flutter_colorpicker`'s widget is told rather than asked. Every call back
/// to the app replaces the accent outright, which is what "instantly" means
/// here — there is no Apply, because there is nothing to apply.
class _AccentWheelDialog extends StatefulWidget {
  const _AccentWheelDialog({required this.accent, required this.onChanged});

  /// The accent in force when the dialog opened: the colour the wheel starts on.
  final NexusAccent accent;

  /// Called with every colour the thumb passes over, as the accent to paint.
  final ValueChanged<NexusAccent> onChanged;

  @override
  State<_AccentWheelDialog> createState() => _AccentWheelDialogState();
}

class _AccentWheelDialogState extends State<_AccentWheelDialog> {
  /// The colour on the wheel right now — already the app's accent, because the
  /// app is what is being painted while the thumb moves.
  late Color _color = widget.accent.seed;

  /// Whether what the wheel is showing came from the user rather than from the
  /// app. Tracked here rather than read back off [widget.accent], which is the
  /// value that opened the dialog and does not change under it: a Reset button
  /// that appeared only after the dialog was reopened would be a button the user
  /// never sees when they need it.
  late bool _custom = widget.accent.isCustom;

  void _choose(Color color) {
    setState(() {
      _color = color;
      _custom = NexusAccent.custom(color).isCustom;
    });
    widget.onChanged(NexusAccent.custom(color));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text('Pick a custom color', style: NexusType.rowTitle(c)),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      content: SingleChildScrollView(
        child: ColorPicker(
          key: kNexusColorWheel,
          pickerColor: _color,
          onColorChanged: _choose,
          paletteType: PaletteType.hueWheel,
          enableAlpha: false,
          displayThumbColor: true,
          hexInputBar: true,
          labelTypes: const <ColorLabelType>[ColorLabelType.hex],
          colorPickerWidth: 260,
        ),
      ),
      actions: <Widget>[
        if (_custom)
          TextButton(
            key: kNexusResetAccent,
            onPressed: () {
              setState(() {
                _color = kNexusAccent;
                _custom = false;
              });
              widget.onChanged(NexusAccent.purple);
            },
            child: const Text('Reset'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
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
    this.system = false,
    this.ok = true,
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

  /// True when this line is the shell reporting something it did rather than
  /// something the assistant said: "Flashlight on." It draws as a grey pill
  /// ([NexusSystemBubble]), it is not the model's words, and it is kept out of
  /// the history the brain is shown — an action the shell took is not an answer
  /// the model gave.
  final bool system;

  /// Whether a [system] line reports something that happened (true) or a
  /// refusal. Only the icon changes.
  final bool ok;
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
  const HomeTab({super.key, this.refreshEpoch = 0});

  /// Bumped by the shell each time this tab is opened.
  ///
  /// The line under the composer says where the next answer comes from, and it
  /// is read once when the screen mounts — which is right for the first answer
  /// and wrong for every one after the model is downloaded or deleted, or the
  /// PC's Ollama starts. A new number means "look again"; see
  /// [SettingsTab.refreshEpoch] for the same signal on the other screen.
  final int refreshEpoch;

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

  /// The conversation, in the order it was said. Empty until the user speaks:
  /// the screen used to open on two invented lines of its own (an assistant
  /// sentence and a question nobody had asked), which read as a chat that had
  /// already happened rather than as an app waiting to be used. What an empty
  /// thread shows instead is [_Welcome] — a heading, not a message.
  final List<NexusMockMessage> _thread = <NexusMockMessage>[];

  /// Whether the microphone has put words into the draft that is about to be
  /// sent.
  ///
  /// This is the whole rule behind the reply being read out loud: a turn the
  /// user *spoke* is answered in the same voice they used, and a turn they
  /// typed is answered in silence — text on screen, and the speaker button
  /// there for whoever wants it. Set where the recognizer's words land (the
  /// final transcript and the interim guesses alike), cleared by the send that
  /// consumes it. Merely opening the microphone is not enough: a session that
  /// heard nothing leaves the turn typed.
  bool _voiceTurn = false;

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
  /// closed, the voice light is blue, and the page is waiting on a future
  /// rather than on the user.
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

  /// The live conversation in progress, oldest first.
  ///
  /// One list, three readers: the page draws it, the model is handed it as
  /// history, and the chat thread inherits it when the room closes. A spoken
  /// sentence that is on screen but missing from what the model was told is the
  /// exact failure this feature exists to fix, so there is nowhere else for it
  /// to live.
  final List<NexusMockMessage> _liveThread = <NexusMockMessage>[];

  /// The recent turns as the brain wants them: what was said, by whom, oldest
  /// first, without the current prompt.
  ///
  /// The failure notices are dropped — the red "no brain answered" line is the
  /// shell talking about itself, and telling the model it said that would be
  /// putting words in its mouth. The last user turn is dropped too: it travels
  /// as the prompt, and passing it twice would have the model answer its own
  /// echo.
  List<AiTurn> get _liveHistory {
    final List<AiTurn> turns = <AiTurn>[
      for (final NexusMockMessage message in _liveThread)
        if (!message.failed)
          AiTurn(fromUser: message.mine, text: message.text),
    ];
    if (turns.isNotEmpty && turns.last.fromUser) turns.removeLast();
    return trimAiHistory(turns);
  }

  /// Adds one line to the live conversation, keeping it within
  /// [kLiveTranscriptMax] — oldest first, so what is dropped is the sentence
  /// that has scrolled off the top of the room.
  void _addLiveTurn(NexusMockMessage message) {
    _liveThread.add(message);
    if (_liveThread.length > kLiveTranscriptMax) {
      _liveThread.removeRange(0, _liveThread.length - kLiveTranscriptMax);
    }
  }

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
  void didUpdateWidget(covariant HomeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The user came back to this screen: re-read where answers come from, so
    // the line under the composer describes this moment rather than the moment
    // the app started.
    if (oldWidget.refreshEpoch != widget.refreshEpoch) unawaited(_readBrain());
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
    // The conversation the app was having last time. Read once, when the screen
    // opens, rather than per message: the point of it is what is on screen when
    // the app comes back, and there is no second moment that matters.
    unawaited(_restoreThread());
    ChatLog.instance.addListener(_onChatLog);
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
    ChatLog.instance.removeListener(_onChatLog);
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
    // Read once, here: whether this turn is answered out loud is a fact about
    // how it was dictated, and the flag is cleared by the send that consumes
    // it so the next typed question is not spoken on the strength of the last
    // spoken one.
    final bool spoken = _voiceTurn;
    _voiceTurn = false;
    setState(() {
      _thread.add(NexusMockMessage(text, mine: true));
      _thread.add(const NexusMockMessage(kNexusThinking, thinking: true));
      _message.clear();
    });
    // Written before the answer exists, on purpose: the question is the half of
    // the exchange that belongs to the user, and an app killed while it is
    // being answered should come back holding what was asked.
    _persistThread();
    _focus.unfocus();
    _scrollToLatest();
    // A request the phone's own vocabulary already understands is run here,
    // without asking the model to translate it: the translation is a closed
    // list, the shell has it, and a 0.5B model that answers "Brightness set to
    // 60%." without acting is the one failure this app cannot ship. The model
    // is still what answers everything else — including the relative steps
    // ("a bit dimmer") this cannot express.
    final SystemActionCall? known = actionFromPhrase(text);
    if (known != null) {
      unawaited(_runAction(known, _thread.length - 1, spoken: spoken));
      return;
    }
    unawaited(_answer(text, _thread.length - 1, spoken: spoken));
  }

  /// Puts the conversation from the last launch back on screen.
  ///
  /// [ChatLog.attach] is idempotent — the shell builds the tab once and keeps
  /// it alive — and a thread that already has something in it is never
  /// overwritten: what the user has just done beats what was on disk.
  Future<void> _restoreThread() async {
    final ChatLog log = ChatLog.instance;
    await log.attach();
    if (!mounted || log.entries.isEmpty) return;
    if (_thread.isNotEmpty) return;
    setState(() {
      _thread.addAll(<NexusMockMessage>[
        for (final ChatEntry entry in log.entries)
          NexusMockMessage(
            entry.text,
            mine: entry.mine,
            failed: entry.failed,
            system: entry.system,
            ok: entry.ok,
          ),
      ]);
    });
    _scrollToLatest();
  }

  /// Writes the thread, as the screen holds it, to the log.
  ///
  /// A placeholder is not a line of the conversation — it is the screen saying
  /// that an answer is on its way — so it is the one thing skipped. Everything
  /// else is written exactly as it is drawn, failures included: a question that
  /// went unanswered is part of the conversation, and hiding it on relaunch
  /// would make the app look like it had never been asked.
  void _persistThread() {
    ChatLog.instance.save(<ChatEntry>[
      for (final NexusMockMessage message in _thread)
        if (!message.thinking)
          ChatEntry(
            message.text,
            mine: message.mine,
            failed: message.failed,
            system: message.system,
            ok: message.ok,
          ),
    ]);
  }

  /// The log changed somewhere else — Settings cleared it — so the bubbles go
  /// with it. Our own saves land here too and are no-ops: they always leave the
  /// log with the thread in it.
  void _onChatLog() {
    final ChatLog log = ChatLog.instance;
    if (log.hasChat || _thread.isEmpty || !mounted) return;
    setState(_thread.clear);
    _scrollToLatest();
  }

  /// The conversation *before* the question at [index], as the brain is shown
  /// it.
  ///
  /// Without the placeholder (it is not something anybody said), without a
  /// failure notice (the shell talking about itself would be read as the
  /// assistant's answer), and without the question being asked — that one
  /// travels as the prompt, and a history that ended on it would ask it twice.
  /// [trimAiHistory] caps the list, so the model's context is a conversation
  /// rather than the whole day.
  ///
  /// An action line travels as the assistant's own turn, because as far as the
  /// *conversation* is concerned that is what it is: the answer to the question
  /// that was asked. Dropping it looks harmless and is not — the model is then
  /// handed two user turns in a row, and a 3B model reading "set a timer" with
  /// no reply followed by "turn on the flashlight" answered the timer again.
  /// The line stays the shell's (it is still drawn as a pill, it is still not
  /// something the model wrote); it is only *context* that it was said.
  List<AiTurn> _historyBefore(int index) {
    final List<AiTurn> turns = <AiTurn>[
      for (final NexusMockMessage message in _thread.take(index))
        if (!message.thinking && !message.failed)
          AiTurn(fromUser: message.mine, text: message.text),
    ];
    if (turns.isNotEmpty && turns.last.fromUser) turns.removeLast();
    return trimAiHistory(turns);
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
  Future<void> _answer(String prompt, int index, {required bool spoken}) async {
    final StringBuffer buffer = StringBuffer();
    // Whether any of the answer has been shown yet: until it has, the bubble is
    // still the placeholder and may be replaced under us; after it has, the
    // words on screen are this turn's.
    bool shown = false;
    bool failed = false;
    // Read before the request goes out: the history is everything said before
    // this question, so the answer knows what "it" refers to. The on-device
    // engine renders these turns through the model's own chat template (Qwen's
    // is ChatML) and Ollama through `/api/chat`; nothing here hand-writes
    // `<|im_start|>`, which would template the turns a second time.
    final List<AiTurn> history = _historyBefore(index);
    try {
      await for (final String piece
          in LocalAiService.current.generateResponseStream(
            prompt,
            history: history,
          )) {
        // The screen may be gone, and the bubble may have been answered
        // already by a seam that resolved twice: a replaced bubble is left
        // alone.
        if (!mounted || index >= _thread.length) return;
        if (!shown && !_thread[index].thinking) return;
        buffer.write(piece);
        // A reply that opens with `{` may be an action request, and half a JSON
        // object is not a sentence: the placeholder stays until the request is
        // whole and [_runAction] can say what happened. Prose streams exactly as
        // it always did, so nothing that is not an action pays for this.
        if (buffer.toString().trimLeft().startsWith('{')) continue;
        shown = true;
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
    // An answer that is one of the five actions is not an answer: it is the
    // model asking this phone to do something. It is run here, before anything
    // is shown, and the thread gets the shell's line about what happened rather
    // than the JSON that asked for it. A reply that is *nearly* an action — an
    // unknown name, a missing argument, prose that happens to contain braces —
    // parses to null and falls through to the bubble below, exactly as written.
    if (!failed) {
      final SystemActionCall? call = SystemActionCall.tryParse(reply);
      if (call != null) {
        await _runAction(call, index, spoken: spoken);
        return;
      }
    }
    setState(() => _thread[index] = NexusMockMessage(reply, failed: failed));
    // The answer is now half of what the next question will be read against.
    _persistThread();
    _scrollToLatest();
    // A spoken answer to a spoken question, and only then. [spoken] is how the
    // turn was dictated, not how it reads: a typed question gets the words on
    // screen and nothing out of the speaker, because a phone that starts
    // talking after a silent tap is the behaviour this rule exists to stop. The
    // speaker button under the bubble still reads any answer out loud on
    // request — the rule is about what happens *unasked*. It never blocks the
    // thread and never throws: a device with no speech engine just leaves the
    // words on the bubble. A failure is never spoken either — a machine
    // apologising for itself is noise, and half a sentence read aloud is worse
    // than one that is read.
    if (!failed && spoken) unawaited(SpeechOutput.current.speak(reply));
  }

  /// Runs one action the model asked for and puts the result in the thread.
  ///
  /// The line that lands is the shell's, not the model's: [SystemActionOutcome]
  /// carries what it did ("Flashlight on.") or the phone's own reason it could
  /// not ("What app should I open?"), and both belong on Nexus's side of the
  /// thread as a system pill instead of as an answer. A spoken question gets the
  /// line spoken back — the user asked out loud and is owed the confirmation
  /// out loud — which is the only difference between the two paths.
  Future<void> _runAction(
    SystemActionCall call,
    int index, {
    required bool spoken,
  }) async {
    final SystemActionOutcome outcome = await SystemActions.current.execute(call);
    if (!mounted || index >= _thread.length) return;
    setState(
      () => _thread[index] = NexusMockMessage(
        outcome.message,
        system: true,
        ok: outcome.ok,
      ),
    );
    // The action is half of what the next question will be read against, and it
    // is stored as what it is: a line the shell wrote, not an answer.
    _persistThread();
    _scrollToLatest();
    if (spoken) unawaited(SpeechOutput.current.speak(outcome.message));
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
      _voiceTurn = true;
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
      // Words the recognizer produced are what make the next send a spoken
      // turn. Set here rather than when the microphone opened, so a session
      // that heard nothing cannot speak for the message the user then types.
      if (_micMode != _MicMode.live) _voiceTurn = true;
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
    if (!await _ensureMicAllowed()) {
      _offerMicSettings();
      return;
    }
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
    // A microphone the user refused: the tap is the way back. Android will not
    // show its own dialog twice, so without this the button would be a dead
    // end — the refusal is a state the user can be in for the rest of the
    // session, and the settings page is the only thing that can change it.
    if (_micRefusal != null) {
      _offerMicSettings();
      return;
    }
    if (!_micUsable) return; // no microphone on this device at all
    unawaited(_micTapStart());
  }

  /// The tap's opening half: ask if it has to, then listen until the next tap.
  ///
  /// The ask can be on screen for a moment, and a hold can arrive while it is:
  /// whichever gesture gets there first owns the session, and the other finds
  /// [_listening] already true and leaves it alone.
  Future<void> _micTapStart() async {
    if (!await _ensureMicAllowed()) {
      _offerMicSettings();
      return;
    }
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
    if (!await _ensureMicAllowed()) {
      _offerMicSettings();
      return;
    }
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
      if (prompt.isNotEmpty) {
        _liveSaid = prompt;
        _addLiveTurn(NexusMockMessage(prompt, mine: true));
      }
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
    // Read once, before the request goes out: the history is the conversation
    // *up to* this question, and a later turn must not be able to change what
    // this one was asked with.
    final List<AiTurn> history = _liveHistory;
    // Only a sentence the model actually said is read out loud. The unreachable
    // notice is the shell talking, and hearing a machine apologise for its PC is
    // worse than reading it.
    bool spoken = true;
    try {
      await for (final String piece in LocalAiService.current
          .generateResponseStream(prompt, history: history)) {
        // Dropped when the page is gone or the user has already moved on: an
        // answer belongs to the turn that asked for it.
        if (!mounted || !_liveOpen || turn != _liveTurns) return;
        buffer.write(piece);
        // Same rule as the thread: a reply that opens with `{` may be an action
        // request, and the page says "Thinking…" for the half-second it takes
        // to be whole rather than spelling raw JSON out in large type.
        if (buffer.toString().trimLeft().startsWith('{')) continue;
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
    // An action asked for out loud is run here too, and its line takes the
    // large type exactly as an answer would: a user who says "it's dark in here"
    // to the live page should see the flashlight turn on, not a JSON object.
    final SystemActionCall? call = spoken
        ? SystemActionCall.tryParse(buffer.toString())
        : null;
    if (call != null) {
      final SystemActionOutcome outcome = await SystemActions.current.execute(
        call,
      );
      if (!mounted || !_liveOpen || turn != _liveTurns) return;
      setState(() {
        _liveThinking = false;
        _liveAnswering = false;
        _liveIdle = _LivePhase.waiting;
        _liveSaid = outcome.message;
        _liveAnswerText = '';
        _addLiveTurn(
          NexusMockMessage(outcome.message, system: true, ok: outcome.ok),
        );
      });
      _syncLive();
      unawaited(SpeechOutput.current.speak(outcome.message));
      return;
    }
    setState(() {
      _liveThinking = false;
      _liveAnswering = false;
      _liveIdle = _LivePhase.waiting;
      _liveSaid = buffer.toString();
      _liveAnswerText = '';
      // The answer joins the conversation, so the next question can be asked
      // about it — and so the chat thread has the whole exchange to inherit.
      // A failure joins it too, marked as one: it is a line the user has to be
      // able to read back in the thread, it is just not something the model
      // said (see [_liveHistory]).
      _addLiveTurn(NexusMockMessage(buffer.toString(), failed: !spoken));
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
    // What was said in the room belongs to the conversation, not to the room:
    // closing the page keeps the exchange in the chat thread, in the order it
    // happened, so the user can read back what they said out loud — and so the
    // next typed question is asked with the same thread behind it.
    final List<NexusMockMessage> spoken = List<NexusMockMessage>.of(
      _liveThread,
    );
    _liveThread.clear();
    if (mounted) {
      setState(() {
        _liveOpen = false;
        _liveIdle = _LivePhase.waiting;
        _liveThinking = false;
        _liveAnswering = false;
        _liveSaid = '';
        _liveAnswerText = '';
        _livePartial = '';
        if (spoken.isNotEmpty) _thread.addAll(spoken);
      });
      if (spoken.isNotEmpty) {
        // What was said in the room is part of the conversation now, so it is
        // part of what survives the app being closed.
        _persistThread();
        _scrollToLatest();
      }
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
      // A copy: the page draws from this while the next turn mutates the list,
      // and a list that changes under a paint is a list that paints half of two
      // conversations.
      turns: List<NexusMockMessage>.of(_liveThread),
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

  /// The way out of a refused permission: a dialog that says which permission
  /// is missing and offers to open the page where it is turned back on.
  ///
  /// Shown after a gesture that asked and was refused, never before one: the
  /// system's own dialog is the first ask, and this is the second — the one a
  /// user who has said no needs, because the button they are pressing cannot do
  /// anything from here. Android will not show its dialog twice, so a screen
  /// that only set a notice would leave the user holding a dead control with no
  /// way back; `openAppSettings` is that way, and it already exists on the
  /// platform side (MainActivity), put there for the capability rows.
  ///
  /// Deliberately not awaited: the gesture that opened it has already ended.
  void _offerMicSettings() {
    if (!mounted) return;
    unawaited(_showMicSettingsDialog());
  }

  Future<void> _showMicSettingsDialog() async {
    final bool open = await showNexusPermissionDialog(
      context,
      title: 'Microphone permission needed',
      message:
          _micRefusal ??
          'Nexus needs the microphone to hear you. Allow it in system '
              'settings, then come back.',
    );
    if (!open) return;
    await DeviceCapabilities.current.openAppSettings();
  }

  /// Whether this device has a microphone to offer at all — the drawing
  /// question, answered by [DeviceCapabilities] rather than by the permission
  /// state: a refused microphone is a button that explains itself, and no
  /// microphone is no button.
  bool get _voiceAvailable => DeviceCapabilities.current.microphoneAvailable;

  /// Whether the mic button can do anything at all: a device that can listen,
  /// and a microphone the user has not refused.
  bool get _micUsable => _voiceAvailable && _micAllowed != false;

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
  ///
  /// Silent on a device with no microphone, because there is nothing there to
  /// explain: the refusal is about a button the user can see, and this is a
  /// button that is not drawn.
  String? get _micNotice => _voiceAvailable ? _micRefusal : null;

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
                // Everything said on this screen can be highlighted, word by
                // word or across several bubbles, the way text on a page can.
                // The per-bubble Copy button stays as it was: a selection is
                // the fine case, and one tap to take the whole sentence is
                // still the common one. A long press now belongs to the
                // selection rather than to a copy that took the entire line.
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: _threadScroll,
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (_thread.isEmpty)
                          const _Welcome()
                        else
                          const SizedBox(height: 30),
                        for (final message in _thread)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            // A failure is not a reply: it takes a notice of its
                            // own instead of a bubble, so a red, bordered
                            // sentence with a warning sign can never be mistaken
                            // for something the assistant said.
                            child: message.system
                                ? NexusSystemBubble(
                                    text: message.text,
                                    ok: message.ok,
                                    maxWidth: bubbleWidth,
                                  )
                                : message.failed
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
            showVoice: _voiceAvailable,
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

/// The screen an empty thread shows: a heading and the one promise that is true
/// before anything has been said.
///
/// Deliberately not a message. The two bubbles that used to sit here were drawn
/// by the same code path as a real answer, which made them indistinguishable
/// from one — and the first thing a user learned about the app was a sentence
/// the app had put in the assistant's mouth.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Hey, what do you need?',
          textAlign: TextAlign.center,
          style: NexusType.greeting(c),
        ),
        const SizedBox(height: 8),
        Text(
          'Ask me anything. Your devices answer directly — no account, no '
          'cloud.',
          textAlign: TextAlign.center,
          style: NexusType.lede(c),
        ),
      ],
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
/// A long press on the bubble selects, on both sides of the thread: the hold
/// belongs to the [SelectionArea] the thread is wrapped in, so a word or a
/// sentence can be taken the way it is on a page. It used to copy the whole
/// line, which both hid the gesture behind an invisible clipboard write and
/// took the hold away from selection — the two cannot share one press, and the
/// finer one is the one worth having. Copying a whole answer in one tap is what
/// the copy control under Nexus's side is for.
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
            // No gesture detector around the bubble: a press and a hold both
            // belong to the selection around it. The bubble's own padding is
            // still inside the painted box, and long-pressing it starts a
            // selection wherever the finger landed.
            Container(
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
            if (!mine && !thinking) _MessageActions(text: text),
          ],
        ),
      ),
    );
  }
}

/// The pill that stands where an *action* was carried out.
///
/// Deliberately the quietest of the three: no bubble colour, no rim, no shadow.
/// A bubble is somebody speaking and a failure notice is somebody apologising;
/// this is the app confirming a thing it did, and it should read like a status
/// line that happens to be in the conversation — a raised pill, one glyph, one
/// short sentence. The glyph is the only difference between success and refusal
/// (a tick, or an information mark), because both are the same kind of line and
/// painting the refusal red would make a fact look like a fault.
///
/// It carries no copy and no speaker of its own: the sentence is short enough to
/// read at a glance, and a user who wants it again can ask for the action again.
class NexusSystemBubble extends StatelessWidget {
  const NexusSystemBubble({
    super.key,
    required this.text,
    this.ok = true,
    this.maxWidth = 320,
  });

  final String text;

  /// True for something that happened, false for a refusal the phone explained.
  final bool ok;

  /// Cap on the pill, the same cap a bubble gets.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: kNexusSystemBubble,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: c.raised,
            border: Border.all(color: c.hairline),
            borderRadius: const BorderRadius.all(NexusLayout.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                ok ? Icons.check_circle_outline : Icons.info_outline,
                size: 15,
                color: ok ? c.accent : c.textMuted,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  text,
                  style: NexusType.rowMeta(c).copyWith(
                    fontSize: 13,
                    color: c.textStrong,
                  ),
                ),
              ),
            ],
          ),
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
/// Its text is selectable like a bubble's, and for the same reason: the hold is
/// the page gesture, and the copy control is the one-tap shortcut.
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
            Container(
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
    required this.showVoice,
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

  /// Whether this device has a microphone at all. False on a device that cannot
  /// listen — an iPhone this build has no recognizer for, a desktop, a tablet
  /// with the feature stripped — and then the mic button and the live button
  /// are *not drawn*.
  ///
  /// This is the one case where hiding beats disabling. The rule the two
  /// buttons follow when they are on screen is the opposite — a refused
  /// microphone is drawn inert with the reason on it, because a button that
  /// vanishes the moment the user says "don't allow" reads as a bug in a
  /// screen they were just using. But a device with no microphone was never
  /// going to listen, and a permanently dead control in the composer's tightest
  /// row is a promise the app cannot keep: the pill is simply shorter, and the
  /// field is wider for it.
  final bool showVoice;

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
                    // The voice half of the pill, drawn only where there is a
                    // microphone to open. Both buttons go together: they are
                    // the same recognizer, so a device that cannot dictate
                    // cannot have a live conversation either — and the live
                    // button was already inert in that case, which is exactly
                    // the "permanently dead control" this flag stops drawing.
                    if (showVoice) ...<Widget>[
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
                    ] else if (hasText) ...<Widget>[
                      // No microphone on this device, so there is no hold to
                      // take and nothing to stop: the trailing slot is the send
                      // arrow alone, and it appears with the first character
                      // the user types. Leaving it out entirely would have made
                      // the one control a device with no voice still needs — the
                      // way to send what was typed — a casualty of the feature
                      // it has nothing to do with.
                      const SizedBox(width: 8),
                      _RoundAction(
                        key: const ValueKey<String>('send'),
                        icon: Icons.arrow_upward_rounded,
                        tooltip: 'Send',
                        onTap: onSend,
                      ),
                    ],
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

  /// False draws the circle neutral: in this file purple means the user can act
  /// on it, and a button that will not do its job is not purple.
  ///
  /// It is deliberately *not* a refusal of the tap. A muted control still owes
  /// the user an answer for why, and on a phone — where nothing hovers — the
  /// tooltip is not one: the tap is how the reason arrives, whether that reason
  /// is a sentence in the composer or the dialog that offers the settings page
  /// a refused permission is turned back on in. What a tap means is the
  /// caller's business, decided in the gesture that owns the button.
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
        // The tap is the short gesture: it starts nothing, it explains. The
        // splash is the acknowledgement that the tap landed at all.
        onTap: onTap,
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
  const _LevelBars({super.key, required this.level, this.color});

  /// The loudness, 0..1, from [rmsToLevel]. Zero is a silent room and is drawn
  /// as dots, not as an empty slot.
  final double level;

  final Color? color;

  /// The composer's meter is the one that shows these five bars; the live page
  /// has its own, rolling waveform ([_LiveWaveform]), which is why the counts
  /// and sizes are constants here rather than parameters nobody passes.
  static const int bars = 5;
  static const double width = 3.5;
  static const double maxHeight = kNexusBarMaxHeight;
  static const double minHeight = kNexusBarMinHeight;

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
    this.turns = const <NexusMockMessage>[],
  });

  final _LivePhase phase;
  final String partial;
  final String said;

  /// The answer being written, empty unless [phase] is [_LivePhase.answering].
  final String answer;

  /// The conversation so far, oldest first — the same turns the model was told
  /// to remember, which is what makes the page a room with a memory rather than
  /// one sentence at a time.
  final List<NexusMockMessage> turns;

  /// Whether the microphone is open right now — the one question the badge, the
  /// orb, the meter and the status line all answer from.
  bool get listening => phase == _LivePhase.listening;
}

/// How many messages of live conversation are kept. The page shows as many as a
/// screen can hold, and the model is handed the same list: a 0.5B model's context
/// window is 2048 tokens, and a conversation longer than this would be spent on
/// remembering rather than on answering.
const int kLiveTranscriptMax = 12;

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
        // The chosen accent, not the shipped one: the room is dark either way,
        // but which colour means "the mic is open" is the user's choice.
        accent: c.accent,
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
              // Once the turn is over the transcript holds what was said, and
              // the last of it is the line in flight's place — so the headline
              // for these phases is the *last turn itself*, drawn once, in the
              // same spot. A quiet room with nothing said yet still says so.
              _ => live.turns.isEmpty
                  ? 'Say something.'
                  : live.turns.last.text,
            };
            // True when the tap on the pulse would resume, i.e. whenever the
            // page is not in the middle of something it has to finish.
            final bool idle =
                live.phase != _LivePhase.listening &&
                live.phase != _LivePhase.thinking &&
                live.phase != _LivePhase.answering;
            // What is drawn *above* the headline. When the turn is over the
            // last turn is the headline, so the transcript stops one short of
            // the end — otherwise the last thing said would be printed twice.
            final List<NexusMockMessage> olderTurns = idle
                ? live.turns.sublist(0, live.turns.isEmpty ? 0 : live.turns.length - 1)
                : live.turns;
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
                // The conversation, which is what this page is now made of:
                // reversed, so it is anchored to the bottom — the newest line
                // sits just above the controls and older ones read upward, the
                // way a conversation does. The page used to be one sentence
                // around a two-inch orb; a room you can talk in has to show
                // what was said in it.
                Expanded(
                  child: ListView(
                    key: kNexusLiveTranscript,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                    children: <Widget>[
                      // Bottom-most first, because the list is reversed: the
                      // line in flight, or the last thing said once the turn is
                      // over. It is the same widget either way, and the only one
                      // carrying [kNexusLiveText].
                      _LiveLine(
                        text: headline,
                        mine: live.phase == _LivePhase.listening,
                        primary: true,
                        palette: palette,
                      ),
                      for (final NexusMockMessage turn in olderTurns.reversed)
                        _LiveLine(
                          text: turn.text,
                          mine: turn.mine,
                          failed: turn.failed,
                          palette: palette,
                        ),
                    ],
                  ),
                ),
                // The meter while it listens, and the same promise the Privacy
                // page makes — said here too, where the microphone actually is.
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    children: <Widget>[
                      // The pulse: the page's heartbeat, small and at the
                      // bottom where the controls are. It is also the resume
                      // control — with the microphone closed its grey light is
                      // the obvious thing to press, and "tap it to go again" is
                      // the one instruction this page has.
                      GestureDetector(
                        // A control exactly when the tap would do something:
                        // while a turn is live there is nothing to resume, and
                        // while an answer is being written the tap is refused by
                        // [_liveResume] anyway — better inert than ignored.
                        onTap: idle ? onResume : null,
                        behavior: HitTestBehavior.opaque,
                        child: _LivePulse(phase: live.phase, palette: palette),
                      ),
                      const SizedBox(height: 12),
                      // The voice, drawn: a rolling waveform whose bars are the
                      // microphone's own readings, interpolated between them by
                      // a ticker (see [_LiveWaveform]).
                      SizedBox(
                        height: 56,
                        child: _LiveWaveform(
                          level: level,
                          listening: live.listening,
                          color: live.listening
                              ? palette.accent
                              : palette.muted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        switch (live.phase) {
                          _LivePhase.listening => 'Listening — just speak.',
                          _LivePhase.thinking =>
                            // Not "on your PC": the same page is shown when the
                            // answer is coming from this device, and the line
                            // names the wait, not the machine.
                            'Mic off — asking the AI…',
                          _LivePhase.answering => 'Mic off — answering…',
                          _LivePhase.waiting => 'Mic off — tap to continue.',
                          _LivePhase.guarded => 'Mic off. Nothing is recording.',
                        },
                        key: kNexusLiveStatus,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          color: palette.muted,
                          fontSize: 14,
                        ),
                      ),
                      // The other way on. Deliberately a button and never a
                      // countdown: the microphone is closed until a person asks
                      // for it, which is the whole fix for a phone that used to
                      // restart itself after every turn.
                      if (idle) ...<Widget>[
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: kNexusLiveResume,
                          onPressed: onResume,
                          icon: const Icon(Icons.mic_rounded, size: 18),
                          label: const Text('Tap to continue'),
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 22),
                            textStyle: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
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
    final Color accent = context.ui.accent;
    return Container(
      key: kNexusLiveRecordingIndicator,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.28),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
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

/// One line of the live conversation.
///
/// The newest line is [primary]: larger, brighter, and allowed to wrap over four
/// lines, because it is the thing the user is listening to or waiting on. The
/// ones above it are the memory of the room — smaller, dimmer, each one a single
/// scrollable line so a long answer cannot push the conversation off the screen.
class _LiveLine extends StatelessWidget {
  const _LiveLine({
    required this.text,
    required this.mine,
    required this.palette,
    this.primary = false,
    this.failed = false,
  });

  final String text;

  /// Whose words these are: the user's are set back in the accent's ink and
  /// aligned right, the assistant's are the page's own ink, aligned left.
  final bool mine;
  final bool failed;
  final bool primary;
  final _LivePalette palette;

  @override
  Widget build(BuildContext context) {
    final Color ink = failed
        ? kNexusLiveThinking
        : mine
        ? palette.accent
        : palette.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        // The key goes on the [Text] rather than on this wrapper: the newest
        // line is the one read back by its key, and what is read is the words.
        key: primary ? kNexusLiveText : null,
        textAlign: mine ? TextAlign.right : TextAlign.left,
        maxLines: primary ? 4 : 3,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(
          color: primary ? ink : ink.withValues(alpha: 0.62),
          fontSize: primary ? 30 : 17,
          height: 1.24,
          fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// The live page's status light: the one wordless answer to what the phone is
/// doing, in colour and motion, small enough to live beside the controls.
///
/// * Listening — the accent, breathing, with a ring leaving it on every breath.
/// * Thinking — blue, pulsing: the microphone is closed and the AI is writing.
/// * Anything else — grey and still.
///
/// Colour is as load-bearing as motion on purpose: motion alone is too easy to
/// miss, and a still accent-coloured light still looks live to somebody glancing
/// at the screen. The states never share a hue, so the page can be read from
/// across a room in the time it takes to glance at it.
///
/// It used to be a 240dp orb in the middle of the page, which said the same
/// thing while taking the space the conversation now uses. Same keys, same
/// states, a twentieth of the pixels.
class _LivePulse extends StatefulWidget {
  const _LivePulse({required this.phase, required this.palette});

  final _LivePhase phase;
  final _LivePalette palette;

  bool get listening => phase == _LivePhase.listening;

  /// Whether the light is in its working colour: the model is writing (or about
  /// to write), so the page pulses blue either way — an answer arriving slowly is
  /// still the same wait, and a colour change halfway through it would read as a
  /// state change the user has to interpret.
  bool get thinking =>
      phase == _LivePhase.thinking || phase == _LivePhase.answering;

  /// Whether this state moves at all. Both of the moving states are states where
  /// something is happening that the user is waiting on; the still ones are the
  /// states where the next move is the user's.
  bool get animated => listening || thinking;

  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse>
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
  void didUpdateWidget(covariant _LivePulse oldWidget) {
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
            (widget.thinking ? 0.16 : widget.listening ? 0.10 : 0) * pulse;
        final Color glow = widget.listening
            ? palette.accent
            : widget.thinking
            ? kNexusLiveThinking
            : palette.muted;
        final double glowAlpha = widget.listening
            ? 0.5
            : widget.thinking
            ? 0.44 + 0.24 * pulse
            : 0.16;
        // The lit core is the accent's own gradient: same colour, three stops,
        // so choosing Ocean Blue changes what "listening" looks like without
        // any second definition of it.
        final Color lit = palette.accent;
        final HSLColor litHsl = HSLColor.fromColor(lit);
        final List<Color> core = widget.listening
            ? <Color>[
                litHsl
                    .withLightness((litHsl.lightness + 0.18).clamp(0.0, 1.0))
                    .toColor(),
                lit,
                litHsl
                    .withLightness((litHsl.lightness - 0.28).clamp(0.0, 1.0))
                    .toColor(),
              ]
            : widget.thinking
            ? const <Color>[
                kNexusLiveThinkingLight,
                kNexusLiveThinking,
                kNexusLiveThinkingDeep,
              ]
            : palette.idleCore;
        return SizedBox(
          key: kNexusLiveOrb,
          width: 76,
          height: 76,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Transform.scale(
                scale: breathe,
                child: Container(
                  width: 74,
                  height: 74,
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
                  width: 26 + 48 * t,
                  height: 26 + 48 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: palette.accent.withValues(
                        alpha: 0.55 * (1 - t),
                      ),
                      width: 1.5,
                    ),
                  ),
                ),
              Transform.scale(
                scale: widget.listening ? breathe : 1,
                // The colour change is eased but quick, and the grey is a
                // property of the closed state rather than of the animation: a
                // test can ask for the idle light and find it the moment the
                // turn ends, without waiting for a fade.
                child: AnimatedContainer(
                  // One key per visual state, on purpose: a test — and a person —
                  // should be able to ask "which state is it in?" and get an
                  // answer that is the state, not an interpolation between two
                  // of them.
                  key: widget.listening
                      ? null
                      : widget.thinking
                      ? kNexusLiveOrbThinking
                      : kNexusLiveOrbIdle,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.4),
                      colors: core,
                    ),
                    border: widget.animated
                        ? null
                        : Border.all(color: palette.idleCore.last),
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

/// The live page's voice meter, as a painter: round-capped bars rolling left,
/// their heights interpolated between the recognizer's readings by a [Ticker].
///
/// Why a ticker and not the [TweenAnimationBuilder] the composer's meter uses:
/// Android calls `onRmsChanged` a handful of times a second, and each reading is
/// a *step*. A widget that animates between two steps shows two shapes — the
/// old one and the new one — which is what "it snaps like two images" means.
/// This reads the clock instead: every frame, the drawn level moves a fraction of
/// the way toward the newest reading (an exponential chase, [_chaseSeconds]), and
/// the bar array rolls at [_barsPerSecond] so the waveform has *direction* rather
/// than only height. Sixty frames a second of small movements is what reads as
/// one continuous voice.
///
/// The heights are public so a test can watch them move: this is the one widget
/// in the shell whose whole output is a motion.
class NexusLiveWavePainter extends CustomPainter {
  const NexusLiveWavePainter({required this.heights, required this.color});

  /// The width of one bar, and of the gap between them at rest.
  static const double dotWidth = 3.5;

  /// One entry per bar, 0..1. Zero draws a dot rather than nothing: a microphone
  /// that is open and hearing silence must look different from a page that has
  /// stopped drawing.
  final List<double> heights;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (heights.isEmpty || size.width <= 0) return;
    final double slot = size.width / heights.length;
    final Paint paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = dotWidth;
    final double middle = size.height / 2;
    for (int i = 0; i < heights.length; i++) {
      final double cx = slot * (i + 0.5);
      final double half = math.max(dotWidth / 2, heights[i] * size.height / 2);
      canvas.drawLine(
        Offset(cx, middle - half),
        Offset(cx, middle + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(NexusLiveWavePainter old) =>
      old.color != color || !listEquals(old.heights, heights);
}

/// That painter, fed by the microphone.
class _LiveWaveform extends StatefulWidget {
  const _LiveWaveform({
    required this.level,
    required this.listening,
    required this.color,
  });

  /// How many bars fit across the page. Fixed rather than passed: the meter is
  /// drawn full width, so the count is a property of the design and not of a
  /// call site.
  static const int bars = 44;

  /// The same readings the composer's meter takes, 0..1.
  final ValueListenable<double> level;

  /// Whether the microphone is open. Closed does not mean frozen: the bars keep
  /// decaying to their resting dots rather than cutting out.
  final bool listening;

  final Color color;

  /// How long the drawn level takes to close most of the gap to a new reading.
  /// Short enough that a shout lands on the same breath, long enough that the
  /// gaps between Android's readings disappear.
  static const double _chaseSeconds = 0.11;

  /// How fast the waveform rolls. About two bars a frame at 60Hz: fast enough to
  /// read as flow, slow enough that a sentence is not a blur.
  static const double _barsPerSecond = 34;

  /// How long a quiet room keeps moving after the last voice. This is the pause
  /// the bars fall through, not the end of the turn — that is the recognizer's
  /// own, and longer ([kSpeechTurnGap]).
  static const double _tailSeconds = 1.0;

  @override
  State<_LiveWaveform> createState() => _LiveWaveformState();
}

class _LiveWaveformState extends State<_LiveWaveform>
    with SingleTickerProviderStateMixin {
  /// Growable on purpose: the roll is a `removeAt(0)` and an `add`, which is the
  /// cheapest way to shift a short array 34 times a second.
  late final List<double> _heights = List<double>.filled(
    _LiveWaveform.bars,
    0,
    growable: true,
  );
  late final Ticker _ticker = createTicker(_tick);

  /// The newest reading, and the level actually being drawn — the second one is
  /// what the ticker moves, and it is the only one a frame uses.
  double _target = 0;
  double _level = 0;

  /// Seconds since the last reading above the resting threshold, and the part of
  /// a bar the roll still owes — both accumulate on the frame clock, so a slow
  /// frame does not slow the waveform down.
  double _quietFor = 0;
  double _carry = 0;

  /// Which sample this is, counted so a reading draws as a wobbling waveform
  /// rather than as a flat bar chart — deterministically, with no random number
  /// generator a test would have to tolerate.
  int _sampleIndex = 0;

  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _target = widget.listening ? widget.level.value : 0;
    _level = _target;
    widget.level.addListener(_onReading);
    _start();
  }

  @override
  void dispose() {
    widget.level.removeListener(_onReading);
    _ticker.dispose();
    super.dispose();
  }

  void _onReading() {
    _target = widget.level.value;
    if (_target > 0) _quietFor = 0;
    _start();
  }

  /// Starts the clock if there is anything it could change. A silent, resting
  /// waveform is a still picture, and a still picture that repaints sixty times
  /// a second is a battery drain pretending to be an animation.
  void _start() {
    if (_ticker.isActive) return;
    if (!widget.listening) return;
    if (_quietFor > _LiveWaveform._tailSeconds) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final Duration since = _last;
    _last = elapsed;
    // Clamped: a frame after a stall must not move the whole waveform at once.
    final double dt = since == Duration.zero
        ? 1 / 60
        : ((elapsed - since).inMicroseconds / 1e6).clamp(0.0, 0.05);
    final bool voice = _target > 0.004 && widget.listening;
    _quietFor = voice ? 0 : _quietFor + dt;
    // An exponential chase toward the newest reading: this is the interpolation
    // between two images, and it is why a step from 0.1 to 0.9 takes about a
    // tenth of a second instead of arriving in one frame.
    final double chase = 1 - math.exp(-dt / _LiveWaveform._chaseSeconds);
    _level += (_target - _level) * chase;
    if (!widget.listening || _quietFor > 0.6) {
      // Falling back to rest is slower than rising, and deliberate: a voice that
      // stops should leave a waveform that settles, not one that is gone.
      _level += (0 - _level) * chase * 0.6;
    }
    // The roll, in whole bars, however many the frame earned.
    _carry += dt * _LiveWaveform._barsPerSecond;
    int moved = 0;
    while (_carry >= 1 && moved < _LiveWaveform.bars) {
      _carry -= 1;
      moved++;
      _heights.removeAt(0);
      _heights.add(_nextSample());
    }
    // The roll is what retires a tall bar: it travels left and off the end, and
    // a silent room fills in behind it with dots. That is why the clock keeps
    // running until the array itself is at rest — stopping the moment the *level*
    // reaches zero would freeze the last shout on screen forever.
    final bool settled =
        !voice &&
        _level < 0.004 &&
        _quietFor > _LiveWaveform._tailSeconds &&
        _heights.every((double height) => height < 0.004);
    if (settled) {
      // A still picture does not need sixty frames a second: the meter stops
      // here and starts again on the next reading ([_onReading] → [_start]).
      _ticker.stop();
      setState(() {});
      return;
    }
    setState(() {});
  }

  /// One new bar: the drawn level, shaped by a fixed wobble so the row reads as
  /// a waveform rather than as a ruler.
  double _nextSample() {
    final int i = _sampleIndex++;
    final double wobble =
        0.58 + 0.42 * math.sin(i * 0.7) * math.cos(i * 0.31);
    return (_level * wobble).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: kNexusLiveWave,
      size: Size.infinite,
      painter: NexusLiveWavePainter(
        heights: List<double>.of(_heights),
        color: widget.color,
      ),
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
///
/// The list is [PairedDevices] rather than a constant, which is the whole
/// change this screen has been waiting for: a pairing made on this screen is
/// the same list the next screen reads, and it is still there after a restart.
/// The online/offline word beside each row is the state the row was written
/// with — see the note at the top of `paired_devices.dart` — because live
/// reachability is the mesh's answer and this front end has no mesh.
class DevicesTab extends StatefulWidget {
  const DevicesTab({super.key});

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  /// The list this screen draws. The app-wide one, unless a test has put
  /// another in its place.
  PairedDevices get _paired => PairedDevices.instance;

  /// True for the two seconds the "Discover nearby" button spends pretending to
  /// look. See [_discoverNearby] for why it is a shape and not a feature.
  bool _discovering = false;

  @override
  void initState() {
    super.initState();
    _paired.addListener(_onChanged);
    // The stored list arrives asynchronously — it is a preference read — so the
    // screen corrects itself from the settled store rather than staying on the
    // seed rows. Idempotent: a second Devices tab (or a rebuild) re-reads
    // nothing.
    unawaited(_paired.attach());
  }

  @override
  void dispose() {
    _paired.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final List<PairedDevice> devices = _paired.devices;
    return NexusTabBody(
      title: 'Devices',
      subtitle: 'Paired directly, over your own network.',
      // The way in that a user looks for first: a + in the corner of the page
      // they are already on, rather than a row they have to scroll to the end
      // of the list to find. Both open the same sheet.
      trailing: IconButton(
        key: kNexusAddDevice,
        tooltip: kNexusAddDeviceLabel,
        onPressed: () => unawaited(showDevicePairingSheet(context)),
        icon: const Icon(Icons.add_rounded),
        color: c.accent,
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Paired'),
          for (final device in devices) ...<Widget>[
            NexusRow(
              title: device.name,
              subtitle: device.detail.isEmpty
                  ? 'Paired directly — no account, no server'
                  : device.detail,
              leading: NexusIconTile(_iconFor(device)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    device.online ? 'Online' : 'Offline',
                    style: NexusType.rowMeta(c),
                  ),
                  const SizedBox(width: 8),
                  NexusStatusDot(online: device.online),
                  // Forget, on every row but this device's own: a device cannot
                  // unpair from itself, and offering the button there would be
                  // offering a control that does nothing. The bin is the whole
                  // of the control — the confirmation behind it is what makes
                  // it safe to have no label.
                  if (!device.isThisDevice) ...<Widget>[
                    const SizedBox(width: 2),
                    IconButton(
                      key: ValueKey<String>('forget-${device.id}'),
                      tooltip: 'Forget ${device.name}',
                      onPressed: () => unawaited(_forget(device)),
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      color: c.danger,
                    ),
                  ],
                ],
              ),
              onTap: () => nexusNotWired(context, 'Device details'),
            ),
            Divider(height: 1, thickness: 1, color: c.hairline, indent: 56),
          ],
          NexusRow(
            title: kNexusPairTitle,
            subtitle: 'Show your code, or scan one from another device',
            leading: const NexusIconTile(Icons.add_rounded),
            accentTitle: true,
            onTap: () => unawaited(showDevicePairingSheet(context)),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: kNexusDiscoverNearby,
            onPressed: _discovering ? null : _discoverNearby,
            icon: _discovering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.radar_rounded, size: 18),
            label: Text(
              _discovering ? 'Looking for devices…' : 'Discover Nearby Devices',
            ),
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

  /// What the row's tile shows: the phone for this device, a desktop for the
  /// seeded example peers, and a generic device for anything that paired by
  /// scanning — the invite does not say what kind of machine it is, and
  /// guessing from the name would be a guess printed as a fact.
  IconData _iconFor(PairedDevice device) {
    if (device.isThisDevice) return Icons.smartphone_rounded;
    if (device.id == 'example-pc') return Icons.desktop_windows_rounded;
    if (device.id == 'example-mac') return Icons.laptop_mac_rounded;
    return Icons.devices_other_rounded;
  }

  /// Takes a device off the list, after asking.
  ///
  /// The question is not politeness. Forgetting is the only way to break a
  /// pairing and nothing on this screen can undo it — the other device has to
  /// pair again — so the bin icon is a door, and the dialog is what stands in
  /// front of it. The confirm button is painted in the danger colour and says
  /// the same word the row's tooltip did, so nobody has to translate "unpair"
  /// to know what they are agreeing to.
  Future<void> _forget(PairedDevice device) async {
    final bool confirmed = await showNexusConfirm(
      context,
      title: kNexusForgetTitle,
      message:
          '${device.name} will have to pair with this device again before it '
          'can send or receive anything.',
      confirmLabel: 'Forget',
    );
    if (!confirmed || !mounted) return;
    if (!_paired.forget(device.id)) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Forgot ${device.name}.'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// The button at the bottom of the list: what a nearby-device hunt will one
  /// day be.
  ///
  /// It spends two seconds looking at nothing and then says so, and that is the
  /// honest version of a control that has to exist before the thing behind it
  /// does: a button that answered instantly would read as broken, and one that
  /// claimed to have found something would be lying about the one property this
  /// app is built on. The wait is a [Future.delayed] rather than a fake progress
  /// loop because there is nothing being waited *for*.
  Future<void> _discoverNearby() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _discovering = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(kNexusDiscoverySoon)));
  }
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

/// What the scanner says when the code in front of it is somebody else's.
///
/// One sentence, and it is the negative half of the whole flow: a QR code is
/// the most common thing in the world to point a camera at, so "that was not
/// ours" has to be a thing the user is *told* rather than something that
/// silently happens. A constant because the test that reads it should be
/// reading the same words the user does.
const String kNexusNotAPairCodeText = 'This is not a Nexus device code.';

/// What it says about a code that *is* Nexus's, but from a build whose pairing
/// this shell cannot complete — the older `nexus://pair` codes, which carry a
/// one-time secret and a port rather than an invite.
///
/// Deliberately different from [kNexusNotAPairCodeText]: the user is holding a
/// Nexus device, and telling them their own device is not one would send them
/// looking for the wrong problem.
const String kNexusLegacyPairCodeText =
    'That is a Nexus code from an older build — update that device to pair.';

/// The title on the sheet, the QR page and the scanner.
const String kNexusPairTitle = 'Pair a device';

/// The + in the Devices header, and what it is called out loud. The key is what
/// a test taps; the label is what a screen reader says.
const Key kNexusAddDevice = Key('nexus-add-device');
const String kNexusAddDeviceLabel = 'Add a device';

/// Test seam for the camera, in the same shape as [MicrophoneAccess]'s: a
/// widget test answers with an invite instead of opening one.
///
/// A function rather than a class because what the shell does with it is one
/// call, and because the page is the only implementation — there is nothing for
/// a fake to subclass.
@visibleForTesting
Future<PairInvite?> Function(BuildContext context)? debugPairScannerOverride;

/// Opens the scanner: the real camera page, or whatever a test has put in its
/// place. Answers null when the user backed out or the camera could not start.
Future<PairInvite?> openPairScanner(BuildContext context) async {
  final override = debugPairScannerOverride;
  if (override != null) return override(context);
  return Navigator.of(context).push<PairInvite>(
    MaterialPageRoute<PairInvite>(
      builder: (routeContext) => const PairScanPage(),
      fullscreenDialog: true,
    ),
  );
}

/// The fork in the road: scan a code, or show one.
///
/// A sheet rather than a page because both answers leave this screen: one opens
/// the camera, the other asks the user to pick up their other device.
///
/// Named apart from `ui/pair_sheet.dart`'s `showPairSheet`, which is the mesh
/// sheet with a live `MeshService` behind it: this one has no mesh, only the
/// invite a QR can carry, and two functions with one name would be a choice
/// made by import order.
Future<void> showDevicePairingSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.ui.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      final c = sheetContext.ui;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The grab handle, so the sheet reads as a sheet rather than as a
              // page that has slid up.
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(kNexusPairTitle, style: NexusType.rowTitle(c)),
              const SizedBox(height: 4),
              Text(
                'Two devices, one code. Nothing leaves the room.',
                style: NexusType.rowMeta(c),
              ),
              const SizedBox(height: 14),
              NexusRow(
                title: kNexusScanQrLabel,
                subtitle: 'Point this camera at the code on the other device',
                leading: const NexusIconTile(Icons.qr_code_scanner_rounded),
                trailing: const NexusChevron(),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_scanFrom(context));
                },
              ),
              NexusRow(
                title: kNexusShowQrLabel,
                subtitle: 'Let the other device scan this one',
                leading: const NexusIconTile(Icons.qr_code_2_rounded),
                trailing: const NexusChevron(),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (routeContext) => const PairQrPage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      );
    },
  );
}

/// The two rows on the sheet, named once so the sheet and the tests that open
/// it are talking about the same words.
const String kNexusScanQrLabel = 'Scan QR code';
const String kNexusShowQrLabel = 'Show my QR code';

/// Runs the scanner and puts whatever came back into the paired list.
///
/// Split out from the sheet so the sheet can close first: a modal sheet left
/// open under a camera page is a sheet that comes back when the camera is
/// dismissed, which is not what "scan a code" means.
Future<void> _scanFrom(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final PairInvite? invite = await openPairScanner(context);
  if (invite == null) return;
  final bool added = PairedDevices.instance.add(invite);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          added
              ? 'Paired with ${invite.deviceName}'
              : '${invite.deviceName} is already paired.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
}

/// The code this device shows: one QR, its own name under it, and the sentence
/// that says what to do with it.
///
/// The QR is drawn on white in both themes — a scanner needs the contrast, and
/// an inverted QR is a QR that does not read — and the payload is deliberately
/// *not* printed on screen: it is 150 characters of JSON, and the one thing a
/// user could do with it is mistype it.
class PairQrPage extends StatelessWidget {
  const PairQrPage({super.key, this.identity});

  /// Who this device is. Null uses [PairIdentity.current]; a test states it, so
  /// the QR it asserts on is not a random id.
  final PairIdentity? identity;

  /// The string the QR carries.
  ///
  /// A getter rather than an inline expression in [build] because it is the one
  /// thing about this page a test can check without a camera — `QrImageView`
  /// keeps its data private — so the page says what it draws, in one place,
  /// and the test parses that same string back into an invite.
  String get payload => (identity ?? PairIdentity.current).invite.encode();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final PairIdentity who = identity ?? PairIdentity.current;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text(kNexusPairTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: <Widget>[
          Text('Scan this with the other device', style: NexusType.rowTitle(c)),
          const SizedBox(height: 6),
          Text(
            'Nexus on the other device reads this code and puts this one in its '
            'list. Nothing is uploaded, and the code stops being useful the '
            'moment you close this screen.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          const SizedBox(height: 22),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.hairline),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: QrImageView(
                  data: payload,
                  size: 236,
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  semanticsLabel: 'Pairing code for ${who.name}',
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: <Widget>[
              const NexusIconTile(Icons.smartphone_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(who.name, style: NexusType.rowTitle(c)),
                    const SizedBox(height: 2),
                    Text(
                      'This device · ${who.id.substring(0, 6)}…',
                      style: NexusType.rowMeta(c),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Paired devices can see and send files to each other directly. Get '
            'rid of one from the Devices tab at any time.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// The camera page: full screen, one frame in the middle, and a pill that says
/// what the last code was if it was not ours.
///
/// The scanner is deliberately greedy in one direction and strict in the other:
/// it hands the raw text of *every* code it sees to the parser, and only a code
/// that parses closes the page. Anything else leaves the camera running with a
/// sentence on screen — a user pointing at the wrong code wants to try the right
/// one, not to be sent back to the sheet.
class PairScanPage extends StatefulWidget {
  const PairScanPage({super.key, this.cameraBuilder});

  /// Test seam: a widget that calls `onCode(text)` instead of opening a camera.
  ///
  /// A camera in a widget test is a platform channel that is not there, so the
  /// page is built around "where the codes come from" rather than around
  /// [MobileScanner] itself — which is what makes the parse/refuse/replace
  /// behaviour provable without a phone pointed at anything.
  final Widget Function(BuildContext context, ValueChanged<String> onCode)?
  cameraBuilder;

  @override
  State<PairScanPage> createState() => _PairScanPageState();
}

class _PairScanPageState extends State<PairScanPage> {
  /// The last code that was not ours, cleared on a two-second clock: long
  /// enough to read, short enough that the next attempt starts clean.
  String? _notice;
  Timer? _noticeTimer;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// One scanned string: ours, or a sentence about why not.
  void _onCode(String raw) {
    final PairInvite? invite = PairInvite.parse(raw);
    if (invite != null) {
      Navigator.of(context).pop(invite);
      return;
    }
    _showNotice(
      raw.trim().startsWith('nexus://pair')
          ? kNexusLegacyPairCodeText
          : kNexusNotAPairCodeText,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final Widget Function(BuildContext, ValueChanged<String>) camera =
        widget.cameraBuilder ?? _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(kNexusPairTitle),
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: camera(context, _onCode)),
          // The frame, so it is obvious where to point the camera.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: context.ui.accent, width: 2.5),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          if (_notice != null)
            Positioned(
              top: 24,
              left: 20,
              right: 20,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: NexusType.rowMeta(
                        c,
                      ).copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 44,
            child: Text(
              'Point at the QR code on the other device',
              textAlign: TextAlign.center,
              style: NexusType.rowMeta(c).copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  /// The real camera. A refused permission, a phone with no camera, and a
  /// desktop are one screen: the framework reports all three here, and the
  /// answer to all three is the same sentence and the same way back.
  Widget _camera(BuildContext context, ValueChanged<String> onCode) {
    // A desktop build has no scanner plugin behind it. Asking first is the
    // difference between the guidance below and a `MissingPluginException`
    // thrown from inside the plugin's own async start — which arrives as an
    // unhandled error with nothing on screen to act on. Android, iOS and macOS
    // do have an implementation; Linux and Windows do not.
    if (!_cameraPlatformSupported) return _cameraUnavailable(context);
    return MobileScanner(
      onDetect: (BarcodeCapture capture) {
        for (final Barcode barcode in capture.barcodes) {
          final String? raw = barcode.rawValue ?? barcode.displayValue;
          if (raw == null || raw.trim().isEmpty) continue;
          // The first code in the frame is the one being pointed at; the rest
          // arrive in the same capture and are not the user's intent.
          onCode(raw);
          return;
        }
      },
      errorBuilder: (context, error) {
        debugPrint('PAIR scan: camera error $error');
        return _cameraUnavailable(context);
      },
    );
  }

  /// Whether there is a scanner behind [MobileScanner] on this platform.
  ///
  /// The plugin ships Android, iOS, macOS and web implementations. Everywhere
  /// else the widget still builds — and then throws while starting its
  /// controller — so the question has to be asked before it is built.
  bool get _cameraPlatformSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// What the page says when there is nothing to look through: no permission,
  /// no camera on this machine, or no camera support in this build. One
  /// screen and one sentence per half, because the answer to all three is the
  /// same — allow it in settings, or show your own code instead.
  Widget _cameraUnavailable(BuildContext context) {
    final c = context.ui;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(
              Icons.no_photography_outlined,
              size: 44,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              'The camera could not start.',
              style: NexusType.rowTitle(c).copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              'Allow the camera for Nexus in this device’s settings, then '
              'come back — or show your own code instead and let the other '
              'device scan it.',
              textAlign: TextAlign.center,
              style: NexusType.rowMeta(c).copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
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
    this.followSystem = true,
    this.onFollowSystemChanged,
    this.accent = NexusAccent.purple,
    this.onAccentChanged,
    this.scrollController,
    this.onDevice,
    this.refreshEpoch = 0,
  });

  /// The appearance on screen right now — which, while [followSystem] is on, is
  /// the phone's answer rather than the user's.
  final bool darkMode;

  final ValueChanged<bool> onDarkModeChanged;

  /// Whether the phone's own light/dark setting is the one in charge.
  final bool followSystem;

  final ValueChanged<bool>? onFollowSystemChanged;

  /// The accent the app is painting with, and the one the swatches show as
  /// selected.
  final NexusAccent accent;
  final ValueChanged<NexusAccent>? onAccentChanged;

  /// The list's scroll position, owned by the shell so that arriving on this
  /// screen always starts at the top. Null builds one of its own, which is what
  /// a widget test that pumps the tab by itself gets.
  final ScrollController? scrollController;

  /// The on-device brain the Brain section manages. Null builds the real one;
  /// a test supplies one pointed at a temp directory, which is what makes the
  /// status, download and delete rows provable without 470 MB or a platform
  /// channel.
  final OnDeviceAiService? onDevice;

  /// Bumped by the shell each time this tab is opened.
  ///
  /// The Brain section asks where answers come from once, on mount, because
  /// that question costs a file check and an HTTP probe. Keeping that answer for
  /// ever is the bug this exists to stop: on a phone whose PC's Ollama starts
  /// after Nexus did, the row said "No AI" for the rest of the session while
  /// answers worked. A changed number means "you are being looked at again", so
  /// the answer is re-read — and while the reading is in flight the row says so.
  final int refreshEpoch;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _wakeWord = true;
  bool _spokenReplies = false;

  /// Whether this device can run a model of its own at all.
  ///
  /// Answered by [DeviceCapabilities], so the decision is one line here and
  /// the same line on every other screen: a device that cannot load the weights
  /// is not offered them. What changes on such a device is the *section* — the
  /// status row stays, because "where do the answers come from" is still a
  /// question with a real answer (the PC, or nothing), and the download and
  /// delete rows are replaced by one sentence naming the way out.
  bool get _onDeviceSupported => DeviceCapabilities.current.supportsOnDeviceAi();

  /// What the status row says under its label.
  ///
  /// [AiStatus.detail] is written for a device that could download the model,
  /// and its "none" case points at the download button below. On a device that
  /// has no such button, the same words would be an instruction the user cannot
  /// follow, so the sentence is the one thing that is overridden here.
  String get _aiDetail {
    final AiStatus? status = _aiStatus;
    if (status == null) return 'Checking where the answers come from…';
    if (!_onDeviceSupported && status.source == AiSource.none) {
      return 'No AI available. Start Ollama on your PC — this device cannot '
          'run a model of its own.';
    }
    return status.detail;
  }

  /// Whether anything in the Voice section can be switched on this device. The
  /// wake word is Android-only (openWakeWord over ONNX Runtime) and spoken
  /// replies are the platform's own TTS, wired up for Android here; a device
  /// with neither gets no Voice section rather than a screen of dead switches.
  bool get _voiceSupported =>
      DeviceCapabilities.current.supportsWakeWord ||
      DeviceCapabilities.current.supportsSpokenReplies;

  /// How many switches the Voice page will really have: one on a device whose
  /// build only does one of the two, and the row's subtitle is written from
  /// this rather than promising both.
  int get _voiceSwitches =>
      (DeviceCapabilities.current.supportsWakeWord ? 1 : 0) +
      (DeviceCapabilities.current.supportsSpokenReplies ? 1 : 0);

  /// What that lone switch is called, for the row's subtitle.
  String get _voiceSingleSwitchName =>
      DeviceCapabilities.current.supportsWakeWord
      ? 'The wake word'
      : 'Spoken replies';

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

  /// Which models are on the disk, so the picker can say so before the user
  /// taps one and waits for a download that is already there.
  Map<OnDeviceModelChoice, bool> _present =
      const <OnDeviceModelChoice, bool>{};

  /// The selection itself, shared with the brain — not a copy of it. A switch
  /// made here is what the next question loads.
  late final ModelChoice _choice = ModelChoice.instance;

  /// The model the rows below the picker are about: the selected one.
  OnDeviceModel get _selectedModel => _onDevice.model.withChoice(_choice.choice);

  /// True from the tap on the appearance switch until the frame that paints the
  /// new theme. The switch becomes a small spinner for that window.
  ///
  /// No artificial delay: on a phone the swap is usually inside one frame and
  /// the spinner is gone before it can be seen, which is the correct cost — the
  /// indicator earns its place on the slow case (a long thread being re-laid out
  /// under a new theme) rather than by being a tax on the fast one.
  bool _themeBusy = false;

  /// The scroll position, either the shell's or this screen's own.
  late final ScrollController _scroll = widget.scrollController ?? ScrollController();

  /// The conversation on this device. This screen does not draw it — the Home
  /// tab does — but it is the only screen that can offer to delete it, so it
  /// reads the same log and listens for the count changing.
  late final ChatLog _chat = ChatLog.instance;

  @override
  void dispose() {
    _chat.removeListener(_onChatChanged);
    _choice.removeListener(_onModelChoiceChanged);
    // Only a controller this state made is this state's to free; the shell's
    // outlives the tab it lent it to.
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  /// The conversation changed — a message was added on the Home tab, or it was
  /// just cleared here — so the row that counts it is rebuilt.
  void _onChatChanged() {
    if (mounted) setState(() {});
  }

  /// The selection changed — here, or somewhere else that shares it — so the
  /// rows that describe it are re-read rather than re-rendered from the old
  /// model's size and state.
  void _onModelChoiceChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_refreshBrain());
  }

  /// Switches the model, and re-reads what that means.
  ///
  /// A model that is on the disk takes over immediately: the brain reads the
  /// selection on its next question, so there is nothing else to do. A model
  /// that is not downloaded becomes the selection too — the download row below
  /// the picker is then about *that* file, which is what "select it, then
  /// download it" means.
  Future<void> _selectModel(OnDeviceModelChoice choice) async {
    if (_downloading || choice == _choice.choice) return;
    await _choice.select(choice);
    if (!mounted) return;
    await _refreshBrain();
  }

  /// Flips dark mode, with the switch showing that the frame is changing.
  Future<void> _toggleDark(bool value) async {
    if (_themeBusy) return;
    setState(() => _themeBusy = true);
    widget.onDarkModeChanged(value);
    // Two frames: the one that rebuilds the shell against the new theme, and
    // the one that paints it. Waiting for the *paint* is the point — a control
    // that comes back before the screen has changed is a control that reported
    // success for something the user cannot see yet.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) setState(() => _themeBusy = false);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshBrain());
    // The stored conversation is read here as well as on Home, because this is
    // the screen that has to know whether there is one to clear — and which
    // screen was built first is not something to depend on. `attach` is
    // idempotent.
    _chat.addListener(_onChatChanged);
    unawaited(_chat.attach());
    // The model picker draws the selection, and anything else that changes it —
    // a second Settings tab, a future deep link — has to move this one too.
    _choice.addListener(_onModelChoiceChanged);
  }

  @override
  void didUpdateWidget(covariant SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The tab was just opened again: re-read the brain, so the rows describe
    // the moment the user is looking at them rather than the moment the app
    // started. The number is a signal and never a value.
    if (oldWidget.refreshEpoch != widget.refreshEpoch) {
      unawaited(_refreshBrain());
    }
  }

  /// Re-reads where the answers come from, and how big the model on this device
  /// is. Both answers are cheap — a file check and one HTTP probe — and both
  /// are allowed to fail: a row that cannot be computed says the honest thing.
  Future<void> _refreshBrain() async {
    // The stored selection is read before anything is asked about it: a first
    // launch can reach this screen before the preference has been loaded, and
    // the row would otherwise describe the default model for a frame and then
    // change under the user.
    await _choice.ensureLoaded();
    final Map<OnDeviceModelChoice, bool> present =
        <OnDeviceModelChoice, bool>{};
    for (final OnDeviceModelChoice choice in OnDeviceModelChoice.values) {
      present[choice] = await _onDevice.model.withChoice(choice).isPresent();
    }
    final bool here = present[_choice.choice] ?? false;
    final int bytes = here ? await _selectedModel.sizeBytes() : 0;
    final AiStatus status = await AiStatus.detect(model: _selectedModel);
    if (!mounted) return;
    setState(() {
      _present = present;
      _modelPresent = here;
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

  /// Asks before clearing the conversation, and clears only on a yes.
  ///
  /// The same red confirm the model's delete uses, because it is the same kind
  /// of row: the user's own words, gone, with no copy anywhere else to restore
  /// them from. The count in the sentence is read before the dialog, so the
  /// question says what is about to be deleted.
  Future<void> _confirmClearChat() async {
    final int count = _chat.length;
    final String messages = count == 1 ? '1 message' : '$count messages';
    final bool confirmed = await showNexusConfirm(
      context,
      title: kNexusClearChatTitle,
      message:
          'This deletes $messages on this device. Nothing was uploaded, and '
          'nothing can be recovered.',
      confirmLabel: 'Clear',
    );
    if (!confirmed || !mounted) return;
    final int cleared = _chat.length;
    _chat.clear();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            cleared == 1 ? 'Cleared 1 message.' : 'Cleared $cleared messages.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Asks before deleting, and deletes only on a yes.
  ///
  /// The row is red and the dialog says what the megabytes cost the user — a
  /// model that goes away takes offline answers with it, which is not something
  /// to discover on a train. Every other way out of the dialog (Cancel, the back
  /// gesture, a tap outside) leaves the file alone: the default answer to "are
  /// you sure" has to be no.
  Future<void> _confirmDeleteModel() async {
    final int megabytes = _megabytes(_modelBytes);
    final bool confirmed = await showNexusConfirm(
      context,
      title: kNexusDeleteModelTitle,
      message:
          'This will free up $megabytes MB, but you will not be able to chat '
          'offline — answers would come from your PC instead.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    await _deleteModel();
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
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Theme'),
          NexusRow(
            title: 'Follow system',
            subtitle: 'Use your phone’s light and dark setting',
            leading: const NexusIconTile(Icons.brightness_auto_outlined),
            trailing: Switch(
              value: widget.followSystem,
              onChanged: (bool value) =>
                  widget.onFollowSystemChanged?.call(value),
            ),
          ),
          NexusRow(
            title: 'Dark mode',
            subtitle: widget.followSystem
                ? 'From your phone — turn off Follow system to choose'
                : 'Neutral greys either way — your accent stays for actions',
            leading: const NexusIconTile(Icons.dark_mode_outlined),
            key: kNexusDarkModeRow,
            // The switch becomes a spinner for the frame or two the new theme
            // takes to land, so a tap is never a control that looks stuck.
            trailing: _themeBusy
                ? const SizedBox(
                    key: kNexusThemeBusy,
                    width: 26,
                    height: 26,
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Switch(
                    value: widget.darkMode,
                    // While the phone is in charge, the switch reports what the
                    // phone decided and cannot be overridden from here: an
                    // enabled switch that bounced straight back would look
                    // broken, and the row above it is the one that has to move.
                    onChanged: widget.followSystem ? null : _toggleDark,
                  ),
          ),
          _AccentRow(
            selected: widget.accent,
            onSelected: widget.onAccentChanged,
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
          if (_voiceSupported) ...<Widget>[
            const NexusSectionLabel('Voice'),
            NexusRow(
              title: 'Voice & speech',
              subtitle: _voiceSwitches == 1
                  ? _voiceSingleSwitchName
                  : 'Wake word, replies, voice',
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
          ],
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
          // The conversation is the one thing on this screen that is the user's
          // own words rather than the app's settings, so it gets its own
          // section — and the row only exists when there is something to
          // forget.
          if (_chat.hasChat) ...<Widget>[
            const NexusSectionLabel('Chat'),
            NexusRow(
              title: kNexusClearChatRow,
              subtitle: _chat.length == 1
                  ? 'Deletes 1 message on this device'
                  : 'Deletes ${_chat.length} messages on this device',
              leading: const NexusIconTile(Icons.delete_sweep_outlined),
              trailing: const NexusChevron(),
              // Red, and it asks first: the conversation cannot be fetched back
              // from anywhere, which is the whole promise this app makes.
              dangerTitle: true,
              onTap: _confirmClearChat,
            ),
          ],
          // Where the words come from, and the one row that can change it. The
          // status is a value, not a switch: there is nothing to turn on — the
          // app asks the device and then the PC on its own — and the only
          // choice the user has is whether the 470 MB lives on this phone.
          const NexusSectionLabel('Brain'),
          NexusRow(
            title: 'AI status',
            subtitle: _aiDetail,
            leading: const NexusIconTile(Icons.memory_rounded),
            trailing: Text(
              _aiStatus?.label ?? 'Checking…',
              style: NexusType.rowMeta(c),
            ),
          ),
          // The download half of the section, which is the half that has to be
          // earned: a device whose platform cannot load the weights, or whose
          // memory cannot hold them, is told so in one sentence and the button
          // is never drawn. The sentence names the other way to get an answer,
          // because "not supported" with nothing after it is a dead end.
          if (!_onDeviceSupported)
            const NexusRow(
              title: 'On-device model',
              subtitle: kNoOnDeviceAiText,
              leading: NexusIconTile(Icons.memory_outlined),
            )
          else ...<Widget>[
            // The picker: one row per model, the selected one ticked and the
            // downloaded ones saying so. Two rather than one because the small
            // model is not the right model for every job — it is quick, and it
            // drops formatting rules like the action JSON, which is a trade the
            // user is allowed to make either way.
            //
            // Selecting a model that is not on the disk is not an error and not
            // a download: it makes the row below the picker a Download row for
            // *that* model, which is the order the two decisions are made in.
            for (final OnDeviceModelChoice choice in OnDeviceModelChoice.values)
              _ModelChoiceRow(
                choice: choice,
                selected: choice == _choice.choice,
                present: _present[choice] ?? false,
                onTap: () => unawaited(_selectModel(choice)),
              ),
            if (_downloading)
              _BrainProgress(
                progress: _downloadProgress,
                label: _selectedModel.label,
                megabytes: _selectedModel.model.megabytes,
              )
            else if (_modelPresent)
              NexusRow(
                title: 'On-device model',
                subtitle:
                    '${_selectedModel.label} — ${_megabytes(_modelBytes)} MB '
                    'on this device',
                leading: const NexusIconTile(Icons.download_done_rounded),
                trailing: Text('Downloaded', style: NexusType.rowMeta(c)),
              )
            else
              NexusRow(
                title: 'Download model',
                subtitle:
                    '${_selectedModel.label} — '
                    '${_selectedModel.model.megabytes} MB. Runs here, no '
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
                // Red, and it asks first: this is the one row on the screen
                // that destroys something the user waited 470 MB for.
                dangerTitle: true,
                onTap: _confirmDeleteModel,
              ),
            if (_brainError != null)
              NexusRow(
                title: 'Download failed',
                subtitle: _brainError,
                leading: const NexusIconTile(Icons.warning_amber_rounded),
              ),
          ],
          const NexusSectionLabel('About'),
          // The build's own name, not a description of what is not wired yet:
          // the row used to read "UI shell preview — no model attached" while
          // the model was answering questions, which is the kind of line a user
          // reads once and then trusts.
          NexusRow(
            title: 'Version',
            subtitle:
                'Nexus $appVersion — on-device answers, no account, no cloud',
            leading: const NexusIconTile(Icons.info_outline_rounded),
            trailing: Text(appVersion, style: NexusType.rowMeta(c)),
          ),
        ],
      ),
    );
  }
}

/// One model in the picker: what it is, whether it is on the disk, and whether
/// it is the one the brain will load.
///
/// A row rather than a radio button in a dialog: the two models differ by size
/// and by what that size buys, and a user choosing between 470 MB and 770 MB
/// should be able to read both sentences at once. The tick is the selection —
/// one of them is always selected, so this is a choice with a current answer,
/// not a checkbox.
class _ModelChoiceRow extends StatelessWidget {
  const _ModelChoiceRow({
    required this.choice,
    required this.selected,
    required this.present,
    required this.onTap,
  });

  final OnDeviceModelChoice choice;
  final bool selected;

  /// Whether these weights are on this device. Drives the subtitle, not the
  /// selection: a model that has not been downloaded yet can still be chosen.
  final bool present;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final int megabytes = choice.weights.megabytes;
    return NexusRow(
      title: choice.label,
      subtitle: present
          ? '$megabytes MB · on this device\n${choice.blurb}'
          : '$megabytes MB · not downloaded\n${choice.blurb}',
      leading: NexusIconTile(
        selected ? Icons.memory_rounded : Icons.memory_outlined,
      ),
      trailing: selected
          ? Icon(Icons.check_circle, size: 20, color: c.accent)
          : const NexusChevron(),
      onTap: onTap,
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
    // One row per switch this device can really offer. The wake word is an
    // Android engine (openWakeWord over ONNX Runtime) and spoken replies are
    // the platform's own text to speech, wired up for Android here — on a
    // device with neither, the page says so instead of drawing switches that
    // could do nothing. Both rows are gated on the same object the composer
    // asks, so a feature is never offered in one place and denied in another.
    final bool wakeWordHere = DeviceCapabilities.current.supportsWakeWord;
    final bool repliesHere = DeviceCapabilities.current.supportsSpokenReplies;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Voice & speech')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          if (wakeWordHere)
            NexusRow(
              title: 'Wake word',
              subtitle: 'Listen for “Hey Nexus” while the app is open',
              leading: const NexusIconTile(Icons.hearing_outlined),
              trailing: Switch(value: wakeWord, onChanged: onWakeWordChanged),
            ),
          if (repliesHere)
            NexusRow(
              title: 'Speak replies',
              subtitle: 'Read answers out loud when they arrive',
              leading: const NexusIconTile(Icons.volume_up_outlined),
              trailing: Switch(
                value: spokenReplies,
                onChanged: onSpokenRepliesChanged,
              ),
            ),
          if (!wakeWordHere && !repliesHere)
            const NexusRow(
              title: 'Voice',
              subtitle:
                  'Wake word and spoken replies are not available on this '
                  'device.',
              leading: NexusIconTile(Icons.voice_over_off_outlined),
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
