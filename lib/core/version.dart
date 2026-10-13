/// The current app version — what this build tells the user, its peers, and
/// the auto-updater it is.
///
/// It must match `version:` in pubspec.yaml (which also carries the build
/// number the stores see). The two drifted apart once, and the cost was
/// user-visible: 0.2.1 shipped with this still reading `0.1.53`, so the
/// updater compared GitHub's `v0.2.1` against `0.1.53`, found it newer, and
/// offered every 0.2.x user an update to the build they were already running —
/// the phone showed "Nexus v0.2.1 is available" while running 0.2.1+155.
///
/// test/version_test.dart now fails when the two drift apart again, and proves
/// the shipped version never reads as an update to itself.
const String appVersion = '0.3.0';
