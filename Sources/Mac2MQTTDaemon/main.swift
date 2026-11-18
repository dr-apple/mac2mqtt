import AppKit
import CocoaMQTT
import CoreGraphics
import Darwin
import Foundation
import IOKit
import ObjectiveC
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
        let mediaSeconds: TimeInterval?
    }

    let computerName: String
    let mqtt: MQTT
    let topics: Topics
    let intervals: Intervals
}

enum ShellError: Error {
    case failed(String)
}

func logMessage(_ message: String) {
    print(message)
    fflush(stdout)
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
    for attempt in 1...2 {
        _ = try runProcess("/usr/bin/osascript", ["-e", script])
        if (try? isMuted()) == value { return }
        logMessage("Mute: Zustand nach Versuch \(attempt) nicht \(value), wiederhole")
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw NSError(domain: "mac2mqtt", code: 1, userInfo: [NSLocalizedDescriptionKey: "mute=\(value) wurde nicht übernommen"])
}

enum MediaPlaybackCommand {
    case play
    case pause
    case toggle
}

extension MediaPlaybackCommand {
    var mediaRemoteValue: Int32 {
        switch self {
        case .play:
            return 0
        case .pause:
            return 1
        case .toggle:
            return 2
        }
    }
}

final class MediaRemote: @unchecked Sendable {
    typealias IsPlayingBlock = @convention(block) (Bool) -> Void
    typealias GetIsPlaying = @convention(c) (DispatchQueue, AnyObject) -> Void
    typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, AnyObject) -> Void
    typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void

    static let shared = MediaRemote()

    private let getIsPlaying: GetIsPlaying?
    private let getNowPlayingInfo: GetNowPlayingInfo?
    private let sendCommand: SendCommand?

    private init() {
        let framework = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )

        if let symbol = framework.flatMap({ dlsym($0, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") }) {
            getIsPlaying = unsafeBitCast(symbol, to: GetIsPlaying.self)
        } else {
            getIsPlaying = nil
        }

        if let symbol = framework.flatMap({ dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }) {
            getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
        } else {
            getNowPlayingInfo = nil
        }

        if let symbol = framework.flatMap({ dlsym($0, "MRMediaRemoteSendCommand") }) {
            sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
        } else {
            sendCommand = nil
        }
    }

    func isPlaying(timeout: TimeInterval = 1.0) -> Bool? {
        let assertionPlaying = isMediaPlaybackActiveByAssertions()
        if assertionPlaying == true {
            return true
        }

        return isPlayingFromMediaRemote(timeout: timeout) ?? assertionPlaying
    }

    func isPlayingFromMediaRemote(timeout: TimeInterval = 1.0) -> Bool? {
        let playbackRatePlaying = nowPlayingPlaybackRate(timeout: timeout).map { $0 > 0.01 }
        let applicationPlaying = nowPlayingApplicationIsPlaying(timeout: timeout)

        if playbackRatePlaying == nil && applicationPlaying == nil {
            return nil
        }

        return (playbackRatePlaying == true) || (applicationPlaying == true)
    }

    private func nowPlayingApplicationIsPlaying(timeout: TimeInterval = 1.0) -> Bool? {
        guard let getIsPlaying else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Bool?

        let callback: IsPlayingBlock = { playing in
            result = playing
            semaphore.signal()
        }
        let callbackObject = unsafeBitCast(callback, to: AnyObject.self)
        getIsPlaying(DispatchQueue.global(qos: .utility), callbackObject)

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        return result
    }

    func nowPlayingPlaybackRate(timeout: TimeInterval = 1.0) -> Double? {
        guard let getNowPlayingInfo else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Double?

        let callback: InfoBlock = { info in
            guard let info else {
                semaphore.signal()
                return
            }

            let dict = info as NSDictionary
            if let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber {
                result = rate.doubleValue
            } else if let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double {
                result = rate
            } else if let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? String {
                result = Double(rate)
            }
            semaphore.signal()
        }

        let callbackObject = unsafeBitCast(callback, to: AnyObject.self)
        getNowPlayingInfo(DispatchQueue.global(qos: .utility), callbackObject)

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        return result
    }

    func send(_ command: MediaPlaybackCommand) -> Bool {
        guard let sendCommand else { return false }
        sendCommand(command.mediaRemoteValue, nil)
        return true
    }

    func isMediaPlaybackActiveByAssertions() -> Bool? {
        guard let output = try? runProcess("/usr/bin/pmset", ["-g", "assertions"]) else {
            return nil
        }

        // Nur echte „Playing audio“-Zusicherungen von Apps (Browser, Player).
        // "resources: audio-out" (coreaudiod) und "Video Wake Lock" bleiben oft stehen, obwohl nichts läuft.
        return output.lowercased().contains("named: \"playing audio\"")
    }
}

/// Startet /usr/bin/perl mit libMac2MQTTNowPlaying.dylib und liest den Now-Playing-Zustand als JSON-Zeilen.
final class NowPlayingMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var state: Bool?
    private var pid: Int32?
    private var lastUpdate = Date.distantPast
    private var stopped = false
    private var failures = 0
    var onChange: ((Bool) -> Void)?

    static func libraryPath() -> String? {
        let fm = FileManager.default
        let name = "libMac2MQTTNowPlaying.dylib"
        var dirs: [String] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path { dirs.append(exe) }
        dirs.append("\(NSHomeDirectory())/mac2mqtt")
        return dirs.map { "\($0)/\(name)" }.first { fm.fileExists(atPath: $0) }
    }

    /// PID der aktuellen Now-Playing-App (nil, wenn unbekannt).
    var nowPlayingPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastUpdate) < 15 ? pid : nil
    }

    /// true/false, wenn der Helfer läuft und frisch gemeldet hat; sonst nil.
    var playing: Bool? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastUpdate) < 15 ? state : nil
    }

    func start() {
        guard let lib = Self.libraryPath() else {
            logMessage("Now Playing: libMac2MQTTNowPlaying.dylib nicht gefunden, nutze Fallback")
            return
        }
        let script = "use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); " +
            "my $s = DynaLoader::dl_find_symbol($l, 'mac2mqtt_np_stream') or die 'symbol'; " +
            "&{DynaLoader::dl_install_xsub('main::np', $s)}();"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", script, lib]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let stop = self.stopped; self.failures += 1; let f = self.failures; self.lock.unlock()
            if stop { return }
            logMessage("Now Playing: Helfer beendet, Neustart in \(min(60, 2 * f)) s")
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(min(60, 2 * f))) { self.start() }
        }
        do {
            try p.run()
            lock.lock(); process = p; lock.unlock()
            logMessage("Now Playing: Helfer gestartet (\(lib))")
        } catch {
            logMessage("Now Playing: Start fehlgeschlagen: \(error)")
        }
    }

    func stop() {
        lock.lock(); stopped = true; let p = process; lock.unlock()
        p?.terminate()
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var changed: Bool?
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let playing = obj["playing"] as? Bool else { continue }
            failures = 0
            lastUpdate = Date()
            if let p = obj["pid"] as? Int, p > 0 { pid = Int32(p) } else { pid = nil }
            if state != playing { state = playing; changed = playing }
        }
        lock.unlock()
        if let changed { onChange?(changed) }
    }
}

func parseMediaPlaybackCommand(_ payload: String) -> MediaPlaybackCommand? {
    switch payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "play", "on", "true":
        return .play
    case "pause", "off", "false":
        return .pause
    case "toggle", "playpause", "play_pause":
        return .toggle
    default:
        return nil
    }
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

/// Liefert den aktuellen Wiedergabe-Zustand (vom Daemon gesetzt: Now-Playing-Helfer, sonst Fallback).
nonisolated(unsafe) var currentMediaPlaying: () -> Bool? = { MediaRemote.shared.isPlaying() }
/// PID der Now-Playing-App (vom Daemon gesetzt).
nonisolated(unsafe) var currentNowPlayingPID: () -> Int32? = { nil }

/// Setzt die Wiedergabe der App fort, die vorher abgespielt hat – nie eine andere.
/// macOS vergibt „Now Playing“ nach einer Pause manchmal an eine andere App (z. B. einen Browser-Tab);
/// ein globales „Play“ würde dann die falsche App starten.
func resumePlayback(of pid: Int32?) {
    let now = currentNowPlayingPID()
    if pid == nil || now == nil || now == pid {
        _ = MediaRemote.shared.send(.play)
        return
    }
    guard let pid, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
        logMessage("Wiedergabe nicht fortgesetzt: Now Playing hat gewechselt (\(pid ?? -1) -> \(now ?? -1))")
        return
    }
    let scripts: [String: String] = [
        "com.apple.Music": "tell application id \"com.apple.Music\" to play",
        "com.spotify.client": "tell application id \"com.spotify.client\" to play",
        "com.apple.TV": "tell application id \"com.apple.TV\" to play",
        "com.apple.QuickTimePlayerX": "tell application id \"com.apple.QuickTimePlayerX\" to play document 1",
    ]
    if let script = scripts[bundle] {
        if (try? runProcess("/usr/bin/osascript", ["-e", script])) == nil {
            logMessage("Wiedergabe von \(bundle) per AppleScript fehlgeschlagen")
        }
    } else {
        logMessage("Wiedergabe nicht fortgesetzt: Now Playing wechselte von \(bundle) zu einer anderen App")
    }
}

func speakWithMediaPauseAndMuteRestore(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let wasPlaying = currentMediaPlaying() == true
    let playingPID = currentNowPlayingPID()
    let wasMuted = (try? isMuted()) ?? false

    if wasPlaying {
        _ = MediaRemote.shared.send(.pause)
        Thread.sleep(forTimeInterval: 0.25)
    }
    if wasMuted {
        try? setMuted(false)
        Thread.sleep(forTimeInterval: 0.1)
    }

    do {
        try speak(text)
    } catch {
        if wasMuted {
            try? setMuted(true)
        }
        if wasPlaying {
            resumePlayback(of: playingPID)
        }
        throw error
    }

    if wasMuted {
        try? setMuted(true)
    }
    if wasPlaying {
        Thread.sleep(forTimeInterval: 0.25)
        resumePlayback(of: playingPID)
    }
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
    let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }

    guard let property = IORegistryEntryCreateCFProperty(
        root,
        "IOConsoleLocked" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() else {
        return false
    }

    if let locked = property as? Bool {
        return locked
    }
    if let locked = property as? NSNumber {
        return locked.boolValue
    }
    if let locked = property as? String {
        return locked.localizedCaseInsensitiveContains("yes") ||
            locked.localizedCaseInsensitiveContains("true")
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

final class Daemon: NSObject, CocoaMQTTDelegate, @unchecked Sendable {
    private let config: AppConfig
    private let mqtt: CocoaMQTT
    private let workQueue = DispatchQueue(label: "com.example.mac2mqttd.status", qos: .utility)
    private let commandQueue = DispatchQueue(label: "com.example.mac2mqttd.commands", qos: .userInitiated)
    private let nowPlaying = NowPlayingMonitor()
    private var lockedState = isSessionLocked()
    private var volumeTimer: DispatchSourceTimer?
    private var batteryTimer: DispatchSourceTimer?
    private var displayTimer: DispatchSourceTimer?
    private var mediaTimer: DispatchSourceTimer?
    private var lastMediaPlayingState: Bool?
    private var mediaOverrideUntil: Date?
    private var mediaOverrideState: Bool?
    private var suppressAssertionPlayingUntil: Date?
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
                                            qos: .qos0,
                                            retained: true)
    }

    func start() {
        setbuf(stdout, nil)
        registerLockNotifications()
        nowPlaying.onChange = { [weak self] _ in
            self?.workQueue.async { self?.publishMediaPlaybackStatus() }
        }
        nowPlaying.start()
        currentMediaPlaying = { [weak self] in self?.combinedMediaPlaying() }
        currentNowPlayingPID = { [weak self] in self?.nowPlaying.nowPlayingPID }
        logMessage("Starting mac2mqttd ...")
        _ = mqtt.connect()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func publishStatus() {
        do {
            publishStatusTopic("alive", "true")
            publishStatusTopic("volume", String(try currentVolume()))
            publishStatusTopic("mute", String(try isMuted()))
            clearRemovedStatusTopics()
            publishBatteryStatus()
            publishDisplayStatus()
            publishLockStatus()
            publishMediaPlaybackStatus()
        } catch {
            logMessage("Status update error: \(error)")
        }
    }

    private func publishStatusTopic(_ suffix: String, _ value: String) {
        mqtt.publish("\(baseTopic)/status/\(suffix)", withString: value, qos: .qos0, retained: true)
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
                if !clearedBatteryStatus {
                    clearRetainedStatusTopic("battery")
                    clearRetainedStatusTopic("power_source")
                    clearedBatteryStatus = true
                }
                return
            }

            clearedBatteryStatus = false
            if let percent = try batteryPercent() {
                publishStatusTopic("battery", String(percent))
                publishStatusTopic("power_source", try powerSource() ?? "")
            }
        } catch {
            logMessage("Battery status error: \(error)")
        }
    }

    private func publishLockStatus() {
        publishStatusTopic("locked", String(lockedState))
    }

    private func publishMediaPlaybackStatus() {
        guard let isPlaying = currentMediaPlayingState() else { return }
        guard lastMediaPlayingState != isPlaying else { return }
        lastMediaPlayingState = isPlaying
        publishStatusTopic("media_playing", String(isPlaying))
    }

    private func publishMediaPlaybackStatus(force: Bool) {
        guard let isPlaying = currentMediaPlayingState() else { return }
        if !force && lastMediaPlayingState == isPlaying { return }
        lastMediaPlayingState = isPlaying
        publishStatusTopic("media_playing", String(isPlaying))
    }

    private func currentMediaPlayingState() -> Bool? {
        if let mediaOverrideUntil, mediaOverrideUntil > Date(), let mediaOverrideState {
            return mediaOverrideState
        }

        mediaOverrideUntil = nil
        mediaOverrideState = nil

        suppressAssertionPlayingUntil = nil
        return combinedMediaPlaying()
    }

    /// Now Playing (perl-Helfer) ist die Hauptquelle; „Playing audio“-Zusicherungen fangen
    /// Apps ab, die gerade nicht „Now Playing“ sind (z. B. ein Browser-Tab im Hintergrund).
    private func combinedMediaPlaying() -> Bool? {
        guard let np = nowPlaying.playing else { return MediaRemote.shared.isPlaying() }
        if np { return true }
        return MediaRemote.shared.isMediaPlaybackActiveByAssertions() ?? false
    }

    private func overrideMediaPlayingState(_ isPlaying: Bool, duration: TimeInterval = 2.5) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.mediaOverrideState = isPlaying
            self.mediaOverrideUntil = Date().addingTimeInterval(duration)
            self.suppressAssertionPlayingUntil = isPlaying ? nil : Date().addingTimeInterval(duration)
            self.publishMediaPlaybackStatus(force: true)
        }
    }

    private func expectedMediaState(after command: MediaPlaybackCommand) -> Bool? {
        switch command {
        case .play:
            return true
        case .pause:
            return false
        case .toggle:
            return lastMediaPlayingState.map { !$0 }
        }
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

        let volumeTimer = DispatchSource.makeTimerSource(queue: workQueue)
        volumeTimer.schedule(deadline: .now(), repeating: config.intervals.volumeSeconds)
        volumeTimer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                self.publishStatusTopic("volume", String(try currentVolume()))
                self.publishStatusTopic("mute", String(try isMuted()))
            } catch {
                logMessage("Volume poll error: \(error)")
            }
        }
        volumeTimer.resume()
        self.volumeTimer = volumeTimer

        let batteryTimer = DispatchSource.makeTimerSource(queue: workQueue)
        batteryTimer.schedule(deadline: .now(), repeating: config.intervals.batterySeconds)
        batteryTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishBatteryStatus()
        }
        batteryTimer.resume()
        self.batteryTimer = batteryTimer

        let displayTimer = DispatchSource.makeTimerSource(queue: workQueue)
        displayTimer.schedule(deadline: .now(), repeating: config.intervals.displaySeconds ?? 5)
        displayTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishDisplayStatus()
        }
        displayTimer.resume()
        self.displayTimer = displayTimer

        let mediaTimer = DispatchSource.makeTimerSource(queue: workQueue)
        mediaTimer.schedule(deadline: .now(), repeating: config.intervals.mediaSeconds ?? 1)
        mediaTimer.setEventHandler { [weak self] in
            self?.publishMediaPlaybackStatus()
        }
        mediaTimer.resume()
        self.mediaTimer = mediaTimer
    }

    private func cancelPolling() {
        volumeTimer?.cancel()
        volumeTimer = nil
        batteryTimer?.cancel()
        batteryTimer = nil
        displayTimer?.cancel()
        displayTimer = nil
        mediaTimer?.cancel()
        mediaTimer = nil
    }

    private func subscribeCommands() {
        mqtt.subscribe("\(baseTopic)/command/#", qos: .qos0)
    }

    private func registerLockNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(screenDidLock),
                           name: Notification.Name("com.apple.screenIsLocked"),
                           object: nil)
        center.addObserver(self,
                           selector: #selector(screenDidUnlock),
                           name: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil)
    }

    @objc private func screenDidLock() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.lockedState = true
            self.publishLockStatus()
            logMessage("Screen locked")
        }
    }

    @objc private func screenDidUnlock() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.lockedState = false
            self.publishLockStatus()
            logMessage("Screen unlocked")
        }
    }

    private func handleCommand(topic: String, payload: String) {
        switch topic {
        case "\(baseTopic)/command/volume":
            if let value = Int(payload) {
                logIfFails("volume \(value)") { try setVolume(value) }
            }
        case "\(baseTopic)/command/mute":
            logIfFails("mute \(payload)") { try setMuted(payload.lowercased() == "true") }
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
            logIfFails("say") { try speakWithMediaPauseAndMuteRestore(payload) }
        case "\(baseTopic)/command/notification":
            logIfFails("notification") { try showNotification(payload) }
        case "\(baseTopic)/command/screensaver":
            if let saver = screenSaver(for: payload) {
                try? setScreenSaver(saver)
                try? startScreenSaver()
            } else if payload == "start" {
                try? startScreenSaver()
            }
        case "\(baseTopic)/command/app":
            logIfFails("app \(payload)") { try launchOrActivateApp(payload) }
        case "\(baseTopic)/command/media_playback":
            if let command = parseMediaPlaybackCommand(payload) {
                let expectedState = expectedMediaState(after: command)
                _ = MediaRemote.shared.send(command)
                if let expectedState {
                    overrideMediaPlayingState(expectedState)
                } else {
                    workQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.publishMediaPlaybackStatus(force: true)
                    }
                }
            }
        case "\(baseTopic)/command/play_pause":
            let expectedState = expectedMediaState(after: .toggle)
            _ = MediaRemote.shared.send(.toggle)
            if let expectedState {
                overrideMediaPlayingState(expectedState)
            } else {
                workQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.publishMediaPlaybackStatus(force: true)
                }
            }
        default:
            break
        }

        workQueue.async { [weak self] in self?.publishStatus() }
    }

    private func logIfFails(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { logMessage("Befehl \(what) fehlgeschlagen: \(error)") }
    }

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            logMessage("MQTT connect failed: \(ack)")
            return
        }
        logMessage("Connected to MQTT")
        mqtt.publish("\(baseTopic)/status/alive", withString: "true", qos: .qos0, retained: true)
        subscribeCommands()
        workQueue.async { [weak self] in
            self?.publishStatus()
            self?.schedulePolling()
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        logMessage("Disconnected: \(err?.localizedDescription ?? "none")")
        cancelPolling()
    }
    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = message.string ?? ""
        let topic = message.topic
        commandQueue.async { [weak self] in self?.handleCommand(topic: topic, payload: payload) }
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
