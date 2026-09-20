// The Nexus core: a small field of particles that says what Nexus is actually
// doing.
//
// It keeps the identity the redesign gave it — one thin, dimensional sphere in
// the header, not a neon "AI orb" — but the sphere is now drawn as a seeded
// constellation of fine dots that reacts to real signals: a wave while the
// microphone is open and loudness arrives, a collapse and ordered orbits while
// the brain works, deliberate pulses while an action runs, an outward ring per
// utterance while speech is actually coming out, and a still constellation the
// rest of the time.
//
// The doctrine has not changed, and it is the whole point of the component: a
// field that shimmers while nothing is happening is decoration pretending to be
// information, and one that says "thinking" when nothing is thinking is a lie
// in the corner of the screen. So motion means work, colour means state, and a
// state with no honest signal is simply absent.
//
// Where the signals come from:
//
//  * **listening** — the microphone really is open, and Android's recogniser
//    reports the loudness of what it hears (`onRmsChanged`), which the field
//    turns into wave height. No level signal on a platform means no fake
//    reaction: the wave breathes at its floor.
//  * **speaking** — the text-to-speech engine now reports when an utterance
//    starts and ends, so the outward pulses are timed from real audio. The
//    field shows the speaking mood when speech is the only thing happening; if
//    an ask is already in flight, that more immediate state keeps the field,
//    because a Core cannot honestly claim two states at once.
//  * **connecting** — still absent, and for the same reason as before: the
//    mesh reports reachability after the fact (`isOnline` answers about now),
//    never a connection in progress. There is no signal that means "trying
//    right now", so there is nothing truthful to show.
//
// The simulation, the rendering and the signals each live in their own file
// (`design/particles/`, `core/audio_level.dart`, `core/speech.dart`). This one
// owns the vocabulary and the mapping from it to a mood — one table, so a new
// state is one row.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'design/particles/particle_field.dart';
import 'design/particles/particle_simulation.dart';

/// What the core is allowed to say about itself.
///
/// Deliberately short. The eight-state vocabulary the product brief names
/// includes two members this build does not show as *presence states*:
///
///  * **speaking** — the platform now reports utterance start and stop, and the
///    field uses it (the particles propagate outward in time with the voice),
///    but a full presence state would collide with the states that describe
///    work in flight: an ask can be thinking while the previous reply is still
///    being read aloud, and the row beside the Core can only honestly say one
///    of them. The field says "speaking" when speech is the only thing
///    happening.
///  * **connecting** — the mesh reports reachability after the fact
///    (`isOnline` answers about now), never a connection in progress. There
///    is no signal that means "trying right now", so there is nothing
///    truthful to show.
///
/// Adding either without its signal would be the exact fake state this core
/// exists to avoid.
enum NexusCoreState {
  /// Nothing is happening. Nexus is here and ready.
  idle('Idle'),

  /// The microphone is on and Nexus is waiting for you to speak.
  listening('Listening'),

  /// A question is out with the brain and the answer has not come back.
  thinking('Thinking'),

  /// An action is being carried out — here, or on a paired device.
  working('Working'),

  /// Paired devices exist but none of them can be reached right now.
  offline('Offline'),

  /// The last thing Nexus tried, it could not do on this device.
  error("Couldn't do that");

  const NexusCoreState(this.label);

  /// The words a screen reader announces, and what a tooltip would say.
  final String label;

  /// Whether Nexus is *doing* something, as opposed to resting or reporting.
  /// Only these states animate, because motion in the core has to mean work.
  bool get isActive =>
      this == listening || this == thinking || this == working;
}

/// The one owner of what the core shows.
///
/// Precedence is immediacy: what Nexus is doing this instant beats what it
/// could not do last, which beats where it stands.
///
/// Every argument is a signal the app already has — the microphone, the brain
/// exchange, an action in flight, the last result, the mesh — and nothing here
/// invents one. A caller with no signal for an argument passes `false` and the
/// core says nothing about it.
NexusCoreState coreStateFor({
  required bool listening,
  required bool thinking,
  required bool working,
  required bool failed,
  required bool offline,
}) {
  if (listening) return NexusCoreState.listening;
  if (thinking) return NexusCoreState.thinking;
  if (working) return NexusCoreState.working;
  if (failed) return NexusCoreState.error;
  if (offline) return NexusCoreState.offline;
  return NexusCoreState.idle;
}

/// What the field should look like for a state. One row per state: adding a
/// state without a mood is a compile error, which is the point.
ParticleMood particleMoodFor(NexusCoreState state) => switch (state) {
      NexusCoreState.idle => ParticleMood.rest,
      NexusCoreState.listening => ParticleMood.listening,
      NexusCoreState.thinking => ParticleMood.thinking,
      NexusCoreState.working => ParticleMood.working,
      NexusCoreState.offline => ParticleMood.offline,
      NexusCoreState.error => ParticleMood.error,
    };

/// The Nexus presence indicator: the particle field, compact by default. It is
/// a status, not a hero, and it has to sit in a header beside a title without
/// crowding it.
class NexusCore extends StatelessWidget {
  const NexusCore({
    super.key,
    required this.state,
    this.size = 40,
    this.energy,
    this.speaking,
  });

  final NexusCoreState state;

  /// Edge length of the square the field is painted into. Small on purpose.
  final double size;

  /// Microphone loudness while listening, and whether speech is coming out.
  /// Both optional and both real: a caller with no signal passes null and the
  /// field shows the state without inventing a reaction.
  final ValueListenable<double>? energy;
  final ValueListenable<bool>? speaking;

  @override
  Widget build(BuildContext context) {
    // A tooltip so a pointer user can read the state the colour encodes —
    // the core says what it is in words on hover, not only in hue. It is
    // excluded from semantics because the field announces the same thing,
    // precisely and once.
    return Tooltip(
      message: state.label,
      excludeFromSemantics: true,
      child: ParticleField(
        mood: particleMoodFor(state),
        energy: energy,
        speaking: speaking,
        size: size,
        semanticLabel: 'Nexus — ${state.label}',
      ),
    );
  }
}
