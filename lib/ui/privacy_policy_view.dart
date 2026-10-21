import 'package:flutter/cupertino.dart'
    show CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:flutter/material.dart';

import 'components/nexus_ui.dart';
import 'theme.dart';

/// The whole of Nexus's privacy promise, on one screen.
///
/// It is a paragraph rather than a list of rows on purpose: this is the one
/// place the app makes a claim about itself, and a claim broken into rows reads
/// as features. The text is the policy — the same sentences the About screen
/// used to spread across its rows — so there is exactly one copy to keep true.
class PrivacyPolicyView extends StatelessWidget {
  const PrivacyPolicyView({super.key});

  /// The policy, verbatim. Kept public so the test can hold the screen to it
  /// instead of a second copy of the wording drifting inside the test file.
  static const String policy =
      'Nexus is a local-first application. No data, audio, or images ever '
      'leave your device unless you explicitly send them to your PC. Your AI '
      'models run locally on your device. No accounts, no cloud, no telemetry.'
      '\n\n'
      'Nexus learns about you using a local memory vault. This data never '
      'leaves your device, is never used to train models, and you can view, '
      'edit, or delete it at any time.';

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    // The same pushed-page chrome as About: title in a translucent bar, the
    // framework's back chevron, and the list sliding under it.
    return CupertinoPageScaffold(
      backgroundColor: palette.bg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.surface.withValues(alpha: 0.82),
        border: Border(
          bottom: BorderSide(color: palette.separator, width: 0.5),
        ),
        middle: const Text('Privacy Policy'),
      ),
      child: NexusPage(
        children: [
          const NexusPageHeader(
            title: 'Privacy Policy',
            subtitle: 'What happens to your data.',
          ),
          NexusGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(NexusSpace.lg),
                child: Text(
                  policy,
                  // The page's own ink: rows carry their colours from the
                  // theme, and a paragraph must read as one of them rather
                  // than as the platform's default body colour.
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
