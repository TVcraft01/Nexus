// Settings and the pages it opens: appearance, voice, the brain, the memory
// vault and the privacy pages.
//
// A part of the shell rather than a library: these pages read and write the
// app-wide settings singletons and the shell's own rows, confirmations and
// keys.

part of '../main_ui.dart';

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// The key on the Brain section's download bar — the filled part, so a test can
/// read how far along a fetch is without measuring pixels.
const Key kNexusBrainProgress = Key('nexus-brain-progress');

/// The same bar, for the vision model. Two downloads share one bar widget, and
/// two bars on screen at once would need to be told apart by a test.
const Key kNexusVisionProgress = Key('nexus-vision-progress');

/// The desktop-only row that opens the phone pairing code.
const Key kNexusPairPhoneRow = Key('nexus-pair-phone-row');

/// The row that opens the Server Agent — the only screen in the app that can
/// change a machine other than this one.
const Key kNexusServerAgentRow = Key('nexus-server-agent-row');

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
    this.vision,
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

  /// The eyes the Vision rows manage. Null builds the app's own service; a test
  /// supplies one whose files are a temp directory, which is what makes the
  /// download, the delete and the "not here" row provable without 1.8 GB.
  final VlmVisionService? vision;

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

  /// The eyes the Vision rows report and manage — the same object the thread
  /// asks for a picture, so downloading here is what changes the next photo.
  late final VlmVisionService _vision =
      widget.vision ?? VlmVisionService.instance;

  /// Which vision models are on this device, and how many bytes each occupies.
  Map<String, bool> _visionPresent = const <String, bool>{};
  Map<String, int> _visionBytes = const <String, int>{};

  /// The model being fetched right now, if any — two downloads at once would
  /// compete for the same connection and the same row.
  VisionModelPair? _visionDownloading;
  double _visionProgress = 0;

  /// The model whose last download failed, so the failure row can retry it
  /// rather than guess.
  VisionModelPair? _visionFailed;
  String? _visionError;

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
    unawaited(HapticFeedback.lightImpact());
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
    unawaited(_refreshVision());
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
      unawaited(_refreshVision());
    }
  }

  /// Re-reads which vision models are installed, and tells the service so a
  /// photo taken now uses one. Two file checks per model: never a load.
  Future<void> _refreshVision() async {
    final Map<String, bool> present = <String, bool>{};
    final Map<String, int> bytes = <String, int>{};
    for (final VisionModelPair pair in kVisionPairs) {
      final VisionModelFiles files = _vision.filesFor(pair);
      final bool here = await files.isPresent();
      present[pair.id] = here;
      bytes[pair.id] = here ? await files.sizeBytes() : 0;
    }
    await _vision.refresh();
    if (!mounted) return;
    setState(() {
      _visionPresent = present;
      _visionBytes = bytes;
    });
  }

  /// Fetches [pair]'s two files, with the progress the row shows.
  ///
  /// Both files or neither: [VisionModelFiles.download] only answers true when
  /// the pair is verified on disk, so a failure leaves the fallback exactly where
  /// it was rather than a phone that looks like it can see.
  Future<void> _downloadVision(VisionModelPair pair) async {
    if (_visionDownloading != null) return;
    setState(() {
      _visionDownloading = pair;
      _visionProgress = 0;
      _visionFailed = null;
      _visionError = null;
    });
    final bool done = await _vision
        .filesFor(pair)
        .download(
          onProgress: (double progress) {
            if (mounted) setState(() => _visionProgress = progress);
          },
        );
    if (!mounted) return;
    setState(() {
      _visionDownloading = null;
      if (!done) {
        _visionFailed = pair;
        _visionError =
            '${pair.label} did not download. Check your connection and try '
            'again — nothing was kept.';
      }
    });
    await _refreshVision();
  }

  /// Asks before deleting a vision model, and says what its absence costs:
  /// photos go back to being read rather than looked at.
  Future<void> _confirmDeleteVision(VisionModelPair pair) async {
    final int megabytes = _megabytes(_visionBytes[pair.id] ?? pair.bytes);
    final bool confirmed = await showNexusConfirm(
      context,
      title: kNexusDeleteModelTitle,
      message:
          'This frees $megabytes MB from ${pair.label}, but photos will go '
          'back to text and object detection if no other vision model is '
          'installed.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    final int freed = await _vision.filesFor(pair).delete();
    await _vision.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Freed ${_megabytes(freed)} MB.')));
    await _refreshVision();
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
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          0,
          NexusLayout.gutter,
          28,
        ),
        children: <Widget>[
          const NexusSectionLabel('Theme', first: true),
          NexusRow(
            title: 'Follow system',
            subtitle: 'Use your phone’s light and dark setting',
            leading: const NexusIconTile(Icons.brightness_auto_outlined),
            trailing: Switch(
              value: widget.followSystem,
              onChanged: (bool value) {
                unawaited(HapticFeedback.lightImpact());
                widget.onFollowSystemChanged?.call(value);
              },
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
            // The page is no longer only about the microphone: it holds the
            // vault, so the row has to promise that too, or the one screen that
            // shows what Nexus remembers is found by accident.
            subtitle: 'Voice, memory, and what stays on this device',
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
          // What Nexus may touch, and the record of what it has. The one screen
          // in the app that can take a capability away, so it sits beside the
          // privacy promise rather than inside the developer log.
          const NexusSectionLabel('Connections'),
          NexusRow(
            key: kNexusConnectionsRow,
            title: 'Connections',
            subtitle: 'What Nexus can do, and what it did lately',
            leading: const NexusIconTile(Icons.hub_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const ConnectionsPage(),
              ),
            ),
          ),
          // A server is a computer the user owns, not a device Nexus paired
          // with: there is no handshake and no shared key, only a login they
          // already have. The page it opens holds the only shell text the app
          // will ever run on another machine (see server_playbooks.dart), which
          // is why it is filed under an advanced row rather than offered in the
          // chat.
          const NexusSectionLabel('Devices'),
          NexusRow(
            key: kNexusServerAgentRow,
            title: 'Server Agent (Advanced)',
            subtitle: 'Set up software on a Linux server over SSH',
            leading: const NexusIconTile(Icons.dns_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const ServerAgentPage(),
              ),
            ),
          ),
          // The desktop half of pairing. A phone scans this; nobody types an
          // address, because the code already carries the one the PC found.
          if (nexusIsDesktopApp) ...<Widget>[
            const NexusSectionLabel('This PC'),
            NexusRow(
              key: kNexusPairPhoneRow,
              title: 'Pair Phone',
              subtitle: 'Show a code your phone scans — no address to type',
              leading: const NexusIconTile(Icons.phone_iphone_rounded),
              trailing: const NexusChevron(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (routeContext) => const PairPhonePage(),
                ),
              ),
            ),
          ],
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
          // The eyes. Two models, because one size did not fit: SmolVLM is
          // 545 MB and runs on this class of phone; Moondream2 describes better
          // and needs memory this one does not have. Both are optional — the
          // service picks the best installed model that fits, and without
          // either ML Kit still reads the picture.
          const NexusSectionLabel('Vision'),
          for (final VisionModelPair pair in kVisionPairs)
            _VisionChoiceRow(
              pair: pair,
              present: _visionPresent[pair.id] ?? false,
              onTap:
                  _visionDownloading == null &&
                      !(_visionPresent[pair.id] ?? false)
                  ? () => _downloadVision(pair)
                  : null,
            ),
          if (_visionDownloading != null)
            _BrainProgress(
              barKey: kNexusVisionProgress,
              progress: _visionProgress,
              label: _visionDownloading!.label,
              megabytes: _visionDownloading!.megabytes,
            ),
          for (final VisionModelPair pair in kVisionPairs)
            if (_visionPresent[pair.id] ?? false)
              NexusRow(
                title: 'Delete ${pair.label}',
                subtitle:
                    'Frees ${_megabytes(_visionBytes[pair.id] ?? 0)} MB. Photos '
                    'use the other vision model, or text and objects',
                leading: const NexusIconTile(Icons.delete_outline_rounded),
                // Red, and it asks first: these are the largest things this
                // app ever asks a phone to carry.
                dangerTitle: true,
                onTap: () => _confirmDeleteVision(pair),
              ),
          if (_visionError != null)
            NexusRow(
              title: 'Vision download failed',
              subtitle: _visionError,
              leading: const NexusIconTile(Icons.warning_amber_rounded),
              // The row that reports the failure is also the retry, for the
              // model that failed.
              onTap: _visionFailed == null
                  ? null
                  : () => _downloadVision(_visionFailed!),
            ),
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

/// One vision model in the Brain section: what it is, whether it is on the
/// disk, and no way to be *selected*.
///
/// There is nothing to switch between, which is the one way these rows differ
/// from [_ModelChoiceRow]: the service uses the best installed model that fits,
/// and ML Kit when none does. So the tick reports the download rather than a
/// preference, and a tap on an undownloaded row is the download.
class _VisionChoiceRow extends StatelessWidget {
  const _VisionChoiceRow({
    required this.pair,
    required this.present,
    required this.onTap,
  });

  /// The model this row is about.
  final VisionModelPair pair;

  /// Whether both files are on this device.
  final bool present;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return NexusRow(
      title: pair.label,
      subtitle: present
          ? '${pair.megabytes} MB · on this device\n${pair.blurb}'
          : '${pair.megabytes} MB · tap to download\n${pair.blurb}',
      leading: NexusIconTile(
        present ? Icons.visibility_rounded : Icons.visibility_outlined,
      ),
      trailing: present
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
    this.barKey = kNexusBrainProgress,
  });

  /// 0 to 1, from [Llm.download] through [OnDeviceAiService.download].
  final double progress;

  final String label;
  final int megabytes;

  /// The filled part's key. Two downloads share this widget, and a test that
  /// cannot say which bar it measured has measured neither.
  final Key barKey;

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
                      key: barKey,
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
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          8,
          NexusLayout.gutter,
          28,
        ),
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
        padding: const EdgeInsets.fromLTRB(
          NexusLayout.gutter,
          8,
          NexusLayout.gutter,
          28,
        ),
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

/// The Privacy row into the memory vault, and the vault's own controls.
///
/// Keyed because the point of the page is that a user can *prove* what is
/// stored: the tests reach the same rows a thumb does.
const Key kNexusMemoryVaultRow = Key('nexus-memory-vault');
const String kNexusMemoryVaultRowLabel = 'What Nexus knows about you';
const Key kNexusMemoryAdd = Key('nexus-memory-add');
const Key kNexusMemoryDeleteAll = Key('nexus-memory-delete-all');
const String kNexusMemoryDeleteAllLabel = 'Delete All Memory';
const Key kNexusMemoryTopicField = Key('nexus-memory-topic');
const Key kNexusMemoryFactField = Key('nexus-memory-fact');
const Key kNexusMemorySave = Key('nexus-memory-save');

/// \"What Nexus knows about you\": the whole vault, one row per fact.
///
/// A list rather than a paragraph because this is the page a user opens when
/// they want to *check*, and a check is done row by row: what it is about, what
/// it says, and a bin beside it. The two other controls are the only two edits a
/// vault needs — add one, or delete them all — and the second one asks first.
///
/// Everything here is read from [MemoryService], the same file the prompt reads,
/// so this page cannot show a comfortable version of the truth.
class NexusMemoryVaultPage extends StatefulWidget {
  const NexusMemoryVaultPage({super.key});

  @override
  State<NexusMemoryVaultPage> createState() => _NexusMemoryVaultPageState();
}

class _NexusMemoryVaultPageState extends State<NexusMemoryVaultPage> {
  final MemoryService _memory = MemoryService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_memory.attach());
    _memory.addListener(_onChanged);
  }

  @override
  void dispose() {
    _memory.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Deletes one fact, and says which one went. No dialog: the bin is beside the
  /// row it deletes, and a confirmation in front of every line would make the
  /// vault feel dangerous to tidy.
  Future<void> _forget(MemoryNote note) async {
    final bool gone = await _memory.forgetNote(note);
    if (!mounted || !gone) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Forgot ${note.topicLabel}.'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// The `+`: one fact, typed by hand. Two fields because the file has two —
  /// the topic is what makes a later correction replace this fact instead of
  /// sitting beside it.
  Future<void> _addFact() async {
    final TextEditingController topic = TextEditingController();
    final TextEditingController fact = TextEditingController();
    final (String, String)? added = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext dialogContext) {
        final NexusUiColors c = dialogContext.ui;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('Add a fact', style: NexusType.rowTitle(c)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: kNexusMemoryTopicField,
                controller: topic,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Topic',
                  hintText: 'e.g. name',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: kNexusMemoryFactField,
                controller: fact,
                decoration: const InputDecoration(
                  labelText: 'Fact',
                  hintText: 'e.g. TVCraft',
                ),
                onSubmitted: (_) =>
                    Navigator.of(dialogContext)
                        .pop((topic.text.trim(), fact.text.trim())),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel', style: TextStyle(color: c.textMuted)),
            ),
            TextButton(
              key: kNexusMemorySave,
              onPressed: () =>
                  Navigator.of(dialogContext)
                      .pop((topic.text.trim(), fact.text.trim())),
              child: Text('Remember', style: TextStyle(color: c.accent)),
            ),
          ],
        );
      },
    );
    topic.dispose();
    fact.dispose();
    if (added == null || !mounted) return;
    if (added.$2.isEmpty) return;
    await _memory.rememberFact(
      added.$1.isEmpty ? kMemoryNoteTopic : added.$1,
      added.$2,
    );
  }

  Future<void> _confirmDeleteAll() async {
    if (_busy) return;
    final bool confirmed = await showNexusConfirm(
      context,
      title: 'Delete all memory?',
      message:
          'This deletes every fact Nexus has learned about you. It cannot be '
          'undone, and the next answer will be from a blank slate.',
      confirmLabel: 'Delete everything',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    await _memory.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Memory deleted.'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final List<MemoryNote> notes = _memory.notes;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: const Text(kNexusMemoryVaultRowLabel),
        actions: <Widget>[
          IconButton(
            key: kNexusMemoryAdd,
            tooltip: 'Add a fact',
            icon: const Icon(Icons.add_rounded),
            onPressed: _addFact,
          ),
        ],
      ),
      body: ListView(
        // The bar at the side of a landscape phone is over the screen, not
        // beside it: without its inset the bin on each row is under the nav
        // buttons, which is the one control this page exists for.
        padding: EdgeInsets.fromLTRB(
          20 + MediaQuery.paddingOf(context).left,
          12,
          20 + MediaQuery.paddingOf(context).right,
          28,
        ),
        children: <Widget>[
          Text(
            'Facts Nexus has learned, kept in one file on this phone. They are '
            'given to the model on this device and never sent anywhere.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          const SizedBox(height: 20),
          if (notes.isEmpty)
            Text(
              'Nothing yet. Tell Nexus something about yourself in a chat, or '
              'add a fact with the + button.',
              key: const Key('nexus-memory-empty'),
              style: NexusType.rowTitle(c).copyWith(color: c.textMuted),
            )
          else
            for (final MemoryNote note in notes)
              NexusRow(
                key: ValueKey<String>('memory-${note.topic}-${note.fact}'),
                title: note.topicLabel,
                subtitle: note.fact,
                leading: const NexusIconTile(Icons.label_outline_rounded),
                trailing: IconButton(
                  key: ValueKey<String>('memory-forget-${note.topic}'),
                  tooltip: 'Forget this',
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: c.danger,
                  ),
                  onPressed: () => unawaited(_forget(note)),
                ),
              ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: kNexusMemoryDeleteAll,
              onPressed: notes.isEmpty || _busy ? null : _confirmDeleteAll,
              style: FilledButton.styleFrom(
                backgroundColor: c.danger.withValues(alpha: 0.16),
                foregroundColor: c.danger,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(NexusLayout.tile),
                ),
              ),
              child: Text(
                _busy ? 'Deleting…' : kNexusMemoryDeleteAllLabel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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

  /// The same sentences [PrivacyPolicyView] shows — one copy, two shells, so a
  /// promise cannot fork between the settings page and the policy screen.
  static const String policy = PrivacyPolicyView.policy;

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

  /// The vault, so the row above the destructive one can say how much is in it
  /// and stay right after a fact is added or deleted on the page below.
  final MemoryService _memory = MemoryService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_memory.attach());
    _memory.addListener(_onMemoryChanged);
  }

  @override
  void dispose() {
    _memory.removeListener(_onMemoryChanged);
    super.dispose();
  }

  void _onMemoryChanged() {
    if (mounted) setState(() {});
  }

  /// What the vault row says under its title: the count, in the words a person
  /// would use, or the truth that there is nothing yet.
  String _factsSubtitle() {
    final int facts = _memory.length;
    if (facts == 0) return 'Nothing yet — view, add or delete what it learns';
    return '$facts ${facts == 1 ? 'fact' : 'facts'} · view, edit or delete them';
  }

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
        padding: EdgeInsets.fromLTRB(
          20 + MediaQuery.paddingOf(context).left,
          12,
          20 + MediaQuery.paddingOf(context).right,
          28,
        ),
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
            key: kNexusMemoryVaultRow,
            title: kNexusMemoryVaultRowLabel,
            subtitle: _factsSubtitle(),
            leading: const NexusIconTile(Icons.psychology_outlined),
            trailing: const NexusChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (routeContext) => const NexusMemoryVaultPage(),
              ),
            ),
          ),
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
