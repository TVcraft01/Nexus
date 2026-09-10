import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/profile.dart';

void main() {
  test(
    'memory profile store round-trips names and the onboarded flag',
    () async {
      final store = MemoryProfileStore();
      expect((await store.read()).userName, isNull);
      expect((await store.read()).assistantName, 'Nexus');
      expect((await store.read()).onboarded, isFalse);

      await store.save(
        const UserProfile(
          userName: 'Sam',
          assistantName: 'Sophie',
          onboarded: true,
        ),
      );
      final p = await store.read();
      expect(p.userName, 'Sam');
      expect(p.assistantName, 'Sophie');
      expect(p.onboarded, isTrue);

      // copyWith keeps the rest when only one field changes.
      final renamed = p.copyWith(assistantName: 'Nexus');
      expect(renamed.userName, 'Sam');
      expect(renamed.assistantName, 'Nexus');
      expect(renamed.onboarded, isTrue);
    },
  );
}
