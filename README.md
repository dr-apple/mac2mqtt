# mac2mqtt-modern (`mac2mqttd` + `mac2mqtt-ui`)

Modernisierte Swift-Version von `mac2mqtt` fuer aktuelle macOS-Versionen:

- `mac2mqttd` = Daemon (MQTT + macOS Steuerung)
- `mac2mqtt-ui` = Menu-Bar App (Start/Stop/Restart, Settings, Logs)

## Features

- Publiziert:
  - `status/alive`
  - `status/volume`
  - `status/mute`
  - `status/battery`
- Reagiert auf:
  - `command/volume`
  - `command/mute`
  - `command/sleep`
  - `command/shutdown`
  - `command/displaysleep`

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
