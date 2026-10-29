part of 'mesh_service.dart';

/// Sync: the knowledge a paired device shares — a taught phrase, a fact, a
/// reminder, a "which …?" answer, a renamed profile — sent by the device
/// that learned it and adopted here without an approval gate.
///
/// Split out of `mesh_service.dart` without touching the code. The live
/// callbacks the assistant wires in and the handlers that answer them now
/// live side by side, which is the point: one concern, one file.
mixin _MeshSync on _MeshBase {
  /// Fired when a paired device teaches a phrase and syncs it here. The view
  /// wires this into the live [CommandService] so the learned meaning is
  /// usable immediately, not only after a restart. Receivers never re-broadcast
  /// — that would loop the mesh forever.
  /// [from] names the peer that sent it, so the memory keeps a real source
  /// ("this came from TVcraft's phone") instead of a vague "a device".
  void Function(String phrase, String meaning, [String from])?
  onLearnedPhraseReceived;

  /// Fired when a paired device tells the assistant a fact and syncs it here.
  /// The view wires this into the live [CommandService] so the fact is usable
  /// immediately. Receivers never re-broadcast — that would loop the mesh.
  ///
  /// Ownership rule: inbound knowledge is persisted by whoever claims it. When
  /// this (or [onLearnedPhraseReceived]) is attached, the mesh only delivers
  /// and the live assistant's own persistence funnel writes the store — never
  /// both. When nobody is listening (startup window, headless mesh), the mesh
  /// writes the store itself so the knowledge survives for the next boot.
  void Function(String fact, [String from])? onFactReceived;

  /// Fired when a paired device sets a reminder and syncs it here, so the
  /// assistant on THIS device reminds the user too — whoever they are near.
  /// Same ownership rule as [onFactReceived]: with a listener attached, the
  /// live assistant's own funnel writes the store; otherwise the mesh
  /// persists the reminder itself so it survives for the next boot.
  void Function(String line)? onReminderReceived;

  /// Fired when a paired device answers a "which …?" question and syncs the
  /// remembered default here. Same ownership rule as [onFactReceived]: with
  /// a listener attached, the live assistant's own funnel writes the store;
  /// otherwise the mesh persists it so it survives for the next boot.
  void Function(String key, dynamic value, [String from])? onDefaultReceived;

  /// Fired when a paired device renames the user or the assistant and syncs
  /// the profile here, so every device answers as one person. Same
  /// ownership rule as [onFactReceived].
  void Function(String? userName, String? assistantName)? onProfileReceived;

  /// Tells every paired device that the user taught [phrase] to mean
  /// [meaning] (e.g. "call tvcraft" -> "call TVcraft01 〘✘ΔτΚ⑤⑦〙"), so one
  /// teaching works on all of them. Fire-and-forget: a peer that is offline
  /// simply misses this one — the phrase stays local until the next teach.
  Future<void> broadcastLearnedPhrase(String phrase, String meaning) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentLearned,
            from: identity.id,
            to: peer.id,
            payload: {'phrase': phrase, 'meaning': meaning},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device a fact the user just told the assistant
  /// ("remember that …"), so one telling is known on all of them.
  /// Fire-and-forget, like [broadcastLearnedPhrase]: a peer that is offline
  /// misses this one until the next telling.
  Future<void> broadcastFact(String fact) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentFact,
            from: identity.id,
            to: peer.id,
            payload: {'text': fact},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device a "which …?" answer the user just picked
  /// (e.g. timer length -> "5 minutes"), so one answer works on all of
  /// them. Fire-and-forget, like [broadcastFact].
  Future<void> broadcastDefault(String key, dynamic value) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentDefault,
            from: identity.id,
            to: peer.id,
            payload: {'key': key, 'value': value},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device the user's and the assistant's names after a
  /// rename ("call me sam", first-run setup), so every device knows the
  /// person. Fire-and-forget, like [broadcastFact].
  Future<void> broadcastProfile({
    String? userName,
    String? assistantName,
  }) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentProfile,
            from: identity.id,
            to: peer.id,
            payload: {'userName': userName, 'assistantName': assistantName},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device about a reminder the user just set, so it
  /// fires on whichever device they are near. Fire-and-forget: a peer that
  /// is offline misses this one until the next setting.
  Future<void> broadcastReminder(String line) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentReminder,
            from: identity.id,
            to: peer.id,
            payload: {'reminder': line},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// A paired device taught a phrase. Knowledge, not an action — adopted
  /// without an approval gate; a local correction wins, and nothing is
  /// re-broadcast or the mesh would loop.
  @override
  Future<void> _handleSyncedLearned(NexusMessage msg) async {
    // A paired device taught a phrase — adopt it silently (it is
    // knowledge, not an action, so no approval gate). The phrase arrives
    // already normalized by the sender; a local correction wins over an
    // incoming one, and we never re-broadcast (that would loop forever).
    final rawPhrase = msg.payload['phrase'];
    final rawMeaning = msg.payload['meaning'];
    final phrase = CommandInterpreter.normalizePhrase(
      rawPhrase?.toString() ?? '',
    );
    final meaning = rawMeaning?.toString().trim().toLowerCase();
    if (phrase.isEmpty || meaning == null || meaning.isEmpty) {
      return;
    }
    final existing = store.agentLearned[phrase];
    if (existing != null && existing != meaning) {
      QueryLog.i.synced(phrase, meaning, from: msg.from, conflict: true);
      return;
    }
    // Who taught it, in the user's terms: the paired device's name when
    // this device knows it, its id otherwise. Recorded either way, so the
    // memory never carries a phrase with no source.
    final learnedFrom = _paired[msg.from]?.name ?? msg.from;
    // No live assistant to claim this phrase — persist it ourselves so it
    // survives until one starts. With a live listener, the assistant's own
    // persistence funnel owns the write (see [onLearnedPhraseReceived]).
    if (onLearnedPhraseReceived == null) {
      store.agentLearned = {...store.agentLearned, phrase: meaning};
      store.agentLedger = store.agentLedger.record(
        MemoryLedgerKind.phrase,
        phrase,
        MemoryStamp.now(MemoryOrigin.device, learnedFrom),
      );
      _queueSave();
    }
    QueryLog.i.synced(phrase, meaning, from: msg.from);
    onLearnedPhraseReceived?.call(phrase, meaning, learnedFrom);
    notifyListeners();
  }

  /// A paired device told the assistant a fact. Same ownership rule as the
  /// learned phrase: one writer, no loop.
  @override
  Future<void> _handleSyncedFact(NexusMessage msg) async {
    // A paired device told the assistant a fact — adopt it silently
    // (knowledge, not an action, so no approval gate). Duplicates are
    // dropped; we never re-broadcast (that would loop forever).
    final text = msg.payload['text']?.toString().trim() ?? '';
    if (text.isEmpty) return;
    if (store.agentFacts.any(
      (f) => f.text.toLowerCase() == text.toLowerCase(),
    )) {
      QueryLog.i.syncedFact(text, from: msg.from, conflict: true);
      return;
    }
    final toldBy = _paired[msg.from]?.name ?? msg.from;
    // No live assistant to claim this fact — persist it ourselves so it
    // survives until one starts. With a live listener, the assistant's own
    // persistence funnel owns the write (see [onFactReceived]).
    if (onFactReceived == null) {
      store.agentFacts = [
        ...store.agentFacts,
        MemoryFact(text, MemoryStamp.now(MemoryOrigin.device, toldBy)),
      ];
      _queueSave();
    }
    QueryLog.i.syncedFact(text, from: msg.from);
    onFactReceived?.call(text, toldBy);
    notifyListeners();
  }

  /// A paired device set a reminder, so this device reminds the user too.
  @override
  Future<void> _handleSyncedReminder(NexusMessage msg) async {
    // A paired device set a reminder — adopt it silently (knowledge,
    // not an action, so no approval gate). Duplicates are dropped; we
    // never re-broadcast (that would loop forever).
    final line = msg.payload['reminder']?.toString().trim() ?? '';
    if (line.isEmpty) return;
    if (store.agentReminders.contains(line)) return;
    // No live assistant: persist it ourselves so it fires later.
    if (onReminderReceived == null) {
      store.agentReminders = [...store.agentReminders, line];
      _queueSave();
    }
    onReminderReceived?.call(line);
    notifyListeners();
  }

  /// A paired device remembered a "which …?" answer. A local answer wins.
  @override
  Future<void> _handleSyncedDefault(NexusMessage msg) async {
    // A paired device remembered a "which …?" answer — adopt it
    // silently (knowledge, not an action). A local answer wins over an
    // incoming one; we never re-broadcast (that would loop forever).
    final key = msg.payload['key']?.toString().trim() ?? '';
    final value = msg.payload['value'];
    if (key.isEmpty || value == null) return;
    if (store.agentDefaults.containsKey(key)) return;
    // No live assistant: persist it ourselves so it survives.
    final answeredOn = _paired[msg.from]?.name ?? msg.from;
    if (onDefaultReceived == null) {
      store.agentDefaults = {...store.agentDefaults, key: value};
      store.agentLedger = store.agentLedger.record(
        MemoryLedgerKind.preference,
        key,
        MemoryStamp.now(MemoryOrigin.device, answeredOn),
      );
      _queueSave();
    }
    onDefaultReceived?.call(key, value, answeredOn);
    notifyListeners();
  }

  /// A paired device renamed the user or the assistant. Last write wins, per
  /// field; an absent field means no information, never erase.
  @override
  Future<void> _handleSyncedProfile(NexusMessage msg) async {
    // A paired device renamed the user or the assistant — adopt it
    // silently (knowledge, not an action); last write wins, per field.
    // Each name travels independently: a rename can legitimately carry a
    // null userName (the user never set their own name), and an absent
    // field means "no information" — never "erase".
    final userName = msg.payload['userName']?.toString().trim();
    final assistantName = msg.payload['assistantName']?.toString().trim();
    final hasUser = userName != null && userName.isNotEmpty;
    final hasAssistant = assistantName != null && assistantName.isNotEmpty;
    if (!hasUser && !hasAssistant) return;
    // No live assistant: persist it ourselves so it survives.
    if (onProfileReceived == null) {
      if (hasUser) store.profileUserName = userName;
      if (hasAssistant) store.profileAssistantName = assistantName;
      _queueSave();
    }
    onProfileReceived?.call(
      hasUser ? userName : null,
      hasAssistant ? assistantName : null,
    );
    notifyListeners();
  }

}
