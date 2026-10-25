import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'free_time.dart';
import 'ocr.dart';

const native = MethodChannel('foto_to_erinnerung/android');
final dateFormat = DateFormat('EEEE, dd.MM.yyyy', 'de_DE');
final shortDate = DateFormat('dd.MM.yyyy');
final hhmm = DateFormat('HH:mm');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE');
  runApp(const ReminderApp());
}

class ReminderApp extends StatelessWidget {
  const ReminderApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Foto to Erinnerung',
    debugShowCheckedModeBanner: false,
    locale: const Locale('de', 'DE'),
    supportedLocales: const [Locale('de', 'DE'), Locale('en', 'US')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: const OverviewPage(),
  );
}

class Occurrence {
  final Reminder reminder;
  final DateTime at;
  Occurrence(this.reminder, this.at);
}

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> with WidgetsBindingObserver {
  List<Reminder> reminders = [];
  List<TagData> tags = [];
  AlarmSound defaultSound = const AlarmSound('default', '', 'Standard-Weckerton');
  bool showNextNotification = false;
  bool vibrateOnly = false;
  List<int> defaultMinutes = [7, 5];
  Future<void> _saveQueue = Future<void>.value();
  final search = TextEditingController();
  final selected = <int>{};
  bool loading = true;
  bool hasExactPermission = true;
  int nextId = 1;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    search.addListener(() { if (mounted) setState(() {}); });
    _load();
    refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    refreshTimer?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkExact();
      // Repost the quiet status notification when returning from Android settings
      // or after the user dismisses it on a newer Android version.
      if (showNextNotification) {
        native.invokeMethod('refreshNextNotification').catchError((Object _) {});
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _checkExact() async {
    try {
      final allowed = await native.invokeMethod<bool>('canExactAlarms') ?? false;
      if (mounted) setState(() => hasExactPermission = allowed);
    } catch (_) { }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawReminders = jsonDecode(prefs.getString('reminders') ?? '[]') as List<dynamic>;
      final rawTags = jsonDecode(prefs.getString('tags') ?? '[]') as List<dynamic>;
      reminders = rawReminders.map((e) => Reminder.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      tags = rawTags.map((e) => TagData.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      defaultSound = AlarmSound.fromJson(jsonDecode(prefs.getString('defaultSound') ?? 'null'));
      showNextNotification = prefs.getBool('showNextNotification') ?? false;
      vibrateOnly = prefs.getBool('vibrateOnly') ?? false;
      final savedMinutes = prefs.getString('defaultMinutes');
      defaultMinutes = savedMinutes == null ? [7, 5] : (parseMinutes(savedMinutes) ?? [7, 5]);
      nextId = reminders.fold<int>(0, (v, e) => e.id > v ? e.id : v) + 1;
      await native.invokeMethod('requestNotificationPermission');
      await _syncNative();
      await _checkExact();
    } catch (err) {
      _message('Fehler beim Laden: $err');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  AlarmSound _resolvedSound(Reminder reminder) {
    if (reminder.sound != null) return reminder.sound!;
    for (final name in reminder.tags) {
      for (final tag in tags) {
        if (tag.name.toLowerCase() == name.toLowerCase() && tag.sound != null) return tag.sound!;
      }
    }
    return defaultSound;
  }

  List<int> _resolvedMinutes(Reminder reminder) {
    if (reminder.minutes != null) return reminder.minutes!;
    for (final name in reminder.tags) {
      for (final tag in tags) {
        if (tag.name.toLowerCase() == name.toLowerCase() && tag.minutes != null) return tag.minutes!;
      }
    }
    return defaultMinutes;
  }

  Future<void> _syncNative() async {
    final list = reminders.map((r) {
      final sound = _resolvedSound(r);
      return <String, dynamic>{
        'id': r.id, 'title': r.title, 'start': r.at.toIso8601String(),
        'repeat': r.repeat, 'unit': r.unit, 'every': r.every,
        'weekdays': r.weekdays, 'minutes': _resolvedMinutes(r),
        'tags': r.tags, 'durationMinutes': r.effectiveDurationMinutes,
        'soundType': sound.type, 'soundValue': sound.value,
      };
    }).toList();
    await native.invokeMethod('scheduleAll', {
      'entries': list,
      'showNextNotification': showNextNotification,
      'vibrateOnly': vibrateOnly,
    });
  }

  // Serialize writes and native alarm rescheduling. A quick succession of
  // switches must not let an older asynchronous save overwrite the newest one.
  Future<void> _save() {
    _saveQueue = _saveQueue.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('reminders', encodeReminders(reminders));
        await prefs.setString('tags', jsonEncode(tags.map((e) => e.toJson()).toList()));
        await prefs.setString('defaultSound', jsonEncode(defaultSound.toJson()));
        await prefs.setBool('showNextNotification', showNextNotification);
        await prefs.setBool('vibrateOnly', vibrateOnly);
        await prefs.setString('defaultMinutes', defaultMinutes.join(', '));
        await _syncNative();
      } catch (e) {
        _message('Speichern oder Alarmplanung fehlgeschlagen: $e');
      }
    });
    if (mounted) setState(() {});
    return _saveQueue;
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _edit([Reminder? old]) async {
    final result = await Navigator.push<Reminder>(context, MaterialPageRoute(
      builder: (_) => ReminderEditor(reminder: old, availableTags: tags, defaultMinutes: defaultMinutes),
    ));
    if (result == null) return;
    if (old == null) {
      result.id = nextId++;
      reminders.add(result);
    } else {
      final index = reminders.indexWhere((x) => x.id == old.id);
      if (index < 0) return;
      result.id = old.id;
      reminders[index] = result;
    }
    for (final tag in result.tags) {
      if (!tags.any((t) => t.name.toLowerCase() == tag.toLowerCase())) tags.add(TagData(name: tag));
    }
    await _save();
  }

  Future<void> _settings() async {
    await Navigator.push<void>(context, MaterialPageRoute(
      builder: (_) => SettingsPage(
        existingTags: tags.map((e) => TagData.fromJson(e.toJson())).toList(),
        defaultSound: defaultSound,
        defaultMinutes: List.of(defaultMinutes),
        showNextNotification: showNextNotification,
        vibrateOnly: vibrateOnly,
        onChanged: _applySettingsImmediately,
      ),
    ));
  }

  // Updates the owning page synchronously, then persists and reschedules.
  // Leaving Settings with Android's back button does not discard changes.
  void _applySettingsImmediately(SettingsData result) {
    for (final reminder in reminders) {
      reminder.tags = reminder.tags
          .map((name) => result.renamed[name] ?? name)
          .where((name) => result.tags.any(
              (tag) => tag.name.toLowerCase() == name.toLowerCase()))
          .toSet()
          .toList();
    }
    tags = result.tags.map((e) => TagData.fromJson(e.toJson())).toList();
    defaultSound = result.sound;
    defaultMinutes = List.of(result.defaultMinutes);
    showNextNotification = result.showNextNotification;
    vibrateOnly = result.vibrateOnly;
    _save();
  }

  Future<void> _deleteSelected() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Erinnerungen löschen?'),
      content: Text('${selected.length} ausgewählte Erinnerungen werden gelöscht. Wiederholungen werden ebenfalls entfernt.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Löschen')),
      ],
    ));
    if (ok != true) return;
    reminders.removeWhere((e) => selected.contains(e.id));
    selected.clear();
    await _save();
  }

  Future<void> _image(ImageSource source) async {
    XFile? image;
    try {
      image = await ImagePicker().pickImage(source: source, imageQuality: 100, maxWidth: 3000);
      if (image == null) return;
      _message('Foto wird eingelesen …');
      final data = await recognizePlan(image.path, DateTime.now());
      if (!mounted) return;
      if (data.isEmpty) {
        await showDialog<void>(context: context, builder: (_) => AlertDialog(
          title: const Text('Keine Termine erkannt'),
          content: const Text('Bitte ein scharfes, gerade aufgenommenes Foto verwenden. Jeder Termin muss eine Zeile mit zwei Uhrzeiten (hh:mm-hh:mm) haben und einem Wochentag zugeordnet sein.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ));
        return;
      }
      final accepted = await Navigator.push<List<ParsedEntry>>(context, MaterialPageRoute(
        builder: (_) => ImportPreview(entries: data, configuredTags: tags),
      ));
      if (accepted == null || accepted.isEmpty) return;
      var imported = 0;
      for (final entry in accepted) {
        final duplicate = reminders.any((r) => r.at.isAtSameMomentAs(entry.at) && r.title == entry.title);
        if (duplicate) continue;
        // Assigned exactly once on photo import. Manual edits and removals persist.
        final importTags = tagsMatchingImportedStart(entry.at, tags);
        reminders.add(Reminder(
          id: nextId++, at: entry.at, title: entry.title, tags: importTags,
          durationMinutes: entry.durationMinutes,
        ));
        imported++;
      }
      await _save();
      _message('$imported Erinnerungen hinzugefügt.');
    } catch (e) {
      _message('Fotoerkennung fehlgeschlagen: $e');
    }
  }

  List<Occurrence> _getOccurrences() {
    final now = DateTime.now();
    final until = now.add(const Duration(days: 365));
    final q = search.text.trim().toLowerCase();
    final found = <Occurrence>[];
    for (final r in reminders) {
      final localUntil = !r.repeat && r.at.isAfter(until) ? r.at : until;
      for (final at in r.occurrences(now, localUntil, limit: 350)) {
        final searchable = '${r.title} ${hhmm.format(at)} ${r.tags.map((t) => '#$t').join(' ')}'.toLowerCase();
        if (q.isEmpty || searchable.contains(q)) found.add(Occurrence(r, at));
      }
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _getOccurrences();
    final groups = <DateTime, List<Occurrence>>{};
    for (final entry in entries) {
      final day = DateTime(entry.at.year, entry.at.month, entry.at.day);
      groups.putIfAbsent(day, () => []).add(entry);
    }
    return Scaffold(
      appBar: AppBar(
        title: selected.isEmpty ? const Text('Foto to Erinnerung') : Text('${selected.length} ausgewählt'),
        leading: selected.isNotEmpty ? IconButton(icon: const Icon(Icons.close), tooltip: 'Auswahl beenden',
            onPressed: () => setState(selected.clear)) : null,
        actions: selected.isEmpty
          ? [
              IconButton(
                icon: const Icon(Icons.event_available),
                tooltip: 'Freiräume zwischen Erinnerungen anzeigen',
                onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => FreeTimePage(reminders: List.of(reminders)),
                )),
              ),
              IconButton(icon: const Icon(Icons.settings), tooltip: 'Einstellungen', onPressed: _settings),
            ]
          : [IconButton(icon: const Icon(Icons.delete), tooltip: 'Ausgewählte löschen', onPressed: _deleteSelected)],
      ),
      body: loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
        if (!hasExactPermission)
          MaterialBanner(
            content: const Text('Exakte Alarme sind nicht freigegeben. Erinnerungen können verspätet erscheinen.'),
            leading: const Icon(Icons.warning_amber_rounded),
            actions: [TextButton(onPressed: () async {
              await native.invokeMethod('openAlarmSettings');
            }, child: const Text('Freigeben'))],
          ),
        Padding(padding: const EdgeInsets.all(12), child: TextField(
          controller: search,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search),
              hintText: 'Titel, Uhrzeit oder #Tag durchsuchen',
              border: const OutlineInputBorder(),
              suffixIcon: search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear),
                  onPressed: search.clear)),
        )),
        Expanded(child: entries.isEmpty
          ? const Center(child: Text('Keine anstehenden Erinnerungen gefunden.'))
          : ListView(children: [
              for (final group in groups.entries) ...[
                Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                  child: Text(dateFormat.format(group.key), style: Theme.of(context).textTheme.titleMedium)),
                for (final entry in group.value)
                  Card(margin: const EdgeInsets.fromLTRB(10, 3, 10, 3), child: ListTile(
                    leading: selected.isEmpty
                      ? SizedBox(width: 57, child: Center(child: Text(hhmm.format(entry.at),
                          style: const TextStyle(fontWeight: FontWeight.bold))))
                      : Checkbox(value: selected.contains(entry.reminder.id), onChanged: (_) => setState(() {
                          if (!selected.add(entry.reminder.id)) selected.remove(entry.reminder.id);
                        })),
                    title: Text(entry.reminder.title),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (entry.reminder.tags.isNotEmpty)
                        Text(entry.reminder.tags.map((e) => '#$e').join('  ')),
                      if (entry.reminder.effectiveDurationMinutes != null)
                        Text('Ende: ${hhmm.format(entry.at.add(Duration(minutes: entry.reminder.effectiveDurationMinutes!)))}'),
                      Text('Vorwarnung: ${_resolvedMinutes(entry.reminder).join(' und ')} Min.'
                        '${entry.reminder.repeat ? ' · Wiederkehrend' : ''}',
                        style: Theme.of(context).textTheme.bodySmall),
                    ]),
                    isThreeLine: true,
                    onTap: () {
                      if (selected.isNotEmpty) {
                        setState(() {
                          if (!selected.add(entry.reminder.id)) selected.remove(entry.reminder.id);
                        });
                      } else { _edit(entry.reminder); }
                    },
                    onLongPress: () => setState(() { selected.add(entry.reminder.id); }),
                  )),
              ],
              const SizedBox(height: 95),
            ])),
      ]),
      floatingActionButton: Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(
        mainAxisAlignment: MainAxisAlignment.end, children: [
          FloatingActionButton.small(heroTag: 'gallery', tooltip: 'Foto aus Galerie',
            onPressed: () => _image(ImageSource.gallery), child: const Icon(Icons.photo_library)),
          const SizedBox(width: 10),
          FloatingActionButton.small(heroTag: 'camera', tooltip: 'Wochenplan fotografieren',
            onPressed: () => _image(ImageSource.camera), child: const Icon(Icons.photo_camera)),
          const SizedBox(width: 10),
          FloatingActionButton(heroTag: 'new', tooltip: 'Erinnerung hinzufügen',
            onPressed: () => _edit(), child: const Icon(Icons.add)),
        ],
      )),
    );
  }
}

// ---- Sound selection ----
Future<AlarmSound?> selectSound(BuildContext context, AlarmSound? current) async {
  final action = await showModalBottomSheet<String>(context: context, builder: (_) => SafeArea(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.volume_up), title: const Text('System-Standardton'),
        onTap: () => Navigator.pop(context, 'default')),
      ListTile(leading: const Icon(Icons.alarm), title: const Text('System-Weckerton auswählen'),
        onTap: () => Navigator.pop(context, 'system')),
      ListTile(leading: const Icon(Icons.audio_file), title: const Text('MP3-Datei auswählen'),
        onTap: () => Navigator.pop(context, 'mp3')),
      ListTile(leading: const Icon(Icons.close), title: const Text('Abbrechen'),
        onTap: () => Navigator.pop(context)),
    ],
  )));
  if (action == null) return null;
  if (action == 'default') return const AlarmSound('default', '', 'System-Standardton');
  if (action == 'system') {
    try {
      final result = await native.invokeMapMethod<String, dynamic>('chooseAlarmSound');
      if (result == null) return null;
      return AlarmSound('${result['type']}', '${result['value']}', '${result['label']}');
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return null;
    }
  }
  try {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );
    if (picked == null) return null;
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/sounds');
    await folder.create(recursive: true);
    final target = File('${folder.path}/${DateTime.now().microsecondsSinceEpoch}.mp3');
    await target.writeAsBytes(await picked.readAsBytes(), flush: true);
    return AlarmSound('mp3', target.path, picked.name);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('MP3 konnte nicht importiert werden: $e')));
    return null;
  }
}

// ---- Add / Edit reminder ----
class ReminderEditor extends StatefulWidget {
  final Reminder? reminder;
  final List<TagData> availableTags;
  final List<int> defaultMinutes;
  const ReminderEditor({super.key, this.reminder, required this.availableTags,
    this.defaultMinutes = const [7, 5]});
  @override
  State<ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<ReminderEditor> {
  late DateTime at;
  TimeOfDay? endTime;
  bool endWasCleared = false;
  late TextEditingController title;
  late TextEditingController tagText;
  late TextEditingController number;
  late TextEditingController offsets;
  bool repeat = false;
  bool customOffsets = false;
  String unit = 'days';
  Set<int> days = {};
  AlarmSound? sound;
  final Set<String> selectedTags = {};

  @override
  void initState() {
    super.initState();
    final existing = widget.reminder;
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    at = existing?.at ?? DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
    if (existing?.effectiveDurationMinutes != null) {
      endTime = TimeOfDay.fromDateTime(at.add(
          Duration(minutes: existing!.effectiveDurationMinutes!)));
    }
    title = TextEditingController(text: existing?.title ?? '');
    // Stored reminder tags are authoritative: do not auto-apply tags from time.
    selectedTags.addAll(existing?.tags ?? const <String>[]);
    tagText = TextEditingController();
    number = TextEditingController(text: '${existing?.every ?? 1}');
    offsets = TextEditingController(text: (existing?.minutes ?? widget.defaultMinutes).join(', '));
    repeat = existing?.repeat ?? false;
    unit = existing?.unit ?? 'days';
    days = existing?.weekdays.toSet() ?? {};
    sound = existing?.sound;
    customOffsets = existing?.minutes != null;
  }

  @override
  void dispose() {
    title.dispose(); tagText.dispose(); number.dispose(); offsets.dispose();
    super.dispose();
  }

  Future<void> chooseDate() async {
    final result = await showDatePicker(context: context, initialDate: at,
      firstDate: DateTime(2020), lastDate: DateTime(2100), locale: const Locale('de', 'DE'));
    if (result != null) setState(() => at = DateTime(result.year, result.month, result.day, at.hour, at.minute));
  }

  Future<void> chooseTime() async {
    final result = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(at));
    if (result != null) setState(() => at = DateTime(at.year, at.month, at.day, result.hour, result.minute));
  }

  Future<void> chooseEndTime() async {
    final initial = endTime ?? TimeOfDay.fromDateTime(at.add(const Duration(minutes: 30)));
    final result = await showTimePicker(context: context, initialTime: initial);
    if (result != null) setState(() {
      endTime = result;
      endWasCleared = false;
    });
  }

  void save() {
    if (title.text.trim().isEmpty) { _error('Bitte einen Titel angeben.'); return; }
    final every = int.tryParse(number.text.trim());
    if (repeat && (every == null || every < 1 || every > 100000)) {
      _error('Wiederholungszahl muss zwischen 1 und 100000 liegen.'); return;
    }
    final parsed = customOffsets ? parseMinutes(offsets.text) : null;
    if (customOffsets && parsed == null) {
      _error('Zwei unterschiedliche Vorwarnzeiten zwischen 0 und 1440 Minuten angeben, z. B. 7, 5.'); return;
    }
    int? durationMinutes;
    if (endTime != null) {
      final begin = at.hour * 60 + at.minute;
      final finish = endTime!.hour * 60 + endTime!.minute;
      durationMinutes = (finish - begin + 1440) % 1440;
      if (durationMinutes == 0) {
        _error('Die Endzeit muss von der Startzeit abweichen.');
        return;
      }
    }
    final manuallyTyped = tagText.text.split(RegExp(r'[,;\n]+'))
        .map(normalizedTag).where((e) => e.isNotEmpty);
    final names = <String>{...selectedTags, ...manuallyTyped}.toList();
    Navigator.pop(context, Reminder(
      id: widget.reminder?.id ?? 0, at: at, title: title.text.trim(), tags: names,
      repeat: repeat, unit: unit, every: every ?? 1, weekdays: days.toList()..sort(),
      sound: sound, minutes: parsed,
      durationMinutes: endTime == null && endWasCleared ? 0 : durationMinutes,
    ));
  }

  void _error(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.reminder == null ? 'Erinnerung erstellen' : 'Erinnerung bearbeiten')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: title, maxLines: 2, decoration: const InputDecoration(
        labelText: 'Titel', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: chooseDate, icon: const Icon(Icons.event),
          label: Text(shortDate.format(at)))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(onPressed: chooseTime, icon: const Icon(Icons.schedule),
          label: Text(hhmm.format(at)))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton.icon(
          onPressed: chooseEndTime,
          icon: const Icon(Icons.more_time),
          label: Text(endTime == null
              ? 'Endzeit hinzufügen'
              : 'Ende ${endTime!.hour.toString().padLeft(2, '0')}:${endTime!.minute.toString().padLeft(2, '0')}'),
        )),
        if (endTime != null)
          IconButton(
            tooltip: 'Endzeit entfernen',
            onPressed: () => setState(() {
              endTime = null;
              endWasCleared = true;
            }),
            icon: const Icon(Icons.close),
          ),
      ]),
      const Padding(padding: EdgeInsets.only(top: 4, bottom: 12), child: Text(
        'Für die Freiraumberechnung eine Endzeit festlegen. Liegt sie vor der Startzeit, gilt der Folgetag.',
        style: TextStyle(fontSize: 12),
      )),
      const Text('Tags (optional)', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      if (selectedTags.isNotEmpty) ...[
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final tag in selectedTags.toList())
            InputChip(
              label: Text('#$tag'),
              deleteButtonTooltipMessage: 'Tag nur aus dieser Erinnerung entfernen',
              onDeleted: () => setState(() => selectedTags.remove(tag)),
            ),
        ]),
        const SizedBox(height: 8),
      ],
      if (widget.availableTags.any((tag) => !selectedTags.contains(tag.name))) ...[
        const Text('Vorhandene Tags hinzufügen:'),
        const SizedBox(height: 5),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final tag in widget.availableTags)
            if (!selectedTags.contains(tag.name))
              ActionChip(
                label: Text('#${tag.name}'),
                onPressed: () => setState(() => selectedTags.add(tag.name)),
              ),
        ]),
        const SizedBox(height: 8),
      ],
      TextField(controller: tagText, decoration: const InputDecoration(
        labelText: 'Weitere Tags eintragen', hintText: '#Therapie, #Wichtig',
        helperText: 'Neue Tags werden angelegt. Chips mit × entfernen nur die Zuordnung zu dieser Erinnerung.',
        helperMaxLines: 3, border: OutlineInputBorder())),
      const SizedBox(height: 16),
      CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Wiederholen'),
        value: repeat, onChanged: (v) => setState(() => repeat = v ?? false)),
      if (repeat) ...[
        Row(children: [
          SizedBox(width: 100, child: TextField(controller: number,
            keyboardType: TextInputType.number, decoration: const InputDecoration(
              labelText: 'Alle', border: OutlineInputBorder()))),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<String>(initialValue: unit,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'hours', child: Text('Stunden')),
              DropdownMenuItem(value: 'days', child: Text('Tage')),
              DropdownMenuItem(value: 'weeks', child: Text('Wochen')),
            ], onChanged: (v) => setState(() => unit = v ?? 'days'))),
        ]),
        const SizedBox(height: 14),
        const Text('Wochentage (optional; keine Auswahl = ohne Filter):'),
        Wrap(spacing: 5, children: [
          for (var day = 1; day <= 7; day++) FilterChip(
            label: Text(weekdaysShort[day - 1]), selected: days.contains(day),
            onSelected: (checked) => setState(() => checked ? days.add(day) : days.remove(day)),
          ),
        ]),
        if (unit == 'days') const Text('Bei Tagesintervallen werden nur Treffer der angegebenen Wochentage verwendet.'),
      ],
      const Divider(height: 30),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.music_note),
        title: const Text('Erinnerungston (optional)'),
        subtitle: Text(sound?.label ?? 'Standardton bzw. Tag-Ton verwenden'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final picked = await selectSound(context, sound);
          if (picked != null) setState(() => sound = picked);
        }),
      if (sound != null) Align(alignment: Alignment.centerRight,
        child: TextButton(onPressed: () => setState(() => sound = null),
          child: const Text('Individuellen Ton entfernen'))),
      CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Eigene Vorwarnzeiten'),
        subtitle: const Text('Übersteuert ggf. Vorgaben der Tags.'), value: customOffsets,
        onChanged: (v) => setState(() => customOffsets = v ?? false)),
      if (customOffsets) TextField(controller: offsets,
        keyboardType: TextInputType.text, decoration: const InputDecoration(
          labelText: 'Minuten vor Beginn (Komma-getrennt)', hintText: '30, 15, 5',
          border: OutlineInputBorder())),
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), label: const Text('Speichern')),
    ]),
  );
}

// ---- OCR preview ----
class ImportPreview extends StatefulWidget {
  final List<ParsedEntry> entries;
  final List<TagData> configuredTags;
  const ImportPreview({super.key, required this.entries, required this.configuredTags});
  @override
  State<ImportPreview> createState() => _ImportPreviewState();
}

class _ImportPreviewState extends State<ImportPreview> {
  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Foto: Termine prüfen')),
      body: Column(children: [
        const Padding(padding: EdgeInsets.all(12), child: Text(
          'Automatisch erkannte Termine prüfen und bei Bedarf Titel korrigieren. '
          'Wochentag und Startzeit werden aus dem Foto übernommen. '
          'Tags mit passender Startuhrzeit werden nur bei diesem Import automatisch vergeben.')),
        Expanded(child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
          final item = entries[index];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Padding(
            padding: const EdgeInsets.all(8), child: Row(children: [
              Checkbox(value: item.selected, onChanged: (value) => setState(() => item.selected = value ?? false)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${item.weekday}, ${shortDate.format(item.at)} · ${hhmm.format(item.at)}–${hhmm.format(item.at.add(Duration(minutes: item.durationMinutes)))}',
                    style: Theme.of(context).textTheme.labelMedium),
                if (tagsMatchingImportedStart(item.at, widget.configuredTags).isNotEmpty)
                  Text('Automatische Tags: ${tagsMatchingImportedStart(item.at, widget.configuredTags).map((t) => '#$t').join('  ')}',
                      style: Theme.of(context).textTheme.bodySmall),
                TextFormField(key: ValueKey(index), initialValue: item.title,
                  maxLines: null, onChanged: (text) => item.title = text,
                  decoration: const InputDecoration(isDense: true, hintText: 'Titel')),
              ])),
            ]),
          ));
        })),
        SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
          child: FilledButton.icon(icon: const Icon(Icons.check), label: Text(
            '${entries.where((e) => e.selected).length} Erinnerungen importieren'), onPressed: () {
              Navigator.pop(context, entries.where((e) => e.selected && e.title.trim().isNotEmpty).toList());
            }))),
        ),
      ]),
    );
  }
}

// ---- Settings and tag management ----
class SettingsData {
  final List<TagData> tags;
  final AlarmSound sound;
  final Map<String, String> renamed;
  final bool showNextNotification;
  final bool vibrateOnly;
  final List<int> defaultMinutes;
  SettingsData(this.tags, this.sound, this.renamed,
      this.showNextNotification, this.vibrateOnly, this.defaultMinutes);
}

class SettingsPage extends StatefulWidget {
  final List<TagData> existingTags;
  final AlarmSound defaultSound;
  final List<int> defaultMinutes;
  final bool showNextNotification;
  final bool vibrateOnly;
  final ValueChanged<SettingsData> onChanged;
  const SettingsPage({super.key, required this.existingTags, required this.defaultSound,
    this.defaultMinutes = const [7, 5], required this.showNextNotification,
    required this.vibrateOnly, required this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late List<TagData> tags;
  late AlarmSound sound;
  late List<int> defaultMinutes;
  late TextEditingController minutesController;
  late bool showNextNotification;
  late bool vibrateOnly;
  String? minutesError;
  final renamed = <String, String>{};

  @override
  void initState() {
    super.initState();
    tags = widget.existingTags.map((e) => TagData.fromJson(e.toJson())).toList();
    sound = widget.defaultSound;
    defaultMinutes = List.of(widget.defaultMinutes);
    minutesController = TextEditingController(text: defaultMinutes.join(', '));
    showNextNotification = widget.showNextNotification;
    vibrateOnly = widget.vibrateOnly;
  }

  @override
  void dispose() {
    minutesController.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    widget.onChanged(SettingsData(
      tags.map((e) => TagData.fromJson(e.toJson())).toList(),
      sound,
      Map<String, String>.of(renamed),
      showNextNotification,
      vibrateOnly,
      List<int>.of(defaultMinutes),
    ));
    // All changes are now applied immediately to the owning OverviewPage.
    renamed.clear();
  }

  void saveDefaultMinutes() {
    final parsed = parseMinutes(minutesController.text);
    if (parsed == null) {
      setState(() => minutesError =
          'Bitte 1 bis 32 unterschiedliche, ganze Minutenwerte durch Kommas trennen.');
      return;
    }
    setState(() {
      defaultMinutes = parsed;
      minutesError = null;
      minutesController.text = parsed.join(', ');
    });
    FocusScope.of(context).unfocus();
    _notifyChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Standard-Vorwarnzeiten gespeichert.')));
  }

  Future<void> editTag([TagData? item]) async {
    final result = await Navigator.push<TagData>(context, MaterialPageRoute(
      builder: (_) => TagEditor(
        tag: item == null ? null : TagData.fromJson(item.toJson()),
        defaultMinutes: defaultMinutes,
      ),
    ));
    if (result == null || !mounted) return;
    if (tags.any((e) => e != item && e.name.toLowerCase() == result.name.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Diesen Tag gibt es bereits.')));
      return;
    }
    setState(() {
      if (item == null) {
        tags.add(result);
      } else {
        if (item.name != result.name) {
          for (final old in renamed.keys.toList()) {
            if (renamed[old] == item.name) renamed[old] = result.name;
          }
          renamed[item.name] = result.name;
        }
        tags[tags.indexOf(item)] = result;
      }
    });
    _notifyChanged();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Einstellungen')),
    body: ListView(padding: const EdgeInsets.all(14), children: [
      const Text('Benachrichtigungen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      SwitchListTile(
        secondary: const Icon(Icons.notifications_none),
        contentPadding: EdgeInsets.zero,
        title: const Text('Nächste Erinnerungen dauerhaft anzeigen'),
        subtitle: const Text('Lautlose Übersicht in der Android-Benachrichtigungsleiste '
            'mit Startzeit und Titel der nächsten anstehenden Termine.'),
        value: showNextNotification,
        onChanged: (value) {
          setState(() => showNextNotification = value);
          _notifyChanged();
        },
      ),
      SwitchListTile(
        secondary: const Icon(Icons.vibration),
        contentPadding: EdgeInsets.zero,
        title: const Text('Erinnerungsalarme: nur Vibration'),
        subtitle: const Text('Kein Weckerton und keine MP3-Wiedergabe; '
            'Benachrichtigung und Vibration bleiben aktiv.'),
        value: vibrateOnly,
        onChanged: (value) {
          setState(() => vibrateOnly = value);
          _notifyChanged();
        },
      ),
      const Text('Schalter, Töne und Tags werden bei Änderungen sofort gespeichert. '
          'Die Standard-Vorwarnzeiten werden mit dem eigenen Speichern-Button übernommen. '
          'Für Benachrichtigungen ist die Android-Berechtigung erforderlich.',
          style: TextStyle(fontSize: 12)),
      TextButton.icon(
        onPressed: () async {
          try {
            await native.invokeMethod('openNotificationSettings');
          } catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Android-Einstellungen konnten nicht geöffnet werden: $e')),
            );
          }
        },
        icon: const Icon(Icons.settings_applications),
        label: const Text('Android-Benachrichtigungsrechte öffnen'),
      ),
      const Divider(),
      const Text('Standard-Vorwarnzeiten', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(
        controller: minutesController,
        keyboardType: TextInputType.text,
        onChanged: (_) {
          if (minutesError != null) setState(() => minutesError = null);
        },
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: 'Minuten vor Beginn',
          hintText: '30, 15, 5',
          helperText: 'Ein Wert oder mehrere Werte, durch Kommas getrennt',
          errorText: minutesError,
        ),
      ),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerRight, child: FilledButton.icon(
        onPressed: saveDefaultMinutes,
        icon: const Icon(Icons.save),
        label: const Text('Speichern'),
      )),
      const Text('Gilt für alle Erinnerungen ohne eigene oder Tag-Vorwarnzeiten. '
          'Bereits vorhandene Erinnerungen werden automatisch neu eingeplant.',
          style: TextStyle(fontSize: 12)),
      const Divider(),
      const Text('Standard-Erinnerungston', style: TextStyle(fontWeight: FontWeight.bold)),
      ListTile(leading: const Icon(Icons.notifications_active), title: Text(sound.label),
        subtitle: const Text('Für Fotoimporte und Erinnerungen ohne eigenen bzw. Tag-Ton'),
        trailing: const Icon(Icons.chevron_right), onTap: () async {
          final newSound = await selectSound(context, sound);
          if (newSound != null && mounted) {
            setState(() => sound = newSound);
            _notifyChanged();
          }
        }),
      const Divider(),
      Row(children: [
        const Expanded(child: Text('Tags', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        IconButton(onPressed: () => editTag(), tooltip: 'Tag hinzufügen', icon: const Icon(Icons.add)),
      ]),
      if (tags.isEmpty) const ListTile(title: Text('Noch keine Tags vorhanden.')),
      for (final tag in tags) ListTile(
        title: Text('#${tag.name}'),
        subtitle: Text([
          if (tag.startTime != null) 'Foto-Startzeit: ${tag.startTime}',
          if (tag.sound != null) 'Ton: ${tag.sound!.label}',
          if (tag.minutes != null) 'Vorwarnung: ${tag.minutes!.join(', ')} Min.',
        ].join(' · ')),
        onTap: () => editTag(tag),
        trailing: IconButton(tooltip: 'Tag löschen', icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
              title: const Text('Tag löschen?'),
              content: Text('#${tag.name} wird auch aus allen Erinnerungen entfernt.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Löschen')),
              ],
            ));
            if (confirm == true && mounted) {
              setState(() => tags.remove(tag));
              _notifyChanged();
            }
          }),
      ),
      const SizedBox(height: 12),
      const Text('Startuhrzeiten ordnen Tags ausschließlich NEUEN Erinnerungen aus Kamera/Galerie zu. '
        'Schon gespeicherte Erinnerungen werden durch eine Änderung nicht neu zugeordnet.'),
      const SizedBox(height: 8),
      const Text('Ton-Priorität: Erinnerung → erster Tag mit Ton → Standardton. '
        'Vorwarnzeiten: Erinnerung → erster Tag mit Zeiten → Standard-Vorwarnzeiten.'),
    ]),
  );
}

class TagEditor extends StatefulWidget {
  final TagData? tag;
  final List<int> defaultMinutes;
  const TagEditor({super.key, this.tag, this.defaultMinutes = const [7, 5]});
  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  late TextEditingController name;
  late TextEditingController times;
  AlarmSound? sound;
  TimeOfDay? matchStartTime;
  bool customTimes = false;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.tag?.name ?? '');
    times = TextEditingController(text: (widget.tag?.minutes ?? widget.defaultMinutes).join(', '));
    sound = widget.tag?.sound;
    customTimes = widget.tag?.minutes != null;
    final configured = normalizeTagStartTime(widget.tag?.startTime);
    if (configured != null) {
      final parts = configured.split(':');
      matchStartTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    }
  }

  Future<void> chooseStartTime() async {
    final chosen = await showTimePicker(
      context: context,
      initialTime: matchStartTime ?? const TimeOfDay(hour: 9, minute: 0),
      helpText: 'Startuhrzeit für automatische Foto-Tags',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (chosen != null && mounted) setState(() => matchStartTime = chosen);
  }
  @override
  void dispose() { name.dispose(); times.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.tag == null ? 'Tag erstellen' : 'Tag bearbeiten')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Tag-Name',
          prefixText: '#', border: OutlineInputBorder())),
      const SizedBox(height: 15),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.schedule),
        title: const Text('Startuhrzeit für Fotoimporte (optional)'),
        subtitle: Text(matchStartTime == null
          ? 'Nicht festgelegt – keine automatische Zuordnung'
          : '${matchStartTime!.hour.toString().padLeft(2, '0')}:${matchStartTime!.minute.toString().padLeft(2, '0')} – bei neuen Fotoerinnerungen zuordnen'),
        trailing: const Icon(Icons.edit_calendar),
        onTap: chooseStartTime,
      ),
      if (matchStartTime != null)
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: () => setState(() => matchStartTime = null),
          icon: const Icon(Icons.close),
          label: const Text('Startuhrzeit entfernen'),
        )),
      const Text('Die Zuordnung wird nur beim Import neuer Fotos durchgeführt. '
        'Bestehende Erinnerungen bleiben unverändert.'),
      const SizedBox(height: 15),
      ListTile(leading: const Icon(Icons.music_note), title: const Text('Tag-Erinnerungston'),
        subtitle: Text(sound?.label ?? 'Kein eigener Ton'), trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final result = await selectSound(context, sound);
          if (result != null) setState(() => sound = result);
        }),
      if (sound != null) TextButton(onPressed: () => setState(() => sound = null),
        child: const Text('Tag-Ton entfernen')),
      CheckboxListTile(contentPadding: EdgeInsets.zero, value: customTimes,
        onChanged: (v) => setState(() => customTimes = v ?? false),
        title: const Text('Eigene Vorwarnzeiten für diesen Tag')),
      if (customTimes) TextField(controller: times, decoration: const InputDecoration(
        labelText: 'Minuten vor Beginn', hintText: '30, 15, 5', border: OutlineInputBorder())),
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: () {
        final cleaned = normalizedTag(name.text);
        final minutes = customTimes ? parseMinutes(times.text) : null;
        if (cleaned.isEmpty || cleaned.contains('#') || (customTimes && minutes == null)) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Tag-Name oder Vorwarnzeiten ungültig.')));
          return;
        }
        final chosenStart = matchStartTime == null ? null
          : '${matchStartTime!.hour.toString().padLeft(2, '0')}:${matchStartTime!.minute.toString().padLeft(2, '0')}';
        Navigator.pop(context, TagData(
          name: cleaned, minutes: minutes, sound: sound, startTime: chosenStart,
        ));
      }, icon: const Icon(Icons.save), label: const Text('Tag speichern')),
    ]),
  );
}
