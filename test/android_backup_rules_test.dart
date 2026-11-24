// The Android backup exclusion is part of the security work, not paperwork:
// the state file holds pairing secrets and the secure-store preference file
// holds the wrapped identity key. If the manifest stops pointing at the rule
// files, or a rule loses a path, the key is back in Google's cloud backup
// without a single test turning red. This checks the three files agree.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _manifest = 'android/app/src/main/AndroidManifest.xml';
const _rules = 'android/app/src/main/res/xml/backup_rules.xml';
const _extraction = 'android/app/src/main/res/xml/data_extraction_rules.xml';

/// Every path that must never be backed up, and the domain it lives in.
const _excluded = <String, String>{
  'nexus/state.json': 'file',
  'nexus.xml': 'sharedpref',
  'FlutterSecureKeyStorage:nexus.xml': 'sharedpref',
};

void main() {
  test('the manifest points at both rule files and keeps backup on', () async {
    final manifest = await File(_manifest).readAsString();
    expect(manifest, contains('android:allowBackup="true"'));
    expect(
      manifest,
      contains('android:fullBackupContent="@xml/backup_rules"'),
      reason: 'API < 31 reads fullBackupContent',
    );
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      reason: 'API 31+ reads dataExtractionRules',
    );
  });

  test('the pre-31 rules exclude the state file and the secure store',
      () async {
    final rules = File(_rules);
    expect(await rules.exists(), isTrue);
    final text = await rules.readAsString();
    expect(text, contains('<full-backup-content>'));
    for (final entry in _excluded.entries) {
      expect(
        text,
        contains('<exclude domain="${entry.value}" path="${entry.key}" />'),
        reason: '${entry.key} must be excluded from pre-31 backups',
      );
    }
  });

  test('the 31+ rules exclude the same paths from backup AND transfer',
      () async {
    final rules = File(_extraction);
    expect(await rules.exists(), isTrue);
    final text = await rules.readAsString();
    expect(text, contains('<cloud-backup>'));
    expect(text, contains('<device-transfer>'));
    for (final section in ['cloud-backup', 'device-transfer']) {
      final start = text.indexOf('<$section>');
      final end = text.indexOf('</$section>');
      expect(start, greaterThanOrEqualTo(0), reason: '$section missing');
      final body = text.substring(start, end);
      for (final entry in _excluded.entries) {
        expect(
          body,
          contains('<exclude domain="${entry.value}" path="${entry.key}" />'),
          reason: '${entry.key} must be excluded from $section',
        );
      }
    }
  });

  test('the secure store namespace the rules name is the one the code uses',
      () async {
    // The preference file name comes from AndroidOptions.storageNamespace.
    // Renaming one without the other would silently un-exclude the store.
    final source = await File('lib/core/identity_seed_store.dart').readAsString();
    expect(source, contains("storageNamespace = 'nexus'"));
    expect(source, contains('storageNamespace: storageNamespace'));
    expect(
      source,
      contains("storageKey = 'nexus.identity.v1'"),
      reason: 'versioned key, so a v2 can never misread v1 bytes',
    );
  });
}
