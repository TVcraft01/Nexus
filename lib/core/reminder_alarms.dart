// The reminder's second half: firing when the app is not looking.
//
// The engine's own timer covers the app-open case (a 15-second tick). This
// bridge covers the rest on Android: every pending reminder is also handed
// to AlarmManager as an exact alarm, so a reminder set at noon still rings
// at 6pm when Nexus spent the afternoon closed. The alarm's receiver posts
// the notification itself — by the time Dart runs again the moment has
// passed, and the engine's startup check then only marks the reminder spent
// and says it in the thread.
//
// Both paths post under one stable notification id per reminder, so the
// alarm firing while the app is open does not double up: the second post
// replaces the first. Every call is best-effort and silent off Android —
// no channel, no permission, no alarm, and the engine's timer is the whole
// story. Tests drive this through the channel mock; nothing here owns
// state beyond the synced id set.
import 'package:flutter/services.dart' show MethodChannel;

import 'reminders.dart';

/// Schedules exact Android alarms and posts reminder notifications through
/// the `dev.nexus.nexus/reminders` channel (see ReminderAlarms.kt).
class ReminderAlarms {
  ReminderAlarms({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.nexus.nexus/reminders');

  final MethodChannel _channel;

  /// Reminder ids synced to AlarmManager. Sync is idempotent: scheduling
  /// the same id replaces its alarm, and ids that left the pending set are
  /// cancelled so a deleted reminder cannot ring.
  final Set<String> _synced = {};

  /// One stable notification id per reminder, shared by the alarm receiver
  /// and the in-app post — computed in Dart so both sides agree without a
  /// round trip.
  static int notificationId(String id) => id.hashCode & 0x7fffffff;

  /// Hands every pending reminder to AlarmManager and cancels alarms whose
  /// reminders are gone or spent. Called on every engine change and at
  /// startup; each schedule replaces the previous one for that id.
  Future<void> sync(Iterable<Reminder> reminders) async {
    final pending = <String, Reminder>{};
    for (final reminder in reminders) {
      if (!reminder.fired) pending[reminder.id] = reminder;
    }
    for (final id in _synced.toList()) {
      if (!pending.containsKey(id)) {
        _synced.remove(id);
        await _call('cancelReminder', {'id': id});
      }
    }
    for (final reminder in pending.values) {
      _synced.add(reminder.id);
      await _call('scheduleReminder', {
        'id': reminder.id,
        'notificationId': notificationId(reminder.id),
        'text': reminder.text,
        'triggerAtMillis': reminder.dueAt.millisecondsSinceEpoch,
      });
    }
  }

  /// Posts the reminder notification now — the in-app half of the fire,
  /// beside the thread message. Same id the alarm would post under.
  Future<void> notifyNow(Reminder reminder) async {
    await _call('showReminderNotification', {
      'id': reminder.id,
      'notificationId': notificationId(reminder.id),
      'text': reminder.text,
    });
  }

  /// Forgets everything without touching the platform: the engine was
  /// disposed (tests, logout) and no alarm state may linger past it.
  void reset() => _synced.clear();

  /// One guarded channel call. A missing channel (desktop, tests without a
  /// mock) or a denied permission is silence, never a throw — the engine's
  /// timer still fires while the app is open.
  Future<void> _call(String method, Map<String, dynamic> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // No bridge, no alarm — the in-app timer is the fallback.
    }
  }
}
