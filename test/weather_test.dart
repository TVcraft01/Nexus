import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/weather.dart';

void main() {
  group('formatWttr', () {
    test('formats current conditions with temperature and description', () {
      const body = '''
      {"current_condition":[{"temp_C":"18","FeelsLikeC":"17",
        "weatherDesc":[{"value":"Partly cloudy"}],"humidity":"64"}],
       "weather":[{"date":"2026-09-06","maxtempC":"22","mintempC":"12",
         "hourly":[{"chanceofrain":"10"}]}]}
      ''';
      final line = formatWttr(body, place: 'Paris');
      expect(line, contains("In Paris it's 18°C"));
      expect(line, contains('feels like 17°C'));
      expect(line, contains('Partly cloudy'));
    });

    test('omits the feels-like when it equals the temperature', () {
      const body = '''
      {"current_condition":[{"temp_C":"20","FeelsLikeC":"20",
        "weatherDesc":[{"value":"Sunny"}]}],
       "weather":[{"hourly":[]}]}
      ''';
      final line = formatWttr(body, place: 'Lyon');
      expect(line, contains("it's 20°C"));
      expect(line, isNot(contains('feels like')));
    });

    test('rain kind reports the peak chance-of-rain honestly', () {
      const body = '''
      {"current_condition":[{"temp_C":"15","FeelsLikeC":"14",
        "weatherDesc":[{"value":"Cloudy"}]}],
       "weather":[{"hourly":[
         {"chanceofrain":"10"},{"chanceofrain":"60"},{"chanceofrain":"40"}
       ]}]}
      ''';
      final line = formatWttr(body, place: 'Brest', kind: 'rain');
      expect(line, contains('up to a 60% chance of rain'));
    });

    test('rain kind with zero chances says no rain', () {
      const body = '''
      {"current_condition":[{"temp_C":"22","FeelsLikeC":"22",
        "weatherDesc":[{"value":"Clear"}]}],
       "weather":[{"hourly":[{"chanceofrain":"0"},{"chanceofrain":"0"}]}]}
      ''';
      final line = formatWttr(body, place: 'Nice', kind: 'rain');
      expect(line, contains('no rain is forecast'));
    });

    test('a malformed payload returns null — never a fake forecast', () {
      expect(formatWttr('not json', place: 'Paris'), isNull);
      expect(formatWttr('{"no":"current_condition"}', place: 'Paris'), isNull);
      expect(formatWttr('', place: 'Paris'), isNull);
    });

    test('an empty place names the area wttr.in actually resolved', () {
      const body = '''
      {"nearest_area":[{"areaName":[{"value":"Montpellier"}],
        "country":[{"value":"France"}]}],
       "current_condition":[{"temp_C":"24","FeelsLikeC":"24",
        "weatherDesc":[{"value":"Sunny"}]}],
       "weather":[{"hourly":[{"chanceofrain":"0"}]}]}
      ''';
      // Place given: the caller's spelling wins, never wttr.in's.
      final named = formatWttr(body, place: 'Lyon');
      expect(named, contains('In Lyon'));
      // No place (location/IP fetch): the resolved area is named honestly.
      final auto = formatWttr(body, place: '');
      expect(auto, contains('In Montpellier'));
      // Rain variant uses the same resolved name.
      final rain = formatWttr(body, place: '', kind: 'rain');
      expect(rain, contains('In Montpellier'));
    });
  });
}