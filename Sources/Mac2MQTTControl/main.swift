import AppKit
import Foundation
import Yams

struct AppConfig: Codable {
    struct MQTT: Codable {
        var host: String
        var port: Int
        var username: String?
        var password: String?
        var useTLS: Bool
        var keepAliveSeconds: UInt16
    }

    struct Topics: Codable {
        var base: String
    }

    struct Intervals: Codable {
        var volumeSeconds: TimeInterval
        var batterySeconds: TimeInterval
    }

    var computerName: String
    var mqtt: MQTT
    var topics: Topics
    var intervals: Intervals
}

enum Paths {
    static let home = NSHomeDirectory()
    static let appDir = "\(home)/mac2mqtt"
    static let daemonPath = "\(appDir)/mac2mqttd"
    static let configPath = "\(appDir)/mac2mqtt.yaml"
    static let plistPath = "\(home)/Library/LaunchAgents/com.example.mac2mqttd.plist"
    static let logsPath = "\(home)/Library/Logs/mac2mqttd.log"
    static let errorsPath = "\(home)/Library/Logs/mac2mqttd.error.log"
}

@discardableResult
func run(_ command: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "Failed to run \(command): \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
}

func ensureBaseFiles() {
    _ = run("/bin/mkdir", ["-p", Paths.appDir])
    _ = run("/bin/mkdir", ["-p", "\(Paths.home)/Library/LaunchAgents"])
    _ = run("/bin/mkdir", ["-p", "\(Paths.home)/Library/Logs"])
}

func bundledResourcePath(_ name: String) -> String? {
    Bundle.main.resourceURL?.appendingPathComponent(name).path
}

func installBundledRuntimeIfNeeded() -> String? {
    let fm = FileManager.default

    guard let bundledDaemon = bundledResourcePath("mac2mqttd") else {
        return "Bundled daemon nicht gefunden. Bitte App neu bauen."
    }

    do {
        if !fm.fileExists(atPath: Paths.daemonPath) {
            try fm.copyItem(atPath: bundledDaemon, toPath: Paths.daemonPath)
            _ = run("/bin/chmod", ["755", Paths.daemonPath])
        }

        if !fm.fileExists(atPath: Paths.configPath) {
            if let bundledConfig = bundledResourcePath("mac2mqtt.yaml.example"), fm.fileExists(atPath: bundledConfig) {
                try fm.copyItem(atPath: bundledConfig, toPath: Paths.configPath)
            } else {
                let yaml = try YAMLEncoder().encode(defaultConfig())
                try yaml.write(toFile: Paths.configPath, atomically: true, encoding: .utf8)
            }
        }
    } catch {
        return "Runtime-Installation fehlgeschlagen: \(error.localizedDescription)"
    }

    return nil
}

func defaultConfig() -> AppConfig {
    AppConfig(
        computerName: Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased() ?? "my-macbook",
        mqtt: .init(host: "127.0.0.1", port: 1883, username: nil, password: nil, useTLS: false, keepAliveSeconds: 30),
        topics: .init(base: "mac2mqtt"),
        intervals: .init(volumeSeconds: 2, batterySeconds: 60)
    )
}

func loadConfig() -> AppConfig {
    let path = Paths.configPath
    guard FileManager.default.fileExists(atPath: path),
          let content = try? String(contentsOfFile: path, encoding: .utf8),
          let cfg = try? YAMLDecoder().decode(AppConfig.self, from: content) else {
        return defaultConfig()
    }
    return cfg
}

func saveConfig(_ config: AppConfig) -> String? {
    do {
        let yaml = try YAMLEncoder().encode(config)
        try yaml.write(toFile: Paths.configPath, atomically: true, encoding: .utf8)
        return nil
    } catch {
        return "Config konnte nicht gespeichert werden: \(error.localizedDescription)"
    }
}

func writeLaunchAgentPlist() -> String? {
    let content = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.example.mac2mqttd</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(Paths.daemonPath)</string>
            <string>--config</string>
            <string>\(Paths.configPath)</string>
        </array>
        <key>WorkingDirectory</key>
        <string>\(Paths.appDir)</string>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(Paths.logsPath)</string>
        <key>StandardErrorPath</key>
        <string>\(Paths.errorsPath)</string>
    </dict>
    </plist>
    """
    do {
        try content.write(toFile: Paths.plistPath, atomically: true, encoding: .utf8)
        return nil
    } catch {
        return "LaunchAgent plist konnte nicht geschrieben werden: \(error.localizedDescription)"
    }
}

func serviceState() -> Bool {
    let uid = String(getuid())
    let (code, out) = run("/bin/launchctl", ["print", "gui/\(uid)/com.example.mac2mqttd"])
    return code == 0 && !out.isEmpty
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitorTimer: Timer?
    private var settingsWindow: NSWindow?
    private var logsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureBaseFiles()
        buildMenu()
        refreshStateTitle()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStateTitle()
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeMenuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Status: unknown", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Start Service", action: #selector(startService), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop Service", action: #selector(stopService), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Restart Service", action: #selector(restartService), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Logs", action: #selector(openLogs), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            image.isTemplate = true
            return image
        }

        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setFillColor(NSColor.clear.cgColor)

        // Outer rounded shape: hybrid Finder/remote shell.
        let outer = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 1.2, width: 15.6, height: 15.6), xRadius: 4.2, yRadius: 4.2)
        outer.stroke()

        // Vertical split like Finder face.
        let split = NSBezierPath()
        split.move(to: NSPoint(x: 9.0, y: 2.5))
        split.line(to: NSPoint(x: 9.0, y: 15.5))
        split.stroke()

        // Left side: finder-like eye + smile.
        let leftEye = NSBezierPath(ovalIn: NSRect(x: 5.2, y: 11.1, width: 1.5, height: 1.5))
        leftEye.fill()

        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 4.8, y: 6.5))
        smile.curve(to: NSPoint(x: 8.0, y: 5.7),
                    controlPoint1: NSPoint(x: 5.8, y: 5.2),
                    controlPoint2: NSPoint(x: 6.9, y: 5.3))
        smile.stroke()

        // Right side: remote control directional ring + buttons.
        let ring = NSBezierPath(ovalIn: NSRect(x: 10.2, y: 9.0, width: 4.0, height: 4.0))
        ring.stroke()

        let center = NSBezierPath(ovalIn: NSRect(x: 11.7, y: 10.5, width: 1.0, height: 1.0))
        center.fill()

        let button1 = NSBezierPath(ovalIn: NSRect(x: 11.0, y: 6.2, width: 1.2, height: 1.2))
        button1.fill()
        let button2 = NSBezierPath(ovalIn: NSRect(x: 13.0, y: 6.2, width: 1.2, height: 1.2))
        button2.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func setStatus(_ text: String) {
        statusItem.menu?.items.first?.title = "Status: \(text)"
    }

    private func refreshStateTitle() {
        setStatus(serviceState() ? "running" : "stopped")
    }

    @objc private func startService() {
        if let installError = installBundledRuntimeIfNeeded() {
            showAlert("Installationsfehler", installError)
            return
        }
        if let err = writeLaunchAgentPlist() {
            showAlert("Fehler", err)
            return
        }
        let uid = String(getuid())
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/com.example.mac2mqttd"])
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", Paths.plistPath])
        _ = run("/bin/launchctl", ["enable", "gui/\(uid)/com.example.mac2mqttd"])
        let (_, out) = run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.example.mac2mqttd"])
        refreshStateTitle()
        if !out.isEmpty { print(out) }
    }

    @objc private func stopService() {
        let uid = String(getuid())
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/com.example.mac2mqttd"])
        refreshStateTitle()
    }

    @objc private func restartService() {
        stopService()
        startService()
    }

    @objc private func openSettings() {
        let cfg = loadConfig()
        let vc = SettingsViewController(config: cfg) { [weak self] newConfig in
            if let error = saveConfig(newConfig) {
                self?.showAlert("Fehler", error)
                return
            }
            self?.showAlert("Gespeichert", "Konfiguration wurde gespeichert.")
        }
        let window = NSWindow(contentViewController: vc)
        window.title = "mac2mqtt Settings"
        window.setContentSize(NSSize(width: 540, height: 380))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func openLogs() {
        let vc = LogsViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = "mac2mqtt Logs"
        window.setContentSize(NSSize(width: 820, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        logsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

final class SettingsViewController: NSViewController {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void

    private let computerName = NSTextField()
    private let mqttHost = NSTextField()
    private let mqttPort = NSTextField()
    private let mqttUser = NSTextField()
    private let mqttPass = NSSecureTextField()
    private let mqttTls = NSButton(checkboxWithTitle: "MQTT TLS aktivieren", target: nil, action: nil)
    private let topicBase = NSTextField()
    private let volumeInterval = NSTextField()
    private let batteryInterval = NSTextField()

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let grid = NSGridView(views: [
            [label("Computer Name"), computerName],
            [label("MQTT Host"), mqttHost],
            [label("MQTT Port"), mqttPort],
            [label("MQTT User"), mqttUser],
            [label("MQTT Password"), mqttPass],
            [label("Topic Base"), topicBase],
            [label("Volume Intervall (s)"), volumeInterval],
            [label("Battery Intervall (s)"), batteryInterval]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let saveButton = NSButton(title: "Speichern", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        mqttTls.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(grid)
        root.addSubview(mqttTls)
        root.addSubview(saveButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            mqttTls.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            mqttTls.leadingAnchor.constraint(equalTo: grid.leadingAnchor),

            saveButton.topAnchor.constraint(equalTo: mqttTls.bottomAnchor, constant: 20),
            saveButton.trailingAnchor.constraint(equalTo: grid.trailingAnchor)
        ])

        fillValues()
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        return l
    }

    private func fillValues() {
        computerName.stringValue = config.computerName
        mqttHost.stringValue = config.mqtt.host
        mqttPort.stringValue = String(config.mqtt.port)
        mqttUser.stringValue = config.mqtt.username ?? ""
        mqttPass.stringValue = config.mqtt.password ?? ""
        topicBase.stringValue = config.topics.base
        volumeInterval.stringValue = String(Int(config.intervals.volumeSeconds))
        batteryInterval.stringValue = String(Int(config.intervals.batterySeconds))
        mqttTls.state = config.mqtt.useTLS ? .on : .off
    }

    @objc private func saveTapped() {
        config.computerName = computerName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.mqtt.host = mqttHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.mqtt.port = Int(mqttPort.stringValue) ?? 1883
        config.mqtt.username = mqttUser.stringValue.isEmpty ? nil : mqttUser.stringValue
        config.mqtt.password = mqttPass.stringValue.isEmpty ? nil : mqttPass.stringValue
        config.mqtt.useTLS = mqttTls.state == .on
        config.topics.base = topicBase.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.intervals.volumeSeconds = TimeInterval(Int(volumeInterval.stringValue) ?? 2)
        config.intervals.batterySeconds = TimeInterval(Int(batteryInterval.stringValue) ?? 60)
        onSave(config)
    }
}

final class LogsViewController: NSViewController {
    private let textView = NSTextView()
    private var timer: Timer?

    override func loadView() {
        let root = NSView()
        view = root

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let out = (try? String(contentsOfFile: Paths.logsPath, encoding: .utf8)) ?? "(no stdout log yet)\n"
        let err = (try? String(contentsOfFile: Paths.errorsPath, encoding: .utf8)) ?? "(no stderr log yet)\n"
        textView.string = "=== stdout ===\n\(out)\n\n=== stderr ===\n\(err)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
