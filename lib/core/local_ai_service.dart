// The brain the shell talks to — one prompt in, one answer out.
//
// This interface exists because the answer comes from more than one place. The
// device's own model is the first choice: no network, no account, and it works
// on a train. The PC's Ollama is the second: faster and better, but only when
// the phone is on the same Wi-Fi. When neither can answer there is no brain at
// all, and the shell says so in a sentence.
//
// That decision lives here, once, instead of as a branch in every `_send`: the
// screens ask [current] for a brain, and [FallbackAiService] walks the two
// candidates in order. Which brain answered is not a thing a screen needs to
// know — the on-device model and the PC both return a string or throw.
//
// What the interface deliberately does *not* carry: chat history, tools, or a
// timeout. Those are decisions for an implementation — the PC's Ollama does one
// request with a 30-second timeout and no memory, the on-device engine keeps its
// own queue and idle unload. A seam that prescribed them would be a seam the
// second implementation has to fight.
//
// Streaming is carried twice on purpose. [generateResponseStream] is the shape a
// chat bubble wants and the one both screens use; [generateResponse] stays as the
// whole-answer shape, because the one-shot form is the honest way to state "ask
// and wait", and because a brain that cannot stream (a future third one, a test
// fake) can implement it in terms of the one method it already has.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, immutable, visibleForTesting;

import 'ai_status.dart' show AiSource, AiStatus;
import 'brain.dart' show ChatTurn;
import 'model_capabilities.dart';
import 'ollama_service.dart';
import 'on_device_ai_service.dart';
import 'on_device_model.dart' show ModelChoice, OnDeviceModelChoice;
import 'paired_devices.dart' show PairedDevice, PairedDevices;
import 'text_generation_backend.dart';

/// One earlier exchange, as a brain that is being asked to remember it needs.
///
/// Deliberately the smallest thing that can carry a conversation: who spoke and
/// what they said. No ids, no timestamps, no per-turn options — a brain that
/// wanted any of those would be asking the screen for something the screen does
/// not have, and a screen that had to build them would be inventing them.
///
/// [fromUser] rather than a role string for the same reason the rest of this
/// file uses booleans: a typo in `'assistant'` would be a silent third role, and
/// there is no third role.
@immutable
class AiTurn {
  const AiTurn({required this.fromUser, required this.text});

  const AiTurn.user(this.text) : fromUser = true;

  const AiTurn.assistant(this.text) : fromUser = false;

  /// True for the user's own words, false for the brain's.
  final bool fromUser;

  /// What was said, as it was said. Never empty: a turn nobody said anything in
  /// is not history, it is a gap, and callers drop those before they get here.
  final String text;

  /// The shape the on-device engine's own seam speaks.
  ChatTurn get chatTurn =>
      (role: fromUser ? 'user' : 'assistant', content: text);

  @override
  String toString() => 'AiTurn(${fromUser ? 'user' : 'assistant'}: $text)';
}

/// How many earlier messages a brain is shown.
///
/// A conversation is context, and context is memory: every turn handed to the
/// model is tokens it holds in a KV cache a phone has a couple of thousand of.
/// Ten is a few exchanges — enough for "and tomorrow?" to have a referent,
/// small enough that a long conversation cannot walk a 0.5B model off the end
/// of its context and turn a good answer into a truncated one.
const int kAiHistoryLimit = 10;

/// [turns] as a brain should be handed them: at most [limit] of the most recent
/// ones, and never starting on the assistant's own words.
///
/// The second rule is what keeps a chat template honest. Templates are built
/// around a conversation that starts with the user — Qwen's ChatML, Llama's
/// headers, Ollama's own renderer — and a message list that opens with an
/// assistant turn is one some of them refuse and others quietly mis-render.
/// Trimming from the front may therefore drop one turn more than [limit] asks
/// for.
List<AiTurn> trimAiHistory(List<AiTurn> turns, {int limit = kAiHistoryLimit}) {
  final List<AiTurn> recent = turns.length <= limit
      ? turns
      : turns.sublist(turns.length - limit);
  var start = 0;
  while (start < recent.length && !recent[start].fromUser) {
    start++;
  }
  return start == 0 ? recent : recent.sublist(start);
}

/// What the shell needs from a brain.
///
/// One method, because one thing is asked of it: given what the user said, say
/// something back. Failures are part of the contract — `generateResponse`
/// throws (a [ModelNotFoundException], an [OllamaException], any implementation's
/// own exception), and the caller turns that into a sentence on screen rather
/// than a crash. A brain that answered `null` for "I could not" would push that
/// distinction into every caller, which is the thing this interface exists to
/// avoid.
abstract class LocalAiService {
  /// Test seam: the brain a test wants the shell to use.
  ///
  /// A static override rather than an injected dependency because the callers
  /// are widget state — a screen's `_send` and a live turn's answer — and
  /// neither has a constructor to take one through. It is the same shape the
  /// microphone and the speaker already use, which is the point: a test that
  /// fakes the AI reads like a test that fakes the microphone.
  static LocalAiService Function()? override;

  /// The memoised default so the app holds one engine, not one per message.
  ///
  /// An on-device model that was rebuilt for every question would reload 470 MB
  /// of weights each time; [OnDeviceAiService] is cheap to hold and expensive to
  /// recreate, so the chain is built once.
  static LocalAiService? _default;

  /// The brain the shell uses: the fake in a test, the real router in the app.
  ///
  /// [HiveRouter] asks the paired PC first when it is reachable and falls back
  /// to the device's own model when it is not. [FallbackAiService] is still the
  /// two-brain chain a test can build explicitly, but the app's default is the
  /// router: the PC in the room is a bigger model, and using it without the
  /// user changing a setting is the whole point of the hive.
  static LocalAiService get current =>
      override?.call() ??
      (_default ??= HiveRouter(
        onDevice: OnDeviceAiService(),
        pc: const OllamaService(),
      ));

  /// Forgets the memoised chain. Tests use this after pointing the on-device
  /// model at a temp directory; the app never calls it.
  static void resetDefault() => _default = null;

  /// What the app remembers about the user, as a system-turn suffix.
  ///
  /// Read at request time rather than copied into the chain: a fact learned in
  /// this conversation is available to the next answer, and a fact deleted in
  /// Privacy is gone from the next answer even though the engine is still warm.
  /// Null means the app has no memory service installed (a test, a desktop
  /// shell) and the system turn is left exactly as it was.
  static String Function()? memoryContext;

  /// The user's standing instructions (Settings › Brain › System prompt).
  ///
  /// Read at request time for the same reason [memoryContext] is: editing the
  /// field applies to the very next answer without rebuilding the brain.
  static String Function()? customInstructions;

  /// [system] with the remembered facts and the user's standing instructions
  /// after it, one blank line between each block.
  ///
  /// Empty memory and an empty custom field answer [system] unchanged, so a
  /// build with neither sends exactly the prompt it always did.
  static String systemWithMemory(String system) {
    final String memory = memoryContext?.call().trim() ?? '';
    final String custom = customInstructions?.call().trim() ?? '';
    final StringBuffer out = StringBuffer(system);
    if (memory.isNotEmpty) {
      out
        ..write('\n\n')
        ..write(memory);
    }
    if (custom.isNotEmpty) {
      out
        ..write('\n\n')
        ..write(
          'Standing instructions from the user. Follow them in every '
          'answer:\n',
        )
        ..write(custom);
    }
    return out.toString();
  }

  /// Answers [prompt], or throws.
  Future<String> generateResponse(String prompt);

  /// The same answer, as it is written.
  ///
  /// This is the shape a chat bubble wants: the first piece arrives while the
  /// model is still thinking, so a screen that used to say "Thinking…" for ten
  /// seconds can show the answer growing instead. A brain that has nothing to
  /// stream yields its whole answer as one piece ([OllamaService] does exactly
  /// that today); the on-device engine yields real tokens.
  ///
  /// The contract mirrors [generateResponse]: a brain that cannot answer at all
  /// throws, and a brain that stops after it has already yielded words throws
  /// too — the caller is showing those words, and it is the only one that can
  /// say the answer ended early. The stream ends when the answer does.
  ///
  /// [history] is what was said before [prompt], oldest first, and it exists for
  /// the one screen that has a conversation rather than a message: live mode,
  /// where the user speaks a reply to something they just heard and "it" would
  /// otherwise have no referent at all. It is optional because every other
  /// caller asks one question at a time — a chat bubble has the thread on
  /// screen, and the privacy promise here is that a brain is told what it needs
  /// and nothing more.
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  });
}

/// The two brains, in the order the app trusts them.
///
/// The first answer wins: an on-device model that speaks is never second-guessed
/// by the PC, which is both the privacy promise and the reason the fallback is
/// invisible when it works. The PC is asked only when the device could not
/// answer at all — no model file ([ModelNotFoundException]), a model that could
/// not load, a model that returned nothing. Every other failure is logged and
/// treated the same way, because the user is waiting and the alternative to
/// trying the PC is a notice they cannot act on.
///
/// When both fail, the error is [OllamaException] carrying
/// [kNexusOllamaUnreachableText] — the one sentence the shell already knows how
/// to show as a red notice.
class FallbackAiService implements LocalAiService, TextGenerationBackend {
  const FallbackAiService({required this.onDevice, required this.pc});

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) =>
      generateResponseStream(prompt, history: history ?? const <AiTurn>[]);

  /// The device's own model. Asked first, always.
  final LocalAiService onDevice;

  /// The PC's Ollama. Asked only when [onDevice] could not answer.
  final LocalAiService pc;

  @override
  Future<String> generateResponse(String prompt) async {
    try {
      final String answer = await onDevice.generateResponse(prompt);
      if (answer.trim().isNotEmpty) return answer;
      // The contract says answer or throw; an empty answer is neither, and it
      // is not worth showing to a user who asked a question.
      debugPrint('AI: on-device answered with nothing; trying the PC');
    } on ModelNotFoundException catch (error) {
      debugPrint('AI: ${error.message} Trying the PC.');
    } on InsufficientMemoryException catch (error) {
      // Not a brain that failed: a model that does not fit. Asking the PC would
      // hide the one fact the user can act on — the model they picked is too big
      // for this phone — and the shell switches down to the smaller one.
      debugPrint('AI: ${error.message} Not asking the PC.');
      rethrow;
    } on Object catch (error) {
      debugPrint('AI: on-device failed ($error); trying the PC');
    }

    try {
      return await pc.generateResponse(prompt);
    } on OllamaException {
      rethrow;
    } on Object catch (error) {
      // A PC seam that throws something other than its own exception is still
      // "the PC did not answer", which is the sentence the user can act on.
      debugPrint('AI: PC failed ($error)');
      throw const OllamaException(kNexusOllamaUnreachableText);
    }
  }

  /// The device's stream, and the PC's only when the device has said nothing.
  ///
  /// The one rule that makes streaming different from the one-shot chain: a
  /// failure *before the first token* is the device's failure, and the PC may
  /// cover it; a failure *after* words are on screen is this turn's failure, and
  /// switching brains mid-answer would hand the user two half-sentences instead
  /// of one with a straight account of what happened. The error is rethrown so
  /// the caller — which holds the words it has already shown — can append the
  /// sentence.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    bool answered = false;
    try {
      await for (final String piece in onDevice.generateResponseStream(
        prompt,
        history: history,
      )) {
        if (piece.isEmpty) continue;
        answered = true;
        yield piece;
      }
      if (answered) return;
      // The contract says answer or throw; an empty stream is neither, and it
      // is not worth showing to a user who asked a question.
      debugPrint('AI: on-device answered with nothing; trying the PC');
    } on InsufficientMemoryException catch (error) {
      // See [generateResponse]: too big is the user's decision to make.
      debugPrint('AI: ${error.message} Not asking the PC.');
      rethrow;
    } on OnDeviceAiException catch (error) {
      if (answered) rethrow;
      debugPrint('AI: ${error.message} Trying the PC.');
    } on Object catch (error) {
      if (answered) rethrow;
      debugPrint('AI: on-device failed ($error); trying the PC');
    }

    try {
      await for (final String piece in pc.generateResponseStream(
        prompt,
        history: history,
      )) {
        yield piece;
      }
    } on OllamaException {
      rethrow;
    } on Object catch (error) {
      debugPrint('AI: PC failed ($error)');
      throw const OllamaException(kNexusOllamaUnreachableText);
    }
  }
}

/// Which machine the next answer will come from.
///
/// The chip in the header and the router that makes the decision share this
/// enum: a screen never guesses from a bool, and there are exactly two states a
/// user can be in.
enum HiveCompute {
  /// The model on this phone.
  onDevice,

  /// Ollama on a paired PC, over the local network.
  pc,
}

/// Something the router did that the screen should say out loud.
///
/// A notice rather than a sentence because two surfaces read it differently —
/// the chat appends a system pill, the live page adds a turn — and because the
/// router must not know which screen is listening.
enum HiveNotice {
  /// The PC came online while the selected on-device model is the small one.
  /// Shows the one-time "your PC is connected" banner.
  pcConnectedWeakModel,

  /// The PC stopped answering mid-request. The device takes over.
  pcDisconnected,
}

/// What the chat shows when the PC drops while it was answering.
const String kNexusPcDisconnectedPill =
    '🔌 PC disconnected. Switched to on-device AI.';

/// The one-time banner for a PC that just made the small model unnecessary.
const String kNexusPcConnectedBanner =
    'Your PC is connected! Nexus is now using your PC\'s power for smarter '
    'answers.';

/// The hive's router: the PC when it is there, the phone when it is not.
///
/// This is [LocalAiService] with one preference: a paired desktop that answers
/// Ollama's `/api/tags` is a bigger model than anything running on the phone, so
/// it answers first. No setting is involved — the user paired the PC once, and
/// the router notices it is back on the network.
///
/// The address is the pairing's, not a build flag: a phone cannot reach Ollama
/// on `localhost` (that is the phone), so a paired desktop's first LAN address is
/// dialled on Ollama's port. An explicit `NEXUS_OLLAMA_HOST` still wins, which
/// keeps the desktop build and the tests pointed at one place.
///
/// A failure is never shown as a failure of the answer: the PC disappearing is a
/// route change, and the device's model picks the question up where the PC left
/// it. The screen is told through [notices] so it can say which machine answered
/// — a pill for the switch, a banner for the upgrade.
class HiveRouter implements LocalAiService, TextGenerationBackend {
  HiveRouter({
    required this.onDevice,
    required this.pc,
    List<PairedDevice> Function()? paired,
    this.pcProbe,
    this.cacheFor = const Duration(seconds: 10),
  }) : _paired = paired ?? (() => PairedDevices.instance.devices);

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) =>
      generateResponseStream(prompt, history: history ?? const <AiTurn>[]);

  /// The device's own model. The route when no PC answers, and the route back
  /// when one stops.
  final LocalAiService onDevice;

  /// The PC's Ollama. Asked first whenever [refresh] says it is reachable.
  final LocalAiService pc;

  /// Where the paired list comes from. A function so the router reads the list
  /// as it is now, not as it was when the chain was built.
  final List<PairedDevice> Function() _paired;

  /// The reachability check, injectable for a test. Null means probe [pc] — or
  /// the service built for the paired address — with its own two-second call.
  final Future<bool> Function()? pcProbe;

  /// How long one probe answers for. A status chip and a send in the same
  /// minute must not mean two round trips; ten seconds is longer than a burst
  /// of messages and shorter than the time it takes a user to walk out of
  /// Wi-Fi range.
  final Duration cacheFor;

  /// Which machine the app is using, live. The header chip listens here, so a
  /// question asked from any screen updates every screen's status.
  static final ValueNotifier<HiveCompute> compute = ValueNotifier<HiveCompute>(
    HiveCompute.onDevice,
  );

  static final StreamController<HiveNotice> _notices =
      StreamController<HiveNotice>.broadcast();

  /// What the router wants a screen to say. Broadcast: the chat and the live
  /// page may both be listening, and neither owns the stream.
  static Stream<HiveNotice> get notices => _notices.stream;

  /// Shown once per app session. A PC that reconnects after lunch is the same
  /// upgrade, and the second banner would be nagging.
  static bool _weakPcBannerShown = false;

  DateTime? _checkedAt;
  bool _online = false;
  OllamaService? _target;

  /// The probe that is already on its way, if any.
  ///
  /// Two checks can arrive in the same second — the screen's first read and
  /// the app-resume read — and the second must wait for the first rather than
  /// read a cache entry that was written before the probe answered. That race
  /// once left the chip on "PC Compute" while the composer still said the
  /// device was answering: both were true of different moments.
  Future<bool>? _inFlight;

  /// Forgets the route and the one-time banner. Tests use this; the app never
  /// does.
  @visibleForTesting
  static void debugReset() {
    compute.value = HiveCompute.onDevice;
    _weakPcBannerShown = false;
  }

  /// Probes the paired PC and updates [compute].
  ///
  /// Answers whether the PC answers. Called by the header when the screen opens
  /// and by every generation; [force] is for a user action that should not wait
  /// out the cache.
  Future<bool> refresh({bool force = false}) {
    final DateTime? checkedAt = _checkedAt;
    if (!force &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < cacheFor) {
      return Future<bool>.value(_online);
    }
    final Future<bool>? running = _inFlight;
    if (running != null) return running;
    final Future<bool> check = _check();
    _inFlight = check;
    return check.whenComplete(() {
      if (identical(_inFlight, check)) _inFlight = null;
    });
  }

  Future<bool> _check() async {
    _checkedAt = DateTime.now();
    final PairedDevice? device = _pairedDesktop();
    if (device == null) {
      _target = null;
      _setOnline(false);
      return false;
    }
    final OllamaService? target = _serviceFor(device);
    final bool online =
        await (pcProbe?.call() ??
            target?.isReachable() ??
            Future<bool>.value(false));
    _target = online ? target : null;
    _setOnline(online);
    return online;
  }

  void _setOnline(bool online) {
    _online = online;
    final HiveCompute next = online ? HiveCompute.pc : HiveCompute.onDevice;
    if (compute.value == next) return;
    compute.value = next;
    ModelCapabilities.observe(
      online ? const AiStatus(AiSource.pc) : const AiStatus(AiSource.onDevice),
    );
    if (online && !_weakPcBannerShown && _weakModelSelected) {
      _weakPcBannerShown = true;
      _notices.add(HiveNotice.pcConnectedWeakModel);
    }
  }

  /// True when the selected on-device model is the one the PC makes redundant.
  bool get _weakModelSelected =>
      ModelChoice.instance.choice == OnDeviceModelChoice.qwen;

  /// The first paired device that is a computer rather than a phone.
  ///
  /// The pairing record is the gate, exactly as the user set it up: a device
  /// this one has never paired with is not offered its compute just because it
  /// is on the Wi-Fi. "Online" is then the probe, not the row's stale flag.
  PairedDevice? _pairedDesktop() {
    final List<PairedDevice> desktops = _paired()
        .where(
          (PairedDevice device) =>
              !device.isThisDevice && _looksLikeComputer(device),
        )
        .toList();
    if (desktops.isNotEmpty) {
      // A PC that said it runs Ollama is the one to ask first; a PC that never
      // mentioned it is still probed, because the capability can be newer than
      // the pairing record.
      for (final PairedDevice device in desktops) {
        if (device.ollama) return device;
      }
      return desktops.first;
    }
    // A build can also be pointed at one machine explicitly
    // (`NEXUS_OLLAMA_HOST`). That address is the pairing it cannot lose: the
    // stored device list is written by the Devices screen and may not have a
    // desktop row yet, while the build itself already names one. A loopback
    // address is this machine, not a PC, and is never promoted.
    final LocalAiService base = pc;
    if (base is! OllamaService) return null;
    final String host = Uri.tryParse(base.baseUrl)?.host ?? '';
    if (host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1') {
      return null;
    }
    return const PairedDevice(
      id: 'configured-ollama',
      name: 'PC',
      publicKey: '',
      platform: 'linux',
    );
  }

  static bool _looksLikeComputer(PairedDevice device) {
    if (device.ollama) return true;
    final String platform = device.platform.toLowerCase();
    if (platform == 'linux' ||
        platform == 'macos' ||
        platform == 'windows' ||
        platform == 'desktop') {
      return true;
    }
    final String where = '${device.name} ${device.detail}'.toLowerCase();
    return where.contains('pc') ||
        where.contains('desktop') ||
        where.contains('mac') ||
        where.contains('linux') ||
        where.contains('windows');
  }

  /// The Ollama client for [device]: the build's own address when it was set
  /// explicitly, otherwise the paired LAN address on Ollama's port.
  OllamaService? _serviceFor(PairedDevice device) {
    final LocalAiService base = pc;
    if (base is! OllamaService) return null;
    final Uri? configured = Uri.tryParse(base.baseUrl);
    final String host = configured?.host ?? '';
    final bool loopback =
        host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1';
    if (!loopback) return base;
    for (final String address in device.addresses) {
      final String candidate = address.trim();
      if (!_isLanIpv4(candidate)) continue;
      return OllamaService(
        baseUrl: 'http://$candidate:11434',
        model: base.model,
        timeout: base.timeout,
        client: base.client,
        system: base.system,
        clock: base.clock,
        includeClock: base.includeClock,
        includeMemory: base.includeMemory,
      );
    }
    return base;
  }

  static bool _isLanIpv4(String host) {
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return false;
    return !host.startsWith('127.') && host != '0.0.0.0';
  }

  /// The PC client for this answer, or null when the device answers.
  Future<LocalAiService?> _pcForThisAnswer() async {
    if (!await refresh()) return null;
    return _target ?? pc;
  }

  @override
  Future<String> generateResponse(String prompt) async {
    final LocalAiService? target = await _pcForThisAnswer();
    if (target != null) {
      try {
        final String answer = await target.generateResponse(prompt);
        if (answer.trim().isNotEmpty) return answer;
        debugPrint('AI: PC answered with nothing; using the device');
      } on Object catch (error) {
        debugPrint('AI: PC failed ($error); switching to the device');
        _lostPc();
      }
    }
    return onDevice.generateResponse(prompt);
  }

  /// The PC's answer, whole, then the device's if the PC did not finish.
  ///
  /// The PC's pieces are collected before the first one is yielded. Ollama is
  /// asked with `stream: false` today, so this loses no streaming; what it buys
  /// is the promise in the failure path — a PC that dies mid-answer is replaced
  /// by a whole device answer, never by half of one brain followed by half of
  /// the other.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    final LocalAiService? target = await _pcForThisAnswer();
    if (target != null) {
      try {
        final StringBuffer buffer = StringBuffer();
        await target
            .generateResponseStream(prompt, history: history)
            .forEach(buffer.write);
        final String answer = buffer.toString();
        if (answer.trim().isNotEmpty) {
          yield answer;
          return;
        }
        debugPrint('AI: PC answered with nothing; using the device');
      } on Object catch (error) {
        debugPrint('AI: PC failed ($error); switching to the device');
        _lostPc();
      }
    }
    yield* onDevice.generateResponseStream(prompt, history: history);
  }

  /// The PC stopped answering: the device is the route now, and the screen is
  /// told once. The next prompt re-probes after the cache window rather than
  /// hammering a PC that just refused a connection.
  void _lostPc() {
    _checkedAt = DateTime.now();
    _online = false;
    _target = null;
    _setOnline(false);
    _notices.add(HiveNotice.pcDisconnected);
  }
}
