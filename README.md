# Foto to Erinnerung – Flutter Android App

## Build

```bash
unzip foto_to_erinnerung_quellcode.zip
cd foto_to_erinnerung
sudo ./compile.sh
```

Es werden bei Bedarf Flutter 3.47.5, das Android SDK (API 36, Build Tools,
NDK) sowie fehlende Debian/Ubuntu-Abhängigkeiten installiert. **Java bleibt
unberührt.** Ziel ist `/root/apk/foto-to-erinnerung_v1.apk` usw.
Der Versionszähler wird anhand vorhandener erfolgreich erzeugter APK-Dateien
im Zielordner bestimmt. Fehlgeschlagene Builds erhöhen ihn nicht.

Das Skript benötigt eine Internetverbindung für fehlende Abhängigkeiten.
Auf ARM-Servern ist es ohne Anpassungen nicht lauffähig.

## Funktionen

- Termine auf dem Gerät gespeichert (SharedPreferences als JSON)
- Anstehende Termine nach Datum gruppiert; Suche nach Titel, Uhrzeit und #Tag
- Einträge manuell erstellen, bearbeiten und mehrfach löschen
- Wiederholung nach Stunden/Tagen/Wochen plus Wochentagfilter
- Kamera/Galerie, OCR via on-device ML Kit und überprüfbare Importvorschau
- Eigene/systemseitige Wecktöne oder importierte MP3s
- Zwei Vorwarnungen (Standard 7 und 5 Minuten) per AlarmManager,
  Benachrichtigung, Vibration und Ton (max. 30 Sekunden)
- Alarm- und Vorwarnzeit-Priorität: Eintrag vor erstem passendem Tag vor Standard
- Weiterplanen wiederkehrender Alarme durch Android-Receiver, auch nach Neustart

## Android-Berechtigungen

Beim ersten Start Benachrichtigungen erlauben. Auf Android 12+ ggf. die
Schaltfläche »Freigeben« für exakte Alarme nutzen. Akkuoptimierung oder
besondere Herstellereinstellungen können die tatsächliche Zustellung beeinflussen.

## Hinweise zur Erkennung

Die App erkennt Text anhand von ML Kit (offline, sobald das Modell geladen ist).
Das Planbild benötigt Wochentagüberschriften und Zeitspannen wie
`07:10-07:25` in der Termine-Spalte. Der nächste passende Kalendertag
wird verwendet; bei gleichem Wochentag ist es **heute** (auch wenn die Zeit
bereits vorbei ist). Bitte alle erkannten Einträge prüfen: schiefe, unscharfe
Bilder, OCR-Fehler und Zeilenumbrüche können falsche Zuordnungen erzeugen.
Einmalige Fotoimporte werden **nicht automatisch wöchentlich wiederholt**.
Die importierten Termine können danach einzeln bearbeitet werden.

## Quellstruktur

- `lib/main.dart`: Oberfläche, Datenhaltung, Einstellungen und Importvorschau
- `lib/models.dart`: Erinnerungen/Tags, Wiederholungsregeln
- `lib/ocr.dart`: OCR-Auswertung für Tagespläne
- `android_overrides/.../MainActivity.kt`: Android-MethodChannel, Ton-Auswahl
- `android_overrides/.../ReminderRuntime.kt`: native Alarmplanung und Audio
- `compile.sh`: vollständiger Build und versionierte APK-Ausgabe
