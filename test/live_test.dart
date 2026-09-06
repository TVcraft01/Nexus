import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/live.dart';
import 'package:nexus/core/timezones.dart';

void main() {
  group('Deezer search parsing', () {
    test('a top hit extracts title, artist and link', () {
      const body = '''
      {"data":[{"id":1,"title":"Hotline Bling",
        "artist":{"name":"Drake"},"link":"https://deezer.page.link/x"}]}
      ''';
      final hit = parseDeezerHit(body);
      expect(hit, isNotNull);
      expect(hit!.title, 'Hotline Bling');
      expect(hit.artist, 'Drake');
      expect(hit.url, 'https://deezer.page.link/x');
    });

    test('empty or malformed payloads return null — never a fake hit', () {
      expect(parseDeezerHit('{"data":[]}'), isNull);
      expect(parseDeezerHit('not json'), isNull);
      expect(parseDeezerHit('{"data":[{"title":"no link"}]}'), isNull);
    });
  });

  group('currency rate parsing', () {
    test('extracts the requested rate', () {
      const body = '{"base":"USD","date":"2026-09-06","rates":{"EUR":0.92}}';
      expect(parseRate(body, 'eur'), 0.92);
      expect(parseRate(body, 'EUR'), 0.92);
    });

    test('missing or malformed rates return null', () {
      expect(parseRate('{"rates":{"GBP":0.8}}', 'eur'), isNull);
      expect(parseRate('not json', 'eur'), isNull);
    });
  });

  group('zone time parsing', () {
    test('extracts HH:mm and the abbreviation', () {
      const body = '''
      {"datetime":"2026-09-06T15:42:00.123456+09:00","abbreviation":"JST"}
      ''';
      expect(parseZoneTime(body), ('15:42', 'JST'));
    });

    test('malformed payloads return null', () {
      expect(parseZoneTime('{"datetime":"short"}'), isNull);
      expect(parseZoneTime('not json'), isNull);
    });
  });

  group('timezone map', () {
    test('curated cities and countries resolve to IANA zones', () {
      expect(zoneForCity('Tokyo'), 'Asia/Tokyo');
      expect(zoneForCity('new york'), 'America/New_York');
      expect(zoneForCity('São Paulo'), 'America/Sao_Paulo');
      expect(zoneForCity('paris'), 'Europe/Paris');
      expect(zoneForCity('japan'), 'Asia/Tokyo');
      expect(zoneForCity('MONACO'), 'Europe/Monaco');
    });

    test('unmapped places return null — the caller never guesses', () {
      expect(zoneForCity('atlantis'), isNull);
      expect(zoneForCity('lille'), isNull);
    });
  });
}