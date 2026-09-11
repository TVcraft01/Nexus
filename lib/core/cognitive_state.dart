import 'dart:convert';

/// A single durable memory formed from experience. Memories are deliberately
/// plain data: the learning policy decides when to create, strengthen, or
/// forget them.
class CognitiveMemory {
  final String id;
  final String content;
  final String kind;
  final double importance;
  final int strength;
  final DateTime createdAt;
  final DateTime lastSeen;

  const CognitiveMemory({
    required this.id,
    required this.content,
    required this.kind,
    required this.importance,
    required this.strength,
    required this.createdAt,
    required this.lastSeen,
  });

  CognitiveMemory reinforce({DateTime? at, double importanceBoost = 0.0}) =>
      CognitiveMemory(
        id: id,
        content: content,
        kind: kind,
        importance: (importance + importanceBoost).clamp(0.0, 1.0),
        strength: strength + 1,
        createdAt: createdAt,
        lastSeen: at ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'kind': kind,
        'importance': importance,
        'strength': strength,
        'createdAt': createdAt.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory CognitiveMemory.fromJson(Map<String, dynamic> json) =>
      CognitiveMemory(
        id: json['id']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'experience',
        importance: (json['importance'] as num?)?.toDouble() ?? 0.5,
        strength: (json['strength'] as num?)?.toInt() ?? 1,
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        lastSeen: DateTime.tryParse(json['lastSeen']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// Learned communication behavior for one person. The model is intentionally
/// separate from the language model: it can evolve without retraining it.
class SocialProfile {
  final String personId;
  final String? name;
  final Map<String, double> style;
  final Map<String, int> vocabulary;
  final DateTime lastSeen;

  const SocialProfile({
    required this.personId,
    this.name,
    this.style = const {},
    this.vocabulary = const {},
    required this.lastSeen,
  });

  SocialProfile observeWords(Iterable<String> words, {DateTime? at}) {
    final next = Map<String, int>.from(vocabulary);
    for (final word in words) {
      final normalized = word.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      next[normalized] = (next[normalized] ?? 0) + 1;
    }
    return SocialProfile(
      personId: personId,
      name: name,
      style: style,
      vocabulary: next,
      lastSeen: at ?? DateTime.now(),
    );
  }

  SocialProfile withStyle(String key, double value, {DateTime? at}) {
    final next = Map<String, double>.from(style);
    next[key] = value.clamp(0.0, 1.0);
    return SocialProfile(
      personId: personId,
      name: name,
      style: next,
      vocabulary: vocabulary,
      lastSeen: at ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'personId': personId,
        'name': name,
        'style': style,
        'vocabulary': vocabulary,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory SocialProfile.fromJson(Map<String, dynamic> json) => SocialProfile(
        personId: json['personId']?.toString() ?? '',
        name: json['name']?.toString(),
        style: {
          for (final e in (json['style'] as Map? ?? const {}).entries)
            e.key.toString(): (e.value as num).toDouble(),
        },
        vocabulary: {
          for (final e in (json['vocabulary'] as Map? ?? const {}).entries)
            e.key.toString(): (e.value as num).toInt(),
        },
        lastSeen: DateTime.tryParse(json['lastSeen']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// A capability advertised by Nexus itself or by a connected device.
class NexusCapability {
  final String id;
  final String description;
  final String providerId;
  final bool available;
  final Map<String, dynamic> metadata;

  const NexusCapability({
    required this.id,
    required this.description,
    required this.providerId,
    required this.available,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'providerId': providerId,
        'available': available,
        'metadata': metadata,
      };

  factory NexusCapability.fromJson(Map<String, dynamic> json) =>
      NexusCapability(
        id: json['id']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        providerId: json['providerId']?.toString() ?? '',
        available: json['available'] as bool? ?? false,
        metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
      );
}

/// The durable identity/state of the cognitive layer. This is the part that
/// survives a restart and can be synced later; it is not the model weights.
class CognitiveState {
  final List<CognitiveMemory> memories;
  final Map<String, SocialProfile> people;
  final Map<String, NexusCapability> capabilities;
  final Map<String, int> habits;
  final DateTime? lastConsolidatedAt;

  const CognitiveState({
    this.memories = const [],
    this.people = const {},
    this.capabilities = const {},
    this.habits = const {},
    this.lastConsolidatedAt,
  });

  CognitiveState copyWith({
    List<CognitiveMemory>? memories,
    Map<String, SocialProfile>? people,
    Map<String, NexusCapability>? capabilities,
    Map<String, int>? habits,
    DateTime? lastConsolidatedAt,
  }) =>
      CognitiveState(
        memories: memories ?? this.memories,
        people: people ?? this.people,
        capabilities: capabilities ?? this.capabilities,
        habits: habits ?? this.habits,
        lastConsolidatedAt: lastConsolidatedAt ?? this.lastConsolidatedAt,
      );

  Map<String, dynamic> toJson() => {
        'memories': [for (final m in memories) m.toJson()],
        'people': {
          for (final e in people.entries) e.key: e.value.toJson(),
        },
        'capabilities': {
          for (final e in capabilities.entries) e.key: e.value.toJson(),
        },
        'habits': habits,
        'lastConsolidatedAt': lastConsolidatedAt?.toIso8601String(),
      };

  String encode() => jsonEncode(toJson());

  factory CognitiveState.fromJson(Map<String, dynamic> json) => CognitiveState(
        memories: [
          for (final raw in (json['memories'] as List? ?? const []))
            if (raw is Map) CognitiveMemory.fromJson(
              Map<String, dynamic>.from(raw),
            ),
        ],
        people: {
          for (final raw in (json['people'] as Map? ?? const {}).entries)
            raw.key.toString(): SocialProfile.fromJson(
              Map<String, dynamic>.from(raw.value as Map),
            ),
        },
        capabilities: {
          for (final raw in (json['capabilities'] as Map? ?? const {}).entries)
            raw.key.toString(): NexusCapability.fromJson(
              Map<String, dynamic>.from(raw.value as Map),
            ),
        },
        habits: {
          for (final raw in (json['habits'] as Map? ?? const {}).entries)
            raw.key.toString(): (raw.value as num).toInt(),
        },
        lastConsolidatedAt: DateTime.tryParse(
          json['lastConsolidatedAt']?.toString() ?? '',
        ),
      );

  factory CognitiveState.decode(String source) =>
      CognitiveState.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
