import 'package:flutter_test/flutter_test.dart';
import 'package:foto_to_erinnerung/models.dart';

void main() {
  group('Startuhrzeit bei Tags', () {
    test('exakte Startzeit ordnet Tags einem neuen Fotoimport zu', () {
      final tags = [
        TagData(name: 'Morgenspaziergang', startTime: '07:10'),
        TagData(name: 'Fruehstueck', startTime: '07:30'),
        TagData(name: 'Therapie', startTime: '07:10'),
      ];
      expect(tagsMatchingImportedStart(DateTime(2026, 10, 23, 7, 10), tags),
        ['Morgenspaziergang', 'Therapie']);
      expect(tagsMatchingImportedStart(DateTime(2026, 10, 23, 7, 30), tags),
        ['Fruehstueck']);
      expect(tagsMatchingImportedStart(DateTime(2026, 10, 23, 7, 11), tags),
        isEmpty);
    });

    test('Startzeit laesst sich speichern, aendern und entfernen', () {
      final tag = TagData(name: 'Training', startTime: '14:45');
      expect(TagData.fromJson(tag.toJson()).startTime, '14:45');
      tag.startTime = null;
      expect(TagData.fromJson(tag.toJson()).startTime, isNull);
      expect(tagsMatchingImportedStart(DateTime(2026, 10, 22, 14, 45), [tag]), isEmpty);
    });

    test('gespeicherte alte Tags ohne neue Eigenschaft bleiben verwendbar', () {
      final tag = TagData.fromJson({'name': 'Alt', 'minutes': [7, 5]});
      expect(tag.startTime, isNull);
      expect(tag.minutes, [7, 5]);
    });

    test('Startzeiten werden validiert und normalisiert', () {
      expect(normalizeTagStartTime('7:05'), '07:05');
      expect(normalizeTagStartTime('24:00'), isNull);
      expect(normalizeTagStartTime('10:66'), isNull);
      expect(normalizeTagStartTime(''), isNull);
    });

    test('Entfernung bleibt in bestehender Erinnerung gespeichert', () {
      final original = Reminder(
        id: 5, at: DateTime(2026, 10, 23, 7, 10),
        title: '07:10–07:25 Morgenspaziergang',
        tags: ['Morgenspaziergang'],
      );
      original.tags.remove('Morgenspaziergang');
      final restored = Reminder.fromJson(original.toJson());
      expect(restored.tags, isEmpty);
      // Eine neue Regel aendert ein bestehendes Erinnerungsobjekt nicht.
      final configuredTags = [
        TagData(name: 'Morgenspaziergang', startTime: '07:10'),
      ];
      expect(tagsMatchingImportedStart(restored.at, configuredTags),
        ['Morgenspaziergang']);
      expect(restored.tags, isEmpty);
    });
  });
}
