// Where a shared setting goes: the sheet that asks, and the bar that says what
// came in.
//
// The sheet exists because "sync my settings" is not one question. A system
// prompt is about the person and belongs on every device; a clipboard sending
// policy is about how this desk is set up, and an hour later the answer may be
// different. So the choice is per change, with "remember my choice" for the user
// who never wants to be asked — and the default, with nothing remembered, is to
// ask.
//
// The bar is the other half: whichever device adopted a value is told which
// device sent it and offered Undo, because a setting that changes without
// anybody seeing it is indistinguishable from one that was changed by a bug.

part of '../main_ui.dart';

/// The sheet's question and its two answers.
const Key kNexusSettingScopeSheet = Key('nexus-setting-scope-sheet');

/// "This device only" — write nothing to the wire.
const Key kNexusSettingScopeLocal = Key('nexus-setting-scope-local');

/// "All devices (n online)" — broadcast the value.
const Key kNexusSettingScopeAll = Key('nexus-setting-scope-all');

/// "Remember my choice" — stop asking, and do this next time.
const Key kNexusSettingScopeRemember = Key('nexus-setting-scope-remember');

/// The bar that reports an adopted value, with Undo.
const Key kNexusSettingNotice = Key('nexus-setting-notice');

/// Undo, on that bar.
const Key kNexusSettingNoticeUndo = Key('nexus-setting-notice-undo');

/// What the sheet answered: where the change goes, and whether to stop asking.
class SettingScopeChoice {
  const SettingScopeChoice({required this.scope, required this.remember});

  /// [SettingScope.local] or [SettingScope.all].
  final String scope;

  /// True when the user ticked "Remember my choice".
  final bool remember;
}

/// Asks where a change to [setting] should go, and for how many devices.
///
/// [online] is the mesh's own count of peers answering right now, so the second
/// answer names a number instead of promising a sync to devices that are asleep.
/// A dismissed sheet answers null, which the caller treats as "change nothing
/// about where it goes" — the change itself already happened here.
Future<SettingScopeChoice?> showSettingScopeSheet(
  BuildContext context, {
  required SharedSetting setting,
  required int online,
}) {
  return showDialog<SettingScopeChoice>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _SettingScopeDialog(setting: setting, online: online),
  );
}

class _SettingScopeDialog extends StatefulWidget {
  const _SettingScopeDialog({required this.setting, required this.online});

  final SharedSetting setting;
  final int online;

  @override
  State<_SettingScopeDialog> createState() => _SettingScopeScopeState();
}

class _SettingScopeScopeState extends State<_SettingScopeDialog> {
  bool _remember = false;

  void _answer(String scope) =>
      Navigator.of(context)
          .pop(SettingScopeChoice(scope: scope, remember: _remember));

  @override
  Widget build(BuildContext context) {
    final c = context.ui;
    return AlertDialog(
      key: kNexusSettingScopeSheet,
      title: Text(widget.setting.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'You changed this here. Send it to your paired devices too?',
            style: NexusType.rowMeta(c),
          ),
          const SizedBox(height: 14),
          InkWell(
            key: kNexusSettingScopeRemember,
            onTap: () => setState(() => _remember = !_remember),
            child: Row(
              children: <Widget>[
                Checkbox(
                  value: _remember,
                  onChanged: (bool? value) =>
                      setState(() => _remember = value ?? false),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Remember my choice',
                    style: NexusType.rowTitle(c).copyWith(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: kNexusSettingScopeLocal,
          onPressed: () => _answer(SettingScope.local),
          child: const Text('This device only'),
        ),
        FilledButton(
          key: kNexusSettingScopeAll,
          onPressed: () => _answer(SettingScope.all),
          // The count is in the label because it is the difference between
          // "my other phone gets this" and "nothing is listening right now".
          child: Text('All devices (${widget.online} online)'),
        ),
      ],
    );
  }
}

/// Reports the last shared setting a peer changed here, with Undo.
///
/// Zero height when nothing is waiting, and it sits with the clipboard bar above
/// the pages: an adopted setting can arrive while the user is on any tab, and a
/// notice only the Settings screen shows is a notice nobody sees.
class NexusSettingNoticeBar extends StatelessWidget {
  const NexusSettingNoticeBar({super.key, required this.mesh});

  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (BuildContext context, Widget? _) {
        final AdoptedSetting? adopted = mesh.lastAdoptedSetting;
        if (adopted == null) return const SizedBox.shrink();
        final NexusUiColors c = context.ui;
        return Container(
          key: kNexusSettingNotice,
          decoration: BoxDecoration(
            color: c.raised,
            border: Border(bottom: BorderSide(color: c.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(NexusLayout.gutter, 10, 8, 10),
          child: Row(
            children: <Widget>[
              Icon(Icons.sync_rounded, size: 20, color: c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${adopted.setting.label} updated from ${adopted.fromName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexusType.rowTitle(c).copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Changed on another of your devices.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexusType.rowMeta(c),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: kNexusSettingNoticeUndo,
                onPressed: () => unawaited(mesh.undoAdoptedSetting()),
                child: const Text('Undo'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: mesh.dismissAdoptedSetting,
                icon: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
              ),
            ],
          ),
        );
      },
    );
  }
}
