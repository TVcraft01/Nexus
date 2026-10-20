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
///     large type, and hands the turn back 1.5 s after the answer has been read
///     out — with a Stop speaking control (and a tap anywhere) to end the voice
///     and stay quiet. See [_HomeTabState] for the session, [_HoldToTalk] for the
///     gesture
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
import 'dart:convert' show jsonDecode;
import 'dart:io' show File;
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
import 'package:flutter_localizations/flutter_localizations.dart';
// The colour wheel in Settings → Theme. A package rather than a hand-rolled
// wheel for the obvious reason: a wheel that is nearly a colour space is worse
// than no wheel, and this one is the HSV wheel with the hex bar under it.
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    show ColorPicker, ColorLabelType, PaletteType;
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:url_launcher/url_launcher.dart';

import 'core/ai_status.dart';
import 'core/appearance.dart';
import 'core/artifacts.dart';
import 'core/attachment_pickers.dart';
import 'core/attachments.dart';
import 'core/chat_log.dart';
import 'core/clock_context.dart' show isClockQuestion;
import 'core/composer_settings.dart';
import 'core/interaction_mode.dart';
import 'core/device_capabilities.dart';
import 'core/device_memory.dart';
import 'core/fast_path.dart';
import 'core/file_link.dart';
import 'core/local_ai_service.dart';
import 'core/local_library.dart';
import 'core/log_service.dart';
import 'core/memory_service.dart';
import 'core/math_helper.dart';
import 'core/mic_access.dart';
import 'core/ml_vision_service.dart';
import 'core/ollama_service.dart';
import 'core/on_device_ai_service.dart';
import 'core/on_device_model.dart';
import 'core/onboarding.dart';
import 'core/pair_invite.dart';
import 'core/paired_devices.dart';
import 'core/qr_pairing.dart' show QrPairingToken;
import 'core/screen_capture.dart';
import 'core/thought.dart';
import 'core/vision_ai.dart';
import 'core/voice_settings.dart';
import 'core/web_search.dart';
import 'core/system_prompt.dart';
import 'core/services/icon_service.dart';
import 'mesh/discovery.dart' show DiscoveredDevice;

// The thought splitter moved to `core` so the chat log can use it when it
// reads an old answer; this export keeps every existing importer of the shell
// (tests included) compiling without a second name for the same thing.
export 'core/thought.dart' show NexusThoughtSplit, splitNexusThought;
import 'mesh/nearby.dart' show NearbyDevices;
import 'core/version.dart';
import 'ui/artifact_page.dart';
import 'ui/image_viewer_page.dart';
import 'ui/local_files.dart' show openLocalFile;
import 'ui/text_file_page.dart';
import 'core/speech.dart';
import 'core/system_actions.dart';
import 'mesh/updater.dart';

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

  /// The swatch the row draws: the colour the user actually picked, not the
  /// legible version derived for a page. A pale `#FBF5FF` has to show as a pale
  /// disc — the row is a colour being chosen, and showing its darkened ink there
  /// made a near-white pick look like a purple one.
  Color get swatch => seed;

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
  bool operator ==(Object other) => other is NexusAccent && other.seed == seed;

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

/// The screen-share control on the live page. Live mode is the only place it
/// lives: sharing the screen is something said in a conversation, not a button
/// beside a draft in the composer.
const Key kNexusLiveScreenShare = Key('nexus-live-screen-share');

/// The way back from a guard trip: live conversation stops listening rather
/// than looping for ever, and this is the one control that reopens the mic.
const Key kNexusLiveResume = Key('nexus-live-resume');

/// The interruption control while the assistant is speaking. One tap cuts the
/// voice off, and the microphone stays closed: the user asked for quiet, not
/// for the next turn.
const Key kNexusLiveStopSpeaking = Key('nexus-live-stop-speaking');
const String kNexusLiveStopSpeakingLabel = 'Stop';

/// The sentence under the orb: the page's plain-language answer to "is the
/// microphone on?".
const Key kNexusLiveStatus = Key('nexus-live-status');

/// The orb while the answer is being written on the PC — blue and pulsing, so
/// "working on it" is never mistaken for "listening to you" or "stopped".
const Key kNexusLiveOrbThinking = Key('nexus-live-orb-thinking');

/// Live mode's Gemini-shaped controls: the menu, the minimize arrow, the
/// photos door, the mic circle, and the centre spinner with its timer.
const Key kNexusLiveMenu = Key('nexus-live-menu');
const Key kNexusLiveMinimize = Key('nexus-live-minimize');
const Key kNexusLivePhotos = Key('nexus-live-photos');
const Key kNexusLiveMic = Key('nexus-live-mic');
const Key kNexusLiveSpinner = Key('nexus-live-spinner');
const Key kNexusLiveThinkTimer = Key('nexus-live-think-timer');

/// The wide layout's breakpoint: at or above this width the chat history is a
/// column of its own instead of a drawer.
///
/// 600 is the usual phone-landscape/tablet line, and it is chosen for the same
/// reason Anthropic's web client chose its own breakpoint: below it, 280 points
/// of sidebar leaves a chat column narrower than a phone in portrait, and a
/// two-pane layout that starves the pane you are reading is worse than one pane.
const double kNexusWideBreakpoint = 600;

/// The sidebar's width when it is permanent. Wide enough for a date group and a
/// two-word chat title, narrow enough that the thread keeps the majority of a
/// small tablet.
const double kNexusSidebarWidth = 280;

/// The RAM a PC needs before it is worth suggesting the 3B model. Eight
/// gigabytes is the model's own floor with room for the desktop around it —
/// below it the download is slower than the answers it buys.
const int kComfortablePcRamBytes = 8 * 1024 * 1024 * 1024;

/// The "your PC can run a better model" notice, its sentence, and the command
/// it offers to copy.
const Key kNexusPcUpgradeBanner = Key('nexus-pc-upgrade-banner');
const Key kNexusPcUpgradeCopy = Key('nexus-pc-upgrade-copy');
const String kNexusPcUpgradeText =
    'Your PC is connected! Download Llama 3.2 3B on your PC for smarter '
    'answers.';
const String kNexusPcUpgradeCommand = 'ollama run llama3.2:3b';

/// A photo handed to live mode, and the question the vision layer is asked
/// about it. The caption is the user's line in the transcript, the prompt is
/// what the model is told — two sentences because one is read by a person and
/// the other by a model.
const String kLivePhotoCaption = 'Photo attached';
const String kLivePhotoPrompt = '[User attached a photo] What do you see?';

/// What both surfaces say while the model on the PC is being asked: the thread's
/// placeholder bubble and the live page's large type.
///
/// One constant for both because it is one state — the request is out, nothing is
/// recording, and the only thing that can happen next is an answer.
const String kNexusThinking = 'Nexus is thinking…';

/// What the thread says when a reply was nothing but punctuation.
///
/// `{}` is the one shape [nexusReadableText] takes everything out of: there is
/// no answer field to read and no words between the braces. An empty bubble
/// would look like a rendering fault, and the object itself is not something a
/// person can read, so the shell says the only true thing left.
const String kNexusNoAnswerText = "I don't have an answer for that.";

/// What the thread says when the selected model does not fit in the phone's
/// memory.
///
/// Red, and actionable: the app has already tried the smaller model if the user
/// has it, so the only thing left to say is which download would fit. "Not
/// enough memory" on its own would be a dead end; deleting the model and taking
/// Qwen 0.5B is the way forward, and it is the sentence the user is given.
const String kNexusNotEnoughMemoryText =
    'Not enough memory to run this model. Please delete it and download '
    'Qwen 0.5B.';

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
    // Solid red, not a muted brick and not the pink the dark theme used: a
    // delete control has to read as destructive before it is read.
    danger: Color(0xFFD32F2F),
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
    // [Colors.redAccent], hardcoded: the old pink (#FFB4AB) read as a faded
    // secondary action rather than as "this deletes something".
    danger: Color(0xFFFF5252),
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
  // The lines the app already writes to `debugPrint` are also kept in memory,
  // where the hidden Developer Logs tab can show them.
  LogService.install();
  // The eyes. Installed here rather than inside [VisionAiService.current] so
  // the interface does not import ML Kit and a widget test never builds a
  // platform model it cannot run.
  VisionAiService.defaultFactory = MlVisionService.new;
  // Memory is a file read and a preference read, and both are needed before
  // the first answer rather than before the first frame. Started here, awaited
  // by the services on their first use if they are not ready yet.
  // The `+` sheet's switches are read at the moment the model is asked, not
  // when the closure is installed: turning Memory off must change the very
  // next answer, without a restart.
  LocalAiService.memoryContext = () => ComposerSettings.instance.memoryEnabled
      ? MemoryService.instance.systemContext
      : '';
  LocalAiService.customInstructions = () {
    final String custom = SystemPrompt.instance.context;
    // The first-run mode is a style instruction, appended after whatever the
    // user wrote themselves: their words win, and this only fills in how to
    // say it.
    final String style = InteractionModeSetting.instance.effective.instruction;
    return custom.trim().isEmpty ? style : '$custom\n\n$style';
  };
  unawaited(ComposerSettings.instance.attach());
  unawaited(InteractionModeSetting.instance.attach());
  unawaited(MemoryService.instance.attach());
  unawaited(SystemPrompt.instance.attach());
  unawaited(VoiceSettings.instance.attach());
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
  return colour == kNexusAccent
      ? NexusAccent.purple
      : NexusAccent.custom(colour);
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

  /// Whether the interaction-mode question has been answered.
  ///
  /// It starts true, and the welcome screen is the only thing that can turn it
  /// false. The question is part of a first run, not a gate on every launch:
  /// a device that finished onboarding on 1.1 has no stored mode, and asking
  /// it now — before a thread, before the user has touched anything — would be
  /// a question the app never earned. Settings offers the same two choices, so
  /// an upgrade can still say which one it is.
  bool _modeChosen = true;

  /// The language voice listens and speaks in — and, since there is one
  /// setting, the language the interface asks the system for.
  ///
  /// It is read from [VoiceSettings] rather than stored a second time: a user
  /// who picks Français in Voice & speech has already said what language they
  /// read, and two preferences would let the transcript, the spoken reply and
  /// the screen disagree.
  late final VoiceSettings _voice = VoiceSettings.instance;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChanged);
    // The first reply should not pay for constructing a speech engine. This is
    // a warm-up, not a request to speak: a device with no engine answers false
    // and the card stays the answer.
    unawaited(SpeechOutput.current.warmUp());
    unawaited(
      _voice.attach().then((_) {
        if (mounted) setState(() {});
      }),
    );
    unawaited(MemoryService.instance.attach());
    // Which launcher mark this device wears is settled at launch, not the first
    // time somebody opens the icon picker: in Auto the system theme decides, and
    // a phone switched to dark overnight was otherwise still wearing the light
    // mark until a Settings visit. attach() is idempotent; the picker calls it
    // again.
    unawaited(IconService.instance.attach());
    Onboarding.isDone().then((bool done) {
      if (mounted) setState(() => _onboarded = done);
    });
    // Read the stored mode in the background: the shell does not wait for it,
    // and only the welcome screen's exit asks whether it needs an answer.
    unawaited(InteractionModeSetting.instance.attach());
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    super.dispose();
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
  ///
  /// This is also where the hybrid-mode question is decided, because this is
  /// the one moment the app knows it has a first run in front of it. A store
  /// that could not be read counts as answered: [needsChoice] is built on
  /// `loaded`, and [InteractionModeSetting.attach] settles that either way.
  Future<void> _finishOnboarding() async {
    await InteractionModeSetting.instance.attach();
    if (!mounted) return;
    setState(() {
      _onboarded = true;
      _modeChosen = !InteractionModeSetting.instance.needsChoice;
    });
  }

  /// The first-run mode was chosen: save it, and move into the shell.
  Future<void> _finishModeChoice(InteractionMode mode) async {
    await InteractionModeSetting.instance.select(mode);
    if (mounted) setState(() => _modeChosen = true);
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
      // The interface language follows the voice language: one setting moves
      // the recognizer, the voice, and the words on screen, so a French phone
      // does not dictate in French and read English back. The delegates come
      // from flutter_localizations, which is what makes Material's own strings
      // — dialog buttons, tooltips, date pickers — follow too; the app's copy
      // switches where it has a translation and stays English where it does
      // not, which is honest preparation rather than a half-translated screen.
      locale: nexusLocaleFor(_voice.language),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: nexusSupportedLocales,
      // The native splash is the brand mark on the same flat field the
      // artwork is drawn on (flutter_native_splash, see pubspec.yaml). Flutter
      // cannot animate that window away, so the first frame repeats the same
      // field and mark and dissolves them into the app here — the hand-off the
      // platform will not do for us.
      home: SplashFade(
        child: switch (onboarded) {
          true when !_modeChosen => _InteractionModePage(
            onDone: _finishModeChoice,
          ),
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
          // blank rather than a logo: a mark that appears and vanishes inside
          // one frame is a flicker, and this window is not long enough to read
          // one.
          null => const _NexusBootGround(),
        },
      ),
    );
  }
}

/// How long the brand splash takes to dissolve once Flutter owns the screen.
///
/// Long enough to read as a fade rather than a cut, short enough that it is
/// over before a finger reaches the first control. A test can wait it out with
/// one `pumpAndSettle`.
const Duration kSplashFade = Duration(milliseconds: 420);

/// The splash overlay, so a test can watch it leave without matching on paint.
const Key kNexusSplashFade = Key('nexus-splash-fade');

/// The field the splash is drawn on, one per system theme.
///
/// Both are sampled from the artwork's own corners — white around the light
/// mark, #131315 around the dark one — and both are written into
/// `flutter_native_splash` in pubspec.yaml and into the generated window
/// themes. A splash image laid on any other colour shows its square as a
/// panel, which is what the purple field did to this artwork.
const Color kNexusSplashFieldLight = Color(0xFFFFFFFF);
const Color kNexusSplashFieldDark = Color(0xFF131315);

/// The native splash's second half: the same field and mark, faded out over
/// the first frame.
///
/// The platform removes its splash when Flutter draws, with no animation of
/// its own — which would read as a hard cut from a bright splash to a dark
/// app. Repainting the splash here and dissolving it hides that seam: the
/// first frame repeats the native one, so the fade starts exactly where the
/// platform stopped. It never takes the pointer — it is a picture, and the
/// app underneath is already live.
class SplashFade extends StatefulWidget {
  const SplashFade({super.key, required this.child});

  final Widget child;

  @override
  State<SplashFade> createState() => _SplashFadeState();
}

class _SplashFadeState extends State<SplashFade>
    with SingleTickerProviderStateMixin {
  /// The fade waits for the app to be drawing normally before it begins.
  ///
  /// Two earlier versions each got one half of this right. An
  /// [AnimationController] ran on wall-clock time and cut in a single step:
  /// the first release frame spends long enough compiling that the clock had
  /// already run out by the time the next frame arrived. Pacing by rendered
  /// frames instead kept every frame a step, but the phone then froze for two
  /// seconds loading the restored chat, and the splash sat half-faded over a
  /// washed-out app until the freeze ended.
  ///
  /// So the fade starts only once the frames settle: after a stall, three
  /// frames in a row; on a start that never stalls, twelve frames. Until then
  /// the overlay is fully opaque, which is exactly what a splash should be
  /// while the app is still coming up. Once it starts it runs on the real
  /// clock, so a late stall finishes it rather than stranding it half-faded.
  late final Ticker _ticker = createTicker(_tick);

  /// A frame slower than this is a stall, not a cadence: 120 ms is below the
  /// 10 fps at which the app is visibly frozen, and above the 100 ms steps a
  /// widget test pumps with.
  static const Duration _stall = Duration(milliseconds: 120);

  double _opacity = 1;
  Duration _last = Duration.zero;

  /// Frames drawn in a row at a normal cadence, and whether a stall has been
  /// seen — the two facts that decide when the fade may begin.
  int _settled = 0;
  bool _stalled = false;
  bool _fading = false;

  /// Whether the fade has finished. The overlay is then taken out of the tree
  /// entirely rather than left transparent, so it costs nothing for the rest
  /// of the session.
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final Duration delta = elapsed - _last;
    _last = elapsed;

    if (!_fading) {
      if (delta > _stall) {
        _stalled = true;
        _settled = 0;
      } else {
        _settled++;
      }
      final bool ready = _stalled ? _settled >= 3 : _settled >= 12;
      if (!ready) return;
      _fading = true;
    }

    final double next =
        _opacity - delta.inMicroseconds / kSplashFade.inMicroseconds;
    if (next <= 0) {
      _ticker.stop();
      setState(() {
        _opacity = 0;
        _gone = true;
      });
      return;
    }
    setState(() => _opacity = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The same choice the platform already made: the native splash reads the
    // system's night mode, and the app follows the system unless told not to,
    // so on the common path these agree. They can differ only when the user
    // has pinned the app's appearance against the phone's — and then the
    // fade is a short cross-dissolve between two brand screens.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_gone)
          IgnorePointer(
            child: Opacity(
              key: kNexusSplashFade,
              opacity: _opacity,
              child: ColoredBox(
                color: dark ? kNexusSplashFieldDark : kNexusSplashFieldLight,
                child: Center(
                  child: Image.asset(
                    // The same file the native splash is built from, so the
                    // first Flutter frame is the platform's splash again.
                    // 192 dp is exactly what the platform draws it at — the
                    // image is composed to that size, mask included — so the
                    // hand-off is the same picture at the same scale, not two
                    // pictures that have to be made to match.
                    dark
                        ? 'assets/splash_mark_dark.png'
                        : 'assets/splash_mark.png',
                    width: 192,
                    height: 192,
                    cacheWidth: 640,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
      ],
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
/// The first-run fork: commands or conversation.
///
/// It is a page rather than a setting row because it is the one choice that
/// changes the shape of every answer that follows, and a user who has not made
/// it yet has no way to know the other style exists. Two cards, one sentence
/// each, and the choice saved before the shell draws — the app opens on the
/// mode the user picked rather than on a default that is corrected a frame
/// later.
class _InteractionModePage extends StatefulWidget {
  const _InteractionModePage({required this.onDone});

  final Future<void> Function(InteractionMode mode) onDone;

  @override
  State<_InteractionModePage> createState() => _InteractionModePageState();
}

class _InteractionModePageState extends State<_InteractionModePage> {
  InteractionMode _selected = InteractionMode.conversational;
  bool _saving = false;

  Future<void> _continue() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.onDone(_selected);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool french = nexusIsFrench(context);
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    french
                        ? 'Comment Nexus doit-il répondre ?'
                        : 'How should Nexus answer?',
                    style: NexusType.greeting(c),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    french
                        ? 'Vous pourrez changer d’avis à tout moment.'
                        : 'You can change your mind any time — this only sets '
                              'the default tone.',
                    style: NexusType.lede(c),
                  ),
                  const SizedBox(height: 24),
                  for (final InteractionMode mode
                      in InteractionMode.values) ...[
                    _ModeCard(
                      key: ValueKey<String>('interaction-${mode.name}'),
                      mode: mode,
                      selected: mode == _selected,
                      onTap: () => setState(() => _selected = mode),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey<String>('interaction-continue'),
                    onPressed: _saving ? null : () => unawaited(_continue()),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                      minimumSize: const Size.fromHeight(52),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(NexusLayout.tile),
                      ),
                    ),
                    child: _saving
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c.onAccent,
                            ),
                          )
                        : const Text('Continue'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No account, no cloud. The mode changes the tone of answers '
                    'and nothing about where they come from.',
                    textAlign: TextAlign.center,
                    style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the two modes: icon, name, example, and a tick when selected.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final InteractionMode mode;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (mode) {
    InteractionMode.instant => Icons.bolt_rounded,
    InteractionMode.conversational => Icons.forum_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Material(
      color: selected ? c.accent.withValues(alpha: 0.10) : c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(NexusLayout.card),
        side: BorderSide(
          color: selected ? c.accent : c.hairline,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              NexusIconTile(_icon, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      mode.label,
                      style: NexusType.rowTitle(c)
                          .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      mode.example,
                      style: NexusType.rowMeta(c).copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 22,
                color: selected ? c.accent : c.hairline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

  late final OnDeviceAiService _onDevice =
      widget.onDevice ?? OnDeviceAiService();

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
                    Text('Welcome to Nexus.', style: NexusType.greeting(c)),
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
                        leading: const NexusIconTile(
                          Icons.auto_awesome_rounded,
                        ),
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
                        style: NexusType.rowMeta(c).copyWith(color: c.danger),
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

  /// True once the hidden Developer Logs tab has been earned. Read from the
  /// preference store on launch, so unlocking it is not a per-session trick.
  bool _developerMode = false;

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
  void initState() {
    super.initState();
    LogService.instance.addListener(_onLogServiceChanged);
    unawaited(
      LogService.instance.attach().then((_) {
        if (!mounted) return;
        setState(() => _developerMode = LogService.instance.developerUnlocked);
      }),
    );
  }

  void _onLogServiceChanged() {
    if (!mounted) return;
    final bool unlocked = LogService.instance.developerUnlocked;
    if (unlocked == _developerMode) return;
    setState(() {
      _developerMode = unlocked;
      // Locking the tab while the user is looking at it would leave the
      // IndexedStack on an index that no longer exists — Settings is the tab
      // they came from, so that is where they land.
      if (!unlocked && _tab >= NexusTabBar.defaultTabs.length) {
        _tab = _settingsIndex;
      }
    });
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_onLogServiceChanged);
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
    final List<NexusTabSpec> tabs = <NexusTabSpec>[
      ...NexusTabBar.defaultTabs,
      if (_developerMode)
        const NexusTabSpec(
          'Logs',
          Icons.terminal_outlined,
          Icons.terminal_rounded,
        ),
    ];
    // One breakpoint, measured once: above it the conversation list is a
    // column beside the thread (ChatGPT on the web), below it the same list is
    // the drawer the phone already had. The two are the same data and the same
    // taps; only the shape differs, and the shape is decided by the width the
    // app was given rather than by a device category.
    final double width = MediaQuery.sizeOf(context).width;
    final bool wide = width >= kNexusWideBreakpoint;
    final Widget pages = IndexedStack(
      index: _tab,
      children: <Widget>[
        // The thread's own drawer is disabled while the sidebar owns history:
        // two ways to open the same list, one of them a panel over the other
        // list, is the kind of duplicate a wide layout exists to remove.
        HomeTab(refreshEpoch: _homeEpoch, wide: wide),
        // The index in this stack is the design: 0 is Home, 1 is Files, and
        // only the page whose index matches the selected tab does work on
        // launch.
        FilesTab(active: _tab == 1),
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
        if (_developerMode) const DeveloperLogsTab(),
      ],
    );
    if (!wide) {
      return Scaffold(
        backgroundColor: c.background,
        body: pages,
        bottomNavigationBar: NexusTabBar(
          index: _tab,
          onSelected: _select,
          tabs: tabs,
        ),
      );
    }
    return Scaffold(
      backgroundColor: c.background,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: kNexusSidebarWidth,
            child: _NexusWideSidebar(
              index: _tab,
              tabs: tabs,
              onSelected: _select,
              onOpenChat: (String id) {
                _select(_homeIndex);
                ChatLog.instance.selectSession(id);
              },
            ),
          ),
          // A hairline rather than a shadow: the two panes are one surface cut
          // in two, not a floating sheet beside a page.
          VerticalDivider(width: 1, thickness: 1, color: c.hairline),
          Expanded(child: pages),
        ],
      ),
    );
  }
}

/// The permanent left column on a wide screen: the four destinations, and the
/// conversations, in one place.
///
/// It is deliberately the drawer's content without the drawer: the same
/// wordmark, the same New chat, the same date-grouped list, the same tap. A
/// wide window does not need a panel that slides over the chat it is next to,
/// and a second implementation of "which chats are there" would be the second
/// place a rename or a pin could fail to appear.
class _NexusWideSidebar extends StatefulWidget {
  const _NexusWideSidebar({
    required this.index,
    required this.tabs,
    required this.onSelected,
    required this.onOpenChat,
  });

  final int index;
  final List<NexusTabSpec> tabs;
  final ValueChanged<int> onSelected;
  final ValueChanged<String> onOpenChat;

  @override
  State<_NexusWideSidebar> createState() => _NexusWideSidebarState();
}

class _NexusWideSidebarState extends State<_NexusWideSidebar> {
  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Material(
      color: c.background,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: const BorderRadius.all(Radius.circular(8)),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: c.onAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('Nexus', style: NexusType.wordmark(c)),
                ],
              ),
            ),
            for (int i = 0; i < widget.tabs.length; i++)
              _WideNavRow(
                spec: widget.tabs[i],
                selected: i == widget.index,
                onTap: () => widget.onSelected(i),
              ),
            const SizedBox(height: 10),
            Divider(height: 1, thickness: 1, color: c.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Chats',
                      style: NexusType.rowTitle(c).copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textMuted,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  IconButton(
                    key: kNexusNewChat,
                    tooltip: 'New chat',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      widget.onSelected(0);
                      ChatLog.instance.newChat();
                    },
                    icon: Icon(Icons.add_rounded, size: 20, color: c.accent),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: ChatLog.instance,
                builder: (BuildContext context, _) {
                  final ChatLog chat = ChatLog.instance;
                  final List<ChatSession> sessions = chat.sessions.toList()
                    ..sort((ChatSession a, ChatSession b) {
                      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                      return b.updatedAt.compareTo(a.updatedAt);
                    });
                  final List<ChatSession> visible = <ChatSession>[
                    for (final ChatSession session in sessions)
                      if (!(session.isEmpty &&
                          session.id != chat.activeSessionId))
                        session,
                  ];
                  if (visible.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        'No conversations yet.',
                        style: NexusType.rowMeta(c),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: visible.length,
                    itemBuilder: (BuildContext context, int i) {
                      final ChatSession session = visible[i];
                      final bool active = session.id == chat.activeSessionId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 1,
                        ),
                        child: Material(
                          color: active
                              ? c.accent.withValues(alpha: 0.13)
                              : Colors.transparent,
                          borderRadius: const BorderRadius.all(
                            NexusLayout.tile,
                          ),
                          child: InkWell(
                            key: ValueKey<String>('wide-chat-${session.id}'),
                            borderRadius: const BorderRadius.all(
                              NexusLayout.tile,
                            ),
                            onTap: () => widget.onOpenChat(session.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    Icons.chat_bubble_outline_rounded,
                                    size: 15,
                                    color: active ? c.accent : c.textMuted,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      session.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: NexusType.rowTitle(c).copyWith(
                                        fontSize: 13.5,
                                        color: active ? c.accent : c.textStrong,
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                  if (session.pinned)
                                    Icon(
                                      Icons.push_pin_rounded,
                                      size: 12,
                                      color: c.textMuted,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
              child: Text(
                'Chats stay on this device.',
                style: NexusType.rowMeta(c).copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One destination in the wide sidebar: glyph, word, and an accent row when it
/// is the screen you are on.
class _WideNavRow extends StatelessWidget {
  const _WideNavRow({
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? c.accent.withValues(alpha: 0.13) : Colors.transparent,
        borderRadius: const BorderRadius.all(NexusLayout.tile),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(NexusLayout.tile),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? spec.activeIcon : spec.icon,
                  size: 19,
                  color: selected ? c.accent : c.textMuted,
                ),
                const SizedBox(width: 11),
                Text(
                  spec.label,
                  style: NexusType.rowTitle(c).copyWith(
                    fontSize: 14,
                    color: selected ? c.accent : c.textStrong,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
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
    this.tabs = defaultTabs,
  });

  /// Which tab is active.
  final int index;

  /// Called with the tapped tab's index.
  final ValueChanged<int> onSelected;

  /// The four tabs, in order.
  final List<NexusTabSpec> tabs;

  static const List<NexusTabSpec> defaultTabs = <NexusTabSpec>[
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

/// The hidden Developer Logs tab: the last [kLogLineLimit] lines the app wrote
/// about itself, oldest first.
///
/// Reached only after seven taps on the version row. It is hidden rather than
/// buried because a log page is a diagnostic tool, not a setting; a user who
/// needs it has just watched something fail and should not have to hunt.
class DeveloperLogsTab extends StatelessWidget {
  const DeveloperLogsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return ListenableBuilder(
      listenable: LogService.instance,
      builder: (BuildContext context, _) {
        final List<LogLine> lines = LogService.instance.lines;
        return NexusTabBody(
          title: 'Developer Logs',
          subtitle: lines.isEmpty
              ? 'Nothing logged yet.'
              : '${lines.length} of $kLogLineLimit lines — newest last',
          trailing: IconButton(
            key: const ValueKey<String>('copy-logs-icon'),
            tooltip: 'Copy to clipboard',
            onPressed: lines.isEmpty
                ? null
                : () => _copy(context, LogService.instance.exportText()),
            icon: const Icon(Icons.copy_all_rounded),
          ),
          child: Column(
            children: <Widget>[
              Expanded(
                child: Container(
                  key: const ValueKey<String>('developer-logs-list'),
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border.all(color: c.hairline),
                    borderRadius: const BorderRadius.all(NexusLayout.tile),
                  ),
                  child: lines.isEmpty
                      ? Center(
                          child: Text(
                            'Logs from this session will appear here.',
                            textAlign: TextAlign.center,
                            style: NexusType.rowMeta(c),
                          ),
                        )
                      : SingleChildScrollView(
                          reverse: true,
                          child: SelectableText(
                            lines
                                .map((LogLine line) => line.display)
                                .join('\n'),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.45,
                              color: c.textStrong,
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey<String>('copy-logs'),
                        onPressed: lines.isEmpty
                            ? null
                            : () => _copy(
                                context,
                                LogService.instance.exportText(),
                              ),
                        style: FilledButton.styleFrom(
                          backgroundColor: c.accent,
                          foregroundColor: c.onAccent,
                          minimumSize: const Size.fromHeight(46),
                        ),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy to Clipboard'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      key: const ValueKey<String>('clear-logs'),
                      onPressed: lines.isEmpty
                          ? null
                          : () {
                              LogService.instance.clear();
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text('Logs cleared.'),
                                  ),
                                );
                            },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.danger,
                        minimumSize: const Size(0, 46),
                        side: BorderSide(color: c.hairline),
                      ),
                      child: const Text('Clear Logs'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Logs copied to clipboard.')),
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
  const NexusSectionLabel(this.text, {super.key, this.first = false});

  final String text;

  /// True for the first label on a page: the page header already supplies the
  /// separation, and a second 22-point gap there reads as an empty line rather
  /// than as a section boundary.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(4, first ? 0 : 22, 4, 8),
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

/// The About section's one update control. It asks GitHub for the latest
/// release and, when there is one, offers its APK — it never sends the user to
/// the releases page to find the file themselves.
const String kNexusCheckUpdatesRow = 'Check for Updates';

/// Offers [info]'s APK in a dialog, and opens its download URL only on a yes.
///
/// Shared by the Settings row and the Home banner so the two cannot disagree
/// about what an update is or where it comes from. The browser is deliberate:
/// the APK is the release's own artifact, and handing it to Android's download
/// manager keeps the install permission prompt in the system's hands.
Future<void> showNexusUpdateDialog(
  BuildContext context,
  UpdateInfo info,
) async {
  final NexusUiColors c = context.ui;
  final bool install =
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            'Update Available (v${info.version})',
            style: NexusType.rowTitle(c),
          ),
          content: Text(
            'Install now?',
            style: NexusType.rowMeta(c).copyWith(height: 1.4),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('Not now', style: TextStyle(color: c.textMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Install now'),
            ),
          ],
        ),
      ) ??
      false;
  if (!install || !context.mounted) return;
  final String? url = info.downloadUrl;
  if (url == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This release has no APK to install.')),
    );
    return;
  }
  final bool opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the APK download.')),
    );
  }
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

/// The opacity that greys the Dark mode switch out while Follow system owns
/// the theme. Keyed so a test can read the treatment rather than guess it from
/// a rendered pixel.
const Key kNexusDarkModeLocked = Key('nexus-dark-mode-locked');

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

/// How long the Discover button listens before it reports what it heard.
///
/// Long enough for two announce cycles (the mesh announces every three
/// seconds) plus the unicast reply a peer sends back, short enough that nobody
/// thinks the button has hung.
const Duration kNexusDiscoverWindow = Duration(seconds: 7);

/// The sentence a v2 pairing code gets. It is a *live* handshake — ephemeral
/// keys, no device id, single use — so a screen with no mesh behind it has
/// nothing it could honestly store from one.
const String kNexusLivePairCodeText =
    'That is a live pairing code. It pairs through the mesh, which this '
    'screen does not run yet — use the code on the other device\u2019s Nexus '
    'code instead.';

/// The key on a destructive dialog's confirm button.
const Key kNexusConfirmAction = Key('nexus-confirm-action');

/// The key on the Theme section's colour row, on the button that opens the
/// wheel, on the wheel itself, and on the one way back to the shipped purple.
///
/// The row is what the accent *is*; the button is what changes it. They are keyed
/// apart because a test that taps the row and a test that reads its subtitle are
/// asking about two different things.
const Key kNexusAccentRow = Key('nexus-accent-row');
const Key kNexusAccentSwatch = Key('nexus-accent-swatch');
const Key kNexusPickColor = Key('nexus-pick-color');
const Key kNexusColorWheel = Key('nexus-color-wheel');
const Key kNexusResetAccent = Key('nexus-reset-accent');

/// The Theme section's accent control: one row that says what the app paints
/// with, and one button that opens a colour wheel.
///
/// A wheel rather than a row of presets, because the presets were five colours
/// somebody else had chosen and the point of the row is that this app is the
/// user's. The wheel previews in its own disc while the thumb drags; the pick is
/// applied to the app when the dialog's Done is pressed, so a drag is not a
/// hundred full-screen repaints and Cancel really does cancel.
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
    // A swatch, not a block. The old row painted the accent across the whole
    // width of the Theme section, which on dark mode read as a giant pale sheet
    // rather than as a colour. A 40dp tile is the same information at the size
    // a colour deserves: the user sees the exact hue beside the words, and the
    // row itself stays a row like every other setting.
    //
    // Square with the same radius as [NexusIconTile], not a disc: every leading
    // mark on this screen is a rounded tile, and a single circle read as a
    // different kind of control.
    final Color ink = c.onAccent;
    return Padding(
      key: kNexusAccentRow,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: Semantics(
        container: true,
        button: true,
        label: 'Accent colour. ${selected.label}. Opens the colour wheel.',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: kNexusPickColor,
            onTap: onSelected == null ? null : () => _pick(context),
            borderRadius: const BorderRadius.all(NexusLayout.tile),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              // No horizontal padding of its own: the swatch starts on the
              // same 4-point gutter as every NexusRow's leading tile, and is
              // the same 40-point rounded square. That is the whole fix — the
              // swatch used to sit 12 points further in than the icons above
              // and below it, which read as a control that belonged to a
              // different list.
              child: Row(
                children: <Widget>[
                  Container(
                    key: kNexusAccentSwatch,
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: const BorderRadius.all(NexusLayout.tile),
                    ),
                    child: Icon(Icons.palette_outlined, color: ink, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Accent colour',
                          style: NexusType.rowTitle(c)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${selected.label} · choose accent color',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NexusType.rowMeta(c),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: c.textMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The colour wheel itself, in a dialog.
///
/// Stateful because the wheel needs to know which colour it is showing, and
/// `flutter_colorpicker`'s widget is told rather than asked. The pick stays
/// local until Done: applying every onColorChanged repainted the whole app on
/// every drag event, which is exactly as laggy as it sounds.
class _AccentWheelDialog extends StatefulWidget {
  const _AccentWheelDialog({required this.accent, required this.onChanged});

  /// The accent in force when the dialog opened: the colour the wheel starts on.
  final NexusAccent accent;

  /// Called once, on Done, with the colour to make the app's accent.
  final ValueChanged<NexusAccent> onChanged;

  @override
  State<_AccentWheelDialog> createState() => _AccentWheelDialogState();
}

class _AccentWheelDialogState extends State<_AccentWheelDialog> {
  /// The colour on the wheel right now — a preview, not the app's accent until
  /// Done is pressed.
  late Color _color = widget.accent.seed;

  /// Whether what the wheel is showing came from the user rather than from the
  /// app. Tracked here rather than read back off [widget.accent], which is the
  /// value that opened the dialog and does not change under it: a Reset button
  /// that appeared only after the dialog was reopened would be a button the user
  /// never sees when they need it.
  late bool _custom = widget.accent.isCustom;

  /// Records the colour under the thumb without painting the app with it.
  ///
  /// The wheel used to repaint every surface on every drag event, which made a
  /// phone stutter while the user was still choosing. Nothing is applied until
  /// Done: the dialog previews the pick in its own disc, and the app stays on
  /// the colour it had — including when the dialog is dismissed any other way.
  void _choose(Color color) {
    setState(() {
      _color = color;
      _custom = NexusAccent.custom(color).isCustom;
    });
  }

  /// The one moment the pick becomes the app's accent.
  void _commit() {
    widget.onChanged(
      _color == kNexusAccent ? NexusAccent.purple : NexusAccent.custom(_color),
    );
    Navigator.of(context).pop();
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
            // A pending reset, like a pending colour: it takes effect when the
            // dialog is confirmed, so Cancel still means cancel.
            onPressed: () => setState(() {
              _color = kNexusAccent;
              _custom = false;
            }),
            child: const Text('Reset'),
          ),
        TextButton(onPressed: _commit, child: const Text('Done')),
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
    this.imagePath,
    this.imagePaths = const <String>[],
    this.filePath,
    this.visionText,
    this.visionLabels = const <String>[],
    this.reasoning,
  });

  final String text;

  /// Where a photo or screenshot the user attached is kept. Null for every
  /// line that is only words.
  ///
  /// [text] is still the caption — "Photo attached" — so a message with an
  /// image is a normal message that happens to carry a picture: the persistence
  /// shape, the history the brain is shown, and the scroll behaviour are the
  /// ones that already exist, and an image that cannot be decoded still leaves
  /// a readable line in the thread.
  final String? imagePath;

  /// Every picture this turn carries, in the order the user picked them.
  ///
  /// [imagePath] is the first one, kept because the live transcript and every
  /// older bubble speak that field. A message with one picture stores the same
  /// thing twice; the accessor below is the one place that folds them.
  final List<String> imagePaths;

  /// Every image path on this line, with the legacy single field folded in.
  List<String> get allImagePaths => imagePaths.isNotEmpty
      ? imagePaths
      : (imagePath == null ? const <String>[] : <String>[imagePath!]);

  /// Where a picked document is kept. Never decoded as a picture: the bubble
  /// draws a file chip from its name, and tapping it hands the path to the
  /// platform's own viewer.
  final String? filePath;

  /// What ML Kit read in the attached picture, or null when there was nothing.
  /// The bubble draws it as a small grey line under the image, so a user can
  /// see the scan worked without having to trust the language model's prose.
  final String? visionText;

  /// The object labels ML Kit found, best first. Empty when there was nothing.
  final List<String> visionLabels;

  /// A copy of this line with the vision evidence filled in.
  ///
  /// Messages are otherwise immutable once placed; this one change arrives
  /// later than the bubble, from the ML Kit callback, and replaces the line in
  /// the list rather than mutating it.
  NexusMockMessage withVision({
    required String? detectedText,
    required List<String> labels,
  }) => NexusMockMessage(
    text,
    mine: mine,
    thinking: thinking,
    failed: failed,
    system: system,
    ok: ok,
    imagePath: imagePath,
    imagePaths: imagePaths,
    filePath: filePath,
    // A multi-image turn receives one evidence callback per picture; the
    // bubble carries the union, because the user asked about the set.
    visionText:
        <String>[
          if (visionText != null && visionText!.trim().isNotEmpty)
            visionText!.trim(),
          if (detectedText != null && detectedText.trim().isNotEmpty)
            detectedText.trim(),
        ].join('\n').trim().isEmpty
        ? null
        : <String>[
            if (visionText != null && visionText!.trim().isNotEmpty)
              visionText!.trim(),
            if (detectedText != null && detectedText.trim().isNotEmpty)
              detectedText.trim(),
          ].join('\n'),
    visionLabels: <String>{...visionLabels, ...labels}.toList(growable: false),
    reasoning: reasoning,
  );

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

  /// The model's `<thought>` text, shown in a collapsible grey bubble above the
  /// answer. Null for every line that did not think out loud.
  final String? reasoning;
}

// ---------------------------------------------------------------------------
// The action interceptor
// ---------------------------------------------------------------------------

/// One reply, split into the prose the user should see and the action requests
/// buried in it.
///
/// A small model does not keep the promise the rules make. It writes
/// `{action: "set_flashlight"}` (unquoted keys, because the grammar of JSON is
/// not the grammar of the sentence), wraps it in a friendly sentence, or fences
/// it in Markdown — and every one of those used to reach the thread as text,
/// because [SystemActionCall.tryParse] only reads strict JSON. The user then
/// saw a flashlight request instead of a flashlight.
///
/// So the shell reads the shape as well as the JSON: a flat `{…}` block anywhere
/// in the reply is normalised (quotes, unquoted keys, trailing commas) and only
/// then offered to the same guarded parser that already refuses unknown actions
/// and missing arguments. A block that survives is stripped from the text and
/// run; a block that does not is prose, exactly as before.
@immutable
class NexusActionIntercept {
  const NexusActionIntercept(
    this.text,
    this.calls, {
    this.refused = const <String>[],
  });

  /// What is left to show: the reply with every recognised action request
  /// removed, and the Markdown fence it was wrapped in taken with it.
  ///
  /// Also JSON the model wrote as an *answer* has been read into words by
  /// [nexusReadableText]: asked "what is two plus two", a 1B model replies
  /// `{"result": 4}` instead of a sentence, and the thread shows "4". Raw
  /// JSON syntax never reaches the screen, because a bubble is read as a
  /// message and `{` is not how a message starts.
  final String text;

  /// The requests, in the order the model wrote them. Already validated: an
  /// action that runs from here is one the phone has and can carry out.
  final List<SystemActionCall> calls;

  /// Action *names* the model asked for that this phone does not have.
  ///
  /// Measured on the A25, and the reason this field exists: asked "it's dark in
  /// here", llama3.2 answered `{"action":"turn_down_brightness","state":90}`,
  /// which is not the vocabulary — the phone's is `set_brightness` with a
  /// `level`. The old rule left anything unrecognised on screen "as written",
  /// so the user got a wall of JSON where a sentence belonged. A request is
  /// never prose: whatever the model called it, the block is taken out of the
  /// text and the shell answers for it.
  final List<String> refused;

  bool get hasAction => calls.isNotEmpty;

  /// True while there is an action request to answer for — one to run, or one
  /// to admit to not having.
  bool get acted => calls.isNotEmpty || refused.isNotEmpty;
}

/// A flat JSON object. The action vocabulary is flat by design — one action and
/// its scalar arguments — so a brace region with no braces inside it is the
/// exact shape being looked for, and a nested object in prose is left alone.
final RegExp _actionBlock = RegExp(r'\{[^{}]*\}');

/// A key that is a bare word rather than a quoted string: `{action: …}`.
final RegExp _bareKey = RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:');

/// A bare word where a value belongs: `{action: set_timer, seconds: 300}`.
///
/// Quoted strings, numbers, booleans, null and nested containers are skipped —
/// only the unquoted word a model writes for an action name or a state is
/// quoted. The lookahead is what keeps `true` and `false` from becoming the
/// strings `"true"` and `"false"`.
final RegExp _bareValue = RegExp(
  r'(:\s*)(?!["\d\-\[{]|true\b|false\b|null\b)'
  r'([A-Za-z_][A-Za-z0-9_ ]*?)(\s*[,}])',
);

/// A comma before the end of an object: `{"state":"on",}`.
final RegExp _trailingComma = RegExp(r',\s*([}\]])');

/// The name inside a block that is shaped like an action request, wherever the
/// phone knows it or not: `{"action":"turn_down_brightness","state":90}`. Read
/// off the loosened text, so the unquoted `{action: set_flashlight}` a small
/// model writes counts too.
final RegExp _askedActionName = RegExp(r'"action"\s*:\s*"([^"]*)"');

/// The action name [loose] asks for, or null when the block is not an action
/// request at all — a JSON object the model wrote for its own reasons, which is
/// left where it is.
String? _askedNameIn(String loose) {
  final String? name = _askedActionName.firstMatch(loose)?.group(1)?.trim();
  return (name == null || name.isEmpty) ? null : name;
}

/// Splits [reply] into visible prose, runnable action calls, and the requests
/// the phone cannot honour.
///
/// Never throws, and never invents an action: [SystemActionCall.tryParse] is
/// still the one gate, so a `launch_missiles` block is never *run*. It is not
/// printed either — a block that names an action is an action request, and the
/// user gets the shell's sentence about it instead of the JSON that asked.
///
/// A block that is not action-shaped at all (no `action` key) is not printed as
/// JSON either. It is read by [nexusReadableText], which takes the answer out
/// of it — `{"result": 4}` is "4" — and the same goes for a reply with no
/// action in it at all. The model may answer in JSON; the thread speaks prose.
NexusActionIntercept interceptSystemActions(String reply) {
  final List<SystemActionCall> calls = <SystemActionCall>[];
  final List<String> refused = <String>[];
  String prose = reply;
  for (final RegExpMatch match in _actionBlock.allMatches(reply)) {
    final String? block = match.group(0);
    if (block == null) continue;
    final String loose = _looseActionJson(block);
    final SystemActionCall? call = SystemActionCall.tryParse(loose);
    final String? asked = _askedNameIn(loose);
    if (call == null && asked == null) continue;
    if (call == null) {
      refused.add(asked!);
    } else {
      calls.add(call);
    }
    prose = prose.replaceFirst(block, '');
  }
  if (calls.isEmpty && refused.isEmpty) {
    // Nothing loose matched. Strict JSON can still be an action with nested
    // braces in a string argument (an app called "Notes {beta}"), which the
    // flat-block scan above deliberately does not read.
    final SystemActionCall? strict = SystemActionCall.tryParse(reply);
    if (strict != null) {
      return NexusActionIntercept('', <SystemActionCall>[strict]);
    }
    final String? asked = _askedNameIn(_looseActionJson(reply));
    if (asked != null) {
      return NexusActionIntercept(
        '',
        const <SystemActionCall>[],
        refused: <String>[asked],
      );
    }
    return NexusActionIntercept(
      _tidyProse(nexusReadableText(reply)),
      const <SystemActionCall>[],
    );
  }
  return NexusActionIntercept(
    _tidyProse(nexusReadableText(prose)),
    calls,
    refused: refused,
  );
}

// ---------------------------------------------------------------------------
// JSON in, words out
// ---------------------------------------------------------------------------

/// The keys a model uses when it puts the answer itself in an object: asked
/// "what is two plus two", llama3.2 answers `{"result": 4}`. Lower-cased and
/// compared case-insensitively, because `Result` is the same field.
const List<String> _answerKeys = <String>[
  'result',
  'answer',
  'text',
  'response',
];

/// [text] with every JSON object or array in it replaced by what a person
/// would read.
///
/// This is the other half of the interceptor above. A 1B model answers in JSON
/// as readily as in a sentence, and a bubble is the wrong place to show that:
/// the user asked a question, not for a wire format. Three shapes are handled,
/// in the order a reader would want them:
///
///  * an object with an answer field (`result`, `answer`, `text`, `response`) —
///    the value alone, so `{"result": 4}` reads as "4";
///  * an array of scalars — its items, separated by commas;
///  * anything else that is still shaped like JSON — the punctuation taken out,
///    so `{"colour": "red"}` reads as "colour: red" rather than as nothing.
///
/// A brace region that is *not* shaped like JSON — prose in braces, a code
/// snippet with no quotes or colons in it — is left exactly as written: the
/// point is to stop the model's wire format, not to edit the user's text.
/// Run to a fixed point, because an extracted value can itself be JSON (a model
/// that answered `{"result": "{\"answer\": 4}"}`).
@visibleForTesting
String nexusReadableText(String text) {
  var out = text;
  for (var pass = 0; pass < 3; pass++) {
    final String next = _readablePass(out);
    if (next == out) break;
    out = next;
  }
  return _bareFragmentText(_unclosedJson(out));
}

/// A reply that starts as a quoted key and a colon: `"mesh_network": …`.
///
/// Measured on the A25: "what is a mesh network" was answered
/// `"mesh_network": type:object,value:name:802.15.4 …` — the model's wire
/// format with the object's braces left off, so the object reader above has no
/// region to read and the quotes went to the screen. A sentence does not begin
/// with a quoted key and a colon; a JSON fragment does, and there the quotes
/// are the only thing between it and something a person can read.
final RegExp _bareFragment = RegExp(r'^\s*"[^"]+"\s*:');

String _bareFragmentText(String text) {
  if (!_bareFragment.hasMatch(text)) return text;
  final String out = text.replaceAll('"', '');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One pass of [nexusReadableText]: every balanced `{…}` and `[…]` region is
/// read into words and the rest of [text] is copied through untouched.
String _readablePass(String text) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < text.length) {
    final String ch = text[i];
    if (ch != '{' && ch != '[') {
      out.write(ch);
      i++;
      continue;
    }
    final int end = _balancedEnd(text, i);
    if (end < 0) {
      out.write(ch);
      i++;
      continue;
    }
    final String region = text.substring(i, end + 1);
    final Object? decoded = _decodeJson(region);
    if (decoded == null) {
      out.write(_looksJson(region) ? _stripJsonSyntax(region) : region);
    } else {
      out.write(_readableValue(decoded, region));
    }
    i = end + 1;
  }
  return out.toString();
}

/// The index of the brace or bracket that closes the one at [start], or -1 when
/// it never closes.
///
/// Quotes and escapes are tracked, so a brace inside a string does not end the
/// region early; a mismatched closer (`{]`) never matches, because a region the
/// parser would refuse is not a region this may rewrite.
int _balancedEnd(String text, int start) {
  final List<String> expected = <String>[];
  bool inString = false;
  bool escaped = false;
  for (int i = start; i < text.length; i++) {
    final String ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{' || ch == '[') {
      expected.add(ch == '{' ? '}' : ']');
    } else if (ch == '}' || ch == ']') {
      if (expected.isEmpty || expected.last != ch) return -1;
      expected.removeLast();
      if (expected.isEmpty) return i;
    }
  }
  return -1;
}

/// [region] as JSON, strict first and then loosened the way the action parser
/// loosens it (single quotes, bare keys, Python's `True`). Null when neither
/// reads it.
Object? _decodeJson(String region) {
  try {
    return jsonDecode(region);
  } catch (_) {
    // A small model writes Python as readily as JSON; the looseness is the
    // same one [SystemActionCall.tryParse] is given.
  }
  try {
    return jsonDecode(_looseActionJson(region));
  } catch (_) {
    return null;
  }
}

/// True for a region that is *shaped* like JSON even when it does not parse: it
/// has a quoted string or a key in it. `{curly braces}` is prose and is left
/// alone; `{"colour": "red"}` is not.
bool _looksJson(String region) => region.contains('"') || region.contains(":");

/// What [decoded] says, in words, with [region] as the fallback when it says
/// nothing this knows how to read.
String _readableValue(Object decoded, String region) {
  if (decoded is Map) {
    for (final String key in _answerKeys) {
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        final Object? name = entry.key;
        if (name is! String || name.trim().toLowerCase() != key) continue;
        final String? value = _answerText(entry.value);
        if (value != null && value.isNotEmpty) return value;
      }
    }
  } else if (decoded is List) {
    final List<String> parts = <String>[];
    for (final Object? item in decoded) {
      final String? value = _answerText(item);
      if (value == null || value.isEmpty) {
        parts.clear();
        break;
      }
      parts.add(value);
    }
    if (parts.isNotEmpty) return parts.join(', ');
  }
  return _stripJsonSyntax(region);
}

/// A JSON scalar as text. Null for null and for a nested container, which are
/// not answers to read out on their own.
String? _answerText(Object? value) {
  if (value is String) return value.trim();
  if (value is num || value is bool) return '$value';
  return null;
}

/// [json] with the punctuation taken out: braces, brackets and quotes go, the
/// words and the spacing stay, so `{"colour": "red"}` reads "colour: red".
String _stripJsonSyntax(String json) {
  var out = json.replaceAll(RegExp(r'[{}]'), '');
  out = out.replaceAll(RegExp(r'^\[\s*|\s*\]$'), '');
  out = out.replaceAll('"', '');
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  return out.replaceAll(RegExp(r'^:+|:+$'), '').trim();
}

/// A reply that *begins* with an object or array and never closes it.
///
/// A truncated object is still not a sentence: the opening brace goes, the
/// words and the key/value colons stay, so half a `{"result": 4` reads as
/// "result: 4" instead of as a broken object. Only a reply that begins with
/// the brace is touched — a lone brace in the middle of prose is the user's
/// text, not a wire format.
String _unclosedJson(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty ||
      !(trimmed.startsWith('{') || trimmed.startsWith('['))) {
    return text;
  }
  var out = trimmed.replaceAll(RegExp(r'^[{\[]+'), '');
  out = out.replaceAll(RegExp(r'[}\]]+$'), '');
  out = out.replaceAll('"', '');
  return out.trim();
}

/// [name] the way a person would say it: `turn_down_brightness` reads as
/// "turn down brightness" in the sentence the shell answers with.
@visibleForTesting
String nexusActionPhrase(String name) =>
    name.replaceAll(RegExp(r'[\s_]+'), ' ').trim();

/// What the thread says when the model asks for something this phone cannot do.
///
/// The alternative the report found on the device was the model's own JSON in
/// the bubble, which is worse than a refusal: it looks like output, and it asks
/// the user to read a request they already made.
@visibleForTesting
String nexusUnknownActionLine(String name) =>
    'I can\'t do that yet — “${nexusActionPhrase(name)}” isn\'t one of my phone '
    'actions.';

/// [text] as far as it can be shown while an answer is still streaming.
///
/// A half-written `{` is not a sentence, and a model that is about to ask for
/// an action must never spell its request out in the thread or in the live
/// page's large type. Everything before the first brace streams normally; from
/// the brace on, the screen waits for the reply to be whole and the interceptor
/// to decide whether it was an action.
@visibleForTesting
String nexusStreamingProse(String text) {
  final int brace = text.indexOf('{');
  return brace < 0 ? text : text.substring(0, brace);
}

/// [json] in the shape `jsonDecode` accepts, without changing its meaning.
///
/// Deliberately mechanical: single quotes become double, a bare key gets its
/// quotes, Python's `True`/`False`/`None` become JSON's, and a trailing comma
/// is dropped. Values are not rewritten, so an action the phone does not have
/// still fails the parser afterwards instead of being normalised into one.
String _looseActionJson(String json) {
  var out = json.trim();
  out = out.replaceAll("'", '"');
  out = out.replaceAll(RegExp(r'\bTrue\b'), 'true');
  out = out.replaceAll(RegExp(r'\bFalse\b'), 'false');
  out = out.replaceAll(RegExp(r'\bNone\b'), 'null');
  out = out.replaceAllMapped(_bareKey, (Match m) => '${m[1]}"${m[2]}":');
  out = out.replaceAllMapped(
    _bareValue,
    (Match m) => '${m[1]}"${m[2]}"${m[3]}',
  );
  out = out.replaceAllMapped(_trailingComma, (Match m) => m[1] ?? '');
  return out;
}

/// The reply with the scaffolding an action was wrapped in taken out: empty
/// Markdown fences, doubled spaces, the blank line a stripped block leaves.
String _tidyProse(String text) {
  var out = text.replaceAll(RegExp(r'```[A-Za-z]*[ \t]*'), '');
  out = out.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  out = out.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  return out.trim();
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
  const HomeTab({super.key, this.refreshEpoch = 0, this.wide = false});

  /// True when the shell is drawing its permanent sidebar beside this tab.
  ///
  /// It changes nothing about the conversation and two things about the frame:
  /// the drawer button is not drawn (the history it opens is already on screen)
  /// and the drawer itself is not installed, so a left-edge drag scrolls the
  /// thread instead of pulling a panel over a list that is already visible.
  final bool wide;

  /// Bumped by the shell each time this tab is opened.
  ///
  /// The line under the composer says where the next answer comes from, and it
  /// is read once when the screen mounts — which is right for the first answer
  /// and wrong for every one after the model is downloaded or deleted, or the
  /// PC's Ollama starts. A new number means "look again"; see
  /// [SettingsTab.refreshEpoch] for the same signal on the other screen.
  final int refreshEpoch;

  /// Test seam for the silent launch check. The app never sets it; a widget
  /// test supplies a canned release instead of reaching GitHub.
  @visibleForTesting
  static Future<UpdateCheck> Function()? updateCheckOverride;

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

  /// The drawer's scaffold, so the header's menu button can open it without
  /// every bubble needing to know where the drawer lives.
  final GlobalKey<ScaffoldState> _homeScaffold = GlobalKey<ScaffoldState>();

  /// True while the chats drawer is on screen. Held here because the back
  /// button's job changes with it: an open drawer is the thing back should
  /// close, and the app should not leave while one is being read.
  bool _drawerOpen = false;

  /// The conversation, in the order it was said. Empty until the user speaks:
  /// the screen used to open on two invented lines of its own (an assistant
  /// sentence and a question nobody had asked), which read as a chat that had
  /// already happened rather than as an app waiting to be used. What an empty
  /// thread shows instead is [_Welcome] — a heading, not a message.
  final List<NexusMockMessage> _thread = <NexusMockMessage>[];

  /// Answers the user has thumbed up or down, by their index in [_thread].
  ///
  /// Deliberately in memory: a reaction is a note to this session, and a
  /// relabelled bubble is worse than a forgotten one. The sets are cleared
  /// whenever the thread is replaced, so an index can never point at a line
  /// the user did not rate.
  final Set<int> _liked = <int>{};
  final Set<int> _disliked = <int>{};

  /// Which stored conversation the bubbles belong to. Kept here so the drawer
  /// can change it and the log's notification can tell a switch from this
  /// screen's own save (which must not rebuild the thread under a streaming
  /// answer).
  String? _activeChatId;

  /// A newer release found by the silent check at launch. Null means there is
  /// nothing to draw — either the check has not finished or there is no newer
  /// build.
  UpdateInfo? _startupUpdate;

  /// The user closed the banner. It stays closed for this session; the next
  /// launch checks again, which is what keeps a release from being forgotten.
  bool _updateBannerDismissed = false;

  /// The user closed the "your PC can run a bigger model" notice. A dismissal
  /// is for this session: the notice is advice, and advice the user has already
  /// declined twice in one week is nagging. This is the first no.
  bool _pcBannerDismissed = false;

  /// The paired PC that could run a bigger model right now, or null.
  ///
  /// "Right now" is the honest part: a paired row that is offline is a record,
  /// not a connection, and telling the user to download 2 GB to a machine that
  /// is not there would be advice about a different day.
  PairedDevice? get _pcPeer {
    for (final PairedDevice device in PairedDevices.instance.devices) {
      if (device.isThisDevice || !device.online) continue;
      final int? ram = device.ramBytes;
      if (ram == null || ram <= kComfortablePcRamBytes) continue;
      final String where = '${device.name} ${device.detail}'.toLowerCase();
      if (!(where.contains('pc') ||
          where.contains('desktop') ||
          where.contains('windows') ||
          where.contains('linux') ||
          where.contains('mac'))) {
        continue;
      }
      return device;
    }
    return null;
  }

  /// The three chips this screen offers. Chosen once, when the tab is built,
  /// so a rebuild (a keystroke, a theme change) cannot reshuffle them under the
  /// user's thumb.
  late final List<(String, String)> _suggestions = pickHomeSuggestions();

  /// The pictures or document chosen but not sent yet. The composer draws one
  /// thumbnail with its own X for each; nothing reaches the thread or the vision
  /// layer until Send. Pictures queue up to three; choosing a document replaces
  /// the queue, because a document is a turn of its own rather than a fourth
  /// picture the vision layer could read.
  final List<_PendingAttachment> _pendingAttachments = <_PendingAttachment>[];

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

  /// True while a system action is carrying the user out of Nexus — a timer, an
  /// alarm, a music player, another app.
  ///
  /// Those actions open Android's own UI, so the app is backgrounded for a
  /// moment. That is not the user leaving the conversation: the live page stays
  /// up, the microphone closes while Nexus is away, and the next turn opens when
  /// the user comes back. Without this flag the same background event ends live
  /// mode, and "set a timer" drops the user into the text thread.
  ///
  /// Cleared on resume, and by its own timer so a stale flag cannot hold a page
  /// open for the rest of the session if the action never actually leaves.
  bool _liveActionPending = false;
  Timer? _liveActionGuard;

  /// True while Android's own screen-projection dialog is up.
  ///
  /// The dialog takes the app out of the foreground exactly as another app
  /// would. That is not the user closing live conversation — the capture is
  /// still running, and its frame is about to join the room — so the page stays
  /// and the lifecycle handler waits for the capture to finish rather than
  /// closing the overlay or opening the microphone underneath it.
  bool _liveCapturePending = false;

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

  /// True while the assistant's answer is being read out loud.
  ///
  /// The live page draws a Stop speaking control while this is set, and tapping
  /// the page (or that control) cuts the voice off. It is cleared by the
  /// platform's own `done`, by the stop, and by the page closing — never left on
  /// after the microphone is allowed to open again.
  bool _speaking = false;

  /// The platform's completion for the utterance in flight, and the pause that
  /// follows it before the microphone reopens. Both are cancelled by a stop, a
  /// new turn, or the page going away.
  StreamSubscription<void>? _speechDone;
  Timer? _autoListen;

  /// True while the microphone is open *under* the assistant's own voice, for
  /// one reason: the user may talk over it. This is live mode's barge-in, and
  /// it is why the answer being read out loud is still a conversation rather
  /// than a recording the user has to wait out.
  ///
  /// It is a separate flag from [_speaking] because the two can disagree for a
  /// moment: the monitor opens after the first half-second of speech, and the
  /// voice can finish while the monitor is still listening.
  bool _liveBargeIn = false;

  /// The short delay before the monitor opens, and the shorter hold that a
  /// loud reading must sustain to count as speech rather than a cough.
  Timer? _bargeInStart;
  Timer? _bargeInHold;

  /// Long enough that the first syllable of the answer is never heard as an
  /// interruption, short enough that a user talking over it is heard at once.
  static const Duration _bargeInDelay = Duration(milliseconds: 500);
  static const Duration _bargeInSustain = Duration(milliseconds: 250);

  /// How long live conversation waits after the voice stops before it listens
  /// again. Long enough for the user to interrupt, short enough that the room
  /// does not feel dead.
  static const Duration _autoListenGap = kLiveAutoListenDelay;

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
        if (!message.failed) AiTurn(fromUser: message.mine, text: message.text),
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
    // Silent on purpose: no dialog and no snackbar at launch. A release that
    // exists is a banner the user can ignore, not a modal in front of the first
    // question they wanted to ask.
    unawaited(_checkStartupUpdate());
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
    if (state == AppLifecycleState.resumed) {
      if (!_liveOpen) return;
      // Back from an action's own app (the clock, the music player): the page
      // that was live is still the page, and the conversation continues.
      _liveActionPending = false;
      _liveActionGuard?.cancel();
      _liveActionGuard = null;
      // The projection dialog is still open; its capture flow owns what happens
      // next, and opening the microphone here would talk over the answer it is
      // about to ask for.
      if (_liveCapturePending) return;
      if (!_listening && !_liveThinking && !_liveAnswering && !_speaking) {
        unawaited(_liveTurn());
      }
      return;
    }
    // A system action opening another app is not the user ending the room. The
    // microphone still closes — a page nobody is looking at must not listen —
    // and everything else waits for the user to come back.
    if (_liveOpen && (_liveActionPending || _liveCapturePending)) {
      _speechDone?.cancel();
      _speechDone = null;
      _autoListen?.cancel();
      _autoListen = null;
      if (_speaking) {
        _speaking = false;
        unawaited(SpeechOutput.current.stop());
      }
      if (_listening) _stopListening(reason: 'background');
      if (mounted) {
        setState(() {
          _liveIdle = _LivePhase.waiting;
          _liveThinking = false;
          _liveAnswering = false;
        });
        _syncLive();
      }
      return;
    }
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

  /// The actions whose result is Android showing another app. `get_*` answers
  /// in place; these four hand the screen to somebody else for a moment.
  static bool _leavesTheApp(SystemActionCall call) =>
      call.action == 'set_timer' ||
      call.action == 'set_alarm' ||
      call.action == 'open_app' ||
      call.action == 'play_music' ||
      // The dialer is another app. Without this, answering "call mom" in live
      // mode backgrounded Nexus and the lifecycle handler closed the page — the
      // user came back to the text thread instead of the conversation they were
      // having. The 20-second guard keeps it open while the dialer is in front.
      call.action == 'call_number';

  /// Marks the background that follows a system action as temporary.
  void _holdLiveForAction() {
    _liveActionPending = true;
    _liveActionGuard?.cancel();
    _liveActionGuard = Timer(const Duration(seconds: 20), () {
      _liveActionPending = false;
      _liveActionGuard = null;
    });
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
    // A voice and its reopen timer belong to this screen: leaving them behind
    // would let the phone talk to a page that no longer exists, or open the
    // microphone from a listener nobody can see.
    _speechDone?.cancel();
    _speechDone = null;
    _autoListen?.cancel();
    _autoListen = null;
    _liveActionGuard?.cancel();
    _liveActionGuard = null;
    if (_speaking) unawaited(SpeechOutput.current.stop());
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

  bool get _hasText =>
      _message.text.trim().isNotEmpty || _pendingAttachments.isNotEmpty;

  /// Whether this turn may be read out loud. A spoken question is answered in
  /// voice only while the user has left Speak replies on; the bubble's own
  /// speaker button is a deliberate press and is not gated by this.
  bool get _maySpeak => VoiceSettings.instance.speakReplies;

  /// Puts one of the empty screen's suggestions into the field.
  ///
  /// Fills the draft rather than sending it: the suggestion is a sentence the
  /// user can finish or edit ("Turn on the flashlight … in the kitchen" is not
  /// the same request), and a tap that fired an action immediately would be a
  /// one-tap way to turn the torch on by accident.
  void _useSuggestion(String text) {
    setState(() {
      _message.text = text;
      _message.selection = TextSelection.collapsed(offset: text.length);
    });
    _focus.requestFocus();
  }

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
    final String text = _message.text.trim();
    final List<_PendingAttachment> pending = List<_PendingAttachment>.of(
      _pendingAttachments,
    );
    // A picture waiting in the composer is a reason to send even with an empty
    // field: the attachment is half the message, and the caption below is the
    // other half.
    if (text.isEmpty && pending.isEmpty) return;
    // Read once, here: whether this turn is answered out loud is a fact about
    // how it was dictated, and the flag is cleared by the send that consumes
    // it so the next typed question is not spoken on the strength of the last
    // spoken one.
    final bool spoken = _voiceTurn;
    _voiceTurn = false;
    // Anything the user just told Nexus about themselves is remembered before
    // the answer is asked for, so the same turn can already be answered with it.
    // Fire-and-forget: a file write must never delay the bubble.
    unawaited(MemoryService.instance.absorb(text));
    if (pending.isNotEmpty) {
      _sendPending(
        pending,
        text: text,
        question: text.isEmpty ? pending.first.kind.prompt : text,
        spoken: spoken,
      );
      return;
    }
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
    // The clock is the shell's, and a model cannot know it: asked on the A25
    // (with the time in its system turn) it answered "07:30" at 14:24. So a
    // question about the time is answered here, and the model is not asked at
    // all — the same rule as the phrase bridge below, for the same reason.
    if (isClockQuestion(text)) {
      unawaited(
        _runAction(
          const SystemActionCall('get_time'),
          _thread.length - 1,
          spoken: spoken,
        ),
      );
      return;
    }
    // Questions with a fixed true answer are the shell's as well, and the
    // weather is the one this app must answer itself: there is no weather
    // service behind a local-first assistant, and a model asked for tomorrow's
    // forecast invents one. The sentence is canned, instant, and says why.
    final String? canned = fastPathReply(text);
    if (canned != null) {
      _sayLocally(canned, _thread.length - 1, spoken: spoken);
      return;
    }
    // Arithmetic is the shell's too, and for a sharper reason than the clock:
    // measured on the A25, "what is 6 times 7" made the 1B model answer
    // `{"action":"set_timer","seconds":420}` — a seven-minute timer where an
    // answer belonged. One operation between two numbers has one answer, so
    // the shell works it out and the model is not asked.
    final String? sum = nexusMathAnswer(text);
    if (sum != null) {
      _sayLocally(sum, _thread.length - 1, spoken: spoken);
      return;
    }
    // A question about a picture goes to the vision layer, never to a text
    // brain: a model that cannot see answers "what is this?" with an invented
    // description, and the user has no way to tell one from a sighting. There
    // is no vision module installed yet, so the shell says so.
    final String? picture = _pictureAttached(_thread.length - 2);
    if (picture != null && isVisionQuestion(text)) {
      unawaited(
        _describePictures(
          <String>[picture],
          text,
          _thread.length - 1,
          spoken: spoken,
        ),
      );
      return;
    }
    // Strict commands — call, timer, flashlight — are the shell's, not the
    // model's. This is the Siri fast path: recognised before a single token is
    // generated, executed through the same native channel as any other action.
    final SystemActionCall? known = fastPathAction(text);
    if (known != null) {
      unawaited(_runAction(known, _thread.length - 1, spoken: spoken));
      return;
    }
    unawaited(_answer(text, _thread.length - 1, spoken: spoken));
  }

  /// Sends the attachment and the words together.
  ///
  /// This is the one place a draft becomes a turn. The picture is a user bubble
  /// with the typed message as its caption (or the kind's own caption when the
  /// user sent the picture alone), and a placeholder follows it exactly as a
  /// typed question does. The vision layer is asked the typed question when
  /// there is one, because "what does this sign say?" is the question the
  /// picture was attached to answer.
  void _sendPending(
    List<_PendingAttachment> pending, {
    required String text,
    required String question,
    required bool spoken,
  }) {
    final List<_PendingAttachment> images = <_PendingAttachment>[
      for (final _PendingAttachment item in pending)
        if (item.kind.isImage) item,
    ];
    _PendingAttachment? document;
    for (final _PendingAttachment item in pending) {
      if (!item.kind.isImage) {
        document = item;
        break;
      }
    }
    if (images.isNotEmpty) {
      final List<String> paths = <String>[
        for (final _PendingAttachment item in images) item.picked.path,
      ];
      final String caption = text.isNotEmpty ? text : images.first.kind.caption;
      setState(() {
        _thread.add(
          NexusMockMessage(
            caption,
            mine: true,
            imagePath: paths.first,
            imagePaths: paths,
          ),
        );
        _thread.add(const NexusMockMessage(kNexusThinking, thinking: true));
        _message.clear();
        _pendingAttachments.clear();
      });
      _persistThread();
      _focus.unfocus();
      _scrollToLatest();
      unawaited(
        _describePictures(paths, question, _thread.length - 1, spoken: spoken),
      );
      return;
    }
    if (document == null) return;
    final _PendingAttachment file = document;
    final String caption = '$kFileCaption: ${file.picked.name}';
    setState(() {
      _thread.add(
        NexusMockMessage(
          text.isNotEmpty ? text : caption,
          mine: true,
          filePath: file.picked.path,
        ),
      );
      _message.clear();
      _pendingAttachments.clear();
    });
    _persistThread();
    _focus.unfocus();
    _scrollToLatest();
  }

  /// Puts a picked image or document in the composer, not in the thread.
  ///
  /// Pictures queue up to [kNexusMaxPendingImages]; a fourth pick is refused
  /// with one sentence rather than silently replacing a picture the user chose.
  /// A document is a turn of its own, so choosing one clears the queue (and
  /// deletes the copies that were just discarded).
  void _addPending(PickedAttachment picked, AttachmentKind kind) {
    if (!kind.isImage) {
      final List<_PendingAttachment> discarded = List<_PendingAttachment>.of(
        _pendingAttachments,
      );
      setState(() {
        _pendingAttachments
          ..clear()
          ..add(_PendingAttachment(picked, kind));
      });
      for (final _PendingAttachment item in discarded) {
        unawaited(_deleteDiscarded(item.picked.path));
      }
      _focus.requestFocus();
      return;
    }
    final List<_PendingAttachment> existingImages = <_PendingAttachment>[
      for (final _PendingAttachment item in _pendingAttachments)
        if (item.kind.isImage) item,
    ];
    if (existingImages.length >= kNexusMaxPendingImages) {
      unawaited(_deleteDiscarded(picked.path));
      _say(
        'You can only attach up to $kNexusMaxPendingImages images at a time.',
        error: true,
      );
      return;
    }
    // A document and pictures cannot share one turn: the vision layer reads a
    // picture, while a document is handed over as a file. Whichever the user
    // picked last decides which kind of turn this is.
    final List<_PendingAttachment> discarded = <_PendingAttachment>[
      for (final _PendingAttachment item in _pendingAttachments)
        if (!item.kind.isImage) item,
    ];
    setState(() {
      _pendingAttachments.removeWhere(
        (_PendingAttachment item) => !item.kind.isImage,
      );
      _pendingAttachments.add(_PendingAttachment(picked, kind));
    });
    for (final _PendingAttachment item in discarded) {
      unawaited(_deleteDiscarded(item.picked.path));
    }
    _focus.requestFocus();
  }

  /// Answers [question] about [path] with the vision layer, in the bubble the
  /// placeholder is in.
  ///
  /// Asynchronous because a sighted implementation will be (an encoder run, a
  /// request over the mesh); the shipped one answers immediately with the
  /// sentence that says it has no eyes. A failure is a sentence too — the
  /// service answers rather than throwing, so this never has to catch.
  Future<void> _describePictures(
    List<String> paths,
    String question,
    int index, {
    required bool spoken,
  }) async {
    // One question, one answer. A single picture goes through [describe]; a
    // multi-image turn goes through [describeMany] so the brain is asked once
    // with a short label line per picture instead of once per image with the
    // whole OCR dump. Evidence is drawn under each bubble as it is reported,
    // whichever path ran, so the scan is visible before the answer is.
    String answer = '';
    if (paths.length > 1) {
      answer = await VisionAiService.current.describeMany(
        paths,
        question: question,
        onEvidence: (int i, VisionEvidence evidence) =>
            _showVisionEvidence(paths[i], evidence),
      );
    } else if (paths.isNotEmpty) {
      answer = await VisionAiService.current.describe(
        paths.first,
        question: question,
        onEvidence: (VisionEvidence evidence) =>
            _showVisionEvidence(paths.first, evidence),
      );
    }
    if (!mounted || index >= _thread.length) return;
    _sayLocally(answer, index, spoken: spoken);
  }

  /// Writes what ML Kit found under the bubble that carries [path].
  ///
  /// Found by path rather than by index because a follow-up question about an
  /// older photo is answered from the photo's own bubble, not the question's.
  /// Nothing is drawn when there was no text and no object: an empty caption
  /// would look like a scan that failed.
  void _showVisionEvidence(String path, VisionEvidence evidence) {
    if (!mounted || evidence.isEmpty) return;
    for (int i = _thread.length - 1; i >= 0; i--) {
      final NexusMockMessage message = _thread[i];
      if (!message.allImagePaths.contains(path)) continue;
      setState(() {
        _thread[i] = message.withVision(
          detectedText: evidence.text.trim().isEmpty
              ? null
              : evidence.text.trim(),
          labels: evidence.labels,
        );
      });
      _persistThread();
      return;
    }
  }

  /// The picture the question at [before] is about, or null.
  ///
  /// The last thing the *user* said before this question is the turn a
  /// follow-up refers to: after a photo, "what is this?" means the photo;
  /// after a typed question, it means the words. Only a user turn that carries
  /// an image counts, and only the newest one — a picture further up the thread
  /// is not what "this" points at, and answering as though it were would
  /// refuse a question nobody asked the shell.
  ///
  /// [before] is the index of the question itself, which is already in the
  /// thread: it is a user turn with no picture, so reading from the end would
  /// always answer "no picture" and the notice would never be said.
  String? _pictureAttached(int before) {
    for (int i = before - 1; i >= 0; i--) {
      final NexusMockMessage message = _thread[i];
      if (!message.mine) continue;
      return message.allImagePaths.isEmpty ? null : message.allImagePaths.first;
    }
    return null;
  }

  /// Puts [answer] where the placeholder is, as a normal bubble.
  ///
  /// This is the shell speaking as itself with something it worked out — a
  /// sum, or what the vision layer said — not the model and not a system pill:
  /// it looks like every other answer, it is stored like one, and a spoken
  /// question hears it back.
  void _sayLocally(String answer, int index, {required bool spoken}) {
    if (!mounted || index >= _thread.length) return;
    setState(() => _thread[index] = NexusMockMessage(answer));
    _persistThread();
    _scrollToLatest();
    if (spoken && _maySpeak) unawaited(SpeechOutput.current.speak(answer));
  }

  /// The composer's camera button: the phone's own camera app, one shot, and
  /// the kept photo back into the thread.
  ///
  /// Deliberately not a preview of our own. A Flutter camera preview on some
  /// Samsung phones returns a black frame — the shutter can fire before the
  /// sensor exposes, and the JPEG that comes back is the dark one. The system
  /// camera app owns its warm-up, its metering and its own shutter, and hands
  /// `image_picker` a finished file, which is the reliability this button owes
  /// the user.
  Future<void> _openCamera() async {
    // One line on the log Flutter already writes, so `adb logcat | grep
    // camera:` answers "did the button fire?" without a debugger. The picker
    // logs its own failure; this line is the tap itself.
    debugPrint('camera: attach button tapped ${_stamp()}');
    // Closing the keyboard first: the system camera is a full screen, and
    // coming back to a raised keyboard over the thread would cover the bubble.
    _focus.unfocus();
    final PickedAttachment? picked = await AttachmentPickers.current
        .captureImage();
    debugPrint(
      'camera: ${picked == null ? 'cancelled' : 'captured'} ${_stamp()}',
    );
    if (picked == null || !mounted) return;
    final String? kept = await AttachmentStore.instance.keep(
      picked.path,
      kind: AttachmentKind.photo,
    );
    if (!mounted) return;
    if (kept == null) {
      _say('That photo could not be read.');
      return;
    }
    _addPending(
      PickedAttachment(path: kept, name: picked.name),
      AttachmentKind.photo,
    );
  }

  /// The `+`: one sheet, three doors, and no dialog of its own. The sheet is
  /// dismissed before a picker opens, so the phone's gallery or file browser
  /// arrives on a screen that is not still drawing a menu over it.
  Future<void> _openAttachmentSheet() async {
    _focus.unfocus();
    final _AttachChoice? choice = await showModalBottomSheet<_AttachChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) => const _AttachmentSheet(),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AttachChoice.camera:
        await _openCamera();
      case _AttachChoice.photos:
        await _pickPhoto();
      case _AttachChoice.files:
        await _pickFile();
    }
  }

  /// One picture from the gallery, kept like a camera shot and described by the
  /// same vision layer.
  Future<void> _pickPhoto() async {
    debugPrint('attach: photos tapped ${_stamp()}');
    final PickedAttachment? picked = await AttachmentPickers.current
        .pickImage();
    debugPrint(
      'attach: gallery ${picked == null ? 'cancelled' : 'picked'} ${_stamp()}',
    );
    if (picked == null || !mounted) return;
    final String? kept = await AttachmentStore.instance.keep(
      picked.path,
      kind: AttachmentKind.gallery,
    );
    if (!mounted) return;
    if (kept == null) {
      _say('That photo could not be read.');
      return;
    }
    _addPending(
      PickedAttachment(path: kept, name: picked.name),
      AttachmentKind.gallery,
    );
  }

  /// One document from the file browser. A document is not a picture: it gets
  /// its own chip and its own line in the thread, and the vision layer is never
  /// asked to look at it. Nothing answers for it, because a text brain given a
  /// PDF's name would invent its contents — the honest reply is the file the
  /// user attached, and the next question they type.
  Future<void> _pickFile() async {
    debugPrint('attach: files tapped ${_stamp()}');
    final PickedAttachment? picked = await AttachmentPickers.current.pickFile();
    debugPrint(
      'attach: file ${picked == null ? 'cancelled' : 'picked'} ${_stamp()}',
    );
    if (picked == null || !mounted) return;
    final String? kept = await AttachmentStore.instance.keep(
      picked.path,
      kind: AttachmentKind.document,
    );
    if (!mounted) return;
    if (kept == null) {
      _say('That file could not be read.');
      return;
    }
    _addPending(
      PickedAttachment(path: kept, name: picked.name),
      AttachmentKind.document,
    );
  }

  /// One frame of this phone through the platform's own projection dialog.
  ///
  /// Live conversation is the only caller: sharing a screen is a thing said
  /// while the user is talking, not a button in the composer that competes with
  /// the message they are typing. Answers the kept path, or null after saying
  /// why on screen.
  Future<String?> _captureScreen() async {
    debugPrint('screen: share button tapped ${_stamp()}');
    final ScreenCaptureResult result = await ScreenCapture.capture();
    debugPrint('screen: capture ${result.ok ? 'ok' : 'refused'} ${_stamp()}');
    if (!mounted) return null;
    final String? path = result.path;
    if (path == null) {
      _say(result.message ?? 'The screenshot could not be taken.');
      return null;
    }
    // Kept like a camera shot, so the thumbnail survives a restart.
    final String? kept = await AttachmentStore.instance.keep(
      path,
      kind: AttachmentKind.screenshot,
    );
    if (!mounted) return null;
    if (kept == null) {
      _say('The screenshot could not be read back.');
      return null;
    }
    return kept;
  }

  /// One short sentence over the thread — what a refusal or a failed capture
  /// gets, in the place the user is already looking.
  /// One short sentence at the bottom of the screen.
  ///
  /// [error] paints it in the theme's danger red. Reserved for something the
  /// user asked for that the app refused — the image limit is the one of those
  /// today — because a red notice for an ordinary "could not read that photo"
  /// would make every unreadable file look like a bug.
  void _say(String message, {bool error = false}) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) return;
    final NexusUiColors c = context.ui;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: error ? TextStyle(color: c.background) : null,
          ),
          backgroundColor: error ? c.danger : null,
          duration: const Duration(milliseconds: 2400),
        ),
      );
  }

  /// Asks GitHub once, quietly, whether this build is the newest. Failures are
  /// silent by design: a check that could not be made is not news, and a banner
  /// saying so would be a worse launch than no banner.
  Future<void> _checkStartupUpdate() async {
    final UpdateCheck check;
    if (HomeTab.updateCheckOverride != null) {
      check = await HomeTab.updateCheckOverride!();
    } else {
      final String current = await installedAppVersion();
      check = await Updater.checkForUpdate(currentVersion: current);
    }
    if (!mounted || check.info == null) return;
    setState(() => _startupUpdate = check.info);
  }

  /// Puts the conversation from the last launch back on screen.
  ///
  /// [ChatLog.attach] is idempotent — the shell builds the tab once and keeps
  /// it alive — and a thread that already has something in it is never
  /// overwritten: what the user has just done beats what was on disk.
  Future<void> _restoreThread() async {
    final ChatLog log = ChatLog.instance;
    await log.attach();
    if (!mounted) return;
    _activeChatId = log.activeSessionId;
    if (log.entries.isEmpty) return;
    if (_thread.isNotEmpty) return;
    _loadThreadFrom(log);
  }

  /// Replaces the bubbles with the open stored conversation.
  ///
  /// The repair callback is shared with the first restore: a line written by an
  /// older build is shown as this build reads it, and written back once.
  void _loadThreadFrom(ChatLog log) {
    bool repaired = false;
    setState(() {
      _liked.clear();
      _disliked.clear();
      _thread
        ..clear()
        ..addAll(<NexusMockMessage>[
          for (final ChatEntry entry in log.entries)
            NexusMockMessage(
              _restoredText(entry, onRepair: () => repaired = true),
              mine: entry.mine,
              failed: entry.failed,
              system: entry.system,
              ok: entry.ok,
              imagePath: entry.imagePath,
              imagePaths: entry.allImagePaths,
              filePath: entry.filePath,
              visionText: entry.visionText,
              visionLabels: entry.visionLabels,
              reasoning: entry.reasoning,
            ),
        ]);
    });
    if (repaired) _persistThread();
    _scrollToLatest();
  }

  /// [entry]'s words as this build shows them.
  ///
  /// The user's own lines and the shell's are copied exactly as saved — they
  /// were never the model's output. An *answer* saved before
  /// [nexusReadableText] existed can still be a JSON object (the A25's thread
  /// had `{ "result": 4 }` in it), and the point of the interceptor is that
  /// the screen never shows one; reading it on the way in is what makes that
  /// true of a conversation that predates the fix, not only of the next one.
  String _restoredText(ChatEntry entry, {required VoidCallback onRepair}) {
    if (entry.mine ||
        entry.system ||
        entry.imagePath != null ||
        entry.filePath != null) {
      return entry.text;
    }
    final String text = nexusReadableText(entry.text).trim();
    if (text.isEmpty) {
      onRepair();
      return kNexusNoAnswerText;
    }
    if (text == entry.text) return entry.text;
    onRepair();
    return text;
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
            imagePath: message.imagePath,
            imagePaths: message.allImagePaths,
            filePath: message.filePath,
            visionText: message.visionText,
            visionLabels: message.visionLabels,
            reasoning: message.reasoning,
          ),
    ]);
  }

  /// The log changed somewhere else — Settings cleared it — so the bubbles go
  /// with it. Our own saves land here too and are no-ops: they always leave the
  /// log with the thread in it.
  void _onChatLog() {
    if (!mounted) return;
    final ChatLog log = ChatLog.instance;
    final String? active = log.activeSessionId;
    if (active != _activeChatId) {
      // The first save of a brand-new chat creates its session while the
      // bubbles are already on screen. That is this screen's own work, not a
      // switch: adopting the id keeps the streaming answer and its placeholder
      // exactly where they are. Any later id change is a drawer selection or a
      // wipe, and the bubbles must follow it.
      final bool firstSave = _activeChatId == null && _thread.isNotEmpty;
      _activeChatId = active;
      if (!firstSave) _loadThreadFrom(log);
      return;
    }
    if (log.hasChat || _thread.isEmpty) return;
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
    // What the model is shown of the shell's own lines is a deliberate split.
    //
    // A *successful* action line stays: "Timer set for 5 minutes." is the reply
    // to the question, and a model handed the question with no reply reads the
    // next turn as a second half of the same request (measured on llama3.2,
    // which answered "turn on the flashlight" by setting the timer again).
    //
    // A *refusal* does not: "I can't do that yet — "get description" isn't one
    // of my phone actions" contains an action-shaped word, teaches nothing about
    // what happened, and measurably turns a small model into an action machine.
    // On the A25 a thread with three of them in it answered "explain what a mesh
    // network is" with a Wi-Fi request.
    final List<AiTurn> turns = <AiTurn>[];
    for (final NexusMockMessage message in _thread.take(index)) {
      if (message.thinking || message.failed) continue;
      if (message.system && !message.ok) continue;
      // Two questions in a row is what dropping a refusal leaves behind, and a
      // chat template built for alternating turns reads it as one question
      // asked twice. The later one is the one still being asked — and keeping
      // it (rather than the earlier one) keeps the question beside its answer.
      if (message.mine && turns.isNotEmpty && turns.last.fromUser) {
        turns[turns.length - 1] = AiTurn.user(message.text);
        continue;
      }
      turns.add(AiTurn(fromUser: message.mine, text: message.text));
    }
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
      unawaited(_settleToLatest());
    });
  }

  /// Scrolls to the end, and again if the end moved while the scroll ran.
  ///
  /// One pass is enough for a bubble that arrives whole. It is not enough for a
  /// picture: the thumbnail is laid out when the bytes are decoded, which is
  /// after the frame that added it, so the thread can grow *behind* an
  /// animation that is already running — and an animation cannot chase a target
  /// that moved. Measured on the A25: attaching a photo left the shell's answer
  /// one bubble below the fold, and the user had to swipe to learn it was
  /// there. Two passes cover the growth; a third would be a ticker.
  Future<void> _settleToLatest() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || !_threadScroll.hasClients) return;
      final ScrollPosition position = _threadScroll.position;
      final double end = position.maxScrollExtent;
      final bool atEnd = (end - position.pixels).abs() < 1;
      // One pass is enough when the thread already ends on screen; the frame
      // below is what proves it, because the extent is only an estimate of the
      // children built so far.
      if (atEnd && attempt > 0) return;
      if (!atEnd) {
        await _threadScroll.animateTo(
          end,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
      // Let the list lay out what the scroll uncovered. Its extent is
      // estimated from the children it has built, so a bubble that arrived
      // below the fold — an attachment's answer is the one measured — can
      // raise it only after this frame, and the next pass is what catches it.
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Switches to Qwen 0.5B when the model the user picked does not fit.
  ///
  /// Answers whether the caller should ask again. True only when the smaller
  /// model is actually on this phone and is not already the selected one — a
  /// switch to a file that is not there would turn one honest failure into a
  /// second, less useful one. The selection is written through [ModelChoice], so
  /// the next question loads the smaller weights and the Settings row agrees.
  Future<bool> _switchToSmallerModel(InsufficientMemoryException error) async {
    if (ModelChoice.instance.choice == OnDeviceModelChoice.qwen) return false;
    const OnDeviceModel model = OnDeviceModel();
    if (!await model.withChoice(OnDeviceModelChoice.qwen).isPresent()) {
      return false;
    }
    debugPrint(
      'AI: ${error.message} Switching to ${OnDeviceModelChoice.qwen.label}.',
    );
    await ModelChoice.instance.select(OnDeviceModelChoice.qwen);
    return true;
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
    final Stopwatch clock = Stopwatch()..start();
    final StringBuffer buffer = StringBuffer();
    // Whether any of the answer has been shown yet: until it has, the bubble is
    // still the placeholder and may be replaced under us; after it has, the
    // words on screen are this turn's.
    bool shown = false;
    bool failed = false;
    // The question the model is actually asked. Web search does not replace
    // the question — it appends what a search found to the same prompt, so the
    // model sees both what was asked and the current facts the user allowed it
    // to look up. A search that fails leaves the prompt exactly as it was.
    String asked = prompt;
    if (ComposerSettings.instance.webSearchEnabled) {
      final List<WebResult> results = await nexusWebSearch(prompt);
      if (results.isNotEmpty) asked = '$prompt\n\n${webContextBlock(results)}';
      if (!mounted) return;
    }
    // Read before the request goes out: the history is everything said before
    // this question, so the answer knows what "it" refers to. The on-device
    // engine renders these turns through the model's own chat template (Qwen's
    // is ChatML) and Ollama through `/api/chat`; nothing here hand-writes
    // `<|im_start|>`, which would template the turns a second time.
    final List<AiTurn> history = _historyBefore(index);
    // Two attempts at most: a model that does not fit is retried once on the
    // smaller one the user has, and a guard that fires again is the answer.
    for (int attempt = 0; ; attempt++) {
      try {
        await for (final String piece
            in LocalAiService.current.generateResponseStream(
              asked,
              history: history,
            )) {
          // The screen may be gone, and the bubble may have been answered
          // already by a seam that resolved twice: a replaced bubble is left
          // alone.
          if (!mounted || index >= _thread.length) return;
          if (!shown && !_thread[index].thinking) return;
          buffer.write(piece);
          // A reply that has reached a `{` may be an action request, and half a
          // JSON object is not a sentence: the visible text stops at the brace
          // and the placeholder stays until the request is whole and the
          // interceptor can say what happened. Prose streams exactly as it
          // always did, so nothing that is not an action pays for this.
          final NexusThoughtSplit split = splitNexusThought(
            buffer.toString(),
            finished: false,
          );
          final String visible = nexusStreamingProse(split.answer);
          final String reasoning = split.reasoning.trim();
          if (visible.trim().isEmpty && split.answer.contains('{')) {
            continue;
          }
          shown = shown || visible.isNotEmpty || reasoning.isNotEmpty;
          // A half-written answer is a placeholder, not a reply: the words are
          // on screen as they arrive, and the copy/speaker row waits for the
          // sentence to be whole. See [NexusChatBubble.thinking]. The reasoning
          // streams above it in its own bubble while [split.thinking] is true.
          setState(
            () => _thread[index] = NexusMockMessage(
              visible.isEmpty ? kNexusThinking : visible,
              thinking: true,
              reasoning: reasoning.isEmpty ? null : reasoning,
            ),
          );
          _scrollToLatestSoon();
        }
        break;
      } on InsufficientMemoryException catch (error) {
        // The guard fires before a weight is loaded, so nothing has been shown
        // and the smaller model can be asked the same question. Once only: a
        // guard that fires again is the answer, not a reason to keep trying.
        if (attempt == 0 && await _switchToSmallerModel(error)) {
          buffer.clear();
          shown = false;
          continue;
        }
        _appendFailure(buffer, kNexusNotEnoughMemoryText);
        failed = true;
        break;
      } on OllamaException catch (error) {
        _appendFailure(buffer, error.message);
        failed = true;
        break;
      } on OnDeviceAiException catch (error) {
        // The model stopped mid-answer: the words it managed are kept, and the
        // sentence that says so is what the bubble ends with.
        _appendFailure(buffer, error.message);
        failed = true;
        break;
      } catch (_) {
        _appendFailure(buffer, kNexusOllamaUnreachableText);
        failed = true;
        break;
      }
    }
    LogService.instance.log(
      'AI: answer in ${clock.elapsedMilliseconds}ms '
      '(${prompt.length} chars${failed ? ', failed' : ''})',
    );
    if (!mounted || index >= _thread.length) return;
    final NexusThoughtSplit thought = splitNexusThought(buffer.toString());
    final String? reasoning = thought.reasoning.trim().isEmpty
        ? null
        : thought.reasoning.trim();
    String reply = thought.answer;
    if (reply.isEmpty) {
      // Nothing at all came back and nothing threw: a brain that answered with
      // silence is not an answer, and the user is owed the notice.
      reply = kNexusOllamaUnreachableText;
      failed = true;
    }
    // An answer that contains an action request is not an answer: it is the
    // model asking this phone to do something. The request is stripped and run
    // here, before anything is shown, and the thread gets whatever prose was
    // left plus the shell's line about what happened — never the JSON that
    // asked for it. A reply that is *nearly* an action — an unknown name, a
    // missing argument, an object that is not an action at all — has no calls
    // to run and becomes the bubble below, with its JSON read into words.
    if (!failed) {
      final NexusActionIntercept intercept = interceptSystemActions(reply);
      if (intercept.acted) {
        await _runActions(
          intercept,
          index,
          spoken: spoken,
          reasoning: reasoning,
        );
        return;
      }
      // The interceptor is also where an answer written in JSON becomes words:
      // the bubble shows what it returned, never the reply as it arrived. Asked
      // "what is two plus two", a 1B model answers `{"result": 4}`, and "4" is
      // the answer — the object is how it was said, not what it said.
      reply = intercept.text.trim().isEmpty
          ? kNexusNoAnswerText
          : intercept.text;
    }
    setState(
      () => _thread[index] = NexusMockMessage(
        reply,
        failed: failed,
        reasoning: reasoning,
      ),
    );
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
    if (!failed && spoken && _maySpeak) {
      unawaited(SpeechOutput.current.speak(reply));
    }
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
  }) => _runActions(
    NexusActionIntercept('', <SystemActionCall>[call]),
    index,
    spoken: spoken,
  );

  /// Runs every action [intercept] found, and puts [intercept]'s prose — if any
  /// — in the bubble the placeholder was in.
  ///
  /// The line that lands is the shell's, not the model's: [SystemActionOutcome]
  /// carries what it did ("Flashlight on.") or the phone's own reason it could
  /// not ("What app should I open?"). A model that wrote a sentence *and* an
  /// action keeps its sentence: it is a real answer, and throwing it away
  /// because the model also asked for something would be losing the half of the
  /// reply the user can read. The pills follow it, one per action, in the order
  /// they were asked for — and a request for an action this phone does not have
  /// gets a pill of its own rather than the JSON the model wrote.
  Future<void> _runActions(
    NexusActionIntercept intercept,
    int index, {
    required bool spoken,
    String? reasoning,
  }) async {
    final String prose = intercept.text.trim();
    if (!mounted || index >= _thread.length) return;
    int at = index;
    if (prose.isEmpty) {
      // The placeholder asked "Nexus is thinking…"; the first pill answers it.
      // Removing it here and inserting at the same index keeps the exchange in
      // the same place the answer would have taken.
      setState(() => _thread.removeAt(index));
    } else {
      setState(
        () => _thread[index] = NexusMockMessage(prose, reasoning: reasoning),
      );
      at = index + 1;
      _persistThread();
      _scrollToLatest();
    }
    // What the model asked for, in the order it asked, each with whether the
    // phone could do it: the actions first, then the requests with no action
    // behind them. Both are the shell speaking about the phone, which is what a
    // system line is.
    final List<(String, bool)> lines = <(String, bool)>[];
    for (final SystemActionCall call in intercept.calls) {
      final SystemActionOutcome outcome = await SystemActions.current.execute(
        call,
      );
      LogService.instance.log(
        'ACTION: ${call.action} ${outcome.ok ? 'ok' : 'failed'} — '
        '${outcome.message}',
      );
      if (!mounted) return;
      lines.add((outcome.message, outcome.ok));
    }
    for (final String name in intercept.refused) {
      lines.add((nexusUnknownActionLine(name), false));
    }
    for (final (String line, bool ok) in lines) {
      if (!mounted) return;
      setState(
        () => _thread.insert(
          at.clamp(0, _thread.length),
          NexusMockMessage(line, system: true, ok: ok),
        ),
      );
      at++;
      // The action is half of what the next question will be read against, and
      // it is stored as what it is: a line the shell wrote, not an answer.
      _persistThread();
      _scrollToLatest();
      if (spoken && _maySpeak) unawaited(SpeechOutput.current.speak(line));
    }
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
    final int session = ++_micSessions;
    setState(() {
      _micSession = session;
      _micMode = mode;
    });
    _logMic('mic:start ${_stamp()} mode=${mode.name}');
    // Apply the chosen language on every session, not only when the dropdown
    // changes. Sent before `listen` on the same channel, and deliberately not
    // awaited: the listening state must appear in the frame the finger asked
    // for it, and a language the platform has not applied yet falls back to its
    // own — a recognizer that never opens is the worse failure.
    unawaited(speech.setLanguage(VoiceSettings.instance.language));
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
        // While the monitor is open under the answer, a transcript is the
        // assistant's own voice coming back: showing it would make the page
        // say the user's words in the user's mouth. Only the loudness is read
        // in that window.
        if (_speaking && _liveBargeIn) return;
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
    // While the assistant is talking, the microphone is not listening for a
    // turn — it is listening for a person. Anything below the barge-in
    // threshold is the phone's own speaker, the room, or both, and is ignored:
    // arming the end-of-turn pause here would end a turn nobody has started.
    if (_speaking) {
      if (_liveBargeIn && db >= kBargeInDb) _armBargeIn(session);
      return;
    }
    if (db >= kSpeechVoiceDb) {
      _noteLiveWord(session);
      return;
    }
    if (db > kSpeechQuietDb) return;
    _armLiveSettle(session);
  }

  /// A voice heard over the assistant's own: one more reading and the voice
  /// stops. The hold is what keeps a door, a cough, or the phone's own speaker
  /// from cutting an answer off — a real interruption is sustained for a
  /// quarter of a second, and a single loud frame is not.
  void _armBargeIn(int session) {
    if (!_liveBargeIn || _bargeInHold != null) return;
    _bargeInHold = Timer(_bargeInSustain, () {
      _bargeInHold = null;
      if (!mounted || _micSession != session || !_speaking) return;
      _interruptForUser();
    });
  }

  /// The interruption itself: the voice goes, the microphone stays. The
  /// session the monitor opened is already live, so the user's next sentence
  /// streams into the page without a second recognizer being started under
  /// their own voice.
  void _interruptForUser() {
    _bargeInHold?.cancel();
    _bargeInHold = null;
    _bargeInStart?.cancel();
    _bargeInStart = null;
    _liveBargeIn = false;
    _liveVoice = false;
    _liveFinished = false;
    if (mounted) setState(() => _speaking = false);
    unawaited(SpeechOutput.current.stop());
    _syncLive();
  }

  /// Opens the monitor half a second into an answer. Nothing happens if the
  /// answer is already over, if the page is gone, or if a session is somehow
  /// open already — one microphone, one session, as everywhere else.
  void _startBargeInMonitor() {
    _bargeInStart?.cancel();
    if (!_liveOpen || !_speaking) return;
    _bargeInStart = Timer(_bargeInDelay, () {
      _bargeInStart = null;
      if (!mounted ||
          !_liveOpen ||
          !_speaking ||
          _listening ||
          _liveThinking ||
          _liveAnswering) {
        return;
      }
      _liveBargeIn = true;
      _liveVoice = false;
      _liveFinished = false;
      unawaited(_listen(_MicMode.live));
    });
  }

  /// Stops the monitor's timers without touching the voice or the microphone.
  /// Used on every path that ends speaking, so a late reading cannot stop a
  /// voice that is no longer going.
  void _cancelBargeIn() {
    _bargeInStart?.cancel();
    _bargeInStart = null;
    _bargeInHold?.cancel();
    _bargeInHold = null;
    _liveBargeIn = false;
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
    // The next turn is the user's, so any speech left over from the last answer
    // is cut off here rather than allowed to talk over them. Its completion
    // listener and its reopen timer belong to that turn and go with it.
    if (_speaking) unawaited(SpeechOutput.current.stop());
    _speechDone?.cancel();
    _speechDone = null;
    _autoListen?.cancel();
    _autoListen = null;
    _speaking = false;
    _cancelBargeIn();
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
    _syncLive();
    await _listen(_MicMode.live);
  }

  /// Reads [text] out loud and reopens the microphone once the voice is done.
  ///
  /// The completion comes from the platform (`done` on the speech-out channel),
  /// not from a guessed duration: a second after the last word is the right
  /// pause, and a second after the *first* word would talk over the answer.
  /// Devices with no speech engine answer `false` immediately, and the turn is
  /// handed back the same way.
  void _speakThenListen(String text) {
    _speechDone?.cancel();
    _autoListen?.cancel();
    _autoListen = null;
    if (!mounted || !_liveOpen) return;
    final SpeechOutput speech = SpeechOutput.current;
    _speechDone = speech.spoken.listen((_) {
      _speechDone?.cancel();
      _speechDone = null;
      _finishSpeaking();
    });
    setState(() => _speaking = true);
    _syncLive();
    _startBargeInMonitor();
    unawaited(
      speech.speak(text).then((bool spoke) {
        // No engine, or it refused: there is nothing to listen for, so the turn
        // comes back on the same 1.5 s beat as a finished sentence.
        if (!spoke) _finishSpeaking();
      }),
    );
  }

  /// The voice has stopped: show the closed microphone, then hand the turn back.
  ///
  /// Guarded by [_speaking], so the platform's `done`, a stop, and a page close
  /// racing each other cannot schedule the microphone twice.
  void _finishSpeaking() {
    if (!mounted || !_speaking) return;
    _cancelBargeIn();
    setState(() => _speaking = false);
    _syncLive();
    // The barge-in monitor may already have the microphone open. The answer
    // ended on its own, but the room is listening: there is nothing to
    // schedule, and opening a second session would be the double microphone
    // this page exists to prevent.
    if (_listening) return;
    _autoListen?.cancel();
    _autoListen = Timer(_autoListenGap, () {
      _autoListen = null;
      if (!mounted ||
          !_liveOpen ||
          _listening ||
          _liveThinking ||
          _liveAnswering) {
        return;
      }
      unawaited(_liveTurn());
    });
  }

  /// The interruption: cut the voice off and hand the microphone straight back.
  ///
  /// This is what "stop" means in a conversation — the user is not asking for
  /// the page to go quiet, they are asking to say the next thing. So the voice
  /// stops and the next turn opens on the same beat, rather than leaving a
  /// greys screen with a tap-to-continue control; the 1.5 s hand-back is for a
  /// reply that finished on its own, not for a control that was pressed.
  void _stopSpeaking() {
    _speechDone?.cancel();
    _speechDone = null;
    _autoListen?.cancel();
    _autoListen = null;
    final bool wasSpeaking = _speaking;
    _cancelBargeIn();
    if (_speaking) setState(() => _speaking = false);
    _syncLive();
    unawaited(SpeechOutput.current.stop());
    // A monitor session is already the next turn: stopping the voice leaves it
    // open rather than closing and reopening the microphone under the user's
    // first word.
    if (_listening) return;
    if (wasSpeaking && _liveOpen && mounted) unawaited(_liveTurn());
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

  /// The tap that opens a live turn by hand — after a Stop speaking, or after
  /// the guard swept a silent room up. (An answer that finishes normally hands
  /// the turn back on its own; see [_finishSpeaking].)
  ///
  /// Refused while an answer is on its way: the user tapping a *thinking* orb is
  /// asking to interrupt a request that is already out, and the honest answer is
  /// to let it finish and then show what it said.
  void _liveResume() {
    if (!_liveOpen || _listening || _liveThinking || _liveAnswering) return;
    unawaited(_liveTurn());
  }

  /// The microphone circle and the pill: one control in two shapes. An open
  /// microphone closes (the page then says Mic off and offers the tap back); a
  /// closed one opens the next turn.
  void _liveToggleMic() {
    if (!_liveOpen) return;
    if (_listening) {
      _stopListening();
      return;
    }
    _liveResume();
  }

  /// A live turn ended with [text] — or with nothing, when the room was quiet.
  ///
  /// The microphone closes here and does not reopen until an answer has been
  /// spoken — the old version restarted itself after a pause, which on real
  /// hardware looked exactly like an app recording a room nobody had asked
  /// about. What happens next depends on whether there is anything to answer. A
  /// quiet turn has nothing to send, so it lands straight in [waiting] with the
  /// previous sentence still on screen. A turn with words in it goes to
  /// [thinking] while the PC is asked, and the answer — or the reason there
  /// isn't one — replaces the large type when it arrives, in [_liveAnswer]; that
  /// is also where the 1.5 s hand-back is scheduled.
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

  /// Puts [text] on the live page as the answer, says it, and hands the turn
  /// back — the shell answering as itself, with something it worked out.
  void _answerLiveLocally(String text, int turn) {
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    setState(() {
      _liveThinking = false;
      _liveAnswering = false;
      _liveIdle = _LivePhase.waiting;
      _liveSaid = text;
      _liveAnswerText = '';
      _addLiveTurn(NexusMockMessage(text));
    });
    _syncLive();
    _speakThenListen(text);
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
    // A spoken clock question gets the same treatment as a typed one: the shell
    // answers from the phone's clock, and the model — which would invent a time
    // — is never asked. It is shown and said exactly as an action result is.
    if (isClockQuestion(prompt)) {
      final SystemActionOutcome outcome = await SystemActions.current.execute(
        const SystemActionCall('get_time'),
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
      _speakThenListen(outcome.message);
      return;
    }
    // The weather, for the same reason and with the same sentence a typed
    // question gets: a spoken "what's the weather" cannot reach a weather
    // service, and the model would guess.
    final String? canned = fastPathReply(prompt);
    if (canned != null) {
      _answerLiveLocally(canned, turn);
      return;
    }
    // And arithmetic is the shell's here too. A spoken "what is six times
    // seven" must not become a timer any more than a typed one did — the same
    // question said out loud is the same question.
    final String? sum = nexusMathAnswer(prompt);
    if (sum != null) {
      _answerLiveLocally(sum, turn);
      return;
    }
    // And the phrase bridge: a request the shell already understands is run
    // here too, before the model is asked. "Play some music" said into the
    // room must open a player or say it could not — never come back as the
    // model claiming it did, which is exactly what it wrote on the A25.
    final SystemActionCall? known = fastPathAction(prompt);
    if (known != null) {
      if (_leavesTheApp(known)) _holdLiveForAction();
      final SystemActionOutcome outcome = await SystemActions.current.execute(
        known,
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
      _speakThenListen(outcome.message);
      return;
    }
    final StringBuffer buffer = StringBuffer();
    // The same web-search rule as the thread: a question said out loud is the
    // same question, and a switch that only worked in text would be a switch
    // the user has to remember is missing here.
    String asked = prompt;
    if (ComposerSettings.instance.webSearchEnabled) {
      final List<WebResult> results = await nexusWebSearch(prompt);
      if (results.isNotEmpty) asked = '$prompt\n\n${webContextBlock(results)}';
      if (!mounted || !_liveOpen || turn != _liveTurns) return;
    }
    // Read once, before the request goes out: the history is the conversation
    // *up to* this question, and a later turn must not be able to change what
    // this one was asked with.
    final List<AiTurn> history = _liveHistory;
    // Only a sentence the model actually said is read out loud. The unreachable
    // notice is the shell talking, and hearing a machine apologise for its PC is
    // worse than reading it.
    bool spoken = true;
    // Same one-retry rule as the thread: a model that does not fit is answered
    // by the smaller one the user has, and the live turn keeps going — the mic
    // stays closed for the whole of it, so nothing is heard twice.
    for (int attempt = 0; ; attempt++) {
      try {
        await for (final String piece
            in LocalAiService.current.generateResponseStream(
              asked,
              history: history,
            )) {
          // Dropped when the page is gone or the user has already moved on: an
          // answer belongs to the turn that asked for it.
          if (!mounted || !_liveOpen || turn != _liveTurns) return;
          buffer.write(piece);
          // Same rule as the thread: once a `{` arrives the reply may be an
          // action request, and the page says "Thinking…" for the half-second
          // it takes to be whole rather than spelling raw JSON out in large
          // type.
          final NexusThoughtSplit thought = splitNexusThought(
            buffer.toString(),
            finished: false,
          );
          final String visible = nexusStreamingProse(thought.answer);
          if (visible.trim().isEmpty &&
              (buffer.toString().contains('{') || thought.thinking)) {
            continue;
          }
          // The words are the page now: the orb keeps its working colour while
          // the answer is being written, but the large type shows the answer
          // arriving instead of leaving the screen on "Thinking…".
          setState(() {
            _liveAnswering = true;
            _liveAnswerText = visible;
          });
          _syncLive();
        }
        break;
      } on InsufficientMemoryException catch (error) {
        if (attempt == 0 && await _switchToSmallerModel(error)) {
          buffer.clear();
          if (mounted) {
            setState(() {
              _liveAnswering = false;
              _liveAnswerText = '';
            });
          }
          continue;
        }
        buffer.write(
          buffer.isEmpty
              ? kNexusNotEnoughMemoryText
              : '\n\n$kNexusNotEnoughMemoryText',
        );
        spoken = false;
        break;
      } on OllamaException catch (error) {
        buffer.write(buffer.isEmpty ? error.message : '\n\n${error.message}');
        spoken = false;
        break;
      } on OnDeviceAiException catch (error) {
        buffer.write(buffer.isEmpty ? error.message : '\n\n${error.message}');
        spoken = false;
        break;
      } catch (_) {
        buffer.write(
          buffer.isEmpty
              ? kNexusOllamaUnreachableText
              : '\n\n$kNexusOllamaUnreachableText',
        );
        spoken = false;
        break;
      }
    }
    if (buffer.isEmpty) {
      buffer.write(kNexusOllamaUnreachableText);
      spoken = false;
    }
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    // An action asked for out loud is run here too, and its line takes the
    // large type exactly as an answer would: a user who says "it's dark in here"
    // to the live page should see the flashlight turn on, not a JSON object —
    // whether the model wrote strict JSON or the loose `{action: …}` a small
    // model actually produces.
    final String spokenText = splitNexusThought(buffer.toString()).answer;
    final NexusActionIntercept intercept = spoken
        ? interceptSystemActions(spokenText)
        : const NexusActionIntercept('', <SystemActionCall>[]);
    if (intercept.acted) {
      // Some of these actions open Android's own app — the clock, the music
      // player, another app — and that background moment must not be read as
      // the user ending live conversation. Nothing else about the turn changes:
      // the action still runs, the line is still said, and the microphone still
      // comes back.
      if (intercept.calls.any(_leavesTheApp)) _holdLiveForAction();
      final List<SystemActionOutcome> outcomes = <SystemActionOutcome>[];
      for (final SystemActionCall call in intercept.calls) {
        outcomes.add(await SystemActions.current.execute(call));
        if (!mounted || !_liveOpen || turn != _liveTurns) return;
      }
      final String prose = intercept.text.trim();
      // The sentence the page shows and says: what happened, then what the
      // phone has no answer for. A refusal is information too — the user asked
      // for something, and "not one of my phone actions" is the honest reply.
      final String line = <String>[
        for (final SystemActionOutcome outcome in outcomes) outcome.message,
        for (final String name in intercept.refused)
          nexusUnknownActionLine(name),
      ].join(' ');
      setState(() {
        _liveThinking = false;
        _liveAnswering = false;
        _liveIdle = _LivePhase.waiting;
        _liveSaid = prose.isEmpty ? line : '$prose\n$line';
        _liveAnswerText = '';
        if (prose.isNotEmpty) _addLiveTurn(NexusMockMessage(prose));
        for (final SystemActionOutcome outcome in outcomes) {
          _addLiveTurn(
            NexusMockMessage(outcome.message, system: true, ok: outcome.ok),
          );
        }
        for (final String name in intercept.refused) {
          _addLiveTurn(
            NexusMockMessage(
              nexusUnknownActionLine(name),
              system: true,
              ok: false,
            ),
          );
        }
      });
      _syncLive();
      _speakThenListen(line);
      return;
    }
    // The same reading happens here as in the thread: the large type is a
    // reply, so a JSON answer becomes words before it is shown or said. A
    // failure is not a reply and is left exactly as the shell wrote it.
    final String answer = !spoken
        ? buffer.toString()
        : (intercept.text.trim().isEmpty ? kNexusNoAnswerText : intercept.text);
    setState(() {
      _liveThinking = false;
      _liveAnswering = false;
      _liveIdle = _LivePhase.waiting;
      _liveSaid = answer;
      _liveAnswerText = '';
      // The answer joins the conversation, so the next question can be asked
      // about it — and so the chat thread has the whole exchange to inherit.
      // A failure joins it too, marked as one: it is a line the user has to be
      // able to read back in the thread, it is just not something the model
      // said (see [_liveHistory]).
      _addLiveTurn(NexusMockMessage(answer, failed: !spoken));
    });
    _syncLive();
    // The answer is said once it is whole, and the page is already in the grey
    // "tap to continue" state by the time the voice starts: what the user sees
    // is the reply they can read, and what they hear is the same reply —
    // neither of which is a microphone that could still be open. The microphone
    // comes back 1.5 s after the voice stops, which is what makes this a
    // conversation rather than a page that needs a tap after every answer.
    if (spoken && _maySpeak) {
      _speakThenListen(answer);
    }
  }

  /// Screen share, from live mode only.
  ///
  /// The microphone closes before the projection dialog opens — a screen
  /// capture is a deliberate moment, and a live microphone underneath it would
  /// be recording the room while the user is deciding what to share. The frame
  /// joins the live conversation as the user's turn, and the vision layer
  /// answers it through the same page and voice as any other answer.
  Future<void> _liveShareScreen() async {
    if (!_liveOpen || !mounted || _liveThinking || _liveAnswering) return;
    if (_listening) _stopListening();
    _liveQuiet?.cancel();
    _liveQuiet = null;
    final int turn = _liveTurns;
    // The projection dialog is a system window over this app; without this the
    // lifecycle handler would read it as the user leaving and close the page
    // while the capture was still being decided.
    _liveCapturePending = true;
    String? path;
    try {
      path = await _captureScreen();
    } finally {
      // The projection dialog is over whichever way it went — shared, refused,
      // or cancelled with the back gesture. Leaving this flag set would make
      // every later lifecycle event look like a capture still in flight.
      _liveCapturePending = false;
    }
    if (path == null) {
      // A refusal leaves the room where it was, listening again. This is the
      // path that used to drop the user out of live mode: the page stayed up
      // but the microphone never came back, so the only control that worked was
      // closing it. The turn is reopened here, and if the app is still coming
      // back to the foreground the resume handler opens it instead.
      if (!mounted || !_liveOpen || turn != _liveTurns) return;
      setState(() {
        _liveIdle = _LivePhase.waiting;
        _liveThinking = false;
        _liveAnswering = false;
      });
      _syncLive();
      if (_inForeground) unawaited(_liveTurn());
      return;
    }
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    setState(() {
      _liveIdle = _LivePhase.waiting;
      _liveThinking = true;
      _liveAnswering = false;
      _liveSaid = kScreenshotCaption;
      _liveAnswerText = '';
      _livePartial = '';
      _addLiveTurn(
        NexusMockMessage(kScreenshotCaption, mine: true, imagePath: path),
      );
    });
    _syncLive();
    final String answer = await VisionAiService.current.describe(
      path,
      question: kScreenshotPrompt,
    );
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    _answerLiveLocally(answer, turn);
  }

  /// A photo from the gallery, described in the live room.
  ///
  /// It is the same shape as screen share: the microphone closes while the
  /// picker is over the app, the frame becomes the user's turn, and the answer
  /// arrives through the same page and voice as any other. Cancelling the
  /// picker is explicitly *not* an exit — the room is reopened, exactly as a
  /// cancelled projection dialog is.
  Future<void> _livePickPhoto() async {
    if (!_liveOpen || !mounted || _liveThinking || _liveAnswering) return;
    if (_listening) _stopListening();
    _liveQuiet?.cancel();
    _liveQuiet = null;
    final int turn = _liveTurns;
    // The gallery is another activity; the lifecycle must not read it as the
    // user leaving the room.
    _liveCapturePending = true;
    PickedAttachment? picked;
    try {
      picked = await AttachmentPickers.current.pickImage();
    } finally {
      _liveCapturePending = false;
    }
    if (picked == null) {
      if (mounted && _liveOpen && turn == _liveTurns && _inForeground) {
        unawaited(_liveTurn());
      }
      return;
    }
    final String? kept = await AttachmentStore.instance.keep(
      picked.path,
      kind: AttachmentKind.gallery,
    );
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    if (kept == null) {
      _say('That photo could not be read.');
      unawaited(_liveTurn());
      return;
    }
    setState(() {
      _liveIdle = _LivePhase.waiting;
      _liveThinking = true;
      _liveAnswering = false;
      _liveSaid = kLivePhotoCaption;
      _liveAnswerText = '';
      _livePartial = '';
      _addLiveTurn(
        NexusMockMessage(kLivePhotoCaption, mine: true, imagePath: kept),
      );
    });
    _syncLive();
    final String answer = await VisionAiService.current.describe(
      kept,
      question: kLivePhotoPrompt,
    );
    if (!mounted || !_liveOpen || turn != _liveTurns) return;
    _answerLiveLocally(answer, turn);
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
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondary,
          ) => _LivePage(
            state: _live,
            onClose: _closeLive,
            onResume: _liveResume,
            onStopSpeaking: _stopSpeaking,
            onShareScreen: _liveShareScreen,
            onPickPhoto: _livePickPhoto,
            onToggleMic: _liveToggleMic,
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
    _liveActionPending = false;
    _liveCapturePending = false;
    _liveActionGuard?.cancel();
    _liveActionGuard = null;
    // Only a live session is this method's to end. A dictation session that a
    // race left open belongs to the button that opened it.
    if (_micMode == _MicMode.live) _stopListening(reason: reason);
    // The page is going away and so is the voice: leaving it talking to an
    // empty room is the same bug as leaving a microphone open. No auto-listen
    // is scheduled from here — the session is over.
    _speechDone?.cancel();
    _speechDone = null;
    _autoListen?.cancel();
    _autoListen = null;
    _cancelBargeIn();
    if (_speaking) {
      _speaking = false;
      unawaited(SpeechOutput.current.stop());
    }
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
        _speaking = false;
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
      speaking: _speaking,
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

    // Back closes the open drawer instead of leaving the app.
    //
    // Material's Scaffold pushes a local history entry while its drawer is open,
    // and on this device that entry did not intercept the system back: the
    // drawer closed and the task went with it, which is the worst of both — the
    // user lost their place *and* the panel they were reading. So the shell says
    // it itself: while the drawer is open the route refuses to pop, and the
    // refused pop is spent on closing the drawer.
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _homeScaffold.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: _homeScaffold,
        backgroundColor: Colors.transparent,
        onDrawerChanged: (bool open) {
          if (open == _drawerOpen) return;
          setState(() => _drawerOpen = open);
        },
        // A wider edge than Material's default (20 plus the system inset): on a
        // phone in a case the first few millimetres belong to the bezel, and a
        // drawer nobody can swipe open is a drawer that only the menu button
        // reaches. 64 is past the visual edge without turning the left sixth of
        // the thread into a gesture nobody can scroll from.
        drawerEdgeDragWidth: widget.wide ? 0 : 64,
        drawer: widget.wide
            ? null
            : _ChatDrawer(
                chat: ChatLog.instance,
                onNewChat: _newChat,
                onSelect: _selectChat,
              ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              _HomeHeader(
                onMenu: widget.wide
                    ? null
                    : () => _homeScaffold.currentState?.openDrawer(),
              ),
              if (!_pcBannerDismissed && _pcPeer != null)
                _PcUpgradeBanner(
                  peer: _pcPeer!,
                  onDismiss: () => setState(() => _pcBannerDismissed = true),
                ),
              if (_startupUpdate != null && !_updateBannerDismissed)
                _UpdateBanner(
                  info: _startupUpdate!,
                  onInstall: () => unawaited(
                    showNexusUpdateDialog(context, _startupUpdate!),
                  ),
                  onDismiss: () =>
                      setState(() => _updateBannerDismissed = true),
                ),
              Expanded(
                // Centred while the thread is short, scrollable once it is not,
                // and never clipped when the keyboard takes the bottom half.
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: NexusLayout.content,
                    ),
                    // One [SelectionArea] per bubble, not one around the thread.
                    // A thread-wide region let "Select all" sweep every message on
                    // the screen into one clipboard, so copying a reply also copied
                    // the question above it. Each message is its own page now: the
                    // long press still selects, and it stops at the end of the
                    // bubble it started in.
                    child: SingleChildScrollView(
                      controller: _threadScroll,
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (_thread.isEmpty)
                            _Welcome(
                              onSuggestion: _useSuggestion,
                              suggestions: _suggestions,
                            )
                          else
                            const SizedBox(height: 30),
                          for (final (int i, NexusMockMessage message)
                              in _thread.indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: SelectionArea(
                                // The index is this line's own name in the thread:
                                // feedback and regeneration act on the bubble the
                                // thumb is under, not on whichever answer is newest.
                                key: ValueKey<String>('thread-$i'),
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
                                    // A captured photo or screenshot: the same
                                    // bubble, with a thumbnail above the caption.
                                    // The attachment shares the message's own
                                    // caption, so nothing about this line is a new
                                    // kind of entry in the thread.
                                    : message.imagePath != null
                                    ? NexusAttachmentBubble(
                                        path: message.allImagePaths.first,
                                        paths: message.allImagePaths,
                                        caption: message.text,
                                        mine: message.mine,
                                        detectedText: message.visionText,
                                        objects: message.visionLabels,
                                        maxWidth: bubbleWidth,
                                      )
                                    // A picked document: a chip with its name, not a
                                    // thumbnail. Tapping it opens the file with the
                                    // platform's own viewer.
                                    : message.filePath != null
                                    ? NexusFileBubble(
                                        path: message.filePath!,
                                        caption: message.text,
                                        mine: message.mine,
                                        maxWidth: bubbleWidth,
                                      )
                                    : message.mine
                                    ? NexusChatBubble(
                                        text: message.text,
                                        mine: true,
                                        thinking: message.thinking,
                                        reasoning: message.reasoning,
                                        maxWidth: bubbleWidth,
                                        onLongPress: () => unawaited(
                                          _showUserMessageActions(message),
                                        ),
                                      )
                                    // An answer may have written files. The
                                    // split and the cards live in the widget,
                                    // so a streamed, restored or regenerated
                                    // answer all read the same block.
                                    : _ThreadAnswer(
                                        message: message,
                                        bubbleWidth: bubbleWidth,
                                        liked: _liked.contains(i),
                                        disliked: _disliked.contains(i),
                                        onLike: () => _react(i, true),
                                        onDislike: () => _react(i, false),
                                        onRegenerate: () => _regenerate(i),
                                      ),
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
                showVoice: _voiceAvailable,
                micNotice: _micMode == _MicMode.oneShot
                    ? 'Slide left to cancel — release to keep'
                    : _micNotice,
                level: _micLevel,
                onCancel: _cancelDictation,
                onMicTap: _micTap,
                onHoldStart: () => unawaited(_micHoldStart()),
                onHoldEnd: _micHoldEnd,
                onLiveTap: () => unawaited(_openLive()),
                liveEnabled: _micUsable && !_listening,
                liveTooltip: _liveTooltip,
                onAdd: () => unawaited(_openAttachmentSheet()),
                pending: _pendingAttachments,
                onRemovePending: _removePendingAttachment,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Starts a fresh conversation from the drawer. The log notifies, the id
  /// changes, and the listener empties the bubbles — one owner of what is on
  /// screen rather than a second clear here that could race it.
  void _newChat() {
    Navigator.of(context).pop();
    ChatLog.instance.newChat();
  }

  /// Records a thumb on the answer at [index]. A thumb is a choice, not two
  /// independent switches: tapping the other one moves the reaction rather
  /// than leaving both filled.
  void _react(int index, bool liked) {
    if (index < 0 || index >= _thread.length || _thread[index].mine) return;
    setState(() {
      if (liked) {
        if (!_liked.remove(index)) {
          _liked.add(index);
          _disliked.remove(index);
        }
      } else if (!_disliked.remove(index)) {
        _disliked.add(index);
        _liked.remove(index);
      }
    });
  }

  /// Re-runs the prompt that produced the answer at [index], in the same
  /// bubble.
  ///
  /// The question is the nearest user line above the answer — not the last
  /// thing in the thread, which may already be a newer question. The answer is
  /// replaced by the thinking placeholder, and the history handed to the brain
  /// stops before that placeholder, so the model rewrites the answer instead of
  /// reading its old one back to itself.
  void _regenerate(int index) {
    if (index <= 0 || index >= _thread.length) return;
    final NexusMockMessage answer = _thread[index];
    if (answer.mine || answer.thinking || answer.failed || answer.system) {
      return;
    }
    String? prompt;
    for (int i = index - 1; i >= 0; i--) {
      if (_thread[i].mine) {
        prompt = _thread[i].text;
        break;
      }
    }
    if (prompt == null) return;
    setState(() {
      _thread[index] = const NexusMockMessage(kNexusThinking, thinking: true);
      _liked.remove(index);
      _disliked.remove(index);
    });
    _persistThread();
    _scrollToLatestSoon();
    unawaited(_answer(prompt, index, spoken: false));
  }

  /// The hold on one of the user's own messages: copy it, read it in a
  /// selectable page, or put it back in the composer to say differently.
  Future<void> _showUserMessageActions(NexusMockMessage message) async {
    final c = context.ui;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('message-action-copy'),
              leading: Icon(Icons.copy_rounded, color: c.textMuted),
              title: const Text('Copy'),
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
            ListTile(
              key: const ValueKey<String>('message-action-select'),
              leading: Icon(Icons.text_fields_rounded, color: c.textMuted),
              title: const Text('Select Text'),
              onTap: () => Navigator.of(sheetContext).pop('select'),
            ),
            ListTile(
              key: const ValueKey<String>('message-action-edit'),
              leading: Icon(Icons.edit_outlined, color: c.textMuted),
              title: const Text('Edit'),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await nexusCopyMessage(context, message.text);
        break;
      case 'select':
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: c.surface,
            title: Text('Select text', style: NexusType.rowTitle(c)),
            content: SingleChildScrollView(
              child: SelectableText(message.text, style: NexusType.bubble(c)),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        );
        break;
      case 'edit':
        setState(() {
          _message.text = message.text;
          _message.selection = TextSelection.collapsed(
            offset: _message.text.length,
          );
        });
        _focus.requestFocus();
        break;
    }
  }

  /// Opens an older conversation from the drawer.
  void _selectChat(String id) {
    Navigator.of(context).pop();
    ChatLog.instance.selectSession(id);
  }

  /// Throws away the attachment chosen but not sent. The copy in the app's
  /// attachment folder goes too: the user said no to this picture, and leaving
  /// it behind would be a silent cache of something they discarded.
  void _removePendingAttachment(_PendingAttachment pending) {
    if (!_pendingAttachments.remove(pending)) return;
    setState(() {});
    unawaited(_deleteDiscarded(pending.picked.path));
  }

  Future<void> _deleteDiscarded(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('ATTACH: could not remove the discarded file ($error)');
    }
  }
}

/// The menu button that opens the conversation drawer, and the drawer's own
/// two actions. Keyed because a drawer that cannot be reached is the same as a
/// second conversation that cannot be opened.
const Key kNexusChatMenu = Key('nexus-chat-menu');

/// The composer's own field. Named because Settings now has a text field too,
/// and "the TextField on screen" is no longer a synonym for "the chat draft".
const Key kNexusComposerField = Key('nexus-composer-field');
const Key kNexusNewChat = Key('nexus-new-chat');

/// The conversations drawer: New chat, then every past chat grouped by the day
/// it was last spoken in.
///
/// The drawer is a list of *titles*, not previews: a second line under every
/// row would be a second conversation to read while looking for the first, and
/// the title is the first thing the user said. Selecting a row makes it the
/// active session; the Home tab listens to the log and swaps the thread.
class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer({
    required this.chat,
    required this.onNewChat,
    required this.onSelect,
  });

  final ChatLog chat;
  final VoidCallback onNewChat;
  final ValueChanged<String> onSelect;

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  /// The conversations ticked in selection mode. Empty means the drawer is in
  /// its ordinary state; a long press puts the first id in here.
  final Set<String> _selected = <String>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _startSelecting(String id) {
    setState(() => _selected.add(id));
  }

  /// The hold menu. Multi-select lives *behind* this rather than starting on
  /// the hold itself: a user who just wants to rename a chat should not be
  /// dropped into a screen full of checkboxes first.
  ///
  /// A small popover anchored to the row the finger was on, not a sheet from
  /// the bottom of the screen. Four short actions belong beside the chat they
  /// act on; a sheet made the user travel the whole screen to reach them and
  /// covered the list they were choosing from.
  Future<void> _openMenu(
    ChatSession session,
    BuildContext anchorContext,
  ) async {
    final c = context.ui;
    final RenderBox? row = anchorContext.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final RelativeRect position = row == null || overlay == null
        ? const RelativeRect.fromLTRB(32, 120, 32, 32)
        : RelativeRect.fromRect(
            Rect.fromPoints(
              row.localToGlobal(Offset.zero, ancestor: overlay),
              row.localToGlobal(
                row.size.bottomRight(Offset.zero),
                ancestor: overlay,
              ),
            ),
            Offset.zero & overlay.size,
          );
    final String? action = await showMenu<String>(
      context: context,
      position: position,
      color: c.surface,
      elevation: 6,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(NexusLayout.tile),
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const ValueKey<String>('chat-menu-rename'),
          value: 'rename',
          child: _ChatMenuLine(
            icon: Icons.edit_outlined,
            label: 'Rename',
            color: c.textStrong,
          ),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('chat-menu-pin'),
          value: 'pin',
          child: _ChatMenuLine(
            icon: session.pinned
                ? Icons.push_pin_rounded
                : Icons.push_pin_outlined,
            label: session.pinned ? 'Unpin' : 'Pin',
            color: c.textStrong,
          ),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('chat-menu-multiselect'),
          value: 'multiselect',
          child: _ChatMenuLine(
            icon: Icons.checklist_rounded,
            label: 'Multi-select',
            color: c.textStrong,
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          key: const ValueKey<String>('chat-menu-delete'),
          value: 'delete',
          child: _ChatMenuLine(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            color: c.danger,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _rename(session);
        break;
      case 'pin':
        widget.chat.togglePinned(session.id);
        break;
      case 'multiselect':
        _startSelecting(session.id);
        break;
      case 'delete':
        final bool confirmed = await showNexusConfirm(
          context,
          title: 'Delete chat?',
          message:
              'This deletes “${session.title}” on this device. Nothing was '
              'uploaded, and nothing can be recovered.',
          confirmLabel: 'Delete',
        );
        if (confirmed && mounted) {
          widget.chat.deleteSessions(<String>[session.id]);
        }
        break;
    }
  }

  Future<void> _rename(ChatSession session) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameChatDialog(initial: session.title),
    );
    if (name != null && name.trim().isNotEmpty) {
      widget.chat.renameSession(session.id, name);
    }
  }

  void _toggleGroup(List<ChatSession> group) {
    final bool all = group.every(
      (ChatSession session) => _selected.contains(session.id),
    );
    setState(() {
      for (final ChatSession session in group) {
        if (all) {
          _selected.remove(session.id);
        } else {
          _selected.add(session.id);
        }
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final int count = _selected.length;
    final bool confirmed = await showNexusConfirm(
      context,
      title: 'Delete ${count == 1 ? 'chat' : 'chats'}?',
      message:
          'This deletes ${count == 1 ? '1 conversation' : '$count conversations'} '
          'on this device. Nothing was uploaded, and nothing can be recovered.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    widget.chat.deleteSessions(_selected);
    setState(_selected.clear);
  }

  Future<void> _deleteAll() async {
    final List<ChatSession> sessions = widget.chat.sessions
        .where((ChatSession session) => session.entries.isNotEmpty)
        .toList();
    if (sessions.isEmpty) return;
    final bool confirmed = await showNexusConfirm(
      context,
      title: 'Delete all chats?',
      message:
          'This deletes every conversation on this device. Nothing was '
          'uploaded, and nothing can be recovered.',
      confirmLabel: 'Delete all',
    );
    if (!confirmed || !mounted) return;
    widget.chat.deleteSessions(
      sessions.map((ChatSession session) => session.id),
    );
    setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final ChatLog chat = widget.chat;
    return Drawer(
      backgroundColor: c.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: _selecting
                  ? Row(
                      children: <Widget>[
                        // Smaller than the page title: three controls share this
                        // bar, and a 34-point count pushed Delete All off the
                        // 360-point drawer. Expanded keeps a long count from
                        // overflowing rather than painting the debug stripes.
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${_selected.length} selected',
                              maxLines: 1,
                              style: NexusType.pageTitle(c)
                                  .copyWith(fontSize: 22),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey<String>('delete-selected-chats'),
                          tooltip: 'Delete selected',
                          visualDensity: VisualDensity.compact,
                          onPressed: _deleteSelected,
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            color: c.danger,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey<String>('delete-all-chats'),
                          onPressed: _deleteAll,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 40),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'Delete All',
                            style: TextStyle(color: c.danger, fontSize: 14),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancel selection',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(_selected.clear),
                          icon: Icon(Icons.close_rounded, color: c.textMuted),
                        ),
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Text('Chats', style: NexusType.pageTitle(c)),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Close chats',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.close_rounded, color: c.textMuted),
                        ),
                      ],
                    ),
            ),
            if (!_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: FilledButton.icon(
                  key: kNexusNewChat,
                  onPressed: widget.onNewChat,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    // The accent may be white (or any pale custom colour): white
                    // type on it is an invisible button. The palette's onAccent
                    // is the contrast pair the rest of the app already uses.
                    foregroundColor: c.onAccent,
                    minimumSize: const Size.fromHeight(48),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(NexusLayout.tile),
                    ),
                  ),
                  icon: const Icon(Icons.add_comment_outlined, size: 19),
                  label: const Text('New Chat'),
                ),
              ),
            Expanded(
              child: ListenableBuilder(
                listenable: chat,
                builder: (BuildContext context, _) {
                  final DateTime now = DateTime.now();
                  final List<ChatSession> sessions = chat.sessions.toList()
                    ..sort(
                      (ChatSession a, ChatSession b) =>
                          b.updatedAt.compareTo(a.updatedAt),
                    );
                  final List<ChatSession> visible = <ChatSession>[
                    for (final ChatSession session in sessions)
                      if (!(session.isEmpty &&
                          session.id != chat.activeSessionId))
                        session,
                  ];
                  // Pinned chats are lifted to the very top of the list, above
                  // the date groups, so a month-old favourite cannot be buried
                  // under today's drafts. They are not a "Pinned" category: the
                  // heading was a second piece of vocabulary between the user and
                  // their chats, and the pin glyph on the row already says why a
                  // chat is up there.
                  final List<ChatSession> pinned = <ChatSession>[
                    for (final ChatSession session in visible)
                      if (session.pinned) session,
                  ];
                  final Map<String, List<ChatSession>> grouped =
                      <String, List<ChatSession>>{};
                  for (final ChatSession session in visible) {
                    if (session.pinned) continue;
                    grouped
                        .putIfAbsent(
                          chatDateGroup(session.updatedAt, now),
                          () => <ChatSession>[],
                        )
                        .add(session);
                  }
                  if (pinned.isEmpty && grouped.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Text(
                        'No conversations yet.',
                        style: NexusType.rowMeta(c),
                      ),
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: <Widget>[
                      for (final ChatSession session in pinned)
                        _ChatDrawerRow(
                          session: session,
                          selected: session.id == chat.activeSessionId,
                          selecting: _selecting,
                          ticked: _selected.contains(session.id),
                          onTap: () {
                            if (_selecting) {
                              _toggle(session.id);
                            } else {
                              widget.onSelect(session.id);
                            }
                          },
                          onLongPress: (BuildContext rowContext) {
                            if (_selecting) {
                              _toggle(session.id);
                            } else {
                              unawaited(_openMenu(session, rowContext));
                            }
                          },
                        ),
                      for (final MapEntry<String, List<ChatSession>> group
                          in grouped.entries) ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  group.key.toUpperCase(),
                                  style: NexusType.rowMeta(c).copyWith(
                                    fontSize: 10.5,
                                    letterSpacing: 0.8,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (_selecting)
                                SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Checkbox(
                                    key: ValueKey<String>(
                                      'select-group-${group.key}',
                                    ),
                                    value: group.value.every(
                                      (ChatSession session) =>
                                          _selected.contains(session.id),
                                    ),
                                    onChanged: (_) => _toggleGroup(group.value),
                                    visualDensity: VisualDensity.compact,
                                    side: BorderSide(color: c.hairline),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        for (final ChatSession session in group.value)
                          _ChatDrawerRow(
                            session: session,
                            selected: session.id == chat.activeSessionId,
                            selecting: _selecting,
                            ticked: _selected.contains(session.id),
                            onTap: () {
                              if (_selecting) {
                                _toggle(session.id);
                              } else {
                                widget.onSelect(session.id);
                              }
                            },
                            onLongPress: (BuildContext rowContext) {
                              if (_selecting) {
                                _toggle(session.id);
                              } else {
                                unawaited(_openMenu(session, rowContext));
                              }
                            },
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Text(
                _selecting
                    ? 'Tap more chats to add them. Use the checkbox on a date '
                          'to pick the whole group.'
                    : 'Chats stay on this device. Long-press one to rename, '
                          'pin, multi-select, or delete.',
                style: NexusType.rowMeta(c).copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rename dialog owns its controller for as long as its route does. A
/// controller disposed the moment `showDialog` returns is still inside the
/// route's reverse transition, and the TextField that uses it rebuilds once
/// more on the way out — which is exactly the dispose-after-use crash this
/// separate State prevents.
class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({required this.initial});

  final String initial;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text('Rename chat', style: NexusType.rowTitle(c)),
      content: TextField(
        key: const ValueKey<String>('rename-chat-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        textInputAction: TextInputAction.done,
        onSubmitted: (String value) => Navigator.of(context).pop(value),
        decoration: const InputDecoration(hintText: 'Chat name'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('rename-chat-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ChatDrawerRow extends StatelessWidget {
  const _ChatDrawerRow({
    required this.session,
    required this.selected,
    required this.selecting,
    required this.ticked,
    required this.onTap,
    required this.onLongPress,
  });

  final ChatSession session;
  final bool selected;
  final bool selecting;
  final bool ticked;
  final VoidCallback onTap;

  /// The row's own context, so a hold can put its popover beside the row rather
  /// than at the bottom of the screen.
  final ValueChanged<BuildContext> onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: ticked
            ? c.accent.withValues(alpha: 0.14)
            : (selected
                  ? c.accent.withValues(alpha: 0.14)
                  : Colors.transparent),
        borderRadius: const BorderRadius.all(NexusLayout.tile),
        child: Builder(
          builder: (BuildContext rowContext) => InkWell(
            key: ValueKey<String>('chat-session-${session.id}'),
            borderRadius: const BorderRadius.all(NexusLayout.tile),
            onTap: onTap,
            onLongPress: () => onLongPress(rowContext),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: <Widget>[
                  Icon(
                    selecting
                        ? (ticked
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined)
                        : Icons.chat_bubble_outline_rounded,
                    size: selecting ? 19 : 17,
                    color: ticked || (!selecting && selected)
                        ? c.accent
                        : c.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexusType.rowTitle(c).copyWith(
                        fontSize: 14,
                        color: ticked || (!selecting && selected)
                            ? c.accent
                            : c.textStrong,
                        fontWeight: ticked || (!selecting && selected)
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  // The only mark a pinned chat gets. A row at the top of the
                  // list is already in the pinned position; the glyph is what
                  // explains the exception to the date order without a heading
                  // above the block.
                  if (session.pinned) ...<Widget>[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.push_pin_rounded,
                      key: ValueKey<String>('chat-pin-${session.id}'),
                      size: 13,
                      color: c.textMuted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line in the conversation's anchored popover: a glyph, a word, and the
/// colour that word is owed (the danger red only for Delete).
class _ChatMenuLine extends StatelessWidget {
  const _ChatMenuLine({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// The quiet update notice above the thread: one line, one install action, and
/// an X that makes it go away without another check.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.info,
    required this.onInstall,
    required this.onDismiss,
  });

  final UpdateInfo info;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: NexusLayout.content),
          child: Material(
            key: const ValueKey<String>('update-banner'),
            color: c.accent.withValues(alpha: 0.11),
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(NexusLayout.tile),
              side: BorderSide(color: c.accent.withValues(alpha: 0.3)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onInstall,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 2, 8),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.system_update_alt_rounded,
                      size: 20,
                      color: c.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            'Nexus v${info.version} is available',
                            style: NexusType.rowTitle(c)
                                .copyWith(fontSize: 13.5),
                          ),
                          Text(
                            'Tap to install the newer build',
                            style: NexusType.rowMeta(c)
                                .copyWith(fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: const ValueKey<String>('update-banner-install'),
                      onPressed: onInstall,
                      style: TextButton.styleFrom(
                        foregroundColor: c.accent,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Install'),
                    ),
                    IconButton(
                      key: const ValueKey<String>('update-banner-dismiss'),
                      tooltip: 'Dismiss',
                      onPressed: onDismiss,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: c.textMuted,
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

/// The one piece of advice the mesh earns: the PC in the room is big enough to
/// run a better model than the phone.
///
/// Shown only when a paired PC is online and has said it has more than
/// [kComfortablePcRamBytes]. The sentence is fixed, and the copy button copies
/// the exact command — a user who has to retype `ollama run llama3.2:3b` from a
/// screenshot will get `ollama run llama3.2` and wonder why nothing changed.
class _PcUpgradeBanner extends StatelessWidget {
  const _PcUpgradeBanner({required this.peer, required this.onDismiss});

  final PairedDevice peer;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: NexusLayout.content),
          child: Material(
            key: kNexusPcUpgradeBanner,
            color: c.accent.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(NexusLayout.tile),
              side: BorderSide(color: c.accent.withValues(alpha: 0.25)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 2, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.laptop_mac_rounded, size: 20, color: c.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          kNexusPcUpgradeText,
                          style: NexusType.rowTitle(c)
                              .copyWith(fontSize: 13, height: 1.35),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: c.raised,
                                  borderRadius: const BorderRadius.all(
                                    Radius.circular(7),
                                  ),
                                ),
                                child: Text(
                                  kNexusPcUpgradeCommand,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: NexusType.rowMeta(c).copyWith(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: c.textStrong,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              key: kNexusPcUpgradeCopy,
                              tooltip: 'Copy command',
                              visualDensity: VisualDensity.compact,
                              onPressed: () async {
                                await Clipboard.setData(
                                  const ClipboardData(
                                    text: kNexusPcUpgradeCommand,
                                  ),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Copied “$kNexusPcUpgradeCommand”.',
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                              },
                              icon: Icon(
                                Icons.copy_rounded,
                                size: 16,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('pc-upgrade-dismiss'),
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The slim header: wordmark on the left, the conversation's two switches on
/// the right.
///
/// Speak replies moved up here from the composer. It is still a switch about
/// the conversation, but it is a *mode* rather than a step in sending a message:
/// beside the `+` it shared a row with the controls that put something in the
/// field, and the one control that changes what happens to every answer looked
/// like another way to attach a file. The top-right corner is where a phone puts
/// a mode, and the speaker glyph says which mode without a label.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onMenu});

  /// Opens the conversation drawer. Null in the wide layout, where the history
  /// is a permanent column and there is no drawer to open.
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Row(
        children: <Widget>[
          if (onMenu != null)
            IconButton(
              key: kNexusChatMenu,
              onPressed: onMenu,
              tooltip: 'Chats',
              icon: Icon(Icons.menu_rounded, color: c.textMuted),
            )
          else
            const SizedBox(width: 8),
          Text('Nexus', style: NexusType.wordmark(c)),
          // The chip is right-aligned and shrinks before anything else does:
          // at 366 points of usable width — a 390-point phone — the wordmark,
          // the chip and the speaker together were 18 points too wide. The
          // promise still gets its line; the speaker and the menu never move.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: c.raised,
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.lock_outline, size: 13, color: c.textMuted),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'On this device',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NexusType.rowMeta(c),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          const _SpeakRepliesButton(),
        ],
      ),
    );
  }
}

/// The sentences the empty screen can offer. All five are commands the app
/// actually handles: a fast-path action, a timer, arithmetic, the music player,
/// and a question the local model answers about itself.
///
/// The screen draws three, chosen at random, rather than the same three every
/// launch — a first screen that never changes stops being a suggestion and
/// becomes furniture. Tapping one fills the field; it never sends.
const List<(String, String)> kNexusSuggestionPool = <(String, String)>[
  ('Turn on the flashlight', 'Turn on the flashlight'),
  ('Set a timer for 5 minutes', 'Set a timer for 5 minutes'),
  ('What is 144 divided by 12?', 'What is 144 divided by 12?'),
  ('Play some music', 'Play some music'),
  ('Who are you?', 'Who are you?'),
];

/// The old name, kept so a caller written before the pool existed still
/// compiles. New code should use [kNexusSuggestionPool] and the picker below.
const List<(String, String)> kNexusHomeSuggestions = kNexusSuggestionPool;

/// Three suggestions, in random order. A test can pass a seeded [math.Random]
/// to pin which ones; the app passes none and gets a fresh set each launch.
List<(String, String)> pickHomeSuggestions({math.Random? random}) {
  final List<(String, String)> shuffled = List<(String, String)>.of(
    kNexusSuggestionPool,
  )..shuffle(random ?? math.Random(DateTime.now().microsecondsSinceEpoch));
  return shuffled.take(3).toList();
}

/// The screen an empty thread shows: a heading, the one promise that is true
/// before anything has been said, and the three suggestions above.
///
/// Deliberately not a message. The two bubbles that used to sit here were drawn
/// by the same code path as a real answer, which made them indistinguishable
/// from one — and the first thing a user learned about the app was a sentence
/// the app had put in the assistant's mouth.
class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.onSuggestion,
    this.suggestions = kNexusSuggestionPool,
  });

  /// Called with the sentence a chip stands for: the screen puts it in the
  /// draft, and the user decides whether to send it.
  final ValueChanged<String> onSuggestion;

  /// The three (or, in a test that passes the pool, five) sentences to show.
  final List<(String, String)> suggestions;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool french = nexusIsFrench(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          french
              ? 'Bonjour, comment puis-je aider ?'
              : 'Hey, what do you need?',
          textAlign: TextAlign.center,
          style: NexusType.greeting(c),
        ),
        const SizedBox(height: 8),
        Text(
          french
              ? 'Demandez-moi n’importe quoi. Vos appareils répondent '
                    'directement — sans compte, sans cloud.'
              : 'Ask me anything. Your devices answer directly — no account, '
                    'no cloud.',
          textAlign: TextAlign.center,
          style: NexusType.lede(c),
        ),
        const SizedBox(height: 22),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final (String label, String prompt) in suggestions)
              ActionChip(
                key: ValueKey<String>('nexus-suggestion-$label'),
                avatar: Icon(
                  switch (label) {
                    'Turn on the flashlight' => Icons.flashlight_on_outlined,
                    'Set a timer for 5 minutes' => Icons.timer_outlined,
                    'What is 144 divided by 12?' => Icons.calculate_outlined,
                    'Play some music' => Icons.music_note_rounded,
                    _ => Icons.help_outline_rounded,
                  },
                  size: 15,
                  color: c.accent,
                ),
                label: Text(label),
                labelStyle: NexusType.rowMeta(c)
                    .copyWith(color: c.textStrong, fontSize: 12.5),
                backgroundColor: c.surface,
                side: BorderSide(color: c.hairline),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                onPressed: () => onSuggestion(prompt),
              ),
          ],
        ),
      ],
    );
  }
}

/// True when the phone is asking for French.
///
/// Used for the handful of strings that have a French answer already, rather
/// than for every label in the shell: a half-translated Settings screen is
/// worse than an English one, and this is preparation rather than a claim that
/// the app is localised.
bool nexusIsFrench(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'fr';

/// A BCP-47 tag from [VoiceSettings] as the [Locale] the app runs in.
///
/// `en-US` becomes `Locale('en', 'US')` rather than a locale whose language
/// code is literally `en-US`: Flutter matches a locale by language first, so
/// an unparsed tag would match nothing and every string would fall back.
Locale nexusLocaleFor(String tag) {
  final List<String> parts = tag
      .trim()
      .replaceAll('_', '-')
      .split('-')
      .where((String part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return const Locale('en');
  return Locale.fromSubtags(
    languageCode: parts.first.toLowerCase(),
    countryCode: parts.length > 1 ? parts[1].toUpperCase() : null,
  );
}

/// Every language the voice dropdown offers, as locales the app can be in.
///
/// Derived from [kVoiceLanguages] rather than written twice: a language a user
/// can speak but the app does not list as supported would fall back to English
/// the moment it was chosen.
final List<Locale> nexusSupportedLocales = <String>[
  'en-US',
  for (final VoiceLanguage language in kVoiceLanguages)
    if (language.tag != 'en-US') language.tag,
].map(nexusLocaleFor).toList(growable: false);

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
    this.liked = false,
    this.disliked = false,
    this.onLongPress,
    this.onLike,
    this.onDislike,
    this.onRegenerate,
    this.reasoning,
    this.speaking = false,
  });

  final String text;
  final bool mine;

  /// True while this answer is the one being read out loud. Draws a pulsing
  /// speaker beside the bubble, so the phone talking is visible on the message
  /// it is talking about rather than only audible.
  final bool speaking;

  /// True while this bubble is a placeholder for an answer that has not arrived:
  /// muted ink, italic, and no controls: "Nexus is thinking…" is not a sentence
  /// anybody wants on their clipboard or in their ear.
  final bool thinking;

  /// Cap on the bubble, so long messages never reach the screen edge.
  final double maxWidth;

  /// The answer's feedback, held by the thread so the filled thumb survives the
  /// rebuild that follows the tap.
  final bool liked;
  final bool disliked;

  /// A hold on the user's own message opens the copy / select / edit sheet.
  /// Null on Nexus's side, where the actions are always visible underneath.
  final VoidCallback? onLongPress;

  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final VoidCallback? onRegenerate;

  /// The model's `<thought>` text. Shown above the answer in a grey collapsible
  /// bubble; null for a reply that did not reason out loud.
  final String? reasoning;

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
            if (!mine &&
                reasoning != null &&
                reasoning!.trim().isNotEmpty) ...<Widget>[
              _ReasoningBubble(text: reasoning!.trim(), streaming: thinking),
              const SizedBox(height: 6),
            ],
            // No gesture detector around the bubble: a press and a hold both
            // belong to the selection around it. The bubble's own padding is
            // still inside the painted box, and long-pressing it starts a
            // selection wherever the finger landed.
            GestureDetector(
              onLongPress: onLongPress,
              behavior: HitTestBehavior.opaque,
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
                child: thinking && text == kNexusThinking
                    ? const _ThinkingWithTimer()
                    : Text(
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
            if (!mine && !thinking)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (speaking) ...<Widget>[
                    const _TtsPulse(),
                    const SizedBox(width: 2),
                  ],
                  _MessageActions(
                    text: text,
                    liked: liked,
                    disliked: disliked,
                    onLike: onLike,
                    onDislike: onDislike,
                    onRegenerate: onRegenerate,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The speaker that breathes beside the answer being read out loud.
///
/// The header's Speaker toggle says *whether* answers are spoken; this says
/// *which* one is being spoken right now. It is deliberately small and beside
/// the message controls: the user glancing at the thread sees which turn the
/// voice belongs to, without a second banner taking a line of the page.
class _TtsPulse extends StatefulWidget {
  const _TtsPulse();

  @override
  State<_TtsPulse> createState() => _TtsPulseState();
}

class _TtsPulseState extends State<_TtsPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Tooltip(
      message: 'Reading this answer aloud',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final double t = Curves.easeInOut.transform(_controller.value);
          return Opacity(
            opacity: 0.45 + 0.55 * t,
            child: Transform.scale(scale: 0.9 + 0.12 * t, child: child),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Icon(Icons.volume_up_rounded, size: 15, color: c.accent),
        ),
      ),
    );
  }
}

/// One assistant reply, with any artifacts it wrote below it.
///
/// The split happens here rather than at send time because the same message
/// text is the source of truth: a restored thread, a regenerated answer and a
/// live-streamed one all pass through this widget, and all three get the same
/// card for the same block. The bubble shows the prose only; the card is a
/// sibling, not a child, so a long file never makes the paragraph scroll
/// sideways.
class _ThreadAnswer extends StatelessWidget {
  const _ThreadAnswer({
    required this.message,
    required this.bubbleWidth,
    required this.liked,
    required this.disliked,
    required this.onLike,
    required this.onDislike,
    required this.onRegenerate,
  });

  final NexusMockMessage message;
  final double bubbleWidth;
  final bool liked;
  final bool disliked;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final NexusArtifactSplit split = splitNexusArtifacts(
      message.text,
      streaming: message.thinking,
    );
    // A half-written answer keeps its trailing space: that space is the gap
    // between the word that just arrived and the one still coming, and trimming
    // it drew "One,two," until the next token landed.
    final String prose = message.thinking
        ? split.prose.trimLeft()
        : split.prose.trim();
    // While the model is mid-block the prose may be empty and the bubble is
    // still the placeholder the thread drew; that is the one case worth a
    // bubble with nothing in it.
    final bool showBubble = prose.isNotEmpty || split.artifacts.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showBubble)
          ValueListenableBuilder<bool>(
            valueListenable: SpeechOutput.speaking,
            builder: (BuildContext context, bool speaking, Widget? child) =>
                NexusChatBubble(
                  text: prose.isEmpty ? message.text : prose,
                  mine: false,
                  thinking: message.thinking,
                  reasoning: message.reasoning,
                  maxWidth: bubbleWidth,
                  liked: liked,
                  disliked: disliked,
                  onLike: onLike,
                  onDislike: onDislike,
                  onRegenerate: onRegenerate,
                  speaking: speaking,
                ),
          ),
        for (final NexusArtifact artifact in split.artifacts)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: NexusArtifactCard(artifact: artifact),
          ),
      ],
    );
  }
}

/// The file a reply wrote: a coloured code block on the left, a name and a
/// language on the right.
///
/// It sits *below* the message because that is what it is — an attachment the
/// answer produced, not part of the sentence. The coloured block is the only
/// decoration: it is the band every code editor puts beside a file, and it says
/// "this is code" before the eye reaches the filename.
class NexusArtifactCard extends StatelessWidget {
  const NexusArtifactCard({super.key, required this.artifact});

  final NexusArtifact artifact;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(NexusLayout.tile),
          side: BorderSide(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('artifact-${artifact.safeFilename}'),
          onTap: () => NexusArtifactPage.open(context, artifact),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, minHeight: 68),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 58,
                  alignment: Alignment.center,
                  color: c.accent.withValues(alpha: 0.13),
                  child: Icon(Icons.code_rounded, size: 24, color: c.accent),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          artifact.safeFilename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NexusType.rowTitle(c).copyWith(fontSize: 13.5),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          artifact.languageLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 16,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The placeholder's sentence, with a live one-second counter until the first
/// token replaces it.
///
/// The widget is only mounted while the bubble still says [kNexusThinking]; the
/// first streamed word swaps it for the growing answer, which disposes the
/// timer. That is why the count is honest about "waiting" rather than about
/// "generating" — the user watches the wait, not the model's tokens.
class _ThinkingWithTimer extends StatefulWidget {
  const _ThinkingWithTimer();

  @override
  State<_ThinkingWithTimer> createState() => _ThinkingWithTimerState();
}

class _ThinkingWithTimerState extends State<_ThinkingWithTimer> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final TextStyle style = NexusType.bubble(c)
        .copyWith(color: c.textMuted, fontStyle: FontStyle.italic);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(child: Text(kNexusThinking, style: style)),
        if (_seconds > 0) ...<Widget>[
          const SizedBox(width: 5),
          Text(
            '(${_seconds}s)',
            key: const ValueKey<String>('thinking-timer'),
            style: style.copyWith(
              fontSize: 12,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

/// The grey reasoning bubble above an answer.
///
/// Open while the model is thinking, so the user can watch the reasoning text
/// arrive; closed once the answer is whole, so the thread stays a conversation
/// rather than a transcript of every token. Tapping the header toggles it.
class _ReasoningBubble extends StatefulWidget {
  const _ReasoningBubble({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  State<_ReasoningBubble> createState() => _ReasoningBubbleState();
}

class _ReasoningBubbleState extends State<_ReasoningBubble> {
  late bool _open = widget.streaming;

  @override
  void didUpdateWidget(covariant _ReasoningBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The answer arrived: collapse the working-out that produced it. The user
    // can open it again by tapping.
    if (oldWidget.streaming && !widget.streaming) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      key: const ValueKey<String>('reasoning-bubble'),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: c.raised,
        border: Border.all(color: c.hairline),
        borderRadius: const BorderRadius.all(NexusLayout.tile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            key: const ValueKey<String>('reasoning-toggle'),
            borderRadius: const BorderRadius.all(NexusLayout.tile),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.streaming)
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: c.textMuted,
                      ),
                    )
                  else
                    Icon(
                      Icons.psychology_outlined,
                      size: 16,
                      color: c.textMuted,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    'Thinking...',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 11),
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontStyle: FontStyle.italic,
                  color: c.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The key on the "Send to…" control in an image bubble and in the viewer.
const Key kNexusSendTo = ValueKey<String>('send-to');

/// The grey block under an attached image that shows what ML Kit found.
///
/// A key so a test can prove the scan is visible, not just that the model was
/// asked: the whole point of the line is that the user can see the evidence
/// even when the small model's answer is poor.
const Key kNexusVisionCaption = ValueKey<String>('vision-caption');

/// The ⓘ that reveals what ML Kit saw. Hidden metadata, not lost metadata.
const Key kNexusVisionInfo = ValueKey<String>('vision-info');

/// What that control is called.
const String kNexusSendToLabel = 'Send to…';

/// The key on the "Share" control in an image bubble, and its label.
const Key kNexusShareImage = ValueKey<String>('share-image');
const String kNexusShareLabel = 'Share';

/// Hands [path] to Android's own share sheet.
///
/// The other door beside "Send to": that one moves a file between Nexus
/// devices, this one moves it to any app the phone has — Messages, Gmail, Drive,
/// a chat. It is the platform's sheet rather than a Nexus list because the
/// destination is the phone's business, and copying the bytes into a private
/// folder first would only make the payload harder to find.
///
/// Nothing here claims the share happened: the sheet's result says whether the
/// user picked something or dismissed it, and neither is an error, so the only
/// thing worth reporting is a file that has gone and a platform that refused.
Future<void> nexusShareImage(BuildContext context, String path) async {
  if (!File(path).existsSync()) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('That image is no longer on this device.'),
        ),
      );
    return;
  }
  try {
    await SharePlus.instance.share(ShareParams(files: <XFile>[XFile(path)]));
  } catch (error) {
    // No share sheet on this platform, or the plugin is missing in a headless
    // test: either way the user is owed a sentence, not a dead tap.
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Could not open the share sheet — $error')),
      );
  }
}

/// The key on the send sheet's progress bar.
const Key kNexusSendProgress = ValueKey<String>('send-progress');

/// Opens the send sheet for one image: choose a paired device, watch the bar,
/// read the result.
///
/// Its own sheet rather than a dialog because the middle of this flow is a
/// device list the user may have to read carefully — which phone am I sending
/// this to — and a dialog that grows a list is a sheet that was designed late.
Future<void> showSendToSheet(
  BuildContext context, {
  required String path,
  String? caption,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.ui.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => _SendToSheet(
      path: path,
      caption: caption,
      send: (PairedDevice device, void Function(double) onProgress) => FileLink
          .instance
          .send(path: path, device: device, onProgress: onProgress),
    ),
  );
}

/// The sheet's whole state machine: pick, send, report.
///
/// [send] is injected rather than called through [FileLink] directly so the
/// sheet can be tested without writing files — the same move the rest of this
/// file makes for the brain, the microphone and the speaker.
class _SendToSheet extends StatefulWidget {
  const _SendToSheet({required this.path, this.caption, required this.send});

  final String path;
  final String? caption;
  final Future<FileSendResult> Function(
    PairedDevice device,
    void Function(double progress) onProgress,
  )
  send;

  @override
  State<_SendToSheet> createState() => _SendToSheetState();
}

class _SendToSheetState extends State<_SendToSheet> {
  PairedDevice? _target;
  double _progress = 0;
  FileSendResult? _result;

  bool get _sending => _target != null && _result == null;

  Future<void> _send(PairedDevice device) async {
    if (_sending) return;
    setState(() {
      _target = device;
      _progress = 0;
      _result = null;
    });
    final FileSendResult result = await widget.send(device, (double value) {
      if (!mounted) return;
      setState(() => _progress = value);
    });
    if (!mounted) return;
    setState(() {
      _progress = 1;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final NearbyDevices nearby = NearbyDevices.instance;
    final List<PairedDevice> devices = <PairedDevice>[
      for (final PairedDevice device in PairedDevices.instance.devices)
        if (!device.isThisDevice) device,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
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
            Text(kNexusSendToLabel, style: NexusType.rowTitle(c)),
            const SizedBox(height: 4),
            Text(widget.caption ?? 'This image', style: NexusType.rowMeta(c)),
            const SizedBox(height: 14),
            if (_target == null && devices.isEmpty)
              Text(
                'No other device is paired yet. Pair one by scanning its code, '
                'or find it under Discover Nearby Devices.',
                style: NexusType.rowMeta(c).copyWith(height: 1.5),
              )
            else if (_sending)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Sending to ${_target!.name}…',
                    style: NexusType.rowMeta(c),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    key: kNexusSendProgress,
                    value: _progress,
                    color: c.accent,
                    backgroundColor: c.hairline,
                  ),
                ],
              )
            else if (_result case final FileSendResult result)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        result.ok
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 18,
                        color: result.ok ? c.accent : c.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          result.message,
                          key: kNexusSendResult,
                          style: NexusType.rowMeta(c).copyWith(height: 1.45),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() {
                      _target = null;
                      _result = null;
                    }),
                    child: const Text('Send to another device'),
                  ),
                ],
              )
            else
              for (final PairedDevice device in devices) ...<Widget>[
                NexusRow(
                  key: ValueKey<String>('send-to-${device.id}'),
                  title: device.name,
                  subtitle: nearby.hasHeard(device.id)
                      ? 'On this network now'
                      : 'Not heard on this network',
                  leading: const NexusIconTile(Icons.send_rounded),
                  accentTitle: true,
                  trailing: NexusStatusDot(online: nearby.hasHeard(device.id)),
                  onTap: () => unawaited(_send(device)),
                ),
              ],
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// The key on the sentence a send ends with.
const Key kNexusSendResult = ValueKey<String>('send-result');

/// A thumbnail in the thread: a photo from the camera or one screenshot of
/// the phone, with the caption the turn carried ("Photo attached").
///
/// It is a bubble in shape and colour — the same rounded box on the user's side
/// — because that is what it is: something the user said, with a picture in it.
/// The picture is drawn *inside* the bubble rather than beside it so the caption
/// and the image can never look like two messages.
///
/// Tapping opens [ImageViewerPage]. A file that has gone missing keeps its
/// caption and draws a placeholder: a conversation is worth more than its
/// pictures, and a blank gap would read as the app having lost the message too.
class NexusAttachmentBubble extends StatelessWidget {
  const NexusAttachmentBubble({
    super.key,
    required this.path,
    this.paths = const <String>[],
    required this.caption,
    required this.mine,
    this.detectedText,
    this.objects = const <String>[],
    this.maxWidth = 320,
  });

  /// Where the first kept image lives. Kept as the one path older callers and
  /// tests name; [allImagePaths] is what the bubble actually draws.
  final String path;

  /// Every image in this turn. Empty means just [path].
  final List<String> paths;

  List<String> get allImagePaths => paths.isNotEmpty ? paths : <String>[path];

  /// The line the turn carried — the same words the brain was given context
  /// for, drawn under the picture.
  final String caption;

  /// True for the user's side. Always true today: only the user attaches
  /// images. Kept as a parameter because a bubble that assumes its side is a
  /// bubble somebody has to rewrite the day the assistant sends one.
  final bool mine;

  /// The words ML Kit read, or null when there were none. Drawn in small grey
  /// type under the caption, so the scan is visible before and after the model
  /// answers.
  final String? detectedText;

  /// The object labels ML Kit found. Empty hides the line.
  final List<String> objects;

  final double maxWidth;

  /// The largest the thumbnail gets. A full-bleed photo in a chat makes every
  /// other line scroll away; this is a reminder of the picture, not the picture.
  static const double thumbnailHeight = 250;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Semantics(
          button: true,
          label: 'Attached image: $caption',
          child: GestureDetector(
            key: ValueKey<String>('attachment:$path'),
            onTap: () => ImageViewerPage.open(
              context,
              path,
              caption: caption,
              // The full-screen page carries the same door as the bubble: a
              // user looking closely at a photo is exactly the one who wants
              // to send it somewhere.
              onSend: () => unawaited(
                showSendToSheet(context, path: path, caption: caption),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _AttachmentThumbnails(
                    paths: allImagePaths,
                    maxHeight: thumbnailHeight,
                    onOpen: (String image) => ImageViewerPage.open(
                      context,
                      image,
                      caption: caption,
                      onSend: () => unawaited(
                        showSendToSheet(context, path: image, caption: caption),
                      ),
                    ),
                  ),
                  _AttachmentCaption(
                    caption: caption,
                    detectedText: detectedText,
                    objects: objects,
                  ),
                  // The way out of the bubble that is not "look at it": a
                  // photo in a thread is usually on its way somewhere else.
                  // Two doors, because they are two different journeys: "Send
                  // to" hands the file to another Nexus device over the mesh,
                  // and Share hands it to whatever app the phone offers.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                    child: Row(
                      children: <Widget>[
                        InkWell(
                          key: kNexusSendTo,
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => unawaited(
                            showSendToSheet(
                              context,
                              path: path,
                              caption: caption,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.send_rounded,
                                  size: 14,
                                  color: c.accent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  kNexusSendToLabel,
                                  style: NexusType.rowMeta(
                                    c,
                                  ).copyWith(fontSize: 12.5, color: c.accent),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          key: kNexusShareImage,
                          borderRadius: BorderRadius.circular(10),
                          onTap: () =>
                              unawaited(nexusShareImage(context, path)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.ios_share_rounded,
                                  size: 14,
                                  color: c.accent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  kNexusShareLabel,
                                  style: NexusType.rowMeta(
                                    c,
                                  ).copyWith(fontSize: 12.5, color: c.accent),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture row inside an attachment bubble: one capped thumbnail, or a
/// horizontal strip when the turn carries several. Each picture opens its own
/// full-screen viewer, because a tap is how the user says *which* one.
class _AttachmentThumbnails extends StatelessWidget {
  const _AttachmentThumbnails({
    required this.paths,
    required this.maxHeight,
    required this.onOpen,
  });

  final List<String> paths;
  final double maxHeight;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final bool many = paths.length > 1;
    if (!many) {
      final String path = paths.first;
      return _Thumb(path: path, height: maxHeight, onTap: () => onOpen(path));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final String path in paths)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Thumb(
                path: path,
                height: maxHeight * 0.6,
                width: maxHeight * 0.6,
                onTap: () => onOpen(path),
              ),
            ),
        ],
      ),
    );
  }
}

/// One thumbnail. Checked before decoding rather than only in the errorBuilder:
/// a file that has been deleted is the common case, the check is one stat, and
/// the placeholder is then on screen in the same frame as the bubble instead of
/// a frame later. The errorBuilder still covers a file that exists and will not
/// decode.
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.path,
    required this.height,
    required this.onTap,
    this.width,
  });

  final String path;
  final double height;
  final double? width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey<String>('attachment-image:$path'),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: SizedBox(
          width: width,
          height: height,
          child: File(path).existsSync()
              ? Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (BuildContext context, Object error, _) =>
                      const _MissingThumbnail(),
                )
              : const _MissingThumbnail(),
        ),
      ),
    );
  }
}

/// The caption line under a picture, and the one small door to what ML Kit saw.
///
/// The tags used to sit in the bubble permanently, which made every photo turn
/// end in a paragraph of machine labels. They are still one tap away — the ⓘ is
/// only drawn when there is something to show — but the conversation's reading
/// order is the user's caption and the assistant's answer.
class _AttachmentCaption extends StatefulWidget {
  const _AttachmentCaption({
    required this.caption,
    required this.detectedText,
    required this.objects,
  });

  final String caption;
  final String? detectedText;
  final List<String> objects;

  @override
  State<_AttachmentCaption> createState() => _AttachmentCaptionState();
}

class _AttachmentCaptionState extends State<_AttachmentCaption> {
  bool _open = false;

  bool get _hasEvidence =>
      (widget.detectedText?.trim().isNotEmpty ?? false) ||
      widget.objects.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 2, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.caption,
                  style: NexusType.bubble(c)
                      .copyWith(fontSize: 14, color: c.textMuted),
                ),
              ),
              if (_hasEvidence)
                IconButton(
                  key: kNexusVisionInfo,
                  tooltip: _open ? 'Hide image details' : 'Image details',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => setState(() => _open = !_open),
                  icon: Icon(
                    _open ? Icons.info_rounded : Icons.info_outline_rounded,
                    size: 18,
                    color: _open ? c.accent : c.textMuted,
                  ),
                ),
            ],
          ),
        ),
        if (_open && _hasEvidence)
          Padding(
            key: kNexusVisionCaption,
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.detectedText?.trim().isNotEmpty ?? false)
                  _VisionCaptionLine(
                    icon: Icons.text_snippet_outlined,
                    text: 'Detected text: "${widget.detectedText!.trim()}"',
                  ),
                if (widget.objects.isNotEmpty)
                  _VisionCaptionLine(
                    icon: Icons.label_outline_rounded,
                    text: 'Objects: ${widget.objects.join(', ')}',
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One line of the grey "what the phone saw" block under a picture.
///
/// Icons rather than emoji so it belongs to the rest of the shell's type, and a
/// separate widget so both lines stay the same size and colour.
class _VisionCaptionLine extends StatelessWidget {
  const _VisionCaptionLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final TextStyle style = NexusType.rowMeta(c)
        .copyWith(fontSize: 12, height: 1.35, color: c.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 12.5, color: c.textMuted),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// The grey box a missing picture leaves. Deliberately quiet: the caption under
/// it already says what the line was.
class _MissingThumbnail extends StatelessWidget {
  const _MissingThumbnail();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      width: 180,
      height: NexusAttachmentBubble.thumbnailHeight,
      color: c.raised,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, size: 26, color: c.textMuted),
    );
  }
}

/// A document in the thread: a chip with the file's name, drawn on the user's
/// side like any other thing they said.
///
/// Deliberately not a thumbnail. A PDF has no picture to show, and the one
/// honest thing a conversation can say about a file it cannot read is which
/// file it is — so the chip names it and taps through to the platform's own
/// viewer. A name that has gone missing says so instead of opening nothing.
class NexusFileBubble extends StatelessWidget {
  const NexusFileBubble({
    super.key,
    required this.path,
    required this.caption,
    required this.mine,
    this.maxWidth = 320,
  });

  /// Where the kept copy lives.
  final String path;

  /// The line the turn carried: "File attached: notes.pdf".
  final String caption;

  final bool mine;
  final double maxWidth;

  Future<void> _open(BuildContext context) async {
    final bool opened = await openLocalFile(path);
    if (opened || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('That file could not be opened.'),
        duration: Duration(milliseconds: 2200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Semantics(
          button: true,
          label: caption,
          child: InkWell(
            key: ValueKey<String>('file:$path'),
            onTap: () => unawaited(_open(context)),
            borderRadius: BorderRadius.all(NexusLayout.bubble),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.raised,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      Icons.description_rounded,
                      size: 20,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NexusType.bubble(c).copyWith(fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tap to open',
                          style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                  style: NexusType.rowMeta(c)
                      .copyWith(fontSize: 13, color: c.textStrong),
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
  const _MessageActions({
    required this.text,
    this.speak = true,
    this.liked = false,
    this.disliked = false,
    this.onLike,
    this.onDislike,
    this.onRegenerate,
  });

  final String text;

  /// False on the failure notice, which offers copy and never a speaker.
  final bool speak;

  final bool liked;
  final bool disliked;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final VoidCallback? onRegenerate;

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
          if (onLike != null)
            _BubbleAction(
              key: const ValueKey<String>('message-like'),
              tooltip: liked ? 'Liked' : 'Like',
              icon: liked
                  ? Icons.thumb_up_alt_rounded
                  : Icons.thumb_up_alt_outlined,
              active: liked,
              onTap: onLike!,
            ),
          if (onDislike != null)
            _BubbleAction(
              key: const ValueKey<String>('message-dislike'),
              tooltip: disliked ? 'Disliked' : 'Dislike',
              icon: disliked
                  ? Icons.thumb_down_alt_rounded
                  : Icons.thumb_down_alt_outlined,
              active: disliked,
              onTap: onDislike!,
            ),
          if (onRegenerate != null)
            _BubbleAction(
              key: const ValueKey<String>('message-regenerate'),
              tooltip: 'Regenerate',
              icon: Icons.refresh_rounded,
              onTap: onRegenerate!,
            ),
        ],
      ),
    );
  }
}

/// One 32dp tap target in a message's action row.
class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  /// True for a thumb the user has pressed: the filled glyph and the accent are
  /// how the row says the note was taken without a snack bar.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: active ? c.accent : c.textMuted),
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
/// One attachment waiting in the composer: the file and what kind it is.
@immutable
class _PendingAttachment {
  const _PendingAttachment(this.picked, this.kind);

  final PickedAttachment picked;
  final AttachmentKind kind;
}

/// The most pictures one turn may carry. Three covers "front, back and the
/// label" without turning a thumbnail into a gallery and the vision pass into a
/// batch job on a phone.
const int kNexusMaxPendingImages = 3;

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
    required this.onAdd,
    required this.pending,
    required this.onRemovePending,
  });

  /// Chosen but not sent. Drawn above the field as a horizontal row of
  /// thumbnails, each with its own X; the words and the pictures leave together
  /// when Send is tapped, and a pick that is never sent never reaches the
  /// thread.
  final List<_PendingAttachment> pending;
  final ValueChanged<_PendingAttachment> onRemovePending;

  /// The way in to everything that is not words: camera, gallery, file, and —
  /// inside live mode — the screen. One button on the left, as Claude's
  /// composer has it: a pair of named circles beside a field that already
  /// shares its row with two voice controls was two more things to read in the
  /// one place the user is trying to type.
  final VoidCallback onAdd;

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
              if (pending.isNotEmpty)
                _PendingAttachmentPreview(
                  pending: pending,
                  onRemove: onRemovePending,
                ),
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
                    if (!listening) ...<Widget>[
                      _AddButton(onTap: onAdd),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: TextField(
                          key: kNexusComposerField,
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
                            hintText: nexusIsFrench(context)
                                ? 'Message'
                                : 'Message Nexus',
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

/// The attachment chosen but not sent: a thumbnail (or a file glyph), its
/// name, and the X that throws it away.
///
/// Above the field rather than inside it: the field is where the words go, and
/// a picture sitting in the text run would be a character the keyboard could
/// delete. The X is its own 40dp target because it is the control a user reaches
/// for when they picked the wrong photo.
const Key kNexusPendingAttachment = Key('nexus-pending-attachment');
const Key kNexusRemoveAttachment = Key('nexus-remove-attachment');

class _PendingAttachmentPreview extends StatelessWidget {
  const _PendingAttachmentPreview({
    required this.pending,
    required this.onRemove,
  });

  final List<_PendingAttachment> pending;
  final ValueChanged<_PendingAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      key: kNexusPendingAttachment,
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.hairline),
          borderRadius: const BorderRadius.all(NexusLayout.tile),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final _PendingAttachment item in pending)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _PendingAttachmentTile(
                    item: item,
                    // One picture keeps the historical key; several get a key
                    // of their own, because two widgets cannot share one.
                    removeKey: pending.length == 1
                        ? kNexusRemoveAttachment
                        : ValueKey<String>(
                            'remove-attachment-${item.picked.path}',
                          ),
                    onRemove: () => onRemove(item),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 22, right: 2),
                child: Text(
                  '${pending.length}/$kNexusMaxPendingImages',
                  style: NexusType.rowMeta(c).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One 64dp thumbnail and its X, with the file's name under it. A row of these
/// is what "three pictures in one turn" looks like before Send.
class _PendingAttachmentTile extends StatelessWidget {
  const _PendingAttachmentTile({
    required this.item,
    required this.removeKey,
    required this.onRemove,
  });

  final _PendingAttachment item;
  final Key removeKey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool image = item.kind.isImage;
    return SizedBox(
      width: 78,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 72,
            height: 64,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(9)),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: image && File(item.picked.path).existsSync()
                        ? Image.file(
                            File(item.picked.path),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => ColoredBox(
                              color: c.raised,
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 20,
                                color: c.textMuted,
                              ),
                            ),
                          )
                        : ColoredBox(
                            color: c.raised,
                            child: Icon(
                              image
                                  ? Icons.image_outlined
                                  : Icons.insert_drive_file_outlined,
                              size: 21,
                              color: c.textMuted,
                            ),
                          ),
                  ),
                ),
                Positioned(
                  top: -8,
                  right: -4,
                  child: Material(
                    color: c.textStrong,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: removeKey,
                      customBorder: const CircleBorder(),
                      onTap: onRemove,
                      child: Tooltip(
                        message: 'Remove attachment',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 13,
                            color: c.background,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.picked.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: NexusType.rowMeta(c).copyWith(fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

/// The key on the composer's `+`: the one door to every attachment.
const Key kComposerAdd = ValueKey<String>('composer-add');

/// The speaker in the Home header: whether answers are read out loud.
///
/// It lives here rather than in Settings because it is a switch about the
/// conversation, and the conversation is the screen it belongs on: a user who
/// wants the voice to stop does not want to leave the chat to say so. The glyph
/// is the state — a speaker with sound when replies are spoken, a crossed one
/// when they are not — and the tooltip says the same thing in words.
const Key kSpeakRepliesToggle = ValueKey<String>('composer-speak-replies');

class _SpeakRepliesButton extends StatefulWidget {
  const _SpeakRepliesButton();

  @override
  State<_SpeakRepliesButton> createState() => _SpeakRepliesButtonState();
}

class _SpeakRepliesButtonState extends State<_SpeakRepliesButton> {
  late final VoiceSettings _voice = VoiceSettings.instance;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_changed);
    // The stored choice arrives asynchronously; the button corrects itself from
    // the settled service rather than showing the default on every launch.
    unawaited(
      _voice.attach().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool on = _voice.speakReplies;
    return Tooltip(
      message: on ? 'Speak replies on' : 'Speak replies off',
      child: InkResponse(
        key: kSpeakRepliesToggle,
        onTap: () => _voice.speakReplies = !on,
        radius: 22,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(NexusLayout.tile),
            color: on ? c.accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(color: on ? c.accent : c.hairline),
          ),
          child: Icon(
            on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            size: 18,
            color: on ? c.accent : c.textMuted,
          ),
        ),
      ),
    );
  }
}

/// The three buttons in the attachment sheet, named so a test can reach each
/// one the way a thumb does.
const Key kSheetCamera = ValueKey<String>('sheet-camera');
const Key kSheetPhotos = ValueKey<String>('sheet-photos');
const Key kSheetFiles = ValueKey<String>('sheet-files');

/// The `+` at the left of the field.
///
/// Outlined rather than filled, and smaller than the mic/send circle: the
/// colour rule in this file says purple means "the action here", and attaching
/// something is a way *into* the composer rather than the composer's action.
/// The glyph is a plus, the label a tooltip, and everything it can do lives one
/// tap away in [_AttachmentSheet] — the same shape as Claude's composer, which
/// is where this came from.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: 'Add',
        child: InkResponse(
          key: kComposerAdd,
          onTap: onTap,
          radius: 22,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.raised,
              border: Border.all(color: c.hairline),
            ),
            child: Icon(Icons.add_rounded, size: 19, color: c.textMuted),
          ),
        ),
      ),
    );
  }
}

/// What the user chose in the attachment sheet.
enum _AttachChoice { camera, photos, files }

/// The two switches at the bottom of the sheet, named so a test can flip them
/// the way a thumb does.
const Key kSheetWebSearch = ValueKey<String>('sheet-web-search');
const Key kSheetMemory = ValueKey<String>('sheet-memory');
const Key kSheetProjects = ValueKey<String>('sheet-projects');

/// The sheet behind the composer's `+`: three ways to attach, and the three
/// switches that change what happens to the next answer.
///
/// Claude's sheet, in the two halves that matter: a row of three square doors
/// for the things a camera roll and a filesystem can hand over, and a quiet list
/// under them for the two modes a conversation has. The doors are *large* — a
/// 96-point square is the whole target — because picking a photo should not
/// require aiming. The switches are rows rather than chips because they are
/// settings, and a setting that looks like an attachment is a setting the user
/// will tap expecting a picker.
class _AttachmentSheet extends StatefulWidget {
  const _AttachmentSheet();

  @override
  State<_AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends State<_AttachmentSheet> {
  /// The sheet's own ink, independent of the app's brightness: a dark sheet
  /// under a light theme is a deliberate surface, not a theme failure.
  static const Color _ground = Color(0xFF1F1F1E);
  static const Color _row = Color(0xFF2C2C2A);
  static const Color _ink = Color(0xFFF5F5F2);
  static const Color _muted = Color(0xFFA8A8A2);
  static const Color _hairline = Color(0xFF3A3A37);

  late final ComposerSettings _settings = ComposerSettings.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.attach());
    _settings.addListener(_onChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Container(
          decoration: const BoxDecoration(
            color: _ground,
            borderRadius: BorderRadius.all(Radius.circular(26)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF4A4A47),
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                ),
              ),
              // The three doors. Equal widths to the pixel: a camera card that
              // is wider than Photos is a suggestion that one is the normal
              // choice, and here there is no normal choice.
              Row(
                children: <Widget>[
                  Expanded(
                    child: _AttachCard(
                      key: kSheetCamera,
                      icon: Icons.photo_camera_rounded,
                      label: 'Camera',
                      onTap: () =>
                          Navigator.of(context).pop(_AttachChoice.camera),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _AttachCard(
                      key: kSheetPhotos,
                      icon: Icons.photo_library_rounded,
                      label: 'Photos',
                      onTap: () =>
                          Navigator.of(context).pop(_AttachChoice.photos),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _AttachCard(
                      key: kSheetFiles,
                      icon: Icons.description_rounded,
                      label: 'Files',
                      onTap: () =>
                          Navigator.of(context).pop(_AttachChoice.files),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Divider(height: 1, thickness: 1, color: _hairline),
              const SizedBox(height: 4),
              _SheetSwitchRow(
                key: kSheetWebSearch,
                icon: Icons.public_rounded,
                label: 'Web search',
                // The one switch that leaves the device. It says what it sends
                // rather than "search the web", because a user deciding this is
                // deciding about their question, not about the feature.
                value: _settings.webSearchEnabled,
                subtitle: _settings.webSearchEnabled
                    ? 'On — each question is sent to DuckDuckGo'
                    : 'Off — answers stay on this device',
                onChanged: (bool value) =>
                    unawaited(_settings.setWebSearchEnabled(value)),
              ),
              _SheetSwitchRow(
                key: kSheetMemory,
                icon: Icons.psychology_outlined,
                label: 'Memory',
                value: _settings.memoryEnabled,
                subtitle: _settings.memoryEnabled
                    ? 'Remembered facts are given to the model'
                    : 'Off — nothing remembered is sent to the model',
                onChanged: (bool value) =>
                    unawaited(_settings.setMemoryEnabled(value)),
              ),
              _SheetLinkRow(
                key: kSheetProjects,
                icon: Icons.workspaces_outline,
                label: 'Add to project',
                trailing: 'Soon',
                onTap: () {
                  Navigator.of(context).pop();
                  nexusNotWired(context, 'Projects');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the three square doors. 96 points tall, the whole block a target.
class _AttachCard extends StatelessWidget {
  const _AttachCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _AttachmentSheetState._row,
      borderRadius: const BorderRadius.all(Radius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 26, color: _AttachmentSheetState._ink),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  color: _AttachmentSheetState._ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A list row with a switch: icon, name, a one-line explanation, and the switch
/// itself. The row is the target as well as the switch.
class _SheetSwitchRow extends StatelessWidget {
  const _SheetSwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 20, color: _AttachmentSheetState._muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        color: _AttachmentSheetState._ink,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: _AttachmentSheetState._muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one row that opens something this build does not have: a report that is
/// honest before it is tapped, rather than a dead chevron.
class _SheetLinkRow extends StatelessWidget {
  const _SheetLinkRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 11, 6, 11),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 20, color: _AttachmentSheetState._muted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    color: _AttachmentSheetState._ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                trailing,
                style: GoogleFonts.inter(
                  color: _AttachmentSheetState._muted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: _AttachmentSheetState._muted,
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
class _HoldToTalk extends StatefulWidget {
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
  State<_HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends State<_HoldToTalk> {
  /// True once the finger has travelled far enough left to mean "throw this
  /// away". WhatsApp's gesture, and the reason the composer says so while the
  /// mic is open: a release after a left slide must not keep the words.
  bool _slidAway = false;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: widget.enabled
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
                      instance.onLongPressStart = (LongPressStartDetails _) {
                        _slidAway = false;
                        widget.onStart();
                      };
                      instance.onLongPressMoveUpdate =
                          (LongPressMoveUpdateDetails details) {
                            if (details.offsetFromOrigin.dx < -48) {
                              _slidAway = true;
                            }
                          };
                      instance.onLongPressEnd = (LongPressEndDetails details) =>
                          widget.onEnd(
                            _slidAway ||
                                !_stillOnButton(
                                  context,
                                  details.globalPosition,
                                ),
                          );
                    },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: widget.child,
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
    this.speaking = false,
    this.turns = const <NexusMockMessage>[],
  });

  final _LivePhase phase;
  final String partial;
  final String said;

  /// True while the assistant's answer is being read out loud. The page draws a
  /// Stop speaking control in place of "Tap to continue" — a tap anywhere on the
  /// page cuts the voice off, and that tap does **not** reopen the microphone.
  final bool speaking;

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
    required this.onAccent,
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

  /// The ink that sits *on* [accent] in a filled control.
  ///
  /// Asked of the accent rather than assumed white: a pale pick is a colour the
  /// user is allowed to make, and white on a near-white button is unreadable.
  final Color onAccent;

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
        onAccent: c.onAccent,
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
      onAccent: c.onAccent,
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
/// large type, shows the answer, and then hands the turn back: the microphone
/// closes while the answer is read out, and reopens 1.5 s after the voice stops.
/// The voice itself can be cut off with the Stop speaking control or a tap
/// anywhere on the page, and that stop leaves the microphone closed. With no
/// conversation behind it yet, the user's own sentence is the honest thing to put
/// on it. The two ways on are the X at the bottom and the orb itself.
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
    required this.onStopSpeaking,
    required this.onShareScreen,
    required this.onPickPhoto,
    required this.onToggleMic,
    required this.level,
  });

  /// The same loudness readings the composer's meter uses: the page's own meter
  /// is real voice too, not a second decoration.
  final ValueListenable<_LiveState> state;
  final VoidCallback onClose;

  /// Opens the next turn by hand. Every state of this page that is not
  /// [listening] draws this tap as the obvious thing to do — after a stop, or
  /// after the guard — even though a normal answer now hands the turn back on
  /// its own.
  final VoidCallback onResume;

  /// Cuts the voice off now. Shown as a control while [state.speaking], and
  /// wired to a tap anywhere else on the page. Tapping it hands the microphone
  /// straight back: an interruption is the start of the next turn.
  final VoidCallback onStopSpeaking;

  /// Shares one frame of the phone's screen with the conversation. Only this
  /// page has it.
  final VoidCallback onShareScreen;

  /// Adds one photo to the conversation. The page's second door, beside the
  /// screen: both are something shown to the room rather than typed into it.
  final VoidCallback onPickPhoto;

  /// The microphone circle and the pill: close an open microphone, or open a
  /// closed one. One callback because it is one control in two shapes, which
  /// is exactly how Gemini's row reads.
  final VoidCallback onToggleMic;

  final ValueListenable<double> level;

  /// The sentence under the conversation: the page's plain-language answer to
  /// "is the microphone on?". One function rather than a switch in two places,
  /// because the badge and the words must never disagree.
  static String statusFor(_LiveState live) {
    if (live.speaking) return 'Speaking — tap to stop.';
    return switch (live.phase) {
      _LivePhase.listening => 'Listening — just speak.',
      _LivePhase.thinking => 'Mic off — asking the AI…',
      _LivePhase.answering => 'Mic off — answering…',
      _LivePhase.waiting => 'Mic off.',
      _LivePhase.guarded => 'Mic off. Nothing is recording.',
    };
  }

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
            final bool thinking =
                live.phase == _LivePhase.thinking ||
                live.phase == _LivePhase.answering;
            // While the answer is being spoken the headline is the answer, not
            // "Listening…": the barge-in monitor is open under the voice, and
            // the words on screen are what is being said aloud.
            final String headline = live.speaking
                ? (live.turns.isEmpty ? live.said : live.turns.last.text)
                : switch (live.phase) {
                    _LivePhase.listening =>
                      live.partial.isEmpty ? 'Listening…' : live.partial,
                    _LivePhase.thinking => kNexusThinking,
                    _LivePhase.answering =>
                      live.answer.isEmpty ? kNexusThinking : live.answer,
                    _ =>
                      live.turns.isEmpty
                          ? 'Say something.'
                          : live.turns.last.text,
                  };
            // The transcript above the headline: the last few turns, so the
            // large type stays one line and the conversation stays readable.
            final List<NexusMockMessage> older = live.turns.length <= 1
                ? const <NexusMockMessage>[]
                : live.turns.sublist(0, live.turns.length - 1);
            final bool recording = live.phase == _LivePhase.listening;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: live.speaking ? onStopSpeaking : null,
              child: Column(
                children: <Widget>[
                  // Menu on the left, minimize on the right, and the one badge
                  // in the middle that says whether the microphone is open.
                  // Gemini's top bar, with this page's own truth in the centre.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          key: kNexusLiveMenu,
                          tooltip: 'Live options',
                          onPressed: () => _showLiveMenu(context, palette),
                          icon: Icon(
                            Icons.menu_rounded,
                            color: palette.ink,
                            size: 24,
                          ),
                        ),
                        Expanded(
                          child: Center(
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
                                _ => const SizedBox.shrink(),
                              },
                            ),
                          ),
                        ),
                        IconButton(
                          key: kNexusLiveMinimize,
                          tooltip: 'Minimize live conversation',
                          onPressed: onClose,
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: palette.ink,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            // Centred while the conversation is short and
                            // scrollable once it is not: a room holding one line
                            // puts that line in the middle of the page, the way
                            // Gemini does, rather than pinning it to the floor
                            // of an empty screen.
                            child: Align(
                              child: SingleChildScrollView(
                                key: kNexusLiveTranscript,
                                reverse: true,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _LiveLine(
                                      text: headline,
                                      mine:
                                          live.phase == _LivePhase.listening &&
                                          !live.speaking &&
                                          live.partial.isNotEmpty,
                                      primary: true,
                                      palette: palette,
                                    ),
                                    for (final NexusMockMessage turn
                                        in older.reversed)
                                      _LiveLine(
                                        text: turn.text,
                                        mine: turn.mine,
                                        failed: turn.failed,
                                        palette: palette,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // The wait, drawn as Gemini draws it: a white spinner
                          // on the room's own ground, with a counter under it.
                          // The counter is honest about *waiting* — it starts
                          // with the request and stops with the first token.
                          if (thinking) ...<Widget>[
                            const SizedBox(height: 2),
                            SizedBox(
                              key: kNexusLiveSpinner,
                              width: 34,
                              height: 34,
                              child: const CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            _LiveThinkTimer(text: live.answer),
                          ],
                          const SizedBox(height: 8),
                          // The voice, drawn: the real microphone readings in
                          // the pill's own glass. Nothing animates on its own.
                          if (!thinking)
                            Text(
                              statusFor(live),
                              key: kNexusLiveStatus,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                color: palette.muted,
                                fontSize: 14,
                              ),
                            )
                          else
                            Text(
                              statusFor(live),
                              key: kNexusLiveStatus,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                color: palette.muted,
                                fontSize: 14,
                              ),
                            ),
                          // The interruption. Large, because it is the control a
                          // user reaches for while the phone is still talking.
                          if (live.speaking) ...<Widget>[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: kNexusLiveStopSpeaking,
                              onPressed: onStopSpeaking,
                              icon: const Icon(
                                Icons.stop_circle_rounded,
                                size: 20,
                              ),
                              label: const Text(kNexusLiveStopSpeakingLabel),
                              style: FilledButton.styleFrom(
                                backgroundColor: palette.accent,
                                foregroundColor: palette.onAccent,
                                minimumSize: const Size(150, 46),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                textStyle: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ] else if (live.phase ==
                              _LivePhase.guarded) ...<Widget>[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: kNexusLiveResume,
                              onPressed: onResume,
                              icon: const Icon(Icons.mic_rounded, size: 18),
                              label: const Text('Tap to continue'),
                              style: FilledButton.styleFrom(
                                backgroundColor: palette.accent,
                                foregroundColor: palette.onAccent,
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
                  // Five controls, evenly spaced: share, photos, the big
                  // listening pill, the microphone, and the way out — Gemini's
                  // row, with the middle one doing the thing the page is for.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        // All five are always here, dimmed rather than removed
                        // while the page is working: a row that reflows mid-turn
                        // moves the pill under the thumb that is about to
                        // interrupt the voice.
                        _LiveRoundButton(
                          key: kNexusLiveScreenShare,
                          icon: Icons.screen_share_rounded,
                          tooltip: 'Share screen',
                          palette: palette,
                          onTap: thinking || live.speaking
                              ? null
                              : onShareScreen,
                        ),
                        _LiveRoundButton(
                          key: kNexusLivePhotos,
                          icon: Icons.photo_library_rounded,
                          tooltip: 'Add a photo',
                          palette: palette,
                          onTap: thinking || live.speaking ? null : onPickPhoto,
                        ),
                        _LiveTalkPill(
                          phase: live.phase,
                          speaking: live.speaking,
                          palette: palette,
                          level: level,
                          onTap: thinking
                              ? null
                              : live.speaking
                              ? onStopSpeaking
                              : recording
                              ? onToggleMic
                              : onResume,
                        ),
                        _LiveRoundButton(
                          key: kNexusLiveMic,
                          icon: recording
                              ? Icons.mic_rounded
                              : Icons.mic_none_rounded,
                          tooltip: recording
                              ? 'Stop listening'
                              : 'Start listening',
                          palette: palette,
                          active: recording,
                          onTap: thinking ? null : onToggleMic,
                        ),
                        _LiveRoundButton(
                          key: kNexusLiveClose,
                          icon: Icons.close_rounded,
                          tooltip: 'Close live conversation',
                          palette: palette,
                          onTap: onClose,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          Icons.lock_outline,
                          size: 12,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            'Recognized on this device when a language pack '
                            'is available; otherwise by your phone’s '
                            'recognizer.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              color: palette.muted,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The menu in the top-left. Not a second settings screen: the two facts
  /// worth having here are what the microphone is doing and how to end the
  /// room, and both are already on the page — so the sheet is the privacy
  /// promise and the one deliberate way out.
  void _showLiveMenu(BuildContext context, _LivePalette palette) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.ground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Live conversation',
                style: GoogleFonts.inter(
                  color: palette.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The microphone is open only while the page says Listening. '
                'Closing the page closes it too.',
                style: GoogleFonts.inter(
                  color: palette.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  onClose();
                },
                icon: Icon(Icons.close_rounded, size: 18, color: palette.ink),
                label: Text(
                  'End live conversation',
                  style: GoogleFonts.inter(color: palette.ink, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The clock under the spinner: "Thinking... (3s)".
///
/// It counts from the frame it is mounted, which is the frame the request goes
/// out, so the number is the time the user has waited rather than the time the
/// model has been generating. It disappears the moment the first token does —
/// the same rule as the bubble's placeholder counter in the thread.
class _LiveThinkTimer extends StatefulWidget {
  const _LiveThinkTimer({required this.text});

  /// The answer so far. Only used to force a fresh count when a new turn starts
  /// with the widget still mounted (an answer that replaces another one).
  final String text;

  @override
  State<_LiveThinkTimer> createState() => _LiveThinkTimerState();
}

class _LiveThinkTimerState extends State<_LiveThinkTimer> {
  int _seconds = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _seconds = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _LivePalette palette = _LivePalette.of(context);
    return Text(
      'Thinking... (${_seconds}s)',
      key: kNexusLiveThinkTimer,
      textAlign: TextAlign.center,
      style: GoogleFonts.inter(
        color: palette.muted,
        fontSize: 13,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}

/// One of the four small controls at the bottom: a dark disc, a light glyph,
/// and the whole 44-point circle as the target.
class _LiveRoundButton extends StatelessWidget {
  const _LiveRoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.palette,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final _LivePalette palette;
  final VoidCallback? onTap;

  /// True for the microphone while it is open: the accent rim is the one bit of
  /// colour in the row that is not the main pill.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: palette.closeWash,
        shape: CircleBorder(
          side: BorderSide(
            color: active
                ? palette.accent.withValues(alpha: 0.7)
                : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 20,
              color: onTap == null
                  ? palette.muted.withValues(alpha: 0.4)
                  : palette.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// The middle of the row: the listening indicator, the mic toggle, and the
/// page's heartbeat in one 156-point pill.
///
/// The glow is the state. Listening is the accent, thinking is the working
/// blue, and a closed microphone is the idle grey — the same three states, in
/// the same order, as the orb this pill replaced. The waveform inside is the
/// recognizer's real readings, drawn only while it listens; a pill that kept
/// moving after the microphone closed would be the page claiming to hear a
/// room it is not listening to.
class _LiveTalkPill extends StatelessWidget {
  const _LiveTalkPill({
    required this.phase,
    required this.speaking,
    required this.palette,
    required this.level,
    required this.onTap,
  });

  final _LivePhase phase;
  final bool speaking;
  final _LivePalette palette;
  final ValueListenable<double> level;
  final VoidCallback? onTap;

  bool get _listening => phase == _LivePhase.listening;

  bool get _thinking =>
      phase == _LivePhase.thinking || phase == _LivePhase.answering;

  @override
  Widget build(BuildContext context) {
    final List<Color> gradient = _listening
        ? <Color>[
            palette.accent.withValues(alpha: 0.98),
            palette.accent.withValues(alpha: 0.74),
          ]
        : _thinking
        ? const <Color>[kNexusLiveThinking, kNexusLiveThinkingDeep]
        : <Color>[
            palette.idleCore.first.withValues(alpha: 0.9),
            palette.idleCore.last.withValues(alpha: 0.9),
          ];
    return GestureDetector(
      key: kNexusLiveOrb,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        // Wide enough for the word plus the glyph at large text scales, and
        // narrow enough that four 44-point circles still fit beside it on a
        // 360-point phone: 4 × 44 + 156 + the row's gutters.
        width: 156,
        height: 56,
        key: _listening
            ? null
            : _thinking
            ? kNexusLiveOrbThinking
            : kNexusLiveOrbIdle,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: (_thinking ? kNexusLiveThinking : palette.accent)
                  .withValues(alpha: _listening || _thinking ? 0.45 : 0.12),
              blurRadius: 22,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Center(
          child: _listening
              ? SizedBox(
                  width: 96,
                  height: 36,
                  child: _LiveWaveform(
                    level: level,
                    listening: true,
                    color: palette.onAccent,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _thinking
                            ? Icons.auto_awesome_rounded
                            : (speaking
                                  ? Icons.volume_up_rounded
                                  : Icons.mic_none_rounded),
                        size: 19,
                        color: _thinking ? Colors.white : palette.ink,
                      ),
                      const SizedBox(width: 7),
                      // The label gives way before the pill does: a phone at
                      // 200% text scale must ellipsize one word, not overflow
                      // the row that holds the page's five controls.
                      Flexible(
                        child: Text(
                          speaking
                              ? 'Speaking'
                              : _thinking
                              ? 'Thinking'
                              : 'Tap to talk',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            color: _thinking ? Colors.white : palette.ink,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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

  /// Whose words these are: the user's are set back in the accent's ink, the
  /// assistant's in the page's own ink.
  ///
  /// The newest line is centred whoever said it — it is the one thing on the
  /// page, and Gemini centres it — while the remembered ones keep the thumb's
  /// own alignment, so a conversation still reads as two speakers.
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
        textAlign: primary
            ? TextAlign.center
            : (mine ? TextAlign.right : TextAlign.left),
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
        final double breathe =
            1 +
            (widget.thinking
                    ? 0.16
                    : widget.listening
                    ? 0.10
                    : 0) *
                pulse;
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
                      color: palette.accent.withValues(alpha: 0.55 * (1 - t)),
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
    // Never wider than the slot it sits in: 44 bars in a 96-point pill are 2.2
    // points apart, and a 3.5-point stroke made them overlap into one solid
    // dash — a rest state that read as a pause button. The stroke follows the
    // space instead, so silence is a row of dots at any pill width.
    final double stroke = math.min(dotWidth, slot * 0.62);
    paint.strokeWidth = stroke;
    for (int i = 0; i < heights.length; i++) {
      final double cx = slot * (i + 0.5);
      final double half = math.max(stroke / 2, heights[i] * size.height / 2);
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
    final double wobble = 0.58 + 0.42 * math.sin(i * 0.7) * math.cos(i * 0.31);
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
  const NexusMockFile(
    this.name,
    this.size,
    this.date,
    this.icon, {
    this.folder = false,
  });

  final String name;
  final String size;
  final String date;
  final IconData icon;

  /// True for a folder row. A folder opens something, so the row says so with a
  /// chevron instead of the "more" dots a file uses.
  final bool folder;
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
  NexusMockFile(
    'Downloads',
    'Folder · 6 items',
    'Today',
    Icons.folder_rounded,
    folder: true,
  ),
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
  const FilesTab({super.key, this.active = true});

  /// True while this tab is the one on screen.
  ///
  /// The tab bar keeps every page alive in an [IndexedStack], so without this
  /// the Files tab would read Documents and Downloads on launch — a disk walk
  /// for a screen the user may never open — and a widget test that pumps the
  /// shell would wait on the machine's real home folder to settle. Defaults to
  /// true so the page still works when it is mounted on its own.
  final bool active;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  /// The two folders, once they have been read. Null while the first read is
  /// in flight: an empty list and a list that has not arrived are different
  /// sentences, and the tab says which one it is looking at.
  List<LocalFolder>? _folders;

  /// Whether the first read has been asked for. Set on the first frame the tab
  /// is visible, and never cleared: going back to Home and returning shows the
  /// list it already has rather than making the disk answer again.
  bool _started = false;

  /// Set when the read itself failed. A folder's own failure travels in that
  /// folder's [LocalFolder.error], so this is only for the case where there is
  /// no folder list at all.
  String? _error;

  Future<void> _load() async {
    final List<LocalFolder> folders;
    try {
      folders = await LocalLibrary.current.read();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Nexus could not read this device ($error).');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _error = null;
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
    // The listener is cheap and the list is shared, so it is attached either
    // way: a pairing made on the Devices tab is already in the model by the
    // time this tab is opened.
    PairedDevices.instance.addListener(_onPairedChanged);
  }

  @override
  void didUpdateWidget(covariant FilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _start();
  }

  /// Starts the first read, once.
  void _start() {
    if (_started) return;
    _started = true;
    unawaited(_load());
    // The paired list is read once so the top section is about this device's
    // real relationships rather than the seed rows.
    unawaited(PairedDevices.instance.attach());
  }

  @override
  void dispose() {
    PairedDevices.instance.removeListener(_onPairedChanged);
    super.dispose();
  }

  void _onPairedChanged() {
    if (mounted) setState(() {});
  }

  /// What a tap does: pictures in the viewer, text in the preview page, and
  /// everything else through whatever app on this phone opens that kind. A
  /// file nothing can open says so rather than doing nothing.
  Future<void> _open(LocalFileEntry entry) async {
    if (entry.isImage) {
      await ImageViewerPage.open(context, entry.path, caption: entry.name);
      return;
    }
    if (entry.isText) {
      await TextFilePage.open(context, path: entry.path, name: entry.name);
      return;
    }
    final bool opened = await openLocalFile(entry.path);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('No app on this device opens ${entry.name}.'),
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final List<PairedDevice> paired = PairedDevices.instance.devices;
    final List<PairedDevice> connected = <PairedDevice>[
      for (final PairedDevice device in paired)
        if (device.isThisDevice ||
            !device.id.startsWith('example-') ||
            device.online)
          device,
    ];
    return NexusTabBody(
      title: 'Files',
      subtitle: 'On this device and the ones paired with it.',
      trailing: IconButton(
        key: const ValueKey<String>('files-refresh'),
        tooltip: 'Refresh',
        onPressed: () => unawaited(_load()),
        icon: Icon(Icons.refresh_rounded, size: 20, color: c.accent),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Connected Devices', first: true),
          for (final PairedDevice device in connected)
            _ConnectedDeviceRow(
              key: ValueKey<String>('files-device-${device.id}'),
              device: device,
            ),
          if (connected.every((PairedDevice d) => d.isThisDevice))
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Text(
                'No other device is paired yet. Pair one in Devices to browse '
                'it here.',
                style: NexusType.rowMeta(c).copyWith(height: 1.4),
              ),
            ),
          const NexusSectionLabel('Local Files'),
          if (_error != null)
            _FilesNotice(
              key: const ValueKey<String>('files-error'),
              icon: Icons.warning_amber_rounded,
              text: _error!,
            )
          else if (_folders == null && !_started)
            // Nothing has been asked of the disk yet: the tab is alive in the
            // stack but nobody is looking at it. This is not the loading
            // state — a spinner here would mean every launch paid for a disk
            // walk it never showed, and a test would wait on one.
            const SizedBox.shrink()
          else if (_folders == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            for (final LocalFolder folder in _folders!) ...<Widget>[
              _LocalFolderHeader(folder: folder),
              if (folder.error != null)
                _FilesNotice(
                  key: ValueKey<String>('files-folder-error-${folder.label}'),
                  icon: Icons.folder_off_outlined,
                  text: folder.error!,
                )
              else if (folder.entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 14),
                  child: Text(
                    'Nothing in ${folder.label} yet.',
                    style: NexusType.rowMeta(c),
                  ),
                )
              else
                for (final LocalFileEntry entry in folder.entries)
                  _LocalFileRow(
                    key: ValueKey<String>('local-file-${entry.path}'),
                    entry: entry,
                    onTap: () => unawaited(_open(entry)),
                  ),
            ],
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
            child: Text(
              'These folders stay on this device. Nothing is uploaded, and a '
              'paired device sees a file only when you send it one.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// A device at the top of Files: this phone, or a paired peer with the RAM it
/// shared. The row is a statement rather than a door — browsing a peer's disk
/// from this tab is the mesh's next feature, and a chevron would promise it now.
class _ConnectedDeviceRow extends StatelessWidget {
  const _ConnectedDeviceRow({super.key, required this.device});

  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final IconData icon = device.isThisDevice
        ? Icons.smartphone_rounded
        : (device.name.toLowerCase().contains('mac')
              ? Icons.laptop_mac_rounded
              : Icons.desktop_windows_rounded);
    final int? ram = device.ramBytes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      child: Row(
        children: <Widget>[
          NexusIconTile(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexusType.rowTitle(c),
                ),
                const SizedBox(height: 3),
                Text(
                  <String>[
                    device.isThisDevice
                        ? 'This device'
                        : (device.detail.isEmpty
                              ? 'Paired device'
                              : device.detail),
                    if (ram != null) '${DeviceMemory.label(ram)} RAM',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexusType.rowMeta(c),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          NexusStatusDot(online: device.isThisDevice || device.online),
          const SizedBox(width: 6),
          Text(
            device.isThisDevice
                ? 'This phone'
                : (device.online ? 'Online' : 'Offline'),
            style: NexusType.rowMeta(c),
          ),
        ],
      ),
    );
  }
}

/// The heading over one folder: its name, its count, and where it is.
class _LocalFolderHeader extends StatelessWidget {
  const _LocalFolderHeader({required this.folder});

  final LocalFolder folder;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              folder.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NexusType.section(c),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            folder.error != null
                ? 'Unavailable'
                : '${folder.count} ${folder.count == 1 ? 'file' : 'files'}',
            style: NexusType.rowMeta(c),
          ),
        ],
      ),
    );
  }
}

/// One real file: its kind, its name, and the size and date that tell one
/// `IMG_2026.jpg` from another.
class _LocalFileRow extends StatelessWidget {
  const _LocalFileRow({super.key, required this.entry, required this.onTap});

  final LocalFileEntry entry;
  final VoidCallback onTap;

  IconData get _icon {
    if (entry.isImage) return Icons.image_rounded;
    return switch (entry.extension) {
      'pdf' => Icons.picture_as_pdf_rounded,
      'doc' || 'docx' => Icons.description_rounded,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_rounded,
      'zip' || 'gz' || 'tar' => Icons.folder_zip_rounded,
      'mp3' || 'wav' || 'm4a' || 'ogg' => Icons.graphic_eq_rounded,
      'mp4' || 'mov' || 'mkv' => Icons.movie_rounded,
      'apk' => Icons.android_rounded,
      'md' || 'txt' || 'log' => Icons.notes_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final String when = localFileDate(entry.modified);
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(NexusLayout.tile),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: <Widget>[
            NexusIconTile(_icon, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NexusType.rowTitle(c),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    <String>[
                      localFileSize(entry.bytes),
                      if (when.isNotEmpty) when,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NexusType.rowMeta(c),
                  ),
                ],
              ),
            ),
            Icon(
              entry.isImage || entry.isText
                  ? Icons.chevron_right_rounded
                  : Icons.open_in_new_rounded,
              size: 18,
              color: c.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// One sentence where a folder or the tab would otherwise be blank.
class _FilesNotice extends StatelessWidget {
  const _FilesNotice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: NexusType.rowMeta(c).copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

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
            // A folder is a door: the chevron is the affordance that says a tap
            // goes somewhere. A file keeps the "more" dots, because a tap on it
            // opens the file rather than a list of things to do with it.
            if (file.folder)
              const NexusChevron()
            else
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

  /// Who is on this network, heard by the mesh's own discovery.
  NearbyDevices get _nearby => NearbyDevices.instance;

  /// True while the Discover button is in its listening window.
  bool _discovering = false;

  /// This device's memory, read once for the mesh total. Null until the probe
  /// answers, and null forever on a device that will not say — the total then
  /// adds up only what the peers shared rather than inventing the missing half.
  int? _localRam;

  @override
  void initState() {
    super.initState();
    _paired.addListener(_onChanged);
    _nearby.addListener(_onChanged);
    unawaited(
      DeviceMemory.totalBytes().then((int? bytes) {
        if (mounted && bytes != null) setState(() => _localRam = bytes);
      }),
    );
    // The stored list arrives asynchronously — it is a preference read — so the
    // screen corrects itself from the settled store rather than staying on the
    // seed rows. Idempotent: a second Devices tab (or a rebuild) re-reads
    // nothing.
    unawaited(_paired.attach());
    // Listening starts with the screen and stops with it: a socket announcing
    // into an empty room costs battery and answers nobody. This is also what
    // makes the Online word on a paired row true rather than remembered.
    unawaited(_nearby.start());
  }

  @override
  void dispose() {
    _paired.removeListener(_onChanged);
    _nearby.removeListener(_onChanged);
    unawaited(_nearby.stop());
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Paired rows, with presence answered by what discovery is hearing right
  /// now: a device heard in the last minute is online, whoever said otherwise
  /// when the row was written.
  List<PairedDevice> get _rows => <PairedDevice>[
    for (final PairedDevice device in _paired.devices)
      if (device.isThisDevice)
        device
      else if (_nearby.running && _nearby.device(device.id) != null)
        device.copyWith(
          online: true,
          detail: 'Seen just now at ${_nearby.device(device.id)!.address}',
        )
      else
        device,
  ];

  /// The memory on this mesh, in bytes: this device's own RAM plus every peer
  /// that shared a number. A peer that did not share is not a zero — it is a
  /// device this total cannot speak for, which is why the row also says how
  /// many devices answered.
  int? get _meshRam {
    final List<PairedDevice> devices = _rows;
    int total = _localRam ?? 0;
    int counted = _localRam == null ? 0 : 1;
    for (final PairedDevice device in devices) {
      final int? ram = device.ramBytes;
      if (device.isThisDevice || ram == null) continue;
      total += ram;
      counted++;
    }
    return counted == 0 ? null : total;
  }

  int get _meshRamDevices {
    final List<PairedDevice> devices = _rows;
    int counted = _localRam == null ? 0 : 1;
    for (final PairedDevice device in devices) {
      if (!device.isThisDevice && device.ramBytes != null) counted++;
    }
    return counted;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final List<PairedDevice> devices = _rows;
    final List<DiscoveredDevice> unpaired = <DiscoveredDevice>[
      for (final DiscoveredDevice device in _nearby.devices)
        if (!_paired.contains(device.id)) device,
    ];
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
          // The mesh's memory, in one row: what the room could run if the
          // models were chosen by the strongest device rather than by the one
          // in the user's hand.
          NexusRow(
            key: const ValueKey<String>('mesh-total-ram'),
            title: 'Mesh Total RAM',
            subtitle: _meshRam == null
                ? 'No device has shared its memory yet'
                : 'Across $_meshRamDevices '
                      '${_meshRamDevices == 1 ? 'device' : 'devices'} on this '
                      'mesh',
            leading: const NexusIconTile(Icons.memory_rounded),
            trailing: Text(
              _meshRam == null ? '—' : DeviceMemory.label(_meshRam),
              style: NexusType.rowTitle(c).copyWith(fontSize: 14),
            ),
          ),
          for (final device in devices) ...<Widget>[
            NexusRow(
              title: device.name,
              subtitle: <String>[
                device.detail.isEmpty
                    ? 'Paired directly — no account, no server'
                    : device.detail,
                if (device.ramBytes != null)
                  '${DeviceMemory.label(device.ramBytes)} RAM',
              ].join(' · '),
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
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              _discovering
                  ? 'Listening on this network for other Nexus devices…'
                  : _nearby.status,
              key: kNexusDiscoveryStatus,
              style: NexusType.rowMeta(c).copyWith(height: 1.4),
            ),
          ),
          if (unpaired.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            const NexusSectionLabel('Nearby'),
            for (final DiscoveredDevice device in unpaired) ...<Widget>[
              NexusRow(
                key: ValueKey<String>('nearby-${device.id}'),
                title: device.name,
                subtitle:
                    '${_platformWord(device.platform)} · ${device.address}'
                    '${device.port > 0 ? ':${device.port}' : ''}',
                leading: const NexusIconTile(Icons.wifi_tethering_rounded),
                accentTitle: true,
                trailing: const NexusChevron(),
                onTap: () => unawaited(_pairNearby(device)),
              ),
              Divider(height: 1, thickness: 1, color: c.hairline, indent: 56),
            ],
          ],
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
    // And out of discovery too: otherwise the next announcement re-adds the
    // same device to the Nearby section a second later, which looks exactly
    // like the Forget button having done nothing.
    _nearby.forget(device.id);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Forgot ${device.name}.'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// The button at the bottom of the list, and now the real thing: it opens the
  /// mesh's own discovery socket, listens for [kNexusDiscoverWindow], and shows
  /// what answered.
  ///
  /// The wait is a window rather than a progress fiction because discovery is a
  /// conversation: this device announces, the others announce back, and one
  /// announce cycle is three seconds — so a button that answered instantly
  /// would answer "nobody" on a network with somebody on it. What it found
  /// stays on screen afterwards as rows, not as a notice that scrolls away.
  Future<void> _discoverNearby() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    await _nearby.start();
    await Future<void>.delayed(kNexusDiscoverWindow);
    if (!mounted) return;
    setState(() => _discovering = false);
  }

  /// Pairs a device that answered discovery, with no code to scan.
  ///
  /// What is stored is what was heard: the id it announced, the name it gave,
  /// and the address the announcement came from. The row then behaves like any
  /// other paired device — it is the same list, the same store, the same way to
  /// forget it.
  Future<void> _pairNearby(DiscoveredDevice device) async {
    final bool added = _paired.add(
      PairInvite(
        deviceName: device.name,
        deviceId: device.id,
        publicKey: '',
        addresses: <String>[device.address],
        port: device.port,
      ),
    );
    // Pairing is the user asking for this device again, so a previous Forget no
    // longer keeps it out of the Nearby list.
    _nearby.remember(device.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            added
                ? 'Paired with ${device.name}'
                : '${device.name} is already paired.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// What kind of machine a row is looking at, in a word.
  static String _platformWord(String platform) => switch (platform) {
    'android' => 'Phone',
    'ios' => 'iPhone',
    'macos' => 'Mac',
    'windows' => 'Windows PC',
    'linux' => 'Linux PC',
    _ => 'Device',
  };
}

/// The line under the Discover button: what discovery is doing right now.
const Key kNexusDiscoveryStatus = Key('nexus-discovery-status');

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

/// What it says about a `nexus://pair` code this build cannot use: a v1 payload
/// that lost a field, or one whose device id is too short to be an id.
///
/// Deliberately different from [kNexusNotAPairCodeText]: the user is holding a
/// Nexus device, and telling them their own device is not one would send them
/// looking for the wrong problem.
const String kNexusLegacyPairCodeText =
    'That Nexus code is incomplete — show the code again on that device.';

/// The sentence for one scanned string: which of the three refusals it is.
///
/// One function rather than a chain inside the scanner, so the page and the
/// tests agree about the mapping — and so a code that is *nearly* ours is never
/// described with the words for a tourist's QR code.
String nexusPairRefusal(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.startsWith('nexus://pair')) {
    return QrPairingToken.parse(trimmed) != null
        ? kNexusLivePairCodeText
        : kNexusLegacyPairCodeText;
  }
  return kNexusNotAPairCodeText;
}

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
class PairQrPage extends StatefulWidget {
  const PairQrPage({super.key, this.identity, this.addresses});

  /// Who this device is. Null uses [PairIdentity.current]; a test states it, so
  /// the QR it asserts on is not a random id.
  final PairIdentity? identity;

  /// Where this device can be reached. Null reads the real interfaces
  /// ([localAddresses]); a test states them, because a widget test host's
  /// interfaces are not the device's.
  final Future<List<String>> Function()? addresses;

  @override
  State<PairQrPage> createState() => PairQrPageState();
}

class PairQrPageState extends State<PairQrPage> {
  /// The addresses read when the page opened, empty until they arrive.
  List<String> _addresses = const <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_readAddresses());
  }

  Future<void> _readAddresses() async {
    final List<String> found = await (widget.addresses ?? localAddresses)();
    if (!mounted) return;
    setState(() => _addresses = found);
  }

  /// The exact string the QR currently carries — the identity, plus the
  /// addresses once they are known. A test reads this rather than poking at the
  /// image, because `QrImageView` keeps its data private.
  String get currentPayload => payloadFor(_addresses);

  /// The payload with [addresses] in it. The two halves are one decision: the
  /// other device needs to know *who* this is (id, name, key) and *where* it is
  /// (the address it just looked up), and a code carrying only the first would
  /// pair a device nobody could dial.
  String payloadFor(List<String> addresses) =>
      (widget.identity ?? PairIdentity.current)
          .withAddresses(addresses)
          .invite
          .encode();

  /// The identity half of the code, without addresses — what the page can say
  /// before the interface list comes back, and what an older `nexus_pair` code
  /// carried.
  String get payload =>
      (widget.identity ?? PairIdentity.current).invite.encode();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final PairIdentity who = widget.identity ?? PairIdentity.current;
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
                  data: currentPayload,
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
                      _addresses.isEmpty
                          ? 'This device · ${who.id.substring(0, 6)}…'
                          : 'Reachable at ${_addresses.first}',
                      key: kNexusQrAddressLine,
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

/// The line under the QR's own name: the address the code now carries.
const Key kNexusQrAddressLine = Key('nexus-qr-address');

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

  /// One scanned string: a code this build can pair with, or a sentence about
  /// why not.
  ///
  /// Both formats in the world are read here — this shell's own `nexus_pair`
  /// code and the mesh's `nexus://pair` URI, which carries the device id, its
  /// name and the address it can be reached at. Both end as the same invite, so
  /// there is exactly one place a scanned device enters the paired list.
  void _onCode(String raw) {
    final PairInvite? invite = PairInvite.fromAnyCode(raw);
    if (invite != null) {
      Navigator.of(context).pop(invite);
      return;
    }
    _showNotice(nexusPairRefusal(raw));
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
                      style: NexusType.rowMeta(c).copyWith(color: Colors.white),
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
  /// Whether this device can run a model of its own at all.
  ///
  /// Answered by [DeviceCapabilities], so the decision is one line here and
  /// the same line on every other screen: a device that cannot load the weights
  /// is not offered them. What changes on such a device is the *section* — the
  /// status row stays, because "where do the answers come from" is still a
  /// question with a real answer (the PC, or nothing), and the download and
  /// delete rows are replaced by one sentence naming the way out.
  bool get _onDeviceSupported =>
      DeviceCapabilities.current.supportsOnDeviceAi();

  /// What the status row says: the whole answer, in one line.
  ///
  /// It used to be split — a short word on the right ("On-Device (Loaded)")
  /// and an explanation beneath it. That named the engine and never the model,
  /// so the one fact a user needs to judge an answer (a 0.5B model, not a
  /// frontier one) was the one the row withheld. The label now names it, and
  /// [AiStatus.detail] stays for the places with room for a second line.
  ///
  /// [AiStatus] is written for a device that could download the model, and its
  /// "none" case points at the download row below. On a device that has no such
  /// row, the same words would be an instruction the user cannot follow, so that
  /// one sentence is overridden here.
  String get _aiLabel {
    final AiStatus? status = _aiStatus;
    if (status == null) return 'Checking where the answers come from…';
    if (!_onDeviceSupported && status.source == AiSource.none) {
      return 'No AI: Start Ollama on your PC.';
    }
    return status.label;
  }

  /// Whether anything in the Voice section can be switched on this device. The
  /// wake word is Android-only (openWakeWord over ONNX Runtime) and spoken
  /// replies are the platform's own TTS, wired up for Android here; a device
  /// with neither gets no Voice section rather than a screen of dead switches.
  bool get _voiceSupported =>
      DeviceCapabilities.current.supportsWakeWord ||
      DeviceCapabilities.current.supportsSpokenReplies;

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
  Map<OnDeviceModelChoice, bool> _present = const <OnDeviceModelChoice, bool>{};

  /// The selection itself, shared with the brain — not a copy of it. A switch
  /// made here is what the next question loads.
  late final ModelChoice _choice = ModelChoice.instance;

  /// The model the rows below the picker are about: the selected one.
  OnDeviceModel get _selectedModel =>
      _onDevice.model.withChoice(_choice.choice);

  /// True from the tap on the appearance switch until the frame that paints the
  /// new theme. The switch becomes a small spinner for that window.
  ///
  /// No artificial delay: on a phone the swap is usually inside one frame and
  /// the spinner is gone before it can be seen, which is the correct cost — the
  /// indicator earns its place on the slow case (a long thread being re-laid out
  /// under a new theme) rather than by being a tax on the fast one.
  bool _themeBusy = false;

  /// The scroll position, either the shell's or this screen's own.
  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();

  /// Seven taps on the version row toggle the hidden Developer Logs tab: the
  /// first seven open it, the next seven hide it again. The counter resets after
  /// a few seconds so a slow reader does not unlock it by opening About seven
  /// times over a week.
  ///
  /// It is a toggle rather than one-way because the tab is reached by accident
  /// as well as on purpose: a user tapping an About row out of curiosity should
  /// be able to put the screen back where they found it.
  int _versionTaps = 0;
  Timer? _versionTapReset;

  void _versionTapped() {
    _versionTapReset?.cancel();
    _versionTapReset = Timer(const Duration(seconds: 3), () {
      _versionTaps = 0;
    });
    _versionTaps++;
    if (_versionTaps < 7) return;
    _versionTaps = 0;
    _versionTapReset?.cancel();
    final bool unlocking = !LogService.instance.developerUnlocked;
    unawaited(LogService.instance.setDeveloperMode(unlocking));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: ValueKey<String>(
            unlocking ? 'developer-mode-unlocked' : 'developer-mode-locked',
          ),
          content: Text(
            unlocking ? 'Developer Mode Unlocked!' : 'Developer Mode Locked',
          ),
        ),
      );
  }

  @override
  void dispose() {
    _versionTapReset?.cancel();
    _choice.removeListener(_onModelChoiceChanged);
    // Only a controller this state made is this state's to free; the shell's
    // outlives the tab it lent it to.
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Freed ${_megabytes(freed)} MB.')));
    await _refreshBrain();
  }

  static int _megabytes(int bytes) =>
      (bytes + 1024 * 1024 - 1) ~/ (1024 * 1024);

  /// True while a release check is in flight, so a second tap cannot start a
  /// second request or stack two dialogs.
  bool _checkingUpdate = false;

  /// The Cloud sync row has nothing to switch — there is no cloud — but it is
  /// still a row, and a tap anywhere on it is answered by the promise it makes.
  void _showCloudOffNote() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'No account, no server copy — your chats and memory stay on this '
            'device.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
  }

  /// Asks GitHub for the latest release, compares it with the installed
  /// package's version, and then says one of three things: install it, you are
  /// up to date, or the check itself could not be made.
  ///
  /// The version comes from `package_info_plus`, not from the `appVersion`
  /// constant: the installed package is the only thing that can prove what is
  /// running, and a forgotten constant is exactly how an app once offered users
  /// the build they already had.
  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final String current = await installedAppVersion();
    final UpdateCheck check = await Updater.checkForUpdate(
      currentVersion: current,
    );
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    final UpdateInfo? info = check.info;
    if (info == null) {
      final String? failure = check.failure;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              failure == null
                  ? 'Nexus is up to date!'
                  : 'Could not check for updates — $failure',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      return;
    }

    await showNexusUpdateDialog(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusTabBody(
      title: 'Settings',
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: <Widget>[
          const NexusSectionLabel('Theme', first: true),
          NexusRow(
            title: 'Follow system',
            subtitle: 'Use your phone’s light and dark setting',
            leading: const NexusIconTile(Icons.brightness_auto_outlined),
            trailing: Switch(
              value: widget.followSystem,
              onChanged: (bool value) =>
                  widget.onFollowSystemChanged?.call(value),
            ),
            // The whole row is the control, not just the switch: a thumb that
            // lands on the label is asking for the same thing.
            onTap: () =>
                widget.onFollowSystemChanged?.call(!widget.followSystem),
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
                // Greyed out as well as disabled: `onChanged: null` alone leaves
                // a Material switch looking almost normal, and an enabled-looking
                // control that ignores taps is the definition of "broken". The
                // opacity is the visible statement that the row above owns this.
                : Opacity(
                    key: kNexusDarkModeLocked,
                    opacity: widget.followSystem ? 0.38 : 1,
                    child: Switch(
                      value: widget.darkMode,
                      // While the phone is in charge, the switch reports what the
                      // phone decided and cannot be overridden from here: an
                      // enabled switch that bounced straight back would look
                      // broken, and the row above it is the one that has to move.
                      onChanged: widget.followSystem ? null : _toggleDark,
                    ),
                  ),
            onTap: widget.followSystem || _themeBusy
                ? null
                : () => unawaited(_toggleDark(!widget.darkMode)),
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
              subtitle: 'Replies, language, and microphone privacy',
              leading: const NexusIconTile(Icons.graphic_eq_outlined),
              trailing: const NexusChevron(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (routeContext) => const _VoiceSettingsPage(),
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
            onTap: _showCloudOffNote,
          ),
          // Where the words come from, and the one row that can change it. The
          // status is a value, not a switch: there is nothing to turn on — the
          // app asks the device and then the PC on its own — and the only
          // choice the user has is whether the 470 MB lives on this phone.
          const NexusSectionLabel('Brain'),
          NexusRow(
            title: 'AI status',
            subtitle: _aiLabel,
            semanticLabel: _aiStatus == null
                ? null
                : 'AI status. $_aiLabel Tap to check again.',
            leading: const NexusIconTile(Icons.memory_rounded),
            // Looking again is the only action this row has, and it is worth
            // one: a PC started after the app did is exactly what the refresh
            // is for. The whole row is the target.
            onTap: () => unawaited(_refreshBrain()),
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
                // The row that reports a failure is also the retry: there is
                // nothing else to press, and making the user find the download
                // row again after an error is a second failure.
                onTap: _downloadModel,
              ),
          ],
          // The one piece of the system turn the user owns. It is not a chat
          // message and it is not memory: a name or a language asked for here
          // applies to every answer, including the first one after a restart.
          const _SystemPromptField(),
          const NexusSectionLabel('About'),
          NexusRow(
            title: kNexusCheckUpdatesRow,
            subtitle: _checkingUpdate
                ? 'Checking GitHub for the latest release…'
                : 'Download the newest version from GitHub',
            leading: const NexusIconTile(Icons.system_update_alt_rounded),
            // No chevron: this row does not open anything. A chevron that only
            // starts a network request reads as a page the tap failed to open.
            // The spinner is the row's whole answer, and the snack bar after it
            // says what the check found.
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _checkForUpdates,
          ),
          // The build's own name, not a description of what is not wired yet:
          // the row used to read "UI shell preview — no model attached" while
          // the model was answering questions, which is the kind of line a user
          // reads once and then trusts.
          NexusRow(
            key: const ValueKey<String>('app-version-row'),
            title: 'Version',
            subtitle:
                'Nexus $appVersion — on-device answers, no account, no cloud',
            leading: const NexusIconTile(Icons.info_outline_rounded),
            trailing: Text(appVersion, style: NexusType.rowMeta(c)),
            onTap: _versionTapped,
          ),
        ],
      ),
    );
  }
}

/// The custom system prompt, in place under the Brain status row.
///
/// A real field rather than a dialog behind a row: the instruction is short,
/// the user wants to reread it while editing it, and a setting that describes
/// every answer should be visible where the answer's source is described. The
/// write is per keystroke and deliberately not awaited; a preference write must
/// never make typing wait.
class _SystemPromptField extends StatefulWidget {
  const _SystemPromptField();

  @override
  State<_SystemPromptField> createState() => _SystemPromptFieldState();
}

class _SystemPromptFieldState extends State<_SystemPromptField> {
  late final SystemPrompt _prompt = SystemPrompt.instance;
  late final TextEditingController _controller = TextEditingController(
    text: _prompt.text,
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      _prompt.attach().then((_) {
        if (!mounted) return;
        if (_controller.text.trim().isEmpty && _prompt.text.isNotEmpty) {
          _controller.text = _prompt.text;
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
        }
        setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const NexusIconTile(Icons.edit_note_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('System prompt', style: NexusType.rowTitle(c)),
                    const SizedBox(height: 3),
                    Text(
                      'Applies to every chat. Example: “The user’s name is '
                      'TVCraft. Always answer in French.”',
                      style: NexusType.rowMeta(c),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('nexus-system-prompt'),
            controller: _controller,
            minLines: 2,
            maxLines: 5,
            maxLength: kSystemPromptLimit,
            textCapitalization: TextCapitalization.sentences,
            style: NexusType.rowTitle(c)
                .copyWith(fontSize: 14, fontWeight: FontWeight.w400),
            decoration: InputDecoration(
              hintText: 'Custom instructions for Nexus',
              hintStyle: NexusType.hint(c).copyWith(fontSize: 14),
              filled: true,
              fillColor: c.surface,
              counterStyle: NexusType.rowMeta(c).copyWith(fontSize: 10.5),
              enabledBorder: OutlineInputBorder(
                borderRadius: const BorderRadius.all(NexusLayout.tile),
                borderSide: BorderSide(color: c.hairline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: const BorderRadius.all(NexusLayout.tile),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
            onChanged: _prompt.setTextSoon,
          ),
          const SizedBox(height: 8),
          // Honest expectations. The 1B on the A25 followed a name but ignored
          // "answer in French", and a field that promises more than the model
          // can do is a field the user blames themselves for. The example is
          // deliberately a short fact rather than an instruction.
          Text(
            'Note: Small on-device models may ignore complex instructions. '
            'For best results, keep it brief (e.g., \'My name is TVCraft\').',
            key: const Key('nexus-system-prompt-note'),
            style: NexusType.rowMeta(c).copyWith(height: 1.45),
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
                    Text('Downloading $label', style: NexusType.rowTitle(c)),
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
class _VoiceSettingsPage extends StatefulWidget {
  const _VoiceSettingsPage();

  @override
  State<_VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends State<_VoiceSettingsPage> {
  late final VoiceSettings _voice = VoiceSettings.instance;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChanged);
    unawaited(
      _voice.attach().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Voice & speech')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          // No wake-word row at all: the engine needs a foreground service
          // this build does not run, so the row was a permanently dead switch
          // — a control that promises an always-on microphone and then does
          // nothing. "Speak replies" moved to the composer, where it is one tap
          // from the conversation it changes.
          const _LanguageRow(),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
            child: Text(
              'Speech is recognized on this device when your language pack is '
              'available. Otherwise your phone’s system recognizer handles it, '
              'which may use the network.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The language dropdown, and the row that explains what it changes.
///
/// One setting for both halves of voice on purpose: a transcript in French
/// answered by an English voice is not a choice anybody made. The value is
/// applied through [VoiceSettings], which updates the recognizer and the TTS
/// engine and stores the tag.
class _LanguageRow extends StatefulWidget {
  const _LanguageRow();

  @override
  State<_LanguageRow> createState() => _LanguageRowState();
}

class _LanguageRowState extends State<_LanguageRow> {
  late final VoiceSettings _voice = VoiceSettings.instance;

  @override
  void initState() {
    super.initState();
    // The setting is a ChangeNotifier: it changes itself when a language is
    // chosen, so the row listens rather than assuming the next build will
    // come along. Without this the dropdown kept drawing the old language
    // until the page was reopened — the choice worked and looked ignored.
    _voice.addListener(_onVoiceChanged);
    unawaited(
      _voice.attach().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    super.dispose();
  }

  Future<void> _pickLanguage() async {
    final String? tag = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.ui.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        final c = sheetContext.ui;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('Language', style: NexusType.rowTitle(c)),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: Icon(Icons.close_rounded, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    key: const Key('nexus-voice-language-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: kVoiceLanguages.length,
                    itemBuilder: (BuildContext context, int index) {
                      final VoiceLanguage language = kVoiceLanguages[index];
                      final bool selected = language.tag == _voice.language;
                      return ListTile(
                        key: ValueKey<String>('voice-language-${language.tag}'),
                        title: Text(
                          language.label,
                          style: NexusType.rowTitle(c).copyWith(fontSize: 14),
                        ),
                        subtitle: Text(language.tag),
                        trailing: selected
                            ? Icon(
                                Icons.check_rounded,
                                size: 20,
                                color: c.accent,
                              )
                            : null,
                        onTap: () =>
                            Navigator.of(sheetContext).pop(language.tag),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (tag == null) return;
    await _voice.setLanguage(tag);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusRow(
      key: const Key('nexus-voice-language'),
      title: 'Language',
      subtitle: 'Used for both listening and speaking',
      leading: const NexusIconTile(Icons.translate_rounded),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            _voice.choice.label,
            style: NexusType.rowMeta(c).copyWith(color: c.textStrong),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more_rounded, color: c.textMuted),
        ],
      ),
      onTap: _pickLanguage,
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
/// The one destructive row in Privacy. Keyed because the test that proves the
/// wipe happens has to reach the same control a thumb does.
const Key kNexusDeleteAllData = Key('nexus-delete-all-data');
const String kNexusDeleteAllDataRow = 'Delete All Memory & Chats';
const String kNexusDeleteAllDataTitle = 'Delete All Memory & Chats?';

class PrivacyPage extends StatefulWidget {
  const PrivacyPage({super.key});

  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

/// The whole privacy promise, on one screen: the text the Privacy page has
/// been pointing at since it shipped with a placeholder link.
///
/// A paragraph rather than a list of rows, because this is the one place the
/// app makes a claim about itself, and a claim broken into rows reads as a
/// feature list. One copy of the wording, [policy], so the page and any test
/// cannot drift apart.
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const String policy =
      'Nexus is a local-first application. No data, audio, or images ever '
      'leave your device unless you explicitly send them to your PC. Your AI '
      'models run locally on your device. No accounts, no cloud, no telemetry.';

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: <Widget>[
          Text(
            'What Nexus does with your data — and what it never does.',
            style: NexusType.rowMeta(c).copyWith(fontSize: 13.5, height: 1.5),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: c.hairline),
            ),
            child: Text(
              policy,
              style: NexusType.rowTitle(c).copyWith(height: 1.55),
            ),
          ),
          const SizedBox(height: 24),
          const NexusSectionLabel('In practice'),
          const SizedBox(height: 8),
          for (final (IconData icon, String title, String detail) in [
            (
              Icons.wifi_off_rounded,
              'Works offline',
              'Answers come from the model on this phone.',
            ),
            (
              Icons.person_off_outlined,
              'No account',
              'There is nothing to sign in to, and nothing to sign up for.',
            ),
            (
              Icons.share_outlined,
              'You choose what leaves',
              'Only a file or message you send to a paired device moves.',
            ),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, size: 20, color: c.textMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(title, style: NexusType.rowTitle(c)),
                        const SizedBox(height: 2),
                        Text(detail, style: NexusType.rowMeta(c)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PrivacyPageState extends State<PrivacyPage> {
  bool _busy = false;

  /// Asks, then deletes every copy this app kept on the device: the remembered
  /// facts file, every chat session, the attachments copied out of the camera
  /// and picker, and the old single-thread key. The dialog is the whole safety
  /// net — there is no backup anywhere to restore from.
  Future<void> _confirmDeleteAll() async {
    if (_busy) return;
    await ChatLog.instance.attach();
    await MemoryService.instance.attach();
    if (!mounted) return;
    final int chats = ChatLog.instance.sessionCount;
    final int facts = MemoryService.instance.length;
    String plural(int n, String one, String many) => n == 1 ? one : many;
    final bool confirmed = await showNexusConfirm(
      context,
      title: kNexusDeleteAllDataTitle,
      message:
          'This deletes $chats ${plural(chats, 'chat', 'chats')}, '
          '$facts remembered ${plural(facts, 'fact', 'facts')}, and every '
          'attached picture or file on this device. Nothing was uploaded, and '
          'nothing can be recovered.',
      confirmLabel: 'Delete everything',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    await MemoryService.instance.clear();
    await ChatLog.instance.clearAll();
    await AttachmentStore.instance.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Memory, chats and attachments deleted.'),
          duration: Duration(seconds: 2),
        ),
      );
  }

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
            'Chats, remembered facts and attachments live in Nexus\'s own '
            'app folder. Nothing is uploaded, and uninstalling the app deletes '
            'all of it.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          const NexusSectionLabel('Your data'),
          NexusRow(
            key: kNexusDeleteAllData,
            title: kNexusDeleteAllDataRow,
            subtitle: _busy
                ? 'Deleting…'
                : 'Erase every chat, remembered fact and attachment',
            leading: const NexusIconTile(Icons.delete_forever_outlined),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const NexusChevron(),
            dangerTitle: true,
            onTap: _busy ? null : _confirmDeleteAll,
          ),
          const SizedBox(height: 12),
          NexusRow(
            title: 'Privacy Policy',
            subtitle: 'The full promise, in one page',
            leading: const NexusIconTile(Icons.policy_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const PrivacyPolicyPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
