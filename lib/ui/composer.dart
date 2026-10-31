// The composer and its one-tap additions: the field, the send/mic button, the
// attachment sheet, the `+` menu, the hold-to-talk gesture and the level meter.
//
// A part of the shell: the button states are the session's (dictating, holding,
// live) and the sheet reads the same settings the screen does.

part of '../main_ui.dart';

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
      padding: const EdgeInsets.fromLTRB(
        NexusLayout.gutter,
        6,
        NexusLayout.gutter,
        12,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: NexusLayout.content),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.only(bottom: pending.isEmpty ? 8 : 0),
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
                    // One line, ellipsised: the note is a hint above the field,
                    // and at 200% text a second line of it takes the height the
                    // field needs.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NexusType.rowMeta(c).copyWith(fontSize: 11.5),
                  ),
                ),
              ),
              // The thumbnail waits above the pill, not inside it: a picture in
              // the text run would be a character the keyboard could delete, and
              // a picture inside the capsule makes the capsule a two-storey box.
              if (pending.isNotEmpty)
                _PendingAttachmentPreview(
                  pending: pending,
                  onRemove: onRemovePending,
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
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

/// The attachments chosen but not sent: 64dp thumbnails (or file glyphs) in a
/// row, each with a small X over its corner.
///
/// Above the pill rather than inside it, and with nothing drawn behind them:
/// the picture is the object, and a card around a single thumbnail is a frame
/// around a frame. The X is the one control here, and it is the control a user
/// reaches for when they picked the wrong photo.
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
    return Padding(
      key: kNexusPendingAttachment,
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final _PendingAttachment item in pending)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// One 64dp square and its X. No filename: the picture is the label, and a
/// name under a thumbnail is a second line of small type the user did not ask
/// for.
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
      width: 70,
      height: 70,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(14)),
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
                        size: NexusLayout.iconLarge,
                        color: c.textMuted,
                      ),
                    ),
            ),
          ),
          Positioned(
            top: -6,
            right: 0,
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
                    padding: const EdgeInsets.all(5),
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
        radius: 24,
        // 48 is the smallest target a thumb can reliably hit, and the visible
        // badge stays 36: the extra 12 is hit area, not ink.
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(NexusLayout.tile),
                color: on
                    ? c.accent.withValues(alpha: 0.14)
                    : Colors.transparent,
                border: Border.all(color: on ? c.accent : c.hairline),
              ),
              child: Icon(
                on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                size: NexusLayout.icon,
                color: on ? c.accent : c.textMuted,
              ),
            ),
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
          radius: 24,
          // 32 is the circle; 48 is what a thumb gets to hit.
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.raised,
                  border: Border.all(color: c.hairline),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: NexusLayout.icon,
                  color: c.textMuted,
                ),
              ),
            ),
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

/// The sheet behind the composer's `+`: three ways to attach, and the two
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
  const _AttachmentSheet({this.onOpenSettings});

  /// Where the lock dialog's one button goes. Null in a widget test that draws
  /// the sheet by itself, and the dialog then offers only the way out.
  final VoidCallback? onOpenSettings;

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

  /// Tapping a feature this brain cannot use: say why, then take the user to
  /// the only screen that changes it.
  Future<void> _openLockedFeature(NexusFeature feature) async {
    final bool go = await showNexusFeatureLocked(
      context,
      feature: feature,
      onOpenSettings: widget.onOpenSettings,
    );
    if (!mounted || !go) return;
    // The sheet was only the menu the lock was discovered from; leaving it up
    // would put a menu over the Settings page it just switched to.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a model downloaded while the sheet was open is a
    // switch that becomes live without closing the chat.
    final ModelCapabilities caps = ModelCapabilities.current;
    final bool webLocked = !caps.supportsWebSearch;
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
                //
                // Locked on a small model: the switch is drawn as a lock until
                // the brain can use what a search brings back.
                value: !webLocked && _settings.webSearchEnabled,
                locked: webLocked,
                subtitle: webLocked
                    ? caps.lockSubtitle(NexusFeature.webSearch)
                    : _settings.webSearchEnabled
                    ? 'On — each question is sent to DuckDuckGo'
                    : 'Off — answers stay on this device',
                onChanged: (bool value) =>
                    unawaited(_settings.setWebSearchEnabled(value)),
                onLockedTap: () =>
                    unawaited(_openLockedFeature(NexusFeature.webSearch)),
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
              Icon(
                icon,
                size: NexusLayout.iconLarge,
                color: _AttachmentSheetState._ink,
              ),
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
    this.locked = false,
    this.onLockedTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// True when the brain behind the next answer cannot do this. The row stays
  /// in place — the feature exists, it is the model that is too small — but it
  /// is greyed, the switch becomes a lock, and a tap explains instead of
  /// toggling a setting that would do nothing.
  final bool locked;

  /// What a tap on a locked row does: the lock dialog.
  final VoidCallback? onLockedTap;

  @override
  Widget build(BuildContext context) {
    final Color ink = locked
        ? _AttachmentSheetState._muted
        : _AttachmentSheetState._ink;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: locked ? onLockedTap : () => onChanged(!value),
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
                        color: ink,
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
              if (locked)
                const Icon(
                  Icons.lock_outline_rounded,
                  size: NexusLayout.icon,
                  color: _AttachmentSheetState._muted,
                )
              else
                Switch(value: value, onChanged: onChanged),
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
          width: NexusLayout.button,
          height: NexusLayout.button,
          child: Icon(icon, size: NexusLayout.iconLarge, color: glyph),
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
