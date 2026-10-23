import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/paired_devices.dart';

/// A brain that counts what it was asked, answers with a fixed line, and can be
/// told to fail the way a PC that left the Wi-Fi fails.
class _FakeBrain implements LocalAiService {
  _FakeBrain(this.reply);

  final String reply;
  int calls = 0;
  bool fail = false;

  @override
  Future<String> generateResponse(String prompt) async {
    calls++;
    if (fail) throw StateError('the PC left the network');
    return reply;
  }

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    calls++;
    if (fail) throw StateError('the PC left the network');
    yield reply;
  }
}

/// The paired desktop the router is allowed to use.
const PairedDevice _pc = PairedDevice(
  id: 'studio-pc',
  name: 'Studio PC',
  publicKey: 'key',
  platform: 'linux',
  addresses: <String>['192.168.1.10'],
);

const PairedDevice _thisPhone = PairedDevice(
  id: 'this-phone',
  name: 'This Phone',
  publicKey: '',
  isThisDevice: true,
  platform: 'android',
);

/// [router] with the desktop in the list and a probe that answers [online].
HiveRouter _router({
  required _FakeBrain pc,
  required _FakeBrain device,
  bool online = true,
}) => HiveRouter(
  onDevice: device,
  pc: pc,
  paired: () => const <PairedDevice>[_thisPhone, _pc],
  pcProbe: () async => online,
);

void main() {
  tearDown(() {
    HiveRouter.debugReset();
    LocalAiService.override = null;
    LocalAiService.resetDefault();
    ModelChoice.override = null;
    ModelChoice.debugReset();
  });

  test('a reachable paired PC answers and the phone is not asked', () async {
    final _FakeBrain pc = _FakeBrain('from the PC');
    final _FakeBrain device = _FakeBrain('from the phone');
    final HiveRouter router = _router(pc: pc, device: device);

    expect(await router.generateResponse('hello'), 'from the PC');
    expect(pc.calls, 1);
    expect(device.calls, 0, reason: 'the bigger model answered first');
    expect(HiveRouter.compute.value, HiveCompute.pc);

    // Streaming takes the same route, and the whole answer arrives as one
    // piece because that is what the PC's Ollama does today.
    expect(await router.generateResponseStream('again').toList(), <String>[
      'from the PC',
    ]);
    expect(device.calls, 0);
  });
  test(
    'a PC that fails mid-answer falls back to the device and says so',
    () async {
      // On the 1B there is no upgrade banner in the way: this test is about the
      // pill the route change puts in the conversation.
      ModelChoice.override = () => ModelChoice(
        store: MemoryModelChoiceStore(),
        initial: OnDeviceModelChoice.llama,
      );
      final _FakeBrain pc = _FakeBrain('never arrives')..fail = true;
      final _FakeBrain device = _FakeBrain('from the phone');
      final List<HiveNotice> notices = <HiveNotice>[];
      final StreamSubscription<HiveNotice> sub = HiveRouter.notices.listen(
        notices.add,
      );
      addTearDown(sub.cancel);
      final HiveRouter router = _router(pc: pc, device: device);

      // The whole PC turn is collected before it is shown, so a failure leaves
      // one clean device answer rather than half of each brain.
      expect(await router.generateResponseStream('hello').toList(), <String>[
        'from the phone',
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(notices, <HiveNotice>[HiveNotice.pcDisconnected]);
      expect(HiveRouter.compute.value, HiveCompute.onDevice);
    },
  );

  test(
    'the upgrade banner is raised once, and only for the small model',
    () async {
      ModelChoice.override = () => ModelChoice(store: MemoryModelChoiceStore());
      final List<HiveNotice> notices = <HiveNotice>[];
      final StreamSubscription<HiveNotice> sub = HiveRouter.notices.listen(
        notices.add,
      );
      addTearDown(sub.cancel);
      final HiveRouter router = _router(
        pc: _FakeBrain('from the PC'),
        device: _FakeBrain('from the phone'),
      );

      expect(await router.refresh(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(notices, <HiveNotice>[HiveNotice.pcConnectedWeakModel]);

      // The cache answers the second call without a second banner: this is a
      // one-time notice, not a status line.
      expect(await router.refresh(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(notices, <HiveNotice>[HiveNotice.pcConnectedWeakModel]);

      // A user already on the 1B model gains nothing the banner can name.
      HiveRouter.debugReset();
      ModelChoice.override = () => ModelChoice(
        store: MemoryModelChoiceStore(),
        initial: OnDeviceModelChoice.llama,
      );
      final HiveRouter stronger = _router(
        pc: _FakeBrain('from the PC'),
        device: _FakeBrain('from the phone'),
      );
      expect(await stronger.refresh(force: true), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(notices, <HiveNotice>[HiveNotice.pcConnectedWeakModel]);
    },
  );
}
