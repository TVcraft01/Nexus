// What Nexus remembers about its person — and where each thing came from.
//
// Memory used to be bare text: facts were a `List<String>`, taught phrases
// and remembered preferences were maps of string to string with nothing
// beside them. So the one question the brief calls essential — "why do you
// know that?" — had no answer at all, and a fact a phone sent over the mesh
// was indistinguishable from one the user typed. Anything Nexus said about
// its own memory would have been invented.
//
// This file is the owner of provenance. Every remembered thing carries a
// [MemoryStamp]: where it came from ([MemoryOrigin]), the specific source in
// the user's terms, when it was learned, and when it was last used.
//
// Two rules the model enforces rather than documents:
//
//  * a stamp cannot exist without an origin and a source, and cannot be
//    decoded from a stored entry that has none — so an origin-less fact
//    cannot enter the app at all;
//  * an entry that was stored before provenance existed is not given a
//    guessed origin. It is [MemoryOrigin.legacy] and the wording admits it,
//    because claiming "you told me this" for something a device sent would
//    be presenting a guess as a fact, which is the exact failure this pass
//    exists to remove.
//
// [MemoryOrigin.inferred] is declared because the brief names it and because
// the wording for it must exist before anything can create one — but nothing
// in Nexus derives a fact from behaviour today, so no code path constructs
// it, an inference may not be created without naming what it was inferred
// from, and its wording says "I inferred this" rather than asserting it.
/// Where a remembered thing came from.
enum MemoryOrigin {
  /// The user said it, on this device.
  explicit,

  /// A paired device sent it over the mesh.
  device,

  /// Nexus created it from a rule of its own (a confirmed "did you mean"
  /// answer became a contact alias).
  system,

  /// Stored before Nexus recorded origins. The origin is genuinely unknown —
  /// the wording says so instead of guessing.
  legacy,

  /// Inferred from the user's behaviour. Nothing constructs this yet.
  inferred,
}

/// How an origin is spoken to the user, always with its source. Kept beside
/// the enum, like the result-status wording, so the sentence about where
/// something came from has one owner and cannot drift between the recall
/// list and the "why do you know that" answer.
extension MemoryOriginWording on MemoryOrigin {
  /// The short name, for a compact list.
  String get label => switch (this) {
    MemoryOrigin.explicit => 'you told me',
    MemoryOrigin.device => 'from a device',
    MemoryOrigin.system => 'Nexus created it',
    MemoryOrigin.legacy => 'source unknown',
    MemoryOrigin.inferred => 'inferred',
  };

  /// The full honest sentence for one entry, naming the recorded [source].
  String sentence(String source) {
    final where = source.trim();
    return switch (this) {
      MemoryOrigin.explicit =>
        where.isEmpty ? 'you told me this' : 'you told me this on $where',
      MemoryOrigin.device =>
        where.isEmpty ? 'this came from a paired device' : 'this came from $where',
      MemoryOrigin.system =>
        where.isEmpty ? 'I created this from your own answer' : 'I created this when $where',
      // Stated as a limit, not as an answer: the entry itself is real, its
      // origin is not known, and saying so is the only honest option.
      MemoryOrigin.legacy =>
        'this was stored before I kept sources, so I don\'t know where it came '
            'from',
      // Never stated as a fact: an inference is reported as an inference.
      MemoryOrigin.inferred =>
        where.isEmpty
            ? 'I inferred this from how you use Nexus'
            : 'I inferred this from $where',
    };
  }
}

/// Where one remembered thing came from, when, and when it was last used.
///
/// [learnedAt] is null only for an entry migrated from a version that did not
/// record it — a new entry must carry a time, so the timestamp cannot be
/// silently absent.
class MemoryStamp {
  final MemoryOrigin origin;

  /// The specific source, in the user's terms: the device it was said on, the
  /// peer that sent it, or the rule that created it. Never empty.
  final String source;

  final DateTime? learnedAt;

  /// The last time this entry was used to answer something. Null until it is
  /// used, and never rewritten twice in a day (see [usedAt]) so a question
  /// does not become a write per keystroke.
  final DateTime? lastUsedAt;

  /// What an inference was drawn from. Required for [MemoryOrigin.inferred],
  /// so an inference can never be recorded without its basis.
  final String? inferredFrom;

  MemoryStamp({
    required this.origin,
    required this.source,
    required this.learnedAt,
    this.lastUsedAt,
    this.inferredFrom,
  }) {
    if (source.trim().isEmpty) {
      throw ArgumentError(
        'a remembered thing must name its source; got an empty one',
      );
    }
    if (origin != MemoryOrigin.legacy && learnedAt == null) {
      throw ArgumentError(
        'a new $origin entry must carry the time it was learned',
      );
    }
    if (origin == MemoryOrigin.inferred &&
        (inferredFrom ?? '').trim().isEmpty) {
      throw ArgumentError(
        'an inference must name what it was inferred from',
      );
    }
  }

  /// A stamp for something learned now.
  factory MemoryStamp.now(
    MemoryOrigin origin,
    String source, {
    DateTime? at,
  }) => MemoryStamp(
    origin: origin,
    source: source,
    learnedAt: at ?? DateTime.now(),
  );

  /// The stamp for an entry stored before origins were recorded. Only
  /// migration may create one, which is what keeps it from becoming a
  /// convenient default for new code.
  factory MemoryStamp.legacy() => MemoryStamp(
    origin: MemoryOrigin.legacy,
    source: 'stored before Nexus kept sources',
    learnedAt: null,
  );

  /// This stamp, marked used at [at]. Returns itself when it was already used
  /// the same day, so repeating a question does not rewrite the store.
  MemoryStamp usedAt(DateTime at) {
    final used = lastUsedAt;
    if (used != null &&
        used.year == at.year &&
        used.month == at.month &&
        used.day == at.day) {
      return this;
    }
    return MemoryStamp(
      origin: origin,
      source: source,
      learnedAt: learnedAt,
      lastUsedAt: at,
      inferredFrom: inferredFrom,
    );
  }

  Map<String, dynamic> toJson() => {
    'origin': origin.name,
    'source': source,
    if (learnedAt != null) 'learnedAt': learnedAt!.toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
    if (inferredFrom != null) 'inferredFrom': inferredFrom,
  };

  /// Reads a stored stamp, refusing one that does not say where it came from.
  /// An unknown origin code is refused too: a store written by a newer Nexus
  /// must not have its entries read as something they are not.
  factory MemoryStamp.fromJson(Map<String, dynamic> json) {
    final raw = (json['origin'] as String?)?.trim() ?? '';
    if (raw.isEmpty) {
      throw const FormatException(
        'a remembered thing encoded without an origin is refused',
      );
    }
    final origin = MemoryOrigin.values.where((o) => o.name == raw).firstOrNull;
    if (origin == null) {
      throw FormatException('unknown memory origin "$raw"');
    }
    final source = (json['source'] as String?)?.trim() ?? '';
    if (source.isEmpty) {
      throw const FormatException(
        'a remembered thing encoded without a source is refused',
      );
    }
    DateTime? when(Object? value) {
      final text = value as String?;
      return text == null ? null : DateTime.tryParse(text);
    }

    return MemoryStamp(
      origin: origin,
      source: source,
      learnedAt: when(json['learnedAt']),
      lastUsedAt: when(json['lastUsedAt']),
      inferredFrom: (json['inferredFrom'] as String?)?.trim(),
    );
  }

  /// "today" / "yesterday" / "5 days ago" / the date — enough to be useful,
  /// never a false precision. An entry with no recorded time says so.
  static String describeWhen(DateTime? at, DateTime now) {
    if (at == null) return 'I don\'t know when';
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(at.year, at.month, at.day)).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 30) return '$days days ago';
    final months = (days / 30).floor();
    if (months < 12) return months == 1 ? 'a month ago' : '$months months ago';
    final years = (days / 365).floor();
    return years <= 1 ? 'a year ago' : '$years years ago';
  }
}

/// One thing the user told Nexus about their world, with its provenance.
///
/// Construction requires both, and [fromJson] refuses an encoded entry that
/// has no origin — that refusal is the "data model refuses a fact that has no
/// origin" rule, enforced rather than documented.
class MemoryFact {
  final String text;
  final MemoryStamp stamp;

  MemoryFact(this.text, this.stamp) {
    if (text.trim().isEmpty) {
      throw ArgumentError('a remembered fact must have text');
    }
  }

  /// What the user sees.
  String get sentence => stamp.origin.sentence(stamp.source);

  /// The recall line: the fact, and where it came from.
  String describe() => '$text — $sentence';

  /// The full account "why do you know that" answers with: where it came
  /// from, when it was learned, and when it was last used. Every part comes
  /// from the stored stamp, and the parts that are unknown are left out
  /// rather than guessed.
  String explain(DateTime now) {
    final when = stamp.learnedAt == null
        ? ''
        : ' I learned it ${MemoryStamp.describeWhen(stamp.learnedAt, now)}.';
    final used = stamp.lastUsedAt == null
        ? ''
        : ' Last used ${MemoryStamp.describeWhen(stamp.lastUsedAt, now)}.';
    return '"$text" — $sentence.$when$used';
  }

  MemoryFact usedAt(DateTime at) {
    final marked = stamp.usedAt(at);
    return identical(marked, stamp) ? this : MemoryFact(text, marked);
  }

  Map<String, dynamic> toJson() => {'text': text, 'stamp': stamp.toJson()};

  /// Reads one stored fact. The old format was a bare string, and those
  /// entries become [MemoryOrigin.legacy] — the only way a legacy stamp is
  /// ever created. A map without an origin is refused.
  factory MemoryFact.fromJson(Object? raw) {
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) throw const FormatException('empty stored fact');
      return MemoryFact(text, MemoryStamp.legacy());
    }
    if (raw is Map) {
      final json = Map<String, dynamic>.from(raw);
      final text = (json['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        throw const FormatException('a stored fact with no text is refused');
      }
      final stamp = json['stamp'];
      if (stamp is! Map) {
        throw const FormatException(
          'a stored fact with no origin is refused',
        );
      }
      return MemoryFact(text, MemoryStamp.fromJson(Map<String, dynamic>.from(stamp)));
    }
    throw FormatException('unreadable stored fact: ${raw.runtimeType}');
  }

  @override
  String toString() => 'MemoryFact($text, ${stamp.origin.name})';
}

/// The kinds of learned entry whose provenance is kept in a [MemoryLedger],
/// beside the maps that hold their values. Facts carry their own stamp, so
/// they are not here.
enum MemoryLedgerKind {
  /// A phrase the user taught the assistant ("bring me home" → "show my
  /// devices").
  phrase,

  /// An answer to a "which …?" question, remembered as a preference.
  preference,
}

/// Provenance for the learned entries that are stored as value maps: taught
/// phrases and remembered preferences.
///
/// It is a ledger keyed by kind and key rather than a new shape for the maps
/// themselves, so the hot lookups (`_learned[normalized]`, `_defaults[key]`)
/// and the brain prompt keep working unchanged while every entry still says
/// where it came from. [stampFor] is the one way to read provenance: it answers
/// "source unknown" honestly for an entry the ledger never saw, instead of
/// returning nothing the caller would have to invent around.
class MemoryLedger {
  /// The stamps by ledger key. Immutable, and small by nature — one record
  /// per taught phrase and remembered preference — so every write below
  /// returns a new ledger. That is deliberate: a shared mutable map invites
  /// the same provenance to be mutated by two owners, and this value is
  /// copied into the store, the service and the answer context.
  final Map<String, MemoryStamp> _stamps;

  const MemoryLedger([this._stamps = const {}]);

  /// A ledger holding copies of [stamps], so a caller cannot mutate theirs
  /// through this one.
  factory MemoryLedger.of(Map<String, MemoryStamp> stamps) =>
      MemoryLedger(Map.of(stamps));

  static String _key(MemoryLedgerKind kind, String key) =>
      '${kind.name}\u0001$key';

  /// This ledger with [key]'s provenance set to [stamp]. Replaces any earlier
  /// stamp — the latest fact about where something came from is the true one.
  MemoryLedger record(MemoryLedgerKind kind, String key, MemoryStamp stamp) {
    if (key.trim().isEmpty) {
      throw ArgumentError('a learned entry must have a key');
    }
    return MemoryLedger({..._stamps, _key(kind, key): stamp});
  }

  /// Where [key] came from, or a legacy stamp when the ledger has no record:
  /// an entry that predates provenance is genuinely unknown, and this is the
  /// only honest thing to answer rather than nothing.
  MemoryStamp stampFor(MemoryLedgerKind kind, String key) =>
      _stamps[_key(kind, key)] ?? MemoryStamp.legacy();

  /// Whether this ledger has a record for [key] at all — the difference
  /// between a stored source and [stampFor]'s honest fallback.
  bool knows(MemoryLedgerKind kind, String key) =>
      _stamps.containsKey(_key(kind, key));

  /// Fills in a legacy stamp for [key] when nothing is recorded for it. The
  /// migration path, and the only caller: the store seeds one for every
  /// taught phrase and remembered preference it holds, so an entry written
  /// before provenance existed still answers with an honest "I don't know
  /// where this came from" instead of having no origin at all.
  MemoryLedger seedLegacy(MemoryLedgerKind kind, String key) {
    if (key.trim().isEmpty) return this;
    final k = _key(kind, key);
    if (_stamps.containsKey(k)) return this;
    return MemoryLedger({..._stamps, k: MemoryStamp.legacy()});
  }

  /// Marks an entry used, at day granularity (see [MemoryStamp.usedAt]).
  /// Every stamp by ledger key, for copying a ledger verbatim.
  Map<String, MemoryStamp> get stampMap => Map.unmodifiable(_stamps);

  /// Every entry that has a stamp, for persistence.
  List<Map<String, dynamic>> toJson() => [
    for (final entry in _stamps.entries)
      if (_keyParts(entry.key) case (final kind, final key)?)
        {'kind': kind, 'key': key, ...entry.value.toJson()},
  ];

  /// The kind and key in a ledger key, or null for a malformed one. A
  /// malformed key is dropped on write rather than crashing a save.
  static (String, String)? _keyParts(String raw) {
    final at = raw.indexOf('\u0001');
    if (at <= 0 || at == raw.length - 1) return null;
    return (raw.substring(0, at), raw.substring(at + 1));
  }

  /// Reads stored provenance, refusing any record that does not say where it
  /// came from. A record that cannot be applied (unknown kind) is skipped —
  /// provenance for a kind this version does not have is not worth failing a
  /// whole load over, and skipping it cannot invent an origin.
  factory MemoryLedger.fromJson(Object? raw) {
    var ledger = const MemoryLedger();
    if (raw is! List) return ledger;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final json = Map<String, dynamic>.from(entry);
      final kindName = (json['kind'] as String?)?.trim() ?? '';
      final key = (json['key'] as String?)?.trim() ?? '';
      final kind = MemoryLedgerKind.values
          .where((k) => k.name == kindName)
          .firstOrNull;
      if (kind == null || key.isEmpty) continue;
      ledger = ledger.record(kind, key, MemoryStamp.fromJson(json));
    }
    return ledger;
  }

  @override
  String toString() => 'MemoryLedger(${_stamps.length} entries)';
}


