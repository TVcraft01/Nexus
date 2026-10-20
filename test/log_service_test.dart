import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LogService.debugReset();
  });

  tearDown(LogService.debugReset);

  test('keeps only the newest 500 lines', () {
    final LogService log = LogService();
    for (int i = 0; i < 600; i++) {
      log.log('line $i');
    }
    expect(log.length, kLogLineLimit);
    expect(log.lines.first.text, 'line 100');
    expect(log.lines.last.text, 'line 599');
  });

  test('a multi-line message is counted as lines, not as one call', () {
    final LogService log = LogService();
    log.log('one\ntwo\n\nthree');
    expect(log.lines.map((LogLine line) => line.text), <String>[
      'one',
      'two',
      'three',
    ]);
    expect(log.exportText(), contains('one'));
    expect(log.exportText(), contains('three'));
  });

  test('clear empties the page without touching the unlock', () async {
    final LogService log = LogService();
    await log.unlockDeveloperMode();
    log.log('something');
    log.clear();
    expect(log.isEmpty, isTrue);
    expect(log.developerUnlocked, isTrue);
  });

  test('developer mode survives a restart', () async {
    final LogService first = LogService();
    await first.attach();
    expect(first.developerUnlocked, isFalse);
    await first.unlockDeveloperMode();

    final LogService second = LogService();
    await second.attach();
    expect(second.developerUnlocked, isTrue);
  });
}
