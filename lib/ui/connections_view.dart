// Settings → Connections: what Nexus may touch, and what it has touched.
//
// Two halves, and they answer the same question from opposite ends. The top
// lists the three systems the app reaches — the player, the phone, the model —
// with the permissions each one holds and one button that takes them away. The
// bottom is the audit: the last ten things Nexus actually did, newest first.
//
// The revoke is not a preference the screen keeps to itself. [Connections] is
// consulted by the executor before every action ([DeviceSystemActions.execute]),
// so a revoked connector refuses the fast path, the model's JSON and anything
// added later — and the refusal is the sentence shown here, naming the way back.
//
// A part of the shell for the same reason the Privacy page is: it uses the
// shell's rows, type and palette rather than a second private copy of them.
part of '../main_ui.dart';

/// The Settings row that opens this page.
const Key kNexusConnectionsRow = Key('nexus-connections-row');

/// The Connections page itself, so a test can find it after the push.
const Key kNexusConnectionsPage = Key('nexus-connections-page');

/// The revoke/restore button on one connector card.
Key nexusConnectorToggle(String id) => Key('nexus-connector-$id-toggle');

/// One line of the audit, keyed by position so a test reads order, not clocks.
Key nexusAuditLine(int index) => Key('nexus-audit-line-$index');

/// The screen.
class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  @override
  void initState() {
    super.initState();
    // Idempotent: the store is read once for the whole app. A failed read
    // leaves every connector granted, which is the state the app shipped in.
    unawaited(Connections.instance.attach());
  }

  /// Revokes or restores one connector, and says which happened so the change
  /// is not only a colour moving.
  Future<void> _toggle(Connector connector) async {
    final Connections connections = Connections.instance;
    final bool wasEnabled = connections.isEnabled(connector.id);
    await (wasEnabled
        ? connections.revoke(connector.id)
        : connections.restore(connector.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasEnabled
              ? '${connector.name} revoked. Nexus cannot use it until you '
                    'restore it.'
              : '${connector.name} restored.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Connections')),
      body: AnimatedBuilder(
        // Both halves are live: revoking a connector redraws its card, and an
        // action executed behind the screen appears in the audit when it lands.
        animation: Listenable.merge(<Listenable>[
          Connections.instance,
          ActionAudit.instance,
        ]),
        builder: (BuildContext context, Widget? _) {
          final Connections connections = Connections.instance;
          final List<AuditEntry> recent = ActionAudit.instance.recent();
          return ListView(
            key: kNexusConnectionsPage,
            // The bottom inset is the system bar, not the app's: this page is
            // pushed over the shell, so nothing else pads it, and without the
            // inset the newest audit line lands under the nav buttons.
            padding: EdgeInsets.fromLTRB(
              20 + MediaQuery.paddingOf(context).left,
              12,
              20 + MediaQuery.paddingOf(context).right,
              28 + MediaQuery.paddingOf(context).bottom,
            ),
            children: <Widget>[
              Text(
                'Nexus can reach three systems on this phone. Revoke one and '
                'every action it covers stops — the instant ones included.',
                style: NexusType.rowMeta(c).copyWith(height: 1.5),
              ),
              const NexusSectionLabel('Connectors', first: true),
              for (final Connector connector in kConnectors)
                _ConnectorCard(
                  connector: connector,
                  connections: connections,
                  onToggle: () => unawaited(_toggle(connector)),
                ),
              const NexusSectionLabel('Recent activity'),
              Text(
                'The last $kAuditRecent things Nexus did to this phone, '
                'newest first. Kept in memory, gone when the app closes.',
                style: NexusType.rowMeta(c).copyWith(height: 1.5),
              ),
              const SizedBox(height: 12),
              if (recent.isEmpty)
                const NexusRow(
                  title: 'No actions yet',
                  subtitle:
                      'Ask for the torch, a timer or the next track — whatever '
                      'Nexus runs is listed here.',
                  leading: NexusIconTile(Icons.history_rounded),
                )
              else
                for (int i = 0; i < recent.length; i++)
                  _AuditLine(entry: recent[i], index: i),
            ],
          );
        },
      ),
    );
  }
}

/// One connector: what it is, what it may do, and the one button.
class _ConnectorCard extends StatelessWidget {
  const _ConnectorCard({
    required this.connector,
    required this.connections,
    required this.onToggle,
  });

  final Connector connector;
  final Connections connections;
  final VoidCallback onToggle;

  static IconData _icon(String id) => switch (id) {
    'music_player' => Icons.music_note_rounded,
    'phone_system' => Icons.smartphone_rounded,
    _ => Icons.auto_awesome_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    final bool enabled = connections.isEnabled(connector.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.hairline),
        borderRadius: const BorderRadius.all(NexusLayout.tile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NexusIconTile(_icon(connector.id)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(connector.name, style: NexusType.rowTitle(c)),
                    const SizedBox(height: 2),
                    Text(connector.summary, style: NexusType.rowMeta(c)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // A word, not only a colour: the state has to survive a
              // screenshot and a screen reader.
              Text(
                enabled ? 'Granted' : 'Revoked',
                style: NexusType.rowMeta(c).copyWith(
                  color: enabled ? c.online : c.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final ConnectorPermission permission in connector.permissions)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    enabled
                        ? Icons.check_circle_outline_rounded
                        : Icons.remove_circle_outline_rounded,
                    size: 16,
                    color: enabled ? c.textMuted : c.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      permission.label,
                      style: NexusType.rowMeta(c),
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: nexusConnectorToggle(connector.id),
              onPressed: onToggle,
              style: TextButton.styleFrom(
                foregroundColor: enabled ? c.danger : c.accent,
                minimumSize: const Size(88, 40),
              ),
              child: Text(enabled ? 'Revoke' : 'Restore'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One executed action: its clock in its own column, then what happened.
class _AuditLine extends StatelessWidget {
  const _AuditLine({required this.entry, required this.index});

  final AuditEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return Container(
      key: nexusAuditLine(index),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: <Widget>[
          // A fixed column so ten lines read as a table rather than as ten
          // sentences of different lengths.
          SizedBox(
            width: 76,
            child: Text(
              entry.clock,
              style: NexusType.rowMeta(c).copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(child: Text(entry.label, style: NexusType.rowTitle(c))),
        ],
      ),
    );
  }
}
