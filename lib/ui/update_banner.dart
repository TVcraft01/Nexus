import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../mesh/updater.dart';

/// The banner a device shows when a newer Nexus exists, when the hand-off needs
/// the user to do something, or when it could not complete.
///
/// It lives on its own because it is the one surface that has to be honest
/// about three different situations on the device where updates actually
/// happen: a next step ([note]) is not a failure ([error]), and neither is
/// rendered while [applying].
class UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final bool applying;

  /// What went wrong, if anything did.
  final String? error;

  /// What the user still has to do — a step, not a failure.
  final String? note;

  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

  const UpdateBanner({
    super.key,
    required this.info,
    required this.applying,
    required this.error,
    required this.note,
    required this.onUpdate,
    required this.onDismiss,
  });

  /// How this platform's button hands the update over.
  static String actionLabel() => switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'View update',
        TargetPlatform.android => 'Update & install',
        _ => 'Update & restart',
      };

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      leading: Icon(
        error != null
            ? Icons.error_outline_rounded
            : note != null
                ? Icons.info_outline_rounded
                : Icons.system_update_rounded,
      ),
      content: Text(
        error ??
            note ??
            (applying
                ? 'Updating to v${info.version}…'
                : 'Nexus v${info.version} is available'),
      ),
      actions: [
        TextButton(
          onPressed: applying ? null : onDismiss,
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: applying ? null : onUpdate,
          child: Text(actionLabel()),
        ),
      ],
    );
  }
}
