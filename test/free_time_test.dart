import 'package:flutter_test/flutter_test.dart';
import 'package:foto_to_erinnerung/models.dart';
import 'package:foto_to_erinnerung/free_time.dart';

Reminder reminder(int id, int day, int hour, int minute, int? duration,
    {String title = 'Termin'}) => Reminder(
      id: id,
      at: DateTime(2026, 10, day, hour, minute),
      title: title,
      durationMinutes: duration,
    );

void main() {
  test('Requested example: only 14:00-14:30, adjacent slots are merged', () {
    final day = DateTime(2026, 10, 22);
    final result = calculateFreeTime([
      reminder(1, 22, 12, 0, 30),
      reminder(2, 22, 12, 30, 90),
      reminder(3, 22, 14, 30, 45),
    ], day, day);
    expect(result.gaps.length, 1);
    expect(result.gaps.first.start, DateTime(2026, 10, 22, 14, 0));
    expect(result.gaps.first.end, DateTime(2026, 10, 22, 14, 30));
    expect(result.gaps.first.duration.inMinutes, 30);
  });

  test('Overlapping appointments merge into a single occupied block', () {
    final day = DateTime(2026, 10, 22);
    final result = calculateFreeTime([
      reminder(1, 22, 10, 0, 120),
      reminder(2, 22, 11, 0, 120),
      reminder(3, 22, 13, 30, 30),
    ], day, day);
    expect(result.gaps.length, 1);
    expect(result.gaps.single.start.hour, 13);
    expect(result.gaps.single.start.minute, 0);
    expect(result.gaps.single.end.minute, 30);
  });

  test('Unknown end prevents an unreliable free slot', () {
    final day = DateTime(2026, 10, 22);
    final result = calculateFreeTime([
      reminder(1, 22, 12, 0, 30),
      reminder(2, 22, 13, 0, null),
      reminder(3, 22, 14, 0, 60),
    ], day, day);
    expect(result.withoutEnd, 1);
    expect(result.gaps, isEmpty);
  });

  test('Old OCR title supplies duration even before the schema update', () {
    final old = Reminder.fromJson({
      'id': 123,
      'at': '2026-10-22T12:00:00.000',
      'title': '12:00–12:30 Erinnerung1',
      'tags': <String>[],
    });
    expect(old.effectiveDurationMinutes, 30);
    expect(old.toJson()['durationMinutes'], 30);
    final cleared = Reminder(
      id: 123,
      at: old.at,
      title: old.title,
      durationMinutes: 0,
    );
    expect(cleared.effectiveDurationMinutes, isNull);
    expect(Reminder.fromJson(cleared.toJson()).effectiveDurationMinutes, isNull);
  });

  test('Overnight appointments occupy the next days early hours', () {
    final day = DateTime(2026, 10, 23);
    final result = calculateFreeTime([
      reminder(1, 22, 23, 45, 30),
      reminder(2, 23, 0, 30, 30),
    ], day, day);
    expect(result.gaps.length, 1);
    expect(result.gaps.single.start, DateTime(2026, 10, 23, 0, 15));
    expect(result.gaps.single.end, DateTime(2026, 10, 23, 0, 30));
  });

  test('Daily repeats are expanded within selected days', () {
    final a = reminder(1, 22, 8, 0, 30)
      ..repeat = true;
    final b = reminder(2, 22, 10, 0, 45)
      ..repeat = true;
    final report = calculateFreeTime([
      a, b,
    ], DateTime(2026, 10, 22), DateTime(2026, 10, 24));
    expect(report.gaps.length, 3);
    expect(report.gaps.every((slot) => slot.duration.inMinutes == 90), isTrue);
  });

  test('No free slots inferred before first or after last reminder', () {
    final d = DateTime(2026, 10, 22);
    expect(calculateFreeTime([reminder(1, 22, 12, 0, 30)], d, d).gaps, isEmpty);
    expect(calculateFreeTime([], d, d).gaps, isEmpty);
  });
}
