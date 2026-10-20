import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoPageRoute;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/capabilities.dart';
import '../core/location_access.dart';
import '../core/services/icon_service.dart';
import '../mesh/wake_word.dart';
import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'about_view.dart';
import 'components/nexus_ui.dart';
import 'privacy_policy_view.dart';
import 'theme.dart';

/// Settings, in the order a person asks about them: who am I, what is
/// connected, what does it know about me, how does the assistant behave, how
/// does it look, how do I update it — and only then the technical parts.
///
/// One row per setting, iOS anatomy: a label on the left, its value or control
/// on the right, and a description only where the label cannot carry the
/// answer — never more than one line. The sentences that used to explain Nexus
/// in the middle of the list live on [AboutView], one tap away, instead of
/// standing between the user and their settings.
class SettingsView extends StatefulWidget {
  final MeshService mesh;
  final Future<UpdateCheck> Function()? onCheckForUpdate;

  /// Opens the assistant's "what I still misunderstand" review. Supplied by
  /// the shell, which holds the one assistant whose service owns what this
  /// device learned; null in a test that builds this view on its own.
  final VoidCallback? onOpenDreamReview;

  const SettingsView({
    super.key,
    required this.mesh,
    this.onCheckForUpdate,
    this.onOpenDreamReview,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool? _allFilesAccess; // Android: can this device read its whole storage?
  String? _checkResult;
  bool _checking = false;

  /// The launcher-icon mode the row shows. Held here so a tap redraws the row at
  /// once; the truth still lives in [IconService].
  IconMode _iconMode = IconService.instance.mode;

  @override
  void initState() {
    super.initState();
    MeshService.hasAllFilesAccess().then((v) {
      if (mounted) setState(() => _allFilesAccess = v);
    });
    // The stored icon choice arrives asynchronously (it is a preference read),
    // so the row corrects itself from the settled service rather than staying on
    // the default it was first built with. attach() is idempotent — the app root
    // calls it too — and it is also what keeps Auto following the system theme
    // for as long as Nexus runs.
    unawaited(
      IconService.instance.attach().then((_) {
        if (mounted) setState(() => _iconMode = IconService.instance.mode);
      }),
    );
  }

  MeshService get mesh => widget.mesh;

  void _setBool(void Function() change) {
    setState(change);
    mesh.store.save();
  }

  /// The location toggle is a promise first, a switch second. Turning it
  /// on asks the system once; a denial leaves the switch off and says
  /// why, with a way back to system settings. Turning it off asks
  /// nothing and forgets nothing - the saved places stay, silent.
  Future<void> _setLocationReminders(bool on) async {
    if (!on) {
      _setBool(() => mesh.store.locationReminders = false);
      return;
    }
    final result = await ReminderLocation.requestAlways();
    if (!mounted) return;
    if (result.granted) {
      _setBool(() => mesh.store.locationReminders = true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.message ??
              'Location reminders need \'Always\' location permission.',
        ),
        action: SnackBarAction(
          label: 'Open Settings',
          onPressed: ReminderLocation.openAppSettings,
        ),
      ),
    );
  }

  /// The wake-word toggle is a promise first, a switch second, like
  /// location: turning it on starts the on-device loop (which asks for the
  /// microphone on the platform side); a refusal leaves the switch off and
  /// says why. Turning it off releases the engine and dismisses the
  /// persistent notification. The store only records an on that runs.
  Future<void> _setWakeWord(bool on) async {
    if (!on) {
      await WakeWord.ensure().stop();
      if (!mounted) return;
      _setBool(() => mesh.store.wakeWord = false);
      return;
    }
    final started = await WakeWord.ensure().start();
    if (!mounted) return;
    if (started) {
      _setBool(() => mesh.store.wakeWord = true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Wake word needs microphone permission — allow it and try again.',
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    final check = widget.onCheckForUpdate;
    if (check == null || _checking) return;
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    try {
      final result = await check();
      if (!mounted) return;
      setState(() {
        _checking = false;
        // Three different answers, never conflated: a check that could not be
        // made must not read as "up to date".
        _checkResult = switch (result) {
          UpdateCheck(:final info?) => 'Update to v${info.version} available',
          UpdateCheck(:final failure?) => 'Could not check — $failure',
          _ => 'Up to date — v$appVersion',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkResult = 'Could not check — try again';
      });
    }
  }

  /// What the icon row says: the chosen mode, and the one platform that can act
  /// on it.
  String _iconSubtitle() {
    if (!IconService.instance.switchingSupported) {
      return 'Light, Dark or Auto — the launcher mark switches on Android.';
    }
    return switch (_iconMode) {
      IconMode.light => 'Always the light mark.',
      IconMode.dark => 'Always the dark mark.',
      IconMode.auto => 'Follows the system theme.',
    };
  }

  /// The icon picker: three choices, one tap. The choice goes to [IconService],
  /// which stores it and switches the launcher alias — this only reports the
  /// outcome, and says so plainly when Android refuses the switch or when this
  /// build has no icon to switch.
  Future<void> _chooseIcon() async {
    final IconMode? chosen = await showNexusSheet<IconMode>(
      context: context,
      builder: (context, scroll) =>
          _IconModeSheet(current: _iconMode, scroll: scroll),
    );
    if (chosen == null || !mounted) return;
    setState(() => _iconMode = chosen);
    await IconService.instance.setMode(chosen);
    if (!mounted) return;
    final String? failure = IconService.instance.failure;
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Icon not switched: $failure')));
    } else if (!IconService.instance.switchingSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved — the launcher mark switches on Android'),
        ),
      );
    }
  }

  /// The promises, on their own screen, the same way About holds the facts.
  void _openPrivacy() {
    Navigator.of(context).push<void>(
      CupertinoPageRoute(builder: (_) => const PrivacyPolicyView()),
    );
  }

  /// The facts this list used to explain in place, on their own screen.
  void _openAbout() {
    // The iOS push: horizontal, with the edge-swipe back the platform has.
    Navigator.of(context).push<void>(
      CupertinoPageRoute(builder: (_) => const AboutView()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final icon = palette.textSecondary;
    final filesOff = _allFilesAccess == false;

    return NexusPage(
      children: [
        const NexusPageHeader(
          title: 'Settings',
          subtitle: 'This device and how Nexus behaves.',
        ),

        const NexusSectionHeader('You'),
        NexusGroup(
          children: [
            NexusRow(
              title: mesh.identity.name,
              subtitle: 'This device · ${_platformName()}',
              leading: Icon(
                Icons.person_outline_rounded,
                size: 20,
                color: icon,
              ),
            ),
          ],
        ),

        // What Nexus may do: every optional feature is a choice the user
        // makes here, never a default. Only the local model stays on; mesh
        // pairing and every post-pairing capability are explicit opt-ins.
        const NexusSectionHeader(
          'Capabilities',
          detail: 'Nexus proposes. You decide.',
        ),
        NexusGroup(
          children: [
            for (final (capability, info) in CapabilityInfo.all())
              if (info.alwaysOn)
                NexusRow(
                  title: info.title,
                  subtitle: '${info.description} ${info.needs}.',
                  leading: Icon(
                    Icons.check_circle_outline_rounded,
                    size: 20,
                    color: palette.success,
                  ),
                )
              else if (capability == Capability.locationReminders)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.locationReminders,
                  onChanged: _setLocationReminders,
                  needsTap: ReminderLocation.openAppSettings,
                )
              else if (capability == Capability.clipboardSync)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.clipboardSync,
                  onChanged: (v) =>
                      _setBool(() => mesh.store.clipboardSync = v),
                )
              else if (capability == Capability.meshPairing)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.pairingEnabled,
                  onChanged: (v) =>
                      _setBool(() => mesh.store.pairingEnabled = v),
                )
              else if (capability == Capability.fileShare)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.fileShare,
                  onChanged: (v) => _setBool(() => mesh.store.fileShare = v),
                )
              else if (capability == Capability.notificationShare)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.notificationShare,
                  onChanged: (v) =>
                      _setBool(() => mesh.store.notificationShare = v),
                )
              else if (capability == Capability.wakeWord)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.wakeWord,
                  onChanged: _setWakeWord,
                )
              else if (capability == Capability.locationShare)
                _CapabilityRow(
                  info: info,
                  value: mesh.store.locationShare,
                  onChanged: (v) =>
                      _setBool(() => mesh.store.locationShare = v),
                  needsTap: ReminderLocation.openAppSettings,
                )
              else
                _CapabilityRow(
                  info: info,
                  value: mesh.store.voiceInput,
                  onChanged: (v) => _setBool(() => mesh.store.voiceInput = v),
                  needsTap: capability == Capability.voiceInput
                      ? ReminderLocation.openAppSettings
                      : null,
                ),
            NexusSwitchRow(
              title: 'Always merge clipboard',
              subtitle: 'Off waits 3 s in case you paste it here.',
              value: mesh.store.alwaysMerge,
              onChanged: (v) => _setBool(() => mesh.store.alwaysMerge = v),
            ),
            NexusSwitchRow(
              title: 'Broadcast discovery',
              subtitle: 'Lets nearby devices find this one.',
              value: mesh.store.broadcastDiscovery,
              onChanged: (v) => _setBool(() => mesh.store.broadcastDiscovery = v),
            ),
          ],
        ),

        // What other devices may see, and — one tap away — the promise in
        // full. The policy row is here on every platform; the storage row is
        // Android's, because the broad-storage permission is.
        const NexusSectionHeader('Privacy'),
        NexusGroup(
          children: [
            if (isAndroid)
              NexusRow(
                title: 'Show your files to paired devices',
                subtitle: filesOff
                    ? 'Off — they see only what Nexus downloaded.'
                    : 'On — they can browse and delete files you allow.',
                leading: Icon(
                  filesOff
                      ? Icons.lock_outline_rounded
                      : Icons.folder_open_rounded,
                  size: 20,
                  color: icon,
                ),
                trailing: NexusRowValue(filesOff ? 'Off' : 'On'),
                chevron: true,
                onTap: MeshService.openAllFilesAccessSettings,
              ),
            NexusRow(
              title: 'Privacy Policy',
              subtitle: 'Local-first, no accounts, no telemetry.',
              leading: Icon(
                Icons.privacy_tip_outlined,
                size: 20,
                color: icon,
              ),
              chevron: true,
              onTap: _openPrivacy,
            ),
          ],
        ),

        const NexusSectionHeader('Assistant'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'What I still misunderstand',
              subtitle: 'Review and teach the phrases I missed.',
              leading: Icon(
                Icons.psychology_alt_outlined,
                size: 20,
                color: icon,
              ),
              chevron: true,
              onTap: widget.onOpenDreamReview,
            ),
          ],
        ),

        const NexusSectionHeader('Appearance'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Theme',
              minHeight: NexusSize.rowCompact,
              leading: Icon(Icons.dark_mode_outlined, size: 20, color: icon),
              trailing: const NexusRowValue('Dark'),
            ),
            // Android can only show the icon of one enabled launcher alias, so
            // this row switches which alias that is: light, dark, or whichever
            // the system theme is asking for. The mark is part of the manifest,
            // not of the theme, which is why it is its own setting.
            NexusRow(
              title: 'App icon',
              subtitle: _iconSubtitle(),
              leading: Icon(Icons.apps_outlined, size: 20, color: icon),
              trailing: NexusRowValue(_iconMode.label),
              chevron: true,
              onTap: _chooseIcon,
            ),
          ],
        ),

        const NexusSectionHeader('Updates'),
        NexusGroup(
          children: [
            NexusSwitchRow(
              title: 'Check for updates automatically',
              value: mesh.store.autoUpdate,
              onChanged: (v) => _setBool(() => mesh.store.autoUpdate = v),
            ),
            // The state is the only thing this row has to say beyond its
            // label, so it is the only thing it shows: nothing when idle.
            NexusRow(
              title: 'Check for updates now',
              subtitle: _checking ? 'Checking…' : _checkResult,
              leading: Icon(
                Icons.system_update_alt_rounded,
                size: 20,
                color: icon,
              ),
              trailing: _checking
                  ? CupertinoActivityIndicator(radius: 8, color: palette.accent)
                  : null,
              onTap: widget.onCheckForUpdate == null ? null : _checkForUpdate,
            ),
          ],
        ),

        const NexusSectionHeader('About'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'About Nexus',
              leading: Icon(Icons.info_outline_rounded, size: 20, color: icon),
              trailing: NexusRowValue('v$appVersion'),
              chevron: true,
              onTap: _openAbout,
            ),
          ],
        ),
      ],
    );
  }

  String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Phone';
      case TargetPlatform.iOS:
        return 'iPhone';
      case TargetPlatform.macOS:
        return 'Mac';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Device';
    }
  }
}

/// The three-way icon choice: Light, Dark or Auto.
///
/// Rows in a group, one of them checked, because that is how this app marks a
/// selection everywhere else — and because a Nexus sheet is Cupertino
/// throughout: [NexusSheetSurface] holds no `Material` (deliberately, so nothing
/// in a sheet can reach for Material ink), so the Material radios this sheet
/// started with had no surface to paint on and opening the picker threw "No
/// Material widget found" instead of offering a choice. The whole row is the
/// target — the words are most of it, and the words are what a finger aims at.
/// A tap chooses and closes the sheet: the switch is applied straight away, so
/// there is nothing left to confirm. The list is the sheet's own scrollable, so
/// a downward drag still dismisses it: the framework reads the controller it
/// hands the builder.
class _IconModeSheet extends StatelessWidget {
  const _IconModeSheet({required this.current, required this.scroll});

  /// The mode in force when the sheet opened.
  final IconMode current;

  /// The sheet's scroll controller — without it a drag on this list could never
  /// dismiss the sheet.
  final ScrollController scroll;

  /// What each choice means, in the same words the row uses.
  static String _meaning(IconMode mode) => switch (mode) {
    IconMode.light => 'Always the light mark.',
    IconMode.dark => 'Always the dark mark.',
    IconMode.auto => 'Follows the system theme.',
  };

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final theme = Theme.of(context);
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.lg,
        NexusSpace.lg,
        NexusSpace.lg,
        NexusSpace.lg,
      ),
      children: [
        Text('App icon', style: theme.textTheme.titleMedium),
        const SizedBox(height: NexusSpace.xs),
        Text(
          'Android names the launcher icon in the app manifest: the switch '
          'takes effect at once, and the phone redraws it a moment later. Only '
          'Android can do this — the choice is remembered either way.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: NexusSpace.md),
        NexusGroup(
          children: [
            for (final mode in IconMode.values)
              NexusRow(
                title: mode.label,
                subtitle: _meaning(mode),
                // The check says which mark is in force to the eye; the
                // semantics label says it to a screen reader, which cannot
                // see a tick.
                semanticLabel: mode == current
                    ? '${mode.label}. ${_meaning(mode)} Selected'
                    : '${mode.label}. ${_meaning(mode)}',
                trailing: mode == current
                    ? Icon(Icons.check_rounded, size: 20, color: palette.accent)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ],
    );
  }
}

/// One capability row: the toggle, and - only when the capability spends
/// something beyond this phone (a permission, a network call, disk) - a
/// small tappable line that opens the system screen where that spend is
/// granted. The disclosure is above the switch in reading order, never
/// behind it.
class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.info,
    required this.value,
    required this.onChanged,
    this.needsTap,
  });

  final CapabilityInfo info;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Future<void> Function()? needsTap;

  /// The "Needs:" line shows only when the capability spends something
  /// beyond this phone. "Needs: nothing" is silence, not a row.
  bool get _showsNeeds => info.needs != 'Needs: nothing';

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NexusSwitchRow(
          title: info.title,
          subtitle: info.description,
          value: value,
          onChanged: onChanged,
        ),
        if (_showsNeeds)
          GestureDetector(
            onTap: needsTap == null ? null : () => needsTap!(),              child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '${info.needs} - tap to open system settings.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.accent,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
