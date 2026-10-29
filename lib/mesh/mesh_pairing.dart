part of 'mesh_service.dart';

/// Pairing: the code this device shows, the QR handshake, and the two
/// sides that turn a matched secret into a paired device.
///
/// Split out of `mesh_service.dart` without touching the code: every body
/// below is the one that ran before this file existed. The state it owns
/// (the shown code, the QR pids already spent, the inbound requests) lives
/// in this mixin because nothing outside pairing reads it; everything
/// shared stays on [_MeshBase].
mixin _MeshPairing on _MeshBase {
  /// The most recently spent pairing code, kept only until the code's own
  /// expiry so a second device that scans the same (now used) code is told
  /// that instead of waiting for a 12-second silence.
  String? _spentCodeValue;
  DateTime? _spentCodeUntil;

  String? pendingCode;
  DateTime? pendingCodeExpiry;

  /// Currently shown v2 QR token (Device A). Null when not showing.
  QrPairingToken? qrShown;

  /// Single-use guard: pids already consumed (accepted, rejected, expired).
  final Set<String> _usedQrPids = {};

  /// Inbound QR requests awaiting the shower's explicit tap (pid -> request).
  final Map<String, QrInboundRequest> _qrInbound = {};

  /// Inbound QR requests, newest last. The pair sheet renders this.
  List<QrInboundRequest> get pendingQrRequests {
    final now = DateTime.now().millisecondsSinceEpoch;
    _qrInbound.removeWhere((_, r) => now >= r.expiryMs);
    return _qrInbound.values.toList();
  }

  /// A frame we could not decrypt with any paired device's key might be a
  /// pairing request encrypted with the code we are currently showing. If it
  /// decrypts and is a pair-request, accept it.
  ///
  /// A code that was already spent is still understood, but only so the
  /// duplicate can be refused with a reason instead of silence — see
  /// [_rejectPairing].
  Future<void> _tryPairingFrame(Socket socket, String enc) async {
    // v2 QR handshake first: the shown token's pid|nonce key. A scan only
    // ever stages a request for explicit accept — never pairs on receipt.
    final shown = qrShown;
    if (shown != null &&
        !shown.expired &&
        !_usedQrPids.contains(shown.pairingId)) {
      try {
        final qrKey = await derivePairingKey(MeshService.qrSecretFor(shown));
        final qrClear = await decryptFromB64(enc, qrKey);
        final qrMsg = NexusMessage.fromJson(
          jsonDecode(utf8.decode(qrClear)) as Map<String, dynamic>,
        );
        if (qrMsg.type == NexusMessage.pairRequest) {
          await _handleQrRequest(qrMsg, socket, shown, qrKey);
          return;
        }
      } catch (_) {}
      // A replay of a consumed pid still decrypts: refuse with a reason.
    }
    if (shown != null && _usedQrPids.contains(shown.pairingId)) {
      try {
        final spentKey = await derivePairingKey(MeshService.qrSecretFor(shown));
        final spentClear = await decryptFromB64(enc, spentKey);
        final spentMsg = NexusMessage.fromJson(
          jsonDecode(utf8.decode(spentClear)) as Map<String, dynamic>,
        );
        if (spentMsg.type == NexusMessage.pairRequest) {
          debugPrint('NEXUS mesh: qr-request <- ${spentMsg.from} (pid spent)');
          await _rejectPairing(
            socket,
            spentKey,
            spentMsg.from,
            'That QR was already used. Show a fresh code and try again.',
          );
          return;
        }
      } catch (_) {}
    }
    final active = pendingCodeActive;
    final code = active ? pendingCode : _spentCode;
    if (code == null) return;
    final key = await derivePairingKey(code);
    Uint8List clear;
    try {
      clear = await decryptFromB64(enc, key);
    } catch (_) {
      return;
    }
    NexusMessage msg;
    try {
      msg = NexusMessage.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } catch (_) {
      return;
    }
    if (msg.type == NexusMessage.pairRequest) {
      if (!active) {
        debugPrint('NEXUS mesh: pair-request <- ${msg.from} (code spent)');
        await _rejectPairing(
          socket,
          key,
          msg.from,
          'That code has already been used. Show a fresh code on the other '
          'device and try again.',
        );
        return;
      }
      debugPrint('NEXUS mesh: pair-request <- ${msg.from} (code matched)');
      await _handlePairRequest(msg, socket, provenByCode: true);
    }
  }


  // ---------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------

  /// Start "show my code": returns a code + QR payload valid for 5 minutes.
  /// The QR includes our addresses when they are already known, so a scanning
  /// device can connect straight away without typing an address. The caller
  /// refreshes it once a first interface scan completes (see `knownIps`).
  PairingSession beginPairing() {
    final code = generatePairingCode();
    pendingCode = code;
    pendingCodeExpiry = DateTime.now().add(const Duration(minutes: 5));
    final ips = knownIps;
    return PairingSession(
      code: code,
      qrPayload: PairPayload.build(
        id: identity.id,
        name: identity.name,
        port: store.port,
        code: code,
        ip: ips.isNotEmpty ? ips.first : null,
        ips: ips,
      ),
      expiresAt: pendingCodeExpiry!,
    );
  }

  /// Starts "show my QR": a minimal single-use v2 token valid ~120s.
  ///
  /// Showing is explicit consent to be scanned, NOT consent to pair: a scan
  /// only lets the other device send a request, and pairing happens solely
  /// through [acceptQrPairing]. The payload carries no name, contacts,
  /// files, clipboard, location, history, or stable device id.
  PairingSession beginQrPairing() {
    final previous = qrShown;
    if (previous != null) _markQrUsed(previous.pairingId);
    final ips = knownIps;
    final token = QrPairingToken.generate(
      address: ips.isNotEmpty ? ips.first : null,
      port: store.port,
    );
    qrShown = token;
    debugPrint(
      'NEXUS mesh: qr-shown pid=${token.pairingId} '
      'code=${token.code} exp=${token.expiryMs}',
    );
    // Audit-only, no save here: showing happens on the UI thread (and in
    // widget tests under a fake clock where real file I/O never lands),
    // so a fire-and-forget write could wedge the store chain that stop()
    // flushes. The event persists with the next save (accept/deny/pair).
    store.logPairingEvent('qr-shown', 'pid=${token.pairingId}');
    notifyListeners();
    return PairingSession(
      code: token.code,
      qrPayload: token.encode(),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(token.expiryMs),
    );
  }

  bool get qrShownActive {
    final shown = qrShown;
    if (shown == null) return false;
    if (shown.expired) return false;
    return !_usedQrPids.contains(shown.pairingId);
  }

  /// Whether a pid may still be used (unexpired, unconsumed).
  @visibleForTesting
  bool qrPidUsable(String pid, int expiryMs) {
    if (_usedQrPids.contains(pid)) return false;
    return DateTime.now().millisecondsSinceEpoch < expiryMs;
  }

  void _markQrUsed(String pid) => _usedQrPids.add(pid);

  /// Device A explicitly accepts an inbound QR request: the ONLY path that
  /// pairs from a QR scan. Marks the pid single-use, stores the peer,
  /// answers accept on the request socket's key, and audit-logs.
  Future<bool> acceptQrPairing(String pid) async {
    final req = _qrInbound[pid];
    if (req == null || req.expired) {
      _qrInbound.remove(pid);
      return false;
    }
    final shown = qrShown;
    if (shown == null || shown.pairingId != pid || shown.expired) {
      return false;
    }
    final socket = _qrSockets[pid];
    final msg = _qrMsgs[pid];
    final key = _qrKeys[pid];
    if (socket != null && msg != null && key != null) {
      _qrInbound.remove(pid);
      _qrSockets.remove(pid);
      _qrMsgs.remove(pid);
      _qrKeys.remove(pid);
      store.logPairingEvent('qr-accepted', 'pid=$pid');
      await _completeQrAccept(msg, socket, shown, key);
      return true;
    }
    _markQrUsed(pid);
    _qrInbound.remove(pid);
    final secret = _qrSecret(shown);
    final peer = PairedDevice(
      id: req.fromDeviceLabel,
      name: 'Paired device',
      platform: 'other',
      address: req.address,
      port: req.port,
      pairingSecret: secret,
      lastVerified: DateTime.now(),
    );
    // The tap raced ahead of the socket: reserve the accept so the request
    // completes the moment it arrives (see _handleQrRequest). Notify first
    // so the sheet redraws spent state on the next frame. No save here
    // (same reason as beginQrPairing): the accept persists when the socket
    // lands in _completeQrAccept.
    _pendingQrAccept[pid] = peer;
    store.logPairingEvent('qr-accepted', 'pid=$pid');
    notifyListeners();
    return true;
  }

  /// Device A explicitly denies an inbound QR request. Single-use: the pid
  /// can never pair afterwards.
  Future<void> rejectQrPairing(String pid, [String reason = 'Denied']) async {
    _markQrUsed(pid);
    _qrInbound.remove(pid);
    _pendingQrAccept.remove(pid);
    final socket = _qrSockets.remove(pid);
    final msg = _qrMsgs.remove(pid);
    final key = _qrKeys.remove(pid);
    if (socket != null && msg != null && key != null) {
      await _rejectPairing(socket, key, msg.from, reason);
    }
    store.logPairingEvent('qr-denied', 'pid=$pid $reason');
    notifyListeners();
  }

  /// Pids the shower accepted but whose request socket has not arrived yet.
  final Map<String, PairedDevice> _pendingQrAccept = {};

  /// Live inbound QR request sockets, kept so the explicit Allow tap can
  /// answer on the same connection the scanner is waiting on.
  final Map<String, Socket> _qrSockets = {};
  final Map<String, NexusMessage> _qrMsgs = {};
  final Map<String, Uint8List> _qrKeys = {};

  String _qrSecret(QrPairingToken token) =>
      MeshService.qrSecretFor(token);

  /// Test seam: stages an inbound QR request without sockets, so widget
  /// tests can prove the confirmation prompt without real I/O in a fake
  /// async zone. Production always stages via [_handleQrRequest].
  @visibleForTesting
  void stageInboundQrForTest(QrInboundRequest req) {
    _qrInbound[req.pairingId] = req;
    notifyListeners();
  }

  /// Either side revokes a pairing at any time. Clears keys/routes and
  /// audit-logs. Revoking an unknown id is a no-op that still logs.
  Future<void> revokePairing(String id) async {
    await forgetDevice(id);
    store.logPairingEvent('revoked', 'id=$id');
    await store.save();
  }

  void _audit(String event, [String detail = '']) {
    store.logPairingEvent(event, detail);
    unawaited(store.save());
  }

  /// Our own non-loopback IPv4 addresses as last resolved by [_myIps], without
  /// touching the interfaces. Empty until the first scan finishes — heartbeats
  /// call [_myIps] within seconds of start, so the QR usually has them already.
  List<String> get knownIps => List.unmodifiable(_ipsCache ?? const <String>[]);

  /// The spent code, while still inside its original validity window. It can
  /// never pair a device — [pendingCodeActive] guards the accept path — it
  /// only exists so a duplicate attempt gets an honest refusal.
  String? get _spentCode {
    final code = _spentCodeValue;
    final until = _spentCodeUntil;
    if (code == null || until == null) return null;
    if (DateTime.now().isAfter(until)) return null;
    return code;
  }

  /// Tells a device that its (already used) code will not pair, over a frame
  /// encrypted with that same code — the only key the caller can read.
  Future<void> _rejectPairing(
    Socket socket,
    Uint8List key,
    String to,
    String reason,
  ) async {
    final reply = NexusMessage(
      type: NexusMessage.pairReject,
      from: identity.id,
      to: to,
      payload: {'reason': reason},
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final enc = await encryptToB64(encodeJson(reply.toJson()), key);
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
      await socket.flush();
    } catch (_) {
      _dropSocket(socket);
    }
  }

  bool get pendingCodeActive {
    final expiry = pendingCodeExpiry;
    return pendingCode != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry);
  }

  /// A v2 QR request arrived on the shown token's key. Stage it for the
  /// shower's explicit tap — NEVER pair here. A scan is a request, not
  /// consent.
  Future<void> _handleQrRequest(
    NexusMessage msg,
    Socket socket,
    QrPairingToken shown,
    Uint8List key,
  ) async {
    debugPrint(
      'NEXUS mesh: qr-request raw from=${msg.from} pid=${shown.pairingId}',
    );
    if (!store.pairingEnabled) {
      debugPrint('NEXUS mesh: qr-request refused (pairing off)');
      await _rejectPairing(
        socket,
        key,
        msg.from,
        'Pairing is off on this device.',
      );
      return;
    }
    final payload = msg.payload;
    if (payload['qrPid'] != shown.pairingId ||
        payload['qrNonce'] != shown.nonce ||
        payload['qrCode'] != shown.code) {
      debugPrint('NEXUS mesh: qr-request pid/nonce/code mismatch — dropped');
      return;
    }
    final peerPort = (payload['port'] as num?)?.toInt() ?? store.port;
    final req = QrInboundRequest(
      pairingId: shown.pairingId,
      fromDeviceLabel: msg.from,
      code: shown.code,
      expiryMs: shown.expiryMs,
      address: socket.remoteAddress.address,
      port: peerPort,
    );
    _qrInbound[shown.pairingId] = req;
    _qrSockets[shown.pairingId] = socket;
    _qrMsgs[shown.pairingId] = msg;
    _qrKeys[shown.pairingId] = key;
    _audit('qr-request-got', 'pid=${shown.pairingId} from=${msg.from}');
    debugPrint(
      'NEXUS mesh: qr-request staged pid=${shown.pairingId} '
      'code=${shown.code} awaiting-confirm',
    );
    // If A already tapped Allow before the socket arrived, complete now.
    final pre = _pendingQrAccept.remove(shown.pairingId);
    if (pre != null) {
      await _completeQrAccept(msg, socket, shown, key);
      return;
    }
    notifyListeners();
  }

  /// Completes an accepted QR pairing on the request socket: stores the peer
  /// and answers accept on the same key. Only called from [_tryPairingFrame]
  /// after [acceptQrPairing] (explicit tap) — or immediately when the tap
  /// raced ahead of the socket.
  Future<void> _completeQrAccept(
    NexusMessage msg,
    Socket socket,
    QrPairingToken shown,
    Uint8List key,
  ) async {
    _markQrUsed(shown.pairingId);
    _qrInbound.remove(shown.pairingId);
    _qrSockets.remove(shown.pairingId);
    _qrMsgs.remove(shown.pairingId);
    _qrKeys.remove(shown.pairingId);
    final payload = msg.payload;
    final name = (payload['name'] as String?) ?? 'Paired device';
    final platform = (payload['platform'] as String?) ?? 'other';
    final peerPort = (payload['port'] as num?)?.toInt() ?? store.port;
    final secret = MeshService.qrSecretFor(shown);
    final peer = PairedDevice(
      id: msg.from,
      name: name,
      platform: platform,
      address: socket.remoteAddress.address,
      port: peerPort,
      pairingSecret: secret,
      lastVerified: DateTime.now(),
    );
    _paired[peer.id] = peer;
    _forgetSessionKey(peer.id);
    store.upsertPaired(peer.toJson());
    await store.save();
    qrShown = null;
    _noteSeen(peer.id, verified: true);
    _audit('paired', 'pid=${shown.pairingId} peer=${peer.id}');
    debugPrint('NEXUS mesh: qr-accept -> ${peer.id} pid=${shown.pairingId}');
    final reply = NexusMessage(
      type: NexusMessage.pairAccept,
      from: identity.id,
      to: msg.from,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
        'qrPid': shown.pairingId,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final enc = await encryptToB64(encodeJson(reply.toJson()), key);
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
      await socket.flush();
    } catch (_) {
      _dropSocket(socket);
    }
    notifyListeners();
  }

  /// The other side: verify the pairing request and accept it.
  Future<void> _handlePairRequest(
    NexusMessage msg,
    Socket socket, {
    required bool provenByCode,
  }) async {
    // Pairing mints a shared secret, so it is the most trusted state there is.
    // The only acceptable proof is that the request decrypted under the code
    // currently on screen; only [_tryPairingFrame] can establish that.
    if (!provenByCode) {
      debugPrint('NEXUS mesh: refused unproven pair-request <- ${msg.from}');
      return;
    }
    if (!store.pairingEnabled) {
      debugPrint('NEXUS mesh: pair-request refused (pairing off)');
      return;
    }
    if (!pendingCodeActive) {
      // We should not even be able to decrypt without a pending code, but
      // guard anyway.
      return;
    }
    final code = pendingCode!;
    final key = await derivePairingKey(code);
    final payload = msg.payload;
    final name = (payload['name'] as String?) ?? 'Unknown device';
    final platform = (payload['platform'] as String?) ?? 'other';
    final peerPort = (payload['port'] as num?)?.toInt();

    final peer = PairedDevice(
      id: msg.from,
      name: name,
      platform: platform,
      address: socket.remoteAddress.address,
      port: peerPort ?? store.port,
      pairingSecret: code,
      lastVerified: DateTime.now(),
    );
    _paired[peer.id] = peer;
    // The secret we just stored replaces whatever this device was paired with
    // before, so the key derived from the old one must not outlive it.
    _forgetSessionKey(peer.id);
    store.upsertPaired(peer.toJson());
    await store.save();
    // Remember that this code is spent (until its own expiry) so the next
    // device to scan the same code is refused with a reason, not silence.
    _spentCodeValue = code;
    _spentCodeUntil = pendingCodeExpiry;
    pendingCode = null;
    pendingCodeExpiry = null;
    _noteSeen(peer.id, verified: true);
    _audit('paired', 'code peer=${peer.id}');

    // Reply on the same socket, encrypted with the same code-derived key.
    final reply = NexusMessage(
      type: NexusMessage.pairAccept,
      from: identity.id,
      to: msg.from,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final enc = await encryptToB64(encodeJson(reply.toJson()), key);
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
      await socket.flush();
    } catch (_) {
      _dropSocket(socket);
    }
    notifyListeners();
  }

  /// This side: connect to a device showing a code, prove we know the code
  /// by encrypting our request with it, and store the pair on acceptance.
  /// Pairs through the first address that answers, trying every address the
  /// other device advertised.
  ///
  /// A QR carries every address its device knows (LAN, VPN, Tailscale)
  /// *because* any single one can be stale — a laptop that changed networks,
  /// a VPN that is down, a Docker bridge that looks like a LAN. Trying only
  /// the first one turns any of those into "I scanned the QR and it never
  /// connected". A failure that already reached the device (a wrong code) is
  /// returned at once: another address cannot fix that.
  Future<PairResult> pairWithCandidates({
    required List<String> addresses,
    required int port,
    required String code,
  }) async {
    final tried = <String>[];
    PairResult? last;
    for (final raw in addresses) {
      final address = raw.trim();
      if (address.isEmpty || tried.contains(address)) continue;
      tried.add(address);
      final result = await pairWith(address: address, port: port, code: code);
      if (result.ok || result.reached) return result;
      last = result;
    }
    if (tried.isEmpty) {
      return PairResult.failure(
        'That code has no address to connect to — ask the other device to show a fresh code.',
      );
    }
    if (tried.length == 1) return last!;
    return PairResult.failure(
      'Could not reach the device on any of its addresses '
      '(${tried.join(', ')}) port $port. Check that both devices are on the '
      'same network and that its firewall allows Nexus.',
    );
  }

  /// Device B sends a QR pairing REQUEST (never a pairing itself). The scan
  /// only builds this request: A must still tap Allow ([acceptQrPairing])
  /// and only the accept stores a session on either side. Returns ok when
  /// the request was delivered AND accepted; a delivered-but-unanswered
  /// request reports `reached:true` so callers show "waiting for confirm".
  Future<PairResult> pairWithQrCandidates({
    required QrPairingToken token,
    required List<String> addresses,
  }) async {
    if (!store.pairingEnabled) {
      return PairResult.failure(
        'Pairing is off on this device. Turn on Mesh pairing in Settings to pair.',
      );
    }
    if (token.expired) {
      _audit('qr-expired', 'pid=${token.pairingId}');
      return PairResult.failure(
        'That QR expired. Ask the other device to show a fresh code.',
      );
    }
    final tried = <String>[];
    PairResult? last;
    for (final raw in addresses) {
      final address = raw.trim();
      if (address.isEmpty || tried.contains(address)) continue;
      tried.add(address);
      final result = await pairWithQr(token: token, address: address);
      if (result.ok || result.reached) return result;
      last = result;
    }
    if (tried.isEmpty) {
      return PairResult.failure(
        'That QR has no address to connect to — ask the other device to show a fresh code.',
      );
    }
    if (tried.length == 1) return last!;
    return PairResult.failure(
      'Could not reach the device on any of its addresses '
      '(${tried.join(', ')}) port ${token.port}. Check VPN/firewall/AP isolation.',
    );
  }

  /// Sends one QR pairing request. See [pairWithQrCandidates].
  Future<PairResult> pairWithQr({
    required QrPairingToken token,
    required String address,
  }) async {
    if (!store.pairingEnabled) {
      return PairResult.failure(
        'Pairing is off on this device. Turn on Mesh pairing in Settings to pair.',
      );
    }
    if (token.expired) {
      _audit('qr-expired', 'pid=${token.pairingId}');
      return PairResult.failure(
        'That QR expired. Ask the other device to show a fresh code.',
      );
    }
    debugPrint(
      'NEXUS mesh: qr-request -> $address:${token.port} '
      'pid=${token.pairingId} code=${token.code}',
    );
    final key = await derivePairingKey(MeshService.qrSecretFor(token));
    Socket socket;
    try {
      socket = await Socket.connect(
        address,
        token.port,
        timeout: connectTimeout,
      );
    } catch (_) {
      debugPrint('NEXUS mesh: qr-request no-route $address:${token.port}');
      return PairResult.failure(
        'Could not reach $address:${token.port}. Same Wi-Fi? VPN or AP isolation may block it.',
      );
    }
    final completer = Completer<PairResult>();
    final request = NexusMessage(
      type: NexusMessage.pairRequest,
      from: identity.id,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
        'qrPid': token.pairingId,
        'qrPub': token.publicKey,
        'qrNonce': token.nonce,
        'qrCode': token.code,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    String? pendingEnc;
    try {
      pendingEnc = await encryptToB64(encodeJson(request.toJson()), key);
    } catch (_) {
      socket.destroy();
      return PairResult.failure(
        'Could not prepare the pairing request.',
        reached: true,
      );
    }
    final decoder = FrameDecoder();
    final timeout = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        _audit('qr-request-sent', 'pid=${token.pairingId} (awaiting confirm)');
        completer.complete(
          PairResult.failure(
            'Request sent — waiting for the other device to tap Allow (code ${token.code}).',
            reached: true,
          ),
        );
        socket.destroy();
      }
    });
    Future<void> handleChunk(List<int> chunk) async {
      decoder.add(chunk);
      final frames = decoder.takeFrames();
      if (frames == null) return;
      for (final frame in frames) {
        try {
          final json = jsonDecode(utf8.decode(frame));
          if (json is! Map<String, dynamic> || json['enc'] is! String) continue;
          final clear = await decryptFromB64(json['enc'] as String, key);
          final msg = NexusMessage.fromJson(
            jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
          );
          if (msg.type == NexusMessage.pairAccept) {
            debugPrint(
              'NEXUS mesh: qr-accept <- ${msg.from} pid=${token.pairingId}',
            );
            if (!completer.isCompleted) {
              _paired[msg.from] = PairedDevice(
                id: msg.from,
                name: (msg.payload['name'] as String?) ?? 'Paired device',
                platform: (msg.payload['platform'] as String?) ?? 'other',
                address: address,
                port: token.port,
                pairingSecret: MeshService.qrSecretFor(token),
                lastVerified: DateTime.now(),
              );
              _forgetSessionKey(msg.from);
              store.upsertPaired(_paired[msg.from]!.toJson());
              await store.save();
              _noteSeen(msg.from, verified: true);
              _audit('paired', 'pid=${token.pairingId} peer=${msg.from}');
              completer.complete(PairResult.ok(_paired[msg.from]!.name));
            }
            return;
          } else if (msg.type == NexusMessage.pairReject) {
            if (!completer.isCompleted) {
              _audit('qr-denied', 'pid=${token.pairingId}');
              completer.complete(
                PairResult.failure(
                  (msg.payload['reason'] as String?) ??
                      'The other device declined.',
                  reached: true,
                ),
              );
            }
            return;
          }
        } catch (_) {}
      }
    }

    socket.listen(
      handleChunk,
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete(
            PairResult.failure(
              'Connection lost before confirm.',
              reached: true,
            ),
          );
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            PairResult.failure(
              'The other device stopped answering. Its code may have expired.',
              reached: true,
            ),
          );
        }
      },
    );
    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': pendingEnc})));
      await socket.flush();
    } catch (_) {
      timeout.cancel();
      socket.destroy();
      return PairResult.failure(
        'Could not send the pairing request.',
        reached: true,
      );
    }
    final result = await completer.future;
    timeout.cancel();
    socket.destroy();
    notifyListeners();
    return result;
  }

  Future<PairResult> pairWith({
    required String address,
    required int port,
    required String code,
  }) async {
    if (!store.pairingEnabled) {
      debugPrint('NEXUS mesh: pairWith refused (pairing off)');
      return PairResult.failure(
        'Pairing is off on this device. Turn on Mesh pairing in Settings to pair.',
      );
    }
    final cleanCode = code.trim().toUpperCase();
    final key = await derivePairingKey(cleanCode);

    Socket socket;
    try {
      socket = await Socket.connect(
        address,
        port,
        // The injectable timeout, like every other connection this service
        // makes — a hard-coded one cannot be shortened in a test, so the
        // "tries the next address" path could never be covered.
        timeout: connectTimeout,
      );
    } catch (_) {
      return PairResult.failure(
        'Could not reach $address:$port. Is that device on, and are both devices reachable from each other?',
      );
    }

    final completer = Completer<PairResult>();
    final request = NexusMessage(
      type: NexusMessage.pairRequest,
      from: identity.id,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );

    String? pendingEnc;
    try {
      pendingEnc = await encryptToB64(encodeJson(request.toJson()), key);
    } catch (e) {
      socket.destroy();
      return PairResult.failure(
        'Something went wrong preparing the pairing request.',
        reached: true,
      );
    }

    final decoder = FrameDecoder();
    final timeout = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        completer.complete(
          PairResult.failure(
            'No answer from the device. Double-check the code and that it is still showing.',
            reached: true,
          ),
        );
        socket.destroy();
      }
    });

    Future<void> handleChunk(List<int> chunk) async {
      decoder.add(chunk);
      final frames = decoder.takeFrames();
      if (frames == null) return;
      for (final frame in frames) {
        try {
          final json = jsonDecode(utf8.decode(frame));
          if (json is! Map<String, dynamic> || json['enc'] is! String) continue;
          final clear = await decryptFromB64(json['enc'] as String, key);
          final msg = NexusMessage.fromJson(
            jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
          );
          if (msg.type == NexusMessage.pairAccept) {
            debugPrint('NEXUS mesh: pair-accept <- ${msg.from}');
            if (!completer.isCompleted) {
              _paired[msg.from] = PairedDevice(
                id: msg.from,
                name: (msg.payload['name'] as String?) ?? 'Paired device',
                platform: (msg.payload['platform'] as String?) ?? 'other',
                // The address/port we actually reached the peer through —
                // when pairing over a tunnel (adb reverse) this differs
                // from the port the peer announces, and reconnecting on
                // the announced one would hit our own mesh instead.
                address: address,
                port: port,
                pairingSecret: cleanCode,
                lastVerified: DateTime.now(),
              );
              // A re-pair mints a new secret; the key cached under the old one
              // would keep signing frames the peer can no longer read.
              _forgetSessionKey(msg.from);
              store.upsertPaired(_paired[msg.from]!.toJson());
              await store.save();
              _noteSeen(msg.from, verified: true);
              completer.complete(PairResult.ok(_paired[msg.from]!.name));
            }
            return;
          } else if (msg.type == NexusMessage.pairReject) {
            if (!completer.isCompleted) {
              completer.complete(
                PairResult.failure(
                  (msg.payload['reason'] as String?) ??
                      'The device rejected the pairing.',
                  reached: true,
                ),
              );
            }
            return;
          }
        } catch (_) {
          // A frame we cannot decrypt is not from the device showing the
          // code — ignore it and keep waiting for the real answer.
        }
      }
    }

    socket.listen(
      handleChunk,
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete(
            PairResult.failure(
              'The connection to the other device was lost. Check it is '
              'still showing a code, then try again.',
              reached: true,
            ),
          );
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            PairResult.failure(
              'The other device stopped answering before pairing finished. '
              'Check its code is still showing, then try again.',
              reached: true,
            ),
          );
        }
      },
    );

    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': pendingEnc})));
      await socket.flush();
    } catch (_) {
      timeout.cancel();
      socket.destroy();
      return PairResult.failure(
        'Could not send the pairing request.',
        reached: true,
      );
    }

    final result = await completer.future;
    timeout.cancel();
    socket.destroy();
    debugPrint('NEXUS mesh: pairWith -> ${result.ok ? 'ok' : result.error}');
    notifyListeners();
    return result;
  }

  Future<void> forgetDevice(String id) async {
    _paired.remove(id);
    _sessionKeys.remove(id);
    // A forgotten device must not keep a control key or a version in this
    // process: `controlKeyFor` already answers null without the pair, but a
    // cached secret outliving the pairing is exactly the kind of leftover the
    // next pass would trust by accident.
    _controlKeys.remove(id);
    _peerVersions.remove(id);
    _clipboardDeliveredTo.remove(id);
    _nearby.remove(id); // a forgotten device must not linger as a ghost
    _lastSeen.remove(id);
    _verified.remove(id);
    store.removePaired(id);
    await store.save();
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    // Mutate the live identity (announcements and heartbeats read it every
    // few seconds) so the new name reaches every paired device without a
    // restart, then persist it.
    identity.name = sanitizeDeviceName(name);
    store.setIdentity(identity);
    await store.save();
    notifyListeners();
  }

  Future<void> renamePairedDevice(String id, String name) async {
    final device = _paired[id];
    if (device == null) return;
    device.name = sanitizeDeviceName(name);
    device.localName = true;
    store.upsertPaired(device.toJson());

    await store.save();
    notifyListeners();
  }
}
