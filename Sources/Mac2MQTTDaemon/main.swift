import AppKit
import CocoaMQTT
import CoreGraphics
import Foundation
import Yams

struct AppConfig: Decodable {
    struct MQTT: Decodable {
        let host: String
        let port: Int
        let username: String?
        let password: String?
        let useTLS: Bool
        let keepAliveSeconds: UInt16
    }

    struct Topics: Decodable {
        let base: String
    }

    struct Intervals: Decodable {
        let volumeSeconds: TimeInterval
        let batterySeconds: TimeInterval
        let displaySeconds: TimeInterval?
    }

    let computerName: String
    let mqtt: MQTT
    let topics: Topics
    let intervals: Intervals
}

enum ShellError: Error {
    case failed(String)
}

@discardableResult
func runProcess(_ launchPath: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
        throw ShellError.failed("Command failed: \(launchPath) \(args.joined(separator: " ")); \(err)")
    }
    return output
}

func currentVolume() throws -> Int {
    let output = try runProcess("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
    return Int(output) ?? 0
}

func isMuted() throws -> Bool {
    let output = try runProcess("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"])
    return output.lowercased() == "true"
}

func setVolume(_ value: Int) throws {
    let clamped = max(0, min(100, value))
    _ = try runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(clamped)"])
}

func setMuted(_ value: Bool) throws {
    let script = value ? "set volume with output muted" : "set volume without output muted"
    _ = try runProcess("/usr/bin/osascript", ["-e", script])
}

func batteryPercent() throws -> Int? {
    let output = try runProcess("/usr/bin/pmset", ["-g", "batt"])
    if !hasBattery(pmsetOutput: output) {
        return nil
    }

    let regex = try NSRegularExpression(pattern: "(\\d+)%")
    let nsString = output as NSString
    let range = NSRange(location: 0, length: nsString.length)
    if let match = regex.firstMatch(in: output, range: range),
       match.numberOfRanges > 1 {
        return Int(nsString.substring(with: match.range(at: 1)))
    }
    return nil
}

func hasBattery(pmsetOutput: String? = nil) -> Bool {
    let output = pmsetOutput ?? ((try? runProcess("/usr/bin/pmset", ["-g", "batt"])) ?? "")
    return output.localizedCaseInsensitiveContains("InternalBattery") &&
        output.localizedCaseInsensitiveContains("present: true")
}

func powerSource() throws -> String? {
    let output = try runProcess("/usr/bin/pmset", ["-g", "batt"])
    if !hasBattery(pmsetOutput: output) {
        return nil
    }

    let regex = try NSRegularExpression(pattern: "Now drawing from '([^']+)'")
    let nsString = output as NSString
    let range = NSRange(location: 0, length: nsString.length)
    guard let match = regex.firstMatch(in: output, range: range),
          match.numberOfRanges > 1 else {
        return nil
    }

    let source = nsString.substring(with: match.range(at: 1)).lowercased()
    if source.contains("battery") {
        return "battery"
    }
    if source.contains("ac power") {
        return "ac_power"
    }
    return source.replacingOccurrences(of: " ", with: "_")
}

func sleepMac() throws {
    _ = try runProcess("/usr/bin/pmset", ["sleepnow"])
}

func shutdownMac() throws {
    _ = try runProcess("/sbin/shutdown", ["-h", "now"])
}

func displaySleep() throws {
    _ = try runProcess("/usr/bin/pmset", ["displaysleepnow"])
}

func displayWake() throws {
    _ = try runProcess("/usr/bin/caffeinate", ["-u", "-t", "2"])
}

struct InstalledScreenSaver {
    let name: String
    let path: String

    var moduleName: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

func installedScreenSavers() -> [InstalledScreenSaver] {
    let fm = FileManager.default
    let paths = [
        "\(NSHomeDirectory())/Library/Screen Savers",
        "/Library/Screen Savers"
    ]

    return paths.flatMap { directory -> [InstalledScreenSaver] in
        guard let items = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return items
            .filter { $0.hasSuffix(".saver") }
            .map { item in
                let path = "\(directory)/\(item)"
                let name = URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent
                return InstalledScreenSaver(name: name, path: path)
            }
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func screenSaver(for value: String) -> InstalledScreenSaver? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    return installedScreenSavers().first {
        $0.path == trimmed || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
    }
}

func setScreenSaver(_ saver: InstalledScreenSaver) throws {
    _ = try runProcess("/usr/bin/defaults", [
        "-currentHost", "write", "com.apple.screensaver", "moduleDict",
        "-dict", "moduleName", saver.moduleName, "path", saver.path, "type", "0"
    ])
    _ = try? runProcess("/usr/bin/killall", ["cfprefsd"])
    _ = try? runProcess("/usr/bin/killall", ["WallpaperAgent"])
}

func startScreenSaver() throws {
    _ = try runProcess("/usr/bin/open", ["-b", "com.apple.ScreenSaver.Engine"])
}

func appleScriptQuoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

func speak(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    _ = try runProcess("/usr/bin/say", [text])
}

func notificationParts(from payload: String) -> (title: String, message: String) {
    let fallbackTitle = "Mac2MQTT"
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (fallbackTitle, payload)
    }

    let title = object["title"] as? String ?? fallbackTitle
    let message = object["message"] as? String ?? object["body"] as? String ?? ""
    return (title, message)
}

func showNotification(_ payload: String) throws {
    let parts = notificationParts(from: payload)
    guard !parts.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let script = """
    tell application "System Events"
        activate
        display dialog \(appleScriptQuoted(parts.message)) with title \(appleScriptQuoted(parts.title)) buttons {"OK"} default button "OK"
    end tell
    """
    _ = try runProcess("/usr/bin/osascript", ["-e", script])
}

func isSessionLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          let value = session["CGSSessionScreenIsLocked"] else {
        return false
    }

    if let locked = value as? Bool {
        return locked
    }
    if let locked = value as? NSNumber {
        return locked.boolValue
    }
    return false
}

struct AppLaunchRequest {
    let name: String?
    let path: String?
    let bundleID: String?
}

struct InstalledApp {
    let name: String
    let path: String
    let bundleID: String?
}

func installedApps() -> [InstalledApp] {
    let fm = FileManager.default
    let paths = [
        "/Applications",
        "/System/Applications",
        "\(NSHomeDirectory())/Applications"
    ]
    var seen = Set<String>()

    let apps = paths.flatMap { directory -> [InstalledApp] in
        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }
        var found: [InstalledApp] = []

        for case let item as String in enumerator {
            guard item.hasSuffix(".app") else { continue }
            if item.dropLast(4).contains(".app/") { continue }

            let path = "\(directory)/\(item)"
            guard !seen.contains(path) else { continue }
            seen.insert(path)

            let url = URL(fileURLWithPath: path)
            let name = URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: url)?.bundleIdentifier
            found.append(InstalledApp(name: name, path: path, bundleID: bundleID))
            enumerator.skipDescendants()
        }

        return found
    }

    return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func appNames() -> [String] {
    var seen = Set<String>()
    return installedApps().compactMap { app in
        guard !seen.contains(app.name) else { return nil }
        seen.insert(app.name)
        return app.name
    }
}

func screenSaverNames() -> [String] {
    installedScreenSavers().map(\.name)
}

func appLaunchRequest(from payload: String) -> AppLaunchRequest? {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let data = trimmed.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return AppLaunchRequest(
            name: object["name"] as? String,
            path: object["path"] as? String,
            bundleID: object["bundleId"] as? String ?? object["bundleID"] as? String
        )
    }

    if trimmed.hasPrefix("/") {
        return AppLaunchRequest(name: nil, path: trimmed, bundleID: nil)
    }

    if trimmed.contains(".") && !trimmed.contains(" ") {
        return AppLaunchRequest(name: nil, path: nil, bundleID: trimmed)
    }

    return AppLaunchRequest(name: trimmed, path: nil, bundleID: nil)
}

func activateRunningApp(_ request: AppLaunchRequest) -> Bool {
    let runningApp = NSWorkspace.shared.runningApplications.first { app in
        if let bundleID = request.bundleID,
           app.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame {
            return true
        }
        if let path = request.path,
           app.bundleURL?.path == path {
            return true
        }
        if let name = request.name,
           app.localizedName?.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        return false
    }

    guard let runningApp else { return false }
    return runningApp.activate(options: [.activateAllWindows])
}

func launchOrActivateApp(_ payload: String) throws {
    guard let request = appLaunchRequest(from: payload) else { return }
    if activateRunningApp(request) {
        return
    }

    if let path = request.path {
        _ = try runProcess("/usr/bin/open", [path])
        return
    }

    if let bundleID = request.bundleID,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        _ = try runProcess("/usr/bin/open", [url.path])
        return
    }

    if let name = request.name {
        _ = try runProcess("/usr/bin/open", ["-a", name])
    }
}

func isDisplayOn() -> Bool {
    var displayCount: UInt32 = 0
    let countResult = CGGetOnlineDisplayList(0, nil, &displayCount)
    guard countResult == .success, displayCount > 0 else {
        return CGDisplayIsActive(CGMainDisplayID()) != 0
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    let listResult = CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
    guard listResult == .success else {
        return CGDisplayIsActive(CGMainDisplayID()) != 0
    }

    return displays.prefix(Int(displayCount)).contains { CGDisplayIsActive($0) != 0 }
}

func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

final class Daemon: NSObject, CocoaMQTTDelegate {
    private let config: AppConfig
    private let mqtt: CocoaMQTT
    private var volumeTimer: DispatchSourceTimer?
    private var batteryTimer: DispatchSourceTimer?
    private var displayTimer: DispatchSourceTimer?
    private var lastDisplayState: Bool?
    private var lastDisplayChangedAt = Date()
    private var clearedBatteryStatus = false
    private var clearedRemovedStatusTopics = false

    private var baseTopic: String {
        "\(config.topics.base)/\(config.computerName)"
    }

    init(config: AppConfig) {
        self.config = config
        self.mqtt = CocoaMQTT(clientID: "mac2mqttd-\(config.computerName)-\(UUID().uuidString.prefix(8))",
                              host: config.mqtt.host,
                              port: UInt16(config.mqtt.port))
        super.init()

        mqtt.username = config.mqtt.username
        mqtt.password = config.mqtt.password
        mqtt.keepAlive = config.mqtt.keepAliveSeconds
        mqtt.enableSSL = config.mqtt.useTLS
        mqtt.autoReconnect = true
        mqtt.delegate = self
        mqtt.willMessage = CocoaMQTTMessage(topic: "\(baseTopic)/status/alive",
                                            string: "false",
                                            qos: .qos1,
                                            retained: true)
    }

    func start() {
        print("Starting mac2mqttd ...")
        _ = mqtt.connect()
    }

    private func publishStatus() {
        do {
            publishStatusTopic("volume", String(try currentVolume()))
            publishStatusTopic("mute", String(try isMuted()))
            clearRemovedStatusTopics()
            publishBatteryStatus()
            publishDisplayStatus()
            publishLockStatus()
        } catch {
            print("Status update error: \(error)")
        }
    }

    private func publishStatusTopic(_ suffix: String, _ value: String) {
        mqtt.publish("\(baseTopic)/status/\(suffix)", withString: value, qos: .qos0, retained: true)
    }

    private func publishDiscoveryTopic(_ component: String, _ objectID: String, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        mqtt.publish("homeassistant/\(component)/\(config.computerName)/\(objectID)/config",
                     withString: json,
                     qos: .qos0,
                     retained: true)
    }

    private func clearDiscoveryTopic(_ component: String, _ objectID: String) {
        let message = CocoaMQTTMessage(topic: "homeassistant/\(component)/\(config.computerName)/\(objectID)/config",
                                      payload: [],
                                      qos: .qos0,
                                      retained: true)
        mqtt.publish(message)
    }

    private func publishHomeAssistantDiscovery() {
        let device: [String: Any] = [
            "identifiers": ["mac2mqtt_\(config.computerName)"],
            "name": config.computerName,
            "manufacturer": "mac2mqtt",
            "model": "Mac"
        ]

        publishDiscoveryTopic("select", "app", [
            "name": "App",
            "unique_id": "mac2mqtt_\(config.computerName)_app",
            "command_topic": "\(baseTopic)/command/app",
            "availability_topic": "\(baseTopic)/status/alive",
            "payload_available": "true",
            "payload_not_available": "false",
            "optimistic": true,
            "icon": "mdi:application",
            "options": appNames(),
            "device": device
        ])

        publishDiscoveryTopic("select", "screensaver", [
            "name": "Screensaver",
            "unique_id": "mac2mqtt_\(config.computerName)_screensaver",
            "command_topic": "\(baseTopic)/command/screensaver",
            "availability_topic": "\(baseTopic)/status/alive",
            "payload_available": "true",
            "payload_not_available": "false",
            "optimistic": true,
            "icon": "mdi:monitor-screenshot",
            "options": screenSaverNames(),
            "device": device
        ])

        clearDiscoveryTopic("sensor", "apps")
        if !hasBattery() {
            clearDiscoveryTopic("sensor", "battery")
            clearDiscoveryTopic("sensor", "power_source")
        }
    }

    private func clearRetainedStatusTopic(_ suffix: String) {
        let message = CocoaMQTTMessage(topic: "\(baseTopic)/status/\(suffix)", payload: [], qos: .qos0, retained: true)
        mqtt.publish(message)
    }

    private func clearRemovedStatusTopics() {
        guard !clearedRemovedStatusTopics else { return }
        clearRetainedStatusTopic("apps")
        clearRetainedStatusTopic("screensaver_selected")
        clearedRemovedStatusTopics = true
    }

    private func publishBatteryStatus() {
        do {
            guard hasBattery() else {
                clearRetainedStatusTopic("battery")
                clearRetainedStatusTopic("power_source")
                clearedBatteryStatus = true
                return
            }

            clearedBatteryStatus = false
            if let percent = try batteryPercent() {
                publishStatusTopic("battery", String(percent))
                publishStatusTopic("power_source", try powerSource() ?? "")
            }
        } catch {
            print("Battery status error: \(error)")
        }
    }

    private func publishLockStatus() {
        publishStatusTopic("locked", String(isSessionLocked()))
    }

    private func publishDisplayStatus() {
        let displayOn = isDisplayOn()
        if let lastDisplayState, lastDisplayState != displayOn {
            lastDisplayChangedAt = Date()
        }
        lastDisplayState = displayOn

        publishStatusTopic("display", String(displayOn))
        publishStatusTopic("display_changed_at", isoTimestamp(lastDisplayChangedAt))
    }

    private func schedulePolling() {
        cancelPolling()

        let volumeTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        volumeTimer.schedule(deadline: .now(), repeating: config.intervals.volumeSeconds)
        volumeTimer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                self.publishStatusTopic("volume", String(try currentVolume()))
                self.publishStatusTopic("mute", String(try isMuted()))
            } catch {
                print("Volume poll error: \(error)")
            }
        }
        volumeTimer.resume()
        self.volumeTimer = volumeTimer

        let batteryTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        batteryTimer.schedule(deadline: .now(), repeating: config.intervals.batterySeconds)
        batteryTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishBatteryStatus()
        }
        batteryTimer.resume()
        self.batteryTimer = batteryTimer

        let displayTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        displayTimer.schedule(deadline: .now(), repeating: config.intervals.displaySeconds ?? 5)
        displayTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishDisplayStatus()
            self.publishLockStatus()
        }
        displayTimer.resume()
        self.displayTimer = displayTimer
    }

    private func cancelPolling() {
        volumeTimer?.cancel()
        volumeTimer = nil
        batteryTimer?.cancel()
        batteryTimer = nil
        displayTimer?.cancel()
        displayTimer = nil
    }

    private func subscribeCommands() {
        mqtt.subscribe("\(baseTopic)/command/#", qos: .qos1)
    }

    private func handleCommand(topic: String, payload: String) {
        switch topic {
        case "\(baseTopic)/command/volume":
            if let value = Int(payload) {
                try? setVolume(value)
            }
        case "\(baseTopic)/command/mute":
            try? setMuted(payload.lowercased() == "true")
        case "\(baseTopic)/command/sleep":
            if payload == "sleep" { try? sleepMac() }
        case "\(baseTopic)/command/shutdown":
            if payload == "shutdown" { try? shutdownMac() }
        case "\(baseTopic)/command/displaysleep":
            if payload == "displaysleep" { try? displaySleep() }
        case "\(baseTopic)/command/displaywake":
            if payload == "displaywake" || payload == "wake" { try? displayWake() }
        case "\(baseTopic)/command/display":
            if payload == "sleep" {
                try? displaySleep()
            } else if payload == "wake" {
                try? displayWake()
            }
        case "\(baseTopic)/command/say":
            try? speak(payload)
        case "\(baseTopic)/command/notification":
            try? showNotification(payload)
        case "\(baseTopic)/command/screensaver":
            if let saver = screenSaver(for: payload) {
                try? setScreenSaver(saver)
                try? startScreenSaver()
            } else if payload == "start" {
                try? startScreenSaver()
            }
        case "\(baseTopic)/command/app":
            try? launchOrActivateApp(payload)
        default:
            break
        }

        publishStatus()
    }

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            print("MQTT connect failed: \(ack)")
            return
        }
        print("Connected to MQTT")
        mqtt.publish("\(baseTopic)/status/alive", withString: "true", qos: .qos1, retained: true)
        publishHomeAssistantDiscovery()
        subscribeCommands()
        publishStatus()
        schedulePolling()
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        print("Disconnected: \(err?.localizedDescription ?? "none")")
        cancelPolling()
    }
    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = message.string ?? ""
        handleCommand(topic: message.topic, payload: payload)
    }
}

func loadConfig() throws -> AppConfig {
    let args = CommandLine.arguments
    let configPath: String
    if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) {
        configPath = args[index + 1]
    } else {
        configPath = "\(NSHomeDirectory())/mac2mqtt/mac2mqtt.yaml"
    }

    let content = try String(contentsOfFile: configPath, encoding: .utf8)
    return try YAMLDecoder().decode(AppConfig.self, from: content)
}

do {
    let config = try loadConfig()
    let daemon = Daemon(config: config)
    daemon.start()
    dispatchMain()
} catch {
    fputs("Startup error: \(error)\n", stderr)
    exit(1)
}
