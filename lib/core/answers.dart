// The assistant's local answer catalog: what it says when a parsed command
// can be answered on this device, plus the pure helpers those answers use
// (fact matching, phone extraction, formatting, arithmetic). Routing —
// which device, which approval, which clarification — stays in
// CommandService; this module only decides the words and the few memory
// writes an answer performs.
import 'dart:math';

import 'agent_contract.dart';
import 'capability.dart';
import 'command_interpreter.dart';
import 'memory.dart';
import 'reminders.dart';
import 'resource_map.dart';
import 'timezones.dart';

/// The window onto the assistant's state the catalog may touch while
/// answering. Kept deliberately small so the catalog is readable and
/// testable without a full [CommandService]:
///  - [facts] is the live fact list — answers may read it and memory
///    commands (remember/forget) mutate it in place.
///  - [devices] lists the mesh devices reachable right now (for honest
///    find/ring answers).
///  - [local] is this device's snapshot (for "is this a phone?" answers).
///  - [onMemoryChanged]/[onFactLearned] fire exactly as in the service so a
///    remembered fact persists and broadcasts through the same funnel.
class AnswerContext {
  AnswerContext({
    required this.facts,
    required this.devices,
    required this.local,
    this.onMemoryChanged,
    this.onFactLearned,
    this.userName,
    this.assistantName = 'Nexus',
    this.verifiedLocally = const {},
    MemoryLedger Function()? ledger,
    this.lastAction,
  }) : _ledgerSource = ledger;

  /// The actions this device genuinely runs end to end. Everything else it
  /// lists as a capability is an assumption from its own platform, and the
  /// resource map says so rather than flattening the two.
  final Set<String> verifiedLocally;

  /// Who can do what around this device.
  ///
  /// Derived from [devices] and [local] on each read rather than stored, so a
  /// cached context cannot report a device that has since gone away, and so
  /// there is one owner of "what counts as able" instead of each answer
  /// having its own rule.
  ResourceMap get resources => ResourceMap.of(
    local: local,
    paired: devices(),
    verifiedLocally: verifiedLocally,
  );

  /// Where the taught phrases and remembered preferences came from, so a
  /// question about provenance can count them without the answer needing its
  /// own copy of the memory.
  ///
  /// A function, not a value: the ledger is immutable, so a ledger captured
  /// when this context was built would go stale the moment something new was
  /// learned. A context nobody gave one to holds nothing, which is the honest
  /// reading of "nothing was recorded".
  final MemoryLedger Function()? _ledgerSource;
  MemoryLedger get ledger => _ledgerSource?.call() ?? const MemoryLedger();

  /// What Nexus last actually did, or null when nothing has been done yet.
  ///
  /// A function rather than a value because the action that matters is the one
  /// that just happened — always after this context was built.
  final LastAction? Function()? lastAction;

  /// Everything the user told Nexus about their world, each entry carrying
  /// where it came from. Mutable on purpose: remembering and forgetting are
  /// memory writes, and the answers below are where they happen.
  final List<MemoryFact> facts;
  final List<AgentDeviceSnapshot> Function() devices;
  final AgentDeviceSnapshot? local;
  final void Function()? onMemoryChanged;

  /// The device this assistant is running on — the source named for anything
  /// the user tells it here.
  String get toldOn => local?.name ?? 'this device';

  /// What the assistant calls this user ("call me sam"), used in greetings.
  final String? userName;

  /// What the user calls the assistant (default Nexus, renamed on setup).
  final String assistantName;
  final void Function(String fact)? onFactLearned;
}

/// Capability ids of a device snapshot, for the catalog cases that ask
/// "can this device act?" (airplane mode, contact actions).
List<String> _capabilitiesOf(AgentDeviceSnapshot? device) =>
    device?.capabilities.map((c) => c.id).toList() ?? const [];

/// Whether [action] can actually execute somewhere in the assistant's world
/// — on this device, or on a paired device. "Somewhere" deliberately ignores
/// whether the device is reachable right now: a phone that is offline still
/// has the address book that makes a call worth asking about.
bool _somewhereRuns(AnswerContext ctx, String action) =>
    ctx.resources.reach(action).hasAnyDevice;

/// The devices whose real name (or id) matches the noun the user said.
///
/// The interpreter keeps the *kind* the user said — "phone", "laptop",
/// "device" — because a kind is all most phrases carry, and it is a good key
/// into the registry: "find my laptop" should reach the device called "work
/// laptop". But a kind is not a name, so it is only ever spoken as one once
/// it has actually matched here. That is the whole rule: a noun that names no
/// device must never be quoted back as if it named one.
List<AgentDeviceSnapshot> _devicesMatching(AnswerContext ctx, String noun) {
  final key = noun.trim().toLowerCase();
  if (key.isEmpty) return const [];
  final named = ctx
      .devices()
      .where(
        (d) =>
            d.name.toLowerCase().contains(key) ||
            d.id.toLowerCase() == key,
      )
      .toList();
  if (named.isNotEmpty) return named;
  // Nothing is called that. The noun may be a *kind* — "my phone", "my pc" —
  // and the registry knows each device's platform, because pairing exchanged
  // it. So the kind resolves against real data instead of against a device's
  // name happening to contain the word: a phone called "Pixel 8" is still a
  // phone, and asking for it should find it.
  final kinds = {
    for (final kind in DeviceKind.values)
      if (deviceKindWords(kind).contains(key)) kind,
  };
  if (kinds.isEmpty) return const [];
  return ctx
      .devices()
      .where((d) => kinds.contains(deviceKindOf(d.platform)))
      .toList();
}

/// Whether the find/ring noun describes the device being spoken to.
///
/// "my device" is the generic noun and always means "mine, the one I am on"
/// — that is what a phone-first user is asking about. A more specific kind
/// ("my pc") means this device when this device is that kind of thing.
bool _nounIsThisDevice(String noun, AgentDeviceSnapshot local) {
  final key = noun.trim().toLowerCase();
  return key == 'device' || local.name.toLowerCase().contains(key);
}

/// The honest answer to `find/ring my <noun>`.
///
/// One rule for the whole class of phrasings, because they all fail the same
/// way: the noun is a kind, and the old answer rendered it inside quotes as
/// though it were a name — `I don't see "device" online right now` invents a
/// device called "device" and answers about it. Which real device the noun
/// names decides the answer instead: a paired one (named, with its state), no
/// clean match (ask which, listing the real registry), or this device (the
/// one being spoken to).
///
/// Neither find nor ring has an executor in this release, so every branch
/// says that rather than implying a search ran or a phone rang.
AgentDispatchResult _findOrRingAnswer(
  ParsedCommand command,
  AnswerContext ctx,
) {
  final noun = command.target.trim();
  final verb = command.action == AgentActions.ringDevice
      ? 'make it ring'
      : 'find it';
  final matches = _devicesMatching(ctx, noun);
  final local = ctx.local;

  if (matches.length == 1) {
    final device = matches.single;
    return _answerWith(
      device.online
          ? '${device.name} is online on your mesh, but I can\'t $verb from '
              'the assistant in this release yet.'
          : 'I don\'t see ${device.name} online right now. $verb needs the '
              'other device connected to your mesh — open the Devices tab to '
              'check.',
    );
  }

  if (matches.length > 1) {
    return _answerWith(
      'More than one paired device matches "$noun" — '
      '${matches.map((d) => d.name).join(', ')}. Open the Devices tab to pick '
      'the one you mean.',
    );
  }

  if (local != null && _nounIsThisDevice(noun, local)) {
    return _answerWith(
      'You\'re on ${local.name} — that\'s the device you\'re asking from. '
      'I can\'t $verb from the assistant in this release yet.',
    );
  }

  final paired = ctx.devices().map((d) => d.name).toList();
  return _answerWith(
    paired.isEmpty
        ? 'I don\'t have a device matching "$noun", and none are paired yet — '
            'open the Devices tab to pair one.'
        : 'I don\'t have a device matching "$noun". Paired right now: '
            '${paired.join(', ')} — open the Devices tab to check.',
  );
}

/// A plain spoken answer from the catalog: honest prose, nothing to execute.
AgentDispatchResult _answerWith(String text) => AgentDispatchResult(
  status: AgentResultStatus.succeeded,
  dispatch: AgentMessage(text),
);

/// "what devices can you use?" — every device Nexus knows, and what each can
/// really do.
///
/// The distinction the answer turns on is evidence. This device's own actions
/// are split into the ones it genuinely runs and the ones it merely lists
/// from its platform; a paired device has never announced anything, so its
/// abilities are assumptions and are labelled as such. Presenting either as
/// fact would be the exact overclaim the brief forbids.
AgentDispatchResult deviceReportAnswer(AnswerContext ctx) {
  final devices = ctx.resources.devices;
  if (devices.isEmpty) {
    return _answerWith(
      'I don\'t know about any devices yet. Pair one from the Devices tab '
      'and I\'ll tell you what it can do.',
    );
  }

  final lines = <String>[];
  var assumedPeers = 0;
  for (final device in devices) {
    if (!device.online) {
      lines.add('${device.name} — offline, so I can\'t use it right now.');
      continue;
    }
    final verified = [
      for (final id in device.capabilityIds)
        if (device.evidenceFor(id) == CapabilityEvidence.verified) id,
    ];
    final assumed = [
      for (final id in device.capabilityIds)
        if (device.evidenceFor(id) == CapabilityEvidence.assumed) id,
    ];
    if (verified.isEmpty && assumed.isEmpty) {
      lines.add('${device.name} — I don\'t know what it can do; '
          'it has never told me.');
      continue;
    }
    final head = device.isThisDevice
        ? '${device.name} — this device'
        : '${device.name} — ${_kindWord(device.kind)}, online';
    final parts = <String>[head];
    if (verified.isNotEmpty) {
      parts.add('  runs now: ${_labelsFor(verified)}');
    }
    if (assumed.isNotEmpty) {
      if (!device.isThisDevice) assumedPeers++;
      parts.add(
        device.isThisDevice
            ? '  listed but not wired up here: ${_labelsFor(assumed)}'
            : '  assumed from its platform: ${_labelsFor(assumed)}',
      );
    }
    lines.add(parts.join('\n'));
  }

  final tail = assumedPeers == 0
      ? ''
      : '\n\nA paired device has never told me what it can really do, so those are '
            'read off its platform, not from it.';
  return _answerWith('Devices I can use:\n  ${lines.join('\n  ')}$tail');
}

/// The label for one capability, or its raw id when the registry has no entry
/// — never a blank, which would read as "this device can nothing".
String _labelOf(String capabilityId) =>
    capabilityFor(capabilityId)?.label ?? capabilityId;

/// Capability labels for [ids], in a stable order, capped so one talkative
/// device cannot crowd out the others.
String _labelsFor(List<String> ids) {
  const shown = 6;
  final labels = [for (final id in ids) _labelOf(id)]..sort();
  if (labels.length <= shown) return labels.join(', ');
  return '${labels.take(shown).join(', ')}, +${labels.length - shown} more';
}

String _kindWord(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => 'phone',
  DeviceKind.computer => 'computer',
  DeviceKind.other => 'device',
};

/// "why did you do that?" — the most recent thing Nexus actually did,
/// explained from the record it made while doing it.
///
/// Every clause comes from that record: which sentence it read, how it
/// resolved it, which capability that became, which device ran it and what
/// came of it. When nothing has been done yet the answer says so instead of
/// inventing a history, and when nothing *ran* — an unresolved sentence or a
/// question — it says that too, because claiming to have acted is the one
/// thing this answer must never do.
AgentDispatchResult lastActionAnswer(AnswerContext ctx) {
  final action = ctx.lastAction?.call();
  if (action == null) {
    return _answerWith(
      'I haven\'t done anything yet, so there\'s nothing to explain. Ask me '
      'something, then ask me again.',
    );
  }

  final lines = <String>['You said "${action.input}".'];
  // Nothing ran: say what Nexus did instead of what it did not do, and never
  // dress a question or an unresolved sentence up as an action.
  switch (action.origin) {
    case ActionOrigin.question:
      lines.add('Nothing ran — I asked you something instead.');
      if (action.detail.isNotEmpty) {
        lines.add('What I asked: "${action.detail}"');
      }
      return _answerWith(lines.join('\n\n'));
    case ActionOrigin.notUnderstood:
      lines.add('I never understood it, so nothing was attempted.');
      if (action.detail.isNotEmpty) {
        lines.add('What I said: "${action.detail}"');
      }
      return _answerWith(lines.join('\n\n'));
    case ActionOrigin.unsupported:
      lines.add(
        'I understood the request, and Nexus has no ability for it at all — '
        'nothing ran.',
      );
      if (action.detail.isNotEmpty) {
        lines.add('What I said: "${action.detail}"');
      }
      return _answerWith(lines.join('\n\n'));
    case ActionOrigin.capability || ActionOrigin.taught:
      break;
  }

  final how = action.capabilityLabel ?? action.capability ?? 'something';
  final source = action.origin == ActionOrigin.taught
      ? 'That is a phrase you taught me — it means $how'
      : 'I understood it as $how';
  if (action.failed) {
    lines.add('$source, and nothing ran it.');
    // The reason, from the same vocabulary "why can't you do this?" uses, so
    // the two explanations cannot disagree about the same failure.
    lines.add(_reasonSentence(ctx, action));
    // And the words Nexus actually used, quoted — the evidence the reason above
    // is drawn from, rather than a paraphrase of it.
    if (action.detail.isNotEmpty) lines.add('What I said: "${action.detail}"');
  } else {
    lines.add(
      action.device == null
          ? '$source.'
          : '$source, and ${action.device} ran it.',
    );
    if (action.detail.isNotEmpty) lines.add('It came off: "${action.detail}"');
  }
  return _answerWith(lines.join('\n\n'));
}

/// The reason, in the four-part vocabulary, for a failure the record explains.
/// One owner, so "why did you do that?" and "why can't you do this?" speak
/// about the same failure with the same words.
String _reasonSentence(AnswerContext ctx, LastAction action) =>
    switch (action.reason) {
      UnableReason.notUnderstood =>
        'I didn\'t understand "${action.input}", so I never tried — Nexus had '
            'no meaning for those words, and guessing at one would have run '
            'something you did not ask for.',
      UnableReason.noSuchCapability => action.capabilityLabel == null
          ? 'Nexus has no such ability at all — nothing on any device would '
                'change that.'
          : 'Nexus has no ${action.capabilityLabel} ability at all — nothing '
                'on any device would change that.',
      UnableReason.noCapableDevice => _noCapableDeviceWhy(ctx, action),
      UnableReason.notAuthorized => switch (action.status) {
        AgentResultStatus.denied =>
          'You turned it down, so nothing ran. That was your decision, not a '
              'fault — ask again and I\'ll wait for your go-ahead.',
        AgentResultStatus.required =>
          'It is still waiting for your go-ahead. Nothing runs until you '
              'approve it.',
        _ => 'The request was not permitted, so it did not run.',
      },
      // The failure carried no cause — so the answer says that, and only adds
      // what the live reach map can still confirm, rather than inventing a
      // reason the failure never had.
      null => _unattributedWhy(ctx, action),
    };

/// "why can't you do this?" — the last failure, explained from the record
/// made at the time.
///
/// The four reasons are the whole point of the answer: "I didn't understand
/// you", "Nexus has no such ability", "no device you have can do it" and
/// "it wasn't permitted" are four different problems with four different next
/// actions. The sentence is chosen by the recorded reason, and the recorded
/// words are quoted rather than paraphrased, so the explanation cannot invent
/// a cause the failure never had.
AgentDispatchResult unableAnswer(AnswerContext ctx) {
  final action = ctx.lastAction?.call();
  if (action == null || !action.failed) {
    // Nothing has failed. If Nexus asked something instead, that is what it
    // did — and saying so is more useful than "nothing to explain".
    if (action != null && action.origin == ActionOrigin.question) {
      return _answerWith(
        'I haven\'t failed at anything — I asked you something instead.\n\n'
        'What I asked: "${action.detail}"',
      );
    }
    return _answerWith(
      'Nothing has failed, so there\'s nothing to explain. Ask me to do '
      'something and, if I can\'t, ask me why.',
    );
  }

  // Name the request being explained, and how Nexus read it. The record
  // survives questions about it, so this answer can be asked long after the
  // failure and must not assume the user still has the sentence in front of
  // them — nor may it leave "it" unaccounted for.
  final lines = <String>[];
  if (action.origin != ActionOrigin.notUnderstood) {
    final label = action.capabilityLabel;
    lines.add(
      label == null
          ? 'The last thing you asked me was "${action.input}".'
          : 'The last thing you asked me was "${action.input}", which I read '
                'as $label.',
    );
  }
  lines.add(_reasonSentence(ctx, action));
  if (action.detail.isNotEmpty) lines.add('What I said: "${action.detail}"');
  return _answerWith(lines.join('\n\n'));
}

/// The "understood, but nowhere here can do it" explanation, from the real
/// reach map: whether anyone holds the capability, whether they are in reach,
/// and where the registry says it works.
String _noCapableDeviceWhy(AnswerContext ctx, LastAction action) {
  final capability = action.capability;
  if (capability == null) {
    return 'I understood the request, but no device I know about can do it.';
  }
  final reach = ctx.resources.reach(capability);
  final where = reach.declaredOn;
  if (!reach.hasAnyDevice) {
    // The capability is named by the caller, which already knows how the
    // sentence was read — repeating it here would say "I understood it as"
    // twice in one answer.
    return 'No device you have says it can do that'
        '${where == null ? '.' : ' — it takes $where.'}';
  }
  // A device gained the ability between the attempt and the question. Say
  // what is true now instead of repeating a verdict that has gone stale.
  final named = [for (final d in reach.able) d.name].join(', ');
  return 'Nothing held it when I tried, and $named lists it now.';
}

/// The failure carried no cause the record can name. Say only what the live
/// reach map still confirms, and never fill the gap with a guess.
String _unattributedWhy(AnswerContext ctx, LastAction action) {
  final capability = action.capability;
  final holders = capability == null
      ? const <String>[]
      : [for (final d in ctx.resources.reach(capability).able) d.name];
  if (holders.isEmpty) {
    return 'I can\'t say why from the record — all I have is what I said at '
        'the time.';
  }
  return 'I can\'t say why from the record: the ability is on '
      '${holders.join(', ')}, so a missing device was not the reason.';
}

/// "what did you infer?" — an honest answer from a system that infers
/// nothing.
///
/// Nexus has no inference engine: nothing derives a fact from behaviour, so
/// there is nothing to report, and the answer says exactly that rather than
/// dressing an assumption up as a conclusion. What it *does* hold is counted
/// from the stamps themselves, by origin, so the distinctions the memory model
/// records — you told me, a device reported it, one of your own answers
/// created it, stored before sources existed — survive into the answer. An
/// inference, if one ever existed, is labelled as an inference and not as a
/// fact; that is the one thing this answer may never soften.
AgentDispatchResult inferredAnswer(AnswerContext ctx) {
  final byOrigin = <MemoryOrigin, int>{};
  void count(MemoryOrigin origin) =>
      byOrigin.update(origin, (n) => n + 1, ifAbsent: () => 1);
  for (final fact in ctx.facts) {
    count(fact.stamp.origin);
  }
  for (final stamp in ctx.ledger.stampMap.values) {
    count(stamp.origin);
  }

  final inferred = byOrigin[MemoryOrigin.inferred] ?? 0;
  final lines = <String>[
    inferred == 0
        ? 'No — I haven\'t inferred anything about you. Nothing in Nexus '
              'works out a fact from your behaviour yet, so there is no '
              'inference to show.'
        : '$inferred of the things I hold came from an inference, not from '
              'anything you told me — I worked them out from how you use '
              'Nexus, and I may be wrong about any of them.',
  ];

  if (byOrigin.isEmpty) {
    lines.add(
      'I hold nothing about you at all right now, so there is nothing to '
      'show either way.',
    );
  } else {
    final counts = [
      for (final origin in MemoryOrigin.values)
        if (byOrigin[origin] case final n?) '  • ${origin.label}: $n',
    ];
    lines.add('Everything I hold, and where it came from:\n${counts.join('\n')}');
    lines.add(
      'Ask "what do you know about me" to see the entries themselves.',
    );
  }
  return _answerWith(lines.join('\n\n'));
}

/// The honest answer when a contact action has no taught number and nothing
/// in the assistant's world can execute it: teach the number instead of
/// echoing an action that can only fail here. (A paired phone would have its
/// own address book — the prompt only fires when no executor is reachable.)
AgentDispatchResult _unknownContactAnswer(String contact, String verb) =>
    AgentDispatchResult(
      // A question, not a result. The sentence asks the user for something
      // Nexus does not have, so reporting it as `succeeded` labelled the card
      // "Done" over a request — the one status claim that was plainly untrue.
      // `needsInfo` is the same status the interpreter uses when a sentence is
      // understood and one detail is missing, and it keeps the core out of the
      // error state, which a question is not.
      status: AgentResultStatus.needsInfo,
      dispatch: AgentMessage(
        'I don\'t have a number for "$contact" yet. Teach me with '
        '"remember that $contact is 0612345678" — then your Nexus phone '
        'can $verb them with the number.',
      ),
    );

/// Words worth matching on — lowercase, alphanumeric runs of 3+ chars,
/// minus a few stopwords so "the" in a topic doesn't match "the" in every
/// fact ("what is the capital of france" must not hit a bike fact).
const _stopWords = {
  'the',
  'and',
  'for',
  'with',
  'that',
  'this',
  'from',
  'was',
  'are',
  'has',
  'had',
  'not',
  'but',
  'all',
  'out',
  'get',
  'got',
};

/// Cross-wording: how people actually ask vs how they said it. Seeded
/// only with observed pairs ("what do you know about internet" for a
/// wifi fact); grows from the assistant log, never by hand-guessing.
const _synonyms = {
  'internet': ['wifi', 'network'],
  'family': ['mom', 'mum', 'mama', 'dad', 'papa', 'brother', 'sister'],
};

Set<String> _topicWords(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.length >= 3 && !_stopWords.contains(w))
    .toSet();

/// Topic words plus their synonyms, so "about internet" reaches a wifi
/// fact without any model.
Set<String> _topicWordsExpanded(String text) {
  final words = _topicWords(text);
  return {...words, for (final w in words) ...?_synonyms[w]};
}

/// Facts loosely matching a spoken topic, best first. Substring matching
/// alone misses real wording: a bike-code fact is "about bike" but not
/// "about bicycle". A fact matches when any of its words loosely matches
/// any topic word — same word, a prefix, or small edit distance for
/// typos. Synonyms ("internet" ↔ "wifi") are deliberately out of scope.
List<MemoryFact> _factsAbout(Iterable<MemoryFact> facts, String topic) {
  final topicWords = _topicWordsExpanded(topic);
  if (topicWords.isEmpty) return const [];
  bool loose(String factWord, String topicWord) {
    if (factWord == topicWord) return true;
    if (factWord.length >= 3 &&
        (factWord.startsWith(topicWord) || topicWord.startsWith(factWord))) {
      return true;
    }
    return topicWord.length >= 4 &&
        factWord.length >= 4 &&
        CommandInterpreter.phraseSimilarity(factWord, topicWord) >= 0.75;
  }

  bool factMatches(String fact) {
    final words = _topicWords(fact);
    return words.any((fw) => topicWords.any((tw) => loose(fw, tw)));
  }

  final hits = facts.where((fact) => factMatches(fact.text)).toList();
  hits.sort(
    (a, b) =>
        _factScore(b.text, topicWords).compareTo(_factScore(a.text, topicWords)),
  );
  return hits;
}

/// The answer to "why do you know that?" / "why do you know about X" —
/// built from the stored stamp of whatever fact matches, never from a canned
/// sentence. It says plainly when nothing matches instead of falling back to
/// a search, because a question about Nexus's own memory has no web answer.
AgentDispatchResult _provenanceAnswer(AnswerContext ctx, String topic) {
  // "why do you know that" carries no topic of its own — the interpreter
  // hands back the word "that", which must not be searched for as if it
  // named something.
  if (topic.isEmpty ||
      const {'that', 'this', 'it', 'those', 'these'}.contains(topic)) {
    return const AgentDispatchResult(
      status: AgentResultStatus.needsInfo,
      message:
          'What should I explain? Ask me "why do you know about my wifi '
          'password".',
    );
  }
  final hits = _factsAbout(ctx.facts, topic);
  if (hits.isEmpty) {
    return AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentMessage(
        'I don\'t know anything about "$topic" — nothing you told me matches '
        'it, so there is nothing to explain.',
      ),
    );
  }
  final now = DateTime.now();
  _markUsed(ctx, hits, now);
  return AgentDispatchResult(
    status: AgentResultStatus.succeeded,
    dispatch: AgentMessage(
      hits.length == 1
          ? hits.single.explain(now)
          : '${hits.length} things I know match "$topic":\n'
                '${hits.map((f) => '  • ${f.explain(now)}').join('\n')}',
    ),
  );
}

/// Records that [used] answered something, by marking each fact used in the
/// caller's live list. This is the one memory write a question can cause, and
/// it is what makes "currently being used" more than a claim — but a fact
/// already used today is not rewritten, so asking twice is not two writes.
void _markUsed(AnswerContext ctx, List<MemoryFact> used, DateTime now) {
  var changed = false;
  for (final fact in used) {
    final marked = fact.usedAt(now);
    if (identical(marked, fact)) continue;
    final at = ctx.facts.indexOf(fact);
    if (at == -1) continue;
    ctx.facts[at] = marked;
    changed = true;
  }
  if (changed) ctx.onMemoryChanged?.call();
}

/// How strongly a fact matches a set of topic words — used only to order
/// multiple hits, never to admit them.
int _factScore(String fact, Set<String> topicWords) =>
    _topicWords(fact).intersection(topicWords).length;

/// A phone-looking token in [fact], normalized to digits, or null. Requires
/// 9..15 digits (E.164 max) so street numbers, years, and card or order
/// numbers never resolve as contacts.
String? _phoneIn(String fact) {
  final run = RegExp(r'\+?[\d\s.\-()]{9,}').firstMatch(fact);
  if (run == null) return null;
  final digits = run.group(0)!.replaceAll(RegExp(r'[^\d+]'), '');
  return digits.length >= 9 && digits.length <= 15 ? digits : null;
}

/// The phone number nexus has been taught for a contact name, or null when
/// no matching fact carries one — the device then falls back to its own
/// address book. Best-scoring fact wins, like question recall.
String? _contactNumber(Iterable<MemoryFact> facts, String name) {
  if (name.isEmpty) return null;
  for (final fact in _factsAbout(facts, name)) {
    final number = _phoneIn(fact.text);
    if (number != null) return number;
  }
  return null;
}

/// The line every help answer ends with — the human frame around the list.
const String _helpClosingLine =
    'If I misunderstand, just teach me once — I remember.';

/// "what can you do?" — the catalogue, built from the capability registry.
///
/// The registry owns this answer: which capabilities are offered, the phrases
/// they are offered as, the section each appears under, the areas those
/// sections are grouped into, and the note beside each capability. A
/// hand-written copy used to live here, and it had already fallen behind — 26
/// declared capabilities were never mentioned, and nothing could catch a line
/// drifting from the phrase it claimed to describe.
///
/// Four shapes, because 47 capabilities in one message is a wall rather than
/// an answer:
///
///  * **no topic** — the summary: one line per area, showing one phrase per
///    section ([helpHeadline]), and how to hear any of it in full.
///  * **a topic naming a section** ("what can you do with music") — that
///    section in full, because that is the thing that was asked about.
///  * **a topic naming only an area** ("what can you do with your things") —
///    every section of that area, in registry order.
///  * **a topic naming nothing** ("what can you do with files") — said
///    plainly, with the areas that do exist. Nothing is invented to have
///    something to say.
///
/// Two things are added here that the registry deliberately does not hold,
/// because they are about the device reading the answer rather than about the
/// capability:
///
///  * **what needs another device.** A capability whose executors are all
///    phones, read on a computer, says so instead of advertising something
///    this device cannot run. Read from the registry's own platform sets, so
///    it cannot disagree with what this device actually offers.
///  * **the closing line**, which is about the assistant rather than any one
///    capability.
///
/// Every double-quoted span below is either a phrase the registry offers for
/// exactly one capability or an area's own question;
/// `test/command_surface_test.dart` reads this output back and proves both, so
/// the answer cannot offer a phrase that means something else or nothing at
/// all.
String helpText(AnswerContext ctx, {String? topic}) {
  final asked = (topic ?? '').trim();
  final localKind = deviceKindOf(ctx.local?.platform ?? '');
  // A question whose words say nothing about what Nexus can do — "what can you
  // do for me" — is the whole list, not a topic nobody has heard of.
  if (asked.isEmpty || helpTopicWords(asked).isEmpty) {
    return _helpSummary(localKind);
  }
  // An area named outright is the area: it is one of the ways in the answer
  // itself offers. Otherwise the narrower reading wins, as it does in the
  // intent rules: a question naming one section gets that section, not the
  // whole area holding it.
  final areas = helpAreasNamed(asked);
  if (areas.isNotEmpty) {
    return _helpScoped(asked, [
      for (final area in areas) ...helpSectionsInArea(area),
    ], localKind);
  }
  final sections = helpSectionsNamed(asked);
  if (sections.isNotEmpty) {
    return _helpScoped(asked, sections, localKind);
  }
  return _helpNothingFor(asked);
}

/// The short answer: what Nexus can do, one line per area, and how to hear any
/// of it in full.
String _helpSummary(DeviceKind localKind) {
  final lines = <String>['Here is what I can do:'];
  final areas = [
    for (final area in kHelpAreas) ?_areaHeadline(area, localKind),
  ];
  if (areas.isNotEmpty) {
    lines
      ..add('')
      ..addAll(areas);
  }
  lines
    ..add('')
    ..add(
      'Ask about any of them in full — "${kHelpAreas.first.question}" — '
      'or just tell me what you want.',
    )
    ..add('')
    ..add(_helpClosingLine);
  return lines.join('\n');
}

/// One area as the summary lists it: its name and one phrase per section it
/// covers, or null when the area offers nothing at all. The phrase is
/// [helpHeadline]'s — the registry's own canonical example where a section has
/// one — and keeps [_helpTail], so a summary read on a computer still says
/// which of its lines this device cannot run.
String? _areaHeadline(HelpArea area, DeviceKind localKind) {
  final headlines = [
    for (final group in helpSectionsInArea(area))
      if (helpHeadline(group) case final capability?)
        '"${capability.example ?? phrasesOf(capability).first}"'
            '${_helpTail(capability, localKind)}',
  ];
  if (headlines.isEmpty) return null;
  return '${area.name}: ${headlines.join(' / ')}';
}

/// What Nexus can do with [asked], in full: every section named, each with all
/// the phrases it offers.
String _helpScoped(
  String asked,
  List<String> sections,
  DeviceKind localKind,
) {
  final lines = <String>['Here is what I can do with $asked:'];
  for (final group in sections) {
    final capabilities = helpCapabilitiesIn(group);
    if (capabilities.isEmpty) continue;
    lines
      ..add('')
      ..add('$group:')
      ..addAll([
        for (final capability in capabilities)
          '  ${[
            for (final phrase in phrasesOf(capability)) '"$phrase"',
          ].join(' / ')}${_helpTail(capability, localKind)}',
      ]);
  }
  lines
    ..add('')
    ..add(_helpClosingLine);
  return lines.join('\n');
}

/// The honest answer when a topic names nothing in this answer. It says what
/// it does not list, offers what it does, and points at the path that can
/// really answer — ask for the thing itself, and Nexus either does it or says
/// why it cannot. It never reaches for a neighbouring capability to appear
/// more capable than it is, and it never claims Nexus is unable to do
/// something it can (this list is not the whole of Nexus: driving an app is
/// a capability no section here advertises yet).
String _helpNothingFor(String asked) => [
  'I don\'t have anything listed for "$asked" yet.',
  '',
  'The areas I do have: ${kHelpAreas.map((area) => area.name).join(', ')} — '
      'say one back to me and I\'ll list it in full.',
  '',
  'Or just ask me for it: if I can, I will — and if I can\'t, I\'ll tell you '
      'why.',
  '',
  _helpClosingLine,
].join('\n');

/// The clause after a capability's phrases: its own note, and — when the
/// capability runs only on a kind of device this is not — what it needs.
String _helpTail(Capability capability, DeviceKind localKind) {
  final notes = <String>[
    ?capability.helpNote,
    ?_needsDeviceNote(capability, localKind),
  ];
  return notes.isEmpty ? '' : ' — ${notes.join('; ')}';
}

/// "needs a phone" / "needs a computer" — said only when Nexus knows what kind
/// of device it is running on and the capability's own platform set excludes
/// it. An unknown platform says nothing rather than guessing, and a capability
/// answered locally has no device to need.
String? _needsDeviceNote(Capability capability, DeviceKind localKind) {
  if (capability.platforms.isEmpty || localKind == DeviceKind.other) {
    return null;
  }
  final kinds = {for (final p in capability.platforms) deviceKindOf(p)};
  if (kinds.contains(localKind)) return null;
  final elsewhere = [
    for (final kind in [DeviceKind.phone, DeviceKind.computer])
      if (kinds.contains(kind)) kind,
  ];
  if (elsewhere.isEmpty) return null;
  // "a phone", not "phone": the line has to read as a sentence.
  return 'needs ${elsewhere.map((k) => 'a ${_kindWord(k)}').join(' or ')}';
}

/// Locally executable intents that need no device: greeting, time, math.
AgentDispatchResult localAnswer(ParsedCommand command, AnswerContext ctx) {
  switch (command.action) {
    case AgentActions.helpGet:
      // The diagnostic questions are about Nexus's own behaviour, not requests
      // for the catalogue — the interpreter marks each with a topic so this
      // switch can tell them apart.
      if (command.arguments['topic'] == 'why') return unableAnswer(ctx);
      if (command.arguments['topic'] == 'actions') return lastActionAnswer(ctx);
      // Any other topic is the area or section the user asked about — "what
      // can you do with music" — and the answer is that part of the catalogue
      // rather than the summary. The registry decides what the topic names, so
      // an unknown one is answered honestly rather than guessed at.
      return _answerWith(
        helpText(ctx, topic: command.arguments['topic'] as String?),
      );
    case AgentActions.greet:
      final name = ctx.userName;
      const base =
          'I can tell you the time, do math, search the web, save notes, show your PC specs, and copy text between your devices. Ask me anything — and if I don\'t understand, I\'ll ask you to teach me.';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          name == null || name.isEmpty ? 'Hello! $base' : 'Hello, $name! $base',
        ),
      );
    case AgentActions.intro:
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I\'m here! I\'m ${ctx.assistantName}, your assistant, running right on this device. I\'m brand new — my first release shipped in August 2026 — so I\'m still learning. Ask me anything, and if I don\'t understand, I\'ll ask you to teach me.',
        ),
      );
    case AgentActions.profileSet:
      final name = command.arguments['name'] as String? ?? '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Got it — $name.',
          action: AgentActions.profileSet,
          arguments: command.arguments,
        ),
      );
    case AgentActions.profileGet:
      // A name taught as a memory fact ("remember that my name is john")
      // still answers here; otherwise the executor reads the profile store
      // — the first-class home — and answers honestly when unknown.
      for (final remembered in ctx.facts) {
        final name = RegExp(
          r'^(?:my name is|i am called|call me) (.+)$',
        ).firstMatch(remembered.text.trim());
        if (name != null) {
          return AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage('Your name is ${name.group(1)}.'),
          );
        }
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: const AgentMessage(
          'Checking…',
          action: AgentActions.profileGet,
        ),
      );
    case AgentActions.timeGet:
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          _formatTime(command.arguments['kind']),
          // The clock keeps ticking instead of freezing at the answer.
          live: command.arguments['kind'] != 'date',
        ),
      );
    case AgentActions.mathCalc:
      final result = evaluateMath(command.arguments['expr'] as String? ?? '');
      if (result == null) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'I couldn\'t work that out — try something like "what is 2 plus 2".',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          '${command.arguments['expr']} = ${_formatNumber(result)}',
        ),
      );
    case AgentActions.webSearch:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I search for?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening search for "$query"…',
          action: AgentActions.webSearch,
          arguments: {'query': query},
        ),
      );
    case AgentActions.weatherGet:
      final place = command.arguments['place'] as String? ?? '';
      final kind = command.arguments['kind'] as String? ?? 'now';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          // No city: "what is the weather" — the device's location or IP
          // answers; the fetched line names the resolved area. Sun
          // questions get their own honest intro line.
          kind == 'sunset'
              ? 'Checking sunset…'
              : kind == 'sunrise'
                  ? 'Checking sunrise…'
                  : place.isEmpty
                      ? 'Checking the weather here…'
                      : 'Checking the weather in $place…',
          action: AgentActions.weatherGet,
          arguments: {'place': place, 'kind': kind},
        ),
      );
    case AgentActions.locationGet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Figuring out where you are…',
          action: AgentActions.locationGet,
        ),
      );
    case AgentActions.musicSearch:
      final query = command.arguments['query'] as String? ?? '';
      final app = command.arguments['app'] as String?;
      final name = app == null ? null : musicApps[app]?.$1;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          name == null
              ? 'Searching for "$query"…'
              : (query.isEmpty
                  ? 'Playing in $name…'
                  : 'Playing "$query" in $name…'),
          action: AgentActions.musicSearch,
          arguments: {'query': query, if (app != null) 'app': app},
        ),
      );
    case AgentActions.timezoneGet:
      final place = command.arguments['place'] as String? ?? '';
      // Only curated cities answer inline; everywhere else goes to the web
      // honestly — the app has no geocoder to guess a zone from a name.
      if (zoneForCity(place) == null) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t know $place\'s time zone — searching instead…',
            action: AgentActions.webSearch,
            arguments: {'query': 'current time in $place'},
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking the time in $place…',
          action: AgentActions.timezoneGet,
          arguments: {'place': place},
        ),
      );
    case AgentActions.calendarAdd:
      final title = command.arguments['title'] as String? ?? '';
      if (title.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I add to your calendar?',
        );
      }
      final app = command.arguments['app'] as String?;
      final name = app == null ? null : calendarApps[app]?.$1;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          name == null
              ? 'Opening a new event: "$title"…'
              : 'Adding "$title" to $name…',
          action: AgentActions.calendarAdd,
          arguments: {'title': title, if (app != null) 'app': app},
        ),
      );
    case AgentActions.appDefault:
      final verb = command.arguments['verb'] as String? ?? 'set';
      final name = command.arguments['name'] as String? ?? '';
      final word = switch (command.arguments['domain'] as String?) {
        'music' => 'music',
        'navigation' => 'navigation',
        'calendar' => 'calendar',
        _ => '',
      };
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          verb == 'clear'
              ? 'Forgetting $name…'
              : 'Setting $name as your $word default…',
          action: AgentActions.appDefault,
          arguments: command.arguments,
        ),
      );
    case AgentActions.calendarRead:
      final when = command.arguments['when'] as String? ?? 'today';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          when == 'tomorrow'
              ? 'Checking tomorrow…'
              : (when == 'week' ? 'Checking this week…' : 'Checking today…'),
          action: AgentActions.calendarRead,
          arguments: {'when': when},
        ),
      );
    case AgentActions.shoppingListAdd:
      final item = command.arguments['item'] as String? ?? '';
      if (item.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I add to the shopping list?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Adding "$item" to your shopping list…',
          action: AgentActions.shoppingListAdd,
          arguments: {'item': item},
        ),
      );
    case AgentActions.shoppingListGet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Reading your shopping list…',
          action: AgentActions.shoppingListGet,
        ),
      );
    case AgentActions.navOpen:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'Where should I take you?',
        );
      }
      final app = command.arguments['app'] as String?;
      final name = app == null ? null : navApps[app]?.$1;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          name == null
              ? 'Opening maps for "$query"…'
              : 'Directions to "$query" in $name…',
          action: AgentActions.navOpen,
          arguments: {'query': query, if (app != null) 'app': app},
        ),
      );
    case AgentActions.noteCreate:
      final text = command.arguments['text'] as String? ?? '';
      if (text.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I note down?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Noted: "$text"',
          action: AgentActions.noteCreate,
          arguments: {'text': text},
        ),
      );
    case AgentActions.timerSet:
      // Accept the remembered default in either shape: an int (typed
      // "300") or the plain answer to the question ("5 minutes").
      final raw = command.arguments['seconds'];
      final seconds = raw is int
          ? raw
          : CommandInterpreter.parseDurationSeconds(raw?.toString() ?? '');
      if (seconds == null || seconds <= 0) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'How long should the timer run?',
        );
      }
      final minutes = seconds ~/ 60;
      final secs = seconds % 60;
      final label = minutes > 0 ? '${minutes}m ${secs}s' : '${secs}s';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Timer set for $label.',
          action: AgentActions.timerSet,
          arguments: {'seconds': seconds},
        ),
      );
    case AgentActions.openUrl:
      final url = command.arguments['url'] as String? ?? '';
      if (url.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I open?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening $url…',
          action: AgentActions.openUrl,
          arguments: {'url': url},
        ),
      );
    case AgentActions.systemInfo:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking system info…',
          action: AgentActions.systemInfo,
        ),
      );
    case AgentActions.volumeSet:
      final mode = command.arguments['mode'] as String? ?? 'mute';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Volume $mode.',
          action: AgentActions.volumeSet,
          arguments: {'mode': mode},
        ),
      );
    // --- System ---
    case AgentActions.appOpen:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What app should I open?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening $query...',
          action: AgentActions.appOpen,
          arguments: {'query': query},
        ),
      );
    case AgentActions.appClose:
      final query = command.arguments['query'] as String? ?? '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Closing $query...',
          action: AgentActions.appClose,
          arguments: {'query': query},
        ),
      );
    case AgentActions.screenshot:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Taking screenshot...',
          action: AgentActions.screenshot,
        ),
      );
    case AgentActions.batteryGet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking battery...',
          action: AgentActions.batteryGet,
        ),
      );
    case AgentActions.brightnessSet:
      final mode = command.arguments['mode'] as String? ?? 'up';
      final level = command.arguments['level'];
      final label = level != null ? 'to $level%' : mode;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Brightness $label.',
          action: AgentActions.brightnessSet,
          arguments: {'mode': mode, if (level != null) 'level': level},
        ),
      );
    case AgentActions.flashlightToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'Flashlight $state.' : 'Toggling flashlight.',
          action: AgentActions.flashlightToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.wifiToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'WiFi $state.' : 'Toggling WiFi.',
          action: AgentActions.wifiToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.bluetoothToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'Bluetooth $state.' : 'Toggling Bluetooth.',
          action: AgentActions.bluetoothToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.lockScreen:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Locking screen.',
          action: AgentActions.lockScreen,
        ),
      );
    // --- Communication ---
    case AgentActions.callPlace:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'Who should I call?',
        );
      }
      final isVideo = command.arguments['mode'] == 'video';
      final app = command.arguments['app'] as String?;
      // Video calls open a named app (WhatsApp/Telegram) by contact, not by
      // number — resolution only applies to plain calls.
      if (!isVideo) {
        final number = _contactNumber(ctx.facts, contact);
        if (number == null && !_somewhereRuns(ctx, AgentActions.callPlace)) {
          return _unknownContactAnswer(contact, 'call');
        }
        final who = number != null ? '$contact at $number' : contact;
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Calling $who...',
            action: AgentActions.callPlace,
            arguments: {'contact': contact, 'number': ?number},
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          app == null
              ? 'Which app should I video call $contact on?'
              : 'Video calling $contact on $app...',
          action: AgentActions.callPlace,
          arguments: {
            'contact': contact,
            'mode': 'video',
            if (app != null) 'app': app,
          },
        ),
      );
    case AgentActions.messageSend:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'Who should I text?',
        );
      }
      final body = command.arguments['body'] as String?;
      final number = _contactNumber(ctx.facts, contact);
      if (number == null && !_somewhereRuns(ctx, AgentActions.messageSend)) {
        return _unknownContactAnswer(contact, 'text');
      }
      final who = number != null ? '$contact at $number' : contact;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          body != null ? 'Texting $who: "$body"' : 'Opening text to $who...',
          action: AgentActions.messageSend,
          arguments: {'contact': contact, 'number': ?number, 'body': ?body},
        ),
      );
    case AgentActions.emailSend:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'Who should I email?',
        );
      }
      final body = command.arguments['body'] as String?;
      // The device's own address book resolves the address (like texts do
      // with numbers); no taught-address concept exists yet, so email stays
      // a device action unless nothing anywhere can run it.
      if (!_somewhereRuns(ctx, AgentActions.emailSend)) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I can\'t open email on this device — try on a device with a mail app.',
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          body != null
              ? 'Emailing $contact: "$body"'
              : 'Opening email to $contact...',
          action: AgentActions.emailSend,
          arguments: {'contact': contact, 'body': ?body},
        ),
      );
    // --- Media ---
    case AgentActions.mediaPlay:
      final query = command.arguments['query'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          query != null ? 'Playing "$query"…' : 'Playing.',
          action: AgentActions.mediaPlay,
          arguments: {if (query != null) 'query': query},
        ),
      );
    case AgentActions.mediaPause:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Paused.', action: AgentActions.mediaPause),
      );
    case AgentActions.mediaNext:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Next track.', action: AgentActions.mediaNext),
      );
    case AgentActions.mediaPrev:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Previous track.',
          action: AgentActions.mediaPrev,
        ),
      );
    case AgentActions.mediaShuffle:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Shuffle toggled.',
          action: AgentActions.mediaShuffle,
        ),
      );
    case AgentActions.mediaRepeat:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Repeat toggled.',
          action: AgentActions.mediaRepeat,
        ),
      );
    // --- Productivity ---
    case AgentActions.alarmSet:
      final hour = command.arguments['hour'] as int? ?? 0;
      final minute = command.arguments['minute'] as int? ?? 0;
      final hh = hour.toString().padLeft(2, '0');
      final mm = minute.toString().padLeft(2, '0');
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Alarm set for $hh:$mm.',
          action: AgentActions.alarmSet,
          arguments: {'hour': hour, 'minute': minute},
        ),
      );
    case AgentActions.reminderSet:
      final raw = command.arguments['text'] as String? ?? '';
      final split = const Reminders().splitTime(raw, Reminders.now());
      if (split == null) {
        // No time in the request — never pretend a reminder was set.
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I\'ll remind you — but when? Try "remind me to buy milk at 6pm" '
            'or "remind me to stretch in 20 minutes".',
          ),
        );
      }
      final (text, dueAt) = split;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Reminder set for ${_clockLabel(dueAt)} — I\'ll tell you then.',
          action: AgentActions.reminderSet,
          arguments: {'text': text, 'dueAt': dueAt.toIso8601String()},
        ),
      );
    case AgentActions.defineWord:
      final word = command.arguments['word'] as String? ?? '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Looking up "$word"...',
          action: AgentActions.defineWord,
          arguments: {'query': 'define $word'},
        ),
      );
    case AgentActions.translateText:
      final text = command.arguments['text'] as String? ?? '';
      final lang = command.arguments['language'] as String?;
      final target = lang != null ? ' to $lang' : '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Translating "$text"$target...',
          action: AgentActions.webSearch,
          arguments: {'query': 'translate $text$target'},
        ),
      );
    case AgentActions.unitConvert:
      final value = command.arguments['value'] ?? 0;
      final from = command.arguments['from'] as String? ?? '';
      final to = command.arguments['to'] as String? ?? '';
      // Currency needs live rates — fetched inline (ECB reference rates,
      // free) when both sides are currencies; a plain unit conversion
      // (miles->km) is computed locally.
      const currencies = {
        'usd', 'eur', 'gbp', 'chf', 'jpy', 'cad', 'aud', 'cny', 'inr', 'btc',
      };
      // Everyday currency words (EN + FR) and symbols map to their codes:
      // "dollars", "bucks", "quid", "yen", "100$", "€"…
      const moneyWords = {
        'dollars': 'usd', 'dollar': 'usd', 'bucks': 'usd', 'buck': 'usd',
        'euros': 'eur', 'euro': 'eur',
        'livres': 'gbp', 'livre': 'gbp',
        'pounds': 'gbp', 'pound': 'gbp', 'quids': 'gbp', 'quid': 'gbp',
        'yens': 'jpy', 'yen': 'jpy',
        'francs': 'chf', 'franc': 'chf',
        'yuans': 'cny', 'yuan': 'cny', 'renminbis': 'cny', 'renminbi': 'cny',
        'rupees': 'inr', 'rupee': 'inr',
        'bitcoins': 'btc', 'bitcoin': 'btc',
        '\$': 'usd', '€': 'eur', '£': 'gbp',
      };
      final fromCode =
          moneyWords[from.toLowerCase()] ?? from.toLowerCase();
      final toCode = moneyWords[to.toLowerCase()] ?? to.toLowerCase();
      if (currencies.contains(fromCode) && currencies.contains(toCode)) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Converting $value $fromCode to $toCode…',
            action: AgentActions.currencyGet,
            arguments: {
              'value': value,
              'from': fromCode,
              'to': toCode,
            },
          ),
        );
      }
      final converted = _convertUnit(value, from, to);
      if (converted != null) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            '$value $from = ${_formatNumber(converted)} $to.',
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Converting $value $from to $to...',
          action: AgentActions.webSearch,
          arguments: {'query': 'convert $value $from to $to'},
        ),
      );
    // --- Alarm dismiss / timer status & cancel: system apps own alarms and
    // timers — apps can set them but cannot read or stop them. Say so
    // instead of faking a win.
    case AgentActions.alarmDismiss:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I can set alarms, but I can\'t turn them off from inside the app — open the Clock app to dismiss it.',
        ),
      );
    case AgentActions.timerStatus:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Timers live in your system Clock app, so I can\'t see the time left from here — open the Clock app to check.',
        ),
      );
    case AgentActions.timerCancel:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I can start timers, but I can\'t stop one from inside the app — open the Clock app to cancel it.',
        ),
      );
    case AgentActions.darkModeSet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Dark mode is a system setting — I can\'t switch it from inside the app. Open your display settings to change it.',
        ),
      );
    // --- Fun ---
    case AgentActions.randomDice:
      final result = Random().nextInt(6) + 1;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Rolled a $result!'),
      );
    case AgentActions.randomCoin:
      final result = Random().nextBool() ? 'Heads' : 'Tails';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('$result!'),
      );
    case AgentActions.randomNumber:
      final min = command.arguments['min'] as int? ?? 1;
      final max = command.arguments['max'] as int? ?? 100;
      final result = min + Random().nextInt(max - min + 1);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('$result'),
      );
    case AgentActions.tellJoke:
      const jokes = [
        'Why do programmers prefer dark mode? Because light attracts bugs!',
        'There are 10 types of people in the world: those who understand binary and those who don\'t.',
        'A SQL query walks into a bar, sees two tables and asks... "Can I join you?"',
        'Why was the JavaScript developer sad? Because he didn\'t Node how to Express himself.',
        'What\'s a programmer\'s favorite hangout place? Foo Bar.',
        'Why do Java developers wear glasses? Because they can\'t C#.',
        'How many programmers does it take to change a light bulb? None, that\'s a hardware problem.',
        'What do you call a group of 8 hobbits? A hobbyte.',
        'Why did the developer go broke? Because he used up all his cache.',
        'What do you call a computer that sings? A-Dell.',
      ];
      final joke = jokes[Random().nextInt(jokes.length)];
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(joke),
      );
    // --- Find/ring a paired device. There is no ring/find executor in
    // this release, so the honest answer depends on which real device the
    // noun names — never a silent dead-end, and never a kind quoted back as
    // if it were a name.
    case AgentActions.findDevice:
    case AgentActions.ringDevice:
      return _findOrRingAnswer(command, ctx);
    // --- Airplane mode: needs a system permission, or doesn't exist on a
    // PC. Say which instead of pretending to toggle radios.
    case AgentActions.airplaneModeSet:
      final isPhone = _capabilitiesOf(ctx.local)
          .contains(AgentActions.callPlace);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          isPhone
              ? 'Airplane mode needs a system-level permission Nexus doesn\'t take — swipe down from the top of the screen and tap the airplane toggle.'
              : 'Airplane mode is a phone feature — this device has no radios to switch.',
        ),
      );
    case AgentActions.deviceRestart:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I won\'t restart the device from inside the app — use the power menu.',
        ),
      );
    // --- Memory: facts the user told us about their world. All three
    // answer locally with plain messages — the store is the memory.
    case AgentActions.memoryRemember:
      final text = (command.arguments['text'] as String? ?? '').trim();
      // A bare framing phrase ("remember that") makes the interpreter's
      // regex backtrack into capturing the framing word itself — answer
      // exactly as if nothing was said, never store it.
      if (text.isEmpty ||
          text.toLowerCase() == 'that' ||
          text.toLowerCase() == 'this') {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I remember? Try "remember that my wifi password is nexus".',
        );
      }
      if (ctx.facts.any((f) => f.text.toLowerCase() == text.toLowerCase())) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('I already know that.'),
        );
      }
      // The user said it, here — recorded as such, with this device named as
      // the source, so "why do you know that" can answer with something the
      // user can check rather than a canned line.
      ctx.facts.add(
        MemoryFact(
          text,
          MemoryStamp.now(MemoryOrigin.explicit, ctx.toldOn),
        ),
      );
      ctx.onMemoryChanged?.call();
      ctx.onFactLearned?.call(text);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Remembered: "$text".'),
      );
    case AgentActions.memoryRecall:
      final topic = (command.arguments['topic'] as String? ?? '').trim();
      if (ctx.facts.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t remember anything about you yet. Tell me with "remember that …".',
          ),
        );
      }
      final matches = topic.isEmpty
          ? ctx.facts.toList()
          : _factsAbout(ctx.facts, topic);
      if (matches.isEmpty) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t remember anything about "$topic" yet. Tell me with "remember that …".',
          ),
        );
      }
      _markUsed(ctx, matches, DateTime.now());
      final heading = topic.isEmpty
          ? 'Here is what I know:'
          : 'About "$topic":';
      // Each line says where it came from, in the user's own terms: told here,
      // sent by a device, created by a rule, or genuinely unknown because it
      // was stored before Nexus kept sources.
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          '$heading\n${matches.map((f) => '  • ${f.describe()}').join('\n')}',
        ),
      );
    case AgentActions.memoryQuestion:
      // The payoff of memory: a personal question answered from what the
      // user actually said. Nothing stored? Fall back to the web honestly.
      final qTopic = (command.arguments['topic'] as String? ?? '').trim();
      // "Why do you know that?" — the same question about the same memory,
      // asked about its provenance instead of its content. Answered only from
      // the stored stamp: no canned explanation, and no searching for one.
      if (command.arguments['kind'] == 'provenance') {
        return _provenanceAnswer(ctx, qTopic);
      }
      // "What did you infer?" is the same question about memory asked about
      // conclusions rather than entries, so it is the same capability with a
      // different question — and it reads the stored origins, not a promise.
      if (command.arguments['kind'] == 'inferred') {
        return inferredAnswer(ctx);
      }
      if (qTopic.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What do you want to know? Try "what is my wifi password".',
        );
      }
      final hits = _factsAbout(ctx.facts, qTopic);
      if (hits.isEmpty) {
        // The user already answered our "I don't know that yet" question
        // ("what is my name" -> "John") — the service stored the answer and
        // re-ran this command with it. Answer from that, never the web.
        final told = command.arguments[qTopic];
        if (told is String && told.trim().isNotEmpty) {
          final answer = told.trim();
          return AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage(
              qTopic == 'my name'
                  ? 'Your name is $answer.'
                  : '$qTopic is $answer — I\'ll remember that.',
            ),
          );
        }
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t know that yet — nothing you told me matches "$qTopic". Searching the web instead…',
            action: AgentActions.webSearch,
            arguments: {'query': qTopic},
          ),
        );
      }
      _markUsed(ctx, hits, DateTime.now());
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          // One hit is the answer itself (a password is the password, not a
          // provenance lecture); several are listed with where each came from,
          // so the user can tell their own from a device's.
          hits.length == 1
              ? hits.single.text
              : '${hits.length} things I know match "$qTopic":\n'
                    '${hits.map((f) => '  • ${f.describe()}').join('\n')}',
        ),
      );
    case AgentActions.memoryForget:
      final query = (command.arguments['text'] as String? ?? '').trim();
      // Same backtrack guard as remember: "forget that" must ask what to
      // forget, never delete every fact containing the word "that".
      if (query.isEmpty || query.toLowerCase() == 'that') {
        return const AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          message: 'What should I forget? Try "forget my wifi password".',
        );
      }
      final gone = ctx.facts
          .where((f) => f.text.toLowerCase().contains(query.toLowerCase()))
          .toList();
      if (gone.isEmpty) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('I don\'t remember anything like "$query".'),
        );
      }
      ctx.facts.removeWhere(
        (f) => f.text.toLowerCase().contains(query.toLowerCase()),
      );
      ctx.onMemoryChanged?.call();
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          gone.length == 1
              ? 'Forgotten: "${gone.single.text}".'
              : 'Forgotten ${gone.length} things.',
        ),
      );
    default:
      return const AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'This command is not available yet.',
      );
  }
}

String _formatTime(Object? kind) {
  final now = DateTime.now();
  if (kind == 'date') {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return 'It\'s ${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year}.';
  }
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  return 'It\'s $hh:$mm.';
}

String _formatNumber(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

/// Inline unit conversion for the units Siri converts without the web:
/// lengths, weights, temperatures, speeds. Returns null when the pair is
/// not known — the caller falls back to a web search, never a fake number.
double? _convertUnit(double value, String from, String to) {
  final f = from.trim().toLowerCase();
  final t = to.trim().toLowerCase();
  double? toBase(String unit) {
    // Length → meters
    switch (unit) {
      case 'km' || 'kilometer' || 'kilometers':
        return value * 1000;
      case 'm' || 'meter' || 'meters':
        return value;
      case 'cm' || 'centimeter' || 'centimeters':
        return value / 100;
      case 'mm' || 'millimeter' || 'millimeters':
        return value / 1000;
      case 'mile' || 'miles' || 'mi':
        return value * 1609.344;
      case 'yard' || 'yards' || 'yd':
        return value * 0.9144;
      case 'foot' || 'feet' || 'ft':
        return value * 0.3048;
      case 'inch' || 'inches' || 'in':
        return value * 0.0254;
      // Weight → kilograms
      case 'kg' || 'kilogram' || 'kilograms':
        return value;
      case 'g' || 'gram' || 'grams':
        return value / 1000;
      case 'mg' || 'milligram' || 'milligrams':
        return value / 1e6;
      case 'lb' || 'lbs' || 'pound' || 'pounds':
        return value * 0.45359237;
      case 'ounce' || 'ounces' || 'oz':
        return value * 0.028349523;
      case 'stone' || 'stones':
        return value * 6.35029318;
      // Temperature → celsius
      case 'c' || 'celsius':
        return value;
      case 'f' || 'fahrenheit':
        return (value - 32) * 5 / 9;
      case 'k' || 'kelvin':
        return value - 273.15;
      // Speed → km/h
      case 'kmh' || 'kph' || 'km/h':
        return value;
      case 'mph':
        return value * 1.609344;
      default:
        return null;
    }
  }

  double? fromBase(double v, String unit) {
    switch (unit) {
      case 'km' || 'kilometer' || 'kilometers':
        return v / 1000;
      case 'm' || 'meter' || 'meters':
        return v;
      case 'cm' || 'centimeter' || 'centimeters':
        return v * 100;
      case 'mm' || 'millimeter' || 'millimeters':
        return v * 1000;
      case 'mile' || 'miles' || 'mi':
        return v / 1609.344;
      case 'yard' || 'yards' || 'yd':
        return v / 0.9144;
      case 'foot' || 'feet' || 'ft':
        return v / 0.3048;
      case 'inch' || 'inches' || 'in':
        return v / 0.0254;
      case 'kg' || 'kilogram' || 'kilograms':
        return v;
      case 'g' || 'gram' || 'grams':
        return v * 1000;
      case 'mg' || 'milligram' || 'milligrams':
        return v * 1e6;
      case 'lb' || 'lbs' || 'pound' || 'pounds':
        return v / 0.45359237;
      case 'ounce' || 'ounces' || 'oz':
        return v / 0.028349523;
      case 'stone' || 'stones':
        return v / 6.35029318;
      case 'c' || 'celsius':
        return v;
      case 'f' || 'fahrenheit':
        return v * 9 / 5 + 32;
      case 'k' || 'kelvin':
        return v + 273.15;
      case 'kmh' || 'kph' || 'km/h':
        return v;
      case 'mph':
        return v / 1.609344;
      default:
        return null;
    }
  }

  final base = toBase(f);
  if (base == null) return null;
  final out = fromBase(base, t);
  if (out == null) return null;
  // Rounding to 4 significant decimals keeps answers clean and honest.
  return double.parse(out.toStringAsPrecision(6));
}

/// "8:00pm" / "6:05am" — how the reminder echo says when it fires.
String _clockLabel(DateTime t) {
  final hh = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mm = t.minute.toString().padLeft(2, '0');
  final meridiem = t.hour < 12 ? 'am' : 'pm';
  return '$hh:$mm$meridiem';
}

/// Safely evaluates a small arithmetic expression: numbers, `+ - * /` and
/// parentheses. Returns null for anything invalid (empty, bad tokens, or
/// division by zero). No dynamic code is ever executed.
double? evaluateMath(String expr) {
  final clean = expr.trim();
  if (clean.isEmpty || RegExp(r'[^0-9+\-*/(). ]').hasMatch(clean)) return null;
  final tokens = RegExp(r'\d+(\.\d+)?|[()+\-*/]')
      .allMatches(clean)
      .map((m) => m.group(0)!)
      .toList();
  final values = <double>[];
  final ops = <String>[];

  int precedence(String op) => op == '+' || op == '-' ? 1 : 2;

  bool apply() {
    if (values.length < 2 || ops.isEmpty) return false;
    final b = values.removeLast();
    final a = values.removeLast();
    final op = ops.removeLast();
    switch (op) {
      case '+':
        values.add(a + b);
      case '-':
        values.add(a - b);
      case '*':
        values.add(a * b);
      case '/':
        if (b == 0) return false;
        values.add(a / b);
    }
    return true;
  }

  for (final token in tokens) {
    if (RegExp(r'^\d').hasMatch(token)) {
      values.add(double.parse(token));
      continue;
    }
    if (token == '(') {
      ops.add(token);
      continue;
    }
    if (token == ')') {
      while (ops.isNotEmpty && ops.last != '(') {
        if (!apply()) return null;
      }
      if (ops.isEmpty) return null;
      ops.removeLast();
      continue;
    }
    while (ops.isNotEmpty &&
        ops.last != '(' &&
        precedence(ops.last) >= precedence(token)) {
      if (!apply()) return null;
    }
    ops.add(token);
  }
  while (ops.isNotEmpty) {
    if (!apply()) return null;
  }
  return values.length == 1 && ops.isEmpty ? values.single : null;
}
