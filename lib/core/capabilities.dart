// What Nexus is allowed to do: every optional feature is a choice, never a
// default. The registry names each capability, says what it does in plain
// words, and discloses what it costs (a permission, a network call, disk)
// BEFORE the toggle can move - no dark patterns, no bundled consent.
//
// Only the local model stays on: without it the app does nothing, and it is
// explained on first launch instead of toggled. Pairing itself is an explicit
// opt-in (off on a fresh install), and every post-pairing capability —
// clipboard, files, notifications, location — is a separate toggle, all
// default OFF. A stored value always wins, so an existing user keeps theirs.
import 'store.dart';

// One optional thing Nexus can do.
enum Capability {
  // "remind me to take milk at the store" fires on arrival. Costs the
  // location permission plus one OpenStreetMap lookup per new place.
  locationReminders,
  // Copy here, paste on a paired device. Costs nothing but privacy: paired
  // devices see what is copied while this is on.
  clipboardSync,
  // Paired devices may browse files shared from this device.
  fileShare,
  // Paired devices may trigger notifications on this device.
  notificationShare,
  // This device shares its location with paired devices.
  locationShare,
  // The microphone button listens. On-device when the language pack is
  // installed; the system recognizer is the fallback when it is not.
  voiceInput,
  // Say the name to start listening. Audio never leaves this phone.
  wakeWord,
  // Nearby devices can find this one and pair with it. Explicit opt-in.
  meshPairing,
  // The model that answers offline. Costs ~470MB on first download.
  localModel,
}

// What the Capabilities section shows for one [Capability]: the words, the
// price, and how the switch reads and writes it.
class CapabilityInfo {
  const CapabilityInfo({
    required this.title,
    required this.description,
    required this.needs,
    required this.alwaysOn,
    required this.read,
    required this.write,
  });

  final String title;
  final String description;

  // The price, shown under the description ("Needs: Always location" or
  // "Needs: nothing"). Tapping it opens the relevant system screen.
  final String needs;

  // True for the one that stays on (local model): rendered as an
  // explanation, never a switch.
  final bool alwaysOn;

  final bool Function(NexusStore store) read;
  final void Function(NexusStore store, bool value) write;

  // The registry, in the order the section shows it.
  static List<(Capability, CapabilityInfo)> all() => [
    (
      Capability.locationReminders,
      CapabilityInfo(
        title: 'Location reminders',
        description:
            'Remind you when you arrive somewhere. A new place costs one '
            'online lookup of its name; after that everything is on-device.',
        needs: 'Needs: Always location',
        alwaysOn: false,
        read: (s) => s.locationReminders,
        write: (s, v) => s.locationReminders = v,
      ),
    ),
    (
      Capability.clipboardSync,
      CapabilityInfo(
        title: 'Clipboard sync',
        description:
            'Copy on one device, paste on another. Text only - paired '
            'devices see what you copy while this is on.',
        needs: 'Needs: nothing',
        alwaysOn: false,
        read: (s) => s.clipboardSync,
        write: (s, v) => s.clipboardSync = v,
      ),
    ),
    (
      Capability.fileShare,
      CapabilityInfo(
        title: 'File sharing',
        description:
            'Let paired devices browse files you share. Nothing is shared '
            'until you turn this on.',
        needs: 'Needs: storage access',
        alwaysOn: false,
        read: (s) => s.fileShare,
        write: (s, v) => s.fileShare = v,
      ),
    ),
    (
      Capability.notificationShare,
      CapabilityInfo(
        title: 'Notifications',
        description:
            'Let paired devices show notifications here. Off means silent.',
        needs: 'Needs: notification permission',
        alwaysOn: false,
        read: (s) => s.notificationShare,
        write: (s, v) => s.notificationShare = v,
      ),
    ),
    (
      Capability.locationShare,
      CapabilityInfo(
        title: 'Location sharing',
        description:
            'Share this device\'s location with paired devices. Off means '
            'no location ever leaves this phone.',
        needs: 'Needs: location permission',
        alwaysOn: false,
        read: (s) => s.locationShare,
        write: (s, v) => s.locationShare = v,
      ),
    ),
    (
      Capability.wakeWord,
      CapabilityInfo(
        title: 'Wake word',
        description:
            'Say \'Hey Jarvis\' to start listening. Audio is processed '
            'on this phone, never sent anywhere. Uses more battery when '
            'enabled. (Custom wake word coming in a future build.)',
        needs: 'Needs: Microphone',
        alwaysOn: false,
        read: (s) => s.wakeWord,
        write: (s, v) => s.wakeWord = v,
      ),
    ),
    (
      Capability.voiceInput,
      CapabilityInfo(
        title: 'Voice input',
        description:
            'Listen when you tap the mic. Recognized on this phone when your '
            'language pack is available; otherwise Android’s recognizer '
            'handles it.',
        needs: 'Needs: Microphone',
        alwaysOn: false,
        read: (s) => s.voiceInput,
        write: (s, v) => s.voiceInput = v,
      ),
    ),
    (
      Capability.meshPairing,
      CapabilityInfo(
        title: 'Mesh pairing',
        description:
            'Let this phone talk to your other devices. Everything stays '
            'on your own network - no cloud, no account. Pairing is '
            'explicit: showing or scanning a code is consent, and every '
            'request needs a tap to accept.',
        needs: 'Needs: nearby-devices discovery',
        alwaysOn: false,
        read: (s) => s.pairingEnabled,
        write: (s, v) => s.pairingEnabled = v,
      ),
    ),
    (
      Capability.localModel,
      CapabilityInfo(
        title: 'Local AI model',
        description:
            'Answers questions offline, on this phone. Downloads a ~470MB '
            'model on first use.',
        needs: 'Needs: ~470MB downloads once',
        alwaysOn: true,
        read: (_) => true,
        write: (_, _) {},
      ),
    ),
  ];
}
