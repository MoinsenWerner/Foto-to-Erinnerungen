import 'dart:math' as math;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class ParsedEntry {
  final DateTime at;
  final String weekday;
  String title;
  final int durationMinutes;
  bool selected = true;
  ParsedEntry(this.at, this.weekday, this.title, this.durationMinutes);
}

class _Row {
  final double top;
  final double bottom;
  final String text;
  _Row(this.top, this.bottom, this.text);
  double get center => (top + bottom) / 2;
}

final _day = RegExp(r'\b(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag)\b', caseSensitive: false);
final _times = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*[-–—~]?\s*(\d{1,2})[:.](\d{2})(?!\d)');
final _days = <String, int>{
  'montag': 1, 'dienstag': 2, 'mittwoch': 3, 'donnerstag': 4,
  'freitag': 5, 'samstag': 6, 'sonntag': 7,
};

/// Reconstruct physical text rows using ML Kit line bounding boxes.
/// Weekdays belong to all subsequent rows until a new weekday is encountered.
Future<List<ParsedEntry>> recognizePlan(String imagePath, DateTime now) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  late final RecognizedText result;
  try {
    result = await recognizer.processImage(InputImage.fromFilePath(imagePath));
  } finally {
    await recognizer.close();
  }
  final lines = [for (final block in result.blocks) ...block.lines];
  lines.sort((a, b) {
    final cy = a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy);
    return cy != 0 ? cy : a.boundingBox.left.compareTo(b.boundingBox.left);
  });
  // Group cells that occupy the same physical row. This handles split time/title OCR cells.
  final groups = <List<TextLine>>[];
  for (final line in lines) {
    final centerY = line.boundingBox.center.dy;
    final tolerance = math.max(5.0, line.boundingBox.height * 0.42);
    if (groups.isNotEmpty) {
      final last = groups.last;
      final mean = last.map((e) => e.boundingBox.center.dy).reduce((a, b) => a + b) / last.length;
      if ((centerY - mean).abs() <= tolerance) {
        last.add(line);
        continue;
      }
    }
    groups.add([line]);
  }
  final rows = <_Row>[];
  for (final group in groups) {
    group.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    rows.add(_Row(
      group.map((e) => e.boundingBox.top).reduce(math.min),
      group.map((e) => e.boundingBox.bottom).reduce(math.max),
      group.map((e) => e.text.trim()).where((s) => s.isNotEmpty).join(' '),
    ));
  }
  rows.sort((a, b) => a.center.compareTo(b.center));

  final parsed = <ParsedEntry>[];
  int? currentWeekday;
  String currentWeekdayName = '';
  for (final row in rows) {
    var content = row.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final foundDay = _day.firstMatch(content);
    if (foundDay != null) {
      final label = foundDay.group(1)!;
      currentWeekday = _days[label.toLowerCase()];
      currentWeekdayName = label;
      content = content.replaceFirst(foundDay.group(0)!, '').trim();
    }
    final foundTime = _times.firstMatch(content);
    if (foundTime != null && currentWeekday != null) {
      final h1 = int.parse(foundTime.group(1)!);
      final m1 = int.parse(foundTime.group(2)!);
      final h2 = int.parse(foundTime.group(3)!);
      final m2 = int.parse(foundTime.group(4)!);
      if (h1 > 23 || h2 > 23 || m1 > 59 || m2 > 59) continue;
      final distance = (currentWeekday - now.weekday + 7) % 7;
      final date = DateTime(now.year, now.month, now.day + distance, h1, m1);
      final rest = content.substring(foundTime.end).trim();
      final title = '${_clock(h1, m1)}–${_clock(h2, m2)}${rest.isEmpty ? '' : ' $rest'}';
      // Account for appointments spanning midnight, e.g. 23:30-00:30.
      final duration = ((h2 * 60 + m2) - (h1 * 60 + m1) + 1440) % 1440;
      if (duration == 0) continue;
      parsed.add(ParsedEntry(date, currentWeekdayName, title, duration));
      continue;
    }
    // Wrapped text belongs to preceding appointment if no new weekday starts.
    // Exclude headings and page labels; preview allows manual correction.
    if (foundDay == null && parsed.isNotEmpty && content.isNotEmpty &&
        !RegExp(r'^(Termine|Wochentag|Name:|Seite\s+\d+)', caseSensitive: false).hasMatch(content)) {
      final item = parsed.last;
      if (content.length < 150 && item.title.length + content.length < 250) {
        item.title = '${item.title} $content';
      }
    }
  }
  return parsed;
}

String _clock(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
