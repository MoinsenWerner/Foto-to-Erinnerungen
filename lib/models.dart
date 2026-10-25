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
  TagData({required this.name, this.sound, this.minutes});
  Map<String, dynamic> toJson() => {
    'name': name,
    'sound': sound?.toJson(),
    'minutes': minutes,
  };
  factory TagData.fromJson(Map<String, dynamic> m) => TagData(
    name: m['name'] as String? ?? '',
    sound: m['sound'] == null ? null : AlarmSound.fromJson(m['sound']),
    minutes: (m['minutes'] as List?)?.map((x) => (x as num).toInt()).toList(),
  );
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

  Reminder({required this.id, required this.at, required this.title,
    this.tags = const [], this.repeat = false, this.unit = 'days',
    this.every = 1, this.weekdays = const [], this.sound, this.minutes});

  Map<String, dynamic> toJson() => {
    'id': id, 'at': at.toIso8601String(), 'title': title, 'tags': tags,
    'repeat': repeat, 'unit': unit, 'every': every, 'weekdays': weekdays,
    'sound': sound?.toJson(), 'minutes': minutes,
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

List<int>? parseMinutes(String text) {
  final parts = text.split(RegExp(r'[,; ]+')).where((e) => e.trim().isNotEmpty).toList();
  if (parts.length != 2) return null;
  final values = parts.map((e) => int.tryParse(e)).toList();
  if (values.any((n) => n == null || n < 0 || n > 1440)) return null;
  if (values[0] == values[1]) return null;
  return [values[0]!, values[1]!];
}

String normalizedTag(String input) => input.trim().replaceFirst(RegExp(r'^#+'), '').trim();
const weekdaysShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
