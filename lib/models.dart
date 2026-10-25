import 'dart:convert';

class AlarmSound {
  final String type; // default, system, mp3
  final String value;
  final String label;
  const AlarmSound(this.type, this.value, this.label);
  Map<String, dynamic> toJson() => {'type': type, 'value': value, 'label': label};
  factory AlarmSound.fromJson(dynamic data) {
    if (data is! Map) return const AlarmSound('default', '', 'Standardton');
    return AlarmSound('${data['type'] ?? 'default'}', '${data['value'] ?? ''}', '${data['label'] ?? 'Standardton'}');
  }
}

class TagData {
  String name;
  AlarmSound? sound;
  List<int>? minutes;
  /// Optional HH:mm time used only when importing NEW reminders from photos.
  /// Existing reminder tags are never recalculated from this property.
  String? startTime;
  TagData({required this.name, this.sound, this.minutes, this.startTime});
  Map<String, dynamic> toJson() => {
    'name': name,
    'sound': sound?.toJson(),
    'minutes': minutes,
    'startTime': startTime,
  };
  factory TagData.fromJson(Map<String, dynamic> m) => TagData(
    name: m['name'] as String? ?? '',
    sound: m['sound'] == null ? null : AlarmSound.fromJson(m['sound']),
    minutes: (m['minutes'] as List?)?.map((x) => (x as num).toInt()).toList(),
    startTime: normalizeTagStartTime(m['startTime'] as String?),
  );
}

/// Accepts a 24-hour HH:mm string; older saved tags without one remain null.
String? normalizeTagStartTime(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Match only the START clock time, not the day or the end time.
/// Call this only when creating a new reminder from a photo/gallery import.
/// Multiple matching tags are supported; existing reminders remain untouched.
List<String> tagsMatchingImportedStart(DateTime at, Iterable<TagData> configuredTags) {
  final clock = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final result = <String>[];
  final seen = <String>{};
  for (final tag in configuredTags) {
    if (tag.startTime != clock) continue;
    final normalized = normalizedTag(tag.name);
    if (normalized.isEmpty || !seen.add(normalized.toLowerCase())) continue;
    result.add(normalized);
  }
  return result;
}

class Reminder {
  int id;
  DateTime at;
  String title;
  List<String> tags;
  bool repeat;
  String unit;
  int every;
  List<int> weekdays;
  AlarmSound? sound;
  List<int>? minutes;
  // Null means that the appointment has no known end time. A duration
  // (instead of a fixed end datetime) also works for repeating appointments.
  int? durationMinutes;

  Reminder({required this.id, required this.at, required this.title,
    this.tags = const [], this.repeat = false, this.unit = 'days',
    this.every = 1, this.weekdays = const [], this.sound, this.minutes,
    this.durationMinutes});

  /// Supports previously imported photo reminders whose title started with
  /// '12:00-12:30 ...', even if they were saved before durationMinutes existed.
  /// If no valid end time is known, return null rather than assuming zero time.
  int? get effectiveDurationMinutes => durationMinutes == 0
      ? null // Explicitly cleared by the user; do not re-read the old OCR title.
      : durationMinutes != null && durationMinutes! > 0 && durationMinutes! <= 1440
          ? durationMinutes
          : durationFromLegacyTitle(at, title);

  Map<String, dynamic> toJson() => {
    'id': id, 'at': at.toIso8601String(), 'title': title, 'tags': tags,
    'repeat': repeat, 'unit': unit, 'every': every, 'weekdays': weekdays,
    'sound': sound?.toJson(), 'minutes': minutes,
    'durationMinutes': durationMinutes == 0 ? 0 : effectiveDurationMinutes,
  };
  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
    id: (j['id'] as num).toInt(),
    at: DateTime.parse(j['at'] as String),
    title: j['title'] as String? ?? '',
    tags: (j['tags'] as List? ?? []).map((e) => '$e').toList(),
    repeat: j['repeat'] as bool? ?? false,
    unit: j['unit'] as String? ?? 'days',
    every: (j['every'] as num?)?.toInt() ?? 1,
    weekdays: (j['weekdays'] as List? ?? []).map((e) => (e as num).toInt()).toList(),
    sound: j['sound'] == null ? null : AlarmSound.fromJson(j['sound']),
    minutes: (j['minutes'] as List?)?.map((e) => (e as num).toInt()).toList(),
    durationMinutes: (j['durationMinutes'] as num?)?.toInt(),
  );

  List<DateTime> occurrences(DateTime from, DateTime until, {int limit = 500}) {
    final output = <DateTime>[];
    void add(DateTime dt) {
      if (!dt.isBefore(from) && !dt.isAfter(until) && output.length < limit) output.add(dt);
    }
    if (!repeat) { add(at); return output; }
    final count = every < 1 ? 1 : every;
    final filter = weekdays.toSet();
    if (unit == 'hours') {
      final distance = from.difference(at).inHours;
      var step = distance > 0 ? (distance ~/ count - 1).clamp(0, 100000000).toInt() : 0;
      for (var i = 0; i < 4000 && output.length < limit; i++, step++) {
        final dt = at.add(Duration(hours: step * count));
        if (dt.isAfter(until)) break;
        if (filter.isEmpty || filter.contains(dt.weekday)) add(dt);
      }
    } else if (unit == 'weeks') {
      final monday = DateTime(at.year, at.month, at.day - (at.weekday - 1));
      final days = filter.isEmpty ? [at.weekday] : filter.toList()..sort();
      final weeks = from.difference(monday).inDays ~/ 7;
      var block = weeks > 0 ? (weeks ~/ count - 1).clamp(0, 10000000).toInt() : 0;
      for (var i = 0; i < 500 && output.length < limit; i++, block++) {
        final start = DateTime(monday.year, monday.month, monday.day + block * count * 7);
        if (start.isAfter(until)) break;
        for (final day in days) {
          final dt = DateTime(start.year, start.month, start.day + day - 1,
              at.hour, at.minute);
          if (!dt.isBefore(at)) add(dt);
        }
      }
    } else {
      final days = from.difference(DateTime(at.year, at.month, at.day)).inDays;
      var step = days > 0 ? (days ~/ count - 1).clamp(0, 100000000).toInt() : 0;
      for (var i = 0; i < 4000 && output.length < limit; i++, step++) {
        final dt = DateTime(at.year, at.month, at.day + step * count, at.hour, at.minute);
        if (dt.isAfter(until)) break;
        if (filter.isEmpty || filter.contains(dt.weekday)) add(dt);
      }
    }
    output.sort();
    return output;
  }
}

String encodeReminders(List<Reminder> reminders) =>
    jsonEncode(reminders.map((e) => e.toJson()).toList());

/// Minutes before a reminder, separated by commas, for example '30, 15, 5'.
/// Supports one or multiple distinct, non-negative whole-minute values.
/// Keep the limit in sync with ReminderRuntime.MAX_OFFSETS on Android.
const int maxNotificationOffsets = 32;
const int maxNotificationMinutes = 525600;

List<int>? parseMinutes(String text) {
  final parts = text.split(',');
  if (parts.isEmpty || parts.length > maxNotificationOffsets) return null;
  final result = <int>[];
  final seen = <int>{};
  for (final raw in parts) {
    final part = raw.trim();
    if (!RegExp(r'^\d+$').hasMatch(part)) return null;
    final minutes = int.tryParse(part);
    if (minutes == null || minutes > maxNotificationMinutes || !seen.add(minutes)) {
      return null;
    }
    result.add(minutes);
  }
  return result;
}

String normalizedTag(String input) => input.trim().replaceFirst(RegExp(r'^#+'), '').trim();
const weekdaysShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

/// The legacy OCR format starts with the start and end clock times. The start
/// must agree with the stored start time, otherwise a user-edited title must
/// not be mistaken for the actual appointment time.
int? durationFromLegacyTitle(DateTime start, String title) {
  final m = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*[-–—]\s*(\d{1,2})[:.](\d{2})(?!\d)')
      .firstMatch(title);
  if (m == null) return null;
  final sh = int.parse(m.group(1)!);
  final sm = int.parse(m.group(2)!);
  final eh = int.parse(m.group(3)!);
  final em = int.parse(m.group(4)!);
  if (sh > 23 || eh > 23 || sm > 59 || em > 59 ||
      sh != start.hour || sm != start.minute) return null;
  final startMinutes = sh * 60 + sm;
  final endMinutes = eh * 60 + em;
  final difference = (endMinutes - startMinutes + 1440) % 1440;
  return difference == 0 ? null : difference;
}
