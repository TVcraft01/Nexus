// Live conversation: the full-screen overlay, its orb, its badges and the
// waveform that moves with the user's voice.
//
// A part of the shell: the overlay is a route pushed from the Home screen and
// driven by the same live state that screen owns.

part of '../main_ui.dart';

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
