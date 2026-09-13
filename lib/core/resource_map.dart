// The capability / resource seam — one owner for "who around me can do this".
//
// An intent already resolves to an [AgentActions] capability id, and the
// registry in `capability.dart` already says where that capability is
// *declared* to run. What was missing was the middle: for one capability, what
// do the devices around this one actually hold, which of them are reachable
// right now, and is this device one of them. `answers.dart` answered pieces of
// that ad hoc — `_somewhereRuns` asked "does anyone have this", the
// find/ring answer matched names — and each caller had its own idea of what
// counts as "a device that can".
//
// This file is that middle, as data and interfaces only. It reads device
// state; it holds none, and it runs nothing.
//
// TWO THINGS IT DELIBERATELY DOES NOT DO YET:
//
//   1. It routes nothing. [ResourceMap.choose] returns a recommendation and
//      has no caller that moves work onto the chosen device. Handing a task
//      to a peer needs a task protocol, a result channel and an authorization
//      check at the far end, and none of those exist — so the seam stops at
//      "this is who I would ask", never at "I asked them". When routing
//      lands, this is the one place that decides.
//
//   2. It never claims more evidence than it has. Nothing in Nexus receives a
//      capability advertisement from a peer yet: a paired device's abilities
//      are assumed from the platform it reported at pairing, and only this
//      device's own abilities are [CapabilityEvidence.verified]. The seam says
//      which is which rather than flattening them, because "it is a phone, so
//      it can probably call" and "it told me it can call" are different facts.
import 'agent_contract.dart';
import 'capability.dart';

/// How Nexus came to believe a device can run a capability.
enum CapabilityEvidence {
  /// This device proved it: the action is one Nexus actually runs here end to
  /// end. Only ever true for the device the assistant is running on.
  verified,

  /// Nexus assumed it from the platform the device reported at pairing. True
  /// today for every paired device, because no peer announces what it can do —
  /// a phone that has never told Nexus anything still looks like a phone.
  assumed,
}

/// What kind of thing a device is, from the platform it reported. Used to
/// resolve the kind a user names ("my phone") against the real registry,
/// instead of hoping the device's name happens to contain the word.
enum DeviceKind {
  phone,
  computer,

  /// A platform Nexus has no kind word for — never guessed at.
  other,
}

/// The kind [platform] names, or [DeviceKind.other] when Nexus has no word for
/// it. Kept here so the registry, the answers and the seam agree on one
/// mapping.
DeviceKind deviceKindOf(String platform) => switch (platform.trim().toLowerCase()) {
  'android' => DeviceKind.phone,
  'linux' || 'windows' || 'macos' => DeviceKind.computer,
  _ => DeviceKind.other,
};

/// The words a user might say for [kind]. Used only to match a noun the user
/// actually said — never to describe a device back to them.
Set<String> deviceKindWords(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => const {'phone', 'mobile', 'tablet', 'android'},
  DeviceKind.computer => const {
    'pc',
    'computer',
    'desktop',
    'laptop',
    'mac',
    'windows',
    'linux',
  },
  DeviceKind.other => const {},
};

/// One device as a resource: what it is, whether it is in reach, and what it
/// is believed able to do — with how that belief was formed.
class DeviceResource {
  final String id;
  final String name;

  /// The platform the device reported, or '' when it never said.
  final String platform;

  /// True for the device the assistant is running on.
  final bool isThisDevice;

  /// True when the mesh can reach it right now. Always true for this device.
  final bool online;

  /// Capability id -> how Nexus knows this device has it.
  final Map<String, CapabilityEvidence> abilities;

  const DeviceResource({
    required this.id,
    required this.name,
    required this.platform,
    required this.isThisDevice,
    required this.online,
    this.abilities = const {},
  });

  DeviceKind get kind => deviceKindOf(platform);

  bool can(String capabilityId) => abilities.containsKey(capabilityId);

  CapabilityEvidence? evidenceFor(String capabilityId) =>
      abilities[capabilityId];

  /// The capabilities this device is *believed* to have, sorted so a report
  /// reads the same way twice.
  List<String> get capabilityIds {
    final ids = abilities.keys.toList()..sort();
    return ids;
  }
}

/// What the world looks like for one capability: whether Nexus declares it at
/// all, which devices are believed able, and which of those are reachable.
class CapabilityReach {
  final String capabilityId;

  /// True when the registry declares this capability. False means Nexus has
  /// never heard of it — a different failure from "nobody here can do it".
  final bool declared;

  /// Devices believed able, this device first, reachable-before-offline.
  final List<DeviceResource> able;

  const CapabilityReach({
    required this.capabilityId,
    required this.declared,
    required this.able,
  });

  /// The able devices the mesh can actually reach right now.
  List<DeviceResource> get reachable =>
      [for (final d in able) if (d.online) d];

  /// Whether any known device is believed able — reachable or not.
  bool get hasAnyDevice => able.isNotEmpty;

  /// Whether any believed-able device is in reach.
  bool get hasExecutor => reachable.isNotEmpty;

  /// True when at least one able device really runs this (not a platform
  /// guess). False means every claim here is an assumption.
  bool get verifiedSomewhere =>
      able.any((d) => d.evidenceFor(capabilityId) == CapabilityEvidence.verified);

  /// Where this capability is *declared* to work, in the user's terms, from
  /// the registry's own platform sets — "a phone", "a phone or computer". Null
  /// when the registry does not declare it, so a caller never invents reach.
  String? get declaredOn {
    final capability = capabilityFor(capabilityId);
    if (capability == null || capability.platforms.isEmpty) return null;
    final kinds = <DeviceKind>{
      for (final platform in capability.platforms) deviceKindOf(platform),
    };
    final words = [
      for (final kind in [DeviceKind.phone, DeviceKind.computer])
        if (kinds.contains(kind))
          kind == DeviceKind.phone ? 'a phone' : 'a computer',
    ];
    if (words.isEmpty) return null;
    if (words.length == 1) return words.single;
    return '${words.first} or ${words.last}';
  }
}

/// Every device Nexus knows about, with what each is believed able to do.
///
/// Built fresh from the device snapshots the caller already has, so it always
/// reflects current state as long as the caller rebuilds it — it caches
/// nothing, because a stale reach map is worse than a slow one.
class ResourceMap {
  /// The device the assistant is running on, or null when unknown.
  final DeviceResource? here;

  /// The paired devices, in the order the registry reported them.
  final List<DeviceResource> paired;

  const ResourceMap({this.here, this.paired = const []});

  /// Reads a device snapshot list into the seam's vocabulary.
  ///
  /// [verifiedLocally] is the set of actions this device genuinely runs end to
  /// end; anything else it lists as a capability is an assumption from its own
  /// platform, exactly as a peer's is. Empty means "assume everything", which
  /// is what a caller that has not been told otherwise should get — the
  /// alternative is claiming a device does things it may not.
  factory ResourceMap.of({
    AgentDeviceSnapshot? local,
    List<AgentDeviceSnapshot> paired = const [],
    Set<String> verifiedLocally = const {},
  }) {
    DeviceResource read(AgentDeviceSnapshot d, {required bool isThisDevice}) =>
        DeviceResource(
          id: d.id,
          name: d.name,
          platform: d.platform,
          isThisDevice: isThisDevice,
          online: d.online,
          abilities: {
            for (final capability in d.capabilities)
              capability.id:
                  isThisDevice && verifiedLocally.contains(capability.id)
                      ? CapabilityEvidence.verified
                      : CapabilityEvidence.assumed,
          },
        );
    return ResourceMap(
      here: local == null ? null : read(local, isThisDevice: true),
      paired: [for (final d in paired) read(d, isThisDevice: false)],
    );
  }

  /// Every known device, this one first, then reachable peers before offline
  /// ones. Ordering is stable so an answer reads the same way twice.
  List<DeviceResource> get devices {
    final peers = paired.toList()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return 0;
      });
    return [?here, ...peers];
  }

  /// The paired devices only — this device is not a peer.
  List<DeviceResource> get peers => paired;

  /// Everything the world can say about [capabilityId] right now.
  CapabilityReach reach(String capabilityId) => CapabilityReach(
    capabilityId: capabilityId,
    declared: capabilityFor(capabilityId) != null,
    able: [for (final d in devices) if (d.can(capabilityId)) d],
  );

  /// The device Nexus *would* ask to run [capabilityId], or null when none can.
  ///
  /// Order: this device (no transfer, nothing to authorize), then a reachable
  /// peer that really runs it, then a reachable peer whose ability is only an
  /// assumption from its platform. An offline device is never chosen — asking
  /// a device nobody can reach is how a wait turns into a hang.
  ///
  /// NOTHING ROUTES WORK THROUGH THIS YET, and no caller may present its
  /// result as an action taken. It answers "who would I ask", which is all
  /// Nexus can honestly say until a task protocol exists.
  DeviceResource? choose(String capabilityId) {
    final self = here;
    if (self != null && self.can(capabilityId)) return self;
    final candidates = [
      for (final d in reachablePeersOf(capabilityId))
        if (d.evidenceFor(capabilityId) == CapabilityEvidence.verified) d,
      for (final d in reachablePeersOf(capabilityId))
        if (d.evidenceFor(capabilityId) == CapabilityEvidence.assumed) d,
    ];
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Reachable peers believed able to run [capabilityId], in [devices] order.
  List<DeviceResource> reachablePeersOf(String capabilityId) => [
    for (final d in devices)
      if (!d.isThisDevice && d.online && d.can(capabilityId)) d,
  ];
}

/// Why Nexus could not do what was asked.
///
/// The four are kept apart on purpose. "I did not understand you", "Nexus has
/// no such capability", "no device you have can do it" and "you are not
/// allowed" are four different problems with four different next actions, and
/// collapsing them into one "sorry, I can't" is what the brief forbids.
enum UnableReason {
  /// The sentence never resolved to anything, so nothing was attempted. Only
  /// the user can fix this, by teaching the phrasing.
  notUnderstood,

  /// Understood, and Nexus has no such capability at all — generating an
  /// image, for instance. Nothing on any device would help.
  noSuchCapability,

  /// Understood, and the capability is real, but no known device holds it.
  /// A different device (or a paired one) would change the answer.
  noCapableDevice,

  /// Understood, a device holds it, and the request was not permitted —
  /// refused, still waiting for a go-ahead, or something this device is not
  /// allowed to do. The user's decision, not a missing capability.
  notAuthorized,
}

/// The last request Nexus could not carry out, recorded where it failed so
/// "why can't you do this?" can explain from the real reason instead of
/// guessing at one afterwards.
///
/// One field, not a trace: the question is about the thing that just failed.
/// A record of everything Nexus ever refused is a log, which is a different
/// feature with its own retention and privacy questions.
class UnableReport {
  /// What the user actually said.
  final String input;

  /// Which of the four reasons this was, or null when the record cannot
  /// attribute one.
  ///
  /// Null is not a fifth reason: it is the admission that the failure did not
  /// carry a cause and the reach map does not supply one — the request failed
  /// while the ability really exists around here. Guessing "no device can do
  /// it" then would be exactly the invented cause this model exists to
  /// prevent, so the answer says it cannot say why and quotes what it
  /// actually said.
  final UnableReason? reason;

  /// The capability the sentence resolved to, when it resolved to one.
  final String? capability;

  /// What Nexus actually said at the time, verbatim. The explanation quotes
  /// it rather than paraphrasing, so it can never invent a cause.
  final String? detail;

  /// The result's own status, for [UnableReason.notAuthorized] — the difference
  /// between "you said no" and "it is waiting for your go-ahead" is in there.
  final AgentResultStatus? status;

  const UnableReport({
    required this.input,
    this.reason,
    this.capability,
    this.detail,
    this.status,
  });

  /// The registry's label for [capability], or null when Nexus has no entry.
  String? get capabilityLabel =>
      capability == null ? null : capabilityFor(capability!)?.label;
}
