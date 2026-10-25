# DropNotch

Werbefreier Nachbau der Kernfunktionen von NotchBox für macOS: eine Datei-Ablage und eine Spotify-Steuerung direkt in der Notch.

> Unabhängiges Hobbyprojekt, nicht mit NotchBox oder Spotify verbunden.

## Funktionen

- **Datei-Ablage:** Zieh eine Datei zur Notch. Sie klappt auf („Hier ablegen“), und du lässt die Datei fallen. Später fährst du mit der Maus über die Notch und ziehst die Datei wieder heraus, in jedes Programm oder jeden Ordner.
  - Doppelklick öffnet die Datei. Rechtsklick bietet Öffnen, Im Finder zeigen, AirDrop und Entfernen.
  - Die Ablage bleibt auch nach einem Neustart erhalten.
  - Standardmäßig wird die Datei nur verlinkt. Im Menü kannst du stattdessen **„Dateien kopieren statt verlinken“** einstellen; dann bleibt die Datei erhalten, auch wenn das Original gelöscht wird.
  - Bilder aus dem Browser (ohne echte Datei) werden als PNG gespeichert.
- **Spotify:** Cover, Titel, Interpret, Fortschrittsbalken (zum Spulen anklicken oder ziehen), Play/Pause, vor und zurück.
  - Wenn Musik läuft, zeigt auch die geschlossene Notch Cover und Equalizer (lässt sich im Menü abschalten).
- **Menüleisten-Icon:** Ablage öffnen oder leeren, Einstellungen, Autostart, Beenden.
- Auf Macs ohne Notch liegt eine unsichtbare Zone oben in der Mitte der Menüleiste.

## Bauen und starten

Voraussetzung: Xcode bzw. die Command Line Tools, macOS 14 oder neuer.

```bash
scripts/build-app.sh --run       # bauen und starten
scripts/build-app.sh --install   # nach /Applications kopieren (nötig für „Bei Anmeldung starten“)
```

Beim ersten Klick auf Play fragt macOS, ob DropNotch Spotify steuern darf. Erlauben.

> Tipp: Mit Ad-hoc-Signatur fragt macOS nach **jedem** Neu-Bauen erneut nach. Mit einem
> Entwicklerzertifikat passiert das nicht:
> `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install`

In Xcode öffnen: `open Package.swift`

## Wie es funktioniert

| Teil | Datei | Technik |
|---|---|---|
| Fenster | `NotchPanel.swift` | Rahmenloses `NSPanel` über der Menüleiste, ohne Aktivierung, auf allen Spaces |
| Hover und Drag | `NotchViewModel.swift` | Fragt 30-mal pro Sekunde `NSEvent.mouseLocation` ab. Einen systemweiten Datei-Drag erkennt es am `changeCount` des Drag-Pasteboards. Ist die Notch zu, lässt das Panel Klicks durch (`ignoresMouseEvents`). |
| Notch-Größe | `NotchViewModel.updateScreen()` | `safeAreaInsets.top` und `auxiliaryTopLeft/RightArea` des Displays |
| Ablage | `ShelfStore.swift` | JSON und Bookmarks in `~/Library/Application Support/DropNotch` |
| Spotify | `SpotifyController.swift` | AppleScript zum Abfragen und Steuern, außerdem die Distributed Notification `com.spotify.client.PlaybackStateChanged` |

Warum AppleScript statt MediaRemote? Das private MediaRemote-Framework funktioniert seit macOS 15.4 für Dritt-Apps nicht mehr zuverlässig. Spotifys AppleScript-Schnittstelle ist dagegen stabil.

## Ideen für später

- Apple Music (über dieselbe AppleScript-Technik)
- Mehrere Dateien auf einmal herausziehen
- Zwischenablage-Verlauf, Kalender, Timer

## Lizenz

MIT, siehe [LICENSE](LICENSE). Jeder darf den Code frei nutzen, ändern und weitergeben.
