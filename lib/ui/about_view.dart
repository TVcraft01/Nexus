import 'package:flutter/cupertino.dart'
    show CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:flutter/material.dart';

import '../core/version.dart';
import 'components/nexus_ui.dart';
import 'theme.dart';

/// About Nexus: the screen the settings list points at for the facts it used
/// to spell out in place — what this build is, and what it promises.
///
/// Every line is still a row: a label on the left, a value or one line of
/// description on the right. Nothing here is a paragraph, the same way nothing
/// on the settings list is.
class AboutView extends StatelessWidget {
  const AboutView({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    // A pushed page, in iOS chrome: the title in the bar, a back chevron the
    // framework draws, and a translucent bar that blurs the list sliding
    // under it instead of an opaque strip across the top.
    return CupertinoPageScaffold(
      backgroundColor: palette.bg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.surface.withValues(alpha: 0.82),
        border: Border(
          bottom: BorderSide(color: palette.separator, width: 0.5),
        ),
        middle: const Text('About Nexus'),
      ),
      child: NexusPage(
        children: [
          const NexusPageHeader(
            title: 'Nexus $appVersion',
            subtitle: 'What this build is, and what it promises.',
          ),

          const NexusSectionHeader('This build'),
          NexusGroup(
            children: [
              NexusRow(
                title: 'Version',
                minHeight: NexusSize.rowCompact,
                trailing: const NexusRowValue(appVersion),
              ),
              NexusRow(
                title: 'Encryption',
                minHeight: NexusSize.rowCompact,
                subtitle: 'AES-GCM, directly between your devices.',
                trailing: const NexusRowValue('End to end'),
              ),
              NexusRow(
                title: 'Account',
                minHeight: NexusSize.rowCompact,
                trailing: const NexusRowValue('None needed'),
              ),
            ],
          ),

          const NexusSectionHeader('How it behaves'),
          NexusGroup(
            children: [
              NexusRow(
                title: 'Local-first',
                subtitle: 'Pairing secrets and your data stay on your devices.',
              ),
              NexusRow(
                title: 'Reachability is honest',
                subtitle: 'Online only after this device really talked to it.',
              ),
              NexusRow(
                title: 'Understands what you teach it',
                subtitle: 'A phrase taught anywhere works on every device.',
              ),
              NexusRow(
                title: 'Actions need your approval',
                subtitle: 'A change on another device waits for a yes there.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
