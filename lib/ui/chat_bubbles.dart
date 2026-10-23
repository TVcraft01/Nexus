// Everything that draws inside the thread: the two sides of a message, the
// system pill, the error notice, attachment and file cards, and the artifact
// card that opens a file the model wrote.
//
// A part of the shell: the bubbles read the same palette, keys and formatting
// helpers as the screen that lays them out.

part of '../main_ui.dart';

/// The small "N" beside every assistant answer: the speaker's mark, the way a
/// chat app puts its own logo at the top of a reply. Named so a test can find
/// it; the widget itself is only a letter in a circle.
const Key kNexusAssistantMark = ValueKey<String>('nexus-assistant-mark');

/// A message in the thread. The two sides are deliberately unequal.
///
/// The user's side is a filled capsule, right-aligned, with no avatar: those
/// are the reader's own words and need no label. The assistant's side has no
/// bubble at all — the words sit directly on the page, with a small "N" mark at
/// the left, the pattern ChatGPT, Claude and Gemini share. A bubble around both
/// sides made every turn a card, and a thread of cards reads as a list of
/// notifications rather than a conversation.
///
/// The action row under an answer (copy, speak, the two thumbs, regenerate) is
/// hidden until the message is long-pressed, so the page stays quiet. The one
/// state that needs to be visible without the row is speech: a small breathing
/// dot on the "N" says which answer the voice belongs to.
///
/// A long press on the user's own message still opens the copy / select / edit
/// sheet; the hold is the gesture each side needs.
class NexusChatBubble extends StatefulWidget {
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
  /// speaker beside the message, so the phone talking is visible on the message
  /// it is talking about rather than only audible.
  final bool speaking;

  /// True while this bubble is a placeholder for an answer that has not arrived:
  /// muted ink, italic, and no controls: "Nexus is thinking…" is not a sentence
  /// anybody wants on their clipboard or in their ear.
  final bool thinking;

  /// Cap on the message, so long replies never reach the screen edge.
  final double maxWidth;

  /// The answer's feedback, held by the thread so the filled thumb survives the
  /// rebuild that follows the tap.
  final bool liked;
  final bool disliked;

  /// A hold on the user's own message opens the copy / select / edit sheet.
  /// On Nexus's side the same hold reveals the action row instead.
  final VoidCallback? onLongPress;

  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final VoidCallback? onRegenerate;

  /// The model's `<thought>` text. Shown above the answer in a grey collapsible
  /// block; null for a reply that did not reason out loud.
  final String? reasoning;

  @override
  State<NexusChatBubble> createState() => _NexusChatBubbleState();
}

class _NexusChatBubbleState extends State<NexusChatBubble> {
  /// The action row's visibility, kept per message: a hold on one answer must
  /// not open the controls under every other answer in the thread.
  bool _actionsOpen = false;

  void _held() {
    if (widget.mine) {
      widget.onLongPress?.call();
      return;
    }
    // A placeholder has nothing to copy or replay yet, so the hold does
    // nothing rather than offering controls that would act on half a sentence.
    if (widget.thinking) return;
    setState(() => _actionsOpen = !_actionsOpen);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return widget.mine ? _mine(c) : _theirs(c);
  }

  /// The reader's own words: a right-aligned capsule, no avatar.
  Widget _mine(NexusUiColors c) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: GestureDetector(
          onLongPress: _held,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: c.bubbleMine,
              borderRadius: const BorderRadius.all(NexusLayout.bubble),
            ),
            child: Text(
              widget.text,
              style: widget.thinking
                  ? NexusType.bubble(
                      c,
                    ).copyWith(color: c.textMuted, fontStyle: FontStyle.italic)
                  : NexusType.bubble(c),
            ),
          ),
        ),
      ),
    );
  }

  /// Nexus's side: mark, then prose straight on the page. Nothing is painted
  /// behind the words, which is what makes a long answer read as a page rather
  /// than as a very tall card.
  Widget _theirs(NexusUiColors c) {
    final String? reasoning = widget.reasoning?.trim();
    final bool showActions = !widget.thinking && _actionsOpen;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            NexusAssistantMark(speaking: widget.speaking),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (reasoning != null && reasoning.isNotEmpty) ...<Widget>[
                    _ReasoningBubble(
                      text: reasoning,
                      streaming: widget.thinking,
                    ),
                    const SizedBox(height: 6),
                  ],
                  GestureDetector(
                    onLongPress: _held,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: widget.thinking && widget.text == kNexusThinking
                          ? const _ThinkingWithTimer()
                          : Text(
                              widget.text,
                              style: widget.thinking
                                  ? NexusType.bubble(c).copyWith(
                                      color: c.textMuted,
                                      fontStyle: FontStyle.italic,
                                    )
                                  : NexusType.bubble(c),
                            ),
                    ),
                  ),
                  // The row grows out of the message on the hold rather than
                  // appearing all at once; 160ms is long enough to read as the
                  // message opening and short enough not to delay the tap.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    alignment: Alignment.topLeft,
                    child: showActions
                        ? Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: _MessageActions(
                              text: widget.text,
                              liked: widget.liked,
                              disliked: widget.disliked,
                              onLike: widget.onLike,
                              onDislike: widget.onDislike,
                              onRegenerate: widget.onRegenerate,
                            ),
                          )
                        : const SizedBox.shrink(),
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

/// The "N" the assistant speaks through.
///
/// Small on purpose: it marks the side of the thread the words came from and
/// then gets out of the way of the words. The accent at low alpha keeps it on
/// the same page as the rest of the palette instead of putting a second brand
/// in every answer.
class NexusAssistantMark extends StatelessWidget {
  const NexusAssistantMark({super.key, this.speaking = false});

  /// True while this answer is the one being read out loud. A small dot on the
  /// mark's shoulder says which turn the voice belongs to without opening the
  /// action row the whole design keeps hidden.
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final Widget mark = SizedBox(
      key: kNexusAssistantMark,
      width: 22,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.accent.withValues(alpha: 0.14),
              border: Border.all(color: c.accent.withValues(alpha: 0.30)),
            ),
            child: Text(
              'N',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                height: 1,
                color: c.accent,
              ),
            ),
          ),
          if (speaking)
            const Positioned(right: -1, bottom: -1, child: _SpeakerDot()),
        ],
      ),
    );
    // The label belongs to the dot, not to the mark: a tooltip on the mark
    // would take the long press meant for the message that starts beside it.
    return speaking
        ? Tooltip(message: 'Reading this answer aloud', child: mark)
        : mark;
  }
}

/// The pulsing dot that marks the answer being read out loud. It lives on the
/// "N" rather than in the action row so the row can stay hidden until asked.
class _SpeakerDot extends StatefulWidget {
  const _SpeakerDot();

  @override
  State<_SpeakerDot> createState() => _SpeakerDotState();
}

class _SpeakerDotState extends State<_SpeakerDot>
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) => Opacity(
        opacity: 0.45 + 0.55 * Curves.easeInOut.transform(_controller.value),
        child: child,
      ),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.accent,
          border: Border.all(color: c.background, width: 1.5),
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
    this.onOpenSettings,
  });

  final NexusMockMessage message;
  final double bubbleWidth;
  final bool liked;
  final bool disliked;
  final VoidCallback? onLike;
  final VoidCallback? onDislike;
  final VoidCallback? onRegenerate;

  /// Where a locked file card's dialog sends the user: the Brain section, which
  /// is the only place the model that would unlock it lives.
  final VoidCallback? onOpenSettings;

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
            child: NexusArtifactCard(
              artifact: artifact,
              onOpenSettings: onOpenSettings,
            ),
          ),
      ],
    );
  }
}

/// The file a reply wrote: a rounded card with a coloured left edge, a name,
/// and a language.
///
/// It sits *below* the message because that is what it is — an attachment the
/// answer produced, not part of the sentence. The four-point band is the strip
/// every code editor puts beside a file, coloured by language (orange for HTML,
/// blue for Python, and so on), so the eye knows "this is a page" or "this is a
/// script" before it reads the filename.
Color nexusArtifactBand(String language, NexusUiColors c) {
  return switch (language.trim().toLowerCase()) {
    'html' || 'xml' || 'svg' => const Color(0xFFE8743B),
    'python' || 'py' => const Color(0xFF3B82F6),
    'javascript' || 'js' => const Color(0xFFD9A300),
    'typescript' || 'ts' => const Color(0xFF2F74C0),
    'dart' => const Color(0xFF12A6B5),
    'css' || 'scss' => const Color(0xFF38BDF8),
    'json' || 'yaml' || 'yml' => const Color(0xFF8A9A5B),
    'sql' => const Color(0xFF9B6BD6),
    'bash' || 'sh' || 'shell' => const Color(0xFF4EAA25),
    'markdown' || 'md' => const Color(0xFF6B7280),
    _ => c.accent,
  };
}

class NexusArtifactCard extends StatelessWidget {
  const NexusArtifactCard({
    super.key,
    required this.artifact,
    this.onOpenSettings,
  });

  final NexusArtifact artifact;

  /// Where the lock dialog's one button goes. Null when the card is drawn on a
  /// screen that cannot reach Settings, and the dialog then only explains.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    // A file only exists because a model wrote one, and only a brain that can
    // hold the tag writes files. A card that still arrives on a smaller brain —
    // a restored chat from before the model was switched — is shown locked
    // rather than opening a page this model could not have produced.
    final ModelCapabilities caps = ModelCapabilities.current;
    final bool locked = !caps.supportsArtifacts;
    final Color band = nexusArtifactBand(artifact.language, c);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(NexusLayout.card),
          side: BorderSide(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('artifact-${artifact.safeFilename}'),
          onTap: locked
              ? () => showNexusFeatureLocked(
                  context,
                  feature: NexusFeature.artifacts,
                  onOpenSettings: onOpenSettings,
                )
              : () => NexusArtifactPage.open(context, artifact),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // The language's colour, as a full-height edge. It is a child
                // rather than a border so the card's rounded corners clip it
                // cleanly on both sides.
                Container(
                  key: ValueKey<String>(
                    'artifact-edge-${artifact.safeFilename}',
                  ),
                  width: 4,
                  color: locked ? c.offline : band,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 356,
                    minHeight: 66,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: locked
                                ? c.raised
                                : band.withValues(alpha: 0.12),
                            borderRadius: const BorderRadius.all(
                              NexusLayout.tile,
                            ),
                          ),
                          child: Icon(
                            locked
                                ? Icons.lock_outline_rounded
                                : Icons.code_rounded,
                            size: NexusLayout.icon,
                            color: locked ? c.textMuted : band,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                artifact.safeFilename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NexusType.rowTitle(c)
                                    .copyWith(fontSize: 13.5),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                locked
                                    ? caps.lockSubtitle(NexusFeature.artifacts)
                                    : artifact.languageLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NexusType.rowMeta(c)
                                    .copyWith(fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          locked
                              ? Icons.lock_outline_rounded
                              : Icons.open_in_full_rounded,
                          size: 16,
                          color: c.textMuted,
                        ),
                      ],
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
                    size: NexusLayout.icon,
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

/// The key on the send sheet's progress bar, and on its percentage.
const Key kNexusSendProgress = ValueKey<String>('send-progress');
const Key kNexusSendPercent = ValueKey<String>('send-percent');

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
                  const SizedBox(height: 4),
                  // The number beside the bar: a bar alone is a shape, and a
                  // transfer over Wi-Fi can sit at the same shape for a while.
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${(_progress * 100).round()}%',
                      key: kNexusSendPercent,
                      style: NexusType.rowMeta(c).copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
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
                        size: NexusLayout.icon,
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

/// The widest an attachment may draw: 75% of the screen, never wider than the
/// thread column's own cap.
///
/// Shared by photos and documents so the two kinds of attachment cannot drift
/// into different widths as the thread widens on a tablet or a desktop window.
double nexusAttachmentWidth(double screenWidth, double maxWidth) =>
    math.min(maxWidth, screenWidth * 0.75);

/// The name a document is known by.
///
/// The stored copy is renamed with a timestamp, so [path] alone loses
/// "notes.pdf". New lines carry [fileName]; lines written by earlier builds
/// still have the name in their automatic caption, and a path basename is the
/// last honest answer.
String nexusAttachmentFileName({
  String? fileName,
  required String caption,
  required String path,
}) {
  final String explicit = fileName?.trim() ?? '';
  if (explicit.isNotEmpty) return _nexusBaseName(explicit);
  const String prefix = '$kFileCaption: ';
  if (caption.startsWith(prefix)) {
    final String fromCaption = caption.substring(prefix.length).trim();
    if (fromCaption.isNotEmpty) return _nexusBaseName(fromCaption);
  }
  return _nexusBaseName(path);
}

String _nexusBaseName(String path) {
  final String trimmed = path.trim();
  final int slash = math.max(
    trimmed.lastIndexOf('/'),
    trimmed.lastIndexOf(r'\'),
  );
  final String name = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  return name.isEmpty ? 'Attachment' : name;
}

/// True for the caption the shell writes itself, which the file chip already
/// says better with a name and a size. A caption the user typed stays.
bool _nexusAutomaticFileCaption(String caption, String name) =>
    caption.trim() == '$kFileCaption: $name';

int? _nexusFileBytes(String path) {
  try {
    final File file = File(path);
    return file.existsSync() ? file.lengthSync() : null;
  } catch (_) {
    return null;
  }
}

/// A photo in the thread, drawn the way the user's side is drawn everywhere
/// else: flush right, rounded, and with nothing wrapped around it.
///
/// The picture is the message. A card or a bubble behind it would be a second
/// frame around the frame, so the image itself carries the 18-point radius and
/// the caption, when there is one, is a separate capsule underneath. The width
/// is capped at 75% of the screen and the height at [thumbnailHeight], which
/// keeps a portrait shot from taking the whole page.
///
/// Tapping anywhere on the picture — not only its centre — opens
/// [ImageViewerPage]; the caption still opens it too, because a user who taps
/// the words under a photo is asking to see the photo. A file that has gone
/// missing keeps its caption and draws a placeholder: a conversation is worth
/// more than its pictures.
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

  /// The line the turn carried — the words the brain was given context for,
  /// drawn under the picture when there are any.
  final String caption;

  /// True for the user's side. False aligns the picture to the left behind the
  /// assistant's "N", ready for the day the model can send one.
  final bool mine;

  /// The words ML Kit read, or null when there were none. One tap behind the
  /// ⓘ beside the picture's actions.
  final String? detectedText;

  /// The object labels ML Kit found. Empty hides the line.
  final List<String> objects;

  final double maxWidth;

  /// The largest the picture gets. A full-bleed photo in a chat makes every
  /// other line scroll away; this is a reminder of the picture, not the picture.
  static const double thumbnailHeight = 250;

  @override
  Widget build(BuildContext context) {
    final double mediaWidth = nexusAttachmentWidth(
      MediaQuery.sizeOf(context).width,
      maxWidth,
    );
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: <Widget>[
        _AttachmentThumbnails(
          paths: allImagePaths,
          maxWidth: mediaWidth,
          maxHeight: thumbnailHeight,
          mine: mine,
          onOpen: (String image) => ImageViewerPage.open(
            context,
            image,
            caption: caption,
            onSend: () => unawaited(
              showSendToSheet(context, path: image, caption: caption),
            ),
          ),
        ),
        if (caption.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _AttachmentCaptionBubble(
              text: caption,
              mine: mine,
              maxWidth: mediaWidth,
            ),
          ),
        _AttachmentFooter(
          path: path,
          caption: caption,
          mine: mine,
          detectedText: detectedText,
          objects: objects,
        ),
      ],
    );
    final Widget body = GestureDetector(
      key: ValueKey<String>('attachment:$path'),
      behavior: HitTestBehavior.opaque,
      onTap: () => ImageViewerPage.open(
        context,
        path,
        caption: caption,
        onSend: () =>
            unawaited(showSendToSheet(context, path: path, caption: caption)),
      ),
      child: content,
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mediaWidth + (mine ? 0 : 32)),
        child: Semantics(
          label: 'Attached image: $caption',
          child: mine
              ? body
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const NexusAssistantMark(),
                    const SizedBox(width: 10),
                    Flexible(child: body),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The caption under a picture: a capsule on the user's side, plain prose on
/// Nexus's side, where no message ever sits in a bubble.
class _AttachmentCaptionBubble extends StatelessWidget {
  const _AttachmentCaptionBubble({
    required this.text,
    required this.mine,
    required this.maxWidth,
  });

  final String text;
  final bool mine;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    if (!mine) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Text(text, style: NexusType.bubble(c)),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: c.bubbleMine,
          borderRadius: const BorderRadius.all(NexusLayout.bubble),
        ),
        child: Text(text, style: NexusType.bubble(c)),
      ),
    );
  }
}

/// The picture row inside an attachment: one capped image, or a small grid when
/// the turn carries several. Each picture opens its own full-screen viewer,
/// because a tap is how the user says *which* one.
class _AttachmentThumbnails extends StatelessWidget {
  const _AttachmentThumbnails({
    required this.paths,
    required this.maxWidth,
    required this.maxHeight,
    required this.mine,
    required this.onOpen,
  });

  final List<String> paths;
  final double maxWidth;
  final double maxHeight;
  final bool mine;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (paths.length == 1) {
      final String path = paths.first;
      return _Thumb(
        path: path,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        onTap: () => onOpen(path),
      );
    }
    // Two columns at most: a grid that stays inside the 75% cap instead of a
    // strip that runs off the side of the page. 150 is the largest a tile gets,
    // so two pictures on a phone read as a pair rather than as a filmstrip.
    final double tile = math.min(150, (maxWidth - 6) / 2);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Wrap(
        alignment: mine ? WrapAlignment.end : WrapAlignment.start,
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final String path in paths)
            _Thumb(
              path: path,
              width: tile,
              height: tile,
              onTap: () => onOpen(path),
            ),
        ],
      ),
    );
  }
}

/// One picture, clipped to the same 18-point radius the image grammar uses.
///
/// A single picture is sized by its own aspect ratio inside the width and
/// height caps; several are square tiles. Checked before decoding rather than
/// only in the errorBuilder: a file that has been deleted is the common case,
/// the check is one stat, and the placeholder is then on screen in the same
/// frame as the bubble instead of a frame later.
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.path,
    required this.onTap,
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
  });

  final String path;
  final double? width;
  final double? height;
  final double? maxWidth;
  final double? maxHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Widget picture = File(path).existsSync()
        ? Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (BuildContext context, Object error, _) =>
                const _MissingThumbnail(),
          )
        : const _MissingThumbnail();
    final Widget sized = width != null || height != null
        ? SizedBox(width: width, height: height, child: picture)
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth ?? double.infinity,
              maxHeight: maxHeight ?? double.infinity,
            ),
            child: picture,
          );
    return Semantics(
      button: true,
      label: 'Open image',
      child: GestureDetector(
        key: ValueKey<String>('attachment-image:$path'),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          child: sized,
        ),
      ),
    );
  }
}

/// The line of small actions under a picture, and the one small door to what
/// ML Kit saw.
///
/// The tags used to sit in the bubble permanently, which made every photo turn
/// end in a paragraph of machine labels. They are still one tap away — the ⓘ is
/// only drawn when there is something to show — and the actions stay on the
/// user's side, under the caption.
class _AttachmentFooter extends StatefulWidget {
  const _AttachmentFooter({
    required this.path,
    required this.caption,
    required this.mine,
    required this.detectedText,
    required this.objects,
  });

  final String path;
  final String caption;
  final bool mine;
  final String? detectedText;
  final List<String> objects;

  @override
  State<_AttachmentFooter> createState() => _AttachmentFooterState();
}

class _AttachmentFooterState extends State<_AttachmentFooter> {
  bool _open = false;

  bool get _hasEvidence =>
      (widget.detectedText?.trim().isNotEmpty ?? false) ||
      widget.objects.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
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
                    size: NexusLayout.icon,
                    color: _open ? c.accent : c.textMuted,
                  ),
                ),
              // Two doors, because they are two different journeys: "Send to"
              // hands the file to another Nexus device over the mesh, and
              // Share hands it to whatever app the phone offers.
              _AttachmentAction(
                key: kNexusSendTo,
                icon: Icons.send_rounded,
                label: kNexusSendToLabel,
                onTap: () => unawaited(
                  showSendToSheet(
                    context,
                    path: widget.path,
                    caption: widget.caption,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _AttachmentAction(
                key: kNexusShareImage,
                icon: Icons.ios_share_rounded,
                label: kNexusShareLabel,
                onTap: () => unawaited(nexusShareImage(context, widget.path)),
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

class _AttachmentAction extends StatelessWidget {
  const _AttachmentAction({
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
    final c = context.ui;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: c.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: NexusType.rowMeta(c)
                  .copyWith(fontSize: 12.5, color: c.accent),
            ),
          ],
        ),
      ),
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
    return SizedBox(
      width: 240,
      height: 160,
      child: ColoredBox(
        color: c.raised,
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: NexusLayout.iconLarge,
            color: c.textMuted,
          ),
        ),
      ),
    );
  }
}

/// A document in the thread: a capsule with a file mark, its real name, and how
/// large it is.
///
/// Deliberately not a thumbnail. A PDF has no picture to show, and the honest
/// things a conversation can say about a file it cannot read are which file it
/// is and how big it is — so the capsule says both, and taps through to the
/// platform's own viewer. A caption the user typed sits under it in the same
/// text capsule a photo caption uses; the shell's automatic
/// "File attached: notes.pdf" is not repeated, because the chip already says it
/// better.
class NexusFileBubble extends StatelessWidget {
  const NexusFileBubble({
    super.key,
    required this.path,
    required this.caption,
    required this.mine,
    this.fileName,
    this.maxWidth = 320,
  });

  /// Where the kept copy lives.
  final String path;

  /// The line the turn carried: the user's caption, or
  /// "File attached: notes.pdf".
  final String caption;

  /// The name the user knows it by. Null for lines written before the field
  /// existed, in which case the automatic caption is read for it.
  final String? fileName;

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
    final double mediaWidth = nexusAttachmentWidth(
      MediaQuery.sizeOf(context).width,
      maxWidth,
    );
    final String name = nexusAttachmentFileName(
      fileName: fileName,
      caption: caption,
      path: path,
    );
    final int? bytes = _nexusFileBytes(path);
    final String size = bytes == null
        ? 'File unavailable'
        : localFileSize(bytes);
    final bool userCaption =
        caption.trim().isNotEmpty && !_nexusAutomaticFileCaption(caption, name);

    final Widget chip = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: mediaWidth),
      child: Material(
        color: mine ? c.bubbleMine : c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(NexusLayout.pill),
          side: mine ? BorderSide.none : BorderSide(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('file:$path'),
          borderRadius: const BorderRadius.all(NexusLayout.pill),
          onTap: () => unawaited(_open(context)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 18, 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.insert_drive_file_rounded,
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
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NexusType.rowTitle(
                          c,
                        ).copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        size,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
    );

    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: <Widget>[
        chip,
        if (userCaption)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _AttachmentCaptionBubble(
              text: caption,
              mine: mine,
              maxWidth: mediaWidth,
            ),
          ),
      ],
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mediaWidth + (mine ? 0 : 32)),
        child: Semantics(
          button: true,
          label: '$name, $size',
          child: mine
              ? content
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const NexusAssistantMark(),
                    const SizedBox(width: 10),
                    Flexible(child: content),
                  ],
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
                  Icon(
                    Icons.warning_amber_rounded,
                    size: NexusLayout.icon,
                    color: ink,
                  ),
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

/// The controls under a Nexus message: copy, speak, the two thumbs and
/// regenerate.
///
/// Muted 16dp glyphs under the answer — close enough to the sentence they
/// belong to that there is no doubt which line they act on. The row is built
/// only while the message is held, so a page of answers is a page of words.
/// The failure notice reuses it with the speaker turned off, because a failure
/// can be copied but not replayed.
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
      icon: Icon(
        icon,
        size: NexusLayout.icon,
        color: active ? c.accent : c.textMuted,
      ),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }
}
