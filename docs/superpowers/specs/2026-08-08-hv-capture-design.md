# HV-Capture — Design (2026-08-08)

iOS-App zur Überwachung, Absicherung und filmischen Dokumentation eines
MOT-Lichtbogen-Aufbaus (Mikrowellen-Trafo, Elektrode am isolierten Stiel gegen
Gehäuse-Masse). Die Leistung wird über eine LSC-Steckdose mit OpenBeken-Firmware
geschaltet und gemessen.

**Das ist kein Sicherheitssystem.** Die App ist eine Komfort- und
Dokumentationsschicht über einer Anlage, die tödliche Ströme führt. Jede
Schutzfunktion in dieser Spec kann durch WLAN-Ausfall, App-Absturz oder ein
klebendes Relais versagen. Physischer Schutz (Vorschaltlast, eigene Sicherung,
erreichbarer Not-Aus) ist Voraussetzung, kein Extra.

## Kontext

- **Hardware:** MOT aus Mikrowelle, Elektrode an isoliertem Stiel, zweites Kabel
  auf Gehäusemasse. Speisung über LSC-Smart-Steckdose mit OpenBeken.
- **Vorbild:** CoolerOS (`~/Claude/Projects/ESP32-Kühler/app/CoolerOS`). Von dort
  wird die *Struktur* übernommen (Theme-Enum, Card-Modifier, Haptics, Dev-Mode
  hinter PIN, Settings-Aufbau, HTTP-Plug-Zugriff), nicht das Aussehen.
- **Eigenständig:** eigenes Xcode-Projekt, eigenes Farb- und Formvokabular,
  eigene Boot-Animation, reaktives Live-Theme.
- **Nutzer:** eine Person, der Entwickler selbst. Kein Multi-User, kein Account,
  keine Cloud.

## Sicherheitsmodell

Vier Ebenen, von außen nach innen. Nur die äußeren beiden sind verlässlich.

1. **Physisch (nicht in der App):** Vorschaltlast in Serie, eigene träge
   Sicherung, physisch erreichbarer Not-Aus. Der Nutzer hat das aktuell **nicht**
   — deshalb erzwingt die App die Checkliste (Punkt 2), bevor sie überhaupt
   schalten lässt.
2. **Sicherheits-Gate:** Vor der ersten Scharfschaltung muss eine Checkliste
   Punkt für Punkt bestätigt werden (Vorschaltlast, Sicherung, Not-Aus,
   Abstand, niemand sonst im Raum, kein Alkohol, trockener Boden, Feuerlöscher).
   Ohne vollständige Bestätigung bleibt der Power-Button gesperrt. Die
   Bestätigung verfällt nach jedem App-Start neu — kein „nie wieder zeigen".
3. **Dead-Man auf der Dose:** Die App erneuert alle 10 s einen Selbstabschalt-
   Auftrag *in der Steckdose* (`addRepeatingEventID <fenster> 1 <ID> POWER OFF`,
   Fenster konfigurierbar, Default 30 s). Bricht App, iPhone oder WLAN weg,
   schaltet die Dose ohne Zutun ab. Das ist die einzige Schutzfunktion, die
   einen Totalausfall der App überlebt.
4. **Stromwächter in der App:** Zwei Kriterien, beide einzeln abschaltbar,
   beide lösen sofort `Power Off` aus:
   - **Schwelle:** Strom über Grenzwert für länger als Haltezeit (Default 2,0 s).
   - **Flachheit:** Strom durchgehend über einem niedrigeren Verdachtswert *und*
     die **Spannweite** (max − min) im Fenster unterschreitet ein Maß — ein
     echter Bogen flackert, ein klebender Kurzschluss ist auffällig ruhig.
     Erkennt Kleben unterhalb der harten Schwelle.

     Bewusst Spannweite statt Standardabweichung: die App pollt schneller, als
     der Messchip neue Werte liefert, also stehen im Fenster viele identische
     Wiederholungen. Die drücken eine Standardabweichung künstlich gegen null
     und würden mitten im echten Bogen auslösen. Auf max − min haben
     Wiederholungen keinen Einfluss.
   Beide Grenzwerte kommen aus einer Kalibrierfahrt und bleiben in den
   Einstellungen von Hand justierbar.

**Kalibrierung:** geführter Ablauf in drei Schritten — Leerlauf messen
(MOT an, kein Bogen), normales Bogenziehen messen, absichtlicher kurzer Kontakt.
Daraus schlägt die App Schwelle, Verdachtswert und Flachheitsmaß vor. Der
Vorschlag ist ein Vorschlag: alle Werte bleiben editierbar, weil jeder MOT,
jede Elektrode und jede Netzimpedanz anders sind.

**Trip-Verhalten:** Jede Auto-Abschaltung wird protokolliert (Grund, Zeitstempel,
Messwert, ±10 s Kurvenausschnitt), löst Alarmhaptik + Ton aus, und die Dose
bleibt gesperrt, bis der Nutzer den Trip aktiv quittiert.

## Architektur

Reine SwiftUI-App, iOS 18, XcodeGen-Projektdatei. Vier Schichten, jede in
eigenen Dateien, jede ohne Kenntnis der darüberliegenden.

```
Views/          SwiftUI — kennt nur die Engines, nie HTTP oder AVFoundation
  ├── RootView, BootAnimationView, SafetyGateView
  ├── ControlView (Power, Timer-Modi, Wächter, Live-Werte)
  ├── CameraView (Sucher, HUD, Trigger, Modi)
  ├── SessionsView (Verlauf, Vergleich, Rekorde, Trips)
  └── SettingsView / DevModeView
Core/           Zustand und Logik — @Observable, testbar
  ├── PlugLink        HTTP zur Dose, Poll-Schleifen, Dead-Man
  ├── ArcGuard        Schwellen-/Flachheits-Erkennung, Kalibrierung
  ├── SessionRecorder Messreihen, Events, Statistik, CSV
  ├── SessionStore    Persistenz, Rekorde, Elektroden-Verschleiß
  ├── CaptureEngine   AVFoundation, Ringpuffer, Auto-Trigger
  ├── LiveTheme       Leistung → Farbe/Glow
  └── ArcIntents      Siri-Not-Aus, Live Activity
Model/          Reine Werte, keine Abhängigkeiten
  └── Sample, ArcEvent, Session, TripReason, GuardConfig
Design/         Theme, Karten, Haptik, HV-Formen
```

**Datenfluss:** `PlugLink` pollt und veröffentlicht `Sample`-Werte. Daran hängen
parallel und ohne einander zu kennen: `ArcGuard` (bewertet, schaltet ggf. ab),
`SessionRecorder` (schreibt mit), `LiveTheme` (färbt die UI), `CaptureEngine`
(Strom-Trigger) und die Live Activity. Eine Quelle, mehrere Verbraucher.

## Polling

Zwei Schleifen, weil der Sicherheitspfad nicht auf den Schaltzustand warten darf:

- **Schnell (200 ms, nur bei eingeschalteter Dose):** `Status 8` → Volt, Ampere,
  Watt, kWh. Das ist der Wächter-Pfad.
- **Langsam (1 s):** `Power` → An/Aus. Ausserdem 3 s im Ruhezustand.

Der Messchip der Dose (BL0937-Klasse) aktualisiert nur etwa im Sekundentakt.
200 ms Poll bringt also keine echte Auflösung, sondern minimiert die Latenz bis
ein neuer Wert *sichtbar* wird. Die App erkennt unveränderte Werte, zählt sie
nicht als neue Messpunkte und zeigt im Dev-Mode die **effektive** Rate an, damit
die Anzeige nicht mehr Präzision vortäuscht als die Hardware liefert.

## Timer-Modi

Alle drei laufen über denselben Ausführungspfad wie der Dead-Man, damit es nur
eine Stelle gibt, die die Dose abschaltet.

- **Session-Timer:** Einschalten, nach N Sekunden hart aus. Grosser Countdown,
  Warnton bei 5 s.
- **Puls-Modus:** N Sekunden an, M Sekunden aus, K Wiederholungen. Die
  An-Phasen werden vom Dead-Man mitabgesichert.
- **Totmann-Taste:** Strom fliesst nur, solange der Finger den Button hält.
  Loslassen sendet sofort `Power Off`. Ehrlich beschriftet: die Latenz liegt bei
  einigen hundert Millisekunden, das ist kein mechanischer Totmannschalter.

## Kamera

`AVCaptureSession` mit Foto, Video und Slo-Mo (240 fps, wo verfügbar, sonst
120 fps). Belichtung ist der Knackpunkt: ein Lichtbogen überstrahlt jede
Automatik. Default ist deshalb **manuelle Belichtung** mit kurzer Zeit und
niedrigem ISO, plus ein Ein-Tipp-Preset „Bogen" (1/1000 s, ISO 50, Fokus auf
Elektrodenabstand fixiert). Automatik bleibt wählbar.

**Ringpuffer:** Video läuft dauerhaft in einen Puffer der letzten Sekunden
(konfigurierbar 2–10 s). Jeder Trigger sichert Vorlauf + Nachlauf — deshalb ist
auch der ~1 s späte Strom-Trigger brauchbar.

**Auto-Trigger,** einzeln zuschaltbar oder alle zusammen im Auto-Modus:
- **Helligkeit:** Luminanzsprung im Bild, schnellster Weg, netzunabhängig.
- **Strom:** Leistungssprung aus `PlugLink`, koppelt Clip an Messdaten.
- **Audio:** Pegel-/Frequenzsprung, anfällig für Umgebungslärm, deshalb per
  Default aus.

## Die zwölf Funktionen

1. **Reaktives Live-Theme** — Akzentfarbe und Glow der gesamten UI folgen der
   Momentanleistung: Ruhe kühl, Bogen glühend. Abschaltbar.
2. **Arc-Statistik & Rekorde** — pro Session Zündungen, längster Bogen,
   Peak-Watt, Wh; dazu Allzeit-Bestwerte.
3. **HUD-Overlay** — V/A/W und Timer über dem Sucher, optional fest ins Video
   gebrannt.
4. **Apple-Watch-Not-Aus** — eigenständige Watch-App mit grossem Aus-Knopf und
   Live-Watt, damit das iPhone am Stativ bleiben kann.
5. **Live Activity / Dynamic Island** — Countdown und Watt auf dem Sperrbildschirm.
6. **Session-Vergleich** — zwei Kurven übereinander.
7. **Best-Frame-Extraktion** — hellstes/schärfstes Einzelbild je Clip als Foto.
8. **Siri-Not-Aus** — App Intent „Strom aus", funktioniert mit belegten Händen.
9. **Export-Paket** — Clip, synchronisierte CSV und Metadaten als ein Bundle.
10. **Bogen-Audiospektrum** — Live-Frequenzanalyse als HUD-Visualisierung.
11. **Elektroden-Verschleiss** — kumulierte Bogensekunden je benannter Elektrode.
12. **Trip-Historie** — jede Auto-Abschaltung mit Grund, Zeit und Kurvenausschnitt.

## Boot-Animation

Links ein MOT in Seitenansicht (laminierter Kern, dicke Primär-, dünne
Sekundärwicklung), rechts eine Jakobsleiter aus zwei nach oben divergierenden
Elektroden. Ablauf: Kern zeichnet sich, Wicklungen laufen ein, ein Funke zündet
unten zwischen den Elektroden, der Bogen wandert nach oben, wird länger und
dünner, reisst oben ab — dabei blitzt der Schriftzug auf. Reines SwiftUI
(`Canvas` + `TimelineView`), Bogenpfad als seeded Zufalls-Zickzack, damit jeder
Start leicht anders aussieht. Überspringbar per Tipp, abschaltbar in den
Einstellungen.

## Persistenz

- Sessions als JSON je Datei in `Documents/Sessions/`, Messreihen als CSV
  daneben. Kein Core Data, kein SwiftData — die Daten sind flach, append-only
  und sollen exportierbar bleiben.
- Einstellungen in `UserDefaults` über `@AppStorage`, wie in CoolerOS.
- Medien in der Fotomediathek (eigenes Album), nicht in der App-Sandbox.

## Fehlerbehandlung

Leitlinie: **Im Zweifel abschalten, nie stillschweigend weiterlaufen.**

- Dose nicht erreichbar während sie an ist → Warnbanner nach 2 s, Alarm nach 5 s;
  der Dead-Man in der Dose übernimmt.
- Messwerte fehlen oder sind unplausibel → Wächter behandelt das wie eine
  Grenzwertverletzung, nicht wie „alles in Ordnung".
- Kamera-/Mikrofonrechte fehlen → Capture-Funktionen deaktiviert, der Rest der
  App bleibt voll nutzbar. Die Überwachung hängt nie an der Kamera.
- Speicher voll → Aufnahme stoppt, Messmitschrieb läuft weiter.

## Tests

Swift Testing für die Logik, die stillschweigend falsch sein kann:
Schwellen- und Flachheitserkennung (inklusive Grenzfällen: fehlende Werte,
Wertesprünge, zu kurze Historie), Kalibrierungs-Vorschläge, Timer-Befehlsbau,
Dead-Man-Erneuerung, CSV-Format, Statistik- und Verschleissrechnung.
Nicht getestet wird, was ohne Hardware oder Kamera sinnlos ist — dafür gibt es
im Dev-Mode ein Testcenter mit Simulationsmodus, das synthetische Messreihen
(sauberer Bogen, klebender Kurzschluss, Verbindungsabriss) einspeist, damit
Wächter und UI ohne scharfen MOT geprüft werden können.

## Bewusst nicht enthalten

Kein Account, keine Cloud, kein Sharing-Backend, keine Mehrgeräte-Sync, keine
Lokalisierung ausser Deutsch, kein iPad-Layout, kein MQTT (die Dose hängt im
selben WLAN wie das iPhone — der direkte HTTP-Weg genügt; die Fernsteuerung
einer Hochspannungsanlage von unterwegs ist ausdrücklich nicht gewollt).
