// The Nexus particle field's physics. Pure Dart: no Flutter, no widgets, no
// painters — so the behaviour of the field is testable frame by frame without
// a screen, and the drawing code never owns a rule about where a particle
// wants to be.
//
// Three jobs, three homes:
//   * this file      — where the particles want to be, given a mood
//   * particle_field — how they are drawn, and when the clock runs
//   * the caller     — what mood the app is honestly in (state, mic, speech)
//
// Nothing here knows what a NexusCoreState is. It speaks in [ParticleMood]s,
// and the mapping table lives with the widget that does know, so a change to
// the core's vocabulary cannot silently change the physics.
import 'dart:math' as math;

/// What the field is being asked to express.
///
/// One mood per thing Nexus can honestly be doing. [rest] and [offline] are
/// still on purpose: their target positions carry no time term at all, so the
/// field settles and the clock can stop.
enum ParticleMood {
  /// Nothing is happening: a compact, still constellation.
  rest,

  /// The microphone is open: a wave travelling around the field, its height
  /// driven by how loud the voice actually is.
  listening,

  /// A question is out with the brain: the field collapses and re-forms into
  /// ordered orbits.
  thinking,

  /// An action is being carried out: deliberate pulses, one per beat.
  working,

  /// Nexus is speaking: rings propagate outward in time with the utterance.
  speaking,

  /// Nothing can be reached: the constellation, held closer and dimmer.
  offline,

  /// The last thing Nexus tried failed: the field destabilises, then settles.
  error;

  /// Whether the field has to keep moving in this mood. A resting field stops
  /// its clock once it has settled — motion in this app means work.
  bool get isMoving =>
      this != rest && this != offline && this != error;
}

/// Where the particles are pointed for one frame of simulation.
class ParticleFrame {
  const ParticleFrame({
    required this.mood,
    this.energy = 0,
    this.pulse = 0,
  });

  final ParticleMood mood;

  /// Microphone loudness, 0 (silence) to 1 (loud). Only [ParticleMood.listening]
  /// reads it; a caller with no level signal passes 0 and the wave still
  /// breathes at its floor, because the mic genuinely being open is itself the
  /// signal.
  final double energy;

  /// Progress through the current speech pulse, 0 to 1, taken from the real
  /// utterance start. Only [ParticleMood.speaking] reads it.
  final double pulse;
}

/// One dot in the field.
///
/// Positions are normalised: radius 1 is the field's own edge, whatever size
/// it is drawn at. The sphere the particles sit on is fixed per particle
/// ([theta], [phi], [r0], all seeded), so the constellation is the same one
/// every time the app opens — an identity, not a new random arrangement.
class Particle {
  Particle({
    required this.r0,
    required this.theta,
    required this.phi,
    required this.seed,
    required this.inner,
  })  : x = 0,
        y = 0,
        z = 0,
        vx = 0,
        vy = 0,
        vz = 0;

  /// Rest radius: the shell has thickness, and a few particles live inside it.
  final double r0;

  /// Azimuth on the shell, in radians.
  final double theta;

  /// Polar angle on the shell, in radians (0 = the top pole).
  final double phi;

  /// Stable 0..1 randomness: jitter, phase offsets, per-particle gain.
  final double seed;

  /// Whether this particle belongs to the inner structure (depth, not decor:
  /// the inner ones give the field its dimension under parallax).
  final bool inner;

  double x, y, z;
  double vx, vy, vz;

  double get radius => math.sqrt(x * x + y * y + z * z);
}

/// The field's step function: springs toward a per-mood target, integrated at
/// a fixed step so behaviour does not depend on the phone's frame rate.
class ParticleSimulation {
  ParticleSimulation({required this.count, int seed = 7})
      : _random = math.Random(seed) {
    _build();
    // The field arrives already formed. It is a status, not an entrance: a
    // constellation that glides in from the middle every time the header is
    // rebuilt would be the decorative motion this component exists to avoid.
    settle(const ParticleFrame(mood: ParticleMood.rest));
  }

  /// How many dots the field has. Passed in rather than defaulted here, so the
  /// design token stays the one owner of the number.
  final int count;

  final math.Random _random;
  final List<Particle> particles = [];

  double _t = 0;
  double _errorAge = 0;
  ParticleMood _lastMood = ParticleMood.rest;

  /// Seconds of simulation run so far. Exposed for tests and for the field's
  /// pulse bookkeeping.
  double get elapsed => _t;

  /// The largest speed in the field — the field's own answer to "am I still
  /// moving?", so the clock can stop when the answer is no.
  double get maxSpeed {
    var m = 0.0;
    for (final p in particles) {
      final s = math.sqrt(p.vx * p.vx + p.vy * p.vy + p.vz * p.vz);
      if (s > m) m = s;
    }
    return m;
  }

  /// The mean distance from the centre: how open or collapsed the field is.
  /// The cheapest honest summary of the shape, and what the tests assert on.
  double get meanRadius {
    if (particles.isEmpty) return 0;
    var sum = 0.0;
    for (final p in particles) {
      sum += p.radius;
    }
    return sum / particles.length;
  }

  /// Whether the field has stopped moving on its own. The field's clock stops
  /// when this is true and the mood asks for no motion.
  ///
  /// The threshold is in field units per second, and the field is drawn about
  /// 40dp across, so 0.03 is well under a tenth of a pixel of movement per
  /// frame: below it, calling the field still is honest.
  bool get isSettled => maxSpeed < 0.03;

  /// Puts every particle at its current mood's target, with no motion at all.
  /// Used when the platform asks for animations to be off: the field is still
  /// shows the right shape, it simply never moves.
  void settle(ParticleFrame frame) {
    for (final p in particles) {
      final (x, y, z) = _target(p, frame, 0);
      p.x = x;
      p.y = y;
      p.z = z;
      p.vx = 0;
      p.vy = 0;
      p.vz = 0;
    }
    _lastMood = frame.mood;
  }

  /// Advances the field by [dt] seconds. Long frames are clamped and split, so
  /// a stalled phone resumes smoothly instead of exploding the springs.
  void step(double dt, ParticleFrame frame) {
    if (dt <= 0) return;
    if (frame.mood != _lastMood) {
      if (frame.mood == ParticleMood.error) _errorAge = 0;
      _lastMood = frame.mood;
    }
    final clamped = dt.clamp(0.0, 0.05);
    // Fixed sub-steps: the same motion at 60 and 120 Hz, and stable springs.
    var remaining = clamped;
    const stepSize = 1 / 120;
    while (remaining > 0) {
      final h = remaining < stepSize ? remaining : stepSize;
      _integrate(h, frame);
      remaining -= h;
    }
    if (frame.mood == ParticleMood.error) _errorAge += clamped;
  }

  void _integrate(double h, ParticleFrame frame) {
    _t += h;
    final (spring, damping) = _constants(frame.mood);
    for (final p in particles) {
      final (tx, ty, tz) = _target(p, frame, _t);
      final gain = 0.85 + 0.3 * p.seed; // no two dots move in lockstep
      p.vx += (tx - p.x) * spring * gain * h;
      p.vy += (ty - p.y) * spring * gain * h;
      p.vz += (tz - p.z) * spring * gain * h;
      final decay = math.exp(-damping * h);
      p.vx *= decay;
      p.vy *= decay;
      p.vz *= decay;
      p.x += p.vx * h;
      p.y += p.vy * h;
      p.z += p.vz * h;
      // A spring that overshoots on a stalled frame must not fling a dot off
      // screen, so the radius is bounded at the edge of the drawn field.
      final r = p.radius;
      if (r > 1.45 || r < 0.10) {
        final scale = (r > 1.45 ? 1.45 : 0.10) / (r == 0 ? 1 : r);
        p.x *= scale;
        p.y *= scale;
        p.z *= scale;
        p.vx *= 0.4;
        p.vy *= 0.4;
        p.vz *= 0.4;
      }
    }
  }

  /// Spring stiffness and damping per mood. Stiff and eager while listening
  /// (the field should follow a voice), soft and slow when resting (nothing
  /// should twitch), over-damped while thinking (order, not bounce).
  (double, double) _constants(ParticleMood mood) => switch (mood) {
        ParticleMood.rest => (7.0, 7.4),
        ParticleMood.listening => (11.0, 6.0),
        ParticleMood.thinking => (9.0, 8.2),
        ParticleMood.working => (10.0, 7.0),
        ParticleMood.speaking => (10.0, 6.4),
        ParticleMood.offline => (6.0, 7.6),
        // Stiff on the way back: a failure should be a moment, not a mood the
        // field drifts out of.
        // Critically damped on purpose (2 * sqrt(k)): the fastest way back to
        // rest without a bounce, so a failure really is brief.
        ParticleMood.error => (24.0, 9.8),
      };

  /// Where one particle wants to be this instant, in normalised space.
  (double, double, double) _target(Particle p, ParticleFrame frame, double t) {
    switch (frame.mood) {
      case ParticleMood.rest:
        // A still constellation: every particle sits where it was born, with a
        // little irregularity so it reads as a constellation and not a lattice.
        return _onShell(p, p.r0 * (1 + 0.06 * math.sin(p.seed * 6.283)));

      case ParticleMood.offline:
        // The same shape, held closer and (when drawn) dimmer. Nothing is
        // broken — it is just out of reach.
        return _onShell(p, p.r0 * 0.74);

      case ParticleMood.listening:
        // A wave travelling around the shell. Louder voice, bigger
        // displacement; silence leaves a slow breath, because the mic being
        // open is itself the signal and a dead-still field would look broken.
        final wave = math.sin(p.theta * 2.0 - t * 2.4 + p.seed * 0.8);
        final amp = 0.09 + 0.62 * frame.energy;
        final r = p.r0 * (1 + 0.10 * frame.energy) + amp * (0.30 + 0.70 * wave);
        return _onShell(p, r);

      case ParticleMood.thinking:
        // Collapse, then hold orbit: ordered motion, no bounce. The rings turn
        // at one steady rate — a brain working, not a firework.
        final a = p.theta + t * 1.15;
        final r = 0.40 + 0.09 * math.sin(p.phi * 4 + p.seed);
        final sinPhi = math.sin(p.phi);
        return (
          math.cos(a) * sinPhi * r,
          math.cos(p.phi) * r,
          math.sin(a) * sinPhi * r,
        );

      case ParticleMood.working:
        // Deliberate pulses: the field draws in, then hands something outward,
        // once per beat, and each beat steps the rings round — information
        // moving through the system rather than noise.
        final beat = t / 1.05;
        final phase = beat - beat.floorToDouble();
        final push = phase < 0.22
            ? phase / 0.22
            : math.pow(1 - (phase - 0.22) / 0.78, 1.6).toDouble();
        final idx = p.seed * 6.283 + beat.floorToDouble() * (math.pi / 4);
        final r = (p.inner ? 0.34 : 0.60) + 0.20 * push;
        final sinPhi = math.sin(p.phi);
        return (
          math.cos(idx) * sinPhi * r,
          math.cos(p.phi) * r * 0.85,
          math.sin(idx) * sinPhi * r,
        );

      case ParticleMood.speaking:
        // An outward-travelling ring per pulse, timed from the utterance
        // itself: outer dots answer later than inner ones, so the ring visibly
        // propagates instead of blinking as a whole.
        final lagged = (frame.pulse - 0.22 * p.r0) % 1.0;
        final env = math.sin(lagged * math.pi);
        final r = p.r0 * (1 + 0.10 * (1 - p.r0)) + 0.30 * env * (0.45 + 0.55 * p.r0);
        return _onShell(p, r);

      case ParticleMood.error:
        // Destabilise, then settle. The first half second throws the field
        // apart; after that the springs pull every dot back to rest, so the
        // failure is a moment and not a state the field is stuck in.
        if (_errorAge < 0.4) {
          final spread = math.sin((_errorAge / 0.4) * math.pi);
          final noise = 0.10 + 0.25 * p.seed;
          final r = p.r0 * (1 + 0.55 * spread) + spread * noise;
          final jitter = 0.16 * spread * (p.seed - 0.5);
          return _onShell(p, r, wobble: jitter);
        }
        return _onShell(p, p.r0 * (1 + 0.06 * math.sin(p.seed * 6.283)));
    }
  }

  /// A point on the particle's own shell direction, at radius [r].
  (double, double, double) _onShell(Particle p, double r, {double wobble = 0}) {
    final sinPhi = math.sin(p.phi);
    return (
      math.cos(p.theta) * sinPhi * r,
      math.cos(p.phi) * r + wobble * r,
      math.sin(p.theta) * sinPhi * r,
    );
  }

  /// The seeded constellation: an even shell (Fibonacci distribution, so the
  /// dots do not clump) with per-particle radial thickness, plus a thin inner
  /// group that only shows up at depth. Built once, never re-rolled.
  void _build() {
    const golden = math.pi * (3 - 2.23606797749979);
    final innerCount = (count * 0.12).round();
    for (var i = 0; i < count; i++) {
      final inner = i < innerCount;
      // z walks the pole to pole; the golden angle spreads the azimuth, which
      // is what keeps the shell even instead of striped.
      final z = 1 - (i / (count - 1)) * 2;
      final jitter = _random.nextDouble();
      particles.add(
        Particle(
          r0: inner ? 0.26 + 0.26 * jitter : 0.66 + 0.32 * jitter,
          theta: i * golden,
          phi: math.acos(z.clamp(-1.0, 1.0)),
          seed: _random.nextDouble(),
          inner: inner,
        ),
      );
    }
  }
}
