part of 'mesh_service.dart';

/// Relay: how a message crosses from one device to another — the frame
/// dispatcher, the agent/brain request plumbing that carries a question to
/// a peer and its answer back, and the multi-hop path to a serial node on
/// someone else's cable.
///
/// Split out of `mesh_service.dart` without touching the code. The state
/// that belongs to a request in flight lives here with it; the sockets,
/// keys and peers it rides on stay shared on [_MeshBase].
mixin _MeshRelay on _MeshBase {
  final Map<String, String> _serialRequesters =
      {}; // serialId -> last peer to ask

  /// An action request that arrived from another device over the mesh:
  /// `{'from': peerId, 'request': AgentRequest}`. The peer already asked its
  /// user; THIS device re-gates before executing (its approval value is never
  /// trusted) and answers with [sendAgentResult].
  ///
  /// Read by the assistant view, which is the only surface that consumed it
  /// before this pass. The launched shell claims the request through
  /// [takeIncomingAgentAction] instead, which clears this field — one request,
  /// one owner.
  Map<String, dynamic>? lastIncomingAgentRequest;

  /// The request [lastIncomingAgentRequest] names, as the type that cannot be
  /// handled without answering it. Null when nothing is waiting, when the
  /// assistant view already dismissed it, or once it has been claimed.
  IncomingAgentAction? _incomingAction;

  /// In-flight replies keyed by request id. Completed by `agent.result` or a
  /// timeout, so a sender can await the remote's answer.
  final Map<String, Completer<AgentDispatchResult?>> _pendingAgentResults = {};

  final Map<String, Completer<BrainReply?>> _pendingBrainResults = {};

  /// A node on our cable reported something — relay it to whichever peer
  /// asked (multi-hop), or note it locally.
  @override
  void _relaySerialUp(String deviceId, Map<String, dynamic> data) {
    final requester = _serialRequesters[deviceId];
    if (requester != null && _paired.containsKey(requester)) {
      unawaited(
        _sendEnc(
          _paired[requester]!,
          NexusMessage(
            type: NexusMessage.serialUp,
            from: deviceId,
            to: requester,
            payload: {
              'data': data,
              'name': _serial?.byId(deviceId)?.name ?? deviceId,
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
    }
    lastSerialUp = {
      'from': deviceId,
      'name': _serial?.byId(deviceId)?.name ?? deviceId,
      'data': data,
    };
    notifyListeners();
  }

  /// Asks a paired device's brain a question and waits for its reply — the
  /// mesh half of [DistributedBrain]. Completes with null when the request
  /// could not be delivered or the peer never answered within [timeout].
  /// The completer is registered BEFORE sending, so an instant reply can
  /// never be missed — exactly like [sendAgentRequest].
  Future<BrainReply?> requestBrainAnswer(
    String deviceId, {
    required String system,
    required List<ChatTurn> history,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final peer = _paired[deviceId];
    if (peer == null) return null;
    final requestId = 'brain-${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<BrainReply?>();
    _pendingBrainResults[requestId] = completer;
    Timer(timeout, () {
      final pending = _pendingBrainResults.remove(requestId);
      if (pending != null && !pending.isCompleted) pending.complete(null);
    });
    final delivered = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.brainAsk,
        from: identity.id,
        to: deviceId,
        payload: {
          'requestId': requestId,
          'system': system,
          'history': [
            for (final turn in history)
              {'role': turn.role, 'content': turn.content},
          ],
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!delivered) {
      final pending = _pendingBrainResults.remove(requestId);
      if (pending != null && !pending.isCompleted) pending.complete(null);
      return null;
    }
    return completer.future;
  }

  /// Sends a brain's reply back to the device that delegated the question.
  Future<bool> sendBrainAnswer(
    String deviceId,
    String requestId,
    BrainReply reply,
  ) async {
    final peer = _paired[deviceId];
    if (peer == null) return false;
    return await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.brainAnswer,
        from: identity.id,
        to: deviceId,
        payload: {
          'requestId': requestId,
          if (reply.text != null && reply.text!.isNotEmpty) 'text': reply.text,
          'reachable': reply.reachable,
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Sends an approved action to a paired device ("call mom" routed to the
  /// phone). Completes with the remote device's typed reply, or null when the
  /// request could not be delivered or the peer never answered within ten
  /// seconds. The completer is registered BEFORE sending so an instant reply
  /// can never be missed.
  Future<AgentDispatchResult?> sendAgentRequest(
    String deviceId,
    AgentRequest request,
  ) async {
    final peer = _paired[deviceId];
    if (peer == null) return null;
    final completer = Completer<AgentDispatchResult?>();
    _pendingAgentResults[request.requestId] = completer;
    Timer(const Duration(seconds: 15), () {
      final pending = _pendingAgentResults.remove(request.requestId);
      if (pending != null && !pending.isCompleted) pending.complete(null);
    });
    final delivered = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.agentAction,
        from: identity.id,
        to: deviceId,
        payload: {'request': request.toJson()},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!delivered) {
      final pending = _pendingAgentResults.remove(request.requestId);
      if (pending != null && !pending.isCompleted) pending.complete(null);
      return null;
    }
    return completer.future;
  }

  /// Whether an `agent.action` frame from [id] has proved itself.
  ///
  /// Three conditions, and all three are needed before a pre-approval may be
  /// spent — see [IncomingAgentAction.trusted] and the shell's decision:
  ///
  /// 1. **the frame arrived encrypted** — the channel key came from a pairing
  ///    secret, so the bytes are the peer's;
  /// 2. **the peer is paired** — there is a record to hang a promise on;
  /// 3. **this session derived the key** — a pairing that exists but has never
  ///    carried a frame is a row, not a peer. A restart forgets this, and a
  ///    request that arrives before the first exchange is asked about rather
  ///    than run, which is the safe direction for the doubt.
  ///
  /// Named and separate because 'auto' is the only thing in the app that acts
  /// without a person watching, and "we think this is probably them" is not a
  /// standard to spend that on.
  bool agentFrameProven(String id, {required bool encrypted}) =>
      encrypted && _paired.containsKey(id) && _sessionKeys.containsKey(id);

  /// Claims the peer-initiated action that is waiting, if any.
  ///
  /// One owner: taking it clears [lastIncomingAgentRequest] as well, so a
  /// second surface cannot pick up a request the first one is already
  /// answering. Null on every call after the first.
  IncomingAgentAction? takeIncomingAgentAction() {
    final IncomingAgentAction? pending = _incomingAction;
    if (pending == null) return null;
    _incomingAction = null;
    lastIncomingAgentRequest = null;
    return pending;
  }

  /// Sends the outcome of an action request back to the requesting device.
  /// Only the status, message and (for plain answers) the text travel — the
  /// remote does not need our device snapshots or plans.
  Future<bool> sendAgentResult(
    String deviceId,
    String requestId,
    AgentDispatchResult result,
  ) async {
    final peer = _paired[deviceId];
    if (peer == null) return false;
    final text = result.dispatch is AgentMessage
        ? (result.dispatch! as AgentMessage).text
        : null;
    return await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.agentResult,
        from: identity.id,
        to: deviceId,
        payload: {
          'requestId': requestId,
          'status': result.status.name,
          'message': result.message,
          if (text != null && text.isNotEmpty) 'text': text,
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// The assistant answered the incoming request (approved or denied) — clear
  /// it so the card disappears and the next request can show.
  void dismissIncomingAgentRequest() {
    lastIncomingAgentRequest = null;
    notifyListeners();
  }

  /// Sends a small command payload to a serial node — over our own cable, or
  /// through whichever paired device hosts it (multi-hop relay).
  Future<bool> sendSerialMessage(String id, Map<String, dynamic> data) async {
    final local = _serial?.byId(id);
    if (local != null) {
      return await _serial!.sendMessage(id, data);
    }
    final hostId = _serialHosts[id];
    final host = hostId == null ? null : _paired[hostId];
    if (host == null) return false;
    _serialRequesters[id] = identity.id;
    return await _sendEnc(
      host,
      NexusMessage(
        type: NexusMessage.serialMsg,
        from: identity.id,
        to: id,
        payload: {'data': data},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// The serial devices on our cable, as announced to peers in ping/pong.
  /// Only live nodes: an unplugged node must not be offered for relay.
  @override
  List<Map<String, dynamic>> _serialAnnouncement() {
    return (_serial?.liveDevices ?? const [])
        .map((d) => {'id': d.id, 'name': d.name, 'caps': d.caps})
        .toList();
  }

  /// Remembers which serial nodes a peer has on its cable. Anything not
  /// announced anymore is forgotten.
  void _noteSerialHosts(String peerId, Object? raw) {
    final list = raw is List ? raw.whereType<Map>().toList() : const [];
    final seen = <String>{};
    for (final item in list) {
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;
      seen.add(id);
      _serialHosts[id] = peerId;
      _serialNames[id] = item['name']?.toString() ?? id;
      _serialCaps[id] =
          (item['caps'] as List?)?.whereType<String>().toList() ??
          const ['ping', 'msg'];
    }
    final stale = _serialHosts.entries
        .where((e) => e.value == peerId && !seen.contains(e.key))
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      _serialHosts.remove(id);
      _serialNames.remove(id);
      _serialCaps.remove(id);
    }
  }

  @override
  Future<void> _handleMessage(
    NexusMessage msg,
    Socket socket, {
    required bool encrypted,
    String? provenId,
    String? sourceAddress,
  }) async {
    // The identity a frame may speak as is the one the channel proved, never
    // the one it claims. Decrypting with a peer's key proves which peer sent
    // the bytes, so a frame whose `from` is a different device is either a
    // bug or an attempt to act as that device — and every trusted thing below
    // (presence, routes, learned phrases, facts, device-addressed answers)
    // hangs off `msg.from`. Dropped before the replay guard so a forged id
    // cannot burn a frame id a real peer still needs.
    //
    // One frame is not speaking as anyone: `serial.up` relays a payload from a
    // node on the *sender's* cable, so its `from` names that node and the
    // sender vouches for it over its own authenticated connection. It is
    // exempt only when addressed to us, and it carries no authority — it fills
    // a field for the UI to show.
    final relayedOriginator =
        msg.type == NexusMessage.serialUp && msg.to == identity.id;
    if (provenId != null && msg.from != provenId && !relayedOriginator) {
      debugPrint(
        'NEXUS mesh: dropped ${msg.type} claiming ${msg.from} on a connection '
        'authenticated as $provenId',
      );
      return;
    }

    // Every frame is processed exactly once. A replay is the same bytes with
    // the same id, so this is where a captured presence claim, clipboard push
    // or agent instruction stops being a second event.
    if (!_remember(msg.id)) {
      debugPrint('NEXUS mesh: dropped replayed ${msg.type} from ${msg.from}');
      return;
    }

    switch (msg.type) {
      case NexusMessage.ping:
        // A ping tells us who is talking, but being *told* is not knowing.
        // Presence and routes are state we act on, so they only move for a
        // peer that proves it holds the session key. An unproven claim is
        // still heard — that is how a new device becomes discoverable — it
        // just cannot reach trusted state.
        final proven = await _presenceProven(msg, encrypted: encrypted);
        if (proven && _paired.containsKey(msg.from)) {
          _inboundPeer[socket] = msg.from;
        }
        final payload = msg.payload;
        if (_paired.containsKey(msg.from)) {
          _notePeerVersion(msg.from, payload['appVersion']);
          _noteSerialHosts(msg.from, payload['serial']);
          _notePeerCapabilities(
            msg.from,
            payload[NexusMessage.caps],
            proven: proven,
          );
          if (proven) _notePeerBrain(msg.from, payload['brain'] == true);
        }
        final name = payload['name'] as String? ?? 'Unknown device';
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        _noteSeen(msg.from, verified: proven);
        debugPrint(
          'NEXUS mesh: ping <- ${msg.from} from ${sourceAddress ?? 'unknown'}'
          '${proven ? '' : ' (unproven)'}',
        );
        if (port != null) {
          await _learnAddress(
            msg.from,
            sourceAddress ?? '',
            port,
            name,
            payload['platform'] as String? ?? 'other',
            ips: ips,
            trusted: proven,
          );
        }
        final pong = await _signedPresence(
          NexusMessage(
            type: NexusMessage.pong,
            from: identity.id,
            to: msg.from,
            payload: {
              'name': identity.name,
              'platform': identity.platform,
              'appVersion': appVersion,
              'port': store.port,
              'ips': await _myIps(),
              'serial': _serialAnnouncement(),
              NexusMessage.caps: await _capabilityAnnouncement(),
              'brain': brain != null,
              if (_tailscale != null)
                'tailscale': {
                  'online': _tailscale!.online,
                  if (_tailscale!.ipv4 != null) 'ipv4': _tailscale!.ipv4,
                },
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _sendPlain(socket, pong);

      case NexusMessage.pong:
        // Same rule as the ping: a proven pong is what makes a peer online,
        // and only a proven pong may move where we reach it.
        final proven = await _presenceProven(msg, encrypted: encrypted);
        _noteSeen(msg.from, verified: proven);
        debugPrint(
          'NEXUS mesh: pong <- ${msg.from}${proven ? '' : ' (unproven)'}',
        );
        final payload = msg.payload;
        if (_paired.containsKey(msg.from)) {
          _notePeerVersion(msg.from, payload['appVersion']);
          _noteSerialHosts(msg.from, payload['serial']);
          _notePeerCapabilities(
            msg.from,
            payload[NexusMessage.caps],
            proven: proven,
          );
          if (proven) _notePeerBrain(msg.from, payload['brain'] == true);
        }
        final name = payload['name'] as String?;
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        if (port != null && name != null) {
          await _learnAddress(
            msg.from,
            sourceAddress ?? '',
            port,
            name,
            payload['platform'] as String? ?? 'other',
            ips: ips,
            trusted: proven,
          );
        }

      case NexusMessage.pairRequest:
        // Deliberately not handled here. A pairing request is legitimate only
        // when it decrypts under the code the user is showing — that is the
        // proof, and it is what [_tryPairingFrame] establishes before calling
        // [_handlePairRequest]. Handling the plaintext form would let a
        // stranger add itself to the paired list and spend the code the user
        // is looking at, so this door stays shut.
        break;

      case NexusMessage.pairAccept:
        // Handled inside pairWith's own flow; reaching here means an
        // unexpected duplicate — ignore.
        break;

      case NexusMessage.pairReject:
        break;

      case NexusMessage.clipboard:
        if (!encrypted) return; // clipboard text must never ride in plaintext
        await _handleIncomingClip(msg);

      case NexusMessage.clipboardAck:
        if (!encrypted) return;
        final req = msg.payload['req'];
        final ack = req is String ? _pendingClipboardAcks.remove(req) : null;
        if (ack != null && !ack.isCompleted) ack.complete(true);

      case NexusMessage.clipboardNotify:
        // No longer used — kept for backward compatibility with older peers.
        break;

      case NexusMessage.clipboardPull:
        // No longer used — kept for backward compatibility with older peers.
        break;

      case NexusMessage.fileList:
        if (!encrypted) return; // file paths are private — never in plaintext
        await _handleFileListRequest(msg);

      case NexusMessage.fileGet:
        if (!encrypted) return;
        await _handleFileGetRequest(msg);

      case NexusMessage.fileListResult:
        if (!encrypted) return;
        await _handleFileListResult(msg);

      case NexusMessage.fileChunk:
        if (!encrypted) return;
        await _handleFileChunk(msg);

      case NexusMessage.filePush:
        if (!encrypted) return;
        await _handleFilePush(msg);

      case NexusMessage.filePushAck:
        if (!encrypted) return;
        await _handleFilePushAck(msg);

      case NexusMessage.fileDelete:
        if (!encrypted) return;
        await _handleFileDelete(msg);

      case NexusMessage.fileDeleteAck:
        if (!encrypted) return;
        await _handleFileDeleteAck(msg);

      case NexusMessage.fileOperation:
        if (!encrypted) return;
        await _handleFileOperation(msg);

      case NexusMessage.fileOperationAck:
        if (!encrypted) return;
        await _handleFileOperationAck(msg);

      case NexusMessage.fileError:
        if (!encrypted) return;
        await _handleFileError(msg);

      case NexusMessage.serialMsg:
        // Multi-hop: a peer wants us to forward a payload to a node on our
        // cable. The node replies with `up`, relayed back to this peer.
        if (!encrypted) return;
        final target = msg.to;
        final data = msg.payload['data'];
        if (target == null || data is! Map<String, dynamic>) break;
        if (_serial?.byId(target) == null) break;
        _serialRequesters[target] = msg.from;
        await _serial!.sendMessage(target, data);

      case NexusMessage.serialUp:
        // A node on a peer's cable answered — remember the payload so the UI
        // can show it.
        if (!encrypted) return;
        final data = msg.payload['data'];
        if (data is Map<String, dynamic>) {
          lastSerialUp = {
            'from': msg.from,
            'name': msg.payload['name'] ?? msg.from,
            'data': data,
          };
          notifyListeners();
        }

      case NexusMessage.agentAction:
        // A paired device routed an approved action here. The request's own
        // approval value is ignored — this device re-gates before executing
        // and answers with agent.result. The gate is two facts decided here
        // and now, because both are properties of *this* frame and this
        // session: whether it proved itself ([agentFrameProven]), and what the
        // user has said this device accepts ([NexusStore.agentPolicy]).
        if (!encrypted) return;
        final raw = msg.payload['request'];
        if (raw is! Map<String, dynamic>) break;
        try {
          final request = AgentRequest.fromJson(raw);
          _incomingAction = IncomingAgentAction(
            (String requestId, AgentDispatchResult result) =>
                sendAgentResult(msg.from, requestId, result),
            from: msg.from,
            request: request,
            trusted: agentFrameProven(msg.from, encrypted: encrypted),
            policy: store.agentPolicy(request.action),
          );
          lastIncomingAgentRequest = {'from': msg.from, 'request': request};
          // One line the hardware can show: a request that reaches this device
          // but never becomes a card is otherwise invisible, because every
          // refusal downstream answers the sender instead of logging here.
          debugPrint(
            'NEXUS mesh: peer action ${request.action} from ${msg.from} '
            '(${_incomingAction!.policy.name}, '
            '${_incomingAction!.trusted ? 'proven' : 'unproven'})',
          );
          notifyListeners();
        } catch (error) {
          // Malformed request — drop it; never execute garbage.
          debugPrint('NEXUS mesh: unreadable peer action from ${msg.from} ($error)');
        }

      case NexusMessage.agentResult:
        // The remote device answered our action — complete the pending
        // future so the sender's UI can show the outcome.
        if (!encrypted) return;
        final requestId = msg.payload['requestId']?.toString();
        if (requestId == null) break;
        final status = AgentResultStatus.values.firstWhere(
          (s) => s.name == msg.payload['status'],
          orElse: () => AgentResultStatus.unavailable,
        );
        final text = msg.payload['text']?.toString();
        final result = AgentDispatchResult(
          status: status,
          message: msg.payload['message']?.toString() ?? '',
          dispatch: text != null && text.isNotEmpty ? AgentMessage(text) : null,
        );
        final pending = _pendingAgentResults.remove(requestId);
        if (pending != null && !pending.isCompleted) pending.complete(result);
        notifyListeners();

      case NexusMessage.brainAsk:
        // A peer delegated a conversation question to this device's brain.
        // Answered automatically — this is transport, not an action, so no
        // approval gate. A device without a brain refuses honestly and
        // quickly, so the asker never waits out the timeout.
        if (!encrypted) return;
        final brainRequestId = msg.payload['requestId']?.toString();
        final system = msg.payload['system']?.toString();
        if (brainRequestId == null || system == null) break;
        final responder = brain;
        if (responder == null) {
          await sendBrainAnswer(msg.from, brainRequestId, (
            text: null,
            reachable: false,
          ));
          break;
        }
        final history = <ChatTurn>[
          for (final raw in (msg.payload['history'] as List?) ?? const [])
            if (raw is Map<String, dynamic>)
              (
                role: raw['role']?.toString() ?? 'user',
                content: raw['content']?.toString() ?? '',
              ),
        ];
        final reply = await responder.reply(system: system, history: history);
        await sendBrainAnswer(msg.from, brainRequestId, reply);

      case NexusMessage.brainAnswer:
        // The peer's brain answered our delegated question.
        if (!encrypted) return;
        final brainAnswerId = msg.payload['requestId']?.toString();
        if (brainAnswerId == null) break;
        final answerText = msg.payload['text']?.toString();
        final reachable = msg.payload['reachable'] == true;
        final brainPending = _pendingBrainResults.remove(brainAnswerId);
        if (brainPending != null && !brainPending.isCompleted) {
          brainPending.complete(
            answerText == null || answerText.isEmpty
                ? (text: null, reachable: reachable)
                : (text: answerText, reachable: reachable),
          );
        }

      case NexusMessage.agentLearned:
        if (!encrypted) return;
        await _handleSyncedLearned(msg);
      case NexusMessage.agentFact:
        if (!encrypted) return;
        await _handleSyncedFact(msg);
      case NexusMessage.agentReminder:
        if (!encrypted) return;
        await _handleSyncedReminder(msg);
      case NexusMessage.agentDefault:
        if (!encrypted) return;
        await _handleSyncedDefault(msg);
      case NexusMessage.agentProfile:
        if (!encrypted) return;
        await _handleSyncedProfile(msg);
    }
  }

}
