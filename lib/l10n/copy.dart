import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// The shell's own copy, in the language the user chose.
///
/// An extension rather than threading an `l10n` local through sixty build
/// methods: every call site reads as one expression — `context.l10n.close` — and
/// the strings that move out of a widget constructor look exactly like the ones
/// around them.
///
/// Non-null by construction: `nullable-getter: false` in `l10n.yaml` makes this
/// throw when the tree has no delegate behind it. That is a real bug (a shell
/// rendered outside the app's `MaterialApp`) rather than a screen that quietly
/// stays English, which is the failure mode the fallback rules exist to stop.
extension NexusL10n on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
