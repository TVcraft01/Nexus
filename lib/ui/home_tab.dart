// The Home screen: the thread, the greeting, and the pieces only it uses.
//
// Split out of `main_ui.dart` so the shell, the drawer and the other three
// screens fit in a head. A part rather than a library of its own because every
// widget here reads the shell's private helpers and the session state around
// them; making those public to cross a file boundary would be a bigger change
// than the one this split is for.

part of '../main_ui.dart';

/// The Claude-shaped home screen: a greeting, a short thread, and the composer
/// pinned at the bottom above the keyboard.
class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    this.refreshEpoch = 0,
    this.wide = false,
    this.onOpenSettings,
  });

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

  /// Switches the shell to Settings, for the one place a chat needs it: the
  /// lock dialog a small model shows. Null in a widget test that pumps this tab
  /// on its own, and the dialog then offers only the way out.
  final VoidCallback? onOpenSettings;

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

  /// How often a streaming answer may rebuild the thread. Tokens can arrive
  /// far faster than the screen can paint, and a `setState` per token makes
  /// the isolate do layout work nobody sees. 50ms is 20 repaints a second —
  /// smooth to the eye, and a fifth of the work.
  static const Duration _streamPaintEvery = Duration(milliseconds: 50);

  /// The trailing edge of that throttle: the newest pending paint, and the
  /// timer that will run it. Null means the last token has already painted.
  Timer? _streamPaint;
  VoidCallback? _streamPaintPending;
  DateTime _lastStreamPaint = DateTime.fromMillisecondsSinceEpoch(0);

  /// Files that arrive over the LAN while this screen is alive. A completed
  /// transfer is a line in the conversation, and the only thing that can put
  /// it there without the user tapping anything — the listener runs in the
  /// service, not in a page.
  StreamSubscription<ReceivedFile>? _receivedFiles;

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

  /// The one-time "your PC is connected" banner. The router raises the notice
  /// once per session, when the PC comes online while Qwen 0.5B is selected;
  /// this state is just whether the banner is on screen right now.
  bool _hiveBanner = false;

  /// The router's notices while this screen is alive. The chat is where a route
  /// change is said out loud — a pill when the PC drops, a banner when it
  /// arrives with more compute than the phone.
  StreamSubscription<HiveNotice>? _hiveNotices;

  /// The slow check behind the chip.
  ///
  /// A PC that wakes up while the user is sitting on the welcome screen should
  /// light the chip and raise its banner without waiting for a question. Fifteen
  /// seconds is slow enough to be one `GET /api/tags` on the LAN, fast enough
  /// that the upgrade arrives while the user is still looking at the phone.
  Timer? _hiveWatch;

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
    final LocalAiService brain = LocalAiService.current;
    // The router is the one place that knows whether the PC is answering. Ask
    // it first: when a paired PC is online, the route is PC even though a model
    // file is on the phone, and a device-first probe would report the wrong
    // source on the chip and in the line above the composer.
    final bool onPc = brain is HiveRouter && await brain.refresh();
    final AiStatus status = onPc
        ? const AiStatus(AiSource.pc)
        : await AiStatus.detect();
    // The same probe answers the gate: which brain is behind the next answer is
    // exactly which features may be offered. Recorded before the frame so the
    // `+` sheet opened in the same second already reads the truth.
    ModelCapabilities.observe(status);
    if (mounted) setState(() => _brain = status);
  }

  /// The route changed outside a question — the slow probe found the PC or
  /// watched it leave. The chip already follows the notifier; this re-reads the
  /// source so the line above the composer cannot keep saying the old machine.
  void _onHiveCompute() {
    if (!mounted) return;
    unawaited(_readBrain());
  }

  /// A route change from the router: a pill in the conversation when the PC
  /// drops, the one-time upgrade banner when it arrives on a small model.
  void _onHiveNotice(HiveNotice notice) {
    if (!mounted) return;
    switch (notice) {
      case HiveNotice.pcConnectedWeakModel:
        setState(() => _hiveBanner = true);
      case HiveNotice.pcDisconnected:
        _showHivePill(kNexusPcDisconnectedPill);
    }
  }

  /// Puts the router's sentence in the conversation.
  ///
  /// The thread while the chat is up, a live turn while the room is live: the
  /// notice is about the answer in flight, and the page the user is looking at
  /// is the one that should say it.
  void _showHivePill(String text) {
    if (_liveOpen) {
      setState(() {
        _addLiveTurn(NexusMockMessage(text, system: true));
      });
      _syncLive();
      return;
    }
    setState(() {
      _thread.add(NexusMockMessage(text, system: true));
    });
    _persistThread();
    _scrollToLatest();
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
    _receivedFiles = FileTransferService.instance.incoming.listen(
      _onFileReceived,
    );
    _hiveNotices = HiveRouter.notices.listen(_onHiveNotice);
    HiveRouter.compute.addListener(_onHiveCompute);
    final LocalAiService brain = LocalAiService.current;
    if (brain is HiveRouter) {
      _hiveWatch = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) unawaited(brain.refresh());
      });
    }
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
      // Coming back to the app is the moment a PC that was asleep, or a phone
      // that was on another Wi-Fi, has changed. Re-reading the route here is
      // what lets the chip and the one-time banner be true without a poll.
      unawaited(_readBrain());
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
      // The Core-15 additions that put something else in front of the user:
      // the SMS and mail composers, the map chooser, the projection dialog and
      // the clock app's lists. Without these, answering "text mom" out loud
      // backgrounded Nexus and closed the conversation page.
      call.action == 'send_sms' ||
      call.action == 'send_email' ||
      call.action == 'navigate_to' ||
      call.action == 'screenshot' ||
      call.action == 'show_alarms' ||
      call.action == 'cancel_alarms' ||
      call.action == 'cancel_timers' ||
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
    _streamPaint?.cancel();
    _streamPaint = null;
    _streamPaintPending = null;
    ChatLog.instance.removeListener(_onChatLog);
    unawaited(_receivedFiles?.cancel());
    _receivedFiles = null;
    unawaited(_hiveNotices?.cancel());
    _hiveNotices = null;
    HiveRouter.compute.removeListener(_onHiveCompute);
    _hiveWatch?.cancel();
    _hiveWatch = null;
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

  /// Applies memory tags the user typed, and shows the pill for each change.
  ///
  /// The same line the model's own tags produce, because it is the same event:
  /// the vault changed, and the user should be told which fact it was.
  Future<void> _applyTypedMemoryTags(List<MemoryTag> tags) async {
    final List<String> lines = await MemoryService.instance.applyTags(tags);
    if (!mounted || lines.isEmpty) return;
    setState(() {
      for (final String line in lines) {
        _thread.add(NexusMockMessage(line, system: true));
      }
    });
    _persistThread();
    _scrollToLatest();
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
    // A tag the user typed is a command to the vault rather than a message:
    // `[remember: …]` is taken out of the bubble (and out of what the model is
    // asked) and applied, exactly as the model's own tags are.
    final MemoryTagSplit typed = splitMemoryTags(_message.text.trim());
    final String text = typed.text.trim();
    final List<_PendingAttachment> pending = List<_PendingAttachment>.of(
      _pendingAttachments,
    );
    // A picture waiting in the composer is a reason to send even with an empty
    // field: the attachment is half the message, and the caption below is the
    // other half.
    if (text.isEmpty && pending.isEmpty) {
      // A message that was *only* a tag still has work to do.
      if (typed.hasTags) {
        _message.clear();
        unawaited(_applyTypedMemoryTags(typed.tags));
      }
      return;
    }
    // The only other haptic: the send. A message leaving the composer is the
    // one moment in the thread that deserves a tick under the thumb.
    unawaited(HapticFeedback.lightImpact());
    // Read once, here: whether this turn is answered out loud is a fact about
    // how it was dictated, and the flag is cleared by the send that consumes
    // it so the next typed question is not spoken on the strength of the last
    // spoken one.
    final bool spoken = _voiceTurn;
    _voiceTurn = false;
    // Anything the user just told Nexus about themselves is remembered before
    // the answer is asked for, so the same turn can already be answered with it.
    // The original text, tags included: [absorb] applies a typed tag as a
    // command, and the sentence detector reads the words around it.
    // Fire-and-forget: a file write must never delay the bubble.
    unawaited(MemoryService.instance.absorb(_message.text));
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
          attachmentName: file.picked.name,
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
      // Material's own sheet transition, only faster and on an ease-out: the
      // default 250ms is right, the default curve is not. Nothing custom is
      // layered on top — the framework still owns the route, the barrier and
      // the drag-to-dismiss.
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 250),
        reverseDuration: Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutCubic,
      ),
      builder: (BuildContext context) =>
          _AttachmentSheet(onOpenSettings: widget.onOpenSettings),
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
              attachmentName: entry.attachmentName,
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
            attachmentName: message.attachmentName,
            visionText: message.visionText,
            visionLabels: message.visionLabels,
            reasoning: message.reasoning,
          ),
    ]);
  }

  /// A file arrived: one bubble saying who sent it, carrying the picture when
  /// it is one. Saved with the thread immediately, because a received file is
  /// part of the conversation even if the app is closed a second later.
  void _onFileReceived(ReceivedFile file) {
    if (!mounted) return;
    setState(() {
      _thread.add(
        NexusMockMessage(
          'Received ${file.name} from ${file.fromName}',
          system: true,
          imagePath: file.isImage ? file.path : null,
          filePath: file.isImage ? null : file.path,
          attachmentName: file.name,
        ),
      );
    });
    _persistThread();
    _scrollToLatest();
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
    // The switch says what the user wants; the capability says what this brain
    // can use. A locked feature appends nothing at all — a page of snippets
    // handed to a 0.5B model is a question it answers about the snippets.
    if (ComposerSettings.instance.webSearchEnabled &&
        ModelCapabilities.current.supportsWebSearch) {
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
          // A memory tag is an instruction to the vault, not words for the
          // bubble: it is cut while it streams, so the user never watches
          // `[remember: 'name' =` arrive and then vanish.
          final String visible = splitMemoryTags(
            nexusStreamingProse(split.answer),
            streaming: true,
          ).text;
          final String reasoning = split.reasoning.trim();
          if (visible.trim().isEmpty && split.answer.contains('{')) {
            continue;
          }
          shown = shown || visible.isNotEmpty || reasoning.isNotEmpty;
          // A half-written answer is a placeholder, not a reply: the words are
          // on screen as they arrive, and the copy/speaker row waits for the
          // sentence to be whole. See [NexusChatBubble.thinking]. The reasoning
          // streams above it in its own bubble while [split.thinking] is true.
          _paintStreamSoon(() {
            if (!mounted || index >= _thread.length) return;
            setState(
              () => _thread[index] = NexusMockMessage(
                visible.isEmpty ? kNexusThinking : visible,
                thinking: true,
                reasoning: reasoning.isEmpty ? null : reasoning,
              ),
            );
            _scrollToLatestSoon();
          });
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
    // The stream is over: the last words must not wait for the 50ms window.
    _flushStreamPaint();
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
    // The vault's tags come out before anything else reads the words: a tag is
    // a balanced `[...]` region, and the JSON reader below reads every one of
    // those into prose — the user would be shown `remember: 'name' = 'X'`,
    // which is neither the tag nor a sentence. A failure carries no tags.
    final MemoryTagSplit memory = failed
        ? MemoryTagSplit(text: reply, tags: const <MemoryTag>[])
        : splitMemoryTags(reply);
    if (!failed) reply = memory.text.trim();
    // Grounded in the question, not just in the model's confidence: a tag for
    // a fact the user never wrote is the model describing itself, and the
    // vault is the user's, not the model's (see [memoryGroundedIn]).
    final List<String> memoryLines = await MemoryService.instance.applyTags(
      memory.tags,
      said: prompt,
    );
    // An answer that contains an action request is not an answer: it is the
    // model asking this phone to do something. The request is stripped and run
    // here, before anything is shown, and the thread gets whatever prose was
    // left plus the shell's line about what happened — never the JSON that
    // asked for it. A reply that is *nearly* an action — an unknown name, a
    // missing argument, an object that is not an action at all — has no calls
    // to run and becomes the bubble below, with its JSON read into words.
    if (!failed && reply.isNotEmpty) {
      final NexusActionIntercept intercept = interceptSystemActions(reply);
      if (intercept.acted) {
        await _runActions(
          intercept,
          index,
          spoken: spoken,
          reasoning: reasoning,
        );
        // A reply can both ask for an action and remember a fact; the pills for
        // the facts were already written, so they are shown after the action's
        // own line rather than lost with the early return.
        if (mounted && memoryLines.isNotEmpty) {
          setState(() {
            for (final String line in memoryLines) {
              _thread.add(NexusMockMessage(line, system: true));
            }
          });
          _persistThread();
          _scrollToLatest();
        }
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
    if (!mounted || index >= _thread.length) return;
    if (reply.isEmpty && memoryLines.isNotEmpty) {
      // The whole reply *was* the tag. There is nothing to say, so the pill is
      // the answer and the placeholder it replaced goes away with it.
      setState(() {
        _thread.removeAt(index);
        for (final (int at, String line) in memoryLines.indexed) {
          _thread.insert(index + at, NexusMockMessage(line, system: true));
        }
      });
      _persistThread();
      _scrollToLatest();
      return;
    }
    if (reply.isEmpty) {
      // The whole reply was a tag the vault refused (a fact the user never
      // said), so there is neither an answer nor a pill. An empty bubble with
      // the message actions under it is a question that looks unanswered on
      // purpose; say the one sentence instead.
      reply = kNexusNoAnswerText;
    }
    setState(
      () => _thread[index] = NexusMockMessage(
        reply,
        failed: failed,
        reasoning: reasoning,
      ),
    );
    if (memoryLines.isNotEmpty) {
      setState(() {
        for (final (int at, String line) in memoryLines.indexed) {
          _thread.insert(index + 1 + at, NexusMockMessage(line, system: true));
        }
      });
    }
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

  /// Runs a stream-driven repaint now, or keeps the newest one for the end of
  /// the current 50ms window.
  ///
  /// This is a leading-and-trailing throttle: the first token of an answer is
  /// painted immediately (the placeholder has to leave at once), a burst of
  /// tokens inside the window collapses to the last one, and the timer always
  /// ends with the newest text on screen. The callback is replaced rather than
  /// queued, so fifty tokens cost one closure and one rebuild.
  void _paintStreamSoon(VoidCallback paint) {
    final DateTime now = DateTime.now();
    final Duration since = now.difference(_lastStreamPaint);
    if (_streamPaint == null && since >= _streamPaintEvery) {
      _lastStreamPaint = now;
      paint();
      return;
    }
    _streamPaintPending = paint;
    _streamPaint ??= Timer(
      since < _streamPaintEvery ? _streamPaintEvery - since : Duration.zero,
      _flushStreamPaint,
    );
  }

  /// Paints the newest token that the throttle held back. Called by the timer
  /// and by the end of every stream, so a finished answer never waits 50ms for
  /// its last words.
  void _flushStreamPaint() {
    _streamPaint?.cancel();
    _streamPaint = null;
    final VoidCallback? paint = _streamPaintPending;
    _streamPaintPending = null;
    if (!mounted || paint == null) return;
    _lastStreamPaint = DateTime.now();
    paint();
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
    // The one haptic the gesture gets: one short tap under the thumb at the
    // moment the hold becomes speech. The release does not buzz — the words
    // appearing in the field are the feedback for that.
    unawaited(HapticFeedback.lightImpact());
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
    if (ComposerSettings.instance.webSearchEnabled &&
        ModelCapabilities.current.supportsWebSearch) {
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
          final String visible = splitMemoryTags(
            nexusStreamingProse(thought.answer),
            streaming: true,
          ).text;
          if (visible.trim().isEmpty &&
              (buffer.toString().contains('{') || thought.thinking)) {
            continue;
          }
          // The words are the page now: the orb keeps its working colour while
          // the answer is being written, but the large type shows the answer
          // arriving instead of leaving the screen on "Thinking…".
          _paintStreamSoon(() {
            if (!mounted || !_liveOpen || turn != _liveTurns) return;
            setState(() {
              _liveAnswering = true;
              _liveAnswerText = visible;
            });
            _syncLive();
          });
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
    _flushStreamPaint();
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
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondary,
            Widget child,
          ) => FadeTransition(
            // The standard route animation, curved rather than linear: a custom
            // slide would compete with the platform's own back gesture, and the
            // page is a room change rather than a card being dealt.
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOut,
              reverseCurve: Curves.easeInOut,
            ),
            child: child,
          ),
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
        // The composer rides the keyboard: the body shrinks by the inset rather
        // than letting the field sit underneath the keys.
        resizeToAvoidBottomInset: true,
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
              if (_hiveBanner)
                _PcConnectedBanner(
                  onDismiss: () => setState(() => _hiveBanner = false),
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
                    // The thread paints into its own layer: a streaming answer
                    // rebuilding one bubble cannot force the header, the
                    // banners and the composer to repaint with it.
                    child: RepaintBoundary(
                      child: SingleChildScrollView(
                        controller: _threadScroll,
                        // The platform's responsive physics rather than the
                        // clamping default: the list gives a little under the
                        // finger instead of stopping dead at the last message.
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          NexusLayout.pageGutter,
                          20,
                          NexusLayout.pageGutter,
                          20,
                        ),
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
                                      // A captured photo or screenshot: a rounded
                                      // picture on the user's side, with the caption
                                      // as its own capsule underneath. It shares the
                                      // message's caption, so nothing about this line
                                      // is a new kind of entry in the thread.
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
                                      // A picked document: a capsule with its real
                                      // name and size, not a thumbnail. Tapping it
                                      // opens the file with the platform's own
                                      // viewer.
                                      : message.filePath != null
                                      ? NexusFileBubble(
                                          path: message.filePath!,
                                          caption: message.text,
                                          mine: message.mine,
                                          fileName: message.attachmentName,
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
                                          onOpenSettings: widget.onOpenSettings,
                                        ),
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
                        size: NexusLayout.icon,
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

/// The one-time notice that the hive just got bigger.
///
/// Shown by [HiveRouter] when a paired PC comes online while Qwen 0.5B is the
/// selected model. One line, one X, and never again this session — the router
/// owns the "once" so a rebuilt screen cannot replay it.
class _PcConnectedBanner extends StatelessWidget {
  const _PcConnectedBanner({required this.onDismiss});

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
            key: const ValueKey<String>('hive-pc-banner'),
            color: c.accent.withValues(alpha: 0.10),
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(NexusLayout.tile),
              side: BorderSide(color: c.accent.withValues(alpha: 0.3)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 2, 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.computer_rounded,
                    size: NexusLayout.icon,
                    color: c.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      kNexusPcConnectedBanner,
                      style: NexusType.rowTitle(c)
                          .copyWith(fontSize: 13, height: 1.35),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('hive-pc-banner-dismiss'),
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close_rounded,
                      size: NexusLayout.icon,
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
                                size: NexusLayout.icon,
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
                      size: NexusLayout.icon,
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
          const SizedBox(width: 8),
          // The chip sits against the wordmark because it is what Nexus *is*
          // right now, not a control on the other side of the header. It keeps
          // its own intrinsic width and the speaker stays pinned right.
          const _HiveChip(),
          const Spacer(),
          const _SpeakRepliesButton(),
        ],
      ),
    );
  }
}

/// Which machine is answering, as a tiny chip beside the wordmark.
///
/// The phone glyph is the default and the quiet one: it is what the app does on
/// its own, and it should not compete with the conversation. The PC glyph is the
/// accent colour because it is the upgrade — the answer just got bigger without
/// the user changing a setting — and the router's [HiveRouter.compute] is the
/// one source for both the chip and the route itself.
class _HiveChip extends StatelessWidget {
  const _HiveChip();

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return ValueListenableBuilder<HiveCompute>(
      valueListenable: HiveRouter.compute,
      builder: (BuildContext context, HiveCompute compute, Widget? _) {
        final bool pc = compute == HiveCompute.pc;
        final Color ink = pc ? c.accent : c.textMuted;
        return Tooltip(
          message: pc
              ? 'Answers come from your PC'
              : 'Answers come from this device',
          child: Container(
            key: const ValueKey<String>('hive-chip'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: pc ? c.accent.withValues(alpha: 0.12) : c.raised,
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              border: pc
                  ? Border.all(color: c.accent.withValues(alpha: 0.3))
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  pc ? Icons.computer_rounded : Icons.smartphone_rounded,
                  size: 13,
                  color: ink,
                ),
                const SizedBox(width: 5),
                Text(
                  pc ? 'PC Compute' : 'On-Device',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexusType.rowMeta(c).copyWith(
                    fontSize: 11.5,
                    height: 1.1,
                    color: ink,
                    fontWeight: pc ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
