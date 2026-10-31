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
import 'dart:io' show File, Platform, Process, ProcessResult;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        defaultTargetPlatform,
        kIsWeb,
        kReleaseMode,
        listEquals,
        visibleForTesting;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/gestures.dart' show LongPressGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_localizations/flutter_localizations.dart';
// The colour wheel in Settings → Theme. A package rather than a hand-rolled
// wheel for the obvious reason: a wheel that is nearly a colour space is worse
// than no wheel, and this one is the HSV wheel with the hex bar under it.
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    show ColorPicker, ColorLabelType, PaletteType;
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:file_selector/file_selector.dart' show openFile;
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:url_launcher/url_launcher.dart';

import 'core/action_audit.dart';
import 'core/ai_status.dart';
import 'core/appearance.dart';
import 'core/connections.dart';
import 'core/artifacts.dart';
import 'core/attachment_pickers.dart';
import 'core/attachments.dart';
import 'core/capability.dart' show capabilityFor, defaultCapabilitiesFor;
import 'core/chat_log.dart';
import 'core/clock_context.dart' show isClockQuestion;
import 'core/command_interpreter.dart'
    show CommandInterpreter, InterpretOutcome, InterpretResult;
import 'core/composer_settings.dart';
import 'core/interaction_mode.dart';
import 'core/device_capabilities.dart';
import 'core/device_memory.dart';
import 'core/fast_path.dart';
import 'core/file_link.dart';
import 'core/llama_cpp_backend.dart';
import 'core/local_ai_service.dart';
import 'core/local_library.dart';
import 'core/log_service.dart';
import 'core/memory_service.dart';
import 'core/math_helper.dart';
import 'core/mic_access.dart';
import 'core/vision_ai_service.dart';
import 'core/model_capabilities.dart';
import 'core/ollama_service.dart';
import 'core/on_device_ai_service.dart';
import 'core/on_device_model.dart';
import 'core/notification_sync.dart';
import 'core/onboarding.dart';
// Hidden rather than shown name by name: this file needs the whole library —
// the status words are an extension, and an extension comes with the import
// rather than with a `show` list. `DeviceCapabilities` is the one name that
// exists in both this and `device_capabilities.dart`, and hiding it is what
// keeps the other import unambiguous.
import 'core/agent_contract.dart' hide DeviceCapabilities;
import 'core/app_services.dart';
import 'core/device_actions.dart' show ActionResult, DeviceActionBackend;
import 'core/phone_actions.dart' show PhoneActionBackend;
import 'core/store.dart' show AgentPolicy, ControlPath;
import 'core/pair_bridge.dart';
import 'core/pair_invite.dart';
import 'core/pair_token.dart';
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
import 'mesh/file_transfer_service.dart'
    show
        FileTransferService,
        NexusPing,
        NexusRequestResult,
        ReceivedFile,
        kFileTransferPort;
import 'mesh/mesh_lifecycle.dart' show MeshLifecycleObserver;
import 'mesh/mesh_service.dart'
    show
        AdoptedSetting,
        ClipEntry,
        IncomingAgentAction,
        MeshService,
        PairResult,
        PairingSession;

// The thought splitter moved to `core` so the chat log can use it when it
// reads an old answer; this export keeps every existing importer of the shell
// (tests included) compiling without a second name for the same thing.
export 'core/thought.dart' show NexusThoughtSplit, splitNexusThought;
import 'mesh/nearby.dart' show NearbyDevices;
import 'core/version.dart';
import 'ui/artifact_page.dart';
import 'ui/device_executor.dart' show DeviceExecutor;
import 'ui/image_viewer_page.dart';
import 'ui/local_files.dart' show openLocalFile;
import 'ui/privacy_policy_view.dart' show PrivacyPolicyView;
import 'ui/remote_files_page.dart' show RemoteFilesPage;
import 'ui/server_agent_page.dart';
import 'ui/text_file_page.dart';
import 'ui/trackpad_page.dart';
import 'core/shared_settings.dart';
import 'core/speech.dart';
import 'core/system_actions.dart';
import 'mesh/updater.dart';

// The shell's screens, split into part files: one library (so the private
// helpers stay private) with a file per screen for editing and review.
part 'ui/chat_bubbles.dart';
part 'ui/clipboard_banner.dart';
part 'ui/composer.dart';
part 'ui/connections_view.dart';
part 'ui/home_tab.dart';
part 'ui/live_mode_page.dart';
part 'ui/setting_share.dart';
part 'ui/settings_tab.dart';

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

/// The window height below which there is no room for chrome beside a keyboard.
///
/// Measured, not chosen: a phone in landscape is about 390dp tall, its keyboard
/// takes roughly 250 of those, and the body that is left — around 140dp — is
/// smaller than the sidebar (280dp) and barely fits the composer. So below this
/// height the things that are not the conversation (the sidebar, Home's header,
/// the advice banners) stand down while the keyboard is open, and the field the
/// user is typing into stays on screen.
///
/// 520 is a first cut derived from that measurement. It is the kind of number
/// that should eventually come from the content's own minimum heights rather
/// than from a constant; until then it is pinned from both sides by the
/// boundary tests in `test/main_ui_test.dart` (700x500 with and without the
/// keyboard), so it cannot drift by accident.
const double kNexusShortHeight = 520;

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
    bubbleMine: Color(0xFFF4F4F4),
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
    bubbleMine: Color(0xFF2C2C2E),
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
/// True when this process is the desktop app rather than the phone one.
///
/// The runner folders exist for Linux and Windows, and those two platforms get
/// the two-pane frame whatever size their window is: a desktop window the user
/// drags narrow is still a desktop window, and swapping it into the phone's
/// tab bar would hide the history that has room beside the chat.
///
/// The `FLUTTER_TEST` guard is deliberate. `flutter test` runs on Linux, so a
/// pure `Platform.isLinux` check would turn every existing phone-layout widget
/// test into the desktop frame. The test runner sets that variable; the app
/// does not.
bool get nexusIsDesktopApp {
  if (kIsWeb) return false;
  if ((Platform.environment['FLUTTER_TEST'] ?? 'false') != 'false') {
    return false;
  }
  return Platform.isLinux || Platform.isWindows;
}

abstract final class NexusLayout {
  /// Widest the content column ever gets. The phone layout is unaffected; a
  /// desktop window stops stretching the list rows into a ruler.
  static const double content = 560;

  /// Height of the tab bar's icon+label strip, above the safe area.
  static const double tabBar = 56;

  /// The edge every scrolling page list keeps from the screen: Files,
  /// Devices, Settings and the composer all line up on it.
  static const double gutter = 16;

  /// The edge the page header and the conversation keep. Slightly wider than
  /// the list gutter because both are read rather than scanned.
  static const double pageGutter = 20;

  /// One glyph size for row icons and inline controls. A row's tile draws its
  /// icon at this size whatever the tile's diameter, so 38- and 40-point tiles
  /// cannot produce two different-looking glyphs.
  static const double icon = 20;

  /// The glyph inside a primary round control. One step larger than a row's
  /// icon because the control around it is one step larger.
  static const double iconLarge = 24;

  /// The diameter of the composer's primary circle (mic, send, live). One
  /// size for the three of them: the button changes glyph, not footprint.
  static const double button = 44;

  /// The one corner radius family: pills, sheets and tiles all come from it.
  static const Radius pill = Radius.circular(26);
  static const Radius card = Radius.circular(16);
  static const Radius tile = Radius.circular(12);
  static const Radius bubble = Radius.circular(22);
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

  /// A message bubble's text. 1.4 is the one line height every block of
  /// running prose in the shell uses; a bubble and a lede must not disagree
  /// about it for no reason.
  static TextStyle bubble(NexusUiColors c) => GoogleFonts.inter(
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    height: 1.4,
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

/// What the model is told this device remembers, at the moment it is asked.
///
/// A function rather than a captured string because the `+` sheet's Memory
/// switch has to change the *next* answer, not the next launch: the switch is
/// consulted here, and off answers the empty string instead of a flag the
/// model would have to interpret.
@visibleForTesting
String nexusMemoryContext() => ComposerSettings.instance.memoryEnabled
    ? MemoryService.instance.systemContext
    : '';

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
  // platform model it cannot run. The vision model is asked for by file, and
  // answers with ML Kit when it is not there — so the factory is one line that
  // covers both cases, and the download (or its absence) decides at runtime.
  VisionAiService.defaultFactory = VlmVisionService.new;
  OnDeviceAiService.defaultBackendFactory = LlamaCppBackend.new;
  // Read once at launch so the first photo does not pay for the check, and so
  // Settings can say which pair of eyes this device has without a disk read of
  // its own. Two file checks, no weights touched.
  unawaited(VlmVisionService.instance.refresh());
  // Memory is a file read and a preference read, and both are needed before
  // the first answer rather than before the first frame. Started here, awaited
  // by the services on their first use if they are not ready yet.
  // The `+` sheet's switches are read at the moment the model is asked, not
  // when the closure is installed: turning Memory off must change the very
  // next answer, without a restart.
  LocalAiService.memoryContext = nexusMemoryContext;
  LocalAiService.customInstructions = () {
    final String custom = SystemPrompt.instance.context;
    // The first-run mode is a style instruction, appended after whatever the
    // user wrote themselves: their words win, and this only fills in how to
    // say it.
    final String style = InteractionModeSetting.instance.effective.instruction;
    return custom.trim().isEmpty ? style : '$custom\n\n$style';
  };
  unawaited(ComposerSettings.instance.attach());
  // Read at launch, not only when the Connections page opens: a revoked
  // connector must stay revoked in the executor's eyes from the first sentence
  // after a restart, and the executor asks this synchronously.
  unawaited(Connections.instance.attach());
  unawaited(InteractionModeSetting.instance.attach());
  unawaited(MemoryService.instance.attach());
  unawaited(SystemPrompt.instance.attach());
  unawaited(VoiceSettings.instance.attach());
  unawaited(ModelChoice.instance.ensureLoaded());
  // The mesh, the store and this device's identity, in that order of
  // consequence: the mesh binds TCP 51820 before the file link starts, which
  // is what lets the link take 51821 on this build and 51820 where nothing has
  // the port (see `FileTransferService.start`). It also installs the stored
  // id into `PairIdentity`, so the QR and the announcements agree from the
  // first frame.
  final AppServices services = await startAppServices();
  // The paired list is read before anything can ask about it: the file link's
  // control endpoints consult it to decide whether an unsigned ping comes from
  // a device this shell knows, and a list that is still only the seed rows
  // would refuse a real peer until somebody opened the Devices tab.
  await PairedDevices.instance.attach();
  // How the file listener names — and therefore whether it trusts — a control
  // request that carries no signature. Both lists, because a device can be
  // paired into either: the shell's row from a scan, or the mesh's record from
  // a pairing made on the other side. The name returned here is the one the
  // notification shows, never the name the request claimed.
  FileTransferService.instance.peerNameLookup = (String id) {
    for (final PairedDevice device in PairedDevices.instance.devices) {
      if (device.id == id) return device.name;
    }
    for (final peer in services.mesh.pairedDevices) {
      if (peer.id == id) return peer.name;
    }
    return null;
  };
  // The key a mesh-paired peer signs its control requests with. Both sides
  // derive it from the pairing secret they already share, so nothing is sent
  // to arrange it and the transfer token never leaves this device. Null for a
  // peer the mesh has never paired — those rows keep the token rule.
  FileTransferService.instance.peerControlKeyLookup =
      services.mesh.controlKeyFor;
  // What an accepted control request is labelled with, and the per-path count
  // that says which proof is still doing real work on a shipped build. Three
  // paths, three deletion criteria; see `NexusStore.controlPathSeen`.
  FileTransferService.instance.peerVersionLookup = services.mesh.peerAppVersion;
  FileTransferService.instance.onControl =
      (ControlPath path, String id, String name, String version) {
        services.store.noteControlPath(path, id, name, version);
        unawaited(services.store.save());
      };
  // The file listener opens with the app, not with the Send sheet: a phone
  // that has to be looked at before it can receive is a phone that misses the
  // file somebody just sent it. The same object is the send transport, so the
  // sheet and the listener agree about tokens and ports by construction.
  FileLink.transport = FileTransferService.instance;
  unawaited(FileTransferService.instance.start());
  final int? seed = await Appearance.accentSeed();
  // Read here with the accent, and for the same reason: an app that opens
  // light and swaps to dark after the engine starts is a flash of the wrong
  // half of the day on every launch.
  final ({bool followSystem, bool dark}) theme = await Appearance.theme();
  runApp(
    NexusUiApp(
      initialAccent: accentFromSeed(seed),
      initialFollowSystem: theme.followSystem,
      initialDark: theme.dark,
      services: services,
    ),
  );
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

/// The action runner the launched shell owns and hands down.
///
/// `DeviceExecutor` is what actually does something on this device — opens an
/// app, sets a timer, dials, plays — and until this existed it was constructed
/// nowhere on the launched path: the shipped assistant reaches its actions
/// through the model's JSON and [SystemActionCall], while every `AgentRequest`
/// that arrives from a peer had no runner at all. One instance, built with the
/// mesh it fetches files through, so a peer's request and a typed one land in
/// the same place rather than in two classes that could disagree about what
/// this device can do.
///
/// Null when the shell was built without services — every widget test — which
/// is also the honest answer for a shell that has nothing to run requests for.
/// The backends are injectable for the same reason the executor's own tests
/// inject them: a test states which platform it is.
@visibleForTesting
DeviceExecutor? launchedExecutor(
  AppServices? services, {
  DeviceActionBackend? deviceBackend,
  PhoneActionBackend? phoneBackend,
}) => services == null
    ? null
    : DeviceExecutor(
        fileMesh: services.mesh,
        deviceBackend: deviceBackend,
        phoneBackend: phoneBackend,
      );

/// What a peer is told when this device refuses an action by policy.
///
/// One string, pinned by a test, because it is the whole of what the other
/// person sees: it has to name the reason without implying they did something
/// wrong, and it has to be the same sentence in the reply and on this screen.
const String kNexusPeerActionDenied =
    'This device does not accept that action from paired peers.';

/// What the shell does with an action a peer asked for.
///
/// [runNow] is the only one that acts without a person watching, which is why
/// it is derived from two facts and nothing else — see [decidePeerAction].
enum PeerActionDecision { runNow, ask, refuse }

/// The decision, from the policy the user set and whether the frame proved
/// itself.
///
/// The 'auto' case is the one worth stating in code rather than in a comment:
/// a pre-approval is a promise the user made about a *specific* peer ("Kit may
/// play music here"), so it is only spent on a frame that proved it came from
/// that peer. Anything else — no signature, an unknown id, a pairing this
/// session never exchanged a frame with — is asked about, never run. Failing
/// towards the person is the right direction for that doubt.
@visibleForTesting
PeerActionDecision decidePeerAction({
  required AgentPolicy policy,
  required bool trusted,
}) => switch (policy) {
  AgentPolicy.deny => PeerActionDecision.refuse,
  AgentPolicy.auto when trusted => PeerActionDecision.runNow,
  AgentPolicy.auto || AgentPolicy.ask => PeerActionDecision.ask,
};

/// The shell app. Holds what outlives a tab — appearance and accent — because
/// the Settings tab changes them and the whole frame has to follow.
///
/// Appearance follows the phone until the user says otherwise: [ThemeMode]
/// .system is the default, so a phone that switches to dark at sunset takes the
/// app with it, and the manual switch is an override rather than a requirement.
/// The override is deliberately all-or-nothing (dark or light, not a third
/// "system" switch position) because the row above it is the one that decides.
class NexusUiApp extends StatefulWidget {
  const NexusUiApp({
    super.key,
    this.initialAccent,
    this.initialFollowSystem = true,
    this.initialDark = false,
    this.services,
  });

  /// The accent to open with, read from the preference before the first frame.
  /// Null is a test that does not care, and starts on the shipped purple.
  final NexusAccent? initialAccent;

  /// Whether the app opens following the platform's brightness, and which
  /// side to open on when it does not — both read from the preference before
  /// the first frame, and both stored by the switches in Settings › Theme.
  final bool initialFollowSystem;
  final bool initialDark;

  /// What `main()` started before the first frame: the store, the identity and
  /// the running mesh.
  ///
  /// Null is a widget test that builds the shell on its own. Nothing on screen
  /// reads it yet — the tabs still draw their own lists — so a null services
  /// object is the same shell a test has always got, and the production path is
  /// the one that has a mesh behind it. Pass 2 is what moves a tab onto it.
  final AppServices? services;

  @override
  State<NexusUiApp> createState() => _NexusUiAppState();
}

class _NexusUiAppState extends State<NexusUiApp> {
  /// True while the app takes its brightness from the platform. Read from the
  /// preference before the first frame, and stored by every flip: a choice
  /// that survived only until the laundry app asked for memory was the bug.
  late bool _followSystem = widget.initialFollowSystem;

  /// The user's own choice, used only while [_followSystem] is false. Stored
  /// separately from [_followSystem], so turning Follow system back off lands
  /// in the half of the day the user picked rather than in light.
  late bool _dark = widget.initialDark;

  /// Which accent every surface paints itself with. Read from the preference in
  /// [main] so the first frame is already the user's colour.
  late NexusAccent _accent = widget.initialAccent ?? NexusAccent.purple;

  /// The root messenger, so a ping can surface from any tab — it is a message
  /// about the device, not about the screen that happens to be open.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Incoming pings live for as long as the app does. Started here rather than
  /// in the Devices tab: a ping that only arrives while its tab is open is not
  /// a ping.
  StreamSubscription<NexusPing>? _pings;

  /// Releases TCP 51820 when the engine goes away, so a recreated engine can
  /// take the port back (see `mesh/mesh_lifecycle.dart`). Null when this shell
  /// was built without services, which is every widget test.
  MeshLifecycleObserver? _meshLifecycle;

  /// The action runner this shell owns, handed to the tab that runs a peer's
  /// request. Built with the services and never rebuilt, because it holds
  /// backends rather than state. Null in a widget test, which has no services.
  DeviceExecutor? _executor;

  /// A peer's request that was not answered immediately — the one waiting for
  /// the user, shown as a card at the top of the Devices list.
  ///
  /// Held here rather than in the tab because the request outlives a visit to
  /// it: a peer that asked while the user was on Home is still waiting, and the
  /// card is where they find it.
  IncomingAgentAction? _peerRequest;

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
    final AppServices? services = widget.services;
    if (services != null) {
      // The mesh belongs to the app, not to a tab: its discovery, its pairing
      // rows and what a peer announced are the same answers wherever the user
      // is standing. The observer stops it on engine detach, which is the one
      // thing that keeps 51820 from staying bound to a dead engine.
      _meshLifecycle = MeshLifecycleObserver(services.mesh);
      WidgetsBinding.instance.addObserver(_meshLifecycle!);
      NearbyDevices.instance.bindTo(services.mesh);
      // Built here rather than in the tab that will use it: the executor is a
      // property of the app (what *this* device can do), not of a screen, and
      // a second one built on a tab rebuild would be a second answer.
      _executor = launchedExecutor(services);
      // A peer's request must be answered wherever the user is standing, and
      // the shell is the one thing that is always mounted. A card that only
      // appeared while its tab was open is the same mistake the ping handler
      // refuses to make.
      services.mesh.addListener(_onMeshChanged);
    }
    _pings = FileTransferService.instance.pings.listen(_onPing);
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
    final MeshLifecycleObserver? lifecycle = _meshLifecycle;
    final AppServices? services = widget.services;
    if (services != null) services.mesh.removeListener(_onMeshChanged);
    if (lifecycle != null && services != null) {
      WidgetsBinding.instance.removeObserver(lifecycle);
      NearbyDevices.instance.unbind();
      unawaited(stopAppServices(services));
    }
    unawaited(_pings?.cancel());
    _pings = null;
    _voice.removeListener(_onVoiceChanged);
    super.dispose();
  }

  /// One device nudged another. A phone feels it and shows it in the app; a
  /// desktop hands it to the platform's own notification centre.
  void _onPing(NexusPing ping) {
    // One string for both surfaces: the badge is part of the sentence, so the
    // snackbar and the desktop notification cannot say different things about
    // the same ping. `verified` is the file link's answer about the signature;
    // false means the sender holds no token of ours and this shell knows it by
    // its own record rather than by anything the request claimed.
    _notifyDevice(
      'Ping from ${ping.deviceName}${ping.verified ? '' : ' (unverified)'}',
      haptic: true,
    );
  }

  /// One message about a device, on the two surfaces this build has.
  ///
  /// A phone feels it when [haptic] says so and shows it in the app; a desktop
  /// hands it to the platform's notification centre. One string for both, so
  /// the snackbar and the notification cannot disagree about the same event.
  void _notifyDevice(String text, {bool haptic = false}) {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (haptic) unawaited(HapticFeedback.heavyImpact());
      _showPingSnack(text);
      return;
    }
    unawaited(_showDesktopPing(text));
  }

  /// A mesh notification, used for exactly one thing: claiming a peer's action
  /// request before a later notification finds it gone.
  ///
  /// Deliberately not a rebuild trigger. The mesh notifies on every message it
  /// handles — presence, results, relays — and rebuilding the whole app for
  /// each of those would be work done for nothing; only an unanswered request
  /// has something to say, and the tabs listen to the mesh themselves.
  void _onMeshChanged() {
    final AppServices? services = widget.services;
    if (services == null) return;
    final IncomingAgentAction? action = services.mesh.takeIncomingAgentAction();
    if (action == null) return;
    unawaited(_handlePeerAction(action));
  }

  /// The name this device knows [id] by, for a sentence a person reads.
  String _peerNameOf(String id) {
    final AppServices? services = widget.services;
    if (services == null) return id;
    for (final peer in services.mesh.pairedDevices) {
      if (peer.id == id) return peer.name;
    }
    return id;
  }

  /// Handles a request a peer sent, by the decision [decidePeerAction] made.
  ///
  /// Two of the three outcomes answer the peer here and now, and the third
  /// puts a card on the Devices list instead. Whichever it is, the sender gets
  /// an answer: [IncomingAgentAction] cannot be resolved any other way.
  Future<void> _handlePeerAction(IncomingAgentAction action) async {
    final bool trusted = action.trusted;
    switch (decidePeerAction(policy: action.policy, trusted: trusted)) {
      case PeerActionDecision.refuse:
        final AgentDispatchResult result = await action.refuse(
          kNexusPeerActionDenied,
        );
        if (mounted) {
          _notifyDevice(_peerActionLine(action.from, result));
        }
      case PeerActionDecision.runNow:
        // The only path in the app that acts without a person watching. It is
        // reached only for a policy the user set to 'auto' *and* a frame that
        // proved itself, and the sentence the user sees is the reply's own.
        final AgentDispatchResult result = await action.resolveWith(
          () => _runPeerAction(action),
        );
        if (mounted) {
          _notifyDevice(_peerActionLine(action.from, result));
        }
      case PeerActionDecision.ask:
        if (mounted) setState(() => _peerRequest = action);
    }
  }

  /// The line a peer-initiated action writes on the user's screen.
  ///
  /// Built from the reply's own words, never from what this shell hoped
  /// happened: an action that could not be run says why, and a hard-coded
  /// "Playing: X" would have told the user it played.
  String _peerActionLine(String from, AgentDispatchResult result) {
    final String words = result.message.trim();
    return '${_peerNameOf(from)} asked — '
        '${words.isEmpty ? result.status.label : words}';
  }

  /// Runs a peer's request on this device and turns the outcome into the truth
  /// the peer is told.
  ///
  /// The mapping is [ActionResult]'s own three-way answer kept intact: a
  /// question (`needsDetail`) is not a failure, and reporting "what should I
  /// play?" as "Unavailable" would call the feature broken when the sentence
  /// was merely incomplete.
  Future<AgentDispatchResult> _runPeerAction(IncomingAgentAction action) async {
    final DeviceExecutor? executor = _executor;
    if (executor == null) {
      return const AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'This device has nothing to run actions with.',
      );
    }
    final ActionResult outcome = await executor.run(action.request);
    return AgentDispatchResult(
      status: outcome.ok
          ? AgentResultStatus.succeeded
          : (outcome.needsDetail
                ? AgentResultStatus.needsInfo
                : AgentResultStatus.unavailable),
      message: outcome.message,
      dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
    );
  }

  /// The user's answer to the card: run it here, or refuse it.
  ///
  /// Approving runs the same path an 'auto' request takes, so the sentence the
  /// peer gets is the same sentence it would have got without the tap.
  Future<void> _answerPeerRequest(bool approve) async {
    final IncomingAgentAction? action = _peerRequest;
    if (action == null) return;
    setState(() => _peerRequest = null);
    final AgentDispatchResult result = approve
        ? await action.resolveWith(() => _runPeerAction(action))
        : await action.refuse(kNexusPeerActionDenied);
    if (mounted) _notifyDevice(_peerActionLine(action.from, result));
  }

  void _showPingSnack(String text) {
    final ScaffoldMessengerState? messenger = _messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
      );
  }

  /// `notify-send` is the desktop notification this build can honestly post on
  /// Linux. A platform without one falls back to the in-app notice rather than
  /// claiming a notification it did not show.
  Future<void> _showDesktopPing(String text) async {
    bool shown = false;
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        final ProcessResult result = await Process.run('notify-send', <String>[
          '-t',
          '5000',
          'Nexus',
          text,
        ]);
        shown = result.exitCode == 0;
      } catch (error) {
        debugPrint('PING: no native notification ($error)');
      }
    }
    if (!shown && mounted) _showPingSnack(text);
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
      scaffoldMessengerKey: _messengerKey,
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
            mesh: widget.services?.mesh,
            executor: _executor,
            peerRequest: _peerRequest,
            onPeerRequestAnswered: _answerPeerRequest,
            onFollowSystemChanged: (value) {
              setState(() => _followSystem = value);
              unawaited(Appearance.setFollowSystem(value));
            },
            onDarkModeChanged: (value) {
              setState(() => _dark = value);
              unawaited(Appearance.setDarkMode(value));
            },
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
                size: NexusLayout.iconLarge,
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
    this.mesh,
    this.executor,
    this.peerRequest,
    this.onPeerRequestAnswered,
  });

  /// The running mesh, when the app started one.
  ///
  /// Handed down rather than reached through a singleton because it is the only
  /// thing on the launched path that is *not* a process-wide static: `main()`
  /// starts it and owns its lifetime. Null is a widget test that built the
  /// shell on its own; the Devices tab then behaves as it did before this pass
  /// — a shell list with no presence and no capability line — rather than
  /// pretending a mesh is there.
  final MeshService? mesh;

  /// Runs an action on this device ([launchedExecutor]), handed to the Devices
  /// tab because that is the tab that owns peers. Null in a widget test.
  final DeviceExecutor? executor;

  /// A peer's request waiting for the user, claimed by the app and shown at the
  /// top of the Devices list. Null when nothing is waiting — which is the
  /// ordinary state.
  final IncomingAgentAction? peerRequest;

  /// The user's answer to [peerRequest]. True runs it here; false refuses.
  final Future<void> Function(bool approve)? onPeerRequestAnswered;

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
    final Size window = MediaQuery.sizeOf(context);
    final double width = window.width;
    final bool wide = nexusIsDesktopApp || width >= kNexusWideBreakpoint;
    // A landscape phone with the keyboard up has about 140dp of body left, and
    // a sidebar that wants twice that. The keys are the edge the user is using,
    // so the sidebar steps aside until they are put away — the same rule the
    // phone's tab bar already follows. Passing the answer to Home as `wide` is
    // what gives the thread its drawer and menu button back while the sidebar is
    // hidden; closing the keyboard restores the column, and because the pages
    // keep their State neither side of the swap loses the draft.
    //
    // Read *here*, above the Scaffold, and not inside the page below it: a
    // Scaffold consumes the keyboard inset for the box it sizes and hands its
    // body a MediaQuery with those insets zeroed. `viewInsetsOf` in HomeTab is
    // always zero — a check written there reads as "no keyboard" on a phone with
    // the keyboard covering half the screen, and the fix silently does nothing.
    // That is exactly how the first attempt at this looked.
    final bool crampedByKeyboard =
        MediaQuery.viewInsetsOf(context).bottom > 0 &&
        window.height < kNexusShortHeight;
    final bool hasSidebar = wide && !crampedByKeyboard;
    final Widget pages = IndexedStack(
      index: _tab,
      children: <Widget>[
        // The thread's own drawer is disabled while the sidebar owns history:
        // two ways to open the same list, one of them a panel over the other
        // list, is the kind of duplicate a wide layout exists to remove.
        HomeTab(
          refreshEpoch: _homeEpoch,
          wide: hasSidebar,
          cramped: crampedByKeyboard,
          onOpenSettings: () => _select(_settingsIndex),
        ),
        // The index in this stack is the design: 0 is Home, 1 is Files, and
        // only the page whose index matches the selected tab does work on
        // launch.
        FilesTab(active: _tab == 1, mesh: widget.mesh),
        DevicesTab(
          mesh: widget.mesh,
          executor: widget.executor,
          peerRequest: widget.peerRequest,
          onPeerRequestAnswered: widget.onPeerRequestAnswered,
        ),
        SettingsTab(
          darkMode: dark,
          onDarkModeChanged: widget.onDarkModeChanged,
          followSystem: widget.followSystem,
          onFollowSystemChanged: widget.onFollowSystemChanged,
          accent: widget.accent,
          onAccentChanged: widget.onAccentChanged,
          scrollController: _settingsScroll,
          refreshEpoch: _settingsEpoch,
          mesh: widget.mesh,
        ),
        if (_developerMode) const DeveloperLogsTab(),
      ],
    );
    // One tree at every width, and a fixed number of children in it: the row has
    // two slots whatever the width, and slot 0 is never absent — the sidebar
    // lives in a SizedBox that collapses to zero when it is hidden.
    //
    // That collapse is load-bearing, not tidiness. The page slot used to be
    // renumbered by the sidebar's presence (`[if (wide) Sidebar(), Expanded(
    // pages)]`), and Flutter reconciles children by position and type: when the
    // sidebar appeared at index 0 the Expanded moved to index 1, `canUpdate`
    // failed, and the entire page subtree — every tab's State, the half-typed
    // message, the focus holding the keyboard open, the thread's scroll
    // position — was unmounted and rebuilt from nothing. On a rotation that is
    // the difference between a relayout and a lost draft.
    //
    // So: two slots, always, and the sidebar is hidden *inside* the first one.
    // If a future change adds a third child here, give it a slot of its own too
    // — or make it the last one — rather than letting it appear only when wide.
    final Widget pagesPane = KeyedSubtree(
      key: const ValueKey<String>('nexus-shell-pages'),
      // A clip that arrived while the user was somewhere else has to be able to
      // say so from that somewhere else: the bar sits above the pages, is zero
      // height unless something is waiting, and leaves every tab's State alone
      // because it is added above the IndexedStack rather than inside it.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.mesh != null) ...<Widget>[
            NexusClipboardBanner(mesh: widget.mesh!),
            // A setting a peer changed here says so on every tab, for the same
            // reason: it is a fact about the app, not about the screen that
            // happens to be open.
            NexusSettingNoticeBar(mesh: widget.mesh!),
          ],
          Expanded(child: pages),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: c.background,
      // The Row's two child slots must stay stable; the sidebar hides inside slot 0.
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Slot 0 is always present; narrow layouts hide the sidebar here at zero width.
          SizedBox(
            width: hasSidebar ? kNexusSidebarWidth + 1 : 0,
            child: hasSidebar
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(
                        width: kNexusSidebarWidth,
                        child: _NexusWideSidebar(
                          key: const ValueKey<String>('nexus-wide-sidebar'),
                          index: _tab,
                          tabs: tabs,
                          onSelected: _select,
                          onOpenChat: (String id) {
                            _select(_homeIndex);
                            ChatLog.instance.selectSession(id);
                          },
                        ),
                      ),
                      // A hairline rather than a shadow: the two panes are one
                      // surface cut in two, not a floating sheet beside a page.
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: c.hairline,
                      ),
                    ],
                  )
                : null,
          ),
          // Slot 1: the pages, at the same index on every device.
          Expanded(child: pagesPane),
        ],
      ),
      // The destinations live at the bottom of a phone and in the sidebar of a
      // wide window. Removing the bar is a slot change in the Scaffold, not a
      // rebuild of the body above it.
      bottomNavigationBar: wide
          ? null
          : NexusTabBar(index: _tab, onSelected: _select, tabs: tabs),
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
    super.key,
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
                  size: NexusLayout.icon,
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
                size: NexusLayout.iconLarge,
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
                padding: const EdgeInsets.fromLTRB(
                  NexusLayout.gutter,
                  0,
                  NexusLayout.gutter,
                  20,
                ),
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
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: NexusLayout.icon,
                        ),
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
      child: Icon(icon, size: NexusLayout.icon, color: c.textMuted),
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

/// The title, dialog key and Settings button of the lock a small model shows.
const String kNexusFeatureLockedTitle = 'Feature Locked';
const Key kNexusFeatureLockedDialog = Key('nexus-feature-locked');
const Key kNexusFeatureLockedGo = Key('nexus-feature-locked-go');

/// Explains why the feature the user just tapped cannot work, and offers the
/// screen that changes it.
///
/// A locked control that only says "no" is a wall. One sentence covers both
/// locked features, because it is one situation — the model on this phone is
/// too small — and it names both things that open the lock (a bigger model, or
/// the PC). The one button is the trip to Settings, where both live.
/// [onOpenSettings] is the caller's, because only the caller knows what "there"
/// is on its screen; when it is null the dialog offers only the way out.
Future<bool> showNexusFeatureLocked(
  BuildContext context, {
  required NexusFeature feature,
  VoidCallback? onOpenSettings,
}) async {
  final NexusUiColors c = context.ui;
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: kNexusFeatureLockedDialog,
      backgroundColor: c.surface,
      title: Text(
        kNexusFeatureLockedTitle,
        style: NexusType.rowTitle(dialogContext.ui),
      ),
      content: Text(
        ModelCapabilities.current.lockMessage(feature),
        style: NexusType.rowMeta(dialogContext.ui).copyWith(height: 1.45),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Not now', style: TextStyle(color: c.textMuted)),
        ),
        if (onOpenSettings != null)
          TextButton(
            key: kNexusFeatureLockedGo,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'Open Settings',
              style: TextStyle(color: c.accent, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    ),
  );
  if (!(go ?? false)) return false;
  onOpenSettings?.call();
  return true;
}

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
    this.attachmentName,
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

  /// The name the user knows a document by. The kept copy is renamed with a
  /// timestamp (`document-…pdf`), so the path cannot be turned back into
  /// "notes.pdf" once the caption is something the user typed.
  final String? attachmentName;

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
    attachmentName: attachmentName,
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
                  icon: const Icon(
                    Icons.add_comment_outlined,
                    size: NexusLayout.icon,
                  ),
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
        Icon(icon, size: NexusLayout.icon, color: color),
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
  const FilesTab({super.key, this.active = true, this.mesh});

  /// The running mesh, when the app started one. Null in a widget test.
  ///
  /// Read for one thing: whether a paired device is reachable *now*. A row's
  /// stored `online` flag is what it was when the row was written, which is the
  /// only answer there is for an example row or a pairing the mesh never made —
  /// but for a device the mesh has paired, "can I send this file" is the mesh's
  /// answer, not a memory.
  final MeshService? mesh;

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

  /// Files that arrive while this tab is alive. The listener writes into the
  /// Received folder and pushes here, so the listing is refreshed without the
  /// user having to tap the refresh button.
  StreamSubscription<ReceivedFile>? _receivedFiles;

  /// The one file currently being sent, its progress (0..1), and the name the
  /// banner shows. Null means no transfer is in flight.
  String? _sendingPath;
  String? _sendingName;
  double _sendProgress = 0;

  /// The AI's categories, when the list is grouped. Null is the ordinary
  /// newest-first folder view.
  List<({String label, List<LocalFileEntry> entries})>? _aiGroups;
  bool _sorting = false;

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
    // A received file is a change to this tab's disk listing. Listening here,
    // in the page that shows the folder, is what makes a transfer appear while
    // the user is looking at it rather than after a pull-to-refresh.
    _receivedFiles = FileTransferService.instance.incoming.listen((_) {
      if (!mounted) return;
      // A new file invalidates the AI's grouping: its category list was built
      // from the names that existed before this one arrived.
      setState(() => _aiGroups = null);
      unawaited(_load());
    });
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
    unawaited(_receivedFiles?.cancel());
    _receivedFiles = null;
    PairedDevices.instance.removeListener(_onPairedChanged);
    super.dispose();
  }

  void _onPairedChanged() {
    if (mounted) setState(() {});
  }

  /// Whether this device can be sent a file right now.
  ///
  /// The mesh answers for a device it has paired, in both directions: a peer
  /// whose row was written `online: false` and which has been talking to us
  /// since is reachable, and a peer the mesh has watched go quiet is not,
  /// whatever the row remembers. Only a row the mesh has never recorded falls
  /// back to the stored flag — the example rows, and a pairing that failed
  /// halfway — because replacing their answer with a null would empty the
  /// destination list of the demo build that has no mesh at all.
  bool _reachable(PairedDevice device) {
    final PeerPresence? presence = peerPresence(widget.mesh, device.id);
    return presence?.online ?? device.online;
  }

  /// The peers a file can actually be sent to right now.
  List<PairedDevice> get _onlinePeers => <PairedDevice>[
    for (final PairedDevice device in PairedDevices.instance.devices)
      if (!device.isThisDevice && _reachable(device)) device,
  ];

  /// Every file the tab is showing, in folder order. Used by the AI sorter and
  /// by the extension fallback.
  List<LocalFileEntry> get _allEntries => <LocalFileEntry>[
    for (final LocalFolder folder in _folders ?? const <LocalFolder>[])
      if (folder.error == null) ...folder.entries,
  ];

  /// The browser for [device], or null when there is nothing to browse.
  ///
  /// Both questions are the mesh's, not the row's: it has to *hold* this device
  /// — a row written by a scan, or the example rows of a build with no mesh,
  /// carries no pairing the mesh can dial — and the device has to be answering
  /// now. A row offering a browser for a device nobody can reach would open on
  /// an error the user did nothing to cause.
  VoidCallback? _remoteBrowser(PairedDevice device) {
    final MeshService? mesh = widget.mesh;
    if (mesh == null || device.isThisDevice) return null;
    if (!mesh.isPaired(device.id) || !_reachable(device)) return null;
    return () => unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              RemoteFilesPage(mesh: mesh, deviceId: device.id),
        ),
      ),
    );
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
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
      _notify('No app on this device opens ${entry.name}.');
    }
  }

  /// One row and its menu. Every route to a file's actions starts here, so the
  /// ordinary list and an AI-grouped list cannot drift apart.
  Widget _fileRow(LocalFileEntry entry) {
    return _LocalFileRow(
      key: ValueKey<String>('local-file-${entry.path}'),
      entry: entry,
      canSend: _onlinePeers.isNotEmpty && _sendingPath == null,
      onTap: () => unawaited(_open(entry)),
      onAction: (action) => unawaited(_fileAction(entry, action)),
    );
  }

  Future<void> _fileAction(
    LocalFileEntry entry,
    _LocalFileAction action,
  ) async {
    switch (action) {
      case _LocalFileAction.open:
        await _open(entry);
      case _LocalFileAction.send:
        await _chooseSendTarget(entry);
      case _LocalFileAction.share:
        await _share(entry);
      case _LocalFileAction.delete:
        await _delete(entry);
    }
  }

  /// The bottom sheet that answers "which device?" for this one file.
  Future<void> _chooseSendTarget(LocalFileEntry entry) async {
    final List<PairedDevice> peers = _onlinePeers;
    if (peers.isEmpty) {
      _notify('No paired device is online right now.');
      return;
    }
    final PairedDevice? target = await showModalBottomSheet<PairedDevice>(
      context: context,
      backgroundColor: context.ui.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) =>
          _SendFileSheet(entry: entry, devices: peers),
    );
    if (target == null || !mounted) return;
    await _sendTo(entry, target);
  }

  Future<void> _sendTo(LocalFileEntry entry, PairedDevice device) async {
    if (_sendingPath != null) {
      _notify('A file is already being sent.');
      return;
    }
    setState(() {
      _sendingPath = entry.path;
      _sendingName = entry.name;
      _sendProgress = 0;
    });
    final FileSendResult result = await FileLink.instance.send(
      path: entry.path,
      device: device,
      onProgress: (double value) {
        if (mounted) setState(() => _sendProgress = value);
      },
    );
    if (!mounted) return;
    setState(() {
      _sendingPath = null;
      _sendingName = null;
      _sendProgress = 0;
    });
    _notify(result.message);
  }

  /// The platform share sheet. This is the phone's own "send this somewhere",
  /// not the mesh's: Nexus is one of the apps that receives it.
  Future<void> _share(LocalFileEntry entry) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(entry.path)], subject: entry.name),
      );
    } catch (error) {
      debugPrint('FILES: share failed ($error)');
      _notify('Could not open the share sheet for ${entry.name}.');
    }
  }

  Future<void> _delete(LocalFileEntry entry) async {
    final bool confirmed = await showNexusConfirm(
      context,
      title: 'Delete ${entry.name}?',
      message:
          'This removes the file from this device. It is not sent anywhere, '
          'and it cannot be recovered.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    try {
      final File file = File(entry.path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('FILES: delete failed ($error)');
      _notify('Could not delete ${entry.name}.');
      return;
    }
    if (!mounted) return;
    setState(() => _aiGroups = null);
    await _load();
    _notify('Deleted ${entry.name}.');
  }

  /// Ask the local brain for categories, then insist on the one shape this
  /// screen can draw. A model that answers with prose, a truncated object or a
  /// made-up filename is not a reason to show nothing: the extension grouping
  /// is the floor.
  Future<void> _sortWithAi() async {
    if (_sorting) return;
    if (_aiGroups != null) {
      setState(() => _aiGroups = null);
      return;
    }
    final List<LocalFileEntry> entries = _allEntries;
    if (entries.isEmpty) return;
    setState(() => _sorting = true);
    try {
      final String raw = await LocalAiService.current
          .generateResponse(_fileSortPrompt(entries))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      final List<({String label, List<LocalFileEntry> entries})>? parsed =
          parseAiFileGroups(raw, entries);
      setState(() {
        _aiGroups = parsed ?? groupFilesByExtension(entries);
        _sorting = false;
      });
      if (parsed == null) {
        _notify(
          'The model could not group these, so they are sorted by file type.',
        );
      }
    } catch (error) {
      debugPrint('FILES: AI sort failed ($error)');
      if (!mounted) return;
      setState(() {
        _aiGroups = groupFilesByExtension(entries);
        _sorting = false;
      });
      _notify(
        'The model could not group these, so they are sorted by file type.',
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
      // A device that paired *into* this one (it scanned our code) has no shell
      // row — nothing on that path writes one — but it is paired, it is in the
      // mesh, and its folders can be opened. Leaving it out here would hide a
      // device the Devices tab is already listing, and would make the browser
      // unreachable for exactly the pairing a phone makes by scanning.
      ...meshOnlyRows(widget.mesh, PairedDevices.instance),
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
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          0,
          NexusLayout.gutter,
          28,
        ),
        children: <Widget>[
          const NexusSectionLabel('Connected Devices', first: true),
          for (final PairedDevice device in connected)
            _ConnectedDeviceRow(
              key: ValueKey<String>('files-device-${device.id}'),
              device: device,
              online: _reachable(device),
              onBrowse: _remoteBrowser(device),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Expanded(child: NexusSectionLabel('Local Files')),
              Padding(
                padding: const EdgeInsets.only(top: 12, right: 2),
                child: TextButton.icon(
                  key: const ValueKey<String>('files-sort-ai'),
                  onPressed: _folders == null || _allEntries.isEmpty || _sorting
                      ? null
                      : () => unawaited(_sortWithAi()),
                  icon: _sorting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 15),
                  label: Text(
                    _aiGroups == null ? 'Sort with AI' : 'Newest first',
                    style: NexusType.rowMeta(c).copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.accent,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: c.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
          if (_sendingPath != null)
            _FileTransferBanner(
              name: _sendingName ?? _sendingPath!.split('/').last,
              progress: _sendProgress,
            ),
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
          else if (_aiGroups != null)
            for (final ({String label, List<LocalFileEntry> entries}) group
                in _aiGroups!) ...<Widget>[
              _LocalFolderHeader(
                folder: LocalFolder(
                  label: group.label,
                  path: '',
                  entries: group.entries,
                ),
              ),
              for (final LocalFileEntry entry in group.entries) _fileRow(entry),
            ]
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
                  _fileRow(entry),
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
/// shared.
///
/// A peer the mesh can reach is a door — tapping it opens that device's folders
/// ([RemoteFilesPage]) and the chevron says so. A peer it cannot reach is a
/// statement: the same row, no chevron, because a browser opened on an
/// unreachable device is an error page the user did not ask for.
class _ConnectedDeviceRow extends StatelessWidget {
  const _ConnectedDeviceRow({
    super.key,
    required this.device,
    required this.online,
    this.onBrowse,
  });

  final PairedDevice device;

  /// Whether the device is reachable right now, which is the mesh's answer when
  /// it has one and the row's own flag when it does not. Not read off [device]
  /// here: the row says what is true now, the same fact the destination list
  /// above is built from.
  final bool online;

  /// Opens this device's files. Null for this device, for a row the mesh never
  /// paired, and for a device that is not answering.
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final IconData icon = device.isThisDevice
        ? Icons.smartphone_rounded
        : (device.name.toLowerCase().contains('mac')
              ? Icons.laptop_mac_rounded
              : Icons.desktop_windows_rounded);
    final int? ram = device.ramBytes;
    final VoidCallback? onBrowse = this.onBrowse;
    final Widget row = Padding(
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
          NexusStatusDot(online: device.isThisDevice || online),
          const SizedBox(width: 6),
          Text(
            device.isThisDevice
                ? 'This phone'
                : (online ? 'Online' : 'Offline'),
            style: NexusType.rowMeta(c),
          ),
          // A chevron only where there is a place to go: it is the row's own
          // promise that the tap does something.
          if (onBrowse != null) ...<Widget>[
            const SizedBox(width: 4),
            const NexusChevron(),
          ],
        ],
      ),
    );
    if (onBrowse == null) return row;
    return InkWell(
      onTap: onBrowse,
      borderRadius: const BorderRadius.all(NexusLayout.tile),
      child: row,
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

/// The four things a file row can do. Kept as one enum so the menu and the
/// action switch cannot disagree about what was chosen.
enum _LocalFileAction { open, send, share, delete }

/// One real file: its kind, its name, the size and date that tell one
/// `IMG_2026.jpg` from another, and the one menu that reaches every action.
class _LocalFileRow extends StatelessWidget {
  const _LocalFileRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.canSend,
    required this.onAction,
  });

  final LocalFileEntry entry;
  final VoidCallback onTap;

  /// False when there is no paired online device to offer, or when another
  /// transfer is already running.
  final bool canSend;

  final ValueChanged<_LocalFileAction> onAction;

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
            PopupMenuButton<_LocalFileAction>(
              key: ValueKey<String>('file-menu-${entry.path}'),
              tooltip: 'More',
              position: PopupMenuPosition.under,
              onSelected: onAction,
              icon: Icon(Icons.more_vert_rounded, size: 20, color: c.textMuted),
              itemBuilder: (BuildContext menuContext) =>
                  <PopupMenuEntry<_LocalFileAction>>[
                    _fileMenuItem(
                      context,
                      _LocalFileAction.open,
                      Icons.open_in_new_rounded,
                      'Open',
                    ),
                    if (canSend)
                      _fileMenuItem(
                        context,
                        _LocalFileAction.send,
                        Icons.send_rounded,
                        'Send to...',
                      ),
                    _fileMenuItem(
                      context,
                      _LocalFileAction.share,
                      Icons.ios_share_rounded,
                      'Share',
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<_LocalFileAction>(
                      value: _LocalFileAction.delete,
                      height: 44,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.delete_outline_rounded,
                            size: NexusLayout.icon,
                            color: c.danger,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Delete',
                            style: NexusType.rowTitle(c)
                                .copyWith(color: c.danger),
                          ),
                        ],
                      ),
                    ),
                  ],
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_LocalFileAction> _fileMenuItem(
    BuildContext context,
    _LocalFileAction action,
    IconData icon,
    String label,
  ) {
    final NexusUiColors c = context.ui;
    return PopupMenuItem<_LocalFileAction>(
      value: action,
      height: 44,
      child: Row(
        children: <Widget>[
          Icon(icon, size: NexusLayout.icon, color: c.textMuted),
          const SizedBox(width: 12),
          Text(label, style: NexusType.rowTitle(c)),
        ],
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
          Icon(icon, size: NexusLayout.icon, color: c.textMuted),
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

/// The line a transfer owns while it runs: what is going, and how far.
///
/// It sits above the list rather than inside the row, because a row can scroll
/// away mid-transfer and the one thing a user needs then is the bar.
class _FileTransferBanner extends StatelessWidget {
  const _FileTransferBanner({required this.name, required this.progress});

  final String name;

  /// 0..1. The service reports real copied bytes, not a spinner's guess.
  final double progress;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final double value = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
    return Container(
      key: const ValueKey<String>('files-send-progress'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.hairline),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.upload_rounded,
                size: NexusLayout.icon,
                color: c.accent,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Sending $name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexusType.rowTitle(c).copyWith(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text('${(value * 100).round()}%', style: NexusType.rowMeta(c)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 5,
              backgroundColor: c.hairline,
              valueColor: AlwaysStoppedAnimation<Color>(c.accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Which device?" as a sheet: every paired device that answered, one tap.
///
/// It only ever shows the peers the caller already decided are online. Handing
/// this widget an offline device would make the sheet promise a transfer the
/// mesh cannot make, so the filtering lives in one place in the page.
class _SendFileSheet extends StatelessWidget {
  const _SendFileSheet({required this.entry, required this.devices});

  final LocalFileEntry entry;
  final List<PairedDevice> devices;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.hairline,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Send to...', style: NexusType.section(c)),
            const SizedBox(height: 4),
            Text(
              '${entry.name} · ${localFileSize(entry.bytes)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: NexusType.rowMeta(c),
            ),
            const SizedBox(height: 14),
            for (final PairedDevice device in devices)
              InkWell(
                key: ValueKey<String>('send-to-${device.id}'),
                onTap: () => Navigator.of(context).pop(device),
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      const NexusIconTile(Icons.devices_rounded, size: 38),
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
                              device.reachableDetail.isEmpty
                                  ? 'Paired device · Online'
                                  : '${device.reachableDetail} · Online',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NexusType.rowMeta(c),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const NexusStatusDot(online: true),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'The file goes straight to the device over your own network. '
              'Nothing is uploaded.',
              style: NexusType.rowMeta(c).copyWith(height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the sort button asks the local model.
///
/// One shape, stated twice — once in words and once in a literal example —
/// because a 0.5B model follows a shape it can copy far better than a shape it
/// has to infer. The file names are copied into the prompt, so the model is
/// choosing labels rather than inventing rows; [parseAiFileGroups] throws away
/// any name it does not recognise.
String _fileSortPrompt(List<LocalFileEntry> entries) {
  final String names = entries.map((LocalFileEntry e) => e.name).join('\n');
  return 'You are organising the files on a phone into a few short groups.\n'
      'Reply with JSON only, with no explanation and no markdown:\n'
      '{"groups":[{"label":"Images","files":["IMG_1.jpg"]},'
      '{"label":"Documents","files":["notes.txt"]}]}\n'
      'Use at most 6 groups and short plain labels (Images, Documents, '
      'Code, Audio, Video, Other). Every file name must appear exactly once '
      'and exactly as written below.\n'
      'Files:\n$names';
}

/// The model's answer, made safe to draw.
///
/// Returns null when there is no usable grouping at all — prose, a truncated
/// object, or labels with no recognised file in them — so the caller can fall
/// back to [groupFilesByExtension]. Names the model invented are dropped; files
/// it forgot are collected under "Other" rather than disappearing from a file
/// manager.
List<({String label, List<LocalFileEntry> entries})>? parseAiFileGroups(
  String raw,
  List<LocalFileEntry> entries,
) {
  if (entries.isEmpty) return null;
  final int start = raw.indexOf('{');
  final int end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? groupsRaw = decoded['groups'] ?? decoded['categories'];
  if (groupsRaw is! List) return null;

  final Map<String, LocalFileEntry> byName = <String, LocalFileEntry>{
    for (final LocalFileEntry entry in entries) entry.name.toLowerCase(): entry,
  };
  final Set<String> used = <String>{};
  final List<({String label, List<LocalFileEntry> entries})> groups =
      <({String label, List<LocalFileEntry> entries})>[];

  for (final Object? groupRaw in groupsRaw) {
    if (groupRaw is! Map) continue;
    final String label =
        '${groupRaw['label'] ?? groupRaw['name'] ?? groupRaw['category'] ?? ''}'
            .trim();
    if (label.isEmpty) continue;
    final Object? filesRaw =
        groupRaw['files'] ?? groupRaw['items'] ?? groupRaw['entries'];
    if (filesRaw is! List) continue;
    final List<LocalFileEntry> members = <LocalFileEntry>[];
    for (final Object? fileRaw in filesRaw) {
      final String name =
          (fileRaw is Map
                  ? '${fileRaw['name'] ?? fileRaw['file'] ?? ''}'
                  : '$fileRaw')
              .trim();
      if (name.isEmpty) continue;
      final String tail = name.split(RegExp(r'[/\\]')).last.toLowerCase();
      final LocalFileEntry? entry = byName[name.toLowerCase()] ?? byName[tail];
      if (entry == null || !used.add(entry.name)) continue;
      members.add(entry);
    }
    if (members.isNotEmpty) groups.add((label: label, entries: members));
  }
  if (groups.isEmpty) return null;

  final List<LocalFileEntry> leftovers = <LocalFileEntry>[
    for (final LocalFileEntry entry in entries)
      if (!used.contains(entry.name)) entry,
  ];
  if (leftovers.isEmpty) return groups;
  final int other = groups.indexWhere(
    (({String label, List<LocalFileEntry> entries}) group) =>
        group.label.toLowerCase() == 'other',
  );
  if (other >= 0) {
    groups[other] = (
      label: groups[other].label,
      entries: <LocalFileEntry>[...groups[other].entries, ...leftovers],
    );
  } else {
    groups.add((label: 'Other', entries: leftovers));
  }
  return groups;
}

/// The fallback grouping: by what a file is, not by what a model guessed.
///
/// Deterministic and instant, which is the point — it is what the button shows
/// when there is no model, when the model answers nonsense, and in the tests.
/// The order is fixed so the same folder always reads the same way; inside a
/// group the folder's own newest-first order is kept.
List<({String label, List<LocalFileEntry> entries})> groupFilesByExtension(
  List<LocalFileEntry> entries,
) {
  const Set<String> documents = <String>{
    'pdf',
    'doc',
    'docx',
    'odt',
    'rtf',
    'txt',
    'md',
    'markdown',
    'csv',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
  };
  const Set<String> code = <String>{
    'dart',
    'py',
    'js',
    'ts',
    'kt',
    'java',
    'c',
    'cpp',
    'h',
    'html',
    'css',
    'xml',
    'json',
    'yaml',
    'yml',
    'sh',
    'toml',
    'ini',
    'log',
  };
  const Set<String> audio = <String>{'mp3', 'wav', 'm4a', 'ogg', 'flac'};
  const Set<String> video = <String>{'mp4', 'mov', 'mkv', 'webm', 'avi'};
  const Set<String> archives = <String>{'zip', 'gz', 'tar', 'rar', '7z', 'apk'};

  final Map<String, List<LocalFileEntry>> buckets =
      <String, List<LocalFileEntry>>{
        'Images': <LocalFileEntry>[],
        'Documents': <LocalFileEntry>[],
        'Code': <LocalFileEntry>[],
        'Audio': <LocalFileEntry>[],
        'Video': <LocalFileEntry>[],
        'Archives': <LocalFileEntry>[],
        'Other': <LocalFileEntry>[],
      };
  for (final LocalFileEntry entry in entries) {
    final String extension = entry.extension;
    final String label = entry.isImage
        ? 'Images'
        : documents.contains(extension)
        ? 'Documents'
        : code.contains(extension)
        ? 'Code'
        : audio.contains(extension)
        ? 'Audio'
        : video.contains(extension)
        ? 'Video'
        : archives.contains(extension)
        ? 'Archives'
        : 'Other';
    buckets[label]!.add(entry);
  }
  return <({String label, List<LocalFileEntry> entries})>[
    for (final MapEntry<String, List<LocalFileEntry>> bucket in buckets.entries)
      if (bucket.value.isNotEmpty) (label: bucket.key, entries: bucket.value),
  ];
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
                  Icon(device.icon, size: NexusLayout.icon, color: c.textMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(device.name, style: NexusType.rowTitle(c)),
                  ),
                  if (device.name == selected.name)
                    Icon(
                      Icons.check_rounded,
                      size: NexusLayout.icon,
                      color: c.accent,
                    ),
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
              Icon(selected.icon, size: NexusLayout.icon, color: c.textMuted),
              const SizedBox(width: 7),
              Text(selected.name, style: NexusType.rowTitle(c)),
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more_rounded,
                size: NexusLayout.icon,
                color: c.textMuted,
              ),
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
              Icon(
                Icons.more_horiz_rounded,
                size: NexusLayout.icon,
                color: c.textMuted,
              ),
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
/// The online/offline word beside each row is what discovery and the mesh are
/// hearing now, and the flag the row was written with is only used for a device
/// the mesh has never recorded — see [_DevicesTabState._rows].
class DevicesTab extends StatefulWidget {
  const DevicesTab({
    super.key,
    this.mesh,
    this.executor,
    this.peerRequest,
    this.onPeerRequestAnswered,
  });

  /// The running mesh, when the app started one. Null in a widget test, which
  /// is why every read of it below is nullable: a shell with no mesh has no
  /// presence to show and no pairing to offer, and says so by showing neither.
  final MeshService? mesh;

  /// Runs an action on this device, for a request a peer sent here.
  ///
  /// Held rather than reached for: the executor is built once by the app
  /// ([launchedExecutor]) and is deliberately not a singleton, so this widget
  /// says which one it was given. Null in a widget test, and on a shell with no
  /// services — a shell that cannot run a peer's request says so instead of
  /// pretending.
  final DeviceExecutor? executor;

  /// A peer's request waiting for an answer, shown as the first card on this
  /// list. This screen is where devices are, so it is where a question about
  /// one belongs — and the card is above the list rather than inside it, so a
  /// request cannot be missed by scrolling past it.
  final IncomingAgentAction? peerRequest;

  /// The user's answer to [peerRequest]. Null on a shell that has no app above
  /// it, which is a widget test: the card then shows what is waiting without
  /// pretending it can answer.
  final Future<void> Function(bool approve)? onPeerRequestAnswered;

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

/// One card's worth of state: the row the shell wrote, and what the mesh says
/// about the same device right now.
///
/// The two are one row on purpose. Identity, address and the file token belong
/// to [device] (the mesh does not carry them); presence and capabilities belong
/// to [presence] (the shell does not know them). [notConnected] is the case the
/// merge has to name rather than blur: a row whose device the mesh has never
/// paired.
class _DeviceRow {
  const _DeviceRow({
    required this.device,
    required this.presence,
    this.notConnected = false,
  });

  final PairedDevice device;
  final PeerPresence? presence;
  final bool notConnected;
}

/// The one request a peer sent that needs a person.
///
/// It names the action in the catalogue's words rather than the protocol's id —
/// "Media", not `media.play` — because the person reading it is deciding
/// whether to let another device play something, not reading a log. The line
/// under it says whether the request proved itself, which is the difference
/// between a device the user paired and a device that says it is one.
class _PeerRequestCard extends StatelessWidget {
  const _PeerRequestCard({
    required this.action,
    required this.peerName,
    required this.onAnswered,
  });

  final IncomingAgentAction action;
  final String peerName;

  /// Null on a shell with no app above it, which is a widget test: the card
  /// then shows what is waiting rather than pretending it can answer.
  final Future<void> Function(bool approve)? onAnswered;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final String what =
        capabilityFor(action.request.action)?.label ?? action.request.action;
    final bool answered = onAnswered != null;
    return Container(
      key: const ValueKey<String>('peer-request-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.danger.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.notification_important_rounded,
                size: 18,
                color: c.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$peerName wants to: $what',
                  key: const ValueKey<String>('peer-request-title'),
                  style: NexusType.rowTitle(c)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            action.trusted
                ? 'From a paired, verified device.'
                : 'Could not be verified — approve this only if you asked for '
                      'it.',
            key: const ValueKey<String>('peer-request-trust'),
            style: NexusType.rowMeta(c).copyWith(height: 1.35),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  key: const ValueKey<String>('peer-request-approve'),
                  onPressed: answered
                      ? () => unawaited(onAnswered!(true))
                      : null,
                  child: const Text('Run it here'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey<String>('peer-request-deny'),
                  onPressed: answered
                      ? () => unawaited(onAnswered!(false))
                      : null,
                  child: const Text('Refuse'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What this device will accept from paired peers, as a sheet.
///
/// A sheet rather than a section of the device list, and that is a measurement
/// rather than a preference: the same rows as a section added three thousand
/// pixels of scroll to the list, which pushed the paired cards out of the built
/// area for anyone who scrolled down to the pairing row. The list is about who
/// is here; this is a decision about them, and the pairing flow already opens a
/// sheet for exactly that kind of thing.
Future<void> showPeerRequestPolicySheet(
  BuildContext context, {
  required MeshService mesh,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: context.ui.background,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (BuildContext sheetContext) => _PeerPolicySheet(mesh: mesh),
);

class _PeerPolicySheet extends StatefulWidget {
  const _PeerPolicySheet({required this.mesh});

  final MeshService mesh;

  @override
  State<_PeerPolicySheet> createState() => _PeerPolicySheetState();
}

class _PeerPolicySheetState extends State<_PeerPolicySheet> {
  /// The actions offered: what this device can actually do, derived from the
  /// catalogue rather than hand-listed, so a new capability appears here the
  /// day it exists.
  ///
  /// Deliberately not "every action Nexus knows" — a policy for something this
  /// device cannot run is a promise about nothing. A choice stored for an
  /// action outside this list still applies, because the table is read by
  /// action id when a request arrives, not from what this sheet drew.
  late final List<String> _actions = <String>[
    for (final DeviceCapability capability in defaultCapabilitiesFor(
      widget.mesh.identity.platform,
    ))
      capability.id,
  ];

  Future<void> _choose(String action, AgentPolicy policy) async {
    widget.mesh.store.setAgentPolicy(action, policy);
    // Drawn before it is written, deliberately. The decision the user just made
    // is already true -- the table the mesh reads is in memory -- and a row that
    // kept saying "Ask first" until a disk write finished would be showing them
    // the old answer to their own question. The write follows.
    if (mounted) setState(() {});
    await widget.mesh.store.save();
  }

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          18,
          NexusLayout.gutter,
          18,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Peer requests', style: NexusType.pageTitle(c)),
            const SizedBox(height: 8),
            Text(kNexusPeerRequestsExplainer, style: NexusType.lede(c)),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final String action in _actions)
                    _PeerPolicyRow(
                      key: ValueKey<String>('peer-policy-$action'),
                      action: action,
                      policy: widget.mesh.store.agentPolicy(action),
                      onChanged: (AgentPolicy policy) =>
                          unawaited(_choose(action, policy)),
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

/// One action's pre-approval, as a row with a picker.
///
/// The label and the sentence under it come from the same table, so a row can
/// never say "Auto-approve" while explaining something else. The words are
/// deliberately not the raw enum names: "ask", "auto" and "deny" are the
/// storage, and a settings row is read by a person.
class _PeerPolicyRow extends StatelessWidget {
  const _PeerPolicyRow({
    super.key,
    required this.action,
    required this.policy,
    required this.onChanged,
  });

  final String action;
  final AgentPolicy policy;
  final ValueChanged<AgentPolicy> onChanged;

  static String label(AgentPolicy policy) => switch (policy) {
    AgentPolicy.ask => 'Ask first',
    AgentPolicy.auto => 'Auto-approve',
    AgentPolicy.deny => 'Never',
  };

  static String explain(AgentPolicy policy) => switch (policy) {
    AgentPolicy.ask => 'Shows the request on this screen and waits for you.',
    AgentPolicy.auto =>
      'Runs without asking when the other device is paired and the request '
          'is verified.',
    AgentPolicy.deny => 'Refused, and the other device is told why.',
  };

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final String what = capabilityFor(action)?.label ?? action;
    return NexusRow(
      title: what,
      subtitle: explain(policy),
      trailing: PopupMenuButton<AgentPolicy>(
        key: ValueKey<String>('peer-policy-menu-$action'),
        initialValue: policy,
        onSelected: onChanged,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<AgentPolicy>>[
          for (final AgentPolicy choice in AgentPolicy.values)
            PopupMenuItem<AgentPolicy>(
              value: choice,
              child: Text(label(choice)),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label(policy),
                key: ValueKey<String>('peer-policy-value-$action'),
                style: NexusType.rowTitle(c)
                    .copyWith(fontSize: 13, color: c.accent),
              ),
              const Icon(Icons.arrow_drop_down_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
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
    // The mesh is a source for this screen now, not just for the file link:
    // a peer going quiet, a capability list arriving and a device pairing into
    // this one all arrive as notifications, and the rows have to follow them.
    widget.mesh?.addListener(_onChanged);
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
    widget.mesh?.removeListener(_onChanged);
    unawaited(_nearby.stop());
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Paired rows, with presence answered by what discovery is hearing right
  /// now: a device heard in the last minute is online, whoever said otherwise
  /// when the row was written — and by the mesh when it has a pairing, which is
  /// the stronger answer of the two.
  ///
  /// The mesh-only rows at the end are devices that paired *into* this one (they
  /// scanned our code). Nothing wrote a shell row for them, so without this the
  /// device the user just paired with would be missing from the list they are
  /// looking at — see [meshOnlyRows].
  List<_DeviceRow> get _rows => <_DeviceRow>[
    for (final PairedDevice device in _paired.devices) _rowFor(device),
    for (final PairedDevice peer in meshOnlyRows(widget.mesh, _paired))
      _meshRow(peer),
  ];

  /// A row for a peer only the mesh knows, drawn from live presence.
  ///
  /// The same rule as [_rowFor], and it has to be: the store never wrote this
  /// row, so its `online` flag is [PairedDevice]'s default of false rather than
  /// anybody's answer. Rendering that would show a device that is talking to us
  /// right now as Offline, with its actions greyed out — the state this screen
  /// was reported for. Presence is the only answer there is here, and a null
  /// one (no mesh) leaves the row as it was built.
  _DeviceRow _meshRow(PairedDevice peer) {
    final PeerPresence? presence = peerPresence(widget.mesh, peer.id);
    return _DeviceRow(
      device: presence == null ? peer : peer.copyWith(online: presence.online),
      presence: presence,
    );
  }

  _DeviceRow _rowFor(PairedDevice device) {
    final PeerPresence? presence = peerPresence(widget.mesh, device.id);
    PairedDevice row = device;
    if (!device.isThisDevice) {
      final DiscoveredDevice? heard = _nearby.running
          ? _nearby.device(device.id)
          : null;
      if (heard != null) {
        row = device.copyWith(
          online: true,
          detail: 'Seen just now at ${heard.address}',
        );
      }
      if (presence?.online == true) row = row.copyWith(online: true);
    }
    return _DeviceRow(
      device: row,
      presence: presence,
      // The mesh is only one of the two answers here, so "not connected" is
      // only meaningful when there *is* a mesh and it has no record.
      notConnected:
          widget.mesh != null && presence == null && !device.isThisDevice,
    );
  }

  /// The memory on this mesh, in bytes: this device's own RAM plus every peer
  /// that shared a number. A peer that did not share is not a zero — it is a
  /// device this total cannot speak for, which is why the row also says how
  /// many devices answered.
  int? get _meshRam {
    int total = _localRam ?? 0;
    int counted = _localRam == null ? 0 : 1;
    for (final _DeviceRow row in _rows) {
      final PairedDevice device = row.device;
      final int? ram = device.ramBytes;
      if (device.isThisDevice || ram == null) continue;
      total += ram;
      counted++;
    }
    return counted == 0 ? null : total;
  }

  int get _meshRamDevices {
    int counted = _localRam == null ? 0 : 1;
    for (final _DeviceRow row in _rows) {
      if (!row.device.isThisDevice && row.device.ramBytes != null) counted++;
    }
    return counted;
  }

  /// Where this device is reachable right now: discovery's fresh address when
  /// it is running, otherwise the address the pairing recorded.
  String? _addressOf(PairedDevice device) {
    if (device.isThisDevice) return null;
    final DiscoveredDevice? heard = _nearby.running
        ? _nearby.device(device.id)
        : null;
    if (heard != null) {
      return heard.port > 0 ? '${heard.address}:${heard.port}' : heard.address;
    }
    if (device.addresses.isEmpty) return null;
    final String address = device.addresses.first;
    return device.port > 0 ? '$address:${device.port}' : address;
  }

  /// Whether the peer is a desktop, which is the one case the trackpad is for.
  /// Older pairing codes did not carry a platform, so the detail line is the
  /// fallback — and a phone never becomes a PC by accident.
  bool _isDesktop(PairedDevice device) {
    switch (device.platform) {
      case 'linux':
      case 'windows':
      case 'macos':
        return true;
      case 'android':
      case 'ios':
        return false;
    }
    final String words = '${device.name} ${device.detail}'.toLowerCase();
    return words.contains('desktop') ||
        words.contains('laptop') ||
        words.contains('pc') ||
        words.contains('linux') ||
        words.contains('windows') ||
        words.contains('mac');
  }

  /// What this screen calls [id]: the shell's row when there is one, because
  /// that is the name the user gave it, then the mesh's, then the id itself.
  String _nameOf(String id) {
    for (final PairedDevice device in _paired.devices) {
      if (device.id == id) return device.name;
    }
    final MeshService? mesh = widget.mesh;
    if (mesh != null) {
      for (final peer in mesh.pairedDevices) {
        if (peer.id == id) return peer.name;
      }
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final List<_DeviceRow> rows = _rows;
    // Every id already on the list, including the ones only the mesh knows:
    // a peer that paired into this device is paired, and offering it under
    // Nearby as though it were a stranger would be the same double-answer the
    // merge exists to remove.
    final Set<String> known = <String>{
      for (final _DeviceRow row in rows) row.device.id,
    };
    final List<DiscoveredDevice> unpaired = <DiscoveredDevice>[
      for (final DiscoveredDevice device in _nearby.devices)
        if (!known.contains(device.id)) device,
    ];
    final MeshService? mesh = widget.mesh;
    return NexusTabBody(
      title: 'Devices',
      subtitle: 'Paired directly, over your own network.',
      // The way in that a user looks for first: a + in the corner of the page
      // they are already on, rather than a row they have to scroll to the end
      // of the list to find. Both open the same sheet.
      trailing: IconButton(
        key: kNexusAddDevice,
        tooltip: kNexusAddDeviceLabel,
        onPressed: () =>
            unawaited(showDevicePairingSheet(context, mesh: widget.mesh)),
        icon: const Icon(Icons.add_rounded),
        color: c.accent,
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          0,
          NexusLayout.gutter,
          28,
        ),
        children: <Widget>[
          // The one request waiting for a person, above everything: it is the
          // only thing on this screen that will not wait, and it belongs to a
          // peer rather than to any row below it.
          if (widget.peerRequest != null) ...<Widget>[
            _PeerRequestCard(
              action: widget.peerRequest!,
              peerName: _nameOf(widget.peerRequest!.from),
              onAnswered: widget.onPeerRequestAnswered,
            ),
            const SizedBox(height: 10),
          ],
          const NexusSectionLabel('Connected Devices', first: true),
          for (final _DeviceRow row in rows) ...<Widget>[
            _ConnectedDeviceCard(
              key: ValueKey<String>('device-card-${row.device.id}'),
              device: row.device,
              online: row.device.isThisDevice ? true : row.device.online,
              address: _addressOf(row.device),
              desktop: _isDesktop(row.device),
              presence: row.presence,
              notConnected: row.notConnected,
              onForget: row.device.isThisDevice
                  ? null
                  : () => unawaited(_forget(row.device)),
              onPairAgain: () =>
                  unawaited(showDevicePairingSheet(context, mesh: mesh)),
            ),
            const SizedBox(height: 10),
          ],
          // The mesh's memory, in one row: what the room could run if the
          // models were chosen by the strongest device rather than by the one
          // in the user's hand.
          const NexusSectionLabel('Mesh'),
          // Off until the user says otherwise, and the switch is here rather
          // than buried in Settings because this is the screen that owns the
          // list it changes. Off is not a hidden default: the subtitle says
          // what off means in the same breath.
          if (mesh != null) ...<Widget>[
            NexusRow(
              key: kNexusMeshPairingToggle,
              title: 'Mesh pairing',
              subtitle: mesh.store.pairingEnabled
                  ? 'Other devices can pair with this one from its code.'
                  : 'Off — no device can pair with this one until you turn '
                        'this on.',
              leading: const NexusIconTile(Icons.link_rounded),
              trailing: Switch.adaptive(
                value: mesh.store.pairingEnabled,
                onChanged: (bool value) => unawaited(_setPairing(value)),
              ),
            ),
            // The other half of a pairing, and off on a fresh install: a pair
            // that can reach this device can still see none of its folders
            // until this says so. It sits under Mesh pairing because it is the
            // same question one step further — who may reach this device, and
            // what may they read once they do.
            NexusRow(
              key: kNexusFileSharingToggle,
              title: 'File sharing',
              subtitle: mesh.store.fileShare
                  ? 'Paired devices can browse this device\u2019s folders and '
                        'download from them.'
                  : 'Off — a paired device sees no folders on this one until '
                        'you turn this on.',
              leading: const NexusIconTile(Icons.folder_shared_rounded),
              trailing: Switch.adaptive(
                value: mesh.store.fileShare,
                onChanged: (bool value) => unawaited(_setFileShare(value)),
              ),
            ),
          ],
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
          NexusRow(
            title: kNexusPairTitle,
            subtitle: 'Show your code, or scan one from another device',
            leading: const NexusIconTile(Icons.add_rounded),
            accentTitle: true,
            onTap: () =>
                unawaited(showDevicePairingSheet(context, mesh: widget.mesh)),
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
                : const Icon(Icons.radar_rounded, size: NexusLayout.icon),
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

  /// Turns mesh pairing on or off for this device, and remembers it.
  ///
  /// The write is fire-and-forget for the same reason every other preference
  /// row's is: the switch has already moved, and a slow disk is not a reason to
  /// hold the frame. The mesh reads the store live, so the next inbound
  /// `pair-request` is refused (or accepted) by the value the user just set.
  Future<void> _setPairing(bool value) async {
    final MeshService? mesh = widget.mesh;
    if (mesh == null || mesh.store.pairingEnabled == value) return;
    setState(() => mesh.store.pairingEnabled = value);
    unawaited(mesh.store.save());
  }

  /// Turns serving this device's folders to paired devices on or off. The mesh
  /// reads the switch per request, so this is the whole change: no restart, and
  /// the next browse from the other side sees it.
  Future<void> _setFileShare(bool value) async {
    final MeshService? mesh = widget.mesh;
    if (mesh == null || mesh.store.fileShare == value) return;
    setState(() => mesh.store.fileShare = value);
    unawaited(mesh.store.save());
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
    // Both lists, and the mesh too: a shell row that outlived its pairing
    // would come back as "Not connected" on the next frame, which is the exact
    // half-state this screen now names rather than hides. The mesh can also
    // hold a device with no shell row (it paired by scanning our code), so the
    // row is not the only place to forget from.
    final MeshService? mesh = widget.mesh;
    final bool meshHad = mesh?.isPaired(device.id) ?? false;
    final bool forgotRow = _paired.forget(device.id);
    if (meshHad) unawaited(mesh!.forgetDevice(device.id));
    if (!forgotRow && !meshHad) return;
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
        platform: device.platform,
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

/// A paired device as a card, the way a local-network app presents a machine
/// you can actually act on: what it is, whether it is here, where it is, and
/// the three things this phone can do to it without opening a menu.
///
/// The card owns its own actions because the picker, the progress line and the
/// result notice all belong to one device. The switch is a saved preference,
/// not a running sync yet; see [NotificationSync].
class _ConnectedDeviceCard extends StatefulWidget {
  const _ConnectedDeviceCard({
    super.key,
    required this.device,
    required this.online,
    required this.address,
    required this.desktop,
    this.presence,
    this.notConnected = false,
    this.onForget,
    this.onPairAgain,
  });

  final PairedDevice device;
  final bool online;
  final String? address;
  final bool desktop;

  /// What the mesh says about this device right now — presence and the list it
  /// announced. Null when the mesh has no pairing for it, which the card shows
  /// as "Not connected" rather than as an offline device.
  final PeerPresence? presence;

  /// True for a shell row the mesh has never paired.
  final bool notConnected;

  /// Opens the pairing sheet again, for the row that says it should.
  final VoidCallback? onPairAgain;

  final VoidCallback? onForget;

  @override
  State<_ConnectedDeviceCard> createState() => _ConnectedDeviceCardState();
}

class _ConnectedDeviceCardState extends State<_ConnectedDeviceCard> {
  bool _sending = false;
  double _progress = 0;
  bool _pinging = false;
  bool _notificationSync = false;
  bool _notificationTouched = false;

  PairedDevice get _device => widget.device;

  bool get _busy => _sending || _pinging;

  @override
  void initState() {
    super.initState();
    unawaited(_loadNotificationSync());
  }

  Future<void> _loadNotificationSync() async {
    final bool on = await NotificationSync.isOn(_device.id);
    if (!mounted || _notificationTouched) return;
    setState(() => _notificationSync = on);
  }

  void _setNotificationSync(bool value) {
    _notificationTouched = true;
    setState(() => _notificationSync = value);
    unawaited(NotificationSync.set(_device.id, value));
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// Open the platform picker, then send straight to this card's device. No
  /// second "which device?" question: the card already answered it.
  Future<void> _sendFile() async {
    if (_busy) return;
    XFile? picked;
    try {
      picked = await openFile();
    } catch (error) {
      debugPrint('DEVICES: picker failed ($error)');
      picked = null;
    }
    if (picked == null || !mounted) return;
    final File file = File(picked.path);
    if (!await file.exists()) {
      _notify('That file is no longer on this device.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _sending = true;
      _progress = 0;
    });
    final FileSendResult result = await FileLink.instance.send(
      path: picked.path,
      device: _device,
      onProgress: (double value) {
        if (mounted) setState(() => _progress = value);
      },
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _progress = 0;
    });
    _notify(result.message);
  }

  Future<void> _ping() async {
    if (_busy) return;
    setState(() => _pinging = true);
    final NexusRequestResult result = await FileTransferService.instance.ping(
      _device,
    );
    if (!mounted) return;
    setState(() => _pinging = false);
    _notify(result.message);
  }

  void _openRemote() {
    if (!widget.desktop || _busy) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => TrackpadPage(device: _device),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final bool self = _device.isThisDevice;
    final TextStyle meta = NexusType.rowMeta(c).copyWith(fontSize: 12);
    final String detail = _device.detail.isEmpty ? 'Device' : _device.detail;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.all(NexusLayout.card),
        border: Border.all(color: c.hairline),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(NexusLayout.card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: widget.online
                          ? c.online.withValues(alpha: 0.12)
                          : c.raised,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _iconFor(_device),
                      size: NexusLayout.iconLarge,
                      color: widget.online ? c.online : c.textMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NexusType.rowTitle(c).copyWith(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: meta,
                        ),
                        if (!self) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            widget.address ?? 'Address not shared',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: meta.copyWith(
                              fontSize: 11.5,
                              color: widget.address == null
                                  ? c.textMuted.withValues(alpha: 0.7)
                                  : c.textMuted,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          NexusStatusDot(online: widget.online),
                          const SizedBox(width: 6),
                          Text(
                            widget.online ? 'Online' : 'Offline',
                            style: meta.copyWith(fontSize: 11.5),
                          ),
                        ],
                      ),
                      if (!self)
                        IconButton(
                          key: ValueKey<String>('forget-${_device.id}'),
                          tooltip: 'Forget ${_device.name}',
                          onPressed: widget.onForget,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.only(top: 4),
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: NexusLayout.icon,
                          ),
                          color: c.danger,
                        ),
                    ],
                  ),
                ],
              ),
              if (!self) ...<Widget>[
                const SizedBox(height: 10),
                _PeerCapabilities(
                  deviceId: _device.id,
                  presence: widget.presence,
                  notConnected: widget.notConnected,
                  onPairAgain: widget.onPairAgain,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _DeviceCardAction(
                        key: ValueKey<String>('send-${_device.id}'),
                        icon: Icons.upload_file_rounded,
                        label: 'Send File',
                        onTap: widget.online && !_busy ? _sendFile : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DeviceCardAction(
                        key: ValueKey<String>('ping-${_device.id}'),
                        icon: Icons.wifi_tethering_rounded,
                        label: _pinging ? 'Pinging…' : 'Ping',
                        onTap: widget.online && !_busy ? _ping : null,
                      ),
                    ),
                    if (widget.desktop) ...<Widget>[
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DeviceCardAction(
                          key: ValueKey<String>('remote-${_device.id}'),
                          icon: Icons.mouse_outlined,
                          label: 'Remote',
                          onTap: widget.online && !_busy ? _openRemote : null,
                        ),
                      ),
                    ],
                  ],
                ),
                if (_sending) ...<Widget>[
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 3,
                      color: c.accent,
                      backgroundColor: c.raised,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.hairline)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.notifications_none_rounded,
                        size: NexusLayout.icon,
                        color: c.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Notification Sync',
                          style: NexusType.rowTitle(c).copyWith(fontSize: 13.5),
                        ),
                      ),
                      Tooltip(
                        message:
                            'Saves the preference on this phone. Notification '
                            'sync is not wired up yet.',
                        child: Switch.adaptive(
                          key: ValueKey<String>(
                            'notification-sync-${_device.id}',
                          ),
                          value: _notificationSync,
                          onChanged: _setNotificationSync,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The glyph on a card. The platform decides when it is known; the seed's
  /// two example machines keep their shapes for a list written before platform
  /// was carried in the pairing code.
  static IconData _iconFor(PairedDevice device) {
    if (device.isThisDevice) return Icons.smartphone_rounded;
    switch (device.platform) {
      case 'linux':
      case 'windows':
        return Icons.desktop_windows_rounded;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'android':
      case 'ios':
        return Icons.smartphone_rounded;
    }
    if (device.id == 'example-pc') return Icons.desktop_windows_rounded;
    if (device.id == 'example-mac') return Icons.laptop_mac_rounded;
    return Icons.devices_other_rounded;
  }
}

/// What this peer can do, said once per card, in five states.
///
/// The states are the whole point, and they are not decoration:
///
///   - no mesh pairing at all → "Not connected · pair again" (the row is a file
///     destination the mesh has never met, and tapping it opens the pairing
///     sheet);
///   - paired but offline → "Offline". The chips a peer announced before it went
///     quiet are not drawn greyed, because a greyed chip is still a claim about
///     what is on the network right now;
///   - never announced → "No capabilities announced yet". Nothing is
///     substituted, least of all the platform's own defaults;
///   - announced an empty list → "Reports no capabilities" — a different fact
///     from the line above;
///   - announced a list → its labels, plus one word for how it arrived.
///
/// The platform fallback the interpreter uses is deliberately absent here. A row
/// is a statement about *that* device, and "it is probably like this one" is
/// exactly the guess Phase 2's evidence ladder exists to keep out of the UI.
class _PeerCapabilities extends StatelessWidget {
  const _PeerCapabilities({
    required this.deviceId,
    required this.presence,
    required this.notConnected,
    this.onPairAgain,
  });

  final String deviceId;
  final PeerPresence? presence;
  final bool notConnected;
  final VoidCallback? onPairAgain;

  /// How many labels fit on one line before the rest become a count.
  static const int _mostChips = 4;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final TextStyle meta = NexusType.rowMeta(c).copyWith(fontSize: 11.5);
    if (notConnected) {
      return InkWell(
        key: ValueKey<String>('pair-again-$deviceId'),
        onTap: onPairAgain,
        borderRadius: const BorderRadius.all(NexusLayout.tile),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: <Widget>[
              Icon(Icons.link_off_rounded, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  kNexusNotConnected,
                  key: ValueKey<String>('caps-$deviceId'),
                  style: meta.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final PeerPresence? peer = presence;
    // A shell with no mesh behind it has nothing to say about capabilities, and
    // inventing a line would be worse than the empty space.
    if (peer == null) return const SizedBox.shrink();
    if (!peer.online) {
      return Text(
        kNexusCapsOffline,
        key: ValueKey<String>('caps-$deviceId'),
        style: meta,
      );
    }
    if (!peer.announced) {
      return Text(
        kNexusCapsNoneYet,
        key: ValueKey<String>('caps-$deviceId'),
        style: meta,
      );
    }
    if (peer.caps.isEmpty) {
      return Text(
        kNexusCapsNoneAnnounced,
        key: ValueKey<String>('caps-$deviceId'),
        style: meta,
      );
    }
    final List<String> labels = <String>[
      for (final String id in (peer.caps.toList()..sort()))
        capabilityFor(id)?.label ?? id,
    ];
    final List<String> shown = labels.take(_mostChips).toList();
    final int rest = labels.length - shown.length;
    return Wrap(
      key: ValueKey<String>('caps-$deviceId'),
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (final String label in shown) _chip(c, meta, label),
        if (rest > 0) _chip(c, meta, '+$rest'),
        // The provenance word is part of the same line, not a second one: one
        // gesture opens it, and the colour alone never carries the difference.
        InkWell(
          key: ValueKey<String>('caps-proof-$deviceId'),
          onTap: () => _showProof(context, peer.verified),
          borderRadius: const BorderRadius.all(NexusLayout.tile),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  peer.verified
                      ? Icons.verified_rounded
                      : Icons.help_outline_rounded,
                  size: 13,
                  color: peer.verified ? c.online : c.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  peer.verified ? kNexusCapsVerified : kNexusCapsAssumed,
                  style: meta.copyWith(
                    fontSize: 11,
                    color: peer.verified ? c.online : c.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(NexusUiColors c, TextStyle meta, String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: c.raised,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: c.hairline),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        style: meta.copyWith(fontSize: 11, color: c.textStrong),
      ),
    ),
  );

  /// What the provenance word means, in the user's words.
  void _showProof(BuildContext context, bool verified) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.ui.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        final NexusUiColors c = sheetContext.ui;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  verified ? kNexusCapsVerified : kNexusCapsAssumed,
                  style: NexusType.rowTitle(c),
                ),
                const SizedBox(height: 8),
                Text(
                  verified ? kNexusCapsVerifiedBody : kNexusCapsAssumedBody,
                  style: NexusType.rowMeta(c).copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One action inside a device card: a quiet raised tile, because the card is
/// the object and these are the verbs on it.
class _DeviceCardAction extends StatelessWidget {
  const _DeviceCardAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final bool enabled = onTap != null;
    final Color ink = enabled
        ? c.textStrong
        : c.textMuted.withValues(alpha: 0.45);
    return Material(
      color: c.raised,
      borderRadius: const BorderRadius.all(NexusLayout.tile),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: NexusLayout.icon, color: ink),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexusType.rowMeta(c).copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: ink,
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

/// The Settings row that opens the pre-approval sheet.
///
/// A row in Settings › Devices rather than a section of the Devices list, and
/// that is a measurement rather than a taste: the same rows drawn inside that
/// list add three thousand pixels of scroll, and the list is scrolled to its
/// bottom by the pairing flow — which pushes the paired cards that page is
/// about out of the built area. A permission table is a setting; the Devices
/// list is about who is here.
const Key kNexusPeerRequestsRow = ValueKey<String>('peer-requests-row');

/// What the pre-approval sheet says before it lists anything.
///
/// It has to say what "Auto-approve" does *and* what it refuses to do, because
/// the promise the user is making is narrower than the words suggest: it is
/// spent only on a request that proved itself.
const String kNexusPeerRequestsExplainer =
    'What a paired device may ask this one to do. Nothing is pre-approved '
    'until you choose it here. "Auto-approve" runs a request without asking, '
    'but only when the other device is paired and the request is verified.';

/// The row on a device card whose device the mesh has never paired.
const String kNexusNotConnected = 'Not connected · pair again';

/// The capability line, in each of its states. Named here so the card, the
/// tests and this note cannot drift into three spellings of one fact.
const String kNexusCapsOffline = 'Offline';
const String kNexusCapsNoneYet = 'No capabilities announced yet';
const String kNexusCapsNoneAnnounced = 'Reports no capabilities';
const String kNexusCapsVerified = 'Verified';
const String kNexusCapsAssumed = 'As announced';
const String kNexusCapsVerifiedBody =
    'This device proved the list came from it: the frame it arrived on was '
    'authenticated with the pairing the two of you hold.';
const String kNexusCapsAssumedBody =
    'This device sent the list, but the frame it arrived on was not '
    'authenticated. Nexus shows the labels and says so rather than calling '
    'them proved.';

/// The switch that lets another device pair with this one.
const Key kNexusMeshPairingToggle = Key('nexus-mesh-pairing-toggle');

/// The switch that lets a paired device see this one's folders. Off on a fresh
/// install, and the browser's own empty state is what a user sees until it is
/// on.
const Key kNexusFileSharingToggle = Key('nexus-file-sharing-toggle');

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
Future<void> showDevicePairingSheet(BuildContext context, {MeshService? mesh}) {
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
                  unawaited(_scanFrom(context, mesh: mesh));
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
                      builder: (routeContext) => PairQrPage(mesh: mesh),
                    ),
                  );
                },
              ),
              // Third row only when a developer asked for it: two desktops on
              // one machine cannot point a camera at each other, and the typed
              // flow already exists — this is the door, not a new lock.
              if (nexusDevPairEnabled)
                NexusRow(
                  key: kNexusDevPairRow,
                  title: kNexusDevPairLabel,
                  subtitle: 'Type the code, address and port — dev builds only',
                  leading: const NexusIconTile(Icons.keyboard_rounded),
                  trailing: const NexusChevron(),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (routeContext) =>
                            DevPairByCodePage(mesh: mesh),
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

// ---------------------------------------------------------------------------
// Dev-only pairing by code
// ---------------------------------------------------------------------------

/// The third row, and the words it uses. Named the same way as the two above so
/// a test that asserts its absence and a test that taps it read one spelling.
const Key kNexusDevPairRow = Key('nexus-dev-pair-row');
const String kNexusDevPairLabel = 'Pair by code';
const String kNexusDevPairHint =
    'For two builds on one desktop: the other side shows its code, this one '
    'types it. No camera, no scan.';

/// The page's fields and button, keyed for the widget tests and the desktop
/// driver that types into them.
const Key kNexusDevPairCodeField = Key('nexus-dev-pair-code');
const Key kNexusDevPairAddressField = Key('nexus-dev-pair-address');
const Key kNexusDevPairPortField = Key('nexus-dev-pair-port');
const Key kNexusDevPairSubmit = Key('nexus-dev-pair-submit');
const String kNexusDevPairSubmitLabel = 'Pair';

/// Whether the dev-only pairing entry is on at all.
///
/// It exists because one machine cannot scan its own screen: pairing two
/// desktop builds needs the typed-code path that [PairSheet] in `lib/ui` already
/// has, wired into the shell that actually runs. Two conditions, both required:
///
///   * `NEXUS_DEV_PAIR=1` in the environment — off by default, so an ordinary
///     run shows the same two rows it always has;
///   * not a release build — [kReleaseMode] is a compile-time constant, so the
///     row and the page are not in a shipped binary at all.
///
/// [debugDevPairEnabled] is the seam a widget test flips, in the same shape as
/// [debugPairScannerOverride].
bool get nexusDevPairEnabled {
  final bool? forced = _devPairOverride;
  if (forced != null) return forced;
  if (kReleaseMode) return false;
  return (Platform.environment['NEXUS_DEV_PAIR'] ?? '') == '1';
}

bool? _devPairOverride;

/// Turns the dev row on or off for one test, and back off with `null`.
@visibleForTesting
set debugDevPairEnabled(bool? value) => _devPairOverride = value;

/// Types a code, an address and a port, and pairs with it.
///
/// The same call the QR scanner makes when the code came from a camera
/// ([MeshService.pairWithCandidates]), so the wire format under test is the
/// shipped one: the code derives the key, the request is encrypted with it, and
/// the device showing the code stores the pairing. Only the way the code gets
/// here is different — typed instead of decoded from a picture.
class DevPairByCodePage extends StatefulWidget {
  const DevPairByCodePage({super.key, this.mesh});

  /// The mesh that pairs. Null is a page built on its own: it still draws, and
  /// its Pair button says there is no mesh rather than pretending.
  final MeshService? mesh;

  @override
  State<DevPairByCodePage> createState() => _DevPairByCodePageState();
}

class _DevPairByCodePageState extends State<DevPairByCodePage> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _port = TextEditingController();
  bool _pairing = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    // Fields first, mesh second: a missing field is something the user can fix
    // in front of them, and reporting "no mesh" over an empty form would hide
    // the part they were asked to type.
    final String code = _code.text.trim().toUpperCase();
    final String address = _address.text.trim();
    final int? port = int.tryParse(_port.text.trim());
    if (code.isEmpty) {
      setState(() => _error = 'Enter the code shown on the other device.');
      return;
    }
    if (address.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(
        () => _error = 'Enter the address and port of the other device.',
      );
      return;
    }
    final MeshService? mesh = widget.mesh;
    if (mesh == null) {
      setState(() => _error = kPairNoMeshText);
      return;
    }
    setState(() {
      _pairing = true;
      _error = null;
    });
    final PairResult result = await mesh.pairWithCandidates(
      addresses: <String>[address],
      port: port,
      code: code,
    );
    if (!mounted) return;
    setState(() => _pairing = false);
    if (result.ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paired with ${result.peerName ?? 'device'}.')),
      );
      return;
    }
    setState(() => _error = result.error);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text(kNexusDevPairLabel)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: <Widget>[
          Text(
            kNexusDevPairHint,
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          const SizedBox(height: 18),
          TextField(
            key: kNexusDevPairCodeField,
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'ABCD-1234',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kNexusDevPairAddressField,
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: '127.0.0.1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kNexusDevPairPortField,
            controller: _port,
            keyboardType: TextInputType.number,
            // The last field submits: one keystroke after the port is typed is
            // the whole form, which is how the desktop driver fills it too.
            onSubmitted: (_) => _pair(),
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: NexusType.rowMeta(c).copyWith(color: c.danger),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            key: kNexusDevPairSubmit,
            onPressed: _pairing ? null : _pair,
            child: Text(_pairing ? 'Pairing…' : kNexusDevPairSubmitLabel),
          ),
        ],
      ),
    );
  }
}

/// Runs the scanner and pairs what came back.
///
/// Split out from the sheet so the sheet can close first: a modal sheet left
/// open under a camera page is a sheet that comes back when the camera is
/// dismissed, which is not what "scan a code" means.
///
/// The scan is now one decision rather than a write: [pairScannedDevice] pairs
/// the mesh and then writes the row, so the notice is the outcome of the pairing
/// rather than of the list operation. A failure says what went wrong and leaves
/// both lists exactly as they were.
Future<void> _scanFrom(BuildContext context, {MeshService? mesh}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final PairInvite? invite = await openPairScanner(context);
  if (invite == null) return;
  final PairOutcome outcome = mesh == null
      ? const PairOutcome.failure(kPairNoMeshText)
      : await pairScannedDevice(
          mesh: mesh,
          invite: invite,
          paired: PairedDevices.instance,
        );
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(outcome.notice),
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
  const PairQrPage({super.key, this.identity, this.addresses, this.mesh});

  /// Who this device is. Null uses [PairIdentity.current]; a test states it, so
  /// the QR it asserts on is not a random id.
  final PairIdentity? identity;

  /// Where this device can be reached. Null reads the real interfaces
  /// ([localAddresses]); a test states them, because a widget test host's
  /// interfaces are not the device's.
  final Future<List<String>> Function()? addresses;

  /// The mesh this code should pair. Null is a page built on its own: it still
  /// draws the file pairing it always did, and the scanning side will say the
  /// code is too old rather than write half a pairing.
  final MeshService? mesh;

  @override
  State<PairQrPage> createState() => PairQrPageState();
}

class PairQrPageState extends State<PairQrPage> {
  /// The addresses read when the page opened, empty until they arrive.
  List<String> _addresses = const <String>[];

  /// The secret the code carries. Loaded rather than built in: the identity is
  /// synchronous and the token is a preference read, and a code shown without
  /// it would pair a device that could never send a file here.
  String _token = '';

  /// The mesh pairing this page is showing, or null when there is no mesh (or
  /// no consent to pair). Its code is what makes the scan a pairing rather than
  /// a file-only row.
  PairingSession? _session;

  /// Whether this device accepts new pairings. Read from the store so the page
  /// tells the truth the mesh will act on: with this off, the peer's request is
  /// refused silently, and a QR that looks scannable would be a lie.
  bool _pairingOn = true;

  /// Mints the next code when the current one lapses, so a page left open is
  /// not a page showing a dead QR.
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_readAddresses());
    unawaited(_readToken());
    final MeshService? mesh = widget.mesh;
    _pairingOn = mesh == null || mesh.store.pairingEnabled;
    if (_pairingOn) _beginSession();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    final MeshService? mesh = widget.mesh;
    final PairingSession? session = _session;
    // Closing the page closes the door. Showing a code is consent to be
    // scanned, and a pending code that outlived its screen would be consent
    // nobody can see — so it is cleared unless something newer replaced it.
    if (mesh != null && session != null && mesh.pendingCode == session.code) {
      mesh.pendingCode = null;
      mesh.pendingCodeExpiry = null;
    }
    super.dispose();
  }

  /// Starts a five-minute mesh pairing, and schedules its replacement.
  void _beginSession() {
    final MeshService? mesh = widget.mesh;
    if (mesh == null) return;
    final PairingSession session = mesh.beginPairing();
    _session = session;
    _expiryTimer?.cancel();
    final Duration wait = session.expiresAt.difference(DateTime.now());
    // A second past the code's own expiry, so the replacement never races the
    // code it is replacing.
    _expiryTimer = Timer(
      wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
      () {
        if (!mounted) return;
        setState(_beginSession);
      },
    );
  }

  /// Turns pairing on from the point of use, then mints the code.
  Future<void> _enableMeshPairing() async {
    final MeshService? mesh = widget.mesh;
    if (mesh == null) return;
    mesh.store.pairingEnabled = true;
    unawaited(mesh.store.save());
    setState(() {
      _pairingOn = true;
      _beginSession();
    });
  }

  Future<void> _readAddresses() async {
    final List<String> found = await (widget.addresses ?? localAddresses)();
    if (!mounted) return;
    setState(() => _addresses = found);
  }

  Future<void> _readToken() async {
    final String known = widget.identity?.token.trim() ?? '';
    final String token = known.isNotEmpty ? known : await PairToken.current();
    if (!mounted) return;
    setState(() => _token = token);
  }

  /// Who this code says this device is, with the token it authenticates its
  /// transfers with.
  PairIdentity get _who =>
      (widget.identity ?? PairIdentity.current).withToken(_token);

  /// The exact string the QR currently carries — the identity, plus the
  /// addresses once they are known. A test reads this rather than poking at the
  /// image, because `QrImageView` keeps its data private.
  String get currentPayload => payloadFor(_addresses);

  /// The payload with [addresses] in it. The two halves are one decision: the
  /// other device needs to know *who* this is (id, name, key) and *where* it is
  /// (the address it just looked up), and a code carrying only the first would
  /// pair a device nobody could dial.
  String payloadFor(List<String> addresses) {
    final PairInvite invite = _who
        .withAddresses(addresses, port: kFileTransferPort)
        .invite;
    final PairingSession? session = _session;
    if (session == null) return invite.encode();
    // Both halves in one code: the file link's long-lived token under `code`,
    // and the mesh's five-minute code under `mesh_code` with the port it dials.
    return invite
        .withMesh(code: session.code, port: widget.mesh!.port)
        .encode();
  }

  /// The identity half of the code, without addresses — what the page can say
  /// before the interface list comes back, and what an older `nexus_pair` code
  /// carried.
  String get payload => _who.invite.encode();

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
            'list. Nothing is uploaded; the code also carries the key this '
            'device checks when a file arrives, so only a device that scanned '
            'it can send one.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          const SizedBox(height: 22),
          if (widget.mesh != null && !_pairingOn)
            _PairingOffCard(onTurnOn: () => unawaited(_enableMeshPairing()))
          else ...<Widget>[
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
            if (_session != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                kNexusQrValidity,
                key: kNexusQrValidityLine,
                textAlign: TextAlign.center,
                style: NexusType.rowMeta(c),
              ),
            ],
          ],
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

/// What the code is worth, in time. Shown only when this page is node to a
/// mesh: a file-only code has no expiry and claiming one would be wrong.
const String kNexusQrValidity = 'This code pairs this device for five minutes.';
const Key kNexusQrValidityLine = Key('nexus-qr-validity');

/// The card a "Show my QR code" page shows when mesh pairing is off.
///
/// It is here rather than only in Settings because this is the moment the user
/// finds out: a code on screen with pairing off is a scan that fails silently
/// on the other device. One tap fixes it from where the problem was found.
class _PairingOffCard extends StatelessWidget {
  const _PairingOffCard({required this.onTurnOn});

  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: const BorderRadius.all(NexusLayout.card),
        border: Border.all(color: c.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.link_off_rounded, size: 18, color: c.accent),
                const SizedBox(width: 8),
                Text('Mesh pairing is off', style: NexusType.rowTitle(c)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Another device can only pair with this one while mesh pairing is '
              'on. Turning it on does not pair anything by itself — it lets this '
              'page\u2019s code be accepted.',
              style: NexusType.rowMeta(c).copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: kNexusPairingOffTurnOn,
              onPressed: onTurnOn,
              child: const Text('Turn on mesh pairing'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one button on the pairing-off card.
const Key kNexusPairingOffTurnOn = Key('nexus-pairing-off-turn-on');

/// The code a desktop shows to a phone.
///
/// It is the phone's own `nexus_pair` JSON with two desktop-shaped fields on
/// top: `name` and `address` under the names this page documents, and `port`
/// as a number. The older `device_name` / `device_id` / `public_key` fields stay
/// in the object so the phone's existing parser accepts it unchanged.
///
/// The QR is withheld until the page knows both halves: an address a phone can
/// dial, and the transfer token that proves it scanned this PC. A code drawn
/// before either existed would pair a device that could never send a file.
class PairPhonePage extends StatefulWidget {
  const PairPhonePage({super.key, this.mesh, this.identity, this.addresses});

  /// Who this device is, for a test that asserts on the code. Null uses
  /// [PairIdentity.current].
  final PairIdentity? identity;

  /// Where this device can be reached. Null reads the real interfaces; a test
  /// states them, because the host's interfaces are not the device's.
  final Future<List<String>> Function()? addresses;

  /// The mesh this code should pair, when the shell has one.
  ///
  /// The PC's code is the direction that made this necessary: a phone scans it
  /// from the Settings row, and without a mesh code the scan is refused as an
  /// old code. Null is a page a test built on its own.
  final MeshService? mesh;

  @override
  State<PairPhonePage> createState() => PairPhonePageState();
}

class PairPhonePageState extends State<PairPhonePage> {
  List<String> _addresses = const <String>[];
  String _token = '';

  /// The mesh pairing this code is showing, or null when there is no mesh.
  PairingSession? _session;

  /// Whether this device accepts new pairings (see [PairQrPage]'s note — the
  /// same rule, on the other door).
  bool _pairingOn = true;

  Timer? _expiryTimer;

  /// Whether Ollama answered on this machine. Null while the first probe runs.
  bool? _ollama;

  bool _linkRunning = false;
  String? _linkProblem;

  @override
  void initState() {
    super.initState();
    unawaited(_readIdentity());
    unawaited(_probeOllama());
    unawaited(_ensureFileLink());
    final MeshService? mesh = widget.mesh;
    _pairingOn = mesh == null || mesh.store.pairingEnabled;
    if (_pairingOn) _beginSession();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    final MeshService? mesh = widget.mesh;
    final PairingSession? session = _session;
    if (mesh != null && session != null && mesh.pendingCode == session.code) {
      mesh.pendingCode = null;
      mesh.pendingCodeExpiry = null;
    }
    super.dispose();
  }

  /// Starts the five-minute mesh pairing this code will carry, and schedules
  /// its replacement so a page left open is not a page showing a dead code.
  void _beginSession() {
    final MeshService? mesh = widget.mesh;
    if (mesh == null) return;
    final PairingSession session = mesh.beginPairing();
    _session = session;
    _expiryTimer?.cancel();
    final Duration wait = session.expiresAt.difference(DateTime.now());
    _expiryTimer = Timer(
      wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
      () {
        if (!mounted) return;
        setState(_beginSession);
      },
    );
  }

  /// Turns pairing on from this page, then mints the code.
  Future<void> _enableMeshPairing() async {
    final MeshService? mesh = widget.mesh;
    if (mesh == null) return;
    mesh.store.pairingEnabled = true;
    unawaited(mesh.store.save());
    setState(() {
      _pairingOn = true;
      _beginSession();
    });
  }

  Future<void> _readIdentity() async {
    final List<String> found = await (widget.addresses ?? localAddresses)();
    final String known = widget.identity?.token.trim() ?? '';
    final String token = known.isNotEmpty ? known : await PairToken.current();
    if (!mounted) return;
    setState(() {
      _addresses = found;
      _token = token;
    });
  }

  /// The PC's own Ollama, as the phone will find it. Localhost is the PC here,
  /// which is the one case the address is not a LAN address.
  Future<void> _probeOllama() async {
    final bool ready = await const OllamaService().isReachable();
    if (!mounted) return;
    setState(() => _ollama = ready);
  }

  /// The listener the phone will send files to. The app starts it at launch;
  /// this makes opening the page enough on its own, and a port already taken is
  /// shown rather than hidden.
  Future<void> _ensureFileLink() async {
    final FileTransferService link = FileTransferService.instance;
    await link.start();
    if (!mounted) return;
    setState(() {
      _linkRunning = link.running;
      _linkProblem = link.problem;
    });
  }

  PairIdentity get _who =>
      (widget.identity ?? PairIdentity.current).withToken(_token);

  PairInvite get invite => PairInvite(
    deviceName: _who.name,
    deviceId: _who.id,
    publicKey: _who.publicKey,
    addresses: _addresses,
    port: kFileTransferPort,
    code: _token,
    platform: defaultPairPlatformToken(),
    ollama: _ollama == true,
  );

  /// The exact bytes the QR carries. Empty until an address and a token exist.
  ///
  /// With a mesh session it also carries `mesh_code` and `mesh_port`, which is
  /// what turns a scan from "this device sends files" into a pairing.
  String get currentPayload {
    if (_addresses.isEmpty || _token.isEmpty) return '';
    final PairingSession? session = _session;
    final PairInvite code = session == null
        ? invite
        : invite.withMesh(code: session.code, port: widget.mesh!.port);
    return code.encodeForDesktop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final String payload = currentPayload;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Pair Phone')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: NexusLayout.content),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Scan this with your phone',
                    style: NexusType.rowTitle(c),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Open Nexus on the phone, choose Pair a device, and point '
                    'it at this code. The address and the transfer key are '
                    'inside it — there is nothing to type.',
                    style: NexusType.rowMeta(c).copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 22),
                  if (widget.mesh != null && !_pairingOn)
                    _PairingOffCard(
                      onTurnOn: () => unawaited(_enableMeshPairing()),
                    )
                  else
                    Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.hairline),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                            width: 260,
                            height: 260,
                            child: payload.isEmpty
                                ? const Center(
                                    child: SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : QrImageView(
                                    data: payload,
                                    size: 260,
                                    backgroundColor: Colors.white,
                                    padding: EdgeInsets.zero,
                                    semanticsLabel:
                                        'Pairing code for ${_who.name}',
                                  ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  NexusRow(
                    title: _who.name,
                    subtitle: _addresses.isEmpty
                        ? 'Looking for this PC’s address…'
                        : 'Reachable at ${_addresses.first}',
                    leading: const NexusIconTile(Icons.computer_rounded),
                  ),
                  const SizedBox(height: 8),
                  NexusRow(
                    title: 'Ollama on this PC',
                    subtitle: switch (_ollama) {
                      null => 'Checking whether this PC can answer…',
                      true =>
                        'Ready — the phone will use this PC’s model for heavy '
                            'answers',
                      false =>
                        'Not running — start Ollama to lend the phone this PC’s '
                            'model',
                    },
                    leading: NexusIconTile(
                      _ollama == true
                          ? Icons.memory_rounded
                          : Icons.memory_outlined,
                    ),
                  ),
                  NexusRow(
                    title: 'File transfer',
                    subtitle:
                        _linkProblem ??
                        (_linkRunning
                            ? 'Listening on port '
                                  '${FileTransferService.instance.boundPort} '
                                  'for files from this phone'
                            : 'Starting the listener…'),
                    leading: NexusIconTile(
                      _linkRunning
                          ? Icons.swap_horiz_rounded
                          : Icons.hourglass_empty_rounded,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Paired phones can send files straight to this PC. Cancel '
                    'the pairing on the phone and the code stops mattering; no '
                    'account or cloud is involved.',
                    style: NexusType.rowMeta(c).copyWith(height: 1.5),
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
