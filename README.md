# HV-Capture

iOS-App zur Überwachung, Absicherung und filmischen Dokumentation eines
MOT-Lichtbogen-Aufbaus. Geschaltet und gemessen wird über eine LSC-Steckdose
mit OpenBeken-Firmware, gefilmt mit der iPhone-Kamera.

> **Das ist kein Sicherheitssystem.**
> Die App ist eine Komfort- und Dokumentationsschicht über einer Anlage, die
> tödliche Ströme führt. Jede Schutzfunktion hier kann durch WLAN-Ausfall,
> App-Absturz oder ein klebendes Relais versagen. Vorschaltlast, eigene
> Sicherung und ein physisch erreichbarer Not-Aus sind Voraussetzung, nicht
> Zubehör. Die App besteht bei jedem Start auf einer Checkliste, bevor sie
> überhaupt schalten lässt.

## Was sie macht

**Überwachen.** Zwei getrennte Poll-Schleifen fragen die Steckdose ab: die
schnelle (200 ms, einstellbar) liest Volt, Ampere und Watt, die langsame den
Schaltzustand. Getrennt, damit der Messpfad nie auf eine Zustandsabfrage wartet.

**Abschalten.** Vier Ebenen, von denen nur die äußeren beiden verlässlich sind:

1. Physischer Schutz — nicht in der App, aber Voraussetzung.
2. Sicherheits-Checkliste vor jeder Bedienung, ohne Merkfunktion.
3. **Selbstabschaltung in der Dose.** Die App erneuert alle paar Sekunden einen
   Auftrag `addRepeatingEventID <fenster> 1 <id> POWER OFF`. Bricht App, iPhone
   oder WLAN weg, schaltet die Dose von selbst ab. Das ist die einzige
   Absicherung, die einen Totalausfall der App überlebt. Kennt die Firmware die
   ID-Variante nicht, wechselt die App auf `clearRepeatingEvents` +
   `addRepeatingEvent` und sagt sichtbar, dass dieser Weg zwischen Löschen und
   Setzen ein kurzes ungeschütztes Fenster hat.
4. **Stromwächter in der App** — zwei unabhängige Kriterien:
   - *Grenzwert*: Strom über Schwelle, länger als die Haltezeit.
   - *Flachheit*: Strom durchgehend über einem Verdachtswert und dabei
     auffällig ruhig. Ein brennender Bogen flackert, ein klebender Kurzschluss
     ist still. Gemessen wird die **Spannweite** (max − min) im Fenster, nicht
     die Standardabweichung — die App fragt schneller ab, als der Messchip neue
     Werte liefert, und die vielen identischen Wiederholungen würden eine
     Standardabweichung künstlich gegen null drücken und mitten im echten Bogen
     auslösen.

   Fehlen die Messwerte, gilt das als Grenzwertverletzung, nicht als Entwarnung.

**Kalibrieren.** Geführter Ablauf in drei Schritten (Leerlauf, normales
Bogenziehen, optional ein kurzer Kontakt). Daraus schlägt die App Grenzwerte
vor — ein Vorschlag, kein Gesetz: alles bleibt von Hand justierbar, weil jeder
MOT, jede Elektrode und jede Netzimpedanz anders sind.

**Filmen.** Foto, Video und Zeitlupe mit dauerhaftem Ringpuffer, sodass jeder
Auslöser auch die Sekunden davor sichert. Auslöser: Helligkeitssprung im Bild,
Leistungssprung aus dem Messstrom, Audio — einzeln oder alle zusammen.
Standard ist manuelle Belichtung, weil ein Lichtbogen jede Automatik
überstrahlt.

**Protokollieren.** Jede Messfahrt wird als Session mitgeschrieben: Messreihe,
erkannte Bögen, jede Abschaltung mit Grund und Kurvenausschnitt. Export als CSV
oder als Paket aus Messwerten, Metadaten und Aufnahmen.

## Betriebsarten

| Modus | Verhalten |
|---|---|
| Frei | Läuft, bis du ausschaltest. Selbstabschaltung sichert weiter ab. |
| Session-Timer | Schaltet nach der eingestellten Zeit selbstständig ab. |
| Puls | Automatische An/Aus-Zyklen für die eingestellte Anzahl Durchgänge. |
| Totmann-Taste | Strom nur, solange der Knopf gehalten wird — mit einigen hundert Millisekunden Latenz, das ist kein mechanischer Schalter. |

## Weitere Funktionen

Reaktives Live-Theme (die Oberfläche folgt der Momentanleistung) · Arc-Statistik
und Allzeit-Rekorde · HUD über dem Sucher · Live Activity mit Countdown ·
Session-Vergleich · Best-Frame-Extraktion aus Clips · Siri-Not-Aus ·
Export-Paket · Audiospektrum · Elektroden-Verschleisszähler · Trip-Historie ·
eigene Startanimation (Transformator und Jakobsleiter, rein in SwiftUI
gezeichnet).

## Bauen

```sh
brew install xcodegen
xcodegen generate
open HVCapture.xcodeproj
```

Das App-Icon ist gezeichnet, nicht gemalt: `tools/RenderIcon.swift` erzeugt die
drei Varianten (hell, dunkel, getönt) mit CoreGraphics. Motiv ist die
Jakobsleiter aus der Startanimation — zwei divergierende Elektroden mit einem
Bogen dazwischen. Ändern und neu erzeugen:

```sh
swift tools/RenderIcon.swift HVCapture/Assets.xcassets/AppIcon.appiconset
```

Tests:

```sh
xcodebuild -scheme HVCapture -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Die Tests decken das ab, was stillschweigend falsch sein kann: Wächter-Urteile
inklusive Grenzfällen, Kalibrierungs-Vorschläge, Befehlsbau und Auswertung.
Kamera und Netzwerk sind bewusst nicht getestet — dafür gibt es in der
Entwickler-Ansicht einen Simulationsmodus, der synthetische Messreihen
einspeist (sauberer Betrieb, konstant werdende Last, Verbindungsabriss), sodass
sich Wächter und Oberfläche ohne angeschlossene Hardware prüfen lassen.

## Einrichtung

1. Steckdose auf OpenBeken flashen und ihre IP im WLAN fixieren.
2. IP in den Einstellungen der App eintragen.
3. Fenster der Selbstabschaltung wählen (Standard 30 s).
4. Kalibrierung durchlaufen, Grenzwerte prüfen.
5. Im Dev-Mode mit dem Simulationsfall „Wird konstant" prüfen, dass die
   Flachheits-Abschaltung tatsächlich greift, **bevor** der Aufbau scharf ist.

## Aufbau

```
HVCapture/
  Model/    reine Werte, ohne Abhängigkeiten
  Core/     PlugLink (HTTP), ArcGuard (Bewertung), SessionStore, CaptureEngine,
            WatchBridge, ArcIntents
  Design/   Palette, Live-Theme, Komponenten
  Views/    Startanimation, Sicherheits-Gate, Steuerung, Kamera, Verlauf, Einstellungen
Widgets/    Live Activity und Widget
Watch/      Not-Aus am Handgelenk
Tests/      Swift Testing
```

## Stand

Drei Targets bauen ohne Warnungen (App, Widget-Extension, Watch-App), 34 Tests
laufen durch. Am echten Aufbau ist noch nichts davon erprobt — insbesondere
diese Punkte gehören vor dem ersten scharfen Einsatz auf dem Tisch verifiziert:

- Ob die Firmware `addRepeatingEventID` kennt. Tut sie es nicht, wechselt die
  App auf den Rückfallweg und zeigt das an — der ist aber schwächer.
- Ob die Selbstabschaltung tatsächlich auslöst, wenn man die App killt.
- Ob die Flachheits-Grenzwerte zum eigenen Aufbau passen (Simulationsfall
  „Wird konstant" im Dev-Mode prüft nur die Logik, nicht deine Zahlen).

Nicht umgesetzt: das Einbrennen der Messwerte ins Video (die Einstellung
existiert, die Engine wertet sie noch nicht aus) und ein Bedienweg für die
Best-Frame-Extraktion (die Funktion existiert, die Clips liegen aber in der
Fotomediathek und werden noch nicht per URL zurückgereicht).

Das Design-Dokument liegt unter
[`docs/superpowers/specs/`](docs/superpowers/specs/2026-08-08-hv-capture-design.md).
