import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foto_to_erinnerung/main.dart';
import 'package:foto_to_erinnerung/models.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async => initializeDateFormatting('de_DE'));

  test('Vorwarnzeiten: genau ein oder mehrere Werte', () {
    expect(parseMinutes('5'), [5]);
    expect(parseMinutes('30, 15, 5'), [30, 15, 5]);
    expect(parseMinutes('0, 5'), [0, 5]);
    expect(parseMinutes(' 7 ,5 '), [7, 5]);
    expect(parseMinutes(''), isNull);
    expect(parseMinutes('1,'), isNull);
    expect(parseMinutes('1,,2'), isNull);
    expect(parseMinutes('1, 1'), isNull);
    expect(parseMinutes('-1'), isNull);
    expect(parseMinutes('2.5'), isNull);
    expect(parseMinutes('1;2'), isNull);
    expect(parseMinutes(List.generate(33, (i) => '$i').join(',')), isNull);
  });

  testWidgets('Schalter werden sofort übernommen, auch beim Zurückgehen',
      (tester) async {
    final changes = <SettingsData>[];
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: ElevatedButton(
        child: const Text('Einstellungen öffnen'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SettingsPage(
            existingTags: const [],
            defaultSound: const AlarmSound('default', '', 'Standard-Weckerton'),
            showNextNotification: false,
            vibrateOnly: false,
            onChanged: changes.add,
          ),
        )),
      ),
    ))));

    await tester.tap(find.text('Einstellungen öffnen'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(changes.last.showNextNotification, true);
    expect(changes.last.vibrateOnly, false);
    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pumpAndSettle();
    expect(changes.last.showNextNotification, true);
    expect(changes.last.vibrateOnly, true);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Einstellungen öffnen'), findsOneWidget);
    expect(changes.length, 2);
  });

  testWidgets('Standard-Minuten werden erst nach Speichern übernommen',
      (tester) async {
    final changes = <SettingsData>[];
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(size: Size(600, 1100)),
      child: SettingsPage(
        existingTags: const [],
        defaultSound: const AlarmSound('default', '', 'Standard-Weckerton'),
        showNextNotification: false,
        vibrateOnly: false,
        onChanged: changes.add,
      ),
    )));

    final field = find.widgetWithText(TextField, 'Minuten vor Beginn');
    await tester.ensureVisible(field);
    await tester.enterText(field, '30, 15, 5');
    await tester.pump();
    expect(changes, isEmpty);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.single.defaultMinutes, [30, 15, 5]);

    await tester.ensureVisible(field);
    await tester.enterText(field, '3,3');
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pump();
    expect(changes, hasLength(1));
    expect(find.textContaining('unterschiedliche'), findsOneWidget);
  });
}
