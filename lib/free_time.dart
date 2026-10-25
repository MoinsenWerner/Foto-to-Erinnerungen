import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';

/// A free time strictly BETWEEN two appointments, never outside the first/last
/// appointment of the day. Adjacent or overlapping appointments have no gap.
class FreeSlot {
  final DateTime start;
  final DateTime end;
  const FreeSlot(this.start, this.end);
  Duration get duration => end.difference(start);
}

class FreeTimeReport {
  final List<FreeSlot> gaps;
  /// Number of occurrences with no known end within the selected date range.
  /// Such appointments can make a purported gap unreliable.
  final int withoutEnd;
  const FreeTimeReport(this.gaps, this.withoutEnd);
}

class _Occupied {
  final DateTime start;
  final DateTime end;
  const _Occupied(this.start, this.end);
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Returns free slots within each selected calendar day (inclusive range).
/// Occupied intervals are merged before the differences are calculated.
/// Reminders without an end time never count as zero-length appointments:
/// candidate gaps containing their start are withheld and a warning is shown.
/// Overnight appointments are clipped to the corresponding days.
FreeTimeReport calculateFreeTime(
  List<Reminder> reminders,
  DateTime firstDay,
  DateTime lastDay,
) {
  final first = _day(firstDay);
  final last = _day(lastDay);
  if (last.isBefore(first)) return const FreeTimeReport([], 0);
  final until = DateTime(last.year, last.month, last.day + 1);
  // Appointments may start the previous day and run past midnight.
  final earliestStart = DateTime(first.year, first.month, first.day - 1);
  final occupied = <_Occupied>[];
  final withoutEndStarts = <DateTime>[];

  for (final reminder in reminders) {
    final duration = reminder.effectiveDurationMinutes;
    final starts = reminder.occurrences(
      earliestStart, until.subtract(const Duration(microseconds: 1)),
      limit: 3000,
    );
    for (final start in starts) {
      if (duration == null) {
        if (!start.isBefore(first) && start.isBefore(until)) {
          withoutEndStarts.add(start);
        }
        continue;
      }
      final end = start.add(Duration(minutes: duration));
      if (start.isBefore(until) && end.isAfter(first)) {
        occupied.add(_Occupied(start, end));
      }
    }
  }

  final gaps = <FreeSlot>[];
  for (var day = first; !day.isAfter(last);
      day = DateTime(day.year, day.month, day.day + 1)) {
    final nextDay = DateTime(day.year, day.month, day.day + 1);
    final intervals = <_Occupied>[];
    for (final item in occupied) {
      if (!item.start.isBefore(nextDay) || !item.end.isAfter(day)) continue;
      intervals.add(_Occupied(
        item.start.isBefore(day) ? day : item.start,
        item.end.isAfter(nextDay) ? nextDay : item.end,
      ));
    }
    intervals.sort((a, b) => a.start.compareTo(b.start));
    if (intervals.isEmpty) continue;

    var busyThrough = intervals.first.end;
    for (final item in intervals.skip(1)) {
      if (item.start.isAfter(busyThrough)) {
        // If another appointment starts inside that gap but its end is unknown,
        // it would be dishonest to advertise this period as completely free.
        final uncertain = withoutEndStarts.any((unknown) =>
            !unknown.isBefore(busyThrough) && unknown.isBefore(item.start));
        if (!uncertain) gaps.add(FreeSlot(busyThrough, item.start));
      }
      if (item.end.isAfter(busyThrough)) busyThrough = item.end;
    }
  }
  return FreeTimeReport(gaps, withoutEndStarts.length);
}

String humanDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  if (hours == 0) return '$minutes Min.';
  if (remaining == 0) return '$hours Std.';
  return '$hours Std. $remaining Min.';
}

class FreeTimePage extends StatefulWidget {
  final List<Reminder> reminders;
  const FreeTimePage({super.key, required this.reminders});

  @override
  State<FreeTimePage> createState() => _FreeTimePageState();
}

class _FreeTimePageState extends State<FreeTimePage> {
  late DateTime firstDay;
  late DateTime lastDay;
  final dateFormat = DateFormat('EEEE, dd.MM.yyyy', 'de_DE');
  final shortFormat = DateFormat('dd.MM.yyyy', 'de_DE');
  final clock = DateFormat('HH:mm');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    firstDay = _day(now);
    lastDay = DateTime(firstDay.year, firstDay.month, firstDay.day + 13);
  }

  Future<void> selectRange() async {
    final dates = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: firstDay, end: lastDay),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Zeitraum für Freiräume wählen',
      saveText: 'Übernehmen',
    );
    if (dates == null || !mounted) return;
    if (dates.end.difference(dates.start).inDays > 92) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Bitte höchstens 93 Tage auf einmal auswählen.'),
      ));
      return;
    }
    setState(() {
      firstDay = _day(dates.start);
      lastDay = _day(dates.end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = calculateFreeTime(widget.reminders, firstDay, lastDay);
    final grouped = <DateTime, List<FreeSlot>>{};
    for (final slot in report.gaps) {
      grouped.putIfAbsent(_day(slot.start), () => []).add(slot);
    }
    final total = report.gaps.fold<Duration>(
      Duration.zero, (sum, slot) => sum + slot.duration,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Freiräume')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: ListTile(
          leading: const Icon(Icons.date_range),
          title: const Text('Zeitraum auswählen'),
          subtitle: Text('${shortFormat.format(firstDay)} – ${shortFormat.format(lastDay)}'),
          trailing: const Icon(Icons.edit_calendar),
          onTap: selectRange,
        )),
        Padding(padding: const EdgeInsets.fromLTRB(8, 12, 8, 8), child: Text(
          '${report.gaps.length} Freiräume · Insgesamt ${humanDuration(total)}',
          style: Theme.of(context).textTheme.titleMedium,
        )),
        if (report.withoutEnd > 0)
          Card(child: ListTile(
            leading: const Icon(Icons.warning_amber),
            title: Text('${report.withoutEnd} Termine ohne Endzeit'),
            subtitle: const Text(
              'Für diese Termine ist die Dauer nicht bekannt. Freiräume können '
              'deshalb unvollständig sein. Bitte die Endzeiten in den Erinnerungen ergänzen.'
            ),
          )),
        const Padding(padding: EdgeInsets.fromLTRB(8, 4, 8, 10), child: Text(
          'Angezeigt werden ausschließlich Lücken zwischen Terminen am selben Tag. '
          'Direkt aufeinanderfolgende und überlappende Termine erzeugen keinen Freiraum.'
        )),
        if (report.gaps.isEmpty)
          const Card(child: Padding(
            padding: EdgeInsets.all(18),
            child: Text('Keine sicher bestimmbaren Freiräume im gewählten Zeitraum.'),
          )),
        for (final group in grouped.entries) ...[
          Padding(padding: const EdgeInsets.fromLTRB(8, 12, 8, 6), child: Text(
            dateFormat.format(group.key),
            style: Theme.of(context).textTheme.titleMedium,
          )),
          for (final slot in group.value)
            Card(child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text('${clock.format(slot.start)} – ${clock.format(slot.end)}'),
              subtitle: Text('${humanDuration(slot.duration)} frei'),
            )),
        ],
      ]),
    );
  }
}
