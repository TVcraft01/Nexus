// What Nexus is allowed to do: every optional feature is a choice, never a
// default. The registry names each capability, says what it does in plain
// words, and discloses what it costs (a permission, a network call, disk)
// BEFORE the toggle can move - no dark patterns, no bundled consent.
//
// Only two things stay on: mesh pairing and the local model, because
// without them the app does nothing - and those two are explained on first
// launch instead of toggled. Everything else is off on a fresh install;
// a stored value always wins, so an existing user keeps what they had.
import 'store.dart';

// One optional thing Nexus can do.
enum Capability {
  // "remind me to take milk at the store" fires on arrival. Costs the
  // location permission plus one OpenStreetMap lookup per new place.
  locationReminders,
  // Copy here, paste on a paired device. Costs nothing but privacy: paired
  // devices see what is copied while this is on.
  clipboardSync,
  // The microphone button listens. Audio never leaves this phone.
  voiceInput,
  // Nearby devices can find this one and pair with it.
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

  // True for the two that stay on (mesh pairing, local model): rendered
  // as an explanation, never a switch.
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
      Capability.voiceInput,
      CapabilityInfo(
        title: 'Voice input',
        description:
            'Listen when you tap the mic. Audio is processed on this '
            'phone, never sent anywhere.',
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
            'on your own network - no cloud, no account.',
        needs: 'Needs: nearby-devices discovery',
        alwaysOn: true,
        read: (_) => true,
        write: (_, _) {},
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
