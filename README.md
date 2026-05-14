# mac2mqtt-modern (`mac2mqttd` + `mac2mqtt-ui`)

Modernisierte Swift-Version von `mac2mqtt` fuer aktuelle macOS-Versionen:

- `mac2mqttd` = Daemon (MQTT + macOS Steuerung)
- `mac2mqtt-ui` = Menu-Bar App (Start/Stop/Restart, Settings, Logs)

## Features

- Publiziert:
  - `status/alive`
  - `status/volume`
  - `status/mute`
  - `status/battery` (nur bei Macs mit internem Akku)
  - `status/power_source` (`ac_power` oder `battery`, nur bei Macs mit internem Akku)
  - `status/display` (`true` = Monitor an, `false` = Monitor aus)
  - `status/display_changed_at` (ISO-8601-Zeitstempel des letzten Monitor-Statuswechsels)
  - `status/locked` (`true` = Benutzer-Session ist gesperrt)
- Reagiert auf:
  - `command/volume`
  - `command/mute`
  - `command/sleep`
  - `command/shutdown`
  - `command/displaysleep`
  - `command/displaywake`
  - `command/display` (`sleep` oder `wake`)
  - `command/say` (Payload wird per macOS-Sprachausgabe vorgelesen)
  - `command/notification` (Payload als Text oder JSON: `{"title":"Titel","message":"Text"}`; erscheint immer als Vordergrund-Dialog)
  - `command/screensaver` (Name eines nachinstallierten `.saver`)
  - `command/app` (App per Payload als Name/Pfad/Bundle-ID starten oder aktivieren)

Damit kannst du z.B. unter `<base>/<computerName>/status/display` sehen, ob mindestens ein angeschlossener Monitor aktiv ist, und unter `<base>/<computerName>/status/display_changed_at`, wann dieser Zustand zuletzt gewechselt hat.
Auf Macs ohne internen Akku werden `status/battery` und `status/power_source` nicht veroeffentlicht; vorhandene retained Werte werden einmal geloescht.
Apps koennen per Payload als Name (`Safari`), Bundle-ID (`com.apple.Safari`), Pfad (`/Applications/Safari.app`) oder JSON (`{"name":"Safari"}`) gestartet bzw. aktiviert werden.
Home Assistant bekommt per MQTT Discovery je eine `select`-Entitaet fuer `App` und `Screensaver`. Die Optionen werden aus installierten Apps bzw. nachinstallierten Bildschirmschonern aus `~/Library/Screen Savers` und `/Library/Screen Savers` erzeugt.

Topic-Schema:

`<base>/<computerName>/status/...` und `<base>/<computerName>/command/...`

## Einfach als .app (Drag & Drop)

Genau fuer deinen Use Case:

```bash
cd /Users/USERNAME/mac2mqtt-modern
./build-app.sh
```

Danach liegt die App hier:

`/Users/USERNAME/mac2mqtt-modern/dist/Mac2MQTT.app`

Die App dann einfach nach `Programme` ziehen.
Das Finder-/Remote-Symbol wird dabei automatisch als App-Icon gesetzt.

Beim ersten `Start Service` in der Menu-Bar macht die App alles selbst:

- installiert `mac2mqttd` nach `~/mac2mqtt/`
- legt `~/mac2mqtt/mac2mqtt.yaml` an (falls nicht vorhanden)
- erzeugt und startet den `launchd` LaunchAgent

## Build (Entwicklung)

```bash
cd /Users/USERNAME/mac2mqtt-modern
swift build -c release
```

Binaries liegen danach unter:

- `./.build/release/mac2mqttd`
- `./.build/release/mac2mqtt-ui`

## Setup

1. Arbeitsordner anlegen:

```bash
mkdir -p /Users/USERNAME/mac2mqtt
```

2. Daemon und Config kopieren:

```bash
cp ./.build/release/mac2mqttd /Users/USERNAME/mac2mqtt/
cp ./mac2mqtt.yaml.example /Users/USERNAME/mac2mqtt/mac2mqtt.yaml
chmod +x /Users/USERNAME/mac2mqtt/mac2mqttd
```

3. `mac2mqtt.yaml` anpassen.

## Als Daemon starten (launchd)

Hinweis: Fuer User-Hintergrunddienste ist `LaunchAgents` der moderne und sichere Weg.

```bash
cp ./com.example.mac2mqttd.plist /Users/USERNAME/Library/LaunchAgents/com.example.mac2mqttd.plist
```

Dann in der plist `USERNAME` ersetzen und laden:

```bash
launchctl bootstrap gui/$(id -u) /Users/USERNAME/Library/LaunchAgents/com.example.mac2mqttd.plist
launchctl enable gui/$(id -u)/com.example.mac2mqttd
launchctl kickstart -k gui/$(id -u)/com.example.mac2mqttd
```

Stoppen:

```bash
launchctl bootout gui/$(id -u)/com.example.mac2mqttd
```

## Testlauf ohne launchd

```bash
/Users/USERNAME/mac2mqtt/mac2mqttd --config /Users/USERNAME/mac2mqtt/mac2mqtt.yaml
```

## Menu-Bar App starten (ohne Bundle)

Die UI verwaltet `launchd` fuer dich und schreibt Config/Plist automatisch an die richtigen Stellen.

```bash
cd /Users/USERNAME/mac2mqtt-modern
./.build/release/mac2mqtt-ui
```

Dann in der Menu-Bar:

- `Settings` fuer MQTT-Host, Topics und Poll-Intervalle
- `Start Service` / `Stop Service` / `Restart Service`
- `Logs` fuer stdout/stderr vom Daemon

## Optional: UI als .app Bundle bauen

Wenn du die UI als klickbare App haben willst:

```bash
mkdir -p Mac2MQTTUI.app/Contents/MacOS
cp ./.build/release/mac2mqtt-ui Mac2MQTTUI.app/Contents/MacOS/mac2mqtt-ui
cat > Mac2MQTTUI.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>mac2mqtt-ui</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.mac2mqtt-ui</string>
  <key>CFBundleName</key>
  <string>Mac2MQTTUI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF
open ./Mac2MQTTUI.app
```

## Home Assistant

Die MQTT-Topics sind bewusst kompatibel zur bisherigen `mac2mqtt`-Logik gehalten, damit bestehende Automationen weiter funktionieren.
