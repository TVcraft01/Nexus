// Settings → Server Agent (Advanced): the one screen that can change a machine
// other than this one.
//
// The page is a small SSH client with a deliberately closed vocabulary. It asks
// for a login, offers the playbooks in [kServerPlaybooks], and shows the exact
// commands before anything runs — then streams the far end's output into a
// terminal. There is no free-text shell and no "ask the AI what to type": the
// matcher in server_playbooks.dart picks a playbook by sentence, and that
// playbook's own array is what runs.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/local_ai_service.dart';
import '../core/memory_service.dart';
import '../core/server_explorer.dart';
import '../core/server_playbooks.dart';
import '../core/ssh_service.dart';
import 'components/nexus_ui.dart';
import 'theme.dart';

/// The page itself, for a test that pushed it.
const Key kNexusServerAgentPage = Key('nexus-server-agent-page');

/// The output pane.
const Key kNexusServerTerminal = Key('nexus-server-terminal');

/// The "What do you want to build?" field.
const Key kNexusServerComposer = Key('nexus-server-composer');

/// The three login fields, keyed because three identical text fields cannot be
/// told apart by their type.
const Key kNexusServerHost = Key('nexus-server-host');
const Key kNexusServerUser = Key('nexus-server-user');
const Key kNexusServerPassword = Key('nexus-server-password');

/// The red button in the confirmation dialog. One key because there is exactly
/// one thing on this page that may touch a server.
const Key kNexusServerExecute = Key('nexus-server-execute');

/// The read-only "Explore Server" button.
const Key kNexusServerExplore = Key('nexus-server-explore');

/// The card that holds the model's two-sentence summary.
const Key kNexusServerSummary = Key('nexus-server-summary');

/// The Server Agent screen.
class ServerAgentPage extends StatefulWidget {
  const ServerAgentPage({super.key, this.connect, this.brain, this.memory});

  /// How to reach a server. Null means [SshService].
  final SshConnector? connect;

  /// The model that writes an exploration summary. Null means the app's brain
  /// ([LocalAiService.current]); a test passes its own.
  final LocalAiService? brain;

  /// Where an exploration summary is kept. Null means the Memory Vault.
  final MemoryService? memory;

  @override
  State<ServerAgentPage> createState() => _ServerAgentPageState();
}

class _ServerAgentPageState extends State<ServerAgentPage> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _composer = TextEditingController();
  final ScrollController _output = ScrollController();

  /// The terminal's contents, oldest first. Strings rather than widgets, so a
  /// rebuild never re-runs anything and the log survives one.
  final List<String> _lines = <String>[];

  /// True from the tap on "Execute on Server" until the runner is closed.
  /// Everything that could start a second run is disabled while it is.
  bool _running = false;

  /// True while the read-only tour is running. Separate from [_running] because
  /// an exploration changes nothing, but the two still exclude each other: one
  /// connection per page, so the terminal shows one story at a time.
  bool _exploring = false;

  /// The last exploration, or null before one has run.
  ServerReport? _report;

  /// Which half of the output section is showing. The terminal is the evidence;
  /// the summary is the reading. A playbook run switches to the terminal, an
  /// exploration ends on the summary.
  bool _showTerminal = false;

  /// The sentence under the terminal: what Nexus understood, or what went
  /// wrong. Null leaves the line out.
  String? _status;

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _password.dispose();
    _composer.dispose();
    _output.dispose();
    super.dispose();
  }

  /// Reads the login fields into a target, splitting an optional `host:port`
  /// the way anyone who has used ssh would write it.
  SshTarget? _target() {
    final String address = _host.text.trim();
    final String user = _user.text.trim();
    if (address.isEmpty || user.isEmpty) return null;

    int port = 22;
    String host = address;
    final int colon = address.lastIndexOf(':');
    if (colon > 0) {
      final int? parsed = int.tryParse(address.substring(colon + 1));
      if (parsed != null && parsed > 0 && parsed < 65536) {
        port = parsed;
        host = address.substring(0, colon);
      }
    }
    return SshTarget(
      host: host,
      port: port,
      username: user,
      password: _password.text,
    );
  }

  /// Reads the server without changing it, then asks the local model what it
  /// found. The raw lines stream into the terminal as they arrive, so the wait
  /// is visible and the evidence is already there if the model is late.
  Future<void> _explore() async {
    if (_running || _exploring) return;
    final SshTarget? target = _target();
    if (target == null) {
      setState(() {
        _status = 'Fill in the server address and the username first.';
      });
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _exploring = true;
      _status = 'Exploring ${target.label} — reading only.';
      _showTerminal = true;
      _lines
        ..clear()
        ..add('Nexus · exploring ${target.label} (read-only)');
    });

    try {
      final ServerReport report = await ServerExplorer(
        connect: widget.connect,
        brain: widget.brain,
        memory: widget.memory,
      ).explore(target, onLine: _append);
      if (!mounted) return;
      setState(() {
        _report = report;
        _status = report.summary == null
            ? report.summaryError
            : (report.remembered
                  ? 'Saved to memory as ${report.topic}.'
                  : 'Explored ${target.label}.');
        // End on the reading when there is one; stay on the evidence when the
        // model could not write it.
        _showTerminal = report.summary == null;
      });
    } on SshFailure catch (error) {
      if (!mounted) return;
      _append(error.message);
      setState(() => _status = error.message);
    } catch (error) {
      if (!mounted) return;
      _append('$error');
      setState(() => _status = 'The exploration failed: $error');
    } finally {
      if (mounted) setState(() => _exploring = false);
    }
  }

  /// What happens when the user sends a sentence: match, confirm, run.
  Future<void> _send([String? raw]) async {
    if (_running || _exploring) return;
    final String sentence = (raw ?? _composer.text).trim();
    if (sentence.isEmpty) return;

    final Playbook? playbook = playbookForIntent(sentence);
    if (playbook == null) {
      setState(() => _status = kNoPlaybookText);
      return;
    }
    await _startPlaybook(playbook);
  }

  /// Confirms and runs one playbook. Split from [_send] so a tap on a playbook
  /// row reaches the same door as a typed sentence.
  Future<void> _startPlaybook(Playbook playbook) async {
    if (_running || _exploring) return;
    final SshTarget? target = _target();
    if (target == null) {
      setState(() {
        _status = 'Fill in the server address and the username first.';
      });
      return;
    }

    // The last answer was about a different attempt; leaving it under the
    // dialog would read as a verdict on this one.
    if (_status != null) setState(() => _status = null);

    final bool? confirmed = await _confirm(playbook, target);
    if (confirmed != true || !mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _running = true;
      _showTerminal = true;
      _status = 'Running ${playbook.title} on ${target.label}…';
      _lines
        ..clear()
        ..add('Nexus · ${playbook.title}')
        ..add('Connecting to ${target.label}…');
    });

    final SshRunner runner =
        await (widget.connect?.call(target) ??
            Future<SshRunner>.value(SshService(target)));

    int failed = 0;
    try {
      for (final String command in playbook.commands) {
        _append('\$ $command');
        await for (final SshOutput event in runner.run(command)) {
          if (!mounted) return;
          switch (event) {
            case SshLine(:final String text):
              _append(text);
            case SshExit(:final int? code):
              if (code != null && code != 0) {
                failed = code;
                _append('exit $code — stopped here.');
              }
          }
        }
        if (failed != 0) break;
      }
      if (!mounted) return;
      setState(() {
        _status = failed == 0
            ? '${playbook.title} is running on ${target.label}.'
            : 'The server stopped with exit code $failed.';
      });
    } on SshFailure catch (error) {
      if (!mounted) return;
      _append(error.message);
      setState(() => _status = error.message);
    } catch (error) {
      if (!mounted) return;
      _append('$error');
      setState(() => _status = 'The run failed: $error');
    } finally {
      await runner.close();
      if (mounted) setState(() => _running = false);
    }
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _lines.add(line));
    // After the frame, so the list has its new extent and can be pinned to the
    // bottom. A terminal that does not follow its own output is a log.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_output.hasClients) return;
      _output.animateTo(
        _output.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  /// The dialog that stands between a sentence and a remote machine. It lists
  /// the commands verbatim, because those strings are what the user agrees to
  /// when the red button is pressed.
  Future<bool?> _confirm(Playbook playbook, SshTarget target) {
    final NexusPalette c = NexusPalette.of(context);
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: c.surfaceElevated,
          shape: const RoundedRectangleBorder(borderRadius: NexusRadius.card),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NexusSpace.xl,
                NexusSpace.xl,
                NexusSpace.xl,
                NexusSpace.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // The reading half scrolls; the two buttons at the bottom do
                  // not. A long command list on a short phone must not push the
                  // decision off the screen.
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Run ${playbook.title}?',
                            style: NexusType.title.copyWith(
                              color: c.textPrimary,
                            ),
                          ),
                          const SizedBox(height: NexusSpace.sm),
                          Text(
                            'On ${target.label}. These are the exact commands, '
                            'in order. Nothing else will run.',
                            style: NexusType.caption.copyWith(
                              color: c.textSecondary,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: NexusSpace.lg),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            decoration: BoxDecoration(
                              color: c.bg,
                              borderRadius: NexusRadius.row,
                              border: Border.all(color: c.separator),
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(NexusSpace.md),
                              child: SelectableText(
                                playbook.commands.join('\n\n'),
                                style: _mono(c, color: c.textPrimary),
                              ),
                            ),
                          ),
                          const SizedBox(height: NexusSpace.md),
                          Text(
                            playbook.description,
                            style: NexusType.caption.copyWith(
                              color: c.textSecondary,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: NexusSpace.xl),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: NexusSpace.md),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          key: kNexusServerExecute,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.danger,
                            foregroundColor: c.onDanger,
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('Execute on Server'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final NexusPalette c = NexusPalette.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: const Text('Server Agent')),
      body: NexusPage(
        key: kNexusServerAgentPage,
        pinnedBottom: _composerBar(c),
        children: <Widget>[
          Text(
            'Nexus can set up software on a Linux server you already own, over '
            'SSH. It only runs the playbooks below — it never writes a shell '
            'command of its own.',
            style: NexusType.body.copyWith(color: c.textSecondary, height: 1.5),
          ),
          const NexusSectionHeader('Server'),
          NexusGroup(
            children: <Widget>[
              _field(
                c,
                key: kNexusServerHost,
                controller: _host,
                label: 'Address',
                hint: '192.168.1.50 or my-server:2222',
                keyboardType: TextInputType.url,
              ),
              _field(
                c,
                key: kNexusServerUser,
                controller: _user,
                label: 'Username',
                hint: 'ubuntu',
              ),
              _field(
                c,
                key: kNexusServerPassword,
                controller: _password,
                label: 'Password',
                hint: 'Used for this session only',
                obscure: true,
              ),
            ],
          ),
          const SizedBox(height: NexusSpace.sm),
          Text(
            'The password is kept in memory until the page closes. Nexus trusts '
            'the key the server shows on first connect.',
            style: NexusType.caption.copyWith(
              color: c.textTertiary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: NexusSpace.md),
          OutlinedButton.icon(
            key: kNexusServerExplore,
            onPressed: _running || _exploring
                ? null
                : () => unawaited(_explore()),
            icon: _exploring
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.travel_explore_rounded),
            label: Text(_exploring ? 'Exploring…' : 'Explore Server'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: NexusSpace.sm),
          Text(
            'Explore is read-only: it asks the server about its CPU, memory, '
            'disks and tools and changes nothing.',
            style: NexusType.caption.copyWith(
              color: c.textTertiary,
              height: 1.45,
            ),
          ),
          const NexusSectionHeader('Playbooks'),
          NexusGroup(
            children: <Widget>[
              for (final Playbook playbook in kServerPlaybooks)
                NexusRow(
                  title: playbook.title,
                  subtitle: playbook.description,
                  leading: _tile(c, Icons.dns_outlined),
                  chevron: true,
                  onTap: _running
                      ? null
                      : () => unawaited(_startPlaybook(playbook)),
                ),
            ],
          ),
          NexusSectionHeader(
            'Output',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // The pill is a strip control and draws small; the box is what
                // makes it a thumb-sized target in a header row.
                SizedBox(
                  height: NexusSize.minTouch,
                  child: NexusChoicePill(
                    label: 'Summary',
                    selected: !_showTerminal,
                    onTap: () => setState(() => _showTerminal = false),
                  ),
                ),
                const SizedBox(width: NexusSpace.sm),
                SizedBox(
                  height: NexusSize.minTouch,
                  child: NexusChoicePill(
                    label: 'Terminal',
                    selected: _showTerminal,
                    onTap: () => setState(() => _showTerminal = true),
                  ),
                ),
              ],
            ),
          ),
          if (_showTerminal)
            Container(
              key: kNexusServerTerminal,
              constraints: const BoxConstraints(minHeight: 150, maxHeight: 320),
              decoration: BoxDecoration(
                // A terminal is the one surface in the app painted by its own
                // rules: black and green, because that is what makes a wall of
                // machine output legible at a glance. It is not part of the
                // palette and does not follow the theme.
                color: Colors.black,
                borderRadius: NexusRadius.row,
                border: Border.all(color: c.separator),
              ),
              padding: const EdgeInsets.all(NexusSpace.md),
              child: _lines.isEmpty
                  ? Center(
                      child: Text(
                        'Output appears here.',
                        style: _mono(c, color: const Color(0xFF5C7A61)),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _output,
                      child: SelectableText(
                        _lines.join('\n'),
                        style: _mono(c, color: const Color(0xFF7CE38B)),
                      ),
                    ),
            )
          else
            _summaryCard(c),
        ],
      ),
    );
  }

  /// What the last exploration found: the model's two sentences, with the row
  /// that says whether they reached memory. Before an exploration it is a
  /// sentence about what Explore does — an empty card would be a dead end.
  Widget _summaryCard(NexusPalette c) {
    final ServerReport? report = _report;
    final String? summary = report?.summary;
    return Container(
      key: kNexusServerSummary,
      width: double.infinity,
      padding: const EdgeInsets.all(NexusSpace.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: NexusRadius.card,
        border: Border.all(color: c.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            report == null ? 'Not explored yet' : report.target.label,
            style: NexusType.overline.copyWith(
              fontSize: 11,
              letterSpacing: 0.6,
              color: c.textTertiary,
            ),
          ),
          const SizedBox(height: NexusSpace.sm),
          if (_exploring)
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: NexusSpace.sm),
                Expanded(
                  child: Text(
                    'Reading the server, then asking the local model to '
                    'describe it…',
                    style: NexusType.caption.copyWith(
                      color: c.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            )
          else if (summary != null) ...<Widget>[
            SelectableText(
              summary,
              style: NexusType.body.copyWith(color: c.textPrimary, height: 1.5),
            ),
            if (report!.remembered) ...<Widget>[
              const SizedBox(height: NexusSpace.md),
              Row(
                children: <Widget>[
                  Icon(Icons.check_rounded, size: 16, color: c.success),
                  const SizedBox(width: NexusSpace.xs),
                  Expanded(
                    child: Text(
                      'Saved to memory as ${report.topic}',
                      style: NexusType.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ] else if (report?.summaryError != null)
            Text(
              report!.summaryError!,
              style: NexusType.caption.copyWith(
                color: c.textSecondary,
                height: 1.45,
              ),
            )
          else
            Text(
              'Explore reads the server\'s hardware, disks and tools without '
              'changing anything, and writes a short summary the assistant '
              'will remember.',
              style: NexusType.caption.copyWith(
                color: c.textSecondary,
                height: 1.45,
              ),
            ),
        ],
      ),
    );
  }

  /// The mono face the terminal and the command list are set in.
  TextStyle _mono(NexusPalette c, {required Color color}) =>
      NexusType.caption.copyWith(
        fontFamily: 'monospace',
        fontSize: 12.5,
        height: 1.5,
        color: color,
      );

  /// The icon on a playbook row, in the same tile the rest of the app uses.
  Widget _tile(NexusPalette c, IconData icon) {
    return Container(
      width: NexusSize.row,
      height: NexusSize.row,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        borderRadius: NexusRadius.row,
      ),
      child: Icon(icon, size: 20, color: c.textSecondary),
    );
  }

  /// One of the three login fields, as a row inside the group.
  Widget _field(
    NexusPalette c, {
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.lg,
        vertical: NexusSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: NexusType.overline.copyWith(
              fontSize: 11,
              letterSpacing: 0.6,
              color: c.textTertiary,
            ),
          ),
          const SizedBox(height: NexusSpace.xs),
          TextField(
            key: key,
            controller: controller,
            obscureText: obscure,
            enabled: !_running,
            keyboardType: keyboardType,
            autocorrect: false,
            enableSuggestions: false,
            style: NexusType.rowTitle.copyWith(color: c.textPrimary),
            decoration: InputDecoration.collapsed(
              hintText: hint,
              hintStyle: NexusType.rowTitle.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// The bottom bar: the only field on the page that takes a sentence, and the
  /// answer to the last one.
  ///
  /// The status sits here rather than under the terminal on purpose — "Nexus
  /// cannot do that yet" is no use below a fold the user has to scroll to find.
  Widget _composerBar(NexusPalette c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NexusSpace.sm),
            child: Text(
              _status!,
              style: NexusType.caption.copyWith(
                color: c.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: kNexusServerComposer,
                controller: _composer,
                enabled: !_running,
                textInputAction: TextInputAction.send,
                onSubmitted: (String value) => unawaited(_send(value)),
                style: NexusType.rowTitle.copyWith(color: c.textPrimary),
                decoration: InputDecoration(
                  hintText: 'What do you want to build?',
                  hintStyle: NexusType.rowTitle.copyWith(color: c.textTertiary),
                  filled: true,
                  fillColor: c.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: NexusSpace.lg,
                    vertical: NexusSpace.md,
                  ),
                  border: const OutlineInputBorder(
                    borderRadius: NexusRadius.pill,
                  ),
                ),
              ),
            ),
            const SizedBox(width: NexusSpace.sm),
            IconButton.filled(
              tooltip: 'Build it',
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _running ? null : () => unawaited(_send()),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ],
    );
  }
}
