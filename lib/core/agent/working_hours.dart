// The hours a user actually used something, read off a local usage log.
//
// "Will it work all the time?" is answered with what the log says, not with a
// model's guess: the assistant offers the hours the person is already active,
// and they choose. No clock arithmetic library and no scheduling here — this
// file only turns timestamps into a window.
class WorkingHours {
  const WorkingHours({
    required this.startHour,
    required this.endHour,
    required this.weekdays,
  });

  final int startHour;

  /// Exclusive: 18 means "until 18:00".
  final int endHour;

  /// True when the weekend is nearly unused, so the offer can say weekdays.
  final bool weekdays;

  /// "09:00–18:00 on weekdays".
  String get label =>
      '${_two(startHour)}:00–${_two(endHour)}:00'
      '${weekdays ? ' on weekdays' : ''}';

  static String _two(int hour) => hour.toString().padLeft(2, '0');
}

/// The window [usage] falls into, or null when there is no log to learn from.
///
/// Deliberately simple: the earliest and latest hour anything happened, and
/// "weekdays" only when the weekend is under a tenth of the log. A tidier
/// clustering would be a nicer number and a worse explanation — this is the
/// one the reply can describe in a sentence.
WorkingHours? suggestWorkingHours(List<DateTime> usage) {
  if (usage.isEmpty) return null;
  var earliest = 23;
  var latest = 0;
  var weekend = 0;
  for (final at in usage) {
    if (at.hour < earliest) earliest = at.hour;
    if (at.hour + 1 > latest) latest = at.hour + 1;
    if (at.weekday > DateTime.friday) weekend++;
  }
  return WorkingHours(
    startHour: earliest,
    endHour: latest,
    weekdays: weekend * 10 <= usage.length,
  );
}
