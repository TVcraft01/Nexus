/// The app's entry point: the UI shell in `main_ui.dart`, with no `-t` flag.
///
/// `flutter run`, `flutter run -d <device>` and `flutter build apk --release`
/// all start the app the way `flutter run -t lib/main_ui.dart` does, because
/// they all run this file, and this file does nothing but hand off to the
/// shell's own `main`.
///
/// It hands off rather than pulling the shell's widget in and calling `runApp`
/// itself so that there is exactly one definition of "start the shell": two
/// entry points that render the same widget tree but configure it separately
/// would drift, and the `-t` shortcut would quietly stop being the truth about
/// the real app.
///
/// The previous entry point — store, identity, mesh, gateway, provisioning
/// intents, the desktop tray, the on-device model and the launcher-icon settle
/// that all of it owns — is intact in `main_old.dart`. Nothing here starts it:
/// the shell is the front end, and wiring it back to those services is the next
/// step rather than something this file should decide by accident.
library;

import 'main_ui.dart' as shell;

void main() => shell.main();
