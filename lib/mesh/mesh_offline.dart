part of 'mesh_service.dart';

/// Offline pairing, end to end: the identity this device keeps, the two
/// sessions a person drives from the pair sheet, and the one call that turns a
/// confirmed offer into a paired device.
///
/// No socket is opened in this mixin. That is the point: the two devices
/// exchange QR strings and nothing else, so the flow works in airplane mode and
/// in a test with the network switched off. What it produces is the same kind
/// of secret every other pairing produces, so file transfer, knowledge sync and
/// control requests work unchanged once it is confirmed.
mixin _MeshOffline on _MeshBase {
  PairingIdentity? _offlineIdentity;
  OfflineIdentityStore? _offlineStoreOverride;
  final OfflineNonceGuard _offlineNonces = OfflineNonceGuard();

  /// Test seam: keep the identity in memory instead of the app store.
  @visibleForTesting
  void useOfflineIdentityStoreForTest(OfflineIdentityStore store) {
    _offlineStoreOverride = store;
    _offlineIdentity = null;
  }

  OfflineIdentityStore get _offlineStore =>
      _offlineStoreOverride ?? _StoreOfflineIdentity(store);

  /// This device's long-term identity for offline pairing: generated the first
  /// time it is asked for, kept for every pairing after that.
  Future<PairingIdentity> offlineIdentity() async {
    final cached = _offlineIdentity;
    if (cached != null) return cached;
    final loaded = await loadOrCreateIdentity(_offlineStore);
    _offlineIdentity = loaded;
    return loaded;
  }

  /// The QR1 this device shows. Carries no address, no port, no network
  /// information of any kind.
  Future<OfflineHostSession> beginOfflinePairing() async {
    final key = await offlineIdentity();
    return OfflineHostSession.begin(
      identity: key,
      deviceId: identity.id,
      deviceName: identity.name,
    );
  }

  /// Answer a scanned or pasted QR1 with this device's QR2, and hold the offer
  /// both screens will compare.
  Future<OfflineGuestSession> answerOfflinePairing(String qr1) async {
    final key = await offlineIdentity();
    return OfflineGuestSession.answer(
      qr1: qr1,
      identity: key,
      deviceId: identity.id,
      deviceName: identity.name,
      guard: _offlineNonces,
    );
  }

  /// Store a pairing both people confirmed, on this device.
  ///
  /// Called only from the "codes match" tap. A mismatch drops the sessions: no
  /// secret, no identity change, no record was written before this call, so
  /// there is nothing to clean up and nothing half-paired.
  ///
  /// [address] and [port] may be empty/zero: an offline pairing is real before
  /// any network path is known. Discovery and presence fill the address in the
  /// first time the two devices meet on a network, and until then the pairing
  /// is listed but not reachable — which is the truth.
  Future<PairedDevice> confirmOfflinePairing(
    OfflinePairingOffer offer, {
    String address = '',
    int port = 0,
  }) async {
    final peer = PairedDevice(
      id: offer.peerDeviceId,
      name: offer.peerName,
      platform: 'other',
      address: address,
      port: port > 0 ? port : store.port,
      pairingSecret: offer.pairingSecret,
      pairingProtocol: offer.version,
      lastVerified: DateTime.now(),
    );
    _paired[peer.id] = peer;
    // A new secret replaces whatever key was cached under this id.
    _forgetSessionKey(peer.id);
    store.upsertPaired(peer.toJson());
    store.logPairingEvent(
      'offline-paired',
      'peer=${peer.id} v=${offer.version}',
    );
    await store.save();
    notifyListeners();
    return peer;
  }

  /// True when this device already holds a pairing with the peer [offer]
  /// describes, made by the offline handshake.
  bool isOfflinePaired(OfflinePairingOffer offer) =>
      _paired[offer.peerDeviceId]?.pairingProtocol == offlinePairingVersion;
}

/// The app's own store as an [OfflineIdentityStore].
///
/// Honest note: this is the same store every other pairing secret already uses
/// in this build. There is no OS-keystore dependency in the tree, and adding
/// one changes every platform build; moving this key to Keystore/libsecret is a
/// separate change and is not claimed by the pairing work.
class _StoreOfflineIdentity implements OfflineIdentityStore {
  final NexusStore store;

  _StoreOfflineIdentity(this.store);

  @override
  Future<Map<String, dynamic>?> read() async {
    final saved = store.offlinePairingIdentity;
    return saved == null ? null : Map<String, dynamic>.of(saved);
  }

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    store.offlinePairingIdentity = identity;
    await store.save();
  }
}
