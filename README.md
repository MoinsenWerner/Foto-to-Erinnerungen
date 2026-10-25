# Foto to Erinnerung – Android & Wear OS

Mit **Foto to Erinnerung** verwaltest du Termine auf einem Android-Handy und – in der erweiterten Version – auf einer **Google Pixel Watch 2** bzw. einer kompatiblen Wear-OS-Uhr. Termine können manuell erstellt oder aus einem fotografierten Wochenplan eingelesen werden. Die Handy-App ist die zentrale Datenquelle; die Uhren-App erhält eine synchronisierte Kopie.

> [!IMPORTANT]
> **Stand des GitHub-Repositories:** Die Dokumentation beschreibt auch die zuletzt entwickelte **erweiterte Projektversion** (Freiräume, zusätzliche Benachrichtigungseinstellungen und Wear OS). Auf `main` liegen aktuell noch ältere Quelldateien: insbesondere fehlt das Verzeichnis `wear/`, und die derzeitige `compile.sh` kennt die Option `-wear` noch nicht. Bevor der Wear-OS-Installationsblock mit einem frischen Klon funktioniert, müssen die aktualisierten Projektdateien ins Repository übernommen werden. Die Dokumentation allein erweitert die App nicht.

## Schnellinstallation: Android-Handy

**System:** Debian/Ubuntu Linux, x86_64, Internetverbindung und Berechtigungen zum Installieren fehlender Build-Abhängigkeiten. Die resultierende APK kann anschließend auf einem Android-Gerät installiert werden. `compile.sh` benötigt aufgrund seiner Zielverzeichnisse und Paketinstallation Rootrechte.

Der folgende Block klont das Repository, prüft **die tatsächlich ausführbaren Java- und Javac-Versionen**, verwendet ein vorhandenes **JDK 17** (auch bei manueller Installation) oder lädt ein geprüftes Eclipse-Temurin-17-JDK herunter, macht `compile.sh` ausführbar und baut die Handy-APK:

```bash
git clone https://github.com/MoinsenWerner/Foto-to-Erinnerungen.git
cd Foto-to-Erinnerungen
source ./scripts/ensure-java17.sh
chmod +x ./compile.sh
if [ "$(id -u)" -eq 0 ]; then
  ./compile.sh
else
  sudo env JAVA_HOME="$JAVA_HOME" PATH="$PATH" ./compile.sh
fi
```

**Ergebnis:** `/root/apk/foto-to-erinnerung_v{Version}.apk` (z. B. `foto-to-erinnerung_v8.apk`). Bei erfolgreichem Build wird die Versionsnummer erhöht; bei einem fehlgeschlagenen Build nicht. Fehlende Flutter-/Android-SDK-Komponenten werden durch `compile.sh` installiert.

## Schnellinstallation: Google Pixel Watch 2 / Wear OS

> [!WARNING]
> Für diesen Block muss die **aktuelle Projektversion mit `wear/`, Wear-Synchronisierung und `./compile.sh -wear`** im Repository vorliegen. Im derzeitigen Stand des Branches `main` ist dies noch **nicht** der Fall.

Die Befehle prüfen Java auf dieselbe Weise und erstellen in der erweiterten Projektfassung **die Handy-APK und die Wear-OS-APK**:

```bash
git clone https://github.com/MoinsenWerner/Foto-to-Erinnerungen.git
cd Foto-to-Erinnerungen
source ./scripts/ensure-java17.sh
chmod +x ./compile.sh
if [ "$(id -u)" -eq 0 ]; then
  ./compile.sh -wear
else
  sudo env JAVA_HOME="$JAVA_HOME" PATH="$PATH" ./compile.sh -wear
fi
```

**Ergebnis der erweiterten Fassung:**

```text
/root/apk/foto-to-erinnerung_v{Version}.apk
/root/apk/foto-to-erinnerung_wear_v{Version}.apk
```

Beide Dateien erhalten dieselbe Buildnummer. Die neue Nummer wird erst nach erfolgreichen Builds und einer Prüfung der übereinstimmenden Signaturen übernommen. **Die Wear-OS-APK allein reicht nicht:** Installiere auch die dazugehörige aktualisierte Handy-App.

### Wie funktioniert die Java-Prüfung?

`scripts/ensure-java17.sh` kontrolliert `java -version` und `javac -version` direkt über die tatsächlich gefundenen JDK-Binärdateien – **nicht** per `dpkg`, `apt list` oder anhand eines installierten Java-APT-Pakets. Wenn ein vollständiges JDK 17 vorhanden ist, wird es weiterbenutzt, gleichgültig ob es über APT, manuell oder anders installiert wurde. Andernfalls lädt das Skript Eclipse Temurin 17 über die [Adoptium-API](https://adoptium.net/installation/ci-scripts) herunter, überprüft dessen SHA-256-Prüfsumme und installiert es unter `~/.local/share/foto-to-erinnerung/jdk-17`. `JAVA_HOME` und `PATH` werden für die laufende Shell angepasst. Das Skript muss daher mit `source` aufgerufen werden.

Die Java-Version des Betriebssystems wird **nicht systemweit umgestellt**. Auch die bestehende `compile.sh` selbst führt weiterhin keine Java-Paketprüfung durch. Andere JDK-Versionen müssen nicht deinstalliert werden. Die Java-17-Auswahl betrifft die Buildumgebung; das Gradle-/Kotlin-JVM-Ziel ist davon zu unterscheiden.

---

## Handy-App bedienen

### 1. Startseite und Erinnerungsübersicht

- Nach dem Öffnen werden anstehende Erinnerungen **tageweise gruppiert** und innerhalb eines Tages nach **Startuhrzeit** sortiert.
- Über die **Suchleiste** suchst du nach Teilen des Titels, einer Startuhrzeit (z. B. `14:30`) oder einem Tag (z. B. `#Therapie`).
- **Antippen** einer Erinnerung öffnet deren Bearbeitung.
- **Langes Drücken** aktiviert die Mehrfachauswahl. Weitere Einträge kannst du auswählen und anschließend über das **Löschsymbol** gemeinsam entfernen.
- Über **Einstellungen** (Zahnrad) erreichst du Benachrichtigungen, Standardtöne und die Tag-Verwaltung.

### 2. Erinnerung manuell erstellen oder bearbeiten

Tippe auf **`+`**. Folgende Angaben stehen zur Verfügung:

| Angabe | Beschreibung |
|---|---|
| Datum und Startuhrzeit | Beginn der Erinnerung |
| Enduhrzeit | Optional; erforderlich für genaue Freiraumberechnung |
| Titel | Angezeigter Erinnerungsname |
| Tags | Optional, Schreibweise `#Tagname`; mehrere Tags möglich |
| Wiederholung | Optional nach Stunden, Tagen oder Wochen mit Zahlenintervall und auswählbaren Wochentagen |
| Erinnerungston | Standard-/Systemweckerton oder eigene MP3 |
| Vorwarnungen | Optional individuelle Minutenwerte; übersteuern Tags und Standard |

Speichere die Erinnerung im Editor. Beim Bearbeiten kannst du Tags einzeln über das **`×`** am Tag entfernen, ohne den Tag selbst zu löschen.

### 3. Wochenplan mit Kamera oder Galerie importieren

- **Kamerasymbol:** einen ausgedruckten Plan fotografieren.
- **Galeriesymbol:** ein vorhandenes Foto auswählen.
- Die Texterkennung (Google ML Kit) sucht Wochentage und Einträge, die mit einer Zeitspanne wie `07:10-07:25` beginnen.
- Bei einem am Donnerstag aufgenommenen Plan wird ein Eintrag für **Freitag** dem nächsten Freitag zugeordnet.
- Die **erste Uhrzeit** wird als Startzeit, die **zweite Uhrzeit** als Endzeit übernommen. Der Titel enthält die Zeitspanne und die erkannte Beschreibung.
- In der **Importvorschau** kannst du Erkennungsfehler berichtigen und unerwünschte Einträge abwählen, bevor sie gespeichert werden.

**Wichtig:** OCR kann bei unscharfen, schrägen oder mehrzeiligen Tabellen Fehler verursachen. Kontrolliere jeden Import. Fotoimporte sind zunächst einmalige Termine; Wiederholungen können anschließend im Editor eingerichtet werden.

### 4. Tags verwenden

Unter **Einstellungen → Tags** kannst du Tags anlegen, umbenennen und löschen. Pro Tag sind optional ein eigener Erinnerungston, eigene Vorwarnzeiten und eine **Startuhrzeit für Fotoimporte** einstellbar.

**Beispiel:** Hat `#Morgenspaziergang` die Startuhrzeit `07:10`, bekommen **neu** per Bild importierte Erinnerungen mit Startzeit `07:10` automatisch diesen Tag. Bereits gespeicherte Erinnerungen werden nicht rückwirkend verändert. Entfernst du den Tag in einer einzelnen Erinnerung, wird er dort nicht automatisch neu hinzugefügt.

### 5. Freiräume anzeigen

Über das **Freiraum-Symbol** auf der Startseite öffnest du die Übersicht freier Zeitfenster zwischen Terminen. Ein Beispiel:

```text
12:00–12:30  Erinnerung 1
12:30–14:00  Erinnerung 2
14:00–14:30  FREI (30 Minuten)
14:30–15:15  Erinnerung 3
```

Anschluss- und Überschneidungszeiten werden bei der Berechnung zusammengefasst. Für Termine ohne bekannte Endzeit kann kein exakter Freiraum abgeleitet werden; in diesem Fall zeigt die App einen Hinweis. Auch wiederkehrende Erinnerungen werden berücksichtigt.

### 6. Benachrichtigungen und Einstellungen

Unter **Einstellungen → Benachrichtigungen** kannst du Folgendes ändern:

- **Standard-Vorwarnzeiten:** Textfeld mit Minutenwerten, beispielsweise `30, 15, 5`. Der daneben beziehungsweise darunter stehende Button **„Speichern“** übernimmt diese Liste. Jeder Wert löst eine separate Vorwarnung aus.
- **Dauerhafte, tonlose Benachrichtigung:** Zeigt die Startzeit und den Titel der nächsten anstehenden Erinnerung; in der erweiterten Ansicht mehrere bevorstehende Termine.
- **Erinnerungsbenachrichtigungen stumm:** Kein Alarmton, aber weiterhin Benachrichtigung und Vibration.
- **Standard-Erinnerungston:** Für Erinnerungen ohne individuellen oder Tag-spezifischen Ton.
- **Tag-Regeln:** Tag-spezifische Töne, Vorwarnzeiten und Foto-Startzeiten.

**Speicherverhalten:** Schalter und andere direkte Einstellungsaktionen werden sofort gespeichert; die Liste der Standard-Vorwarnzeiten wird absichtlich erst mit **„Speichern“** übernommen. Ein eigener Tag-Editor verwendet weiterhin seinen Button **„Tag speichern“**.

**Priorität für Ton und Vorwarnzeiten:** individuelle Einstellung der Erinnerung → Einstellung eines passenden Tags → Standardwert.

### 7. Berechtigungen und Alarmzustellung

Beim ersten Start **Benachrichtigungen erlauben**. Unter Android 12 und neuer können für exakt geplante Alarme weitere Berechtigungen erforderlich sein; öffne sie gegebenenfalls über den entsprechenden Hinweis in der App. Akkuoptimierung und Herstellerregeln können die Alarmzustellung beeinflussen. Eine Benachrichtigung allein bedeutet nicht, dass ein Alarm garantiert sekundengenau erscheint.

**Datenhaltung:** Erinnerungen und Tags liegen lokal auf dem Android-Gerät. Installiere neu gebaute APKs nach Möglichkeit **als Update**, ohne die App vorher zu deinstallieren, damit Daten erhalten bleiben. Vor größeren Änderungen empfiehlt sich eine Sicherung.

---

## Wear-OS-App bedienen (erweiterte Projektversion)

### 1. Was zeigt die Uhr an?

Die Wear-OS-App ist für die **Google Pixel Watch 2** vorgesehen. Sie zeigt die vom Handy übertragenen Erinnerungen nach Tagen und Startuhrzeit sortiert an. Die Uhr speichert den letzten Stand **lokal**, sodass die Übersicht auch vorübergehend ohne Handyverbindung verfügbar bleibt.

### 2. Erinnerungen synchronisieren

1. **Aktualisierte Handy-App** und **dazugehörige Wear-OS-App** installieren.
2. Die Uhr über die Pixel-Watch-Begleit-App mit dem Android-Handy koppeln; Google Play Services müssen auf beiden Geräten verfügbar sein.
3. Handy-App öffnen. Beim Start und bei Änderungen wird der aktuelle Erinnerungsbestand an die Wear-OS-Data-Layer-Schnittstelle übergeben.
4. Uhren-App öffnen. Über **„Synchronisieren“** kannst du den letzten verfügbaren Stand abrufen. Nachfolgende Änderungen werden automatisch übertragen, sobald eine passende Verbindung verfügbar ist.

**Synchronisiert werden:** bestehende, neu erstellte, bearbeitete und gelöschte Erinnerungen einschließlich Wiederholung und Vorwarnzeiten. Die Handy-App ist führend; auf der Uhr werden keine neuen Erinnerungen erstellt oder geändert. Bei fehlender Verbindung bleibt zunächst die letzte erfolgreich synchronisierte Liste sichtbar.

### 3. Benachrichtigungen auf der Uhr

Die Uhr plant eigene Vorwarnungen und **vibriert ohne Alarmton**. MP3-Dateien und Weckertöne des Handys werden nicht auf die Uhr kopiert. Erlaube die erforderlichen Benachrichtigungen und gegebenenfalls genaue Alarme auf der Uhr. Wenn die Pixel Watch zusätzlich Handy-Benachrichtigungen spiegelt, können doppelte Meldungen auftreten. Schalte dann gegebenenfalls die Benachrichtigungsspiegelung der Handy-App in der Pixel-Watch-Begleit-App aus.

### 4. APK auf der Pixel Watch installieren

Auf der Uhr **Entwickleroptionen** und **WLAN-Debugging** aktivieren; im gleichen erreichbaren Netzwerk auf einem PC mit installiertem Android Debug Bridge (ADB) ausführen:

```bash
adb pair WATCH_IP:PAIRING_PORT
adb connect WATCH_IP:DEBUG_PORT
adb -s WATCH_IP:DEBUG_PORT install -r foto-to-erinnerung_wear_v8.apk
```

`WATCH_IP`, `PAIRING_PORT`, `DEBUG_PORT` und die APK-Version entsprechend ersetzen. Die ADB-Befehle müssen auf einem Rechner ausgeführt werden, der die Uhr erreichen kann; ein entfernter Rootserver hat nicht automatisch Zugriff auf das lokale WLAN. Die Handy-APK separat auf dem Telefon aktualisieren.

### 5. Technische Einschränkungen

- Synchronisierung: **Google Play Services Wearable Data Layer**, kein eigener Server erforderlich.
- Für eine verlässliche Kopplung müssen **Paketname und Signatur** der Handy- und Wear-OS-APK übereinstimmen.
- Offline werden zuletzt synchronisierte Daten verwendet; Änderungen erscheinen erst nach erneuter Verbindung.
- Benachrichtigungen/Alarme hängen von Berechtigungen, Energieverwaltung und dem Zustand der Uhr ab.
- Der Synchronisationsstand ist in der Implementierung aus Größen- und Zuverlässigkeitsgründen begrenzt; sehr große Terminlisten müssen gegebenenfalls reduziert werden.

---

## Entwicklung, Fehlerbehebung und Projektdateien

```bash
# Projekt nach Änderungen erneut bauen:
./compile.sh         # Handy
./compile.sh -wear   # Handy + Wear OS (nur im aktualisierten Projekt)

# Flutter-Tests (sofern Flutter eingerichtet ist):
flutter test
```

Wichtige Projektteile:

| Pfad | Aufgabe |
|---|---|
| `lib/main.dart` | Flutter-Oberfläche, Einstellungen, Speichern/Import |
| `lib/models.dart` | Erinnerungen, Tags, Wiederholungsregeln |
| `lib/ocr.dart` | OCR-Analyse der fotografierten Tabellen |
| `lib/free_time.dart` | Freiraumberechnung (erweiterte Fassung) |
| `android_overrides/` | Native Android-Alarme, Benachrichtigungen und Wear-Übertragung |
| `wear/` | Eigenständige Wear-OS-App (erweiterte Fassung) |
| `scripts/ensure-java17.sh` | Prüfung von `java`/`javac`, bei Bedarf JDK-17-Installation |
| `compile.sh` | Android-/Wear-Build und fortlaufende APK-Versionierung |

**Plattformen:** Der automatisierte Build ist für **Debian/Ubuntu auf x86_64** ausgelegt. Eine Internetverbindung wird für erstmalig benötigte Buildkomponenten und gegebenenfalls Java benötigt. Der JDK-Installer ist getrennt von `compile.sh`, damit das Build-Skript nicht die Java-Installation des Systems verändert.

**Bekannte Build- und Laufzeitfehler:** Für ML-Kit-OCR sind in der erweiterten Fassung R8-/ProGuard-Korrekturen enthalten. Bei Abweichungen der Java- und Kotlin-JVM-Zielversionen muss das Wear-Modul Java **und** Kotlin auf JVM 17 kompilieren. Funktionalität und Build wurden nicht auf jeder Geräte-/Android-Version abschließend getestet.
